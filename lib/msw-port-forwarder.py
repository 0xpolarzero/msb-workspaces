#!/usr/bin/python3
"""Host-managed published-port forwarder for one MSW workspace.

MicroSandbox Workspaces no longer asks msb to publish ports at create/boot.
Instead this unprivileged manager, run once per workspace (a launchd
KeepAlive agent in production), keeps ONE OpenSSH control connection with one
`-L <workspace-ip>:P:127.0.0.1:P` per currently free desired port, through
the existing workspace SSH config (ProxyCommand -> msb ssh serve).

Rules:
- The VM is NEVER auto-started: `msb ping -q` gates every cycle.
- Desired ports come from the immutable config list (MSW_PUBLISHED_PORTS).
- Occupied ports (or ports ssh refuses to bind) are omitted and persisted as
  skippedPorts in ~/.config/msw/workspace-state/<box>.json so the MSW Monitor
  app can surface a portWarning. State updates are fail-soft.
- Every interval the forwarder reconciles: when a skipped port becomes free
  or an ssh bind fails, ONLY the ssh process is restarted — never the VM.
- VM stop -> ssh exits -> the manager waits. ssh crash -> respawned.

Environment seams (mirror the rest of the MSW toolchain):
  MSW_MSB_BIN, MSW_SSH_BIN, MSW_CONFIG_FILE, MSW_SSH_PROXY_NO_START,
  MSW_TEST_PORT_CONFLICTS (ip:port pairs or bare ports to probe; unset in
  production probes every desired port), MSW_PORT_FORWARDER_INTERVAL,
  MSW_PORT_FORWARDER_ONESHOT (run a single reconcile cycle and exit),
  MSW_PORT_FORWARDER_SSH_ERR (ssh stderr log path; defaults under
  ~/.local/state/msw).
"""
from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import List, Optional, Set

DEFAULT_PUBLISHED_PORTS = "3000,5173,8080"
DEFAULT_INTERVAL = 5
WORKSPACE_KEYS = {
    "name", "cpu", "cpuCeiling", "memoryGiB", "memoryCeilingGiB",
    "workspaceStorageGiB", "runtimeStorageGiB",
}


def log(msg: str) -> None:
    print(f"msw-port-forwarder: {msg}", file=sys.stderr, flush=True)


# --------------------------------------------------------------------------
# Configuration (the same config.sh the msw CLI sources)
# --------------------------------------------------------------------------

def load_config() -> dict:
    path = os.environ.get("MSW_CONFIG_FILE", os.path.expanduser("~/.config/msw/config.sh"))
    values: dict = {}
    if os.path.isfile(path):
        try:
            text = Path(path).read_text(errors="replace")
        except OSError:
            text = ""
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "${" in line:
                continue
            m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=(?:"([^"]*)"|([^#\s]*))', line)
            if m:
                values[m.group(1)] = m.group(2) if m.group(2) is not None else (m.group(3) or "")
    return values


def expand_published(config: dict) -> List[int]:
    """Expand the MSW_PUBLISHED_PORTS config into a sorted list of ports."""
    ports: List[int] = []
    seen: Set[int] = set()
    raw = config.get("MSW_PUBLISHED_PORTS") or DEFAULT_PUBLISHED_PORTS
    for token in raw.split(","):
        token = token.strip()
        if not token:
            continue
        if "-" in token:
            start_s, end_s = token.split("-", 1)
            start, end = int(start_s), int(end_s)
        else:
            start = end = int(token)
        if start < 1 or end > 65535 or start > end:
            raise ValueError(f"invalid published port token: {token}")
        for p in range(start, end + 1):
            if p not in seen:
                seen.add(p)
                ports.append(p)
    return ports


