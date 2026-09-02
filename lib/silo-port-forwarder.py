#!/usr/bin/python3
"""Host-managed published-port forwarder for one Silo workspace.

Silo no longer asks msb to publish ports at create/boot.
Instead this unprivileged manager, run once per workspace (a launchd
KeepAlive agent in production), keeps ONE OpenSSH control connection with one
`-L <workspace-ip>:P:127.0.0.1:P` per currently free desired port, through
the existing workspace SSH config (ProxyCommand -> msb ssh serve).

Rules:
- The VM is NEVER auto-started: `msb ping -q` gates every cycle.
- Desired ports come from the immutable config list (SILO_PUBLISHED_PORTS).
- Occupied ports (or ports ssh refuses to bind) are omitted and persisted as
  skippedPorts in ~/.config/silo/workspace-state/<box>.json so the Silo
  app can surface a portWarning. State updates are fail-soft.
- Every interval the forwarder reconciles: when a skipped port becomes free
  or an ssh bind fails, ONLY the ssh process is restarted — never the VM.
- VM stop -> ssh exits -> the manager waits. ssh crash -> respawned.

Environment seams (mirror the rest of the Silo toolchain):
  SILO_MSB_BIN, SILO_SSH_BIN, SILO_CONFIG_FILE, SILO_SSH_PROXY_NO_START,
  SILO_TEST_PORT_CONFLICTS (ip:port pairs or bare ports to probe; unset in
  production probes every desired port), SILO_PORT_FORWARDER_INTERVAL,
  SILO_PORT_FORWARDER_ONESHOT (run a single reconcile cycle and exit),
  SILO_PORT_FORWARDER_TRANSACTION (fail closed and report candidate readiness),
  SILO_PORT_FORWARDER_READY_FILE, SILO_PORT_FORWARDER_REVISION,
  SILO_PORT_FORWARDER_SSH_ERR (ssh stderr log path; defaults under
  ~/.local/state/silo).
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import signal
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
    print(f"silo-port-forwarder: {msg}", file=sys.stderr, flush=True)


# --------------------------------------------------------------------------
# Configuration (the same config.sh the silo CLI sources)
# --------------------------------------------------------------------------

def load_config() -> dict:
    path = os.environ.get("SILO_CONFIG_FILE", os.path.expanduser("~/.config/silo/config.sh"))
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
    """Expand the SILO_PUBLISHED_PORTS config into a sorted list of ports."""
    ports: List[int] = []
    seen: Set[int] = set()
    raw = config.get("SILO_PUBLISHED_PORTS") or DEFAULT_PUBLISHED_PORTS
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
    path = workspace_file(config)
    try:
        document = json.loads(path.read_text())
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


def workspace_file(config: dict) -> Path:
    return Path(
        os.environ.get("SILO_WORKSPACES_FILE")
        or config.get("SILO_WORKSPACES_FILE")
        or os.path.expanduser("~/.config/silo/workspaces.json")
    )


def candidate_revision(config: dict) -> str:
    return hashlib.sha256(workspace_file(config).read_bytes()).hexdigest()


def workspace_ip(config: dict, box: str) -> str:
    names = load_workspace_names(config)
    if names is not None and box in names:
        return f"127.0.0.{10 + names.index(box)}"
    raise ValueError(f"workspace is not configured: {box}")


def state_file(box: str) -> Path:
    return Path(os.path.expanduser("~/.config/silo/workspace-state")) / f"{box}.json"


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
        # Compact separators: bin/silo's sed-based state reader expects
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
    """SILO_TEST_PORT_CONFLICTS: 'ip:port' pairs (matched to the bind ip) or
    bare ports (probed on every workspace). An empty env seam set means every
    desired port is probed (production)."""
    raw = os.environ.get("SILO_TEST_PORT_CONFLICTS", "")
    if not raw:
        return set()
    return {token.strip() for token in raw.split(",") if token.strip()}


def seam_simulated_set() -> Set[str]:
    """SILO_TEST_PORT_CONFLICTS_FILE (re-read every cycle, same format as the
    env seam): entries are treated as blocked WITHOUT a real bind probe, so
    tests can flip the occupied set deterministically regardless of what else
    is listening on the host. Not used in production."""
    path = os.environ.get("SILO_TEST_PORT_CONFLICTS_FILE", "")
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
      - with no seam at all, SILO_TEST_MODE=1 skips probing (all free) so the
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
        elif os.environ.get("SILO_TEST_MODE") == "1":
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
        override = os.environ.get("SILO_PORT_FORWARDER_SSH_ERR", "")
        if override:
            return Path(override)
        return Path.home() / ".local/state/silo" / f"port-forwarder-{self.box}.ssh.err"

    def _ssh_argv(self, ports: List[int]) -> List[str]:
        exit_on_failure = "yes" if os.environ.get("SILO_PORT_FORWARDER_TRANSACTION") == "1" else "no"
        argv = [
            self.ssh_bin,
            "-N", "-T",
            "-o", f"ExitOnForwardFailure={exit_on_failure}",
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
                   bind_ip: str, seam: Set[str], oneshot: bool = False,
                   required_ports: Optional[Set[int]] = None,
                   state_ports: Optional[Set[int]] = None) -> bool:
    if not fwd.msb_running():
        # Never auto-start a stopped VM; while it is stopped nothing is
        # published and there is nothing to warn about.
        fwd.stop()
        write_state(box, desired, [], [], utc_now())
        return False

    simulated = seam_simulated_set()
    blocked = probe_blocked(bind_ip, desired_ports, fwd.launched, seam, simulated)
    state_blocked = blocked if state_ports is None else blocked & state_ports
    if required_ports and blocked & required_ports:
        fwd.stop()
        write_state(box, desired, sorted(state_blocked), sorted(state_blocked), utc_now())
        raise RuntimeError(
            f"required published ports are unavailable: {sorted(blocked & required_ports)}"
        )
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

    state_still = still if state_ports is None else still & state_ports
    write_state(box, desired, sorted(state_blocked), sorted(state_still), utc_now())
    return fwd.alive() and fwd.launched == set(target)


def write_ready(path: Path, box: str, revision: str) -> None:
    document = {
        "schemaVersion": 1,
        "workspace": box,
        "revision": revision,
        "status": "ready",
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f".tmp.{os.getpid()}")
    with open(tmp, "w") as handle:
        json.dump(document, handle, separators=(",", ":"))
        handle.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


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
    published_ports = expand_published(config)
    desired_ports = list(published_ports)
    required_raw = os.environ.get("SILO_PORT_FORWARDER_REQUIRED_PORTS", "")
    required_ports: Set[int] = set()
    if required_raw:
        required_ports = set(expand_published({"SILO_PUBLISHED_PORTS": required_raw}))
        desired_ports = sorted(set(desired_ports) | required_ports)
    desired = [f"{bind_ip}:{p}:{p}" for p in published_ports]
    seam = seam_probe_set()

    msb_bin = os.environ.get("SILO_MSB_BIN", "")
    if not msb_bin:
        for candidate in ("/usr/local/bin/msb", "/opt/homebrew/bin/msb",
                          str(Path.home() / ".local/bin/msb")):
            if os.path.exists(candidate):
                msb_bin = candidate
                break
    ssh_bin = os.environ.get("SILO_SSH_BIN", "ssh")
    fwd = Forwarder(box, bind_ip, ssh_bin, msb_bin)

    oneshot = os.environ.get("SILO_PORT_FORWARDER_ONESHOT") == "1"
    transaction = os.environ.get("SILO_PORT_FORWARDER_TRANSACTION") == "1"
    ready_path_value = os.environ.get("SILO_PORT_FORWARDER_READY_FILE", "")
    revision = os.environ.get("SILO_PORT_FORWARDER_REVISION", "")
    if transaction:
        if not ready_path_value or not re.fullmatch(r"[0-9a-f]{64}", revision):
            print("candidate forwarding requires a readiness file and revision", file=sys.stderr)
            return 64
        try:
            if candidate_revision(config) != revision:
                print("candidate forwarding revision does not match configuration", file=sys.stderr)
                return 78
        except OSError:
            print("candidate forwarding configuration is unreadable", file=sys.stderr)
            return 78
    ready_path = Path(ready_path_value) if ready_path_value else None
    interval = float(os.environ.get("SILO_PORT_FORWARDER_INTERVAL", str(DEFAULT_INTERVAL)))
    def stop_requested(_signum: int, _frame: object) -> None:
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop_requested)
    signal.signal(signal.SIGINT, stop_requested)
    try:
        while True:
            try:
                ready = reconcile_once(
                    box, fwd, desired, desired_ports, bind_ip, seam, oneshot,
                    required_ports=required_ports if transaction else None,
                    state_ports=set(published_ports),
                )
                if transaction and ready and ready_path is not None and not ready_path.exists():
                    # ExitOnForwardFailure plus a live ssh process proves that
                    # every unblocked candidate bind was accepted.
                    time.sleep(float(os.environ.get("SILO_PORT_FORWARDER_READY_DELAY", "0.25")))
                    if fwd.alive() and not fwd.bind_failures():
                        write_ready(ready_path, box, revision)
                    else:
                        return 69
            except Exception as exc:
                if transaction:
                    log(f"candidate reconcile failed for {box}: {exc}")
                    return 69
                log(f"reconcile error for {box}: {exc}")
            if oneshot:
                # State-only cycle (tests / kick probe): no ssh is spawned, so
                # nothing is left behind.
                return 0
            time.sleep(interval)
    finally:
        fwd.stop()


if __name__ == "__main__":
    raise SystemExit(main())
