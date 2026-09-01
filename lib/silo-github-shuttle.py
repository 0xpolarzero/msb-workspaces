#!/usr/bin/env python3
"""Host shuttle for the Path C GitHub proxy transport (contract §3).

One shuttle per workspace. It spawns the guest relay through the byte-faithful
`msb exec <box> --stream -- python3 <relay>` bridge and multiplexes the framed
stream to the proxy at host 127.0.0.1:18446:

    frame  = 1-byte conn-id + 4-byte big-endian length + payload
    conn-id 0x00 is the control channel:
      relay  -> shuttle  b"O" + conn-id   guest connection opened -> connect upstream
      relay  -> shuttle  b"C" + conn-id   guest connection closed  -> close upstream
      shuttle -> relay   b"C" + conn-id   upstream closed          -> close guest socket

Lifecycle (self-heal): if the relay process dies (sandbox stopped, stream
broken, shuttle SIGKILLed), this process respawns it with backoff, so the
tunnel recovers when the sandbox comes back. Because msb exec can hang
without exiting when the sandbox stops mid-stream, the relay sends a
heartbeat control frame every 10s; a silent stream for >30s is treated as a
dead relay and the child is killed and respawned. The shuttle itself is
respawned by launchd KeepAlive (installed by `silo github proxy-configure`) or
by the app; on SIGTERM/SIGINT it tears the relay down and exits 0.

Retry circuit: before every spawn the shuttle runs ONE authoritative
precondition probe — the guest relay artifact exists AND the guest can
execute it (`command -v python3`) — with an explicit absent/present/unknown
result. ABSENT (missing relay or missing interpreter) is a PERMANENT
precondition failure: the shuttle emits exactly ONE actionable failure line
(SILO_RELAY_NOT_INSTALLED) and stops spawning, re-checking the precondition
every CIRCUIT_POLL_SECS so a repair (`silo github proxy-configure <box>` or a
policy apply) resumes the tunnel without a shuttle restart. UNKNOWN (the
probe itself failed) and every post-spawn failure — including a relay that
dies later with an unrelated ENOENT — stay transient and keep the bounded
exponential backoff.

Gotchas (verified in the GuestPlumbingPlan spike): the host side must use
os.read()/os.write() on the child pipes — BufferedReader.read(n) blocks until
n bytes or EOF and wedges the tunnel on sparse frames. The relay dies with
the stream (os._exit(0) on stdin EOF) so no zombie holds the guest port.

Security: this process never listens on any host interface; it only dials
host loopback 127.0.0.1:18446 and carries no credentials.
"""

import os
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import faulthandler
from typing import Optional

CONTROL = 0
OP_OPEN = b"O"
OP_CLOSE = b"C"
OP_HEARTBEAT = b"H"
HEADER = 5  # 1-byte conn-id + 4-byte length
INTERNAL_LOG_SESSION_SIGNATURE = (
    bytes([CONTROL]) + len(OP_HEARTBEAT).to_bytes(4, "big") + OP_HEARTBEAT
)

PROXY_HOST = os.environ.get("SILO_GITHUB_PROXY_HOST", "127.0.0.1")
PROXY_PORT = int(os.environ.get("SILO_GITHUB_PROXY_PORT", "18446"))
GUEST_RELAY = os.environ.get("SILO_GUEST_RELAY_PATH", "/var/lib/silo-runtime/silo-github-relay.py")
HEARTBEAT_TIMEOUT = float(os.environ.get("SILO_GITHUB_HEARTBEAT_TIMEOUT", "30"))
# CIRCUIT_POLL_SECS is how often an open retry circuit re-checks the relay
# precondition so an external repair resumes the tunnel without a shuttle
# restart (see the module docstring).
CIRCUIT_POLL_SECS = float(os.environ.get("SILO_GITHUB_CIRCUIT_POLL_SECS", "60"))
# Hostile-interface hardening: the relay is the untrusted side of this pipe.
# Frames are produced by chunking socket reads of at most 65536 bytes, so no
# legitimate frame is ever larger. Any declared length above this cap is a
# protocol violation and tears the whole stream down before any payload is
# buffered. MUST match MAX_FRAME in silo-github-relay.py.
MAX_FRAME = 65536


class ProtocolViolation(Exception):
    """The relay violated the framing contract; the whole stream is untrusted."""


def log(message: str) -> None:
    sys.stderr.write("shuttle[%s] %s %s\n" % (os.getpid(), time.strftime("%H:%M:%S"), message))
    sys.stderr.flush()