def load_workspace_names(config: dict) -> Optional[List[str]]:
    workspace_file = Path(
        os.environ.get("MSW_WORKSPACES_FILE")
        or config.get("MSW_WORKSPACES_FILE")
        or os.path.expanduser("~/.config/msw/workspaces.json")
    )
    try:
        document = json.loads(workspace_file.read_text())
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        return None
    if not isinstance(document, dict) or set(document) != {"schemaVersion", "workspaces"}:
        return None
    workspaces = document.get("workspaces")
    schema_version = document.get("schemaVersion")
    if isinstance(schema_version, bool) or schema_version != 1:
        return None
    if not isinstance(workspaces, list) or not 1 <= len(workspaces) <= 64:
        return None
    names: List[str] = []
    for entry in workspaces:
        if not isinstance(entry, dict) or set(entry) != WORKSPACE_KEYS:
            return None
        name = entry.get("name")
        cpu = entry.get("cpu")
        cpu_ceiling = entry.get("cpuCeiling")
        memory = entry.get("memoryGiB")
        memory_ceiling = entry.get("memoryCeilingGiB")
        numeric_values = (cpu, cpu_ceiling, memory, memory_ceiling,
                          entry.get("workspaceStorageGiB"), entry.get("runtimeStorageGiB"))
        if any(
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or (isinstance(value, float) and not value.is_integer())
            for value in numeric_values
        ):
            return None
        if (not isinstance(name, str) or re.fullmatch(r"[a-z][a-z0-9-]{0,31}", name) is None
                or cpu not in (4, 6, 8, 12) or cpu_ceiling not in (4, 6, 8, 12)
                or cpu > cpu_ceiling or memory not in (16, 32, 48)
                or memory_ceiling not in (16, 32, 48) or memory > memory_ceiling
                or entry["workspaceStorageGiB"] not in (60, 80, 100, 120)
                or entry["runtimeStorageGiB"] not in (60, 80, 100, 120)):
            return None
        names.append(name)
    if len(set(names)) != len(names):
        return None
    return names


def workspace_ip(config: dict, box: str) -> str:
    names = load_workspace_names(config)
    if names is not None and box in names:
        return f"127.0.0.{10 + names.index(box)}"
    raise ValueError(f"workspace is not configured: {box}")


def state_file(box: str) -> Path:
    return Path(os.path.expanduser("~/.config/msw/workspace-state")) / f"{box}.json"


def read_state(box: str) -> dict:
    path = state_file(box)
    if not path.is_file() or path.is_symlink():
        return {}
    try:
        return json.loads(path.read_text())
    except ValueError:
        return {}


def write_state(box: str, desired: List[str], skipped: List[int], still: List[int], warned_at: str) -> None:
    path = state_file(box)
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(path.parent, 0o700)
    except OSError:
        pass
    doc = {
        "schemaVersion": 1,
        "desiredPorts": desired,
        "skippedPorts": sorted(skipped),
        "stillInUse": sorted(still),
        "warnedAt": warned_at,
    }
    tmp = path.with_name(path.name + f".tmp.{os.getpid()}")
    with open(tmp, "w") as f:
        # Compact separators: bin/msw's sed-based state reader expects
        # integer arrays without spaces.
        json.dump(doc, f, separators=(",", ":"))
    try:
        os.chmod(tmp, 0o600)
    except OSError:
        pass
    os.replace(tmp, path)


def utc_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


# --------------------------------------------------------------------------
# Probing
# --------------------------------------------------------------------------

def seam_probe_set() -> Set[str]:
    """MSW_TEST_PORT_CONFLICTS: 'ip:port' pairs (matched to the bind ip) or
    bare ports (probed on every workspace). An empty env seam set means every
    desired port is probed (production)."""
    raw = os.environ.get("MSW_TEST_PORT_CONFLICTS", "")
    if not raw:
        return set()
    return {token.strip() for token in raw.split(",") if token.strip()}


def seam_simulated_set() -> Set[str]:
    """MSW_TEST_PORT_CONFLICTS_FILE (re-read every cycle, same format as the
    env seam): entries are treated as blocked WITHOUT a real bind probe, so
    tests can flip the occupied set deterministically regardless of what else
    is listening on the host. Not used in production."""
    path = os.environ.get("MSW_TEST_PORT_CONFLICTS_FILE", "")
    if not path:
        return set()
    try:
        raw = Path(path).read_text(errors="replace")
    except OSError:
        return set()
    return {token.strip() for token in raw.replace("\n", ",").split(",") if token.strip()}


