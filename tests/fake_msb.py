#!/usr/bin/python3
"""Stateful MicroSandbox CLI simulator used by the Silo release tests."""
from __future__ import annotations

import json
import os
import re
import shutil
import time
import subprocess
import sys
from pathlib import Path
from typing import Any
STATE_ROOT = Path(os.environ.get("SILO_FAKE_STATE", "/tmp/silo-fake-state")).resolve()
STATE_FILE = STATE_ROOT / "state.json"
REMOTE_ROOT = os.environ.get("SILO_TEST_GITHUB_REMOTE_ROOT", "")


# Raw-disk tail-discard seam: SILO_FAKE_TAIL_DISCARD=safe|unsafe selects how
# the simulated runtime answers a guest FITRIM that reaches the end of a
# mounted raw disk. safe preserves the raw image length; unsafe reproduces
# msb-imago 0.1.1's File::try_discard_by_truncate defect, which shortens the
# raw file at the first free block of the final ext4 group (the exact
# 132,112,384-byte deficit observed on 2 GiB images). While the seam is
# active, `volume create` materializes real raw images (instead of
# directories) so setup.sh's geometry checks can observe the truncation.
TAIL_DISCARD = os.environ.get("SILO_FAKE_TAIL_DISCARD", "")
TAIL_DISCARD_DEFICIT = 132_112_384


def initial_state() -> dict[str, Any]:
    return {"sandboxes": {}, "volumes": {}, "snapshots": {}, "events": []}


def load() -> dict[str, Any]:
    STATE_ROOT.mkdir(parents=True, exist_ok=True)
    if not STATE_FILE.exists():
        return initial_state()
    return json.loads(STATE_FILE.read_text())


def save(state: dict[str, Any]) -> None:
    STATE_ROOT.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True))
    tmp.replace(STATE_FILE)


def fail(msg: str, code: int = 1) -> int:
    print(msg, file=sys.stderr)
    return code

def require_secret_source(sb: dict[str, Any], *, binding_operation: bool = False) -> bool:
    if (
        binding_operation
        and
        os.environ.get("SILO_FAKE_REQUIRE_SECRET_SOURCE") == "1"
        and sb.get("secrets", {}).get("GH_TOKEN")
        and not os.environ.get("GH_TOKEN")
    ):
        fail("host source GH_TOKEN missing")
        return False
    return True
def record_lock_fd() -> None:
    marker = os.environ.get("SILO_FAKE_LOCK_FD_MARKER", "")
    if not marker:
        return
    try:
        os.fstat(9)
    except OSError:
        value = "closed"
    else:
        value = "open"
    Path(marker).write_text(value + "\n")

def record_secrets_lock_fd(command: str) -> None:
    marker = os.environ.get("SILO_FAKE_SECRETS_LOCK_FD_MARKER", "")
    if not marker:
        return
    try:
        os.fstat(6)
    except OSError:
        value = "closed"
    else:
        value = "open"
    with Path(marker).open("a") as handle:
        handle.write(f"{command}:{value}\n")



def log_event(state: dict[str, Any], event: str, **data: Any) -> None:
    state.setdefault("events", []).append({"event": event, **data})


def ensure_sandbox_dirs(state: dict[str, Any], box: str) -> dict[str, Any]:
    sb = state["sandboxes"][box]
    root = STATE_ROOT / "guests" / box
    (root / "tmp").mkdir(parents=True, exist_ok=True)
    (root / "home").mkdir(parents=True, exist_ok=True)
    (root / "rootfs").mkdir(parents=True, exist_ok=True)
    sb["root"] = str(root)
    return sb


def ext4_declared_bytes(path: Path) -> int | None:
    """Bytes declared by the ext4 superblock at byte 1024, or None."""
    try:
        with path.open("rb") as handle:
            handle.seek(1028)
            blocks_lo_raw = handle.read(4)
            handle.seek(1048)
            log_block_size_raw = handle.read(4)
    except OSError:
        return None
    if len(blocks_lo_raw) != 4 or len(log_block_size_raw) != 4:
        return None
    blocks_lo = int.from_bytes(blocks_lo_raw, "little")
    log_block_size = int.from_bytes(log_block_size_raw, "little")
    if blocks_lo == 0 or log_block_size > 6:
        return None
    return blocks_lo * (1024 << log_block_size)


