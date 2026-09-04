#!/usr/bin/python3
"""Silo GitHub proxy -- outbound (upstream) leg (host-proxy contract section 4).

The upstream side is the TRUSTED leg (real github.com / objects.githubusercontent.com,
or the tests/fake_github.py fixture via SILO_PROXY_UPSTREAM_ROOT). It therefore uses
stdlib `http.client` (TLS with system roots, fail-closed; plain HTTP only when a
test seam points at the fake). The HOSTILE ingress leg is parsed exclusively by the
vendored h11 tree in lib/proxycore.py -- nothing in this module touches ingress bytes.

Contract-relevant properties implemented here:
  * Streaming: request bodies are pushed to send_body() by the caller as
    h11 decodes them and are forwarded socket-to-socket; response bodies
    stream to the caller chunk by chunk. Nothing is buffered whole (except
    what the caller explicitly buffers for the LFS batch JSON rewrite).
  * Framing: Content-Length is passed through when the ingress had Content-Length;
    chunked ingress is re-encoded as chunked (a Content-Length is NEVER
    synthesized for a chunked body).
  * Hop-by-hop headers are stripped by the caller; this module never adds headers
    beyond what the caller passes.
  * Idle timeout / total deadline: every blocking socket operation is bounded by
    min(idle_timeout, deadline - elapsed). A socket.timeout is classified as an
    idle timeout unless the total deadline has passed.
  * Abort semantics: on any upstream failure mid-body, UpstreamError is raised so
    the caller tears both legs down; a partial body can never appear complete.

This module imports stdlib only and never imports lib/proxycore.py.
"""
from __future__ import annotations

import http.client
import socket
import ssl
import time
import urllib.parse
from typing import Any, List, Optional, Tuple

# Hop-by-hop headers stripped on BOTH legs (ingress->outbound and
# outbound->client). Content-Length / Transfer-Encoding are handled separately
# by the framing logic in the caller, so they are excluded here.
HOP_BY_HOP = frozenset(
    {
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "proxy-connection",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
        "expect",
        "host",
    }
)

_CHUNK = 64 * 1024


class UpstreamError(Exception):
    """An upstream failure that must tear down both legs (fail-closed)."""

    def __init__(self, reason: str, *, category: str = "upstream", status: int = 502) -> None:
        super().__init__(reason)
        self.reason = reason
        self.category = category
        self.status = status


class UpstreamIdleTimeout(UpstreamError):
    """No upstream data within SILO_PROXY_IDLE_TIMEOUT."""

    def __init__(self) -> None:
        super().__init__("idle timeout waiting on upstream", category="idle", status=504)


class UpstreamDeadline(UpstreamError):
    """SILO_PROXY_TOTAL_DEADLINE elapsed while talking to upstream."""

    def __init__(self) -> None:
        super().__init__("total deadline exceeded while talking to upstream", category="deadline", status=504)


