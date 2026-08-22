#!/usr/bin/env python3
"""Guest relay for the Path C GitHub proxy transport (contract §3).

Bridges guest TCP connections on 127.0.0.1:18446 over a single framed byte
stream carried by `msb exec --stream` stdin/stdout:

    frame  = 1-byte conn-id + 4-byte big-endian length + payload
    conn-id 0x00 is the control channel:
      relay  -> shuttle  b"O" + conn-id   guest connection opened (open upstream)
      relay  -> shuttle  b"C" + conn-id   guest connection closed (close upstream)
      shuttle -> relay   b"C" + conn-id   upstream closed (close guest socket)

Lifecycle: this process dies with the stream. On stdin EOF (the shuttle or
the msb exec bridge went away) it calls os._exit(0) so it never lingers as a
zombie holding the guest port; the host shuttle respawns a fresh relay.

Heartbeat: every MSW_GITHUB_HEARTBEAT_SECS (default 10) this relay sends a
control frame b"H" so the shuttle can tell a healthy idle tunnel apart from a
wedged one (msb exec can hang without exiting when the sandbox stops
mid-stream; the shuttle kills and respawns us when heartbeats stop).

Security: binds ONLY guest loopback 127.0.0.1:18446. It never listens on any
other interface and carries no credentials — the capability gate lives in the
host proxy.
"""

import os
import select
import socket
import sys
import threading
import time

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = int(os.environ.get("MSW_GITHUB_PROXY_PORT", "18446"))
MAX_CONNS = 254  # conn-id is one byte; 0 is reserved for control
HEARTBEAT_SECS = float(os.environ.get("MSW_GITHUB_HEARTBEAT_SECS", "10"))

CONTROL = 0
OP_OPEN = b"O"
OP_CLOSE = b"C"
OP_HEARTBEAT = b"H"
HEADER = 5  # 1-byte conn-id + 4-byte length
# Hostile-interface hardening (mirror of the shuttle's cap): frames are
# produced by chunking socket reads of at most 65536 bytes, so no legitimate
# frame is ever larger. A declared length above this cap is a protocol
# violation and the relay dies fail-closed. MUST match MAX_FRAME in
# msw-github-shuttle.py.
MAX_FRAME = 65536


class ProtocolViolation(Exception):
    """The host stream violated the framing contract; the relay dies."""


