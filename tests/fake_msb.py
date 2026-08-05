#!/usr/bin/python3
"""Stateful MicroSandbox CLI simulator used by the MSW release tests."""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

STATE_ROOT = Path(os.environ.get("MSW_FAKE_STATE", "/tmp/msw-fake-state")).resolve()
STATE_FILE = STATE_ROOT / "state.json"
REMOTE_ROOT = os.environ.get("MSW_TEST_GITHUB_REMOTE_ROOT", "")


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


def volume_path(state: dict[str, Any], name: str) -> Path:
    entry = state["volumes"][name]
    p = Path(entry["path"])
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
    if raw == "/var/lib/msw-runtime":
        return str(guest_runtime(state, box))
    if raw.startswith("/var/lib/msw-runtime/"):
        return str(guest_runtime(state, box) / raw[len("/var/lib/msw-runtime/"):])
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
        "MSW_GUEST_WORKSPACE_ROOT": str(guest_workspace(state, box)),
        "GH_TOKEN": r"$MSB_GH_TOKEN",
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "GIT_TERMINAL_PROMPT": "0",
    })
    if os.environ.get("MSW_FAKE_GUEST_PUSH_ALLOWED") != "1":
        env["MSW_GUEST_READ_ONLY"] = "1"
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
    }
    for mount in mounts:
        parts = mount.split(":", 2)
        vol, dest = parts[0], parts[1]
        options = parts[2] if len(parts) > 2 else ""
        size_match = re.search(r"(?:^|,)size=([^,]+)", options)
        if vol not in state["volumes"]:
            p = STATE_ROOT / "volumes" / vol
            p.mkdir(parents=True, exist_ok=True)
            state["volumes"][vol] = {"path": str(p), "size": size_match.group(1) if size_match else ""}
        if dest == "/workspace": sb["workspace_volume"] = vol
        if dest == "/var/lib/msw-runtime": sb["runtime_volume"] = vol
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
        if arg in ("--no-tty", "-t", "--tty", "-q", "--quiet"):
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
    if i < len(args) and args[i] == "--": i += 1
    command = args[i:]
    if not command:
        return fail("missing exec command")
    sb = ensure_sandbox_dirs(state, box)
    sb["running"] = True
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
        if "Installing Ubuntu development packages" in text:
            sb["bootstrapped"] = True
            save(state)
            return 0
        if "hostnamectl set-hostname" in text and "msw-docker-smoke" in text:
            sb["configured"] = True
            save(state)
            return 0
        if "findmnt -n -o FSTYPE /workspace" in text and "docker buildx version" in text:
            return 0

    # Simulate systemd-published direct web process.
    if command[:2] == ["bash", "-lc"] and len(command) >= 3 and "systemd-run" in command[2]:
        match = re.search(r"printf '%s\\n' '([^']+)'", command[2])
        sb.setdefault("port_content", {})["24678"] = match.group(1) if match else f"{box}-direct-ok"
        save(state)
        return 0

    if command[0] == "systemctl":
        if "stop" in command and any("msw-health-direct" in x for x in command):
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

    if command[0] in {"sync", "hostnamectl", "findmnt", "uname"}:
        if command[0] == "uname": print("aarch64")
        elif command[0] == "findmnt": print("ext4")
        return 0

    # Map guest absolute paths passed as normal arguments.
    mapped = [command[0]] + [map_guest_path(state, box, x) if x.startswith("/") else x for x in command[1:]]
    # For shell command strings, replace only the guest roots used by MSW.
    if mapped[0] in {"bash", "sh"} and len(mapped) >= 3 and mapped[1] in {"-c", "-lc"}:
        script = mapped[2]
        # Map /tmp first so an absolute simulator workspace path below /tmp is
        # not remapped a second time after /workspace substitution.
        script = script.replace("/tmp/", str(Path(sb["root"]) / "tmp") + "/")
        script = script.replace("/workspace/", str(guest_workspace(state, box)) + "/")
        mapped[2] = script

    try:
        proc = subprocess.run(mapped, cwd=mapped_workdir, env=env, input=stdin_data if stdin_data else None)
        return proc.returncode
    except FileNotFoundError:
        return fail(f"fake guest command not found: {mapped[0]}", 127)


