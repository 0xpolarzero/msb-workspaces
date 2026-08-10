#!/usr/bin/python3
"""Comprehensive release tests for MicroSandbox Workspaces.

The suite installs the package into a clean fake home, drives the real `msw`
CLI, uses a stateful MicroSandbox simulator, and uses real local Git/bare
repositories for clone, pull, bundle, push, force-with-lease, and LFS flows.
"""
from __future__ import annotations

import hashlib
import io
import json
import os
import re
import signal
import shutil
import stat
import time
import subprocess
import tarfile
import tempfile
import textwrap
import unittest
from pathlib import Path
from typing import Iterable

PACKAGE = Path(__file__).resolve().parents[1]
FAKE_MSB = PACKAGE / "tests" / "fake_msb.py"
FAKE_SSH = PACKAGE / "tests" / "fake_ssh.sh"
FAKE_CURL = PACKAGE / "tests" / "fake_curl.py"
FAKE_ZED = PACKAGE / "tests" / "fake_zed.sh"
FAKE_OPEN = PACKAGE / "tests" / "fake_open.sh"
FAKE_SECURITY = PACKAGE / "tests" / "fake_security.py"
SYSTEM_GIT = shutil.which("git") or "/usr/bin/git"
SYSTEM_TAR = shutil.which("gtar") or shutil.which("tar") or "/usr/bin/tar"
SYSTEM_ZSTD = shutil.which("zstd") or "/usr/bin/zstd"
SYSTEM_SHASUM = shutil.which("shasum") or "/usr/bin/shasum"


def run_cmd(
    args: Iterable[str | Path],
    *,
    env: dict[str, str] | None = None,
    cwd: str | Path | None = None,
    input_text: str | None = None,
    check: bool = True,
    timeout: int = 60,
) -> subprocess.CompletedProcess[str]:
    cmd = [str(x) for x in args]
    proc = subprocess.run(
        cmd,
        env=env,
        cwd=str(cwd) if cwd else None,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
    )
    if check and proc.returncode != 0:
        raise AssertionError(
            f"command failed ({proc.returncode}): {' '.join(cmd)}\n"
            f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
        )
    return proc


def rewrite_json_paths(value, old: str, new: str):
    if isinstance(value, dict):
        return {k: rewrite_json_paths(v, old, new) for k, v in value.items()}
    if isinstance(value, list):
        return [rewrite_json_paths(v, old, new) for v in value]
    if isinstance(value, str):
        return value.replace(old, new)
    return value


class ReleaseBase:
    root: Path
    home: Path
    env: dict[str, str]

    @classmethod
    def create(cls) -> None:
        cls.root = Path(tempfile.mkdtemp(prefix="msw-release-base-"))
        cls.home = cls.root / "home"
        cls.home.mkdir()
        (cls.root / "remotes").mkdir()
        (cls.root / "keychain").mkdir()
        cls.env = cls.make_env(cls.root, cls.home)
        proc = run_cmd([PACKAGE / "setup.sh"], env=cls.env, timeout=90)
        if "all live VM, Docker, SSH, internet, and published-port checks passed" not in proc.stdout:
            raise AssertionError(f"base setup did not complete deep checks:\n{proc.stdout}\n{proc.stderr}")

    @staticmethod
    def make_env(root: Path, home: Path) -> dict[str, str]:
        env = os.environ.copy()
        env.update(
            {
                "HOME": str(home),
                "MSW_TEST_MODE": "1",
                "MSW_TEST_HOST_CPUS": "12",
                "MSW_FAKE_STATE": str(home / ".microsandbox"),
                "MSW_MSB_BIN": str(FAKE_MSB),
                "MSW_SSH_BIN": str(FAKE_SSH),
                "MSW_CURL_BIN": str(FAKE_CURL),
                "MSW_OPEN_BIN": str(FAKE_OPEN),
                "MSW_ZED_BIN": str(FAKE_ZED),
                "MSW_TEST_KEYCHAIN_DIR": str(root / "keychain"),
                "MSW_TEST_GITHUB_REMOTE_ROOT": str(root / "remotes"),
                "MSW_GTAR_BIN": SYSTEM_TAR,
                "MSW_ZSTD_BIN": SYSTEM_ZSTD,
                "MSW_SHASUM_BIN": SYSTEM_SHASUM,
                "MSW_GIT_BIN": SYSTEM_GIT,
                "MSW_FAKE_LOG": str(root / "fake.log"),
                "MSW_ASSUME_YES": "1",
                "LC_ALL": "C",
                "LANG": "C",
            }
        )
        env["PATH"] = f"{home}/.local/bin:{env.get('PATH', '/usr/bin:/bin')}"
        return env

    @classmethod
    def clone(cls, label: str) -> "TestEnv":
        root = Path(tempfile.mkdtemp(prefix=f"msw-{label}-"))
        home = root / "home"
        shutil.copytree(cls.home, home, symlinks=True)
        (root / "remotes").mkdir()
        (root / "keychain").mkdir()
        (root / "tools").mkdir()

        state_file = home / ".microsandbox" / "state.json"
        state = json.loads(state_file.read_text())
        state = rewrite_json_paths(state, str(cls.root), str(root))
        state_file.write_text(json.dumps(state, indent=2, sort_keys=True))

        env = cls.make_env(root, home)
        test_env = TestEnv(root, home, env)
        test_env.msw("host", "repair")
        return test_env


class TestEnv:
    def __init__(self, root: Path, home: Path, env: dict[str, str]):
        self.root = root
        self.home = home
        self.env = env
        self.msw_bin = home / ".local" / "bin" / "msw"

    def cleanup(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)

    def run(self, *args: str | Path, check: bool = True, input_text: str | None = None,
            extra_env: dict[str, str] | None = None, timeout: int = 60) -> subprocess.CompletedProcess[str]:
        env = self.env.copy()
        if extra_env:
            env.update(extra_env)
        return run_cmd(args, env=env, input_text=input_text, check=check, timeout=timeout)

    def msw(self, *args: str, check: bool = True, input_text: str | None = None,
            extra_env: dict[str, str] | None = None, timeout: int = 60) -> subprocess.CompletedProcess[str]:
        return self.run(self.msw_bin, *args, check=check, input_text=input_text,
                        extra_env=extra_env, timeout=timeout)

    def setup(self, *args: str, check: bool = True,
              extra_env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        return self.run(PACKAGE / "setup.sh", *args, check=check, extra_env=extra_env, timeout=90)

    @property
    def state_file(self) -> Path:
        return self.home / ".microsandbox" / "state.json"

    def state(self) -> dict:
        return json.loads(self.state_file.read_text())

    def workspace(self, box: str) -> Path:
        state = self.state()
        vol = state["sandboxes"][box]["workspace_volume"]
        return Path(state["volumes"][vol]["path"])

    def runtime(self, box: str) -> Path:
        state = self.state()
        vol = state["sandboxes"][box]["runtime_volume"]
        return Path(state["volumes"][vol]["path"])

    def guest_repo(self, box: str, relative: str) -> Path:
        return self.workspace(box) / relative

    def key_file(self, service: str, box: str) -> Path:
        safe = lambda s: re.sub(r"[^A-Za-z0-9_.-]", "_", s)
        return self.root / "keychain" / f"{safe(service)}__{safe(box)}"

    def configure_tokens(self, box: str, repo: str, *, read: str | None = None,
                         write: str | None = None, extra_env: dict[str, str] | None = None,
                         check: bool = True) -> subprocess.CompletedProcess[str]:
        read = read or f"github_pat_READ_{box}_abcdefghijklmnopqrstuvwxyz0123456789"
        write = write or f"github_pat_WRITE_{box}_abcdefghijklmnopqrstuvwxyz0123456789"
        env = {
            "MSW_GITHUB_READ_TOKEN_INPUT": read,
            "MSW_GITHUB_WRITE_TOKEN_INPUT": write,
        }
        if extra_env:
            env.update(extra_env)
        return self.msw("github", "setup", box, repo, extra_env=env, check=check, timeout=90)
    def configure_read_only(self, box: str, repo: str, *, read: str | None = None,
                            extra_env: dict[str, str] | None = None,
                            check: bool = True) -> subprocess.CompletedProcess[str]:
        read = read or f"github_pat_READ_{box}_abcdefghijklmnopqrstuvwxyz0123456789"
        env = {"MSW_GITHUB_READ_TOKEN_INPUT": read}
        if extra_env:
            env.update(extra_env)
        return self.msw("github", "setup", box, repo, "--read-only",
                        extra_env=env, check=check, timeout=90)

    def init_remote(self, owner: str = "acme", repo: str = "demo", *, files: dict[str, str] | None = None) -> Path:
        bare = self.root / "remotes" / owner / f"{repo}.git"
        bare.parent.mkdir(parents=True, exist_ok=True)
        run_cmd([SYSTEM_GIT, "init", "--bare", str(bare)], env=self.env)
        seed = self.root / f"seed-{owner}-{repo}"
        run_cmd([SYSTEM_GIT, "init", "-b", "main", str(seed)], env=self.env)
        run_cmd([SYSTEM_GIT, "-C", str(seed), "config", "user.name", "Seed"], env=self.env)
        run_cmd([SYSTEM_GIT, "-C", str(seed), "config", "user.email", "seed@example.invalid"], env=self.env)
        for name, content in (files or {"README.md": "initial\n"}).items():
            target = seed / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)
        run_cmd([SYSTEM_GIT, "-C", str(seed), "add", "."], env=self.env)
        run_cmd([SYSTEM_GIT, "-C", str(seed), "commit", "-m", "Initial"], env=self.env)
        run_cmd([SYSTEM_GIT, "-C", str(seed), "remote", "add", "origin", str(bare)], env=self.env)
        run_cmd([SYSTEM_GIT, "-C", str(seed), "push", "-u", "origin", "main"], env=self.env)
        run_cmd([SYSTEM_GIT, "--git-dir", str(bare), "symbolic-ref", "HEAD", "refs/heads/main"], env=self.env)
        hook = bare / "hooks" / "pre-receive"
        hook.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "if [ \"${MSW_GUEST_READ_ONLY:-}\" = 1 ]; then echo 'guest token is read-only' >&2; exit 1; fi\n"
            "if [ -f deny-host ]; then echo 'host push denied for test' >&2; exit 1; fi\n"
            "cat >/dev/null\n"
        )
        hook.chmod(0o755)
        return bare

    def git(self, repo: Path, *args: str, check: bool = True, extra_env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        env = self.env.copy()
        env.update(
            {
                "HOME": str(self.state()["sandboxes"]["dev"]["root"] + "/home"),
                "MSW_GUEST_READ_ONLY": "1",
                "GIT_TERMINAL_PROMPT": "0",
            }
        )
        if extra_env:
            env.update(extra_env)
        return run_cmd([SYSTEM_GIT, "-C", repo, *args], env=env, check=check)

    def install_fake_git_lfs(self) -> Path:
        log = self.root / "git-lfs.log"
        tool = self.root / "tools" / "git-lfs"
        tool.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            f"log={str(log)!r}\n"
            "printf 'git-lfs %s\\n' \"$*\" >>\"$log\"\n"
            "cat >>\"$log\" || true\n"
            "exit 0\n"
        )
        tool.chmod(0o755)
        self.env["PATH"] = f"{self.root}/tools:{self.env['PATH']}"
        return log