class Relay:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._conns: dict[int, socket.socket] = {}
        self._free_ids = set(range(1, MAX_CONNS + 1))
        self._stdout_lock = threading.Lock()

    # -- conn-id management -------------------------------------------------
    def alloc_id(self) -> int | None:
        with self._lock:
            if not self._free_ids:
                return None
            chosen = min(self._free_ids)
            self._free_ids.discard(chosen)
            return chosen

    def free_id(self, conn_id: int) -> None:
        with self._lock:
            self._free_ids.add(conn_id)

    def close_guest(self, conn_id: int) -> None:
        with self._lock:
            sock = self._conns.pop(conn_id, None)
        if sock is None:
            return
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            sock.close()
        except OSError:
            pass
        self.free_id(conn_id)

    # -- stream output (framed, atomic under the stdout lock) ---------------
    def write_stream(self, frame: bytes) -> None:
        with self._stdout_lock:
            view = memoryview(frame)
            while view:
                try:
                    written = os.write(1, view)
                except OSError:
                    os._exit(1)
                if written <= 0:
                    os._exit(1)
                view = view[written:]

    def send_control(self, payload: bytes) -> None:
        self.write_stream(bytes([CONTROL]) + len(payload).to_bytes(4, "big") + payload)

    def send_data(self, conn_id: int, payload: bytes) -> None:
        self.write_stream(bytes([conn_id]) + len(payload).to_bytes(4, "big") + payload)

    # -- host frames (shuttle -> relay) -------------------------------------
    def handle_host_frame(self, conn_id: int, payload: bytes) -> None:
        if conn_id == CONTROL:
            # Only byte-exact b"C"+id control frames are legal from the host.
            if len(payload) == 2 and payload[:1] == OP_CLOSE:
                target = payload[1]
                if target != CONTROL:
                    self.close_guest(target)
                return
            raise ProtocolViolation("malformed control frame on conn-id 0")
        if not payload:
            raise ProtocolViolation("zero-length data frame for conn %d" % conn_id)
        with self._lock:
            sock = self._conns.get(conn_id)
        if sock is None:
            # In-flight data for a guest connection that already closed: drop.
            return
        try:
            sock.sendall(payload)
        except OSError:
            with self._lock:
                current = self._conns.get(conn_id)
            if current is sock:
                self.close_guest(conn_id)

    def stream_reader(self) -> None:
        header = bytearray()
        while True:
            # Read the 5-byte header exactly.
            while len(header) < HEADER:
                try:
                    chunk = os.read(0, HEADER - len(header))
                except OSError:
                    os._exit(0)
                if not chunk:
                    os._exit(0)  # stream died: this relay is done
                header += chunk
            conn_id = header[0]
            length = int.from_bytes(header[1:HEADER], "big")
            header.clear()
            # Reject oversized declared frames BEFORE buffering any payload.
            if length > MAX_FRAME:
                os._exit(1)
            payload = bytearray()
            while len(payload) < length:
                try:
                    chunk = os.read(0, length - len(payload))
                except OSError:
                    os._exit(0)
                if not chunk:
                    os._exit(0)
                payload += chunk
            try:
                self.handle_host_frame(conn_id, bytes(payload))
            except ProtocolViolation:
                os._exit(1)

    # -- guest connection handling ------------------------------------------
    def handle_guest(self, sock: socket.socket, conn_id: int) -> None:
        try:
            while True:
                try:
                    data = sock.recv(65536)
                except socket.timeout:
                    continue
                except OSError:
                    break
                if not data:
                    break
                self.send_data(conn_id, data)
        finally:
            # Only tear down if this thread still OWNS the conn-id: the id can
            # be freed and reused by a newer guest connection before this
            # stale reader sees EOF; closing then would kill the new
            # connection (and a stale CLOSE frame would kill its upstream).
            with self._lock:
                current = self._conns.get(conn_id)
            if current is sock:
                self.close_guest(conn_id)
                self.send_control(OP_CLOSE + bytes([conn_id]))

    # -- accept loop ---------------------------------------------------------
    def heartbeat_loop(self) -> None:
        # An immediate first beat lets the shuttle confirm the relay is up
        # quickly; subsequent beats keep idle tunnels distinguishable from
        # wedged ones (msb exec can hang when the sandbox stops mid-stream).
        while True:
            try:
                self.send_control(OP_HEARTBEAT)
            except OSError:
                os._exit(0)
            time.sleep(HEARTBEAT_SECS)

    def run(self) -> None:
        threading.Thread(target=self.stream_reader, daemon=True).start()
        threading.Thread(target=self.heartbeat_loop, daemon=True).start()
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            listener.bind((LISTEN_HOST, LISTEN_PORT))
            listener.listen(32)
        except OSError as exc:
            sys.stderr.write("relay: cannot bind %s:%d: %s\n" % (LISTEN_HOST, LISTEN_PORT, exc))
            os._exit(1)
        sys.stderr.write("relay: listening on %s:%d (pid %d)\n" % (LISTEN_HOST, LISTEN_PORT, os.getpid()))
        while True:
            try:
                sock, _ = listener.accept()
            except OSError:
                continue
            conn_id = self.alloc_id()
            if conn_id is None:
                try:
                    sock.close()
                except OSError:
                    pass
                continue
            sock.settimeout(60)
            with self._lock:
                self._conns[conn_id] = sock
            self.send_control(OP_OPEN + bytes([conn_id]))
            threading.Thread(target=self.handle_guest, args=(sock, conn_id), daemon=True).start()


def main() -> int:
    for signum in ("SIGTERM", "SIGINT", "SIGHUP"):
        try:
            signal_handler = getattr(__import__("signal"), signum)
            __import__("signal").signal(signal_handler, lambda *_: os._exit(0))
        except (AttributeError, ValueError):
            pass
    Relay().run()
    return 0


if __name__ == "__main__":
    main()