def write_raw_ext4_image(path: Path, declared_bytes: int, length_bytes: int) -> None:
    """Materialize a raw ext4 image (4 KiB blocks, magic 0x53ef) at length_bytes."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        handle.truncate(length_bytes)
        handle.seek(1028)
        handle.write((declared_bytes // 4096).to_bytes(4, "little"))
        handle.seek(1048)
        handle.write((2).to_bytes(4, "little"))
        handle.seek(1080)
        handle.write(b"\x53\xef")


def volume_path(state: dict[str, Any], name: str) -> Path:
    entry = state["volumes"][name]
    p = Path(entry["path"])
    if p.is_file() and os.environ.get("SILO_TEST_VALIDATE_RAW_DISKS") == "1":
        p = p.parent / "guest-data"
    p.mkdir(parents=True, exist_ok=True)
    return p


def guest_workspace(state: dict[str, Any], box: str) -> Path:
    sb = ensure_sandbox_dirs(state, box)
    name = sb.get("workspace_volume")
    if name:
        return volume_path(state, name)
    p = Path(sb["root"]) / "workspace"
    p.mkdir(parents=True, exist_ok=True)
    return p


def guest_runtime(state: dict[str, Any], box: str) -> Path:
    sb = ensure_sandbox_dirs(state, box)
    name = sb.get("runtime_volume")
    if name:
        return volume_path(state, name)
    p = Path(sb["root"]) / "runtime"
    p.mkdir(parents=True, exist_ok=True)
    return p


def map_guest_path(state: dict[str, Any], box: str, raw: str) -> str:
    sb = ensure_sandbox_dirs(state, box)
    root = Path(sb["root"])
    # Preserve paths already returned by commands running in the simulator.
    # Test state normally lives below /tmp, so this must run before guest /tmp mapping.
    try:
        resolved = Path(raw).resolve(strict=False)
        allowed_roots = (root.resolve(), guest_workspace(state, box).resolve(), guest_runtime(state, box).resolve())
        if any(resolved == base or base in resolved.parents for base in allowed_roots):
            return raw
    except OSError:
        pass
    if raw == "/workspace":
        return str(guest_workspace(state, box))
    if raw.startswith("/workspace/"):
        return str(guest_workspace(state, box) / raw[len("/workspace/"):])
    if raw == "/var/lib/silo-runtime":
        return str(guest_runtime(state, box))
    if raw.startswith("/var/lib/silo-runtime/"):
        return str(guest_runtime(state, box) / raw[len("/var/lib/silo-runtime/"):])
    if raw == "/tmp":
        return str(root / "tmp")
    if raw.startswith("/tmp/"):
        return str(root / "tmp" / raw[len("/tmp/"):])
    return raw


def git_env(state: dict[str, Any], box: str) -> dict[str, str]:
    sb = ensure_sandbox_dirs(state, box)
    env = os.environ.copy()
    env.update({
        "HOME": str(Path(sb["root"]) / "home"),
        "SILO_GUEST_WORKSPACE_ROOT": str(guest_workspace(state, box)),
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "GIT_TERMINAL_PROMPT": "0",
        # Isolate the guest "system" git config so guest-side
        # `git config --system ...` (proxy-configure) never mutates the real
        # host /etc/gitconfig.
        "GIT_CONFIG_SYSTEM": str(Path(sb["root"]) / "gitconfig"),
    })
    # Bound secrets substitute placeholders inside the guest, so a real value
    # can never reach the simulated VM environment even if the host-side CLI
    # leaked it (GitHub's legacy GH_TOKEN keeps its historical placeholder).
    for secret_name in sb.get("secrets", {}):
        if secret_name == "GH_TOKEN":
            env["GH_TOKEN"] = r"$MSB_GH_TOKEN"
        else:
            env[secret_name] = "$MSB_" + secret_name
    if os.environ.get("SILO_FAKE_GUEST_PUSH_ALLOWED") != "1":
        env["SILO_GUEST_READ_ONLY"] = "1"
    if REMOTE_ROOT:
        env["GIT_CONFIG_COUNT"] = "2"
        env["GIT_CONFIG_KEY_0"] = f"url.file://{Path(REMOTE_ROOT).resolve()}/.insteadOf"
        env["GIT_CONFIG_VALUE_0"] = "https://github.com/"
        env["GIT_CONFIG_KEY_1"] = "protocol.file.allow"
        env["GIT_CONFIG_VALUE_1"] = "always"
    return env


def parse_named_arg(args: list[str]) -> str | None:
    positional: list[str] = []
    skip = False
    value_opts = {"-t", "--timeout", "--source", "--tail", "--label", "--format"}
    for i, arg in enumerate(args):
        if skip:
            skip = False
            continue
        if arg in value_opts:
            skip = True
        elif arg.startswith("-"):
            continue
        else:
            positional.append(arg)
    return positional[-1] if positional else None


def first_box_arg(args: list[str]) -> str:
    """First non-flag argument (the sandbox name) for credential-env events."""
    skip = False
    value_opts = {
        "-t", "--timeout", "--source", "--tail", "--label", "--format",
        "-w", "--workdir", "-u", "--user", "-e", "--env", "--rlimit",
    }
    for arg in args:
        if skip:
            skip = False
            continue
        if arg in value_opts:
            skip = True
        elif arg.startswith("-"):
            continue
        else:
            return arg
    return ""


def parse_create(args: list[str], state: dict[str, Any]) -> int:
    if "--" in args:
        args = args[:args.index("--")]
    name: str | None = None
    image: str | None = None
    snapshot: str | None = None
    envs: dict[str, str] = {}
    labels: dict[str, str] = {}
    ports: list[str] = []
    mounts: list[str] = []
    options_with_value = {
        "--name", "--from-snapshot", "--cpus", "--max-cpus", "--memory", "--max-memory",
        "--root-disk", "--mount-named", "--mkdir", "--workdir", "--init", "--security",
        "--net", "--label", "--env", "--port", "-p", "-e", "-w",
    }
    i = 0
    while i < len(args):
        arg = args[i]
        if arg in options_with_value:
            if i + 1 >= len(args):
                return fail(f"missing value for {arg}")
            value = args[i + 1]
            if arg == "--name": name = value
            elif arg == "--from-snapshot": snapshot = value
            elif arg == "--mount-named": mounts.append(value)
            elif arg in ("--port", "-p"): ports.append(value)
            elif arg in ("--env", "-e"):
                key, _, val = value.partition("=")
                envs[key] = val
            elif arg == "--label":
                key, _, val = value.partition("=")
                labels[key] = val
            i += 2
        elif arg.startswith("-"):
            i += 1
        else:
            if image is None: image = arg
            i += 1
    if not name:
        return fail("create requires --name")
    if name in state["sandboxes"]:
        return fail(f"sandbox exists: {name}")
    if snapshot and snapshot not in state["snapshots"]:
        return fail(f"snapshot missing: {snapshot}")
    sb: dict[str, Any] = {
        "running": True,
        "image": image,
        "snapshot": snapshot,
        "env": envs,
        "labels": labels,
        "ports": ports,
        "secrets": {},
        "configured": False,
        "bootstrapped": False,
        "port_content": {},
        "args": args,
        "mounts": {},
    }
    for mount in mounts:
        parts = mount.split(":", 2)
        vol, dest = parts[0], parts[1]
        options = parts[2] if len(parts) > 2 else ""
        size_match = re.search(r"(?:^|,)size=([^,]+)", options)
        if vol not in state["volumes"]:
            p = STATE_ROOT / "volumes" / vol
            p.mkdir(parents=True, exist_ok=True)
            state["volumes"][vol] = {
                "path": str(p), "size": size_match.group(1) if size_match else "",
                "kind": "disk", "filesystem": "ext4", "magic": "53ef", "formatCount": 1,
            }
        sb["mounts"][dest] = vol
        if dest == "/workspace": sb["workspace_volume"] = vol
        if dest == "/var/lib/silo-runtime": sb["runtime_volume"] = vol
    state["sandboxes"][name] = sb
    ensure_sandbox_dirs(state, name)
    guest_workspace(state, name).mkdir(parents=True, exist_ok=True)
    guest_runtime(state, name).mkdir(parents=True, exist_ok=True)
    log_event(state, "create", box=name)
    save(state)
    print(name)
    return 0


def parse_exec(args: list[str], state: dict[str, Any]) -> int:
    workdir = "/"
    i = 0
    box: str | None = None
    while i < len(args):
        arg = args[i]
        if arg in ("--no-tty", "-t", "--tty", "-q", "--quiet", "--stream"):
            i += 1
        elif arg in ("-w", "--workdir", "-u", "--user", "-e", "--env", "--timeout", "--rlimit"):
            if arg in ("-w", "--workdir"): workdir = args[i + 1]
            i += 2
        else:
            box = arg
            i += 1
            break
    if not box or box not in state["sandboxes"]:
        return fail("unknown sandbox")
    # Real msb also accepts transport flags AFTER the box (`exec <box>
    # --stream -- ...` is how the shuttle spawns relays); skip them before
    # the `--` command separator.
    while i < len(args) and args[i] in ("--no-tty", "-t", "--tty", "-q", "--quiet", "--stream"):
        i += 1
    if i < len(args) and args[i] == "--": i += 1
    command = args[i:]
    if not command:
        return fail("missing exec command")
    sb = ensure_sandbox_dirs(state, box)
    if not require_secret_source(sb):
        return 1
    sb["running"] = True
    # Silo control-plane execs run through a bash -c wrapper that prints the
    # reserved internal-session marker (control conn-id 0, length 1, payload
    # "H") to stderr before exec'ing the real command. Strip that wrapper so
    # every stub below — including the relay stub and systemctl branches —
    # matches the unchanged real command shape. The CLI wrappers use $0="_"
    # and exec "$@" (the payload follows the marker); the shuttle's relay
    # wrapper uses $0="silo-shuttle" and execs `python3 "$1"` explicitly, so
    # the stripped command must restore the python3 it would run. Only the
    # marker wrapper is stripped: plain `bash -c ... _ ARG` commands that
    # legitimately use "_" as $0 (git verification probes) are left intact.
    if (len(command) >= 4 and command[:2] == ["bash", "-c"]
            and command[3] in ("_", "silo-shuttle")
            and command[2].startswith("printf ")
            and "exec " in command[2]):
        # Journal that this exec arrived as the marker-wrapped control-plane
        # argv so regressions can prove control-session provenance.
        sb["wrapped_control_execs"] = sb.get("wrapped_control_execs", 0) + 1
        if command[3] == "silo-shuttle":
            command = ["python3"] + command[4:]
        else:
            command = command[4:]
    mapped_workdir = Path(map_guest_path(state, box, workdir))
    mapped_workdir.mkdir(parents=True, exist_ok=True)
    env = git_env(state, box)
    env.update(sb.get("env", {}))
    if "GH_TOKEN" in sb.get("secrets", {}): env["GH_TOKEN"] = r"$MSB_GH_TOKEN"

    wants_stdin = len(command) >= 2 and command[0] == "bash" and command[1] == "-s"
    stdin_data = sys.stdin.buffer.read() if wants_stdin else b""

    # Setup/bootstrap and deep-check scripts are exercised semantically by the simulator.
    if command[:2] == ["bash", "-s"] or command[:3] == ["bash", "-s", "--"]:
        text = stdin_data.decode("utf-8", errors="replace")
        if "Silo app listening-port probe" in text:
            configured = set(command[3:]) if command[:3] == ["bash", "-s", "--"] else set(command[2:])
            listening = set(sb.get("port_content", {}).keys())
            fixture = os.environ.get("SILO_FAKE_LISTENING_PORTS", "")
            if fixture:
                try:
                    listening.update(str(port) for port in json.loads(fixture).get(box, []))
                except (json.JSONDecodeError, AttributeError, TypeError):
                    return fail("invalid SILO_FAKE_LISTENING_PORTS", 64)
            for port in sorted(configured & listening, key=int):
                print(port)
            return 0
        if "Installing Ubuntu development packages" in text:
            sb["bootstrapped"] = True
            save(state)
            return 0
        if "hostnamectl set-hostname" in text and "silo-docker-smoke" in text:
            sb["configured"] = True
            save(state)
            return 0
        if "findmnt -n -o FSTYPE /workspace" in text and "docker buildx version" in text:
            if os.environ.get("SILO_FAKE_DEEP_CHECK_FAIL") == "1":
                print("Docker/containerd did not become ready within 30 seconds", file=sys.stderr)
                return 1
            return 0
        if "Silo named-volume migration" in text:
            source_name = sb.get("mounts", {}).get("/source")
            destination_name = sb.get("mounts", {}).get("/destination")
            if not source_name or not destination_name:
                return fail("volume migration mounts missing")
            source = volume_path(state, source_name)
            destination = volume_path(state, destination_name)
            for child in source.iterdir():
                target = destination / child.name
                if child.is_dir() and not child.is_symlink():
                    shutil.copytree(child, target, dirs_exist_ok=True, symlinks=True)
                elif child.is_symlink():
                    target.unlink(missing_ok=True)
                    target.symlink_to(os.readlink(child))
                else:
                    shutil.copy2(child, target)
            return 0

    # Simulate systemd-published direct web process.
    if command[:2] == ["bash", "-lc"] and len(command) >= 3 and "systemd-run" in command[2]:
        match = re.search(r"printf '%s\\n' '([^']+)'", command[2])
        sb.setdefault("port_content", {})["24678"] = match.group(1) if match else f"{box}-direct-ok"
        save(state)
        return 0

    if command[0] == "systemctl":
        # Delayed systemd-bus readiness: with SILO_FAKE_GUEST_READY_ATTEMPTS
        # set, the first N daemon-reload probes fail (the bootstrap readiness
        # wait discards this raw stderr), then the bus comes up. The probe
        # count is journaled on the sandbox so tests can prove guest
        # configuration ran only after readiness.
        if command[1:2] == ["daemon-reload"]:
            delay = os.environ.get("SILO_FAKE_GUEST_READY_ATTEMPTS", "")
            if delay:
                attempts = sb.setdefault("systemd_reload_attempts", 0) + 1
                sb["systemd_reload_attempts"] = attempts
                save(state)
                if attempts <= int(delay):
                    print("Failed to connect to bus: no such file or directory", file=sys.stderr)
                    return 1
        if "stop" in command and any("silo-health-direct" in x for x in command):
            sb.setdefault("port_content", {}).pop("24678", None)
            save(state)
        return 0

    if command[0] == "docker":
        if len(command) >= 2 and command[1] == "run":
            if "nginx:alpine" in command:
                sb.setdefault("port_content", {})["24679"] = "Welcome to nginx!"
            save(state)
            if "-d" in command: print("fake-container-id")
            return 0
        if len(command) >= 2 and command[1] == "rm":
            sb.setdefault("port_content", {}).pop("24679", None)
            save(state)
            return 0
        if len(command) >= 2 and command[1] in {"info", "version", "ps"}: return 0
        if len(command) >= 2 and command[1] == "compose":
            if "version" in command: print("Docker Compose version v2.fake")
            return 0
        if len(command) >= 2 and command[1] == "buildx": return 0
        if len(command) >= 2 and command[1] in {"system", "builder"}:
            log_event(state, "docker", box=box, args=command[1:])
            save(state)
            return 0

    # The guest relay (lib/silo-github-relay.py) is a REAL python script that
    # would bind host 127.0.0.1:18446 and collide with the proxy's listener.
    # Stub it as a bounded sleep so shuttle-spawned relay processes keep the
    # exec stream alive without ever touching the proxy port; the frame
    # protocol itself is exercised by the real relay in integration tests.
    # Faithful failure modes: an absent relay artifact fails exactly like
    # python3 (rc 2 + "can't open file ... No such file or directory") so the
    # shuttle's permanent-failure circuit can be exercised; while
    # SILO_FAKE_RELAY_FAIL_FILE exists the relay fails with a plain transient
    # error (rc 1, no ENOENT signature) so bounded retry can be exercised.
    if command[0] == "python3" and len(command) >= 2 and command[1].endswith("silo-github-relay.py"):
        relay_path = Path(map_guest_path(state, box, command[1]))
        fail_file = os.environ.get("SILO_FAKE_RELAY_FAIL_FILE", "")
        if fail_file and Path(fail_file).exists():
            if Path(fail_file).read_text().strip() == "enoent":
                # An ENOENT-flavored failure AFTER a passing precondition
                # probe: the artifact exists, so this is an unrelated runtime
                # error and must stay transient.
                return fail(
                    "python3: can't open file '%s': [Errno 2] No such file or directory" % relay_path,
                    2,
                )
            return fail("relay: transient transport failure", 1)
        if not relay_path.exists():
            return fail(
                "python3: can't open file '%s': [Errno 2] No such file or directory" % relay_path,
                2,
            )
        return subprocess.run(["python3", "-c", "import time; time.sleep(600)"],
                              cwd=mapped_workdir, env=env).returncode

    if command[0] == "fstrim":
        # Model the runtime's discard path: an EOF-reaching guest FITRIM on
        # a mounted raw disk either preserves the image length (safe) or
        # truncates it at the first free block of the final ext4 group
        # (unsafe, the msb-imago 0.1.1 defect).
        target = next((arg for arg in command[1:] if arg.startswith("/")), None)
        vol = (sb.get("mounts") or {}).get(target) if target else None
        if vol and TAIL_DISCARD == "unsafe":
            entry = state["volumes"].get(vol)
            raw = Path(entry["path"]) if entry else None
            declared = ext4_declared_bytes(raw) if raw and raw.is_file() else None
            if declared:
                with raw.open("r+b") as handle:
                    handle.truncate(declared - TAIL_DISCARD_DEFICIT)
        log_event(state, "guest-fstrim", box=box, target=target or "",
                  tail_discard=TAIL_DISCARD or "none")
        save(state)
        return 0

    if command[0] == "findmnt":
        # Attaching a raw image that is shorter than its ext4 superblock
        # fails (mount EINVAL): model the restart-mount probe against the
        # mounted volume's raw image.
        target = next((arg for arg in command[1:] if arg.startswith("/")), None)
        vol = (sb.get("mounts") or {}).get(target) if target else None
        entry = state["volumes"].get(vol) if vol else None
        raw = Path(entry["path"]) if entry else None
        declared = ext4_declared_bytes(raw) if raw and raw.is_file() else None
        if declared and raw.stat().st_size < declared:
            print(f"mount: {target}: the backing image is shorter than the filesystem it declares", file=sys.stderr)
            return 1
        print("ext4")
        return 0

    if command[0] in {"sync", "hostnamectl", "uname"}:
        if command[0] == "uname": print("aarch64")
        return 0

    # Map guest absolute paths passed as normal arguments.
    mapped = [command[0]] + [map_guest_path(state, box, x) if x.startswith("/") else x for x in command[1:]]
    # For shell command strings, replace only the guest roots used by Silo.
    if mapped[0] in {"bash", "sh"} and len(mapped) >= 3 and mapped[1] in {"-c", "-lc"}:
        script = mapped[2]
        # Map /tmp first so an absolute simulator workspace path below /tmp is
        # not remapped a second time after /workspace substitution.
        script = script.replace("/tmp/", str(Path(sb["root"]) / "tmp") + "/")
        script = script.replace("/workspace/", str(guest_workspace(state, box)) + "/")
        script = script.replace("/var/lib/silo-runtime/", str(guest_runtime(state, box)) + "/")
        # Test seam: model a guest without python3 (the shuttle's relay
        # precondition probes `command -v python3`).
        if os.environ.get("SILO_FAKE_GUEST_PYTHON_MISSING") == "1" and "command -v python3" in script:
            return fail("python3: command not found", 1)
        mapped[2] = script

    pause_file = os.environ.get("SILO_FAKE_VERIFY_PAUSE_FILE", "")
    pause_once = os.environ.get("SILO_FAKE_VERIFY_PAUSE_ONCE", "") == "1"
    pause_after_clone = bool(
        pause_file
        and command[:2] == ["bash", "-s"]
        and b"git -C" in stdin_data
        and b"clone" in stdin_data
    )

    try:
        proc = subprocess.run(mapped, cwd=mapped_workdir, env=env, input=stdin_data if stdin_data else None)
        if pause_after_clone:
            pause_path = Path(pause_file)
            pause_once_marker = Path(f"{pause_file}.once")
            if not pause_once or not pause_once_marker.exists():
                if pause_once:
                    pause_once_marker.write_text("paused")
                pause_path.write_text("ready")
                while pause_path.exists():
                    time.sleep(0.05)
        return proc.returncode
    except FileNotFoundError:
        return fail(f"fake guest command not found: {mapped[0]}", 127)


def advance_remote_for_race() -> None:
    remote = os.environ.get("SILO_FAKE_ADVANCE_REMOTE_ON_BUNDLE", "")
    ref = os.environ.get("SILO_FAKE_RACE_REF", "refs/heads/main")
    marker = os.environ.get("SILO_FAKE_RACE_ONCE_FILE", "")
    if not remote:
        return
    if marker and Path(marker).exists():
        return
    git_dir = Path(remote)
    old = subprocess.check_output(["git", "--git-dir", str(git_dir), "rev-parse", ref], text=True).strip()
    tree = subprocess.check_output(["git", "--git-dir", str(git_dir), "rev-parse", f"{old}^{{tree}}"], text=True).strip()
    env = os.environ.copy()
    env.update({
        "GIT_AUTHOR_NAME": "Silo Race Test",
        "GIT_AUTHOR_EMAIL": "race@example.invalid",
        "GIT_COMMITTER_NAME": "Silo Race Test",
        "GIT_COMMITTER_EMAIL": "race@example.invalid",
    })
    commit = subprocess.check_output(
        ["git", "--git-dir", str(git_dir), "commit-tree", tree, "-p", old, "-m", "simulated concurrent update"],
        text=True,
        env=env,
    ).strip()
    subprocess.run(["git", "--git-dir", str(git_dir), "update-ref", ref, commit, old], check=True)
    if marker:
        Path(marker).parent.mkdir(parents=True, exist_ok=True)
        Path(marker).write_text(commit + "\n")


def do_copy(args: list[str], state: dict[str, Any]) -> int:
    args = [a for a in args if a not in {"-q", "--quiet"}]
    if len(args) != 2:
        return fail("copy expects source and destination")
    src_raw, dst_raw = args
    if ":" in src_raw and src_raw.split(":", 1)[0] in state["sandboxes"]:
        box, raw = src_raw.split(":", 1)
        if not require_secret_source(state["sandboxes"][box]):
            return 1
        src = Path(map_guest_path(state, box, raw))
        dst = Path(dst_raw)
        dst.parent.mkdir(parents=True, exist_ok=True)
        if os.environ.get("SILO_FAKE_COPY_SYMLINK_LFS") == "1" and "/lfs/objects/" in str(src):
            dst.symlink_to("/etc/passwd")
            return 0
        if os.environ.get("SILO_FAKE_COPY_CORRUPT_LFS") == "1" and "/lfs/objects/" in str(src):
            dst.write_bytes(b"corrupt")
            return 0
        if src.is_dir():
            shutil.copytree(src, dst, dirs_exist_ok=True)
        else:
            shutil.copy2(src, dst)
        if src.suffix == ".bundle":
            advance_remote_for_race()
        return 0
    if ":" in dst_raw and dst_raw.split(":", 1)[0] in state["sandboxes"]:
        box, raw = dst_raw.split(":", 1)
        if not require_secret_source(state["sandboxes"][box]):
            return 1
        dst = Path(map_guest_path(state, box, raw))
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src_raw, dst)
        return 0
    return fail("fake copy requires one guest endpoint")


def main() -> int:
    args = sys.argv[1:]
    if not args:
        return fail("missing command", 64)
    state = load()
    if args[0] in {"--version", "version"}:
        print("microsandbox 0.6.9-fake")
        return 0
    cmd, rest = args[0], args[1:]
    record_secrets_lock_fd(cmd)
    if os.environ.get("SILO_FAKE_RECORD_CREDENTIAL_ENV") == "1":
        exported = [n for n in os.environ.get("SILO_SECRET_EXPORTED", "").split(",") if n]
        box = first_box_arg(rest) if cmd in {
            "start", "restart", "stop", "rm", "exec", "inspect", "ping",
            "logs", "modify", "copy", "cp", "ssh",
        } else ""
        sb = state["sandboxes"].get(box) if box else None
        bound = sorted((sb or {}).get("secrets", {}).keys())
        log_event(
            state,
            "credential-env",
            command=cmd,
            # Nonsecret command args (boxes, --secret NAME@HOSTS specs, flags)
            # so tests can observe the exact lifecycle-boundary invocation.
            args=rest,
            gh_token_present=bool(os.environ.get("GH_TOKEN")),
            secret_exported=exported,
            secret_resolved={n: bool(os.environ.get(n)) for n in exported},
            bound_env_present={n: bool(os.environ.get(n)) for n in bound},
        )
        save(state)
    if cmd == "doctor":
        if os.environ.get("SILO_FAKE_DOCTOR_FAIL") == "1" and "--fix" not in rest:
            return fail("fake doctor failure")
        return 0
    if cmd == "update":
        log_event(state, "update")
        save(state)
        return 0
    if cmd == "self" and rest[:1] == ["update"]:
        log_event(state, "self-update")
        save(state)
        return 0
    if cmd in {"create", "run"}: return parse_create(rest, state)
    if cmd == "inspect":
        box = rest[0] if rest else ""
        if os.environ.get("SILO_FAKE_INSPECT_FAIL") == "1":
            return fail("fake inspect failure", 2)
        if box in state["sandboxes"]:
            if not require_secret_source(state["sandboxes"][box]):
                return 1
            if "--format" in rest and rest[rest.index("--format") + 1:rest.index("--format") + 2] == ["json"]:
                tls_enabled = "--tls-intercept" in state["sandboxes"][box].get("args", [])
                secrets = []
                for name, spec in sorted(state["sandboxes"][box].get("secrets", {}).items()):
                    hosts = spec.split("@", 1)[1].split(",") if "@" in spec else []
                    secrets.append({
                        "env_var": name,
                        "allowed_hosts": ["any" if host == "*" else host for host in hosts],
                        "source": {"kind": "env", "var": name},
                    })
                network = {
                    "tls": {"enabled": tls_enabled},
                    "secrets": {"secrets": secrets},
                }
                print(json.dumps({
                    "active_config": {"network": network},
                    "config": {"network": network},
                }))
            return 0
        return fail(f"error: sandbox not found: {box}")
    if cmd == "ping":
        box = parse_named_arg(rest) or ""
        if os.environ.get("SILO_FAKE_PING_FAIL") == "1":
            return 1
        if box not in state["sandboxes"] or not require_secret_source(state["sandboxes"][box]):
            return 1
        return 0 if state["sandboxes"][box].get("running") else 1
    if cmd in {"start", "restart"}:
        box = parse_named_arg(rest) or ""
        if box not in state["sandboxes"]: return 1
        record_lock_fd()
        if os.environ.get("SILO_FAKE_START_FAIL") == "1":
            return fail("fake start failure")
        missing = [n for n in state["sandboxes"][box].get("secrets", {}) if not os.environ.get(n)]
        if missing:
            return fail("host source %s missing" % missing[0])
        state["sandboxes"][box]["running"] = True
        log_event(state, cmd, box=box)
        save(state)
        return 0
    if cmd == "stop":
        box = parse_named_arg(rest) or ""
        if box not in state["sandboxes"]: return 1
        if not require_secret_source(state["sandboxes"][box]):
            return 1
        if os.environ.get("SILO_FAKE_STOP_FAIL") == "1":
            return fail("fake stop failure")
        state["sandboxes"][box]["running"] = False
        log_event(state, "stop", box=box)
        save(state)
        return 0
    if cmd == "rm":
        box = parse_named_arg(rest) or ""
        if box not in state["sandboxes"]: return 1
        if not require_secret_source(state["sandboxes"][box]):
            return 1
        state["sandboxes"].pop(box, None)
        shutil.rmtree(STATE_ROOT / "guests" / box, ignore_errors=True)
        save(state)
        return 0
    if cmd == "volume":
        if not rest: return 1
        sub = rest[0]
        name = rest[1] if len(rest) > 1 else ""
        if sub == "inspect":
            if os.environ.get("SILO_FAKE_VOLUME_INSPECT_ERROR") == "1":
                print("error: volume registry unavailable", file=sys.stderr)
                return 2
            entry = state["volumes"].get(name)
            if entry is None:
                print(f"error: volume not found: {name}", file=sys.stderr)
                return 1
            print(f"Name:           {name}")
            print(f"Kind:           {entry.get('kind', 'disk')}")
            print("Format:         raw")
            print(f"Filesystem:     {entry.get('filesystem', 'ext4')}")
            print(f"Path:           {entry['path']}")
            print(f"Magic:          {entry.get('magic', '53ef')}")
            return 0
        if sub == "create":
            if not name or name in state["volumes"]:
                return 1
            size = ""
            if "--size" in rest and rest.index("--size") + 1 < len(rest):
                size = rest[rest.index("--size") + 1]
            path = STATE_ROOT / "volumes" / name
            path.mkdir(parents=True, exist_ok=True)
            volume_path = path
            if os.environ.get("SILO_FAKE_TRUNCATED_EXT4_CREATE") == "1":
                size_match = re.fullmatch(r"([0-9]+)G", size)
                if not size_match:
                    return fail("truncated ext4 fixture requires a GiB size")
                declared_bytes = int(size_match.group(1)) * 1024 * 1024 * 1024
                volume_path = (
                    Path(os.environ["HOME"]) / ".microsandbox" /
                    "volumes" / name / "disk.raw"
                )
                write_raw_ext4_image(volume_path, declared_bytes, declared_bytes - TAIL_DISCARD_DEFICIT)
            elif TAIL_DISCARD:
                size_match = re.fullmatch(r"([0-9]+)G", size)
                if not size_match:
                    return fail("tail-discard fixture requires a GiB size")
                declared_bytes = int(size_match.group(1)) * 1024 * 1024 * 1024
                volume_path = (
                    Path(os.environ["HOME"]) / ".microsandbox" /
                    "volumes" / name / "disk.raw"
                )
                write_raw_ext4_image(volume_path, declared_bytes, declared_bytes)
            state["volumes"][name] = {
                "path": str(volume_path), "size": size, "kind": "disk",
                "filesystem": "ext4", "magic": "53ef", "formatCount": 1,
            }
            log_event(state, "volume-create", volume=name, size=size, filesystem="ext4")
            save(state)
            return 0
        if sub == "rm":
            entry = state["volumes"].pop(name, None)
            if entry:
                path = Path(entry["path"])
                shutil.rmtree(path.parent if path.is_file() else path, ignore_errors=True)
            save(state); return 0
        if sub in {"ls", "list"}:
            print("\n".join(sorted(state["volumes"])))
            return 0
    if cmd == "snapshot":
        if not rest: return 1
        sub = rest[0]
        if sub == "inspect":
            name = rest[1] if len(rest) > 1 else ""
            if os.environ.get("SILO_FAKE_RESTORE_HEALTH_FAIL") == "1": return 1
            return 0 if name in state["snapshots"] else 1
        if sub == "create":
            name = rest[1]
            source = rest[rest.index("--from") + 1]
            if source not in state["sandboxes"] or state["sandboxes"][source].get("running"):
                return fail("snapshot source must be stopped")
            state["snapshots"][name] = {"from": source, "integrity": "--integrity" in rest}
            save(state); return 0
        if sub == "verify":
            name = rest[1]
            return 0 if name in state["snapshots"] else 1
        if sub == "rm":
            name = rest[1]; state["snapshots"].pop(name, None); save(state); return 0
        if sub == "reindex": return 0
        if sub in {"ls", "list"}:
            print("\n".join(sorted(state["snapshots"]))); return 0
    if cmd == "modify":
        box = rest[0] if rest else ""
        if box not in state["sandboxes"]: return 1
        sb = ensure_sandbox_dirs(state, box)
        if not require_secret_source(sb):
            return 1
        if "--secret" in rest:
            spec = rest[rest.index("--secret") + 1]
            name = spec.split("@", 1)[0]
            if not os.environ.get(name): return fail(f"host source {name} missing")
            state["sandboxes"][box].setdefault("secrets", {})[name] = spec
        if "--secret-rm" in rest:
            name = rest[rest.index("--secret-rm") + 1]
            if os.environ.get("SILO_FAKE_SECRET_REMOVE_FAIL") == "1":
                return fail("fake secret removal failure")
            state["sandboxes"][box].setdefault("secrets", {}).pop(name, None)
        for option, key in (("--memory", "memory"), ("--cpus", "cpus"), ("--root-disk", "root_disk")):
            if option in rest:
                state["sandboxes"][box][key] = rest[rest.index(option) + 1]
        log_event(state, "modify", box=box, args=rest)
        save(state); return 0
    if cmd == "exec": return parse_exec(rest, state)
    if cmd in {"copy", "cp"}: return do_copy(rest, state)
    if cmd == "ssh":
        if rest and rest[0] == "authorize":
            return 0
        if rest and rest[0] == "serve":
            box = rest[1] if len(rest) > 1 else ""
            if box in state["sandboxes"] and not require_secret_source(state["sandboxes"][box]):
                return 1
            return 0
    if cmd in {"ps", "ls", "status"}:
        if cmd == "status" and "--format" in rest and rest[rest.index("--format") + 1:rest.index("--format") + 2] == ["json"]:
            if os.environ.get("SILO_FAKE_STATUS_FAIL") == "1":
                return fail("fake status failure", 69)
            if "SILO_FAKE_STATUS_JSON" in os.environ:
                print(os.environ["SILO_FAKE_STATUS_JSON"])
                return 0
            names = [name for name in sorted(state["sandboxes"]) if name in rest]
            if not names:
                names = sorted(state["sandboxes"])
            print(json.dumps([
                {"name": name, "status": "Running" if state["sandboxes"][name].get("running") else "Stopped"}
                for name in names
            ]))
        else:
            for name, sb in sorted(state["sandboxes"].items()):
                print(f"{name}\t{'running' if sb.get('running') else 'stopped'}")
        return 0
    if cmd == "metrics":
        payload = os.environ.get("SILO_FAKE_METRICS", "")
        if payload:
            print(payload)
        return 0
    if cmd == "logs":
        box = rest[0] if rest else ""
        log_event(state, "logs", box=box, args=rest[1:])
        save(state)
        if os.environ.get("SILO_FAKE_LOGS_JSON_FAIL") == "1" and "--json" in rest:
            return 64
        payload = os.environ.get("SILO_FAKE_LOGS", "")
        if payload:
            print(payload)
        return 0
    return fail(f"fake msb: unsupported command: {cmd} {' '.join(rest)}")


if __name__ == "__main__":
    raise SystemExit(main())