class MSWTestCase(unittest.TestCase):
    env: TestEnv

    def setUp(self) -> None:
        self.env = ReleaseBase.clone(self._testMethodName)

    def tearDown(self) -> None:
        self.env.cleanup()

    def assertFailed(self, proc: subprocess.CompletedProcess[str], text: str | None = None) -> None:
        self.assertNotEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        if text:
            self.assertIn(text, proc.stdout + proc.stderr)


class SyntaxAndStaticTests(MSWTestCase):
    def test_shell_python_syntax_and_port_config(self) -> None:
        for script in [PACKAGE / "setup.sh", PACKAGE / "bin/msw", PACKAGE / "lib/bootstrap-base.sh"]:
            run_cmd(["bash", "-n", script])
        for script in [PACKAGE / "bin/msw-ssh-proxy", PACKAGE / "bin/msw-git-askpass"]:
            run_cmd(["sh", "-n", script])
        run_cmd(["/usr/bin/python3", "-m", "py_compile", FAKE_MSB, FAKE_CURL, FAKE_SECURITY])
        config = (PACKAGE / "config.sh").read_text()
        self.assertIn("24678-24679", config)
        self.assertIn("3000-3010", config)
        self.assertIn("5173-5180", config)
        self.assertIn('MSW_GITHUB_SECRET_HOSTS="github.com,api.github.com"', config)
        self.assertNotIn("githubusercontent", config)
        self.assertNotRegex((PACKAGE / "bin/msw").read_text(), r"(?:declare|local) -A|mapfile|readarray")
        docs = "\n".join(
            (PACKAGE / name).read_text()
            for name in [
                "README.md",
                "docs/SETUP-GUIDE.md",
                "docs/GITHUB-SETUP.md",
                "docs/MSW-CHEATSHEET.md",
            ]
        )
        for stale in ("msw auth", "msw selftest", "--skip-update"):
            self.assertNotIn(stale, docs)
        self.assertIn("msw github setup dev", docs)
        self.assertIn("msw push dev", docs)
        self.assertIn("msw backup", docs)

    def test_static_security_invariants(self) -> None:
        msw = (PACKAGE / "bin/msw").read_text()
        setup = (PACKAGE / "setup.sh").read_text()
        proxy = (PACKAGE / "bin/msw-ssh-proxy").read_text()
        self.assertIn('"$MSB_BIN" run --detach', setup)
        self.assertIn("-- sleep infinity", setup)
        self.assertIn("wait_for_guest_systemd", setup)
        self.assertIn("--tls-intercept", setup)
        self.assertIn('--secret "GH_TOKEN@${MSW_GITHUB_SECRET_HOSTS}" --restart', msw)
        self.assertIn("--secret-rm GH_TOKEN --restart", msw)
        self.assertIn("env -i", msw)
        self.assertIn("GIT_CONFIG_NOSYSTEM=1", msw)
        self.assertIn("GIT_CONFIG_GLOBAL=/dev/null", msw)
        self.assertIn("--force-with-lease=$ref:$remote_sha", msw)
        self.assertIn("failed SHA-256 verification", msw)
        self.assertIn('"$LOCKF_BIN" -s -t 0 9', msw)
        self.assertIn('"$MSB_BIN" "$@" 9>&-', msw)
        self.assertIn("MSW_GITHUB_VERIFY_INHERITED=1", msw)
        self.assertNotIn("tar -x", msw[msw.index("copy_lfs_objects"):msw.index("cmd_github_setup")])
        self.assertNotIn("ForwardAgent", setup + proxy)
        self.assertNotIn("/var/run/docker.sock", setup)
        self.assertIn('--secret "GH_TOKEN@${MSW_GITHUB_SECRET_HOSTS}"', msw + setup)
        push_body = msw[msw.index("push_impl()") : msw.index("cmd_push()")]
        self.assertNotIn("write_token_for_workspace", push_body)
        bootstrap = (PACKAGE / "lib/bootstrap-base.sh").read_text()
        self.assertIn("url.https://github.com/.insteadOf", bootstrap)
        self.assertIn("gh config set git_protocol https", bootstrap)
        self.assertIn('"$MSB_BIN" self update', msw)
    def test_askpass_uses_login_keychain_with_isolated_git_home(self) -> None:
        state_path = self.env.root / "askpass-security.json"
        service = "msw.github.write"
        account = "dev"
        value = "diagnostic-write-token"
        security_env = self.env.env.copy()
        security_env.update({
            "MSW_FAKE_SECURITY_STATE": str(state_path),
            "MSW_SECURITY_BIN": str(FAKE_SECURITY),
        })
        run_cmd(
            [FAKE_SECURITY, "add-generic-password", "-s", service, "-a", account, "-w", value],
            env=security_env,
        )
        isolated_home = self.env.root / "isolated-home"
        isolated_home.mkdir()
        askpass_env = security_env.copy()
        askpass_env.update({
            "HOME": str(isolated_home),
            "MSW_TEST_KEYCHAIN_DIR": "",
            "MSW_KEYCHAIN_SERVICE": service,
            "MSW_KEYCHAIN_ACCOUNT": account,
            "MSW_KEYCHAIN_HOME": str(self.env.home),
            "MSW_FAKE_SECURITY_HOME": str(self.env.home),
        })
        proc = run_cmd(
            [PACKAGE / "bin/msw-git-askpass", "Password for https://github.com:"],
            env=askpass_env,
        )
        self.assertEqual(proc.stdout, value + "\n")


