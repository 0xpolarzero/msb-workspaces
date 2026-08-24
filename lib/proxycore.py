#!/usr/bin/python3
"""MSW GitHub proxy core -- the per-connection "checker" (Path C contract section 4).

Per-connection process: launchd spawns one instance per accepted socket on
127.0.0.1:18446 (inetdCompatibility Wait:true); the socket is stdin/stdout.
Manual stdin/stdout invocation (used by tests via socketpair) works the same;
`--listen [PORT]` adds a test-only accept/fork loop that prints
`PROXY_READY port=<n>` (binds 127.0.0.1, port 0 = ephemeral).

Ingress parsing is done EXCLUSIVELY by the vendored h11 tree at
lib/vendor/h11 (sys.path insertion; site-packages is never consulted). The
vendored __version__ floor (>= 0.16.0, CVE-2025-43859) is enforced at start.
No stdlib http.server and no hand-rolled HTTP parsing anywhere on the ingress
side. All section-4 transport rules are enforced pre-auth: HTTP/1.1 only, one
request per connection then `Connection: close`, origin-form targets, exact
Host match, header allowlist (names ^[A-Za-z0-9-]+$, values 0x20-0x7E + HTAB,
<=64 headers, <=8KiB/value, <=16KiB block including trailers), exactly one
Content-Length OR `Transfer-Encoding: chunked` as the sole coding (CL+TE,
duplicate CL, stacked/unknown TE rejected), no bodies on GET/HEAD/DELETE/
OPTIONS, running body cap, idle + total timeouts.

Body handling is stream-then-forward (section 4: stream socket-to-socket,
never buffer): after policy approval the upstream request is opened and
h11-decoded body chunks are forwarded as they arrive (Content-Length
passthrough when the ingress had Content-Length; chunked re-encoded as
chunked; a Content-Length is never synthesized). Each chunk is held in a
small bounded confirmation window (at most one chunk, capped at 1 MiB) until
h11 validates the next event, so a malformed body (e.g. the CVE-2025-43859
malformed post-chunk-CRLF class) aborts before its bytes are sent and the
upstream is never contacted at all for a malformed first chunk (REGRESS-1:
never contacts upstream). On cap exceeded, timeout, malformed frame, or
client disconnect mid-stream the upstream request is aborted so a partial
body never appears complete. The ONLY buffered body is the LFS batch JSON,
bounded in memory (8 MiB) for the operation parse and href rewriting.

Identity is the X-MSW-Capability header, matched constant-time against
the policy file (re-read per request/process). The policy is a CREDENTIAL
GRANT table, never a reachability gate: a missing or malformed policy, an
absent or unknown capability, an ungranted repository, or a read-only
workspace attempting a write all mean "forward anonymously WITHOUT the host
credential" -- GitHub decides whether the request succeeds. The host token
is loaded and injected ONLY for a valid workspace+repo+operation grant, and
an unavailable token degrades to anonymous forwarding so public access
keeps working. The endpoint table, LFS URL stamping (HMAC), and
canonicalization rules are in this module; the outbound TLS/socket leg is
lib/proxy-upstream.py.

HMAC stamp key: random 32 bytes per deployment, hex, persisted mode 0600 in
<policy dir>/github-proxy-hmac.key (MSW_PROXY_HMAC_KEY_FILE seam), created
atomically with O_EXCL. NOTE FOR PHASE 2 REVIEW: key-rotation/expiry policy
for this file is owned by the phase-2 credential/migration work; the key is
only ever used to stamp/verify LFS object URLs, never to sign anything else.

One structured, single-line, REDACTED JSON record per request goes to
MSW_PROXY_LOG_FILE. Capability and token values are never logged; the LFS
stamp signature query value is redacted.

Env seams (all optional; defaults noted): MSW_POLICY_FILE,
MSW_PROXY_HMAC_KEY_FILE, MSW_PROXY_LOG_FILE, MSW_PROXY_UPSTREAM_ROOT,
MSW_PROXY_OBJECTS_UPSTREAM_ROOT, MSW_PROXY_BASE_URL, MSW_GITHUB_PROXY_PORT,
MSW_PROXY_MAX_BODY_BYTES, MSW_PROXY_IDLE_TIMEOUT, MSW_PROXY_TOTAL_DEADLINE,
MSW_PROXY_STAMP_TTL, MSW_HOST_KEYCHAIN_SERVICE, MSW_HOST_KEYCHAIN_ACCOUNT,
MSW_TEST_KEYCHAIN_DIR.
"""
from __future__ import annotations

import base64
import datetime
import hashlib
import hmac
import importlib.util
import json
import os
import re
import select
import shutil
import signal
import socket
import stat
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

VENDOR_H11_FLOOR = (0, 16, 0)
VENDOR_H11_FLOOR_TEXT = "0.16.0"


def _bootstrap() -> None:
    lib_dir = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, lib_dir)
    sys.path.insert(0, os.path.join(lib_dir, "vendor"))
    return lib_dir


_LIB_DIR = _bootstrap()

import h11  # noqa: E402  (vendored tree, verified below)


def _verify_vendored_h11() -> None:
    try:
        version = tuple(int(part) for part in h11.__version__.split("."))
    except (AttributeError, ValueError):
        version = (0, 0, 0)
    if version < VENDOR_H11_FLOOR:
        sys.stderr.write(
            f"msw-github-proxy: vendored h11 {h11.__version__} is below the hard "
            f"floor {VENDOR_H11_FLOOR_TEXT} (CVE-2025-43859 / GHSA-vqfr-h8mv-ghfj); "
            "refusing to start (fail-closed)\n"
        )
        raise SystemExit(1)


_verify_vendored_h11()


