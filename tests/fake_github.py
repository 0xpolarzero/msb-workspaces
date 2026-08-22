#!/usr/bin/python3
"""Stateful fake GitHub server for the MSW Monitor Path C proxy tests.

Phase 0 fixture: a stdlib-only, DUMB recording upstream that speaks the git
smart-HTTP protocol, a small GitHub REST surface, and Git LFS basic transfer.
It enforces NO policy itself (no capability checks, no push gates, no
permission decisions) — the proxy is the checker. Every request is recorded
to a state dir and failure injection is supported so proxy tests can observe
upstream stalls, aborts, and oversized upstreams.

ENV INTERFACE (for Phase 1 proxy-test implementers)
---------------------------------------------------
MSW_FAKE_GITHUB_PORT        int    TCP port to listen on; 0 = ephemeral. The
                                   chosen port is printed on the ready line.
                                   TestEnv.start_fake_github() always passes 0
                                   and reads the ready line for the real port.
MSW_FAKE_GITHUB_STATE       path   State dir (created if missing). Holds:
                                   requests.jsonl  one JSON line per request
                                   control.json    failure-injection control
                                   repos.json      /repos/{o}/{r} permissions
                                   user.json       GET /user payload override
                                   lfs-objects/    stored LFS object blobs
                                   server.err      server + git stderr
MSW_FAKE_GITHUB_REMOTE_ROOT path   Directory of bare repos laid out as
                                   {owner}/{repo}.git (same layout as the
                                   suite's MSW_TEST_GITHUB_REMOTE_ROOT, which
                                   is the fallback; final fallback is
                                   <state>/remotes).
MSW_FAKE_GITHUB_MODE        str    Initial failure-injection mode:
                                   normal | drop | slow=<seconds> | oversized.
                                   Runtime changes go in <state>/control.json
                                   (see FAILURE INJECTION below).

ENDPOINTS (all under the base URL http://127.0.0.1:<port>)
- GET  /{o}/{r}(.git)?/info/refs?service=git-upload-pack|git-receive-pack
       git smart-HTTP advertisement served from <remote-root>/{o}/{r}.git
       (client Git-Protocol header is passed through, so v0 and v2 both work)
- POST /{o}/{r}(.git)?/git-upload-pack    git smart-HTTP RPC (read side)
- POST /{o}/{r}(.git)?/git-receive-pack   git smart-HTTP RPC (write side; NO
       gate here — receive-pack is always accepted for a bare repo that exists)
- GET  /user                              REST user payload (default login
       "fake-user"; override with <state>/user.json)
- GET  /repos/{o}/{r}                     REST repo payload carrying
       permissions{pull,push}; override with <state>/repos.json
- POST /{o}/{r}/info/lfs/objects/batch    LFS batch (basic transfer)
- GET/PUT /objects/<oid>                  LFS object blob endpoints
Unknown paths 404; known paths with the wrong method 405.

REQUEST RECORDING (requests.jsonl — one JSON object per line)
{"seq": 1, "method": "GET", "path": "/acme/demo.git/info/refs",
 "query": "service=git-upload-pack",
 "transfer_encoding": null | "<raw header>",
 "content_length": null | "<raw header>",
 "authorization_present": false | true,
 "request_bytes": 0, "response_status": 200, "response_bytes": 158,
 "duration_ms": 4.2, "injected": null | "slow" | "drop" | "oversized",
 "error": null | "<message>"}
request_bytes is the decoded body byte count (chunked bodies are decoded),
response_bytes the response body byte count. Authorization VALUES are never
recorded — only whether the header was present.

FAILURE INJECTION
<state>/control.json is re-read per request and overrides MSW_FAKE_GITHUB_MODE:
{"mode": "normal"|"drop"|"slow"|"oversized",
 "slow_seconds": 5.0, "oversized_bytes": 16777216,
 "match": {"path": "/acme/demo.git/info/refs", "method": "GET"},
 "once": true}
- slow:      sleep slow_seconds before processing (upstream stall — the
             proxy's MSW_PROXY_IDLE_TIMEOUT fires while the fake is stalled)
- drop:      close the connection with RST and no response (upstream teardown)
- oversized: stream oversized_bytes with Content-Length larger than the
             proxy's MSW_PROXY_MAX_BODY_BYTES so the proxy aborts mid-stream
             (the fake's record is persisted before streaming with the
             declared byte count; the abort is observed on the proxy side)
- once:      apply to the first matching request, then reset to normal
"match" restricts injection to requests whose path starts with path and/or
whose method equals method.

RUNNING
python3 tests/fake_github.py [--serve] [--port N] [--state DIR]
                             [--remote-root DIR] [--mode MODE]
Prints "FAKE_GITHUB_READY port=<n> state=<dir>" once listening, then serves
until SIGINT/SIGTERM (clean shutdown, exit 0). Stdlib-only and
MSW_TEST_MODE-independent: runs under plain python3 with no third-party
packages. TestEnv.start_fake_github() in tests/test_suite.py launches it as a
subprocess with MSW_FAKE_GITHUB_PORT=0 and reads the ready line.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, unquote, urlsplit

GIT_TIMEOUT = 300
MAX_BODY_BYTES = 1024 * 1024 * 1024  # 1 GiB fixture cap for request bodies
DEFAULT_OVERSIZED_BYTES = 16 * 1024 * 1024
_VALID_OID = re.compile(r"[0-9a-f]{64}")
GIT_SERVICES = ("git-upload-pack", "git-receive-pack")


def _pkt_line(data: bytes) -> bytes:
    """Encode data as one git pkt-line (4-hex length + payload, no padding)."""
    return f"{len(data) + 4:04x}".encode("ascii") + data


def _parse_mode(value: str) -> dict[str, Any]:
    """Parse MSW_FAKE_GITHUB_MODE into a control-style dict."""
    if value in ("", "normal"):
        return {"mode": "normal"}
    if value == "drop":
        return {"mode": "drop"}
    if value == "oversized":
        return {"mode": "oversized", "oversized_bytes": DEFAULT_OVERSIZED_BYTES}
    if value.startswith("slow="):
        try:
            seconds = float(value.split("=", 1)[1])
        except ValueError:
            raise SystemExit(f"invalid MSW_FAKE_GITHUB_MODE slow value: {value}")
        if seconds < 0:
            raise SystemExit(f"invalid MSW_FAKE_GITHUB_MODE slow value: {value}")
        return {"mode": "slow", "slow_seconds": seconds}
    raise SystemExit(f"unknown MSW_FAKE_GITHUB_MODE: {value}")


class _State:
    """Mutable per-server state shared by all request-handler threads."""

    def __init__(self, state_dir: Path, remote_root: Path, env_mode: dict[str, Any], git_bin: str) -> None:
        self.state_dir = state_dir
        self.remote_root = remote_root
        self.env_mode = env_mode
        self.git_bin = git_bin
        self.lock = threading.Lock()
        self.seq = 0
        self.requests_path = state_dir / "requests.jsonl"
        self.control_path = state_dir / "control.json"
        self.repos_path = state_dir / "repos.json"
        self.user_path = state_dir / "user.json"
        self.objects_dir = state_dir / "lfs-objects"
        state_dir.mkdir(parents=True, exist_ok=True)

    def record(self, entry: dict[str, Any]) -> None:
        with self.lock:
            with self.requests_path.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(entry, sort_keys=True) + "\n")

    def next_seq(self) -> int:
        with self.lock:
            self.seq += 1
            return self.seq

    def control(self) -> dict[str, Any]:
        if self.control_path.exists():
            try:
                return json.loads(self.control_path.read_text())
            except (OSError, ValueError):
                return {}
        return {}

    def write_control(self, control: dict[str, Any]) -> None:
        tmp = self.control_path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(control, sort_keys=True))
        tmp.replace(self.control_path)

    def repos(self) -> dict[str, Any]:
        if self.repos_path.exists():
            try:
                return json.loads(self.repos_path.read_text())
            except (OSError, ValueError):
                return {}
        return {}

    def user_repos(self) -> list[dict[str, Any]]:
        path = self.state_dir / "user-repos.json"
        if path.exists():
            try:
                value = json.loads(path.read_text())
                if isinstance(value, list):
                    return value
            except (OSError, ValueError):
                pass
        return []

    def orgs(self) -> list[dict[str, Any]]:
        path = self.state_dir / "orgs.json"
        if path.exists():
            try:
                value = json.loads(path.read_text())
                if isinstance(value, list):
                    return value
            except (OSError, ValueError):
                pass
        return []

    def org_repos(self, org: str) -> list[dict[str, Any]]:
        path = self.state_dir / "org-repos.json"
        if path.exists():
            try:
                value = json.loads(path.read_text())
                if isinstance(value, dict):
                    return value.get(org, []) or []
            except (OSError, ValueError):
                pass
        return []

    def device_record(self) -> dict[str, Any]:
        path = self.state_dir / "device.json"
        if path.exists():
            try:
                value = json.loads(path.read_text())
                if isinstance(value, dict):
                    return value
            except (OSError, ValueError):
                pass
        return {}

    def write_device_record(self, record: dict[str, Any]) -> None:
        tmp = self.state_dir / "device.json.tmp"
        tmp.write_text(json.dumps(record, sort_keys=True))
        tmp.replace(self.state_dir / "device.json")

    def user(self) -> dict[str, Any]:
        if self.user_path.exists():
            try:
                value = json.loads(self.user_path.read_text())
                if isinstance(value, dict):
                    return value
            except (OSError, ValueError):
                pass
        return {"login": "fake-user", "id": 1, "name": "Fake User", "type": "User"}


def _failure_mode(state: _State, method: str, path: str) -> dict[str, Any] | None:
    """Resolve failure injection for one request, or None for normal handling."""
    ctrl = state.control()
    mode = ctrl.get("mode") or state.env_mode.get("mode")
    if mode in (None, "normal"):
        return None
    match = ctrl.get("match") or {}
    if match.get("path") and not path.startswith(match["path"]):
        return None
    if match.get("method") and method != match["method"]:
        return None
    if ctrl.get("once"):
        reset = dict(ctrl)
        reset["mode"] = "normal"
        state.write_control(reset)
    return {
        "mode": mode,
        "slow_seconds": float(ctrl.get("slow_seconds", state.env_mode.get("slow_seconds", 5.0))),
        "oversized_bytes": int(ctrl.get("oversized_bytes", state.env_mode.get("oversized_bytes", DEFAULT_OVERSIZED_BYTES))),
    }


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "FakeGitHub"
    sys_version = ""

    state: _State
    _recorded = False
    _request_started = 0.0

    def log_message(self, fmt: str, *args: Any) -> None:
        pass

    def _record_entry(self, record: dict[str, Any]) -> None:
        """Persist the request record exactly once, before the response goes out."""
        if self._recorded:
            return
        self._recorded = True
        record["duration_ms"] = round((time.monotonic() - self._request_started) * 1000, 1)
        try:
            self.state.record(record)
        except OSError:
            pass

    # ---- response helpers (each persists the record before writing) ----

    def _send_bytes(self, record: dict[str, Any], status: int, body: bytes, content_type: str) -> None:
        record["response_status"] = status
        record["response_bytes"] = len(body)
        self._record_entry(record)
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_json(self, record: dict[str, Any], status: int, payload: Any) -> None:
        body = json.dumps(payload).encode("utf-8")
        self._send_bytes(record, status, body, "application/json; charset=utf-8")

    def _method_not_allowed(self, record: dict[str, Any], allow: str) -> None:
        body = json.dumps({"message": "method not allowed"}).encode("utf-8")
        record["response_status"] = 405
        record["response_bytes"] = len(body)
        self._record_entry(record)
        self.send_response(405, "Method Not Allowed")
        self.send_header("Allow", allow)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _drop_connection(self) -> None:
        self.close_connection = True
        try:
            self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        except OSError:
            pass

    def _stream_oversized(self, record: dict[str, Any], total: int) -> None:
        # Persisted up front with the declared byte count; the pacing below
        # lets the proxy observe the running total and abort mid-stream.
        record["response_status"] = 200
        record["response_bytes"] = total
        self._record_entry(record)
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(total))
        self.end_headers()
        chunk = b"x" * (64 * 1024)
        sent = 0
        while sent < total:
            piece = chunk if total - sent >= len(chunk) else chunk[: total - sent]
            self.wfile.write(piece)
            self.wfile.flush()
            sent += len(piece)
            time.sleep(0.005)

    # ---- request body plumbing ----

    def _read_body(self) -> bytes:
        te = self.headers.get("Transfer-Encoding")
        cl = self.headers.get("Content-Length")
        if te is not None:
            if cl is not None:
                raise ValueError("Transfer-Encoding and Content-Length are mutually exclusive")
            if te.lower() != "chunked":
                raise ValueError(f"unsupported Transfer-Encoding: {te}")
            return self._read_chunked_body()
        if cl is not None:
            try:
                length = int(cl)
            except ValueError:
                raise ValueError(f"invalid Content-Length: {cl!r}")
            if not 0 <= length <= MAX_BODY_BYTES:
                raise ValueError(f"Content-Length out of range: {cl!r}")
            return self.rfile.read(length)
        return b""

    def _read_chunked_body(self) -> bytes:
        chunks = bytearray()
        while True:
            line = self.rfile.readline(64 * 1024)
            if not line:
                raise ValueError("truncated chunked body")
            size_part = line.split(b";", 1)[0].strip()
            try:
                size = int(size_part, 16)
            except ValueError:
                raise ValueError(f"invalid chunk size: {size_part!r}")
            if size < 0 or len(chunks) + size > MAX_BODY_BYTES:
                raise ValueError("chunked body too large")
            if size == 0:
                while True:
                    trailer = self.rfile.readline(64 * 1024)
                    if trailer in (b"", b"\n", b"\r\n"):
                        break
                break
            chunks += self.rfile.read(size)
            if self.rfile.read(2) != b"\r\n":
                raise ValueError("chunk data not terminated by CRLF")
        return bytes(chunks)

    # ---- routing helpers ----

    def _repo_dir(self, owner: str, repo: str) -> Path | None:
        name = repo[:-4] if repo.endswith(".git") else repo
        if "/" in owner or "/" in name or owner in ("", ".", "..") or name in ("", ".", ".."):
            return None
        candidates = (
            self.state.remote_root / owner.lower() / f"{name.lower()}.git",
            self.state.remote_root / owner / f"{name}.git",
        )
        try:
            root = self.state.remote_root.resolve()
        except OSError:
            root = self.state.remote_root
        for candidate in candidates:
            try:
                resolved = candidate.resolve()
            except OSError:
                continue
            if root in resolved.parents and resolved.is_dir():
                return resolved
        return None

    def _repo_meta(self, owner: str, repo: str) -> dict[str, Any] | None:
        name = repo[:-4] if repo.endswith(".git") else repo
        meta = self.state.repos().get(f"{owner.lower()}/{name.lower()}")
        if meta is not None:
            if not isinstance(meta, dict) or meta.get("exists") is False:
                return None
            return meta
        if self._repo_dir(owner, repo) is not None:
            return {}
        return None

    def _service_from_query(self, query: str) -> str | None:
        services = parse_qs(query).get("service", [])
        if len(services) != 1 or services[0] not in GIT_SERVICES:
            return None
        return services[0]

    def _base_url(self) -> str:
        host = self.headers.get("Host", "")
        if host:
            return f"http://{host}"
        return f"http://127.0.0.1:{self.server.server_address[1]}"

    def _object_path(self, oid: str) -> Path:
        return self.state.objects_dir / oid[:2] / oid[2:4] / oid

    def _run_git(self, service: str, repo: Path, body: bytes | None, advertise: bool) -> tuple[int, bytes, bytes]:
        cmd = [self.state.git_bin, service, "--stateless-rpc"]
        if advertise:
            cmd.append("--advertise-refs")
        cmd.append(str(repo))
        env = os.environ.copy()
        env.update(
            {
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "LC_ALL": "C",
            }
        )
        protocol = self.headers.get("Git-Protocol", "").strip()
        if protocol:
            env["GIT_PROTOCOL"] = protocol
        try:
            proc = subprocess.run(
                cmd,
                input=body,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env,
                timeout=GIT_TIMEOUT,
            )
        except subprocess.TimeoutExpired:
            return 1, b"", b"git rpc timed out"
        return proc.returncode, proc.stdout, proc.stderr

    # ---- endpoint handlers ----

    def _serve_user(self, record: dict[str, Any]) -> None:
        self._send_json(record, 200, self.state.user())

    def _paginate(self, items: list[dict[str, Any]], query: str) -> list[dict[str, Any]]:
        params = parse_qs(query)
        try:
            per_page = int(params.get("per_page", ["100"])[0])
        except ValueError:
            per_page = 100
        try:
            page = int(params.get("page", ["1"])[0])
        except ValueError:
            page = 1
        if per_page <= 0:
            per_page = 100
        if page <= 0:
            page = 1
        start = (page - 1) * per_page
        return items[start : start + per_page]

    def _serve_user_repos(self, record: dict[str, Any], query: str) -> None:
        self._send_json(record, 200, self._paginate(self.state.user_repos(), query))

    def _serve_user_orgs(self, record: dict[str, Any]) -> None:
        self._send_json(record, 200, self.state.orgs())

    def _serve_org_repos(self, record: dict[str, Any], org: str, query: str) -> None:
        self._send_json(record, 200, self._paginate(self.state.org_repos(org), query))

    def _form_params(self) -> dict[str, list[str]]:
        try:
            body = self._read_body()
        except ValueError as exc:
            raise ValueError(f"invalid form body: {exc}")
        try:
            return parse_qs(body.decode("utf-8"))
        except UnicodeDecodeError:
            return {}

    def _serve_device_code(self, record: dict[str, Any]) -> None:
        # Device Flow start: reuse the fixture's device record (deterministic
        # for tests) or mint one; always reset to pending.
        existing = self.state.device_record()
        if existing.get("device_code"):
            record_entry = existing
        else:
            record_entry = {
                "device_code": f"dev-{record['seq']}",
                "user_code": "ABCD-EFGH",
                "verification_uri": "https://github.com/login/device",
                "expires_in": 900,
                "interval": 5,
                "status": "pending",
                "access_token": "",
            }
        record_entry["status"] = "pending"
        self.state.write_device_record(record_entry)
        self._send_json(record, 200, {
            "device_code": record_entry["device_code"],
            "user_code": record_entry["user_code"],
            "verification_uri": record_entry["verification_uri"],
            "expires_in": record_entry.get("expires_in", 900),
            "interval": record_entry.get("interval", 5),
        })

    def _serve_device_token(self, record: dict[str, Any]) -> None:
        params = self._form_params()
        device_code = (params.get("device_code") or [""])[0]
        state = self.state.device_record()
        if not device_code or state.get("device_code") != device_code:
            return self._send_json(record, 200, {"error": "access_denied"})
        if state.get("status") == "ready":
            token = state.get("access_token") or "gho_ready_token_abcdefghijklmnopqrstuvwxyz0123456789"
            return self._send_json(record, 200, {"access_token": token, "token_type": "bearer", "scope": "repo"})
        return self._send_json(record, 200, {"error": "authorization_pending", "error_description": "authorization pending"})

    def _serve_repo(self, record: dict[str, Any], owner: str, repo: str) -> None:
        meta = self._repo_meta(owner, repo)
        if meta is None:
            return self._send_json(record, 404, {"message": "Not Found"})
        name = repo[:-4] if repo.endswith(".git") else repo
        full_name = f"{owner.lower()}/{name.lower()}"
        payload = {
            "id": meta.get("id", 1),
            "name": name,
            "full_name": full_name,
            "private": bool(meta.get("private", False)),
            "default_branch": meta.get("default_branch", "main"),
            "permissions": {
                "pull": bool(meta.get("permissions", {}).get("pull", True)),
                "push": bool(meta.get("permissions", {}).get("push", True)),
            },
            "owner": {"login": owner.lower()},
            "html_url": f"https://github.com/{full_name}",
        }
        self._send_json(record, 200, payload)

    def _serve_advertisement(self, record: dict[str, Any], service: str, repo: Path) -> None:
        git_command = "upload-pack" if service == "git-upload-pack" else "receive-pack"
        rc, out, err = self._run_git(git_command, repo, body=None, advertise=True)
        if rc != 0:
            record["error"] = (err or b"").decode("utf-8", "replace")[:500] or f"git {service} failed"
            return self._send_json(record, 500, {"message": "git advertisement failed"})
        body = _pkt_line(f"# service={service}\n".encode()) + b"0000" + out
        self._send_bytes(record, 200, body, f"application/x-{service}-advertisement")

    def _serve_git_rpc(self, record: dict[str, Any], endpoint: str, repo: Path) -> None:
        body = self._read_body()
        record["request_bytes"] = len(body)
        service = "upload-pack" if endpoint == "git-upload-pack" else "receive-pack"
        rc, out, err = self._run_git(service, repo, body=body, advertise=False)
        if rc != 0:
            record["error"] = (err or b"").decode("utf-8", "replace")[:500] or f"git {service} failed"
            return self._send_json(record, 500, {"message": "git rpc failed"})
        self._send_bytes(record, 200, out, f"application/x-{endpoint}-result")

    def _serve_lfs_batch(self, record: dict[str, Any], owner: str, repo: str) -> None:
        body = self._read_body()
        record["request_bytes"] = len(body)
        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            return self._send_json(record, 400, {"message": "invalid LFS batch JSON"})
        if not isinstance(payload, dict):
            return self._send_json(record, 400, {"message": "invalid LFS batch payload"})
        operation = payload.get("operation")
        objects = payload.get("objects")
        if operation not in ("download", "upload") or not isinstance(objects, list):
            return self._send_json(record, 400, {"message": "invalid LFS batch operation"})
        base = self._base_url()
        expires = (datetime.now(timezone.utc) + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        entries: list[dict[str, Any]] = []
        for item in objects:
            if not isinstance(item, dict):
                continue
            oid = item.get("oid")
            size = item.get("size", 0)
            if not isinstance(oid, str) or not _VALID_OID.fullmatch(oid):
                entries.append({"oid": oid, "size": size, "error": {"code": 422, "message": "invalid oid"}})
                continue
            entry: dict[str, Any] = {"oid": oid, "size": size, "authenticated": True}
            obj_path = self._object_path(oid)
            if operation == "download":
                if obj_path.is_file():
                    entry["actions"] = {"download": {"href": f"{base}/objects/{oid}", "expires_at": expires}}
                else:
                    entry["error"] = {"code": 404, "message": "Object does not exist"}
            elif not obj_path.exists():
                entry["actions"] = {
                    "upload": {
                        "href": f"{base}/objects/{oid}",
                        "header": {"Content-Type": "application/octet-stream"},
                        "expires_at": expires,
                    }
                }
            entries.append(entry)
        self._send_bytes(record, 200, json.dumps({"transfer": "basic", "objects": entries}).encode("utf-8"),
                         "application/vnd.git-lfs+json")

    def _serve_object_get(self, record: dict[str, Any], oid: str) -> None:
        path = self._object_path(oid)
        if not path.is_file():
            return self._send_json(record, 404, {"message": "Object does not exist"})
        self._send_bytes(record, 200, path.read_bytes(), "application/octet-stream")

    def _serve_object_put(self, record: dict[str, Any], oid: str) -> None:
        body = self._read_body()
        record["request_bytes"] = len(body)
        digest = hashlib.sha256(body).hexdigest()
        if digest != oid:
            return self._send_json(record, 422, {"message": "SHA-256 mismatch", "expected": oid, "actual": digest})
        path = self._object_path(oid)
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_bytes(body)
        tmp.replace(path)
        self._send_bytes(record, 200, b"", "application/octet-stream")

    # ---- dispatcher ----

    def _dispatch(self, method: str) -> None:
        state = self.state
        split = urlsplit(self.path)
        raw_path = split.path
        query = split.query
        try:
            segments = [unquote(seg) for seg in raw_path.split("/") if seg != ""]
        except ValueError:
            segments = []
        record: dict[str, Any] = {
            "seq": state.next_seq(),
            "method": method,
            "path": raw_path,
            "query": query,
            "transfer_encoding": self.headers.get("Transfer-Encoding"),
            "content_length": self.headers.get("Content-Length"),
            "authorization_present": self.headers.get("Authorization") is not None,
            "request_bytes": 0,
            "response_status": None,
            "response_bytes": 0,
            "duration_ms": 0.0,
            "injected": None,
            "error": None,
        }
        self._request_started = time.monotonic()
        self._recorded = False
        try:
            for seg in segments:
                if seg in (".", "..") or "/" in seg:
                    return self._send_json(record, 404, {"message": "Not Found"})

            failure = _failure_mode(state, method, raw_path)
            if failure is not None:
                record["injected"] = failure["mode"]
                if failure["mode"] == "slow":
                    time.sleep(failure["slow_seconds"])
                elif failure["mode"] == "drop":
                    self._record_entry(record)
                    self._drop_connection()
                    return
                elif failure["mode"] == "oversized":
                    self._stream_oversized(record, failure["oversized_bytes"])
                    return

            if len(segments) == 1 and segments[0] == "user":
                if method != "GET":
                    return self._method_not_allowed(record, "GET")
                return self._serve_user(record)
            if len(segments) == 2 and segments[0] == "objects":
                oid = segments[1]
                if not _VALID_OID.fullmatch(oid):
                    return self._send_json(record, 400, {"message": "invalid oid"})
                if method == "GET":
                    return self._serve_object_get(record, oid)
                if method == "PUT":
                    return self._serve_object_put(record, oid)
                return self._method_not_allowed(record, "GET, PUT")
            if len(segments) == 3 and segments[0] == "repos":
                if method != "GET":
                    return self._method_not_allowed(record, "GET")
                return self._serve_repo(record, segments[1], segments[2])
            if len(segments) == 2 and segments[0] == "user" and segments[1] == "repos":
                if method != "GET":
                    return self._method_not_allowed(record, "GET")
                return self._serve_user_repos(record, query)
            if len(segments) == 2 and segments[0] == "user" and segments[1] == "orgs":
                if method != "GET":
                    return self._method_not_allowed(record, "GET")
                return self._serve_user_orgs(record)
            if len(segments) == 3 and segments[0] == "orgs" and segments[2] == "repos":
                if method != "GET":
                    return self._method_not_allowed(record, "GET")
                return self._serve_org_repos(record, segments[1], query)
            if len(segments) == 3 and segments[0] == "login" and segments[1] == "device" and segments[2] == "code":
                if method != "POST":
                    return self._method_not_allowed(record, "POST")
                return self._serve_device_code(record)
            if len(segments) == 3 and segments[0] == "login" and segments[1] == "oauth" and segments[2] == "access_token":
                if method != "POST":
                    return self._method_not_allowed(record, "POST")
                return self._serve_device_token(record)
            if len(segments) >= 3:
                owner, repo = segments[0], segments[1]
                if len(segments) == 6 and segments[2:6] == ["info", "lfs", "objects", "batch"]:
                    if method != "POST":
                        return self._method_not_allowed(record, "POST")
                    return self._serve_lfs_batch(record, owner, repo)
                repo_dir = self._repo_dir(owner, repo)
                if len(segments) == 4 and segments[2] == "info" and segments[3] == "refs":
                    if method != "GET":
                        return self._method_not_allowed(record, "GET")
                    if repo_dir is None:
                        return self._send_json(record, 404, {"message": "Not Found"})
                    service = self._service_from_query(query)
                    if service is None:
                        return self._send_json(record, 400, {"message": "service parameter required"})
                    return self._serve_advertisement(record, service, repo_dir)
                if len(segments) == 3 and segments[2] in GIT_SERVICES:
                    if method != "POST":
                        return self._method_not_allowed(record, "POST")
                    if repo_dir is None:
                        return self._send_json(record, 404, {"message": "Not Found"})
                    return self._serve_git_rpc(record, segments[2], repo_dir)
            return self._send_json(record, 404, {"message": "Not Found"})
        except ValueError as exc:
            record["error"] = str(exc)
            try:
                self._send_json(record, 400, {"message": str(exc)})
            except OSError:
                self._record_entry(record)
        except (BrokenPipeError, ConnectionResetError):
            record["error"] = "client disconnected"
            self._record_entry(record)
        except Exception as exc:  # noqa: BLE001 — the fixture records and keeps serving
            record["error"] = f"{type(exc).__name__}: {exc}"
            try:
                self._send_json(record, 500, {"message": "fake github error"})
            except OSError:
                self._record_entry(record)
        finally:
            self._record_entry(record)

    def do_GET(self) -> None:
        self._dispatch("GET")

    def do_POST(self) -> None:
        self._dispatch("POST")

    def do_PUT(self) -> None:
        self._dispatch("PUT")


def build_handler(state: _State) -> type[BaseHTTPRequestHandler]:
    class FakeGitHubHandler(_Handler):
        pass

    FakeGitHubHandler.state = state
    return FakeGitHubHandler


def serve(state_dir: Path, remote_root: Path, mode: dict[str, Any], port: int, git_bin: str) -> int:
    state = _State(state_dir, remote_root, mode, git_bin)
    httpd = ThreadingHTTPServer(("127.0.0.1", port), build_handler(state))
    httpd.daemon_threads = True
    actual_port = httpd.server_address[1]
    print(f"FAKE_GITHUB_READY port={actual_port} state={state_dir}", flush=True)

    def _stop(signum: int, frame: Any) -> None:
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, _stop)
    try:
        httpd.serve_forever(poll_interval=0.25)
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        httpd.server_close()
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Stateful fake GitHub server (MSW Path C test fixture).")
    parser.add_argument("--serve", action="store_true", help="serve (default action; accepted for symmetry with the test harness)")
    parser.add_argument("--port", type=int, default=int(os.environ.get("MSW_FAKE_GITHUB_PORT", "0")))
    parser.add_argument("--state", default=os.environ.get("MSW_FAKE_GITHUB_STATE", ""))
    parser.add_argument("--remote-root", default="")
    parser.add_argument("--mode", default=os.environ.get("MSW_FAKE_GITHUB_MODE", "normal"))
    args = parser.parse_args(argv)

    state_dir = Path(args.state or "/tmp/msw-fake-github-state").resolve()
    remote_root = Path(
        args.remote_root
        or os.environ.get("MSW_FAKE_GITHUB_REMOTE_ROOT")
        or os.environ.get("MSW_TEST_GITHUB_REMOTE_ROOT")
        or (state_dir / "remotes")
    ).resolve()
    git_bin = shutil.which("git") or "/usr/bin/git"
    return serve(state_dir, remote_root, _parse_mode(args.mode), args.port, git_bin)


if __name__ == "__main__":
    raise SystemExit(main())