class Shuttle:
    def __init__(self, box: str) -> None:
        self._box = box
        self._msb = os.environ.get("SILO_MSB_BIN") or shutil.which("msb") or ""
        self._running = True
        self._child: subprocess.Popen[bytes] | None = None
        self._reader: threading.Thread | None = None
        self._upstreams: dict[int, socket.socket] = {}
        self._lock = threading.Lock()
        self._stdin_lock = threading.Lock()
        self._backoff = 0.5
        self._relay_uptime: float | None = None
        self._last_activity = 0.0
        self._stream_dead = False
        self._circuit_open = False
        self._pidfile = os.environ.get("SILO_SHUTTLE_PID_FILE") or os.path.join(
            os.path.expanduser("~"), ".local", "state", "silo", "shuttle-%s.pid" % box
        )

    # -- pidfile ------------------------------------------------------------
    def write_pidfile(self) -> None:
        try:
            os.makedirs(os.path.dirname(self._pidfile), exist_ok=True)
            with open(self._pidfile, "w", encoding="ascii") as fh:
                fh.write("%d\n" % os.getpid())
        except OSError as exc:
            log("cannot write pidfile %s: %s" % (self._pidfile, exc))

    def remove_pidfile(self) -> None:
        try:
            if os.path.exists(self._pidfile):
                os.unlink(self._pidfile)
        except OSError:
            pass

    # -- relay process management -------------------------------------------
    def spawn_relay(self) -> None:
        if not self._msb:
            log("msb binary not found (SILO_MSB_BIN unset and no msb on PATH); exiting")
            self._running = False
            return
        log("spawning relay: %s exec %s --stream -- (internal marker) python3 %s"
            % (self._msb, self._box, GUEST_RELAY))
        try:
            # The wrapper prints the reserved internal-session marker frame
            # before exec'ing the relay, so the MicroSandbox log adapter
            # classifies this whole exec session as control-plane even when
            # the relay can never start (missing file, interpreter error)
            # and therefore never emits its own heartbeat. The marker is a
            # byte-exact heartbeat control frame the shuttle already treats
            # as benign. The real command follows $0 ("silo-shuttle"); the
            # MicroSandbox test simulator strips the wrapper and restores
            # the `python3 <relay>` form it would run.
            self._child = subprocess.Popen(
                [self._msb, "exec", self._box, "--stream", "--",
                 "bash", "-c", "printf '\\x00\\x00\\x00\\x00\\x01H'; exec python3 \"$1\"",
                 "silo-shuttle", GUEST_RELAY],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                bufsize=0,
            )
        except OSError as exc:
            log("failed to spawn msb exec: %s" % exc)
            self._child = None
            return
        self._relay_uptime = time.monotonic()
        self._last_activity = time.monotonic()
        self._stream_dead = False
        self._reader = threading.Thread(target=self.stream_reader, daemon=True)
        self._reader.start()
        log("relay spawned (pid %d)" % self._child.pid)

    def sandbox_up(self) -> bool:
        """True only when the sandbox is currently running.

        msb exec auto-boots a stopped sandbox, which would silently undo a
        user's `silo stop`. The shuttle must therefore never spawn the relay
        while the sandbox is stopped; it waits and retries instead.
        """
        if not self._msb:
            return False
        try:
            proc = subprocess.run(
                [self._msb, "ping", "-q", self._box],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=10,
            )
        except (OSError, subprocess.SubprocessError):
            return False
        return proc.returncode == 0

    def relay_precondition(self) -> str:
        """The ONE authoritative relay precondition, checked before every
        spawn and while the retry circuit is open:

        'present' — the guest relay artifact exists AND the guest can execute
        it (`command -v python3`), so a spawn attempt is justified;
        'absent' — the artifact or interpreter is missing, a PERMANENT
        condition no respawn can fix;
        'unknown' — the probe itself failed (transient; callers must keep
        bounded backoff and never open the circuit on this result)."""
        if not self._msb:
            return "absent"
        try:
            proc = subprocess.run(
                [self._msb, "exec", "--no-tty", self._box, "--", "sh", "-c",
                 "test -f %s && command -v python3 >/dev/null" % GUEST_RELAY],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=10,
            )
        except (OSError, subprocess.SubprocessError):
            return "unknown"
        return "present" if proc.returncode == 0 else "absent"

    def open_circuit(self) -> None:
        """Stop respawning after a permanent precondition failure. Emits the
        single actionable failure; the run loop re-checks the artifact every
        CIRCUIT_POLL_SECS and closes the circuit once it reappears."""
        if self._circuit_open:
            return
        self._circuit_open = True
        log(
            "relay failure for %s: SILO_RELAY_NOT_INSTALLED guest relay %s is missing or cannot be executed; "
            "retry circuit opened, relay respawns stopped. Repair: run 'silo github proxy-configure %s' "
            "or re-apply the GitHub policy." % (self._box, GUEST_RELAY, self._box)
        )

    def kill_child(self) -> None:
        child = self._child
        if child is None:
            return
        try:
            child.kill()
        except OSError:
            pass
        try:
            child.wait(timeout=5)
        except OSError:
            pass

    def close_child(self) -> None:
        child, self._child = self._child, None
        if child is None:
            return
        try:
            if child.stdin:
                child.stdin.close()  # relay sees EOF and os._exit(0)
        except OSError:
            pass
        try:
            if child.stdout:
                child.stdout.close()
        except OSError:
            pass
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                child.kill()
            except OSError:
                pass
            try:
                child.wait(timeout=5)
            except OSError:
                pass
        except OSError:
            pass

    def teardown_conns(self) -> None:
        with self._lock:
            conns = list(self._upstreams.items())
            self._upstreams.clear()
        for _conn_id, sock in conns:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                sock.close()
            except OSError:
                pass

    def next_backoff(self) -> float:
        delay = self._backoff
        self._backoff = min(self._backoff * 2, 8.0)
        return delay

    # -- relay frames (child stdout -> proxy) -------------------------------
    def stream_reader(self) -> None:
        child = self._child
        if child is None or child.stdout is None:
            return
        fd = child.stdout.fileno()
        header = bytearray()
        while self._running:
            # Read the 5-byte header exactly, byte-by-byte.
            while len(header) < HEADER:
                try:
                    chunk = os.read(fd, HEADER - len(header))
                except OSError:
                    self._stream_dead = True
                    return
                if not chunk:
                    self._stream_dead = True
                    return
                self._last_activity = time.monotonic()
                header += chunk
            conn_id = header[0]
            length = int.from_bytes(header[1:HEADER], "big")
            header.clear()
            # Reject oversized declared frames BEFORE buffering any payload.
            if length > MAX_FRAME:
                self.protocol_violation("declared frame length %d exceeds cap %d" % (length, MAX_FRAME))
                return
            # Read exactly `length` payload bytes into a bounded buffer.
            payload = bytearray()
            while len(payload) < length:
                try:
                    chunk = os.read(fd, length - len(payload))
                except OSError:
                    self._stream_dead = True
                    return
                if not chunk:
                    self._stream_dead = True
                    return
                self._last_activity = time.monotonic()
                payload += chunk
            try:
                self.handle_relay_frame(conn_id, bytes(payload))
            except ProtocolViolation as exc:
                self.protocol_violation(str(exc))
                return
        self._stream_dead = True

    def handle_relay_frame(self, conn_id: int, payload: bytes) -> None:
        if conn_id == CONTROL:
            # Control frames must be byte-exact: b"O"+id / b"C"+id (2 bytes)
            # or b"H" (1 byte). Anything else is a protocol violation.
            if len(payload) == 2 and payload[:1] == OP_OPEN:
                target = payload[1]
                if target == CONTROL:
                    raise ProtocolViolation("OPEN for control conn-id 0")
                self.open_upstream(target)
                return
            if len(payload) == 2 and payload[:1] == OP_CLOSE:
                self.close_upstream(payload[1], send_close=False)
                return
            if payload == INTERNAL_LOG_SESSION_SIGNATURE[HEADER:]:
                return
            raise ProtocolViolation("malformed control frame on conn-id 0")
        if not payload:
            # The relay only emits data frames from socket reads, which are
            # never empty; a zero-length data frame is malformed.
            raise ProtocolViolation("zero-length data frame for conn %d" % conn_id)
        with self._lock:
            sock = self._upstreams.get(conn_id)
        if sock is None:
            # Legitimate race: the relay may still have in-flight data for a
            # connection the upstream already closed. Drop, don't tear down.
            return
        try:
            sock.sendall(payload)
        except OSError:
            with self._lock:
                current = self._upstreams.get(conn_id)
            if current is sock:
                self.close_upstream(conn_id)

    def protocol_violation(self, reason: str) -> None:
        """The relay stream is hostile/untrusted: kill the child, close every
        upstream socket for this relay session, and let self-heal respawn a
        fresh relay. Never attempt to resync on a hostile stream."""
        log("protocol violation from relay: %s; tearing down stream" % reason)
        self._stream_dead = True
        self.kill_child()
        self.teardown_conns()

    # -- upstream proxy connections -----------------------------------------
    def open_upstream(self, conn_id: int) -> None:
        with self._lock:
            if conn_id in self._upstreams:
                raise ProtocolViolation("duplicate OPEN for conn %d" % conn_id)
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(10)
        try:
            sock.connect((PROXY_HOST, PROXY_PORT))
        except OSError as exc:
            log("upstream connect to %s:%d failed for conn %d: %s" % (PROXY_HOST, PROXY_PORT, conn_id, exc))
            try:
                sock.close()
            except OSError:
                pass
            self.send_to_relay(CONTROL, OP_CLOSE + bytes([conn_id]))
            return
        sock.settimeout(60)
        with self._lock:
            self._upstreams[conn_id] = sock
        threading.Thread(target=self.upstream_reader, args=(sock, conn_id), daemon=True).start()

    def upstream_reader(self, sock: socket.socket, conn_id: int) -> None:
        try:
            while self._running:
                try:
                    data = sock.recv(65536)
                except socket.timeout:
                    continue
                except OSError:
                    break
                if not data:
                    break
                self.send_to_relay(conn_id, data)
        finally:
            # Only tear down if this reader still OWNS the conn-id. The id can
            # be freed and reused by a newer connection before this stale
            # reader notices EOF; closing then would kill the new connection.
            with self._lock:
                current = self._upstreams.get(conn_id)
            if current is sock:
                self.close_upstream(conn_id)

    def close_upstream(self, conn_id: int, send_close: bool = True) -> None:
        with self._lock:
            sock = self._upstreams.pop(conn_id, None)
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
        if send_close:
            self.send_to_relay(CONTROL, OP_CLOSE + bytes([conn_id]))

    def send_to_relay(self, conn_id: int, payload: bytes) -> None:
        child = self._child
        if child is None or child.poll() is not None or child.stdin is None:
            return
        frame = bytes([conn_id]) + len(payload).to_bytes(4, "big") + payload
        with self._stdin_lock:
            try:
                fd = child.stdin.fileno()
                view = memoryview(frame)
                while view:
                    written = os.write(fd, view)
                    if written <= 0:
                        return
                    view = view[written:]
            except OSError:
                return

    # -- main loop ----------------------------------------------------------
    def run(self) -> None:
        self.write_pidfile()
        log("shuttle starting for %s -> %s:%d" % (self._box, PROXY_HOST, PROXY_PORT))
        while self._running:
            if not self._msb:
                break
            if not self.sandbox_up():
                # Never spawn while the sandbox is stopped: msb exec would
                # auto-boot it and silently undo a user's `silo stop`.
                time.sleep(2)
                continue
            if self._circuit_open:
                # Permanent precondition failure: do not respawn. Re-check the
                # precondition slowly; a repair (`silo github proxy-configure`
                # or a policy apply) closes the circuit without a restart.
                if self.relay_precondition() == "present":
                    log("guest relay %s present again; retry circuit closed" % GUEST_RELAY)
                    self._circuit_open = False
                    self._backoff = 0.5
                else:
                    time.sleep(CIRCUIT_POLL_SECS)
                    continue
            state = self.relay_precondition()
            if state == "absent":
                # Permanent: the relay artifact or interpreter is missing; no
                # respawn can fix it. Exactly one actionable failure line.
                self.open_circuit()
                continue
            if state == "unknown":
                # The probe itself failed: transient, bounded backoff. Never
                # opens the permanent circuit.
                delay = self.next_backoff()
                log("relay precondition check failed; retrying in %.1fs" % delay)
                time.sleep(delay)
                continue
            self.spawn_relay()
            while self._running:
                child = self._child
                if child is None:
                    break
                rc = child.poll()
                if rc is not None:
                    log("relay exited rc=%s" % rc)
                    break
                if self._stream_dead:
                    log("relay stream closed; killing child")
                    self.kill_child()
                    break
                if time.monotonic() - self._last_activity > HEARTBEAT_TIMEOUT:
                    log("relay heartbeat stalled (>%.0fs); killing child" % HEARTBEAT_TIMEOUT)
                    self.kill_child()
                    break
                time.sleep(0.5)
            if not self._running:
                break
            self.teardown_conns()
            self.close_child()
            if self._relay_uptime and (time.monotonic() - self._relay_uptime) >= 10:
                self._backoff = 0.5
            delay = self.next_backoff()
            log("respawn in %.1fs" % delay)
            time.sleep(delay)
        self.teardown_conns()
        self.close_child()
        self.remove_pidfile()
        log("shuttle exiting")
        return

    def on_signal(self, _signum: int, _frame) -> None:
        log("signal received; shutting down")
        self._running = False


def main() -> int:
    if len(sys.argv) != 2 or not sys.argv[1] or sys.argv[1].startswith("-"):
        sys.stderr.write("usage: silo-github-shuttle.py WORKSPACE\n")
        return 2
    shuttle = Shuttle(sys.argv[1])
    faulthandler.register(signal.SIGUSR1, file=sys.stderr)
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, shuttle.on_signal)
    try:
        shuttle.run()
    finally:
        shuttle.remove_pidfile()
    return 0


if __name__ == "__main__":
    main()