def _load_proxy_upstream(lib_dir: str) -> Any:
    """Load lib/proxy-upstream.py (hyphenated filename per the file plan)."""
    path = os.path.join(lib_dir, "proxy-upstream.py")
    spec = importlib.util.spec_from_file_location("proxy_upstream", path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"msw-github-proxy: cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["proxy_upstream"] = module
    spec.loader.exec_module(module)
    return module


proxy_upstream = _load_proxy_upstream(_LIB_DIR)  # noqa: E402

# ---------------------------------------------------------------------------
# Constants (section 4 ingress rules)
# ---------------------------------------------------------------------------

H11_HEADER_BLOCK_LIMIT = 16 * 1024  # request line + headers (h11 max event)
MAX_HEADER_COUNT = 64
MAX_HEADER_VALUE_BYTES = 8 * 1024
COVERED_HOSTS = ("github.com", "objects.githubusercontent.com")
GIT_SERVICES = ("git-upload-pack", "git-receive-pack")
ALLOWED_METHODS = (b"GET", b"POST", b"PUT")
NO_BODY_METHODS = (b"GET", b"HEAD", b"DELETE", b"OPTIONS")
REDIRECT_STATUSES = (301, 302, 303, 307, 308)
LFS_CONTENT_TYPE = "application/vnd.git-lfs+json"
# The ONLY buffered body is the LFS batch JSON (section 4); bounded in memory.
LFS_MEMORY_LIMIT = 8 * 1024 * 1024
# Streaming confirmation window: at most one h11-decoded chunk is held until
# its terminator is validated by the next event. Large chunks stream their
# excess immediately so the window stays bounded.
CHUNK_CONFIRM_LIMIT = 1024 * 1024
DEFAULT_PORT = 18446
DEFAULT_BODY_CAP = 8 * 1024 * 1024 * 1024  # 8 GiB
HOST_TOKEN_PREFIXES = ("gho_", "ghp_", "github_pat_", "ghu_")

_HEADER_NAME_RE = re.compile(r"[A-Za-z0-9-]+")
_REPO_SEG_RE = re.compile(r"[a-z0-9._-]+", re.IGNORECASE)
_OID_RE = re.compile(r"[0-9a-f]{64}")
_ISO_STAMP_RE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")

# LFS stamp version byte + nonce length + MAC length (encrypt-then-MAC blob).
STAMP_VERSION = 1
STAMP_NONCE_LEN = 12
STAMP_MAC_LEN = 32


def stamp_encode(key: bytes, payload: bytes) -> str:
    """AEAD-encode the LFS stamp payload with the deployment key.

    Encrypt-then-MAC: the keystream is HMAC-SHA256(key, nonce || u32be(counter)
    || b"lfs-ctr") in counter mode (a PRF-in-CTR stream cipher, equivalent to
    CTR-mode AES); the tag is HMAC-SHA256(key, nonce || ciphertext || b"lfs-mac").
    stdlib has no AES, so a PRF-based stream cipher is used; the wire format
    carries a version byte so phase 2 may swap in AES-GCM (libsodium or
    cryptography) without changing the URL shape. The VM sees only the base64
    blob -- never the plaintext href or its credential headers.
    """
    nonce = os.urandom(STAMP_NONCE_LEN)
    ciphertext = _ctr_xor(key, nonce, payload)
    mac = hmac.new(key, nonce + ciphertext + b"lfs-mac", hashlib.sha256).digest()
    return base64.urlsafe_b64encode(
        bytes([STAMP_VERSION]) + nonce + ciphertext + mac
    ).decode("ascii")


def stamp_decode(key: bytes, blob: str) -> Optional[bytes]:
    """Decode and authenticate an LFS stamp blob; None on any failure."""
    try:
        raw = base64.urlsafe_b64decode(blob.encode("ascii") + b"=" * (-len(blob) % 4))
    except (ValueError, UnicodeEncodeError):
        return None
    if len(raw) < 1 + STAMP_NONCE_LEN + STAMP_MAC_LEN:
        return None
    if raw[0] != STAMP_VERSION:
        return None
    nonce = raw[1:1 + STAMP_NONCE_LEN]
    ciphertext = raw[1 + STAMP_NONCE_LEN:-STAMP_MAC_LEN]
    mac = raw[-STAMP_MAC_LEN:]
    expected = hmac.new(key, nonce + ciphertext + b"lfs-mac", hashlib.sha256).digest()
    if not hmac.compare_digest(mac, expected):
        return None
    return _ctr_xor(key, nonce, ciphertext)


def _ctr_xor(key: bytes, nonce: bytes, data: bytes) -> bytes:
    out = bytearray()
    counter = 0
    while len(out) < len(data):
        block = hmac.new(key, nonce + counter.to_bytes(4, "big") + b"lfs-ctr", hashlib.sha256).digest()
        out += block
        counter += 1
    return bytes(b ^ k for b, k in zip(data, out))


def _pkt(data: bytes) -> bytes:
    """Encode `data` as one git pkt-line (4-hex length + payload)."""
    return f"{len(data) + 4:04x}".encode("ascii") + data


def _git_service_from_target(target: str) -> Optional[str]:
    """Infer the git smart-HTTP service from a request target (for denials
    raised before classification, e.g. identity/policy)."""
    split = urllib.parse.urlsplit(target)
    path = split.path
    if path.endswith("/info/refs"):
        service = urllib.parse.parse_qs(split.query).get("service", [None])[0]
        return service if service in GIT_SERVICES else None
    for name in GIT_SERVICES:
        if path.endswith("/" + name):
            return name
    return None

# Hop-by-hop + identity headers stripped on the OUTBOUND leg (framing headers
# and Host are re-added by the caller). BYTES: header names from h11 are bytes.
# Every standard credential-bearing REQUEST header is stripped too, so a guest
# Cookie/Authorization can never authenticate GitHub outside the host grant
# decision -- the only credential that may ride an outbound request is the host
# token, re-added below strictly under a live grant.
_STRIP_OUTBOUND = frozenset({
    b"connection",
    b"keep-alive",
    b"proxy-authenticate",
    b"proxy-authorization",
    b"proxy-connection",
    b"te",
    b"trailer",
    b"transfer-encoding",
    b"upgrade",
    b"expect",
    b"host",
    b"authorization",
    b"cookie",
    b"x-msw-capability",
})


# ---------------------------------------------------------------------------
# Exceptions
# ---------------------------------------------------------------------------


class ProxyError(Exception):
    """Reject the request with `status` and a redacted reason (fail-closed)."""

    def __init__(self, status: int, reason: str, category: str = "denied") -> None:
        super().__init__(reason)
        self.status = status
        self.reason = reason
        self.category = category


class AbortError(Exception):
    """Tear both legs down WITHOUT sending a response (cap/timeout/disconnect)."""


class ClientGone(AbortError):
    pass


class ResponseTooLarge(AbortError):
    pass


class UpstreamTruncated(AbortError):
    pass


# ---------------------------------------------------------------------------
# Config / seams
# ---------------------------------------------------------------------------


def _default_policy_path() -> str:
    return os.path.join(
        os.path.expanduser("~"), "Library", "Application Support", "MSW Monitor", "github-policy.json"
    )


def _default_workspace_path() -> str:
    return os.path.join(os.path.expanduser("~"), ".config", "msw", "workspaces.json")


class Config:
    def __init__(self) -> None:
        self.policy_file = Path(os.environ.get("MSW_POLICY_FILE", _default_policy_path()))
        self.workspace_file = Path(os.environ.get("MSW_WORKSPACES_FILE", _default_workspace_path()))
        policy_dir = self.policy_file.parent
        self.hmac_key_file = Path(
            os.environ.get("MSW_PROXY_HMAC_KEY_FILE", str(policy_dir / "github-proxy-hmac.key"))
        )
        log = os.environ.get("MSW_PROXY_LOG_FILE")
        self.log_file = str(log) if log else str(policy_dir / "github-proxy.log")

        self.github_upstream_root = os.environ.get("MSW_PROXY_UPSTREAM_ROOT", "https://github.com")
        if os.environ.get("MSW_PROXY_OBJECTS_UPSTREAM_ROOT"):
            self.objects_upstream_root = os.environ["MSW_PROXY_OBJECTS_UPSTREAM_ROOT"]
        elif os.environ.get("MSW_PROXY_UPSTREAM_ROOT"):
            # Test seam: the fake fixture serves both hosts from one root.
            self.objects_upstream_root = self.github_upstream_root
        else:
            self.objects_upstream_root = "https://objects.githubusercontent.com"

        port = os.environ.get("MSW_GITHUB_PROXY_PORT", str(DEFAULT_PORT))
        base = os.environ.get("MSW_PROXY_BASE_URL", f"http://127.0.0.1:{port}")
        self.base_url = base.rstrip("/")
        split = urllib.parse.urlsplit(self.base_url)
        self.expected_host = split.netloc or f"127.0.0.1:{port}"

        self.max_body_bytes = int(os.environ.get("MSW_PROXY_MAX_BODY_BYTES", str(DEFAULT_BODY_CAP)))
        self.idle_timeout = float(os.environ.get("MSW_PROXY_IDLE_TIMEOUT", "60"))
        self.total_deadline = float(os.environ.get("MSW_PROXY_TOTAL_DEADLINE", "3600"))
        self.stamp_ttl = int(os.environ.get("MSW_PROXY_STAMP_TTL", "3600"))

        self.keychain_service = os.environ.get(
            "MSW_HOST_KEYCHAIN_SERVICE", "org.microsandbox.MSWMonitor.github-host.v2"
        )
        self.keychain_account = os.environ.get("MSW_HOST_KEYCHAIN_ACCOUNT", "user")
        td = os.environ.get("MSW_TEST_KEYCHAIN_DIR")
        self.test_keychain_dir = Path(td) if td else None

        self.hmac_key = _load_or_create_hmac_key(self.hmac_key_file)
        self.github_upstream_host = urllib.parse.urlsplit(self.github_upstream_root).hostname
        self.objects_upstream_host = urllib.parse.urlsplit(self.objects_upstream_root).hostname


def _load_or_create_hmac_key(path: Path) -> bytes:
    """Load the deployment HMAC key, creating it atomically (0600) if absent.

    Random 32 bytes per deployment, hex-encoded, mode 0600, stored beside the
    policy file. O_EXCL create with a re-read on race, so concurrent first
    starts agree on one key. A present-but-invalid file is fail-closed
    (refuse to start) -- never silently regenerate a corrupted key.
    """
    try:
        key = _parse_key_file(path)
        if key is not None:
            return key
    except OSError:
        pass
    try:
        fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        key = _parse_key_file(path)
        if key is None:
            sys.stderr.write(
                f"msw-github-proxy: HMAC key file {path} is invalid; refusing to start (fail-closed)\n"
            )
            raise SystemExit(1)
        return key
    except OSError as exc:
        sys.stderr.write(f"msw-github-proxy: cannot create HMAC key file {path}: {exc}\n")
        raise SystemExit(1)
    key = os.urandom(32)
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(key.hex() + "\n")
        os.chmod(str(path), 0o600)
    except OSError as exc:
        sys.stderr.write(f"msw-github-proxy: cannot write HMAC key file {path}: {exc}\n")
        raise SystemExit(1)
    return key


def _parse_key_file(path: Path) -> Optional[bytes]:
    try:
        raw = path.read_bytes().strip()
        key = bytes.fromhex(raw.decode("ascii"))
    except (OSError, ValueError, UnicodeDecodeError):
        return None
    if len(key) >= 16:
        return key
    return None


# ---------------------------------------------------------------------------
# Policy (section 2; credential grants, never a reachability gate)
# ---------------------------------------------------------------------------


def _valid_canonical(repo: str) -> bool:
    if not isinstance(repo, str) or repo.count("/") != 1:
        return False
    owner, name = repo.split("/", 1)
    return bool(_REPO_SEG_RE.fullmatch(owner) and _REPO_SEG_RE.fullmatch(name))


WORKSPACE_KEYS = {
    "name", "cpu", "cpuCeiling", "memoryGiB", "memoryCeilingGiB",
    "workspaceStorageGiB", "runtimeStorageGiB",
}
# EXACT canonical repo grammar (host parity): owner/name, each segment starts
# with [a-z0-9] then [a-z0-9._-]*; lowercase only, no IGNORECASE.
POLICY_REPO_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*$")


def _is_schema_one(value: Any) -> bool:
    """Match jq's JSON numeric equality: accept 1 and 1.0, reject booleans."""
    return not isinstance(value, bool) and isinstance(value, (int, float)) and value == 1


def _supported_number(value: Any, allowed: Tuple[int, ...]) -> bool:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    if isinstance(value, float) and not value.is_integer():
        return False
    return value in allowed


def _load_configured_workspaces(cfg: Config) -> Optional[Tuple[str, ...]]:
    """Load the same schema-v1 workspace list as the CLI; malformed input denies all."""
    try:
        metadata = cfg.workspace_file.lstat()
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 262144:
            return None
        data = json.loads(cfg.workspace_file.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (OSError, UnicodeDecodeError, ValueError):
        return None
    if (not isinstance(data, dict)
            or set(data) != {"schemaVersion", "workspaces"}
            or not _is_schema_one(data.get("schemaVersion"))):
        return None
    workspaces = data.get("workspaces")
    if not isinstance(workspaces, list) or not 1 <= len(workspaces) <= 64:
        return None
    names: List[str] = []
    for workspace in workspaces:
        if not isinstance(workspace, dict) or set(workspace) != WORKSPACE_KEYS:
            return None
        name = workspace.get("name")
        if not isinstance(name, str) or re.fullmatch(r"[a-z][a-z0-9-]{0,31}", name) is None:
            return None
        cpu = workspace.get("cpu")
        cpu_ceiling = workspace.get("cpuCeiling")
        memory = workspace.get("memoryGiB")
        memory_ceiling = workspace.get("memoryCeilingGiB")
        if not (
            _supported_number(cpu, (4, 6, 8, 12))
            and _supported_number(cpu_ceiling, (4, 6, 8, 12))
            and cpu <= cpu_ceiling
            and _supported_number(memory, (16, 32, 48))
            and _supported_number(memory_ceiling, (16, 32, 48))
            and memory <= memory_ceiling
            and _supported_number(workspace.get("workspaceStorageGiB"), (60, 80, 100, 120))
            and _supported_number(workspace.get("runtimeStorageGiB"), (60, 80, 100, 120))
        ):
            return None
        names.append(name)
    if len(set(names)) != len(names):
        return None
    return tuple(names)

def _load_policy(cfg: Config) -> Optional[Dict[str, Any]]:
    """Load and STRICTLY validate the policy file (section 2; fail-closed).

    Mirrors the host's strict validator exactly: schemaVersion must be JSON
    numeric 1 (1 or 1.0; booleans rejected); workspace keys may only name
    configured workspaces (absent workspaces are simply denied); capability
    must be exactly lowercase [0-9a-f]{48} and unique across workspaces; repo
    canonicals must match EXACTLY `^[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*$`
    (already-lowercase, leading [a-z0-9] only, no .git suffix, no query or
    fragment; uppercase is rejected, never silently lowercased); modes only
    read-only/read-write; duplicate canonical entries and any shape deviation
    (workspaces not an object, repos not a list, entries not objects,
    non-string fields) reject the WHOLE policy so NO workspace can hold a
    grant: every valid request is then forwarded anonymously and GitHub
    decides (never a local denial for valid Git traffic).
    """
    try:
        raw = cfg.policy_file.read_bytes()
    except OSError:
        return None
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    if not _is_schema_one(data.get("schemaVersion")):
        return None
    workspaces = data.get("workspaces")
    if not isinstance(workspaces, dict):
        return None
    configured_workspaces = _load_configured_workspaces(cfg)
    if configured_workspaces is None:
        return None
    if any(key not in configured_workspaces for key in workspaces):
        return None
    out: Dict[str, Any] = {}
    seen_capabilities: set = set()
    for box in configured_workspaces:
        if box not in workspaces:
            continue  # absent workspace: no grant possible (anonymous)
        workspace = workspaces[box]
        if not isinstance(workspace, dict):
            return None
        capability = workspace.get("capability")
        if not isinstance(capability, str) or not re.fullmatch(r"[0-9a-f]{48}", capability):
            return None  # exactly lowercase hex, 48 chars
        if capability in seen_capabilities:
            return None  # capabilities must be unique across workspaces
        seen_capabilities.add(capability)
        repos = workspace.get("repos")
        if not isinstance(repos, list):
            return None
        entries: List[Tuple[str, str]] = []
        seen_repos: set = set()
        for item in repos:
            if not isinstance(item, dict):
                return None
            canon = item.get("canonical")
            mode = item.get("mode")
            if not isinstance(canon, str) or not isinstance(mode, str):
                return None
            if mode not in ("read-only", "read-write"):
                return None
            # Canonical repo id: EXACT grammar, already lowercase, no .git /
            # query / fragment (reject, never silently canonicalize).
            if canon != canon.lower():
                return None
            if "?" in canon or "#" in canon or not POLICY_REPO_RE.fullmatch(canon):
                return None
            if canon.endswith(".git"):
                return None
            if canon in seen_repos:
                return None  # duplicate canonical entries rejected
            seen_repos.add(canon)
            entries.append((canon, mode))
        out[box] = {"capability": capability, "repos": entries}
    return out


# ---------------------------------------------------------------------------
# Host credential (section 5; delivered by bin/msw-github-host-token over a pipe)
# ---------------------------------------------------------------------------


def _load_host_token(cfg: Config) -> Optional[str]:
    """Read the host credential by spawning bin/msw-github-host-token (§4/§5).

    The helper is fail-closed: it prints the raw accessToken to stdout and
    exits 0; on a missing/invalid record or a rejected token kind (ghs_/ghr_)
    it prints NOTHING and exits 1. The token is captured over a pipe
    (stdout=PIPE) and never appears in argv, env, or logs. Empty stdout or a
    nonzero exit is treated as unavailable, so the caller degrades to
    anonymous forwarding (never a local denial) -- objects requests never
    need a token (the signed URL is the auth). MSW_HOST_TOKEN_BIN is the
    test/install seam; fallbacks are the repo copy and the setup.sh install
    location.
    """
    candidates = [
        os.environ.get("MSW_HOST_TOKEN_BIN"),
        os.path.join(_LIB_DIR, "..", "bin", "msw-github-host-token"),
        os.path.expanduser("~/.local/libexec/msw-github-host-token"),
    ]
    helper = next((c for c in candidates if c and os.path.isfile(c)), None)
    if helper is None:
        return None
    env = {
        "MSW_HOST_KEYCHAIN_SERVICE": cfg.keychain_service,
        "MSW_HOST_KEYCHAIN_ACCOUNT": cfg.keychain_account,
        "MSW_TEST_KEYCHAIN_DIR": str(cfg.test_keychain_dir) if cfg.test_keychain_dir else "",
        "MSW_SECURITY_BIN": os.environ.get("MSW_SECURITY_BIN", "/usr/bin/security"),
        "MSW_JQ_BIN": os.environ.get("MSW_JQ_BIN") or shutil.which("jq") or "",
        "MSW_HOST_KEYCHAIN_HOME": os.environ.get("MSW_HOST_KEYCHAIN_HOME", ""),
        "MSW_HOST_META_FILE": os.environ.get("MSW_HOST_META_FILE", ""),
        "MSW_KEYCHAIN_BRIDGE": os.environ.get("MSW_KEYCHAIN_BRIDGE", ""),
        "MSW_FAKE_BRIDGE_HANG": os.environ.get("MSW_FAKE_BRIDGE_HANG", ""),
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": os.environ.get("HOME", ""),
    }
    # Never export an empty timeout: the bridge parses it eagerly and an empty
    # value would turn the production default into an immediate config error.
    keychain_timeout = os.environ.get("MSW_KEYCHAIN_TIMEOUT_SECS", "")
    if keychain_timeout:
        env["MSW_KEYCHAIN_TIMEOUT_SECS"] = keychain_timeout
    # Staggered watchdog stack. The helper may perform TWO bridge reads
    # (deny item, then activation record), each bounded by its own outer
    # deadline. The proxy deadline is clamped above both complete helper
    # deadlines so it can never pre-empt the helper while it is killing the
    # second bridge/worker process group.
    helper_timeout_raw = os.environ.get("MSW_HOST_TOKEN_TIMEOUT_SECS") or "15"
    helper_timeout = max(1.0, float(helper_timeout_raw))
    env["MSW_HOST_TOKEN_TIMEOUT_SECS"] = str(helper_timeout)
    requested_timeout = float(os.environ.get("MSW_HOST_TOKEN_TIMEOUT") or "40")
    timeout = max(requested_timeout, (2.0 * helper_timeout) + 5.0)
    try:
        proc = subprocess.Popen(
            [helper], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env,
            start_new_session=True,
        )
    except OSError:
        return None
    try:
        stdout, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            try:
                proc.kill()
            except OSError:
                pass
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        return None
    token = stdout.decode("utf-8", "replace").strip()
    if proc.returncode != 0 or not token:
        return None
    if not token.startswith(HOST_TOKEN_PREFIXES):
        return None  # defense in depth; the helper already rejects ghs_/ghr_
    return token


# ---------------------------------------------------------------------------
# Endpoint classifier + stamping (section 4 table)
# ---------------------------------------------------------------------------


class Decision:
    __slots__ = ("host", "kind", "repo", "op", "oid", "service", "href", "headers", "authenticated", "stamp_op")

    def __init__(
        self,
        host: str,
        kind: str,
        repo: str,
        op: Optional[str],
        oid: Optional[str] = None,
        service: Optional[str] = None,
        href: Optional[str] = None,
        headers: Optional[Dict[str, str]] = None,
        authenticated: bool = False,
        stamp_op: Optional[str] = None,
    ) -> None:
        self.host = host
        self.kind = kind  # "git" | "lfs-batch" | "objects"
        self.repo = repo
        self.op = op  # "read" | "write" | None (lfs-batch until body parsed)
        self.oid = oid
        self.service = service
        self.href = href  # objects leg: the REAL href, decrypted host-side
        self.headers = headers  # objects leg: the REAL action headers, host-side only
        # objects leg only: True when the stamp was minted under a grant (it
        # carries host-derived credentials and MUST re-check the grant here)
        self.authenticated = authenticated
        # objects leg only: the stamp's raw operation ("download"|"upload"),
        # preserved so a resealed redirect keeps the same provenance.
        self.stamp_op = stamp_op


def _canonical_repo(owner: str, repo: str) -> str:
    """Canonical repo id: lowercase owner/name, no .git (section 2)."""
    name = repo[:-4] if repo.endswith(".git") else repo
    if not _REPO_SEG_RE.fullmatch(owner) or not _REPO_SEG_RE.fullmatch(name):
        raise ProxyError(403, "invalid repository path", category="canonicalization")
    return f"{owner.lower()}/{name.lower()}"


def _service_param(query: str) -> str:
    # Strict request shape: exactly ONE service parameter and no other query
    # keys. An extra query parameter (e.g. an embedded access_token) could
    # otherwise authenticate the request outside the host grant decision, so
    # it is rejected locally as a shape violation and never forwarded.
    # keep_blank_values=True so a bare `&x` (no '=') still counts as a key.
    params = urllib.parse.parse_qs(query, keep_blank_values=True)
    services = params.get("service", [])
    if set(params) != {"service"} or len(services) != 1 or services[0] not in GIT_SERVICES:
        raise ProxyError(
            403, "info/refs requires exactly one service=git-upload-pack|git-receive-pack "
            "and no other query parameters",
            category="denied",
        )
    return services[0]


class Classifier:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg

    def classify(self, method: bytes, target: bytes) -> Decision:
        text = target.decode("latin-1")
        split = urllib.parse.urlsplit(text)
        path = split.path
        query = split.query
        raw_segs = path.split("/")
        # raw_segs[0] is "" (leading slash). Any other empty segment is a
        # canonicalization attack (double slash / trailing slash).
        if any(seg == "" for seg in raw_segs[1:]):
            raise ProxyError(403, "empty path segment", category="canonicalization")
        segs = raw_segs[1:]
        if not segs:
            raise ProxyError(403, "empty request path", category="canonicalization")
        host = segs[0]
        if host not in COVERED_HOSTS:
            raise ProxyError(
                403, f"host {host!r} is not a covered GitHub host (only github.com and "
                "objects.githubusercontent.com are proxied)", category="denied",
            )
        if host == "github.com":
            return self._classify_github(method, segs[1:], query)
        return self._classify_objects(method, segs[1:], query)

    def _classify_github(self, method: bytes, segs: List[str], query: str) -> Decision:
        # GET /{o}/{r}(.git)?/info/refs?service=git-upload-pack|git-receive-pack
        if len(segs) == 4 and segs[2] == "info" and segs[3] == "refs":
            if method != b"GET":
                raise ProxyError(405, "info/refs requires GET", category="denied")
            service = _service_param(query)
            repo = _canonical_repo(segs[0], segs[1])
            return Decision(
                "github.com", "git", repo,
                "read" if service == "git-upload-pack" else "write",
                service=service,
            )
        # POST /{o}/{r}(.git)?/git-upload-pack | /git-receive-pack
        if len(segs) == 3 and segs[2] in GIT_SERVICES:
            if method != b"POST":
                raise ProxyError(405, f"{segs[2]} requires POST", category="denied")
            if query:
                # Query parameters could carry credentials that authenticate
                # outside the grant decision: refuse the shape, never forward.
                raise ProxyError(
                    403, f"{segs[2]} accepts no query parameters", category="denied",
                )
            repo = _canonical_repo(segs[0], segs[1])
            return Decision(
                "github.com", "git", repo,
                "read" if segs[2] == "git-upload-pack" else "write",
                service=segs[2],
            )
        # POST /{o}/{r}(.git)?/info/lfs/objects/batch (Content-Type vnd.git-lfs+json)
        if len(segs) == 6 and segs[2:6] == ["info", "lfs", "objects", "batch"]:
            if method != b"POST":
                raise ProxyError(405, "LFS batch requires POST", category="denied")
            if query:
                raise ProxyError(
                    403, "LFS batch accepts no query parameters", category="denied",
                )
            repo = _canonical_repo(segs[0], segs[1])
            return Decision("github.com", "lfs-batch", repo, None)
        raise ProxyError(
            403, "endpoint is not in the proxy allowlist (git smart-HTTP and LFS batch only)",
            category="denied",
        )

    def _classify_objects(self, method: bytes, segs: List[str], query: str) -> Decision:
        if len(segs) != 2 or segs[0] != "objects" or not _OID_RE.fullmatch(segs[1]):
            raise ProxyError(
                403, "objects host only serves /objects/<sha256> with a proxy stamp",
                category="denied",
            )
        if method not in (b"GET", b"PUT"):
            raise ProxyError(405, "objects endpoints require GET or PUT", category="denied")
        repo, op, href, headers, authenticated = self._validate_stamp(query, segs[1], method)
        # The stamp operation is download/upload, validated as such (method
        # match + payload cross-check) inside _validate_stamp; the grant
        # engine speaks read/write. Normalize BEFORE the grant decision so a
        # read-only repo's stamped GET is authorized as read (contract §4:
        # GET=download(read), PUT=upload(write)).
        policy_op = "read" if op == "download" else "write"
        return Decision("objects.githubusercontent.com", "objects", repo, policy_op,
                        oid=segs[1], href=href, headers=headers, authenticated=authenticated,
                        stamp_op=op)

    def _validate_stamp(
        self, query: str, oid: str, method: bytes
    ) -> Tuple[str, str, str, Dict[str, str], bool]:
        """Validate the self-carrying LFS stamp (section 4).

        Visible params: _msw_repo, _msw_op, _msw_exp; _msw_sig is the AEAD
        blob (stamp_encode) carrying the REAL href, the action's credential
        headers, op, repo, expiry and whether the batch was authenticated --
        decrypted host-side only, TTL enforced here. GET must carry
        op=download, PUT op=upload. Returns (repo, op, real_href,
        real_headers, authenticated); the caller forwards to the real href
        and re-attaches the real headers -- the VM never sees either.
        Authenticated stamps (minted under a grant) re-check the CURRENT
        policy on this leg so a revoked grant cannot keep using them.
        """
        params = urllib.parse.parse_qs(query)
        try:
            repo = params["_msw_repo"][0]
            op = params["_msw_op"][0]
            exp = params["_msw_exp"][0]
            sig = params["_msw_sig"][0]
        except (KeyError, IndexError):
            raise ProxyError(
                403, "missing LFS stamp parameters (_msw_repo/_msw_op/_msw_exp/_msw_sig); "
                "unstamped object URLs are denied", category="denied",
            )
        if op not in ("download", "upload"):
            raise ProxyError(403, "invalid LFS stamp operation", category="denied")
        if (op == "download" and method != b"GET") or (op == "upload" and method != b"PUT"):
            raise ProxyError(
                403, "LFS stamp operation does not match the request method", category="denied",
            )
        if not _valid_canonical(repo):
            raise ProxyError(403, "invalid repository in LFS stamp", category="denied")
        if not _ISO_STAMP_RE.fullmatch(exp):
            raise ProxyError(403, "invalid LFS stamp expiry format", category="denied")
        try:
            exp_dt = datetime.datetime.strptime(exp, "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=datetime.timezone.utc
            )
        except ValueError:
            raise ProxyError(403, "invalid LFS stamp expiry", category="denied")
        if exp_dt <= datetime.datetime.now(datetime.timezone.utc):
            raise ProxyError(403, "LFS stamp expired", category="denied")

        raw = stamp_decode(self.cfg.hmac_key, sig)
        if raw is None:
            raise ProxyError(403, "invalid LFS stamp signature", category="denied")
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise ProxyError(403, "invalid LFS stamp payload", category="denied")
        if not isinstance(data, dict):
            raise ProxyError(403, "invalid LFS stamp payload", category="denied")
        # The blob is MAC'd as a unit; cross-check its fields against the
        # visible params so a URL/param substitution cannot reclassify it.
        if data.get("op") != op or data.get("repo") != repo or data.get("exp") != exp:
            raise ProxyError(403, "LFS stamp fields do not match the request", category="denied")
        href = data.get("href")
        headers = data.get("headers")
        if not isinstance(href, str) or not isinstance(headers, dict):
            raise ProxyError(403, "invalid LFS stamp payload", category="denied")
        href_split = urllib.parse.urlsplit(href)
        if href_split.scheme not in ("http", "https") or not href_split.hostname:
            raise ProxyError(403, "invalid LFS stamp href", category="denied")
        if not href_split.path.startswith("/objects/"):
            raise ProxyError(403, "invalid LFS stamp href path", category="denied")
        href_oid = href_split.path[len("/objects/"):]
        if href_oid != oid or not _OID_RE.fullmatch(href_oid):
            raise ProxyError(403, "LFS stamp href oid mismatch", category="denied")
        clean_headers: Dict[str, str] = {}
        for name, value in headers.items():
            if not isinstance(name, str) or not isinstance(value, str):
                raise ProxyError(403, "invalid LFS stamp headers", category="denied")
            if _HEADER_NAME_RE.fullmatch(name) and len(value) <= MAX_HEADER_VALUE_BYTES:
                clean_headers[name] = value
        # `auth` is set host-side only when the batch was forwarded WITH the
        # host token; anonymous batches mint stamps with `auth: false`. A
        # stamp WITHOUT the flag predates this change and was necessarily
        # minted under a grant (the old proxy never forwarded a batch without
        # the host token), so it is treated as authenticated -- fail-closed,
        # so a legacy stamp cannot outlive a grant revocation.
        return repo, op, href, clean_headers, bool(data.get("auth", True))


# ---------------------------------------------------------------------------
# Request context / handler
# ---------------------------------------------------------------------------


class RequestContext:
    def __init__(self, cfg: Config, fd_in: int, fd_out: int) -> None:
        self.cfg = cfg
        self.fd_in = fd_in
        self.fd_out = fd_out
        self.conn = h11.Connection(h11.SERVER, max_incomplete_event_size=H11_HEADER_BLOCK_LIMIT)
        self.start = time.monotonic()
        self.classifier = Classifier(cfg)
        self.log_fh: Optional[Any] = None
        self.policy: Optional[Dict[str, Any]] = None
        self.box: Optional[str] = None
        self.covered_host: Optional[str] = None
        self.repo: Optional[str] = None
        self.op: Optional[str] = None
        self.method: Optional[str] = None
        self.target: Optional[str] = None
        self.in_bytes = 0
        self.out_bytes = 0
        self.error: Optional[str] = None
        self.pipelined = False
        self.framing = "none"
        self.cl_value: Optional[int] = None
        self.upstream: Optional[proxy_upstream.Upstream] = None
        self.presented_capability: Optional[str] = None
        self.host_token: Optional[str] = None
        # Non-None only when the current workspace/repo/operation has a live
        # policy grant (the repo's "read-only" | "read-write" mode); None
        # means forward anonymously.
        self.grant: Optional[str] = None
        self.batch_failed = False
        self.git_service: Optional[str] = None
        self._head_buf = bytearray()
        self._head_scanned = False

    # ---- low-level fd I/O -------------------------------------------------

    def _wait_readable(self) -> None:
        elapsed = time.monotonic() - self.start
        remaining = self.cfg.total_deadline - elapsed
        if remaining <= 0:
            raise AbortError()
        ready, _, _ = select.select([self.fd_in], [], [], min(self.cfg.idle_timeout, remaining))
        if not ready:
            if time.monotonic() - self.start >= self.cfg.total_deadline:
                self.error = "total deadline exceeded"
            else:
                self.error = "idle timeout"
            raise AbortError()

    def _flush(self, data: bytes) -> None:
        if not data:
            return
        view = memoryview(data)
        while len(view):
            try:
                n = os.write(self.fd_out, view)
            except OSError as exc:
                raise ClientGone() from exc
            if n == 0:
                raise ClientGone()
            view = view[n:]

    def _next_event(self) -> Any:
        while True:
            try:
                event = self.conn.next_event()
            except h11.RemoteProtocolError as exc:
                raise ProxyError(400, self._sanitize(str(exc)), category="ingress") from exc
            if event is not h11.NEED_DATA:
                return event
            self._wait_readable()
            data = os.read(self.fd_in, 65536)
            if not data:
                self.conn.receive_data(b"")
            else:
                self._scan_raw_head(data)
                self.conn.receive_data(data)

    def _scan_raw_head(self, data: bytes) -> None:
        """Count duplicate Content-Length / Transfer-Encoding header LINES.

        h11 coalesces identical duplicate Content-Length values while parsing
        (only one survives in the parsed header list), so the contract's
        "duplicate CL (identical or conflicting) => reject" and "stacked TE"
        rules (section 4; INGRESS-4 / SMUGGLE) cannot be enforced from the
        parsed headers alone. This is a targeted line count over the raw
        header block BEFORE h11 parses it -- h11 remains the parser and the
        authority on syntax/framing; this only detects line multiplicity and
        comma-valued Content-Length lines.
        """
        if self._head_scanned:
            return
        self._head_buf += data
        idx = self._head_buf.find(b"\r\n\r\n")
        if idx == -1:
            if len(self._head_buf) > H11_HEADER_BLOCK_LIMIT + 4:
                self._head_buf = bytearray()  # h11 rejects oversized heads
            return
        self._head_scanned = True
        head = bytes(self._head_buf[:idx])
        self._head_buf = bytearray()
        lines = head.split(b"\r\n")
        if lines:
            lines = lines[1:]  # first line is the request line
        cl_count = 0
        te_count = 0
        for line in lines:
            if not line or line[:1] in (b" ", b"\t"):
                continue  # obs-fold continuation, not a new header
            name, sep, value = line.partition(b":")
            if not sep:
                continue
            lname = name.strip().lower()
            if lname == b"content-length":
                cl_count += 1
                if b"," in value:
                    raise ProxyError(400, "duplicate Content-Length values", category="ingress")
            elif lname == b"transfer-encoding":
                te_count += 1
        if cl_count > 1:
            raise ProxyError(400, "duplicate Content-Length", category="ingress")
        if te_count > 1:
            raise ProxyError(400, "stacked Transfer-Encoding", category="ingress")

    def _sanitize(self, text: str) -> str:
        for secret in (self.presented_capability, self.host_token):
            if secret:
                text = text.replace(secret, "<redacted>")
        return text

    # ---- ingress: request head ---------------------------------------------

    def receive_request(self) -> h11.Request:
        while True:
            event = self._next_event()
            if isinstance(event, h11.Request):
                self.method = event.method.decode("latin-1")
                self.target = event.target.decode("latin-1")
                self.validate_request(event)
                return event
            if isinstance(event, h11.ConnectionClosed):
                raise ClientGone()
            raise ProxyError(400, "unexpected protocol event", category="ingress")

    def validate_request(self, request: h11.Request) -> None:
        if request.http_version != b"1.1":
            raise ProxyError(400, "HTTP/1.1 is required", category="ingress")
        if request.method == b"CONNECT":
            raise ProxyError(405, "CONNECT is not supported by the proxy", category="denied")
        if request.method not in ALLOWED_METHODS:
            raise ProxyError(
                405, f"method {request.method.decode('latin-1')} is not supported",
                category="denied",
            )
        target = request.target
        if not target.startswith(b"/") or target.startswith(b"//"):
            raise ProxyError(400, "request-target must be origin-form", category="ingress")
        if b"://" in target:
            raise ProxyError(400, "absolute-form request-target is not allowed", category="ingress")

        raw = request.headers.raw_items()
        if len(raw) > MAX_HEADER_COUNT:
            raise ProxyError(400, "too many headers (max 64)", category="ingress")
        for rname, value in raw:
            try:
                rname_str = rname.decode("ascii")
            except UnicodeDecodeError:
                rname_str = ""
            if not _HEADER_NAME_RE.fullmatch(rname_str):
                raise ProxyError(400, "header name outside the allowlist", category="ingress")
            if len(value) > MAX_HEADER_VALUE_BYTES:
                raise ProxyError(400, "header value exceeds 8KiB", category="ingress")
            for byte in value:
                if byte != 0x09 and not (0x20 <= byte <= 0x7E):
                    raise ProxyError(
                        400, "header value contains disallowed bytes", category="ingress",
                    )

        names = [name.lower() for name, _ in raw]
        cl_count = names.count(b"content-length")
        te_count = names.count(b"transfer-encoding")
        if cl_count > 1:
            raise ProxyError(400, "duplicate Content-Length", category="ingress")
        if te_count > 1:
            raise ProxyError(400, "stacked Transfer-Encoding", category="ingress")
        if cl_count == 1 and te_count == 1:
            raise ProxyError(400, "both Content-Length and Transfer-Encoding", category="ingress")
        cl_values = [value for name, value in raw if name.lower() == b"content-length"]
        if cl_values and b"," in cl_values[0]:
            raise ProxyError(400, "duplicate Content-Length values", category="ingress")

        hosts = [value for name, value in raw if name.lower() == b"host"]
        if len(hosts) != 1 or hosts[0].decode("latin-1") != self.cfg.expected_host:
            raise ProxyError(
                400, "Host header must match the proxy base", category="ingress",
            )

        if te_count == 1:
            self.framing = "chunked"
            self.cl_value = None
        elif cl_count == 1:
            self.framing = "cl"
            self.cl_value = int(cl_values[0].decode("ascii"))
        else:
            self.framing = "none"
            self.cl_value = None
        if request.method in NO_BODY_METHODS and (
            self.framing == "chunked" or (self.framing == "cl" and self.cl_value not in (None, 0))
        ):
            raise ProxyError(400, "request body is not allowed on this method", category="ingress")

    # ---- identity / policy / endpoint ---------------------------------------

    def evaluate(self, request: h11.Request) -> Decision:
        # Policy is a CREDENTIAL-GRANT table, re-read per request. A missing
        # or malformed policy means NO workspace can hold a grant: every
        # valid request is forwarded anonymously and GitHub decides.
        self.policy = _load_policy(self.cfg)
        self.box = self._identify(request)
        decision = self.classifier.classify(request.method, request.target)
        self.covered_host = decision.host
        self.git_service = decision.service
        self.repo = decision.repo
        if decision.kind == "lfs-batch":
            # Section 4: batch is only a covered endpoint with the LFS
            # content type; anything else is denied (fail-closed).
            cts = [value for name, value in request.headers if name == b"content-type"]
            if len(cts) != 1 or cts[0].split(b";", 1)[0].strip().lower() != b"application/vnd.git-lfs+json":
                raise ProxyError(
                    403, "LFS batch requires Content-Type application/vnd.git-lfs+json",
                    category="denied",
                )
            return decision
        self.op = decision.op
        if decision.kind == "objects":
            if decision.authenticated:
                # A credential-carrying stamp was minted under a grant; it
                # must STILL be covered by a live grant or it is revoked
                # (immediate revocation safety). Anonymous stamps (public
                # LFS) need no grant -- GitHub decides.
                if self._credential_grant(self.box, decision.repo, decision.op) is None:
                    raise ProxyError(
                        403,
                        f"repository {decision.repo} is not granted for {decision.op} "
                        "in this workspace; the LFS credential was revoked",
                        category="policy",
                    )
        else:
            self.grant = self._credential_grant(self.box, decision.repo, decision.op)
        return decision

    def _identify(self, request: h11.Request) -> Optional[str]:
        """Map the capability header to a policy workspace, or None.

        None means "no grant possible": the header is absent, the policy is
        unloadable, or the capability is unknown. That is NEVER a local
        denial -- it only disables host-credential injection. More than one
        capability header is a request-shape violation and stays denied
        (ambiguous identity cannot authorize a grant).
        """
        caps = [value for name, value in request.headers if name == b"x-msw-capability"]
        if len(caps) > 1:
            raise ProxyError(
                403, "at most one X-MSW-Capability header is allowed", category="identity",
            )
        if caps:
            self.presented_capability = caps[0].decode("latin-1")
        if not caps or self.policy is None:
            return None
        for box, workspace in self.policy.items():
            if hmac.compare_digest(caps[0], workspace["capability"].encode("ascii")):
                return box
        return None

    def _credential_grant(self, box: Optional[str], repo: str, op: str) -> Optional[str]:
        """Return the grant mode that authorizes host-credential injection.

        None means "never inject the host credential; forward anonymously
        and let GitHub decide" -- for missing/malformed policy, absent or
        unknown capability, unlisted repositories, and read-only workspaces
        attempting writes. A read grant permits read (either mode); a write
        grant requires read-write mode. The returned value is the repo's
        grant mode ("read-only" | "read-write") or None.
        """
        if box is None or self.policy is None:
            return None
        workspace = self.policy.get(box)
        if workspace is None:
            return None
        for canon, mode in workspace["repos"]:
            if canon == repo:
                if op == "read" and mode in ("read-only", "read-write"):
                    return mode
                if op == "write" and mode == "read-write":
                    return mode
                return None
        return None

    # ---- ingress: body streaming (never buffered/spooled) -------------------

    def _client_expects_continue(self, request: h11.Request) -> bool:
        for name, value in request.headers:
            if name == b"expect" and value.lower() == b"100-continue":
                return True
        return False

    def _send_body_upstream(self, data: bytes) -> None:
        assert self.upstream is not None
        self.upstream.send_body(data, self.start, self.cfg.total_deadline)

    def _open_upstream(
        self,
        request: h11.Request,
        host_kind: str,
        framing: str,
        *,
        href: Optional[str] = None,
        href_headers: Optional[Dict[str, str]] = None,
    ) -> None:
        """Open the upstream request head.

        For the git leg the outbound target/headers derive from the ingress
        request. For the objects leg the REAL href and its credential headers
        come from the decrypted stamp (host-side only) -- everything incoming
        is stripped; only the framing headers are added.
        """
        if self.upstream is not None:
            return
        method = request.method.decode("latin-1")
        if href is not None:
            upstream = proxy_upstream.Upstream.from_href(href, self.cfg.idle_timeout)
            self.upstream = upstream
            split = urllib.parse.urlsplit(href)
            path = split.path or "/"
            if split.query:
                path += "?" + split.query
            headers: List[Tuple[str, str]] = []
            for name, value in (href_headers or {}).items():
                headers.append((name, value))
            headers.append(("Host", upstream.netloc))
            if framing == "cl":
                headers.append(("Content-Length", str(self.cl_value)))
            elif framing == "chunked":
                headers.append(("Transfer-Encoding", "chunked"))
        else:
            upstream = self._make_upstream(host_kind)
            headers = self._outbound_headers(request, host_kind, framing, upstream)
            path = self._upstream_path(request)
        upstream.connect()
        upstream.start_request(method, path, headers, framing, self.start, self.cfg.total_deadline)

    def _abort_upstream(self) -> None:
        if self.upstream is not None:
            self.upstream.close()
            self.upstream = None

    def stream_ingress_body(
        self, request: h11.Request, host_kind: str, decision: Optional[Decision] = None
    ) -> str:
        """Stream the h11-decoded request body upstream as it arrives.

        Section 4 requires socket-to-socket streaming with no buffering and no
        spooling, while REGRESS-1 (CVE-2025-43859) requires that a malformed
        chunked body never contacts upstream. Both hold because each chunk's
        bytes are held in a small bounded confirmation window (at most one
        chunk, capped at CHUNK_CONFIRM_LIMIT) and are forwarded only once h11
        has validated the NEXT event (a new chunk header, the end-of-message,
        or the terminating trailers) -- i.e. the current chunk's terminator
        parsed cleanly. A malformed terminator therefore aborts before any
        byte of the offending chunk is sent, and the upstream is never opened
        at all when the first chunk is malformed.

        On cap exceeded, malformed framing, timeout, or client disconnect
        mid-stream the upstream request is aborted (never completed), so a
        partial body can never appear complete at the upstream. Returns when
        the full body has been streamed; the caller then reads the response.
        """
        framing = self.framing
        if framing == "none":
            trailing, _ = self.conn.trailing_data
            if trailing:
                self.pipelined = True
            return framing
        if framing == "cl" and (self.cl_value or 0) > self.cfg.max_body_bytes:
            raise ProxyError(
                413, "request body exceeds MSW_PROXY_MAX_BODY_BYTES", category="cap",
            )
        if self._client_expects_continue(request):
            self._flush(self.conn.send(h11.InformationalResponse(status_code=100, headers=[])))
        href = decision.href if decision is not None else None
        href_headers = decision.headers if decision is not None else None

        def open_up() -> None:
            self._open_upstream(request, host_kind, framing, href=href, href_headers=href_headers)

        pending = bytearray()      # current chunk's bytes awaiting confirmation
        pending_confirmed = False  # a complete chunk is pending and validated
        body_done = False
        try:
            while not body_done:
                event = self._next_event()
                if isinstance(event, h11.Data):
                    self.in_bytes += len(event.data)
                    if self.in_bytes > self.cfg.max_body_bytes:
                        # Cap exceeded: abort the upstream (a partial body must
                        # never appear complete) and discard the pending chunk.
                        self._abort_upstream()
                        raise ProxyError(
                            413, "request body exceeds MSW_PROXY_MAX_BODY_BYTES (mid-stream)",
                            category="cap",
                        )
                    if framing == "chunked" and event.chunk_start and pending_confirmed:
                        # A new chunk header validated the previous chunk's
                        # terminator: forward it now.
                        open_up()
                        self._send_body_upstream(bytes(pending))
                        pending = bytearray()
                        pending_confirmed = False
                    pending += event.data
                    if framing == "chunked":
                        if event.chunk_end:
                            pending_confirmed = True
                    else:
                        # CL framing: a Data event is confirmed by the next
                        # event (or end-of-message); hold only the last slice.
                        if pending_confirmed:
                            open_up()
                            self._send_body_upstream(bytes(pending))
                            pending = bytearray()
                        pending_confirmed = True
                    if len(pending) > CHUNK_CONFIRM_LIMIT:
                        # Oversized chunk: stream the excess immediately (the
                        # confirmation window stays bounded); a huge single
                        # chunk cannot be held.
                        overflow = len(pending) - CHUNK_CONFIRM_LIMIT
                        open_up()
                        self._send_body_upstream(bytes(pending[:overflow]))
                        del pending[:overflow]
                elif isinstance(event, h11.EndOfMessage):
                    # The end-of-message (terminal chunk + trailers) validated
                    # everything up to here, so the held bytes are safe to send.
                    if pending:
                        open_up()
                        self._send_body_upstream(bytes(pending))
                    pending = bytearray()
                    body_done = True
                else:
                    raise ProxyError(400, "unexpected ingress body event", category="ingress")
            # Body complete and validated: finish the upstream framing.
            if self.upstream is not None:
                self.upstream.finish_body(self.start, self.cfg.total_deadline)
            trailing, _ = self.conn.trailing_data
            if trailing:
                self.pipelined = True
            return framing
        except (ProxyError, AbortError, ClientGone):
            self._abort_upstream()
            raise
        except proxy_upstream.UpstreamError:
            self._abort_upstream()
            raise
        except Exception:
            self._abort_upstream()
            raise

    # ---- response helpers -----------------------------------------------------

    def _send_head(self, status: int, headers: List[Tuple[str, str]], reason: Optional[str] = None) -> None:
        if reason:
            reason = "".join(ch for ch in reason if 0x20 <= ord(ch) <= 0x7E)
        # h11 requires a reason string (bytesify(None) raises); "" is legal.
        self._flush(
            self.conn.send(h11.Response(status_code=status, reason=reason or "", headers=headers))
        )

    def _respond_error(self, status: int, reason: str) -> None:
        self.error = self._sanitize(reason)
        if self.batch_failed:
            # LFS error shape so git-lfs surfaces the refusal message.
            body = json.dumps({"message": f"msw-proxy: {self.error}"}).encode("utf-8")
            content_type = "application/vnd.git-lfs+json"
        else:
            body = json.dumps({"error": f"msw-proxy: {self.error}"}).encode("utf-8")
            content_type = "application/json"
        try:
            self._send_head(status, [("Content-Type", content_type),
                                     ("Content-Length", str(len(body))),
                                     ("Connection", "close")])
            if body:
                self._flush(self.conn.send(h11.Data(data=body)))
            self._flush(self.conn.send(h11.EndOfMessage()))
            self.out_bytes += len(body)
        except ClientGone:
            pass

    def _respond_git_deny(self, service: str, reason: str) -> None:
        """Deny a git smart-HTTP request with an ERR pkt-line (HTTP 200).

        git's remote-curl surfaces an `ERR <msg>` pkt-line in the smart-HTTP
        advertisement/result as `fatal: remote error: <msg>` and NEVER enters
        the 401/403 credential-retry path (the response is 200, so no
        password prompt for x-access-token@ URLs). This is what makes a
        read-only push inside a VM fail cleanly with the actionable reason
        instead of prompting for a password.
        """
        self.error = self._sanitize(reason)
        body = _pkt(f"# service={service}\n".encode("ascii")) + b"0000" + _pkt(
            f"ERR {self.error}".encode("utf-8")
        )
        content_type = f"application/x-{service}-advertisement"
        try:
            self._send_head(200, [("Content-Type", content_type),
                                  ("Content-Length", str(len(body))),
                                  ("Connection", "close")])
            self._flush(self.conn.send(h11.Data(data=body)))
            self._flush(self.conn.send(h11.EndOfMessage()))
            self.out_bytes = len(body)
        except ClientGone:
            pass

    def _respond_redirect(self, status: int, location: str) -> None:
        body = b""
        self._send_head(status, [("Location", location), ("Content-Length", "0"),
                                 ("Connection", "close")])
        self._flush(self.conn.send(h11.EndOfMessage()))
        self.out_bytes = 0

    # ---- outbound --------------------------------------------------------------

    def _make_upstream(self, host_kind: str) -> proxy_upstream.Upstream:
        root = (
            self.cfg.objects_upstream_root if host_kind == "objects" else self.cfg.github_upstream_root
        )
        upstream = proxy_upstream.Upstream(root, self.cfg.idle_timeout)
        self.upstream = upstream
        return upstream

    def _upstream_path(self, request: h11.Request) -> str:
        text = request.target.decode("latin-1")
        split = urllib.parse.urlsplit(text)
        segs = split.path.split("/")
        path = "/" + "/".join(segs[2:])
        if split.query:
            path += "?" + split.query
        return path

    def _outbound_headers(
        self, request: h11.Request, host_kind: str, framing: str, upstream: proxy_upstream.Upstream
    ) -> List[Tuple[str, str]]:
        out: List[Tuple[str, str]] = []
        for name, value in request.headers.raw_items():
            if name.lower() in _STRIP_OUTBOUND:
                continue
            try:
                out.append((name.decode("ascii"), value.decode("latin-1")))
            except UnicodeDecodeError:
                raise ProxyError(400, "invalid outbound header", category="ingress") from None
        out.append(("Host", upstream.netloc))
        if framing == "cl":
            out.append(("Content-Length", str(self.cl_value)))
        elif framing == "chunked":
            out.append(("Transfer-Encoding", "chunked"))
        if host_kind == "github" and self.host_token:
            cred = base64.b64encode(
                b"x-access-token:" + self.host_token.encode("utf-8")
            ).decode("ascii")
            out.append(("Authorization", "Basic " + cred))
        return out

    def _forward_git(self, request: h11.Request, decision: Decision) -> int:
        host_kind = "github" if decision.host == "github.com" else "objects"
        if host_kind == "github":
            # The host credential is injected ONLY for a live grant; without
            # one (or when the token is unavailable) the request is forwarded
            # anonymously -- public access must never depend on the token.
            if self.grant:
                self.host_token = _load_host_token(self.cfg)
        # Stream the body upstream as it arrives (the upstream opens lazily
        # once the first chunk is confirmed, or here for bodyless requests).
        # The objects leg targets the REAL href decrypted from the stamp and
        # re-attaches its stored headers host-side only.
        self.stream_ingress_body(request, host_kind, decision)
        self._open_upstream(
            request, host_kind, self.framing,
            href=decision.href, href_headers=decision.headers,
        )
        assert self.upstream is not None
        status, reason, resp_headers = self.upstream.read_response_head(
            self.start, self.cfg.total_deadline
        )
        return self._forward_response(status, reason, resp_headers, decision)

    def _forward_response(self, status: int, reason: str, headers: List[Tuple[str, str]],
                          decision: Optional[Decision] = None) -> int:
        location = next((v for n, v in headers if n.lower() == "location"), None)
        if status in REDIRECT_STATUSES and location is not None:
            if decision is not None and decision.kind == "objects":
                # Objects-leg redirects are resealed into a fresh stamp (the
                # upstream Location carries the real signed URL; handing it
                # to the VM would leak the signature AND yield an unstamped
                # URL the classifier rejects on the second hop).
                rewritten = self._stamp_object_redirect(location, decision)
            else:
                rewritten = self._rewrite_location(location)
            if rewritten is None:
                raise ProxyError(
                    403, "redirect to a non-covered host is not allowed", category="redirect",
                )
            self._respond_redirect(status, rewritten)
            return status
        filtered = [
            (n, v.strip(" \t"))
            for n, v in headers
            if n.lower() not in proxy_upstream.HOP_BY_HOP
            and n.lower() not in ("content-length", "transfer-encoding")
        ]
        cl = next((v for n, v in headers if n.lower() == "content-length"), None)
        te = next((v for n, v in headers if n.lower() == "transfer-encoding"), None)
        if cl is not None:
            try:
                cl_n = int(cl)
            except ValueError:
                raise ProxyError(502, "invalid upstream Content-Length", category="upstream")
            if cl_n > self.cfg.max_body_bytes:
                raise ResponseTooLarge()
            self._send_head(status, filtered + [("Content-Length", cl), ("Connection", "close")], reason)
            self._stream_body_cl(cl_n)
        elif te is not None and te.strip().lower() == "chunked":
            self._send_head(
                status, filtered + [("Transfer-Encoding", "chunked"), ("Connection", "close")], reason
            )
            self._stream_body_chunked()
        else:
            self._send_head(status, filtered + [("Connection", "close")], reason)
            self._stream_body_eof()
        return status

    def _read_upstream_chunk(self, size: int) -> bytes:
        assert self.upstream is not None
        chunk = self.upstream.read_body(size, self.start, self.cfg.total_deadline)
        if not chunk:
            raise UpstreamTruncated()
        return chunk

    def _stream_body_cl(self, remaining: int) -> None:
        assert self.upstream is not None
        total_out = 0
        while remaining > 0:
            chunk = self._read_upstream_chunk(min(65536, remaining))
            total_out += len(chunk)
            remaining -= len(chunk)
            self._flush(self.conn.send(h11.Data(data=chunk)))
        self._flush(self.conn.send(h11.EndOfMessage()))
        self.out_bytes = total_out

    def _stream_body_chunked(self) -> None:
        assert self.upstream is not None
        total_out = 0
        while True:
            chunk = self.upstream.read_body(65536, self.start, self.cfg.total_deadline)
            if not chunk:
                break
            total_out += len(chunk)
            if total_out > self.cfg.max_body_bytes:
                raise ResponseTooLarge()
            self._flush(self.conn.send(h11.Data(data=chunk)))
        self._flush(self.conn.send(h11.EndOfMessage()))
        self.out_bytes = total_out

    def _stream_body_eof(self) -> None:
        assert self.upstream is not None
        total_out = 0
        while True:
            chunk = self.upstream.read_body(65536, self.start, self.cfg.total_deadline)
            if not chunk:
                break
            total_out += len(chunk)
            if total_out > self.cfg.max_body_bytes:
                raise ResponseTooLarge()
            self._flush(self.conn.send(h11.Data(data=chunk)))
        self._flush(self.conn.send(h11.EndOfMessage()))
        self.out_bytes = total_out

    # ---- redirect rewriting (no redirect following; section 4) ---------------

    def _rewrite_location(self, location: str) -> Optional[str]:
        """Rewrite a covered-host redirect to the proxy form; None => refuse.

        The rewritten host prefix is the redirect target's literal covered
        host when it is one (github.com / objects.githubusercontent.com),
        otherwise the host kind of the CURRENT request (the fake test
        upstream serves both covered hosts from one root, so the redirect
        host alone is ambiguous).
        """
        split = urllib.parse.urlsplit(location)
        if split.scheme and split.scheme not in ("http", "https"):
            return None
        if split.hostname is None:
            host_kind = self.covered_host or "github.com"
            path = location
        else:
            host = split.hostname
            if host in COVERED_HOSTS:
                host_kind = host
            elif host in (self.cfg.github_upstream_host, self.cfg.objects_upstream_host):
                host_kind = self.covered_host or "github.com"
            else:
                return None
            path = split.path or "/"
            if split.query:
                path += "?" + split.query
        if not path.startswith("/"):
            path = "/" + path
        return f"{self.cfg.base_url}/{host_kind}{path}"

    # ---- LFS batch (section 4: op from body; response stamped) ---------------

    def _read_bounded_ingress_body(self, request: h11.Request) -> bytes:
        """Buffer the LFS batch body in memory, bounded (section 4's ONLY
        buffered-body exception -- a few MiB; everything else streams)."""
        limit = min(LFS_MEMORY_LIMIT, self.cfg.max_body_bytes)
        if self.framing == "none":
            raise ProxyError(403, "LFS batch requires a request body", category="denied")
        if self.framing == "cl" and (self.cl_value or 0) > limit:
            raise ProxyError(413, "LFS batch body too large", category="cap")
        if self._client_expects_continue(request):
            self._flush(self.conn.send(h11.InformationalResponse(status_code=100, headers=[])))
        buf = bytearray()
        while True:
            event = self._next_event()
            if isinstance(event, h11.Data):
                buf += event.data
                if len(buf) > limit:
                    raise ProxyError(413, "LFS batch body too large", category="cap")
            elif isinstance(event, h11.EndOfMessage):
                break
            else:
                raise ProxyError(400, "unexpected ingress body event", category="ingress")
        self.in_bytes = len(buf)
        trailing, _ = self.conn.trailing_data
        if trailing:
            self.pipelined = True
        return bytes(buf)

    def _handle_lfs_batch(self, request: h11.Request, decision: Decision) -> int:
        body = self._read_bounded_ingress_body(request)
        try:
            data = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise ProxyError(403, "LFS batch body is not valid JSON", category="denied")
        if not isinstance(data, dict):
            raise ProxyError(403, "LFS batch body must be a JSON object", category="denied")
        operation = data.get("operation")
        if operation == "download":
            decision.op = "read"
        elif operation == "upload":
            decision.op = "write"
        else:
            raise ProxyError(
                403, "LFS batch requires operation=download|upload", category="denied",
            )
        self.op = decision.op
        # The batch is authenticated (host token injected upstream) ONLY under
        # a live grant with a usable token; otherwise it is forwarded
        # anonymously and GitHub decides whether the batch succeeds. Either
        # way the action headers are sealed into the stamps (they are
        # GitHub-issued, object-scoped temporaries -- for an anonymous batch
        # they are credentials GitHub granted to the anonymous requester, not
        # host secrets); `auth` records whether the batch rode the host
        # credential, which is what the objects leg re-checks.
        authenticated = False
        if self._credential_grant(self.box, decision.repo, decision.op) is not None:
            token = _load_host_token(self.cfg)
            if token is not None:
                self.host_token = token
                authenticated = True
        upstream = self._make_upstream("github")
        framing = self.framing  # CL passthrough or chunked re-encode, never synthesized
        headers = self._outbound_headers(request, "github", framing, upstream)
        upstream.connect()
        upstream.send_request(
            "POST", self._upstream_path(request), headers, body, framing,
            self.start, self.cfg.total_deadline,
        )
        status, reason, resp_headers = upstream.read_response_head(
            self.start, self.cfg.total_deadline
        )
        resp_body = self._read_bounded_response_body(upstream, resp_headers)
        try:
            rewritten = self._rewrite_batch_body(resp_body, decision.repo, authenticated)
        except ProxyError:
            self.batch_failed = True
            raise
        filtered = [
            (n, v.strip(" \t"))
            for n, v in resp_headers
            if n.lower() not in proxy_upstream.HOP_BY_HOP
            and n.lower() not in ("content-length", "transfer-encoding")
        ]
        self._send_head(
            status, filtered + [("Content-Length", str(len(rewritten))), ("Connection", "close")], reason
        )
        if rewritten:
            self._flush(self.conn.send(h11.Data(data=rewritten)))
        self._flush(self.conn.send(h11.EndOfMessage()))
        self.out_bytes = len(rewritten)
        return status

    def _read_bounded_response_body(
        self, upstream: proxy_upstream.Upstream, headers: List[Tuple[str, str]]
    ) -> bytes:
        cl = next((v for n, v in headers if n.lower() == "content-length"), None)
        te = next((v for n, v in headers if n.lower() == "transfer-encoding"), None)
        out = bytearray()
        if cl is not None:
            try:
                remaining = int(cl)
            except ValueError:
                raise ProxyError(502, "invalid upstream Content-Length", category="upstream")
            if remaining > LFS_MEMORY_LIMIT:
                raise ResponseTooLarge()
            while remaining > 0:
                chunk = upstream.read_body(min(65536, remaining), self.start, self.cfg.total_deadline)
                if not chunk:
                    raise UpstreamTruncated()
                out += chunk
                remaining -= len(chunk)
            return bytes(out)
        # chunked or EOF-framed upstream body: read until end, bounded.
        while True:
            chunk = upstream.read_body(65536, self.start, self.cfg.total_deadline)
            if not chunk:
                break
            out += chunk
            if len(out) > LFS_MEMORY_LIMIT:
                raise ResponseTooLarge()
        return bytes(out)

    def _seal_stamp(
        self, href: str, headers: Any, oid: str, repo: str, stamp_op: str,
        authenticated: bool, what: str,
    ) -> str:
        """Seal a REAL object href (query included) + its credential headers
        into a self-carrying stamp; returns the VM-visible stamped proxy URL.

        Fail-closed: an unparseable, foreign-host, or oid-mismatched href
        raises ProxyError, so the VM never sees an upstream href or a
        credential header. `what` names the source ("LFS batch {op} action"
        or "objects redirect") for deny messages. `auth` records whether the
        href/headers were granted to the HOST credential (True) or to the
        anonymous requester (False); the objects leg re-checks the live grant
        only for host-credential stamps.
        """
        split = urllib.parse.urlsplit(href)
        if split.scheme not in ("http", "https") or not split.hostname:
            raise ProxyError(
                403, f"{what} href is not a valid URL; refused", category="denied",
            )
        if not split.path.startswith("/objects/"):
            raise ProxyError(
                403, f"{what} href is not an object URL; refused", category="denied",
            )
        href_oid = split.path[len("/objects/"):]
        if not _OID_RE.fullmatch(href_oid) or href_oid != oid:
            raise ProxyError(
                403, f"{what} href oid does not match the object; refused",
                category="denied",
            )
        host = split.hostname
        covered = host in COVERED_HOSTS or host in (
            self.cfg.github_upstream_host,
            self.cfg.objects_upstream_host,
        )
        if not covered:
            raise ProxyError(
                403, f"{what} href host {host!r} is not covered; refused",
                category="denied",
            )
        clean_headers: Dict[str, str] = {}
        if isinstance(headers, dict):
            for name, value in headers.items():
                if (isinstance(name, str) and isinstance(value, str)
                        and _HEADER_NAME_RE.fullmatch(name)
                        and len(value) <= MAX_HEADER_VALUE_BYTES):
                    clean_headers[name] = value
        exp = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(
            seconds=self.cfg.stamp_ttl
        )).strftime("%Y-%m-%dT%H:%M:%SZ")
        payload = json.dumps({
            "v": 1,
            "href": href,
            "headers": clean_headers,
            "op": stamp_op,
            "repo": repo,
            "exp": exp,
            "auth": authenticated,
        }, sort_keys=True).encode("utf-8")
        sig = stamp_encode(self.cfg.hmac_key, payload)
        params = (
            f"_msw_repo={urllib.parse.quote(repo, safe='')}"
            f"&_msw_op={stamp_op}&_msw_exp={exp}&_msw_sig={urllib.parse.quote(sig, safe='')}"
        )
        return f"{self.cfg.base_url}/objects.githubusercontent.com/objects/{oid}?{params}"

    def _stamp_action(
        self, action: Dict[str, Any], oid: str, repo: str, op: str,
        authenticated: bool,
    ) -> str:
        """Build the self-carrying stamped URL for one upload/download action.

        The REAL href and the action's credential headers are AEAD-encoded
        into _msw_sig (host-side key); the VM only ever sees the stamped
        proxy URL. Raises ProxyError (failing the WHOLE batch closed) for any
        foreign, unparseable, or mismatched href -- the VM must never see an
        upstream href or action header. The headers are GitHub-issued,
        object-scoped temporaries: for an authenticated batch they were
        granted to the HOST credential, for an anonymous batch they were
        granted to the anonymous requester (never host secrets). `auth`
        records which, so the objects leg re-checks the live grant only for
        host-credential stamps.
        """
        href = action.get("href")
        if not isinstance(href, str):
            raise ProxyError(
                403, f"LFS batch {op} action has no href; batch refused", category="denied",
            )
        return self._seal_stamp(href, action.get("header"), oid, repo, op, authenticated,
                                f"LFS batch {op} action")

    def _stamp_object_redirect(self, location: str, decision: Decision) -> Optional[str]:
        """Reseal an objects-leg redirect into a fresh stamped proxy URL.

        The real object endpoint (e.g. GitHub's CDN) answers the stamped
        request with a 302 whose Location carries the upstream-SIGNED URL,
        query included. Handing that Location to the VM would leak the
        upstream signature AND produce an unstamped URL the classifier
        rejects on the second hop. Instead the redirect href/query and the
        PRESERVED action headers are sealed into a fresh stamp with the same
        repo/op/oid/auth provenance, so the second hop re-enters the proxy
        and works. Non-covered or malformed targets stay denied (None ->
        the caller refuses the redirect exactly like any other non-covered
        redirect).
        """
        if decision.oid is None or decision.stamp_op is None:
            return None
        split = urllib.parse.urlsplit(location)
        if split.scheme and split.scheme not in ("http", "https"):
            return None
        if split.hostname is None:
            # Relative Location: resolve against the REAL upstream href origin
            # (the host the redirect came from).
            base = urllib.parse.urlsplit(decision.href) if decision.href else None
            if base is None or base.scheme not in ("http", "https") or not base.hostname:
                return None
            resolved = urllib.parse.urlunsplit(
                (base.scheme, base.netloc, split.path or "/", split.query, ""))
        else:
            resolved = urllib.parse.urlunsplit(
                (split.scheme or "https", split.netloc, split.path or "/", split.query, ""))
        try:
            return self._seal_stamp(
                resolved, decision.headers, decision.oid, decision.repo,
                decision.stamp_op, decision.authenticated, "objects redirect",
            )
        except ProxyError:
            return None

    def _rewrite_batch_body(self, body: bytes, repo: str, authenticated: bool) -> bytes:
        """Rewrite every LFS batch action to a proxy-stamped URL (section 4).

        FAIL-CLOSED: unless EVERY object entry is a dictionary carrying a
        valid 64-hex oid, and EVERY entry is either an actions map whose
        actions are all covered upload/download dictionaries that stamp
        successfully, or an actionless form (absent or EMPTY actions) with no
        top-level href/header and, when present, a spec-shaped `error` (a
        dict with an integer code and a string message). Any other shape -- a
        malformed entry, a missing oid, non-dict actions, nonempty malformed
        actions, raw href/header on the entry, a foreign or unparseable
        href, or any unsupported action type (such as verify) -- refuses the
        WHOLE batch with an LFS error and must never pass through, because
        batch actions can carry temporary credentials and direct-to-upstream
        URLs that would bypass the proxy. Actionless entries serialize
        unchanged (nothing to stamp, nothing to leak). Action header maps
        (credentials) are removed from the VM-visible response and travel
        only inside the encrypted stamp, re-attached host-side on the
        objects leg. Stamps minted under a grant carry `auth: true` (the
        objects leg re-checks the live grant); anonymous batches carry
        `auth: false` -- their headers are GitHub-issued anonymous-scope
        temporaries, not host secrets, so no grant recheck applies (and the
        batch request itself was credential-free, so that provenance is
        sound).
        """
        try:
            data = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise ProxyError(502, "upstream LFS batch response is not valid JSON", category="upstream")
        if not isinstance(data, dict):
            raise ProxyError(502, "upstream LFS batch response is not valid JSON", category="upstream")
        objects = data.get("objects")
        if not isinstance(objects, list):
            raise ProxyError(502, "upstream LFS batch response is not valid JSON", category="upstream")
        for entry in objects:
            if not isinstance(entry, dict):
                raise ProxyError(
                    403, "LFS batch object entry is not an object; batch refused",
                    category="denied",
                )
            oid = entry.get("oid")
            if not isinstance(oid, str) or not _OID_RE.fullmatch(oid):
                raise ProxyError(
                    403, "LFS batch object entry has no valid oid; batch refused",
                    category="denied",
                )
            # Raw href/header anywhere on an entry is a smuggling vector (they
            # could carry credentials past the proxy); refuse it on EVERY
            # entry, action-bearing or error-only.
            if "href" in entry or "header" in entry:
                raise ProxyError(
                    403, f"LFS batch object {oid} carries raw href/header; batch refused",
                    category="denied",
                )
            actions = entry.get("actions")
            if actions is None or actions == {}:
                # A valid-oid entry WITHOUT actions is legitimate (GitHub
                # answers an upload of an already-present object, or a
                # missing-object download, with an actionless entry). There
                # is nothing to stamp and nothing to leak (raw href/header
                # already refused above), so it is serialized unchanged; an
                # EMPTY actions map is the same actionless form. When an
                # `error` is present it must be spec-shaped (a dict with an
                # integer code and a string message).
                error = entry.get("error")
                if error is not None:
                    code = error.get("code") if isinstance(error, dict) else None
                    message = error.get("message") if isinstance(error, dict) else None
                    if (not isinstance(error, dict)
                            or isinstance(code, bool) or not isinstance(code, int)
                            or not isinstance(message, str)):
                        raise ProxyError(
                            403, f"LFS batch object {oid} has an invalid error; batch refused",
                            category="denied",
                        )
                continue
            if not isinstance(actions, dict):
                raise ProxyError(
                    403, f"LFS batch object {oid} has invalid actions; batch refused",
                    category="denied",
                )
            # actions is a nonempty dict: stamp EVERY action.
            for name, action in list(actions.items()):
                if name not in ("upload", "download") or not isinstance(action, dict):
                    raise ProxyError(
                        403, f"LFS batch action {name!r} is not supported; batch refused",
                        category="denied",
                    )
                stamped = self._stamp_action(action, oid, repo, name, authenticated)
                action["href"] = stamped
                action.pop("header", None)  # credentials never leave the host
        return json.dumps(data).encode("utf-8")

    # ---- teardown / logging -----------------------------------------------------

    def open_log(self) -> None:
        try:
            self.log_fh = open(self.cfg.log_file, "a")
        except OSError:
            self.log_fh = None

    def log_request(self, status: Any) -> None:
        if self.log_fh is None:
            return
        target = self.target or ""
        redacted_target = re.sub(r"(_msw_sig=)[^&]+", r"\1<redacted>", target)
        entry = {
            "t": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "pid": os.getpid(),
            "method": self.method,
            "target": redacted_target,
            "box": self.box,
            "repo": self.repo,
            "op": self.op,
            "status": status,
            "in": self.in_bytes,
            "out": self.out_bytes,
            "ms": round((time.monotonic() - self.start) * 1000, 1),
            "error": self.error,
            "pipelined": self.pipelined or None,
        }
        try:
            self.log_fh.write(json.dumps(entry, sort_keys=True) + "\n")
            self.log_fh.flush()
        except OSError:
            pass

    def close(self) -> None:
        if self.upstream is not None:
            self.upstream.close()
            self.upstream = None
        if self.log_fh is not None:
            try:
                self.log_fh.close()
            except OSError:
                pass
            self.log_fh = None


# ---------------------------------------------------------------------------
# Per-connection entry point
# ---------------------------------------------------------------------------


def handle_connection(cfg: Config, fd_in: int = 0, fd_out: int = 1) -> int:
    ctx = RequestContext(cfg, fd_in, fd_out)
    ctx.open_log()
    status: Any = "closed"
    ctx.log_request("start")
    try:
        request = ctx.receive_request()
        decision = ctx.evaluate(request)
        if decision.kind == "lfs-batch":
            status = ctx._handle_lfs_batch(request, decision)
        else:
            status = ctx._forward_git(request, decision)
    except ProxyError as exc:
        status = exc.status
        # Git smart-HTTP denials (read-only/unticked/identity) surface as an
        # HTTP-200 ERR pkt-line so the VM's git shows a clean
        # "fatal: remote error: <reason>" instead of a 401-style credential
        # prompt for x-access-token@ URLs.
        service = ctx.git_service or _git_service_from_target(ctx.target or "")
        if status == 403 and service is not None and not ctx.batch_failed:
            ctx._respond_git_deny(service, exc.reason)
            status = 200
        else:
            ctx._respond_error(exc.status, exc.reason)
    except (ClientGone, ResponseTooLarge, UpstreamTruncated, AbortError) as exc:
        if ctx.error is None:
            ctx.error = type(exc).__name__.lower()
        status = "closed"
    except proxy_upstream.UpstreamError as exc:
        ctx.error = exc.category
        if isinstance(exc, (proxy_upstream.UpstreamIdleTimeout, proxy_upstream.UpstreamDeadline)):
            status = "closed"
        else:
            status = exc.status
            ctx._respond_error(exc.status, exc.reason)
    except Exception as exc:  # noqa: BLE001 -- fail closed on anything unexpected
        ctx.error = f"internal: {type(exc).__name__}: {ctx._sanitize(str(exc))}"
        status = "closed"
    finally:
        ctx.log_request(status)
        ctx.close()
    return 0


# ---------------------------------------------------------------------------
# Entry points: direct per-connection (default) and --listen (test mode)
# ---------------------------------------------------------------------------


def serve_listen(port: int) -> int:
    """Test-only accept/fork loop mirroring launchd's per-connection spawn."""
    cfg = Config()
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", port))
    sock.listen(128)
    actual_port = sock.getsockname()[1]
    print(f"PROXY_READY port={actual_port}", flush=True)
    # Children must advertise and validate against the real bound port.
    os.environ["MSW_PROXY_BASE_URL"] = f"http://127.0.0.1:{actual_port}"

    def _stop(signum: int, frame: Any) -> None:
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGCHLD, signal.SIG_IGN)
    try:
        while True:
            conn, _ = sock.accept()
            pid = os.fork()
            if pid == 0:
                sock.close()
                os.dup2(conn.fileno(), 0)
                os.dup2(conn.fileno(), 1)
                conn.close()
                try:
                    handle_connection(Config())
                finally:
                    os._exit(0)
            else:
                conn.close()
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        sock.close()
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "--listen":
        port = int(argv[1]) if len(argv) > 1 else 0
        return serve_listen(port)
    return handle_connection(Config())


if __name__ == "__main__":
    raise SystemExit(main())