class Upstream:
    """One outbound connection to the configured upstream root."""

    def __init__(self, root: str, idle_timeout: float) -> None:
        parsed = urllib.parse.urlsplit(root)
        if parsed.scheme not in ("http", "https"):
            raise UpstreamError(f"unsupported upstream scheme {parsed.scheme!r}", category="config")
        if not parsed.hostname:
            raise UpstreamError("upstream root has no host", category="config")
        self.scheme = parsed.scheme
        self.host = parsed.hostname
        try:
            self.port = parsed.port or (443 if self.scheme == "https" else 80)
        except ValueError:
            raise UpstreamError("upstream root has an invalid port", category="config") from None
        # host[:port] authority used for the outbound Host header (the fake
        # fixture derives its LFS href base from this header).
        self.netloc = parsed.netloc
        self.idle_timeout = idle_timeout
        self.conn: Optional[http.client.HTTPConnection] = None
        self.sock: Optional[socket.socket] = None
        self.resp: Optional[http.client.HTTPResponse] = None
        self.framing: str = "none"

    @classmethod
    def from_href(cls, href: str, idle_timeout: float) -> "Upstream":
        """Build an upstream connection from an absolute href.

        Used by the objects leg: the REAL href (and its credential headers)
        are decrypted host-side from the proxy stamp and the connection
        targets that href directly -- the VM never supplies the outbound
        target or headers.
        """
        parsed = urllib.parse.urlsplit(href)
        if parsed.scheme not in ("http", "https") or not parsed.hostname:
            raise UpstreamError("invalid stamped href", category="config")
        root = f"{parsed.scheme}://{parsed.netloc}"
        return cls(root, idle_timeout)

    # ---- connection ----

    def connect(self) -> None:
        try:
            if self.scheme == "https":
                # System trust roots, hostname verification, fail-closed.
                ctx = ssl.create_default_context()
                self.conn = http.client.HTTPSConnection(
                    self.host, self.port, timeout=self.idle_timeout, context=ctx
                )
            else:
                self.conn = http.client.HTTPConnection(self.host, self.port, timeout=self.idle_timeout)
            self.conn.connect()
            self.sock = self.conn.sock
        except UpstreamError:
            raise
        except Exception as exc:  # noqa: BLE001 -- fail-closed upstream
            raise UpstreamError(
                f"upstream connect failed: {type(exc).__name__}", category="upstream"
            ) from exc

    # ---- timeouts ----

    def _set_socket_timeout(self, deadline_start: float, total_deadline: float) -> None:
        if self.sock is None:
            return
        elapsed = time.monotonic() - deadline_start
        remaining = total_deadline - elapsed
        if remaining <= 0:
            raise UpstreamDeadline()
        self.sock.settimeout(min(self.idle_timeout, remaining))

    def _classify_timeout(self, deadline_start: float, total_deadline: float) -> None:
        if time.monotonic() - deadline_start >= total_deadline:
            raise UpstreamDeadline()
        raise UpstreamIdleTimeout()

    # ---- request leg ----

    def start_request(
        self,
        method: str,
        path: str,
        headers: List[Tuple[str, str]],
        framing: str,
        deadline_start: float,
        total_deadline: float,
    ) -> None:
        """Send the request line + headers for a body framed by `framing`.

        framing: "none", "cl" (caller added Content-Length to headers),
        or "chunked" (caller added Transfer-Encoding). Body bytes follow via
        send_body()/finish_body() so ingress data streams upstream as it
        arrives -- never buffered or spooled.
        """
        if self.conn is None:
            raise UpstreamError("upstream not connected", category="config")
        self.framing = framing
        try:
            self._set_socket_timeout(deadline_start, total_deadline)
            self.conn.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
            for name, value in headers:
                self.conn.putheader(name, value)
            self.conn.endheaders()
        except (UpstreamError, UpstreamIdleTimeout, UpstreamDeadline):
            raise
        except socket.timeout:
            self._classify_timeout(deadline_start, total_deadline)
        except Exception as exc:  # noqa: BLE001 -- fail-closed upstream
            raise UpstreamError(
                f"upstream request failed: {type(exc).__name__}", category="upstream"
            ) from exc

    def send_body(
        self, data: bytes, deadline_start: float, total_deadline: float
    ) -> None:
        """Stream one chunk of the request body with the negotiated framing.

        Content-Length framing sends raw bytes (the caller streams exactly the
        declared count); chunked framing re-encodes each chunk (a
        Content-Length is never synthesized).
        """
        if self.conn is None:
            raise UpstreamError("upstream not connected", category="config")
        if not data:
            return
        try:
            self._set_socket_timeout(deadline_start, total_deadline)
            if self.framing == "chunked":
                self.conn.send(b"%x\r\n" % len(data))
                self.conn.send(data)
                self.conn.send(b"\r\n")
            else:
                self.conn.send(data)
        except (UpstreamError, UpstreamIdleTimeout, UpstreamDeadline):
            raise
        except socket.timeout:
            self._classify_timeout(deadline_start, total_deadline)
        except Exception as exc:  # noqa: BLE001 -- fail-closed upstream
            raise UpstreamError(
                f"upstream body send failed: {type(exc).__name__}", category="upstream"
            ) from exc

    def finish_body(self, deadline_start: float, total_deadline: float) -> None:
        """Terminate the body: the terminal chunk for chunked framing."""
        if self.conn is None or self.framing != "chunked":
            return
        try:
            self._set_socket_timeout(deadline_start, total_deadline)
            self.conn.send(b"0\r\n\r\n")
        except (UpstreamError, UpstreamIdleTimeout, UpstreamDeadline):
            raise
        except socket.timeout:
            self._classify_timeout(deadline_start, total_deadline)
        except Exception as exc:  # noqa: BLE001 -- fail-closed upstream
            raise UpstreamError(
                f"upstream body finish failed: {type(exc).__name__}", category="upstream"
            ) from exc

    def send_request(
        self,
        method: str,
        path: str,
        headers: List[Tuple[str, str]],
        body: bytes,
        framing: str,
        deadline_start: float,
        total_deadline: float,
    ) -> None:
        """Send a fully-buffered body (used only for the bounded LFS batch)."""
        self.start_request(method, path, headers, framing, deadline_start, total_deadline)
        if framing != "none":
            self.send_body(body, deadline_start, total_deadline)
            self.finish_body(deadline_start, total_deadline)

    # ---- response leg ----

    def read_response_head(
        self, deadline_start: float, total_deadline: float
    ) -> Tuple[int, str, List[Tuple[str, str]]]:
        """Return (status, reason, headers) for the upstream response head."""
        if self.conn is None:
            raise UpstreamError("upstream not connected", category="config")
        try:
            self._set_socket_timeout(deadline_start, total_deadline)
            resp = self.conn.getresponse()
            self.resp = resp
            return resp.status, resp.reason or "", [(str(n), str(v)) for n, v in resp.getheaders()]
        except (UpstreamError, UpstreamIdleTimeout, UpstreamDeadline):
            raise
        except socket.timeout:
            self._classify_timeout(deadline_start, total_deadline)
        except Exception as exc:  # noqa: BLE001 -- fail-closed upstream
            raise UpstreamError(
                f"upstream response failed: {type(exc).__name__}", category="upstream"
            ) from exc
        raise UpstreamError("upstream response failed", category="upstream")  # pragma: no cover

    def read_body(
        self, size: int, deadline_start: float, total_deadline: float
    ) -> bytes:
        """Read up to `size` decoded body bytes from the upstream response."""
        if self.resp is None:
            raise UpstreamError("no upstream response in progress", category="config")
        try:
            self._set_socket_timeout(deadline_start, total_deadline)
            return self.resp.read(size)
        except (UpstreamError, UpstreamIdleTimeout, UpstreamDeadline):
            raise
        except socket.timeout:
            self._classify_timeout(deadline_start, total_deadline)
        except http.client.IncompleteRead as exc:
            # Upstream closed mid-body: partial must never appear complete.
            raise UpstreamError(
                "upstream closed mid-body (partial response)", category="upstream"
            ) from exc
        except Exception as exc:  # noqa: BLE001 -- fail-closed upstream
            raise UpstreamError(
                f"upstream body read failed: {type(exc).__name__}", category="upstream"
            ) from exc
        raise UpstreamError("upstream body read failed", category="upstream")  # pragma: no cover

    def close(self) -> None:
        try:
            if self.conn is not None:
                self.conn.close()
        except Exception:  # noqa: BLE001 -- teardown is best-effort
            pass
        self.conn = None
        self.sock = None
        self.resp = None