def probe_blocked(bind_ip: str, ports: List[int], launched: Set[int], seam: Set[str],
                  simulated: Set[str]) -> Set[int]:
    """Return the desired ports that cannot be bound on the workspace ip.
    Ports the running ssh already holds (launched) are never re-probed; the
    rest are tested with a real bind (SO_REUSEADDR), which is what ssh will
    do next anyway. Seam policy:
      - simulated entries count as blocked (no real probe);
      - with a real env seam set, only its entries are probed, everything
        else is assumed free;
      - with no seam at all, MSW_TEST_MODE=1 skips probing (all free) so the
        suite never depends on what else listens on the host, and production
        probes every desired port."""
    blocked: Set[int] = set()
    for p in ports:
        if p in launched:
            continue
        if simulated and _seam_matches(simulated, bind_ip, p):
            blocked.add(p)
            continue
        if seam:
            if not _seam_matches(seam, bind_ip, p):
                continue
        elif os.environ.get("MSW_TEST_MODE") == "1":
            continue
        if not _bind_ok(bind_ip, p):
            blocked.add(p)
    return blocked


def _seam_matches(seam: Set[str], bind_ip: str, port: int) -> bool:
    port_s = str(port)
    for token in seam:
        if ":" in token:
            ip, _, p = token.rpartition(":")
            if ip == bind_ip and p == port_s:
                return True
        elif token == port_s:
            return True
    return False


def _bind_ok(bind_ip: str, port: int) -> bool:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((bind_ip, port))
    except OSError:
        return False
    finally:
        s.close()
    return True


# --------------------------------------------------------------------------
# ssh lifecycle
# --------------------------------------------------------------------------

BIND_FAILURE_RE = re.compile(r"listen port (\d+)|bind \[[^\]]+\]:(\d+)")


class Forwarder:
    def __init__(self, box: str, bind_ip: str, ssh_bin: str, msb_bin: str):
        self.box = box
        self.bind_ip = bind_ip
        self.ssh_bin = ssh_bin
        self.msb_bin = msb_bin
        self.proc: Optional[subprocess.Popen] = None
        self.launched: Set[int] = set()
        self._err_file = None

    def msb_running(self) -> bool:
        try:
            return subprocess.run(
                [self.msb_bin, "ping", "-q", self.box],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=10,
            ).returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            return False

    def _err_path(self) -> Path:
        override = os.environ.get("MSW_PORT_FORWARDER_SSH_ERR", "")
        if override:
            return Path(override)
        return Path.home() / ".local/state/msw" / f"port-forwarder-{self.box}.ssh.err"

    def _ssh_argv(self, ports: List[int]) -> List[str]:
        argv = [
            self.ssh_bin,
            "-N", "-T",
            "-o", "ExitOnForwardFailure=no",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "BatchMode=yes",
        ]
        for p in ports:
            argv += ["-L", f"{self.bind_ip}:{p}:127.0.0.1:{p}"]
        argv.append(f"{self.box}.msb")
        return argv

    def start(self, ports: List[int]) -> bool:
        self.stop()
        if not ports:
            return True
        err_path = self._err_path()
        err_path.parent.mkdir(parents=True, exist_ok=True)
        # Truncate: bind_failures() must only ever see the live instance's
        # stderr, not warnings from a previous ssh process.
        err = open(err_path, "wb")
        argv = self._ssh_argv(ports)
        log(f"starting ssh forwarder for {self.box} with ports {ports}")
        try:
            self.proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stderr=err)
        except OSError as exc:
            log(f"could not start ssh ({exc}); retrying next cycle")
            err.close()
            self.proc = None
            self.launched = set()
            return False
        self._err_file = err
        self.launched = set(ports)
        return True

    def stop(self) -> None:
        if self.proc is not None and self.proc.poll() is None:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                try:
                    self.proc.kill()
                except OSError:
                    pass
                self.proc.wait(timeout=3)
        self.proc = None
        self.launched = set()
        if self._err_file is not None:
            try:
                self._err_file.close()
            except OSError:
                pass
            self._err_file = None

    def alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def bind_failures(self) -> Set[int]:
        """Parse the ssh stderr log for ports ssh refused to bind. Fail-soft:
        lines we cannot parse change nothing (the next cycle re-probes those
        ports and reconciles)."""
        path = self._err_path()
        if not path.exists():
            return set()
        try:
            text = path.read_text(errors="replace")
        except OSError:
            return set()
        failed: Set[int] = set()
        for m in BIND_FAILURE_RE.finditer(text):
            port = int(m.group(1) or m.group(2))
            failed.add(port)
        return failed