class InstallerAndDailyTests(MSWTestCase):
    def test_fresh_install_state_resources_volumes_and_ports(self) -> None:
        state = self.env.state()
        self.assertEqual(set(state["sandboxes"]), {"dev", "playgrounds", "personal"})
        self.assertEqual(set(state["volumes"]), {
            "msw-dev-workspace", "msw-dev-runtime",
            "msw-playgrounds-workspace", "msw-playgrounds-runtime",
            "msw-personal-workspace", "msw-personal-runtime",
        })
        self.assertEqual(set(state["snapshots"]), {"msw-base-v1"})
        self.assertTrue(state["snapshots"]["msw-base-v1"]["integrity"])
        expected_memory = {
            "dev": ("32G", "48G"),
            "playgrounds": ("32G", "48G"),
            "personal": ("16G", "32G"),
        }
        for box, ip in (("dev", "127.0.0.10"), ("playgrounds", "127.0.0.11"), ("personal", "127.0.0.12")):
            sb = state["sandboxes"][box]
            self.assertFalse(sb["running"])
            self.assertTrue(sb["configured"])
            self.assertIn(f"{ip}:3000:3000", sb["ports"])
            self.assertIn(f"{ip}:5173:5173", sb["ports"])
            self.assertIn(f"{ip}:24678:24678", sb["ports"])
            self.assertIn(f"{ip}:24679:24679", sb["ports"])
            self.assertEqual(sb["labels"]["msw.managed"], "true")
            args = sb["args"]
            self.assertEqual(args[args.index("--memory") + 1], expected_memory[box][0])
            self.assertEqual(args[args.index("--max-memory") + 1], expected_memory[box][1])

    def test_setup_is_idempotent(self) -> None:
        before = self.env.state()
        before_create = sum(e["event"] == "create" for e in before["events"])
        proc = self.env.setup()
        self.assertIn("Using existing base snapshot", proc.stdout)
        after = self.env.state()
        after_create = sum(e["event"] == "create" for e in after["events"])
        self.assertEqual(before_create, after_create)
        self.assertEqual(set(before["volumes"]), set(after["volumes"]))

    def test_recreate_github_workspace_rebinds_secret_from_keychain(self) -> None:
        self.env.init_remote()
        self.env.configure_tokens("dev", "acme/demo")
        proc = self.env.setup("--recreate-workspaces", extra_env={"MSW_FAKE_REQUIRE_SECRET_SOURCE": "1"})
        self.assertNotIn("host source GH_TOKEN missing", proc.stdout + proc.stderr)
        state = self.env.state()
        self.assertIn("GH_TOKEN", state["sandboxes"]["dev"]["secrets"])
        self.assertFalse(state["sandboxes"]["dev"]["running"])

    def _seed_volume_sentinels(self) -> None:
        (self.env.workspace("dev") / "repo-sentinel").write_text("workspace")
        (self.env.runtime("dev") / "docker-sentinel").write_text("runtime")

    def _assert_volume_sentinels(self) -> None:
        self.assertEqual((self.env.workspace("dev") / "repo-sentinel").read_text(), "workspace")
        self.assertEqual((self.env.runtime("dev") / "docker-sentinel").read_text(), "runtime")

    def test_recreate_workspaces_preserves_both_data_volumes(self) -> None:
        self._seed_volume_sentinels()
        before_creates = sum(e["event"] == "create" for e in self.env.state()["events"])
        self.env.setup("--recreate-workspaces")
        self._assert_volume_sentinels()
        after_creates = sum(e["event"] == "create" for e in self.env.state()["events"])
        self.assertEqual(after_creates - before_creates, 3)

    def test_version_migration_rebuilds_roots_and_preserves_both_data_volumes(self) -> None:
        self._seed_volume_sentinels()
        (self.env.home / ".config/msw/base-version").write_text("0.0.0\n")
        self.env.setup()
        self._assert_volume_sentinels()
        self.assertEqual((self.env.home / ".config/msw/base-version").read_text().strip(), "3.1.0")

    def test_reset_config_and_rebuild_base(self) -> None:
        config = self.env.home / ".config/msw/config.sh"
        config.write_text(config.read_text().replace("dev.msw.test", "broken.invalid"))
        self.env.setup("--reset-config", "--rebuild-base")
        self.assertIn("dev.msw.test", config.read_text())
        state = self.env.state()
        self.assertTrue(state["snapshots"]["msw-base-v1"]["integrity"])

    def test_urls_open_zed_shell_and_tunnel(self) -> None:
        self.assertEqual(self.env.msw("url", "dev", "3000").stdout.strip(), "http://dev.msw.test:3000")
        self.env.msw("open", "personal", "5173")
        self.env.msw("zed", "playgrounds", "nested/app")
        self.env.msw("dev", "nested/app")
        self.env.msw("tunnel", "dev", "12345", "12346")
        for bad in ("0", "65536", "not-a-port"):
            self.assertFailed(self.env.msw("tunnel", "dev", bad, check=False), "port")
        self.assertFailed(self.env.msw("tunnel", "dev", "3000", "65536", check=False), "local port")
        log = (self.env.root / "fake.log").read_text()
        self.assertIn("open http://personal.msw.test:5173", log)
        self.assertIn("zed ssh://root@playgrounds.msb/workspace/nested/app", log)
        self.assertIn("ssh -t dev.msb", log)
        self.assertIn("-L 12346:127.0.0.1:12345", log)
        self.assertFailed(self.env.msw("url", "dev", "9999", check=False), "not pre-published")

    def test_clean_preserves_volumes_unless_explicitly_requested(self) -> None:
        before = len(self.env.state()["events"])
        self.env.msw("clean", "dev")
        first = self.env.state()["events"][before:]
        system_prunes = [e["args"] for e in first if e["event"] == "docker" and e["args"][:2] == ["system", "prune"]]
        self.assertEqual(system_prunes, [["system", "prune", "-af"]])

        before = len(self.env.state()["events"])
        self.env.msw("clean", "dev", "--volumes")
        second = self.env.state()["events"][before:]
        system_prunes = [e["args"] for e in second if e["event"] == "docker" and e["args"][:2] == ["system", "prune"]]
        self.assertEqual(system_prunes, [["system", "prune", "-af", "--volumes"]])
        self.assertFailed(self.env.msw("clean", "dev", "personal", check=False), "only one cleanup target")

    def test_update_uses_supported_self_update_flow(self) -> None:
        before = len(self.env.state().get("events", []))
        proc = self.env.msw("update")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        events = self.env.state().get("events", [])[before:]
        self.assertTrue(any(event.get("event") == "self-update" for event in events), events)

    def test_app_bootstrap_runs_deep_verification_and_restores_running_set(self) -> None:
        self.env.msw("start", "dev")
        before = {
            box: self.env.state()["sandboxes"][box]["running"]
            for box in ("dev", "playgrounds", "personal")
        }
        proc = self.env.msw("app", "bootstrap", "--resume", "--format", "json", timeout=90)
        envelope = json.loads(proc.stdout)
        self.assertTrue(envelope["ok"])
        self.assertEqual(envelope["result"]["phase"], "complete")
        self.assertFalse(envelope["result"]["requiresApproval"])
        self.assertTrue(envelope["result"]["vmsStarted"])
        after = {
            box: self.env.state()["sandboxes"][box]["running"]
            for box in ("dev", "playgrounds", "personal")
        }
        self.assertEqual(after, before)

    def test_lifecycle_resize_restart_token_guard_and_proxy(self) -> None:
        self.env.msw("start", "dev")
        self.assertTrue(self.env.state()["sandboxes"]["dev"]["running"])
        self.env.msw("resize", "dev", "32G", "10")
        self.assertEqual(self.env.state()["sandboxes"]["dev"]["memory"], "32G")
        self.assertEqual(self.env.state()["sandboxes"]["dev"]["cpus"], "10")
        self.env.msw("stop", "dev")
        self.assertFalse(self.env.state()["sandboxes"]["dev"]["running"])
        meta = self.env.home / ".config/msw/github/dev.conf"
        meta.parent.mkdir(parents=True, exist_ok=True)
        meta.write_text("verification_repo=acme/demo\n")
        self.assertFailed(self.env.msw("restart", "dev", check=False), "read token is missing")
        proxy = self.env.home / ".local/bin/msw-ssh-proxy"
        self.assertFailed(self.env.run(proxy, "dev.msb", check=False), "read token is missing")
        meta.unlink()
        self.env.run(proxy, "dev.msb")
        self.assertTrue(self.env.state()["sandboxes"]["dev"]["running"])

    def test_nested_clone_direct_inside_repo_listing_identity_and_pull(self) -> None:
        bare = self.env.init_remote()
        self.env.configure_tokens("dev", "acme/demo")
        self.env.msw("clone", "dev", "acme/demo", "clients/acme/backend")
        self.assertTrue((self.env.guest_repo("dev", "clients/acme/backend") / ".git").is_dir())
        self.assertIn("clients/acme/backend", self.env.msw("repos", "dev").stdout)
        self.env.msw("identity", "Alice Example", "alice@example.invalid", "dev")
        repo = self.env.guest_repo("dev", "clients/acme/backend")
        self.assertEqual(self.env.git(repo, "config", "user.name").stdout.strip(), "Alice Example")

        updater = self.env.root / "updater"
        run_cmd([SYSTEM_GIT, "clone", str(bare), str(updater)], env=self.env.env)
        run_cmd([SYSTEM_GIT, "-C", updater, "config", "user.name", "Updater"], env=self.env.env)
        run_cmd([SYSTEM_GIT, "-C", updater, "config", "user.email", "updater@example.invalid"], env=self.env.env)
        (updater / "remote.txt").write_text("remote\n")
        run_cmd([SYSTEM_GIT, "-C", updater, "add", "remote.txt"], env=self.env.env)
        run_cmd([SYSTEM_GIT, "-C", updater, "commit", "-m", "Remote update"], env=self.env.env)
        run_cmd([SYSTEM_GIT, "-C", updater, "push", "origin", "main"], env=self.env.env)

        self.env.msw("pull", "dev", "clients/acme/backend")
        self.assertEqual((repo / "remote.txt").read_text(), "remote\n")

        # The user can also clone directly from an interactive/exec shell.
        self.env.msw("exec", "dev", "bash", "-lc", "mkdir -p /workspace/direct && cd /workspace/direct && git clone https://github.com/acme/demo.git second")
        self.assertTrue((self.env.guest_repo("dev", "direct/second") / ".git").is_dir())

    def test_path_containment_and_duplicate_destination(self) -> None:
        self.env.init_remote()
        self.env.configure_tokens("dev", "acme/demo")
        for bad in ("../escape", "/absolute", "a//b", "a/./b", "a/../b"):
            self.assertFailed(self.env.msw("clone", "dev", "acme/demo", bad, check=False), "path")
        self.env.msw("clone", "dev", "acme/demo", "safe/repo")
        self.assertFailed(self.env.msw("clone", "dev", "acme/demo", "safe/repo", check=False), "already exists")
        outside = self.env.root / "outside"
        outside.mkdir()
        (self.env.workspace("dev") / "link").symlink_to(outside)
        self.assertFailed(self.env.msw("push", "dev", "link", "--yes", check=False), "escapes /workspace")