def advance_remote_for_race() -> None:
    remote = os.environ.get("MSW_FAKE_ADVANCE_REMOTE_ON_BUNDLE", "")
    ref = os.environ.get("MSW_FAKE_RACE_REF", "refs/heads/main")
    marker = os.environ.get("MSW_FAKE_RACE_ONCE_FILE", "")
    if not remote:
        return
    if marker and Path(marker).exists():
        return
    git_dir = Path(remote)
    old = subprocess.check_output(["git", "--git-dir", str(git_dir), "rev-parse", ref], text=True).strip()
    tree = subprocess.check_output(["git", "--git-dir", str(git_dir), "rev-parse", f"{old}^{{tree}}"], text=True).strip()
    env = os.environ.copy()
    env.update({
        "GIT_AUTHOR_NAME": "MSW Race Test",
        "GIT_AUTHOR_EMAIL": "race@example.invalid",
        "GIT_COMMITTER_NAME": "MSW Race Test",
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
        src = Path(map_guest_path(state, box, raw))
        dst = Path(dst_raw)
        dst.parent.mkdir(parents=True, exist_ok=True)
        if os.environ.get("MSW_FAKE_COPY_SYMLINK_LFS") == "1" and "/lfs/objects/" in str(src):
            dst.symlink_to("/etc/passwd")
            return 0
        if os.environ.get("MSW_FAKE_COPY_CORRUPT_LFS") == "1" and "/lfs/objects/" in str(src):
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
    if cmd == "doctor":
        if os.environ.get("MSW_FAKE_DOCTOR_FAIL") == "1" and "--fix" not in rest:
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
        return 0 if box in state["sandboxes"] else 1
    if cmd == "ping":
        box = parse_named_arg(rest) or ""
        return 0 if box in state["sandboxes"] and state["sandboxes"][box].get("running") else 1
    if cmd in {"start", "restart"}:
        box = parse_named_arg(rest) or ""
        if box not in state["sandboxes"]: return 1
        if state["sandboxes"][box].get("secrets", {}).get("GH_TOKEN") and not os.environ.get("GH_TOKEN"):
            return fail("host source GH_TOKEN missing")
        state["sandboxes"][box]["running"] = True
        log_event(state, cmd, box=box)
        save(state)
        return 0
    if cmd == "stop":
        box = parse_named_arg(rest) or ""
        if box not in state["sandboxes"]: return 1
        state["sandboxes"][box]["running"] = False
        log_event(state, "stop", box=box)
        save(state)
        return 0
    if cmd == "rm":
        box = parse_named_arg(rest) or ""
        state["sandboxes"].pop(box, None)
        shutil.rmtree(STATE_ROOT / "guests" / box, ignore_errors=True)
        save(state)
        return 0
    if cmd == "volume":
        if not rest: return 1
        sub = rest[0]
        name = rest[1] if len(rest) > 1 else ""
        if sub == "inspect": return 0 if name in state["volumes"] else 1
        if sub == "rm":
            entry = state["volumes"].pop(name, None)
            if entry: shutil.rmtree(entry["path"], ignore_errors=True)
            save(state); return 0
        if sub in {"ls", "list"}:
            print("\n".join(sorted(state["volumes"])))
            return 0
    if cmd == "snapshot":
        if not rest: return 1
        sub = rest[0]
        if sub == "inspect":
            name = rest[1] if len(rest) > 1 else ""
            if os.environ.get("MSW_FAKE_RESTORE_HEALTH_FAIL") == "1": return 1
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
        if "--secret" in rest:
            spec = rest[rest.index("--secret") + 1]
            name = spec.split("@", 1)[0]
            if not os.environ.get(name): return fail(f"host source {name} missing")
            state["sandboxes"][box].setdefault("secrets", {})[name] = spec
        if "--secret-rm" in rest:
            name = rest[rest.index("--secret-rm") + 1]
            if os.environ.get("MSW_FAKE_SECRET_REMOVE_FAIL") == "1":
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
        if rest and rest[0] == "serve": return 0
    if cmd in {"ps", "ls", "status"}:
        for name, sb in sorted(state["sandboxes"].items()):
            print(f"{name}\t{'running' if sb.get('running') else 'stopped'}")
        return 0
    if cmd in {"metrics", "logs"}: return 0
    return fail(f"fake msb: unsupported command: {cmd} {' '.join(rest)}")


if __name__ == "__main__":
    raise SystemExit(main())