# --------------------------------------------------------------------------
# One reconcile cycle
# --------------------------------------------------------------------------

def reconcile_once(box: str, fwd: Forwarder, desired: List[str], desired_ports: List[int],
                   bind_ip: str, seam: Set[str], oneshot: bool = False) -> None:
    if not fwd.msb_running():
        # Never auto-start a stopped VM; while it is stopped nothing is
        # published and there is nothing to warn about.
        fwd.stop()
        write_state(box, desired, [], [], utc_now())
        return

    simulated = seam_simulated_set()
    blocked = probe_blocked(bind_ip, desired_ports, fwd.launched, seam, simulated)
    still = set(blocked)
    target = sorted(set(desired_ports) - blocked)

    if not oneshot:
        if not fwd.alive():
            # ssh crashed or never started: drop ports the previous instance
            # failed to bind, then (re)start with the current target.
            fwd.launched -= fwd.bind_failures()
            fwd.start(target)
        elif target != sorted(fwd.launched):
            # A skipped port became free or an active one became occupied:
            # restart ONLY the forwarder, never the VM.
            log(f"{box}: forwarding set changed {sorted(fwd.launched)} -> {target}; restarting ssh")
            fwd.start(target)
        else:
            # Set unchanged: pick up any bind failures reported on stderr so
            # the next cycle re-probes those ports.
            fwd.launched -= fwd.bind_failures()

    write_state(box, desired, sorted(blocked), sorted(still), utc_now())


def main() -> int:
    if len(sys.argv) != 2 or not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", sys.argv[1]):
        print(f"usage: {sys.argv[0]} WORKSPACE", file=sys.stderr)
        return 64
    box = sys.argv[1]
    config = load_config()
    configured = load_workspace_names(config)
    if configured is None or box not in configured:
        print(f"unknown configured workspace: {box}", file=sys.stderr)
        return 64
    bind_ip = workspace_ip(config, box)
    desired_ports = expand_published(config)
    desired = [f"{bind_ip}:{p}:{p}" for p in desired_ports]
    seam = seam_probe_set()

    msb_bin = os.environ.get("MSW_MSB_BIN", "")
    if not msb_bin:
        for candidate in ("/usr/local/bin/msb", "/opt/homebrew/bin/msb",
                          str(Path.home() / ".local/bin/msb")):
            if os.path.exists(candidate):
                msb_bin = candidate
                break
    ssh_bin = os.environ.get("MSW_SSH_BIN", "ssh")
    fwd = Forwarder(box, bind_ip, ssh_bin, msb_bin)

    oneshot = os.environ.get("MSW_PORT_FORWARDER_ONESHOT") == "1"
    interval = float(os.environ.get("MSW_PORT_FORWARDER_INTERVAL", str(DEFAULT_INTERVAL)))
    while True:
        try:
            reconcile_once(box, fwd, desired, desired_ports, bind_ip, seam, oneshot)
        except Exception as exc:  # fail-soft: never let the agent die on a bad cycle
            log(f"reconcile error for {box}: {exc}")
        if oneshot:
            # State-only cycle (tests / kick probe): no ssh is spawned, so
            # nothing is left behind.
            return 0
        time.sleep(interval)


if __name__ == "__main__":
    raise SystemExit(main())