class GitHubAndPushTests(MSWTestCase):
    def prepare(self, *, box: str = "dev", nested: str = "clients/acme/demo") -> tuple[Path, Path]:
        bare = self.env.init_remote()
        self.env.configure_tokens(box, "acme/demo")
        self.env.msw("clone", box, "acme/demo", nested)
        repo = self.env.guest_repo(box, nested)
        self.env.git(repo, "config", "user.name", "Agent")
        self.env.git(repo, "config", "user.email", "agent@example.invalid")
        return bare, repo

    def test_github_setup_rejects_disabled_tls_before_token_prompt(self) -> None:
        state = self.env.state()
        state["sandboxes"]["dev"]["args"] = [
            arg for arg in state["sandboxes"]["dev"]["args"] if arg != "--tls-intercept"
        ]
        self.env.state_file.write_text(json.dumps(state, indent=2, sort_keys=True))
        proc = self.env.configure_tokens("dev", "acme/demo", check=False)
        output = proc.stdout + proc.stderr
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("TLS interception disabled", output)
        self.assertIn("./setup.sh --recreate-workspaces", output)
        self.assertNotIn("Paste the READ-ONLY token:", output)
        self.assertFalse(self.env.key_file("msw.github.read", "dev").exists())
        self.assertFalse(self.env.key_file("msw.github.write", "dev").exists())
    def test_github_setup_rejects_empty_verification_repository(self) -> None:
        bare = self.env.root / "remotes" / "acme" / "empty.git"
        bare.parent.mkdir(parents=True, exist_ok=True)
        run_cmd([SYSTEM_GIT, "init", "--bare", str(bare)], env=self.env.env)

        proc = self.env.configure_tokens("dev", "acme/empty", check=False)
        output = proc.stdout + proc.stderr
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("has no branches", output)
        self.assertIn("initialize main", output)
        self.assertNotIn("Verifying the host-only push path", output)
        refs = run_cmd(
            [SYSTEM_GIT, "--git-dir", str(bare), "for-each-ref", "--format=%(refname)", "refs/heads"],
            env=self.env.env,
        ).stdout
        self.assertEqual(refs.strip(), "")
        self.assertFalse(self.env.key_file("msw.github.read", "dev").exists())
        self.assertFalse(self.env.key_file("msw.github.write", "dev").exists())

    def test_github_setup_end_to_end_secret_hidden_and_remove(self) -> None:
        bare = self.env.init_remote()
        proc = self.env.configure_tokens("dev", "acme/demo")
        self.assertIn("guest push rejected", proc.stdout)
        self.assertIn("host push and cleanup succeeded", proc.stdout)
        refs = run_cmd([SYSTEM_GIT, "--git-dir", bare, "for-each-ref", "--format=%(refname)", "refs/heads/msw-permission-test-*"], env=self.env.env).stdout
        self.assertEqual(refs.strip(), "")
        state_text = self.env.state_file.read_text()
        self.assertNotIn("github_pat_READ", state_text)
        self.assertNotIn("github_pat_WRITE", state_text)
        self.assertEqual(self.env.state()["sandboxes"]["dev"]["secrets"]["GH_TOKEN"], "GH_TOKEN@github.com,api.github.com")
        status_out = self.env.msw("github", "status", "dev").stdout
        self.assertIn("present", status_out)
        self.env.msw("github", "remove", "dev")
        self.assertFalse(self.env.key_file("msw.github.read", "dev").exists())
        self.assertFalse(self.env.key_file("msw.github.write", "dev").exists())
        self.assertNotIn("GH_TOKEN", self.env.state()["sandboxes"]["dev"]["secrets"])

    def test_github_setup_preserves_secret_source_for_verifier_cli(self) -> None:
        self.env.init_remote()
        marker = self.env.root / "lock-fd.marker"
        proc = self.env.configure_tokens(
            "dev",
            "acme/demo",
            extra_env={
                "MSW_FAKE_REQUIRE_SECRET_SOURCE": "1",
                "MSW_FAKE_LOCK_FD_MARKER": str(marker),
            },
        )
        self.assertIn("GitHub configured for dev", proc.stdout)
        self.assertIn("guest push rejected", proc.stdout)
        self.assertIn("host push and cleanup succeeded", proc.stdout)
        self.assertEqual(marker.read_text().strip(), "closed")

    def test_github_secret_source_survives_fresh_clone_exec_and_remove(self) -> None:
        self.env.init_remote()
        self.env.configure_tokens("dev", "acme/demo")
        guard = {"MSW_FAKE_REQUIRE_SECRET_SOURCE": "1"}

        self.env.msw("clone", "dev", "acme/demo", "fresh/repo", extra_env=guard)
        self.assertTrue(self.env.guest_repo("dev", "fresh/repo").joinpath(".git").is_dir())
        self.env.msw("exec", "dev", "true", extra_env=guard)
        self.env.run(self.env.home / ".local/bin/msw-ssh-proxy", "dev.msb", extra_env=guard)
        self.env.msw("github", "remove", "dev", extra_env=guard)

        self.assertFalse(self.env.key_file("msw.github.read", "dev").exists())
        self.assertFalse(self.env.key_file("msw.github.write", "dev").exists())
        self.assertNotIn("GH_TOKEN", self.env.state()["sandboxes"]["dev"]["secrets"])

    def test_stale_github_lock_is_reclaimed(self) -> None:
        self.env.init_remote()
        stale_lock = self.env.home / ".config/msw/github/dev.lock"
        stale_lock.mkdir(parents=True)
        (stale_lock / "pid").write_text("99999999\n")

        configured = self.env.configure_tokens("dev", "acme/demo")
        self.assertIn("GitHub configured for dev", configured.stdout)
        self.assertTrue(stale_lock.is_file())

        self.env.msw("github", "remove", "dev")
        stale_lock.unlink()
        stale_lock.mkdir()
        configured = self.env.configure_tokens("dev", "acme/demo")
        self.assertIn("GitHub configured for dev", configured.stdout)
        self.assertTrue(stale_lock.is_file())

    def test_verification_lock_blocks_remove_until_sigkill(self) -> None:
        self.env.init_remote()
        self.env.configure_tokens("dev", "acme/demo")
        pause_file = self.env.root / "verify-lock.ready"
        env = self.env.env.copy()
        env["MSW_FAKE_VERIFY_PAUSE_FILE"] = str(pause_file)
        proc = subprocess.Popen(
            [str(self.env.msw_bin), "github", "verify", "dev"],
            env=env,
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        try:
            for _ in range(100):
                if pause_file.exists():
                    break
                time.sleep(0.05)
            else:
                self.fail("verification did not reach the injected pause")
            blocked = self.env.msw("github", "remove", "dev", check=False)
            self.assertFailed(blocked, "already in progress")
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=15)
        finally:
            pause_file.unlink(missing_ok=True)
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait(timeout=5)
        self.env.msw("github", "remove", "dev")

    def test_orphaned_setup_verifier_keeps_remove_locked_after_parent_sigkill(self) -> None:
        self.env.init_remote()
        pause_file = self.env.root / "orphaned-verify.ready"
        env = self.env.env.copy()
        env.update(
            {
                "MSW_GITHUB_READ_TOKEN_INPUT": "github_pat_READ_dev_abcdefghijklmnopqrstuvwxyz0123456789",
                "MSW_GITHUB_WRITE_TOKEN_INPUT": "github_pat_WRITE_dev_abcdefghijklmnopqrstuvwxyz0123456789",
                "MSW_FAKE_VERIFY_PAUSE_FILE": str(pause_file),
            }
        )
        proc = subprocess.Popen(
            [str(self.env.msw_bin), "github", "setup", "dev", "acme/demo"],
            env=env,
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        try:
            for _ in range(100):
                if pause_file.exists():
                    break
                time.sleep(0.05)
            else:
                self.fail("setup verification did not reach the injected pause")
            os.kill(proc.pid, signal.SIGKILL)
            proc.wait(timeout=15)
            blocked = self.env.msw("github", "remove", "dev", check=False)
            self.assertFailed(blocked, "already in progress")
            os.killpg(proc.pid, signal.SIGKILL)
            pause_file.unlink(missing_ok=True)
            for _ in range(100):
                removed = self.env.msw("github", "remove", "dev", check=False)
                if removed.returncode == 0:
                    break
                time.sleep(0.05)
            else:
                self.fail("orphaned verification lock was not released")
        finally:
            pause_file.unlink(missing_ok=True)
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            if proc.poll() is None:
                proc.wait(timeout=5)

    def test_read_only_setup_keeps_guest_access_without_host_token(self) -> None:
        self.env.init_remote()
        proc = self.env.configure_read_only("playgrounds", "acme/demo")
        self.assertIn("guest push rejected", proc.stdout)
        self.assertIn("Read-only GitHub access verified", proc.stdout)
        self.assertNotIn("host-only push", proc.stdout)
        self.assertTrue(self.env.key_file("msw.github.read", "playgrounds").exists())
        self.assertFalse(self.env.key_file("msw.github.write", "playgrounds").exists())
        metadata = (self.env.home / ".config/msw/github/playgrounds.conf").read_text()
        self.assertIn("verification_repo=acme/demo", metadata)
        self.assertIn("access=read-only", metadata)
        self.assertEqual(
            self.env.state()["sandboxes"]["playgrounds"]["secrets"]["GH_TOKEN"],
            "GH_TOKEN@github.com,api.github.com",
        )
        self.assertIn("playgrounds   present    missing", self.env.msw("github", "status", "playgrounds").stdout)
        verify = self.env.msw("github", "verify", "playgrounds")
        self.assertIn("Read-only GitHub access verified", verify.stdout)
        self.assertFailed(
            self.env.msw("push", "playgrounds", "repo", "--yes", check=False),
            "host write token missing",
        )

    def test_read_only_metadata_blocks_stale_write_token(self) -> None:
        bare = self.env.init_remote()
        self.env.configure_read_only("playgrounds", "acme/demo")
        self.env.key_file("msw.github.write", "playgrounds").write_text("stale-write-token")
        self.env.msw("clone", "playgrounds", "acme/demo", "repo")
        before = run_cmd([SYSTEM_GIT, "--git-dir", bare, "rev-parse", "refs/heads/main"], env=self.env.env).stdout.strip()
        proc = self.env.msw("push", "playgrounds", "repo", "--yes", check=False)
        self.assertFailed(proc, "workspace is read-only")
        after = run_cmd([SYSTEM_GIT, "--git-dir", bare, "rev-parse", "refs/heads/main"], env=self.env.env).stdout.strip()
        self.assertEqual(after, before)

    def test_keychain_delete_security_outcomes(self) -> None:
        command = 'source "$1"; keychain_delete "msw.github.write" "dev"'
        cases = (
            ("delete-failure", True, "could not delete Keychain item"),
            ("post-delete-lookup-failure", True, "could not verify Keychain item removal"),
            ("still-present", True, "Keychain item still exists"),
            ("missing-item", False, None),
        )
        state_path = self.env.root / "fake-security-state.json"
        for mode, should_fail, message in cases:
            with self.subTest(mode=mode):
                items = {} if mode == "missing-item" else {"msw.github.write/dev": "write-token"}
                state_path.write_text(json.dumps(items))
                proc = self.env.run(
                    "bash",
                    "-c",
                    command,
                    "msw-keychain-test",
                    str(PACKAGE / "bin/msw"),
                    check=False,
                    extra_env={
                        "MSW_SOURCE_ONLY": "1",
                        "MSW_TEST_KEYCHAIN_DIR": "",
                        "MSW_SECURITY_BIN": str(FAKE_SECURITY),
                        "MSW_FAKE_SECURITY_STATE": str(state_path),
                        "MSW_FAKE_SECURITY_MODE": mode,
                    },
                )
                if should_fail:
                    self.assertFailed(proc, message)
                else:
                    self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)


    def test_github_remove_failure_revokes_metadata_first(self) -> None:
        self.env.init_remote()
        state_path = self.env.root / "fake-security-remove-state.json"
        fake_env = {
            "MSW_TEST_KEYCHAIN_DIR": "",
            "MSW_SECURITY_BIN": str(FAKE_SECURITY),
            "MSW_FAKE_SECURITY_STATE": str(state_path),
            "MSW_FAKE_SECURITY_MODE": "normal",
        }
        self.env.configure_tokens("dev", "acme/demo", extra_env=fake_env)
        self.env.msw("clone", "dev", "acme/demo", "repo", extra_env=fake_env)
        metadata = self.env.home / ".config/msw/github/dev.conf"
        self.assertIn("access=host-write", metadata.read_text())

        failed_env = {**fake_env, "MSW_FAKE_SECURITY_MODE": "delete-failure"}
        proc = self.env.msw("github", "remove", "dev", check=False, extra_env=failed_env)
        self.assertFailed(proc, "could not delete Keychain item")
        self.assertFalse(metadata.exists())
        self.assertIn("msw.github.write/dev", json.loads(state_path.read_text()))

        push = self.env.msw("push", "dev", "repo", "--yes", check=False, extra_env=failed_env)
        self.assertFailed(push, "quarantined")

    def test_setup_rollback_failure_revokes_metadata_first(self) -> None:
        self.env.init_remote()
        state_path = self.env.root / "fake-security-rollback-state.json"
        fake_env = {
            "MSW_TEST_KEYCHAIN_DIR": "",
            "MSW_SECURITY_BIN": str(FAKE_SECURITY),
            "MSW_FAKE_SECURITY_STATE": str(state_path),
            "MSW_FAKE_SECURITY_MODE": "delete-failure",
            "MSW_FAKE_GUEST_PUSH_ALLOWED": "1",
            "MSW_FAKE_SECRET_REMOVE_FAIL": "1",
        }
        proc = self.env.configure_tokens("dev", "acme/demo", extra_env=fake_env, check=False)
        self.assertFailed(proc, "guest token can push")
        metadata = self.env.home / ".config/msw/github/dev.conf"
        self.assertFalse(metadata.exists())
        self.assertIn("msw.github.write/dev", json.loads(state_path.read_text()))
        state = self.env.state()
        self.assertEqual(state["sandboxes"]["dev"]["secrets"]["GH_TOKEN"], "GH_TOKEN@github.com,api.github.com")
        self.assertFalse(state["sandboxes"]["dev"]["running"])
        quarantine = self.env.home / ".config/msw/github/dev.quarantine"
        self.assertTrue(quarantine.exists())
        start = self.env.msw("start", "dev", check=False, extra_env=fake_env)
        self.assertFailed(start, "quarantined")

        guest_push = self.env.msw("exec", "dev", "git", "push", "origin", "main", check=False, extra_env=fake_env)
        self.assertFailed(guest_push, "quarantined")
        metadata.write_text("verification_repo=acme/demo\naccess=host-write\n")
        host_push = self.env.msw("push", "dev", "repo", "--yes", check=False, extra_env=fake_env)
        self.assertFailed(host_push, "quarantined")
        metadata.unlink()


    def test_stop_remains_available_for_quarantined_running_workspace(self) -> None:
        self.env.init_remote()
        self.env.configure_tokens("dev", "acme/demo")
        self.env.msw("start", "dev")

        quarantine = self.env.home / ".config/msw/github/dev.quarantine"
        quarantine.write_text("credential cleanup failed\n")

        document = json.loads(self.env.msw(
            "app", "state", "--workspace", "dev", "--format", "json"
        ).stdout)
        workspace = document["result"]["workspaces"][0]
        self.assertEqual(workspace["lifecycle"], "Running")
        self.assertEqual(workspace["quarantine"]["state"], "quarantined")
        self.assertTrue(workspace["actionCapabilities"]["canStop"])
        self.assertFalse(workspace["actionCapabilities"]["canStart"])
        self.assertFalse(workspace["actionCapabilities"]["canRestart"])
        self.assertFalse(workspace["actionCapabilities"]["canOpenTerminal"])
        self.assertFalse(workspace["actionCapabilities"]["canPush"])

        self.env.msw("stop", "dev")
        self.assertFalse(self.env.state()["sandboxes"]["dev"]["running"])

    def test_ssh_proxy_blocks_quarantined_workspace_without_starting(self) -> None:
        self.env.init_remote()
        self.env.configure_tokens("dev", "acme/demo")
        self.env.msw("stop", "dev")
        quarantine = self.env.home / ".config/msw/github/dev.quarantine"
        quarantine.write_text("credential cleanup failed\n")
        self.assertFalse(self.env.state()["sandboxes"]["dev"]["running"])

        proxy = self.env.home / ".local/bin/msw-ssh-proxy"
        proc = self.env.run(proxy, "dev.msb", check=False)
        self.assertFailed(proc, "quarantined")
        self.assertFalse(self.env.state()["sandboxes"]["dev"]["running"])

    def test_quarantine_requires_proven_stop(self) -> None:
        command = 'source "$1"; quarantine_workspace "dev" "test quarantine"'
        quarantine = self.env.home / ".config/msw/github/dev.quarantine"
        cases = (
            ({"MSW_FAKE_PING_FAIL": "1"}, False, False, ""),
            ({"MSW_FAKE_STOP_FAIL": "1"}, True, True, "could not stop"),
            ({"MSW_FAKE_INSPECT_FAIL": "1"}, True, True, "could not inspect"),
        )
        for overrides, should_fail, should_still_run, expected in cases:
            with self.subTest(overrides=overrides):
                if quarantine.exists():
                    quarantine.unlink()
                self.env.msw("start", "dev")
                proc = self.env.run(
                    "bash",
                    "-c",
                    command,
                    "msw-quarantine-test",
                    str(PACKAGE / "bin/msw"),
                    check=False,
                    extra_env={"MSW_SOURCE_ONLY": "1", **overrides},
                )
                if should_fail:
                    self.assertFailed(proc, expected)
                else:
                    self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                self.assertEqual(self.env.state()["sandboxes"]["dev"]["running"], should_still_run)
                self.assertTrue(quarantine.exists())

    def test_interrupted_verification_failed_repair_keeps_quarantine(self) -> None:
        self.env.init_remote()
        state_path = self.env.root / "fake-security-interrupt-state.json"
        pause_file = self.env.root / "fake-verification-interrupt.ready"
        state_path.write_text("{}")
        env = self.env.env.copy()
        env.update(
            {
                "MSW_GITHUB_READ_TOKEN_INPUT": "github_pat_READ_interrupt_abcdefghijklmnopqrstuvwxyz0123456789",
                "MSW_GITHUB_WRITE_TOKEN_INPUT": "github_pat_WRITE_interrupt_abcdefghijklmnopqrstuvwxyz0123456789",
                "MSW_TEST_KEYCHAIN_DIR": "",
                "MSW_SECURITY_BIN": str(FAKE_SECURITY),
                "MSW_FAKE_SECURITY_STATE": str(state_path),
                "MSW_FAKE_SECURITY_MODE": "normal",
                "MSW_FAKE_VERIFY_PAUSE_FILE": str(pause_file),
                "MSW_FAKE_VERIFY_PAUSE_ONCE": "1",
            }
        )
        proc = subprocess.Popen(
            [str(self.env.msw_bin), "github", "setup", "dev", "acme/demo"],
            env=env,
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        try:
            for _ in range(100):
                if pause_file.exists():
                    break
                time.sleep(0.05)
            else:
                self.fail("verification did not reach the injected pause")
            verification_root = self.env.workspace("dev") / ".msw-verification"
            verification_entries = list(verification_root.iterdir())
            self.assertEqual(len(verification_entries), 1, f"{verification_root}: {verification_entries}")
            overlap = self.env.msw("github", "remove", "dev", check=False, extra_env=env)
            self.assertFailed(overlap, "already in progress")
            os.killpg(proc.pid, signal.SIGTERM)
            pause_file.unlink(missing_ok=True)
            proc.wait(timeout=15)
        finally:
            pause_file.unlink(missing_ok=True)
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait(timeout=5)
        self.assertNotEqual(proc.returncode, 0)
        for _ in range(100):
            verification_entries = list(verification_root.iterdir()) if verification_root.exists() else []
            if not verification_entries:
                break
            time.sleep(0.05)
        self.assertEqual(verification_entries, [])
        quarantine = self.env.home / ".config/msw/github/dev.quarantine"
        self.assertTrue(quarantine.exists())
        metadata = self.env.home / ".config/msw/github/dev.conf"
        self.assertTrue(metadata.exists())
        self.assertIn("access=host-write", metadata.read_text())
        self.assertFalse(self.env.state()["sandboxes"]["dev"]["running"])
        self.assertIn("msw.github.read/dev", json.loads(state_path.read_text()))
        for command in (
            ("start", "dev"),
            ("restart", "dev"),
            ("exec", "dev", "true"),
            ("push", "dev", "repo", "--yes"),
        ):
            with self.subTest(command=command):
                blocked = self.env.msw(*command, check=False, extra_env=env)
                self.assertFailed(blocked, "quarantined")

        repair_env = env.copy()
        repair_env.pop("MSW_GITHUB_READ_TOKEN_INPUT", None)
        repair_env.pop("MSW_GITHUB_WRITE_TOKEN_INPUT", None)
        repair_env.pop("MSW_FAKE_VERIFY_PAUSE_FILE", None)
        failed_repair = self.env.configure_tokens(
            "dev",
            "acme/missing",
            read="github_pat_READ_repair_abcdefghijklmnopqrstuvwxyz0123456789",
            write="github_pat_WRITE_repair_abcdefghijklmnopqrstuvwxyz0123456789",
            extra_env=repair_env,
            check=False,
        )
        self.assertFailed(failed_repair, "workspace remains quarantined")
        self.assertTrue(quarantine.exists())
        self.assertFalse(metadata.exists())
        security_state = json.loads(state_path.read_text())
        self.assertNotIn("msw.github.read/dev", security_state)
        self.assertNotIn("msw.github.write/dev", security_state)
        self.assertNotIn("GH_TOKEN", self.env.state()["sandboxes"]["dev"]["secrets"])
        self.assertFalse(self.env.state()["sandboxes"]["dev"]["running"])

    def test_read_only_conversion_failure_revokes_metadata_first(self) -> None:
        self.env.init_remote()
        state_path = self.env.root / "fake-security-read-only-state.json"
        normal_env = {
            "MSW_TEST_KEYCHAIN_DIR": "",
            "MSW_SECURITY_BIN": str(FAKE_SECURITY),
            "MSW_FAKE_SECURITY_STATE": str(state_path),
            "MSW_FAKE_SECURITY_MODE": "normal",
        }
        self.env.configure_tokens("dev", "acme/demo", extra_env=normal_env)
        self.env.msw("clone", "dev", "acme/demo", "repo", extra_env=normal_env)

        failed_env = {**normal_env, "MSW_FAKE_SECURITY_MODE": "delete-failure"}
        proc = self.env.configure_read_only("dev", "acme/demo", extra_env=failed_env, check=False)
        self.assertFailed(proc, "could not delete Keychain item")
        metadata = self.env.home / ".config/msw/github/dev.conf"
        self.assertFalse(metadata.exists())
        self.assertIn("msw.github.write/dev", json.loads(state_path.read_text()))

        push = self.env.msw("push", "dev", "repo", "--yes", check=False, extra_env=failed_env)
        self.assertFailed(push, "quarantined")

    def test_same_token_is_rejected_without_mutation(self) -> None:
        self.env.init_remote()
        token = "github_pat_IDENTICAL_abcdefghijklmnopqrstuvwxyz0123456789"
        proc = self.env.configure_tokens("dev", "acme/demo", read=token, write=token, check=False)
        self.assertFailed(proc, "two different tokens")
        self.assertFalse(self.env.key_file("msw.github.read", "dev").exists())

    def test_failed_permission_verification_restores_old_tokens_and_metadata(self) -> None:
        self.env.init_remote(repo="good")
        self.env.configure_tokens("dev", "acme/good", read="github_pat_OLD_READ_abcdefghijklmnopqrstuvwxyz", write="github_pat_OLD_WRITE_abcdefghijklmnopqrstuvwxyz")
        bad = self.env.init_remote(repo="bad")
        (bad / "deny-host").write_text("1")
        proc = self.env.configure_tokens(
            "dev", "acme/bad",
            read="github_pat_NEW_READ_abcdefghijklmnopqrstuvwxyz",
            write="github_pat_NEW_WRITE_abcdefghijklmnopqrstuvwxyz",
            check=False,
        )
        self.assertFailed(proc, "restoring the previous")
        self.assertEqual(self.env.key_file("msw.github.read", "dev").read_text(), "github_pat_OLD_READ_abcdefghijklmnopqrstuvwxyz")
        self.assertEqual(self.env.key_file("msw.github.write", "dev").read_text(), "github_pat_OLD_WRITE_abcdefghijklmnopqrstuvwxyz")
        self.assertIn("verification_repo=acme/good", (self.env.home / ".config/msw/github/dev.conf").read_text())

    def test_guest_token_with_write_permission_is_detected_and_rolled_back(self) -> None:
        bare = self.env.init_remote()
        proc = self.env.configure_tokens(
            "dev", "acme/demo",
            extra_env={"MSW_FAKE_GUEST_PUSH_ALLOWED": "1"},
            check=False,
        )
        self.assertFailed(proc, "guest token can push")
        refs = run_cmd([SYSTEM_GIT, "--git-dir", bare, "for-each-ref", "--format=%(refname)", "refs/heads/msw-permission-test-*"], env=self.env.env).stdout
        self.assertEqual(refs.strip(), "")
        self.assertFalse(self.env.key_file("msw.github.read", "dev").exists())

    def test_normal_new_branch_push_only_committed_current_branch(self) -> None:
        bare, repo = self.prepare()
        self.env.git(repo, "switch", "-c", "feature/one")
        (repo / "committed.txt").write_text("committed\n")
        self.env.git(repo, "add", "committed.txt")
        self.env.git(repo, "commit", "-m", "Feature")
        (repo / "dirty.txt").write_text("not committed\n")
        self.env.git(repo, "tag", "local-only-tag")
        self.env.msw("push", "dev", "clients/acme/demo", "--yes")
        remote_sha = run_cmd([SYSTEM_GIT, "--git-dir", bare, "rev-parse", "refs/heads/feature/one"], env=self.env.env).stdout.strip()
        local_sha = self.env.git(repo, "rev-parse", "HEAD").stdout.strip()
        self.assertEqual(remote_sha, local_sha)
        self.assertFailed(run_cmd([SYSTEM_GIT, "--git-dir", bare, "rev-parse", "refs/tags/local-only-tag"], env=self.env.env, check=False))
        show = run_cmd([SYSTEM_GIT, "--git-dir", bare, "show", "feature/one:committed.txt"], env=self.env.env).stdout
        self.assertEqual(show, "committed\n")
        self.assertFailed(run_cmd([SYSTEM_GIT, "--git-dir", bare, "show", "feature/one:dirty.txt"], env=self.env.env, check=False))

    def test_fast_forward_push_and_remote_tracking_refresh(self) -> None:
        bare, repo = self.prepare()
        (repo / "one.txt").write_text("one\n")
        self.env.git(repo, "add", "one.txt")
        self.env.git(repo, "commit", "-m", "One")
        self.env.msw("push", "dev", "clients/acme/demo", "--yes")
        (repo / "two.txt").write_text("two\n")
        self.env.git(repo, "add", "two.txt")
        self.env.git(repo, "commit", "-m", "Two")
        self.env.msw("push", "dev", "clients/acme/demo", "--yes")
        remote = run_cmd([SYSTEM_GIT, "--git-dir", bare, "rev-parse", "refs/heads/main"], env=self.env.env).stdout.strip()
        tracking = self.env.git(repo, "rev-parse", "refs/remotes/origin/main").stdout.strip()
        self.assertEqual(remote, tracking)

    def test_non_fast_forward_rejected_then_exact_force_with_lease_succeeds(self) -> None:
        bare, repo = self.prepare()
        (repo / "local.txt").write_text("local\n")
        self.env.git(repo, "add", "local.txt")
        self.env.git(repo, "commit", "-m", "Local divergent")

        updater = self.env.root / "other"
        run_cmd([SYSTEM_GIT, "clone", str(bare), updater], env=self.env.env)
        run_cmd([SYSTEM_GIT, "-C", updater, "config", "user.name", "Other"], env=self.env.env)
        run_cmd([SYSTEM_GIT, "-C", updater, "config", "user.email", "other@example.invalid"], env=self.env.env)
        (updater / "remote.txt").write_text("remote\n")
        run_cmd([SYSTEM_GIT, "-C", updater, "add", "remote.txt"], env=self.env.env)
        run_cmd([SYSTEM_GIT, "-C", updater, "commit", "-m", "Remote divergent"], env=self.env.env)
        run_cmd([SYSTEM_GIT, "-C", updater, "push", "origin", "main"], env=self.env.env)

        self.assertFailed(self.env.msw("push", "dev", "clients/acme/demo", "--yes", check=False), "not a fast-forward")
        local_sha = self.env.git(repo, "rev-parse", "HEAD").stdout.strip()
        self.env.msw("push", "dev", "clients/acme/demo", "--force-with-lease", "--yes")
        remote_sha = run_cmd([SYSTEM_GIT, "--git-dir", bare, "rev-parse", "main"], env=self.env.env).stdout.strip()
        self.assertEqual(remote_sha, local_sha)

    def test_force_with_lease_rejects_concurrent_remote_change(self) -> None:
        bare, repo = self.prepare()
        (repo / "local.txt").write_text("local\n")
        self.env.git(repo, "add", "local.txt")
        self.env.git(repo, "commit", "-m", "Local")
        marker = self.env.root / "race-fired"
        proc = self.env.msw(
            "push", "dev", "clients/acme/demo", "--force-with-lease", "--yes",
            check=False,
            extra_env={
                "MSW_FAKE_ADVANCE_REMOTE_ON_BUNDLE": str(bare),
                "MSW_FAKE_RACE_REF": "refs/heads/main",
                "MSW_FAKE_RACE_ONCE_FILE": str(marker),
            },
        )
        self.assertFailed(proc, "stale info")
        self.assertTrue(marker.exists())
        self.assertNotEqual(run_cmd([SYSTEM_GIT, "--git-dir", bare, "rev-parse", "main"], env=self.env.env).stdout.strip(), self.env.git(repo, "rev-parse", "HEAD").stdout.strip())

    def test_detached_head_bad_origin_missing_token_and_cancel(self) -> None:
        _, repo = self.prepare()
        self.env.git(repo, "checkout", "--detach")
        self.assertFailed(self.env.msw("push", "dev", "clients/acme/demo", "--yes", check=False), "detached HEAD")
        self.env.git(repo, "switch", "main")
        self.env.git(repo, "remote", "set-url", "origin", "https://example.com/nope.git")
        self.assertFailed(self.env.msw("push", "dev", "clients/acme/demo", "--yes", check=False), "origin must point to github.com")
        self.env.git(repo, "remote", "set-url", "origin", "https://github.com/acme/demo.git")
        self.env.key_file("msw.github.write", "dev").unlink()
        self.assertFailed(self.env.msw("push", "dev", "clients/acme/demo", "--yes", check=False), "host write token missing")
        self.env.key_file("msw.github.write", "dev").write_text("github_pat_WRITE_dev_abcdefghijklmnopqrstuvwxyz0123456789")
        (repo / "cancel.txt").write_text("cancel\n")
        self.env.git(repo, "add", "cancel.txt")
        self.env.git(repo, "commit", "-m", "Cancel")
        self.assertFailed(self.env.msw("push", "dev", "clients/acme/demo", check=False, input_text="NO\n"), "push cancelled")

    def test_host_git_config_isolation(self) -> None:
        bare, repo = self.prepare()
        (self.env.home / ".gitconfig").write_text(textwrap.dedent(f"""
            [url \"/definitely/not/the/remote\"]
                insteadOf = {bare}
            [core]
                hooksPath = /definitely/not/hooks
        """))
        (repo / "isolated.txt").write_text("safe\n")
        self.env.git(repo, "add", "isolated.txt")
        self.env.git(repo, "commit", "-m", "Isolated")
        self.env.msw("push", "dev", "clients/acme/demo", "--yes")
        self.assertEqual(run_cmd([SYSTEM_GIT, "--git-dir", bare, "show", "main:isolated.txt"], env=self.env.env).stdout, "safe\n")

    def _add_lfs_pointer(self, repo: Path, content: bytes, *, valid: bool = True, object_present: bool = True) -> str:
        oid = hashlib.sha256(content).hexdigest()
        pointer_oid = oid if valid else "NOT-A-VALID-OID"
        (repo / "asset.bin").write_text(
            "version https://git-lfs.github.com/spec/v1\n"
            f"oid sha256:{pointer_oid}\n"
            f"size {len(content)}\n"
        )
        if object_present:
            obj = repo / ".git" / "lfs" / "objects" / oid[:2] / oid[2:4] / oid
            obj.parent.mkdir(parents=True, exist_ok=True)
            obj.write_bytes(content)
        self.env.git(repo, "add", "asset.bin")
        self.env.git(repo, "commit", "-m", "Add LFS pointer")
        return oid

    def test_lfs_valid_object_is_verified_and_uploaded_via_host_stub(self) -> None:
        bare, repo = self.prepare()
        log = self.env.install_fake_git_lfs()
        oid = self._add_lfs_pointer(repo, b"large-content-for-lfs-test")
        self.env.msw("push", "dev", "clients/acme/demo", "--yes")
        lfs_log = log.read_text()
        self.assertIn("push --object-id origin --stdin", lfs_log)
        self.assertIn(oid, lfs_log)
        self.assertIn(f"oid sha256:{oid}", run_cmd([SYSTEM_GIT, "--git-dir", bare, "show", "main:asset.bin"], env=self.env.env).stdout)

    def _run_lfs_failure_case(self, label: str, *, valid: bool, object_present: bool,
                              extra: dict[str, str], expected: str) -> None:
        self.env.init_remote()
        self.env.configure_tokens("dev", "acme/demo")
        self.env.msw("clone", "dev", "acme/demo", "repo")
        repo = self.env.guest_repo("dev", "repo")
        self.env.git(repo, "config", "user.name", "Agent")
        self.env.git(repo, "config", "user.email", "agent@example.invalid")
        self.env.install_fake_git_lfs()
        content = b"lfs-case-content"
        oid = hashlib.sha256(content).hexdigest()
        pointer_oid = oid if valid else "NOT-A-VALID-OID"
        (repo / "asset.bin").write_text(
            "version https://git-lfs.github.com/spec/v1\n"
            f"oid sha256:{pointer_oid}\nsize {len(content)}\n"
        )
        if object_present:
            obj = repo / ".git/lfs/objects" / oid[:2] / oid[2:4] / oid
            obj.parent.mkdir(parents=True, exist_ok=True)
            obj.write_bytes(content)
        self.env.git(repo, "add", "asset.bin")
        self.env.git(repo, "commit", "-m", label)
        proc = self.env.msw("push", "dev", "repo", "--yes", check=False, extra_env=extra)
        self.assertFailed(proc, expected)

    def test_lfs_invalid_pointer_is_rejected(self) -> None:
        self._run_lfs_failure_case("invalid", valid=False, object_present=True, extra={}, expected="invalid Git LFS pointer")

    def test_lfs_missing_object_is_rejected(self) -> None:
        self._run_lfs_failure_case("missing", valid=True, object_present=False, extra={}, expected="No such file")

    def test_lfs_corrupt_transfer_is_rejected(self) -> None:
        self._run_lfs_failure_case(
            "corrupt", valid=True, object_present=True,
            extra={"MSW_FAKE_COPY_CORRUPT_LFS": "1"},
            expected="failed SHA-256 verification",
        )

    def test_lfs_symlink_transfer_is_rejected(self) -> None:
        self._run_lfs_failure_case(
            "symlink", valid=True, object_present=True,
            extra={"MSW_FAKE_COPY_SYMLINK_LFS": "1"},
            expected="not a regular file",
        )


class BackupRestoreTests(MSWTestCase):
    def _backup(self) -> Path:
        proc = self.env.msw("backup", str(self.env.root / "backups"), timeout=90)
        archives = [Path(line) for line in proc.stdout.splitlines() if line.endswith(".tar.zst")]
        self.assertEqual(len(archives), 1, proc.stdout)
        return archives[0]

    def test_backup_restores_only_previous_running_set_and_excludes_keychain(self) -> None:
        self.env.msw("start", "dev")
        self.env.msw("start", "personal")
        self.env.key_file("msw.github.read", "dev").write_text("super-secret-token")
        archive = self._backup()
        state = self.env.state()
        self.assertTrue(state["sandboxes"]["dev"]["running"])
        self.assertTrue(state["sandboxes"]["personal"]["running"])
        self.assertFalse(state["sandboxes"]["playgrounds"]["running"])
        self.assertTrue(archive.exists())
        self.assertTrue(Path(str(archive) + ".sha256").exists())
        self.assertTrue(Path(str(archive) + ".info.txt").exists())
        listing = run_cmd([SYSTEM_ZSTD, "-dc", "-q", archive], env=self.env.env).stdout if False else ""
        tar_list = run_cmd(["bash", "-lc", f"{SYSTEM_ZSTD} -dc -q {archive!s} | {SYSTEM_TAR} -tf -"], env=self.env.env).stdout
        self.assertNotIn("keychain", tar_list.lower())
        self.assertNotIn("super-secret-token", archive.read_bytes().decode("latin1", errors="ignore"))

    def test_full_backup_and_transactional_restore_recovers_workspace_runtime_and_config(self) -> None:
        workspace_file = self.env.workspace("dev") / "project/data.txt"
        runtime_file = self.env.runtime("dev") / "docker/state.txt"
        workspace_file.parent.mkdir(parents=True)
        runtime_file.parent.mkdir(parents=True)
        workspace_file.write_text("backed-up-workspace\n")
        runtime_file.write_text("backed-up-runtime\n")
        archive = self._backup()

        workspace_file.write_text("mutated\n")
        runtime_file.write_text("mutated\n")
        config = self.env.home / ".config/msw/config.sh"
        config.write_text(config.read_text() + "\nMSW_TEST_MUTATION=broken\n")
        proc = self.env.msw("restore", str(archive), "--yes", timeout=90)
        self.assertIn("restore complete", proc.stdout)
        self.assertEqual(workspace_file.read_text(), "backed-up-workspace\n")
        self.assertEqual(runtime_file.read_text(), "backed-up-runtime\n")
        restored_config = (self.env.home / ".config/msw/config.sh").read_text()
        self.assertIn("MSW_VERSION=", restored_config)
        self.assertNotIn("MSW_TEST_MUTATION", restored_config)
        state = self.env.state()
        self.assertTrue(all(not sb["running"] for sb in state["sandboxes"].values()))
        rollbacks = list(self.env.home.glob(".msw-restore-rollback-*"))
        self.assertEqual(len(rollbacks), 1)
        self.assertTrue(os.access(self.env.home / ".local/bin/msw", os.X_OK))

    def test_corrupt_checksum_is_rejected_before_mutation(self) -> None:
        marker = self.env.home / ".config/msw/current-marker"
        marker.write_text("current")
        archive = self._backup()
        with archive.open("ab") as f:
            f.write(b"corruption")
        proc = self.env.msw("restore", str(archive), "--yes", check=False)
        self.assertFailed(proc, "checksum failed")
        self.assertEqual(marker.read_text(), "current")

    def _write_malicious_archive(self, members: list[tarfile.TarInfo], payloads: dict[str, bytes] | None = None) -> Path:
        payloads = payloads or {}
        raw = self.env.root / "malicious.tar"
        with tarfile.open(raw, "w") as tf:
            for info in members:
                data = payloads.get(info.name, b"")
                if info.isfile():
                    info.size = len(data)
                    tf.addfile(info, io.BytesIO(data))
                else:
                    tf.addfile(info)
        out = self.env.root / "malicious.tar.zst"
        run_cmd([SYSTEM_ZSTD, "-q", "-f", str(raw), "-o", str(out)], env=self.env.env)
        digest = hashlib.sha256(out.read_bytes()).hexdigest()
        Path(str(out) + ".sha256").write_text(f"{digest}  {out.name}\n")
        return out

    def _required_tar_members(self) -> list[tarfile.TarInfo]:
        names = [
            ".microsandbox", ".config/msw", ".local/bin/msw", ".local/bin/msw-ssh-proxy",
            ".local/libexec/msw-git-askpass", ".local/share/msw", ".ssh/msw_ed25519",
            ".ssh/msw_ed25519.pub", ".ssh/config.d/msw.conf",
        ]
        result = []
        for name in names:
            info = tarfile.TarInfo(name)
            if name in {".microsandbox", ".config/msw", ".local/share/msw"}:
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
            else:
                info.type = tarfile.REGTYPE
                info.mode = 0o755
            result.append(info)
        return result

    def test_restore_rejects_path_traversal_duplicate_incomplete_and_absolute_symlink(self) -> None:
        variants: list[tuple[str, list[tarfile.TarInfo], str]] = []
        traversal = self._required_tar_members()
        bad = tarfile.TarInfo("../escape"); bad.type = tarfile.REGTYPE
        traversal.append(bad)
        variants.append(("traversal", traversal, "unsafe or unexpected"))

        duplicate = self._required_tar_members()
        dup = tarfile.TarInfo(".local/bin/msw"); dup.type = tarfile.REGTYPE
        duplicate.append(dup)
        variants.append(("duplicate", duplicate, "duplicate archive member"))

        incomplete = self._required_tar_members()[:-1]
        variants.append(("incomplete", incomplete, "backup is incomplete"))

        symlink = self._required_tar_members()
        link = tarfile.TarInfo(".microsandbox/absolute-link")
        link.type = tarfile.SYMTYPE; link.linkname = "/etc/passwd"
        symlink.append(link)
        variants.append(("absolute-symlink", symlink, "absolute symlink"))

        for label, members, expected in variants:
            with self.subTest(label=label):
                archive = self._write_malicious_archive(members)
                proc = self.env.msw("restore", str(archive), "--yes", check=False)
                self.assertFailed(proc, expected)
                self.assertFalse((self.env.root / "escape").exists())

    def test_failed_restore_health_rolls_back_current_state(self) -> None:
        backup_marker = self.env.home / ".config/msw/backup-marker"
        backup_marker.write_text("from-backup")
        archive = self._backup()
        backup_marker.write_text("current-state")
        current_only = self.env.home / ".config/msw/current-only"
        current_only.write_text("preserve-me")
        proc = self.env.msw(
            "restore", str(archive), "--yes", check=False,
            extra_env={"MSW_FAKE_RESTORE_HEALTH_FAIL": "1"},
        )
        self.assertFailed(proc, "rolling back")
        self.assertEqual(backup_marker.read_text(), "current-state")
        self.assertEqual(current_only.read_text(), "preserve-me")

    def test_backup_pipeline_failure_restarts_vms_and_leaves_no_partial_artifacts(self) -> None:
        self.env.msw("start", "dev")
        fake_zstd = self.env.root / "tools/failing-zstd"
        fake_zstd.write_text("#!/bin/sh\nexit 42\n")
        fake_zstd.chmod(0o755)
        dest = self.env.root / "failed-backups"
        proc = self.env.msw("backup", str(dest), check=False, extra_env={"MSW_ZSTD_BIN": str(fake_zstd)})
        self.assertFailed(proc)
        self.assertTrue(self.env.state()["sandboxes"]["dev"]["running"])
        self.assertEqual(list(dest.glob("*")), [])
        self.assertFailed(self.env.msw("backup", str(self.env.home / ".microsandbox/backups"), check=False), "may not be inside managed state")


class PackagedBehaviorTests(MSWTestCase):
    def test_help_version_docs_without_msb_and_complete_deep_check(self) -> None:
        env = self.env.env.copy()
        env["MSW_MSB_BIN"] = "/does/not/exist"
        self.assertIn("msw 3.1.0", self.env.msw("version", extra_env=env).stdout)
        self.assertIn("grouped MicroSandbox", self.env.msw("help", extra_env=env).stdout)
        self.assertIn("MSW", self.env.msw("docs", "cheatsheet", extra_env=env).stdout)
        proc = self.env.msw("check", "--deep", timeout=90)
        self.assertIn("all live VM, Docker, SSH, internet, and published-port checks passed", proc.stdout)
        state = self.env.state()
        self.assertNotIn("24678", state["sandboxes"]["dev"].get("port_content", {}))
        self.assertNotIn("24679", state["sandboxes"]["dev"].get("port_content", {}))

    def test_app_github_state_emits_guest_metadata_as_valid_json(self) -> None:
        credentials = self.env.home / "Library/Application Support/MSW Monitor/credentials.json"
        credentials.parent.mkdir(parents=True, exist_ok=True)
        credentials.write_text(json.dumps({
            "schemaVersion": 2,
            "entries": {
                "dev.guest": {
                    "workspace": "dev",
                    "schemaVersion": 2,
                    "role": "guest",
                    "provider": "github-app-user",
                    "appClientID": "guest-public",
                    "accountLogin": "alice",
                    "owner": "acme",
                    "repositoryIDs": [12, 34],
                    "accessMode": "read-only",
                    "verificationRepository": "acme/demo",
                    "installationID": 123,
                    "accessExpiresAt": "2026-08-08T08:00:00Z",
                    "refreshExpiresAt": "2027-02-08T08:00:00Z",
                    "needsRestart": False,
                    "generation": 1,
                    "quarantined": False,
                    "updatedAt": "2026-08-08T00:00:00Z",
                }
            },
        }))

        document = json.loads(self.env.msw("app", "github-state", "--format", "json").stdout)
        self.assertTrue(document["ok"])
        workspaces = {item["workspace"]: item for item in document["result"]["workspaces"]}
        self.assertEqual(workspaces["dev"]["provider"], "github-app-user")
        self.assertEqual(workspaces["dev"]["accessMode"], "read-only")
        self.assertEqual(workspaces["dev"]["verificationRepository"], "acme/demo")
        self.assertEqual(workspaces["dev"]["accountLogin"], "alice")
        self.assertEqual(workspaces["dev"]["installationId"], "123")
        self.assertFalse(workspaces["dev"]["needsRestart"])
        self.assertFalse(workspaces["dev"]["quarantined"])

    def test_app_polling_contract_never_starts_or_forwards_guest_credentials(self) -> None:
        before = len(self.env.state().get("events", []))
        probe_env = {
            "MSW_GITHUB_READ_TOKEN_DEV": "ghu_probe_fixture",
            "MSW_FAKE_RECORD_CREDENTIAL_ENV": "1",
        }
        commands = [
            ("state", "--workspace", "dev", "--format", "json"),
            ("metrics", "--workspace", "dev", "--format", "json", "--once"),
            ("logs", "--workspace", "dev", "--format", "jsonl"),
            ("repositories", "--workspace", "dev", "--if-running", "--format", "json"),
            ("ports", "--workspace", "dev", "--format", "json"),
        ]
        for command in commands:
            with self.subTest(command=command[0]):
                self.env.msw("app", *command, extra_env=probe_env)

        events = self.env.state().get("events", [])[before:]
        self.assertFalse(any(event.get("event") == "start" for event in events), events)
        credential_events = [event for event in events if event.get("event") == "credential-env"]
        self.assertTrue(credential_events, events)
        self.assertTrue(all(not event["gh_token_present"] for event in credential_events), credential_events)
        self.assertTrue(all(not sandbox["running"] for sandbox in self.env.state()["sandboxes"].values()))

    def test_app_state_preserves_unknown_for_malformed_or_unrecognized_runtime_state(self) -> None:
        malformed = json.loads(self.env.msw(
            "app", "state", "--workspace", "dev", "--format", "json",
            extra_env={"MSW_FAKE_STATUS_JSON": "not-json"},
        ).stdout)
        workspace = malformed["result"]["workspaces"][0]
        self.assertEqual(workspace["lifecycle"], "Unknown")
        self.assertEqual(workspace["freshness"], "unavailable")
        self.assertIsNone(workspace["statusObservedAt"])
        self.assertFalse(workspace["actionCapabilities"]["canStart"])
        self.assertTrue(malformed["warnings"])

        unrecognized = json.loads(self.env.msw(
            "app", "state", "--workspace", "dev", "--format", "json",
            extra_env={"MSW_FAKE_STATUS_JSON": json.dumps({"name": "dev", "status": "Paused"})},
        ).stdout)["result"]["workspaces"][0]
        self.assertEqual(unrecognized["lifecycle"], "Unknown")
        self.assertEqual(unrecognized["freshness"], "fresh")
        self.assertNotEqual(unrecognized["lifecycle"], "Stopped")

    def test_app_backup_returns_archive_and_reconciled_running_set(self) -> None:
        self.env.msw("start", "dev")
        destination = self.env.root / "app-backups"

        document = json.loads(self.env.msw(
            "app", "backup", "--directory", str(destination), "--format", "json",
            timeout=90,
        ).stdout)

        result = document["result"]
        self.assertTrue(result["archive"].endswith(".tar.zst"), result)
        self.assertTrue(Path(result["archive"]).is_file())
        self.assertEqual(result["checksum"], result["archive"] + ".sha256")
        self.assertEqual(result["stoppedWorkspaces"], ["dev"])
        self.assertEqual(result["restartedWorkspaces"], ["dev"])
        self.assertTrue(self.env.state()["sandboxes"]["dev"]["running"])

    def test_app_oauth_host_profile_enables_aggregate_host_write_capability(self) -> None:
        credentials = self.env.home / "Library/Application Support/MSW Monitor/credentials.json"
        credentials.parent.mkdir(parents=True, exist_ok=True)
        common = {
            "workspace": "dev",
            "schemaVersion": 2,
            "provider": "github-app-user",
            "accountLogin": "alice",
            "owner": "acme",
            "repositoryIDs": [12],
            "verificationRepository": "acme/demo",
            "installationID": 123,
            "accessExpiresAt": "2099-08-08T08:00:00Z",
            "refreshExpiresAt": "2099-12-08T08:00:00Z",
            "needsRestart": False,
            "generation": 1,
            "quarantined": False,
            "updatedAt": "2026-08-08T00:00:00Z",
        }
        credentials.write_text(json.dumps({
            "schemaVersion": 2,
            "entries": {
                "dev.guest": common | {
                    "role": "guest", "appClientID": "guest-public", "accessMode": "read-only",
                },
                "dev.host": common | {
                    "role": "host", "appClientID": "host-public", "accessMode": "host-write",
                },
            },
        }))
        token_env = {
            "MSW_GITHUB_READ_TOKEN_DEV": "ghu_read_fixture",
            "MSW_GITHUB_WRITE_TOKEN_DEV": "ghu_write_fixture",
        }

        github = json.loads(self.env.msw(
            "app", "github-state", "--workspace", "dev", "--format", "json",
            extra_env=token_env,
        ).stdout)
        self.assertEqual(github["result"]["workspaces"][0]["accessMode"], "host-write")

        state = json.loads(self.env.msw(
            "app", "state", "--workspace", "dev", "--format", "json",
            extra_env=token_env,
        ).stdout)["result"]["workspaces"][0]
        self.assertEqual(state["credential"]["state"], "Ready")
        self.assertEqual(state["credential"]["accessMode"], "host-write")
    def test_app_logs_normalizes_and_redacts_jsonl(self) -> None:
        self.env.msw("start", "dev")
        payload = json.dumps({
            "message": "Authorization: Bearer ghp_secret",
            "detail": "runtime",
            "secret": "MSW_GITHUB_READ_TOKEN_DEV=opaque_secret",
        })
        document = self.env.msw(
            "app", "logs", "--workspace", "dev", "--format", "jsonl",
            extra_env={"MSW_FAKE_LOGS": payload},
        )
        lines = [json.loads(line) for line in document.stdout.splitlines() if line.strip()]
        self.assertEqual([line["type"] for line in lines], ["stream-start", "log", "stream-end"])
        self.assertEqual(lines[0]["stream"], "logs")
        self.assertEqual(lines[0]["protocolVersion"], 1)
        self.assertEqual({line["requestId"] for line in lines}, {lines[0]["requestId"]})
        self.assertTrue(all(line["workspace"] == "dev" for line in lines))
        self.assertTrue(all(line["safeForDisplay"] for line in lines))
        self.assertTrue(all("observedAt" in line for line in lines))
        self.assertIn("[REDACTED]", lines[1]["message"])
        self.assertNotIn("ghp_secret", lines[1]["message"])
        self.assertNotIn("opaque_secret", lines[1]["message"])


    def test_app_lifecycle_plan_requires_exact_confirmation_and_reconciles(self) -> None:
        plan_document = json.loads(self.env.msw(
            "app", "plan", "start", "--workspace", "dev", "--format", "json"
        ).stdout)
        plan = plan_document["result"]
        self.assertEqual(plan["confirmationPhrase"], "START dev")
        self.assertFalse(self.env.state()["sandboxes"]["dev"]["running"])

        rejected = self.env.msw(
            "app", "apply", plan["planId"], "--confirmation-fd", "0", "--format", "json",
            input_text="START playgrounds\n", check=False,
        )
        self.assertFailed(rejected, "MSW_CONFIRMATION_MISMATCH")
        self.assertFalse(self.env.state()["sandboxes"]["dev"]["running"])

        applied = json.loads(self.env.msw(
            "app", "apply", plan["planId"], "--confirmation-fd", "0", "--format", "json",
            input_text="START dev\n",
        ).stdout)
        self.assertTrue(applied["result"]["reconciled"])
        self.assertTrue(self.env.state()["sandboxes"]["dev"]["running"])

        replayed = self.env.msw(
            "app", "apply", plan["planId"], "--confirmation-fd", "0", "--format", "json",
            input_text="START dev\n", check=False,
        )
        self.assertEqual(replayed.returncode, 78)
        self.assertFailed(replayed, "MSW_PLAN_NOT_FOUND")

    def test_app_push_apply_reconciles_the_reviewed_commit(self) -> None:
        bare = self.env.init_remote()
        self.env.configure_tokens("dev", "acme/demo")
        self.env.msw("clone", "dev", "acme/demo", "repo")
        repo = self.env.guest_repo("dev", "repo")
        self.env.git(repo, "config", "user.name", "App Contract")
        self.env.git(repo, "config", "user.email", "app-contract@example.invalid")
        (repo / "reviewed.txt").write_text("reviewed commit\n")
        self.env.git(repo, "add", "reviewed.txt")
        self.env.git(repo, "commit", "-m", "Reviewed app push")
        reviewed_commit = self.env.git(repo, "rev-parse", "HEAD").stdout.strip()

        plan = json.loads(self.env.msw(
            "app", "push-plan", "--workspace", "dev", "--repositories", "repo",
            "--format", "json",
        ).stdout)["result"]
        self.assertEqual(plan["localCommit"], reviewed_commit)
        self.assertEqual(plan["confirmationPhrase"], "PUSH")

        applied = json.loads(self.env.msw(
            "app", "apply", plan["planId"], "--confirmation-fd", "0", "--format", "json",
            input_text="PUSH\n",
        ).stdout)["result"]
        self.assertTrue(applied["pushed"])
        self.assertTrue(applied["reconciled"])
        remote_commit = run_cmd(
            [SYSTEM_GIT, "--git-dir", bare, "rev-parse", "refs/heads/main"],
            env=self.env.env,
        ).stdout.strip()
        self.assertEqual(remote_commit, reviewed_commit)

    def test_app_command_inventory_is_dispatched_and_guarded(self) -> None:
        help_text = self.env.msw("app", "help").stdout
        for command in (
            "url", "clone", "pull", "identity", "disk", "resize", "clean",
            "upgrade", "update", "check", "backup", "restore", "push-plan",
        ):
            self.assertIn(f"msw app {command}", help_text)

        url = json.loads(self.env.msw(
            "app", "url", "--workspace", "dev", "--port", "3000",
            "--scheme", "https", "--format", "json",
        ).stdout)
        self.assertEqual(url["command"], "url")
        self.assertEqual(url["result"]["url"], "https://dev.msw.test:3000")
        self.assertFalse(url["result"]["started"])

        invalid_destination = self.env.msw(
            "app", "clone", "--workspace", "dev", "--repository", "acme/demo",
            "--destination", "../escape", "--format", "json", check=False,
        )
        self.assertEqual(invalid_destination.returncode, 64)
        self.assertFailed(invalid_destination, "MSW_INVALID_REQUEST")

        update_without_confirmation = self.env.msw(
            "app", "update", "--format", "json", check=False,
        )
        self.assertEqual(update_without_confirmation.returncode, 77)
        self.assertFailed(update_without_confirmation, "MSW_CONFIRMATION_MISMATCH")

        deep_without_confirmation = self.env.msw(
            "app", "check", "--deep", "--format", "json", check=False,
        )
        self.assertEqual(deep_without_confirmation.returncode, 77)
        self.assertFailed(deep_without_confirmation, "MSW_CONFIRMATION_MISMATCH")

        invalid_repository = self.env.msw(
            "app", "github-bind", "--workspace", "dev", "--repository", "../escape",
            "--mode", "read-only", "--format", "json", check=False,
        )
        self.assertEqual(invalid_repository.returncode, 64)
        self.assertFailed(invalid_repository, "MSW_INVALID_REQUEST")

        invalid_push_path = self.env.msw(
            "app", "push-plan", "--workspace", "dev", "--repositories", "../escape",
            "--format", "json", check=False,
        )
        self.assertEqual(invalid_push_path.returncode, 64)
        self.assertFailed(invalid_push_path, "MSW_INVALID_REQUEST")

    def test_app_repository_scan_never_treats_remote_failure_as_absent(self) -> None:
        self.env.init_remote()
        self.env.configure_tokens("dev", "acme/demo")
        self.env.msw("clone", "dev", "acme/demo", "repo")
        repo = self.env.guest_repo("dev", "repo")
        self.env.git(repo, "remote", "set-url", "origin", "https://github.com/acme/missing.git")

        result = json.loads(self.env.msw(
            "app", "repositories", "--workspace", "dev", "--if-running",
            "--include-worktree-status", "--format", "json",
        ).stdout)["result"]
        snapshot = next(item for item in result["repositories"] if item["path"] == "repo")
        self.assertEqual(snapshot["destinationState"], "unavailable")
        self.assertEqual(snapshot["pushability"], "blocked")

    def test_app_follow_metrics_normalizes_jsonl_events(self) -> None:
        self.env.msw("start", "dev")
        process = self.env.msw(
            "app", "metrics", "--workspace", "dev", "--format", "json", "--follow",
            extra_env={"MSW_FAKE_METRICS": '{"cpu":12.5}'},
        )
        events = [json.loads(line) for line in process.stdout.splitlines() if line.strip()]
        self.assertEqual([event["type"] for event in events], ["stream-start", "metrics", "stream-end"])
        event = events[1]
        self.assertEqual(event["schemaVersion"], 1)
        self.assertEqual(event["type"], "metrics")
        self.assertEqual(event["workspace"], "dev")
        self.assertEqual(event["snapshot"]["cpu"], 12.5)
        self.assertTrue(event["safeForDisplay"])
        self.assertEqual(events[0]["stream"], "metrics")
        self.assertEqual(events[0]["protocolVersion"], 1)
        self.assertEqual({item["requestId"] for item in events}, {events[0]["requestId"]})


if __name__ == "__main__":
    ReleaseBase.create()
    try:
        unittest.main(verbosity=2)
    finally:
        shutil.rmtree(ReleaseBase.root, ignore_errors=True)
