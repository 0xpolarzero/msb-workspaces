#!/usr/bin/python3
"""Comprehensive release tests for MicroSandbox Workspaces.

The suite installs the package into a clean fake home, drives the real `msw`
CLI, uses a stateful MicroSandbox simulator, and uses real local Git/bare
repositories for clone, pull, bundle, push, force-with-lease, and LFS flows.
"""
from __future__ import annotations

import contextlib
import hashlib
import hmac
import http.client
import http.server
import io
import json
import os
import re
import select
import signal
import shutil
import socket
import stat
import sys
import time
import subprocess
import tarfile
import tempfile
import textwrap
import threading
import unittest
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Iterable, Iterator

PACKAGE = Path(__file__).resolve().parents[1]
FAKE_MSB = PACKAGE / "tests" / "fake_msb.py"
FAKE_SSH = PACKAGE / "tests" / "fake_ssh.sh"
FAKE_SSH_FORWARDER = PACKAGE / "tests" / "fake_ssh_forwarder.py"
FAKE_CURL = PACKAGE / "tests" / "fake_curl.py"
FAKE_ZED = PACKAGE / "tests" / "fake_zed.sh"
FAKE_OPEN = PACKAGE / "tests" / "fake_open.sh"
FAKE_SECURITY = PACKAGE / "tests" / "fake_security.py"
FAKE_GITHUB = PACKAGE / "tests" / "fake_github.py"
FAKE_GH = PACKAGE / "tests" / "fake_gh.py"
FAKE_API_CURL = PACKAGE / "tests" / "fake_api_curl.py"
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
                # Phase 0 suite exercises the legacy Connect flow; Path C
                # local-mode tests (GitHubProxyContractTests) set
                # MSW_GITHUB_MODE=local explicitly.
                "MSW_GITHUB_MODE": "connect",
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


class _FakeGitHubHandle:
    """Handle to a running tests/fake_github.py server (see TestEnv.start_fake_github)."""

    def __init__(self, env: dict[str, str], state_dir: Path, err_log) -> None:
        self.env = env
        self.state_dir = state_dir
        self.port = 0
        self.proc: subprocess.Popen[str] | None = None
        self._err_path = Path(err_log.name)
        self._err_log = err_log
        self.closed = False

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def start(self) -> None:
        self.proc = subprocess.Popen(
            ["/usr/bin/python3", str(FAKE_GITHUB), "--serve"],
            env=self.env,
            cwd=str(PACKAGE),
            stdout=subprocess.PIPE,
            stderr=self._err_log,
            text=True,
        )
        assert self.proc.stdout is not None
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise AssertionError(
                    f"fake github exited early (rc={self.proc.returncode}):\n{self.err_text()}"
                )
            ready, _, _ = select.select([self.proc.stdout], [], [], 0.5)
            if not ready:
                continue
            line = self.proc.stdout.readline()
            match = re.match(r"FAKE_GITHUB_READY port=(\d+)", line)
            if match:
                self.port = int(match.group(1))
                return
        self.close()
        raise AssertionError(f"fake github did not become ready:\n{self.err_text()}")

    def requests(self) -> list[dict]:
        path = self.state_dir / "requests.jsonl"
        if not path.exists():
            return []
        records = []
        for line in path.read_text().splitlines():
            if not line.strip():
                continue
            try:
                records.append(json.loads(line))
            except ValueError:
                continue
        return records

    def set_control(self, control: dict) -> None:
        (self.state_dir / "control.json").write_text(json.dumps(control, sort_keys=True))

    def err_text(self) -> str:
        try:
            return self._err_path.read_text(errors="replace")
        except OSError:
            return ""

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        if self.proc is not None and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)
        if self.proc is not None and self.proc.stdout is not None:
            self.proc.stdout.close()
        if self._err_log is not None:
            try:
                self._err_log.close()
            except OSError:
                pass
            self._err_log = None


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

    def app_bootstrap(self, *, check: bool = True, timeout: int = 90) -> subprocess.CompletedProcess[str]:
        workspace_input = (self.home / ".config/msw/workspaces.json").read_text()
        return self.msw(
            "app", "bootstrap", "--resume", "--workspace-config-fd", "0", "--format", "json",
            input_text=workspace_input, check=check, timeout=timeout,
        )

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

    @contextlib.contextmanager
    def start_fake_github(self, *, extra_env: dict[str, str] | None = None) -> Iterator[_FakeGitHubHandle]:
        """Start the stateful fake GitHub server (tests/fake_github.py) for this env.

        Binds an ephemeral port on 127.0.0.1, points the server at this env's
        on-disk bare remote root (the MSW_TEST_GITHUB_REMOTE_ROOT layout), and
        yields a handle exposing .port / .base_url / .state_dir / .requests() /
        .set_control(). The server process is terminated on exit; its state
        dir lives under this env's root and is removed with it. See the env
        interface comment block at the top of tests/fake_github.py for the
        full contract (request-record schema, failure injection, endpoints).
        """
        state_dir = self.root / "fake-github"
        state_dir.mkdir(parents=True, exist_ok=True)
        remote_root = self.env.get("MSW_TEST_GITHUB_REMOTE_ROOT") or str(self.root / "remotes")
        err_log = (state_dir / "server.err").open("ab")
        env = self.env.copy()
        env.update(
            {
                "MSW_FAKE_GITHUB_PORT": "0",
                "MSW_FAKE_GITHUB_STATE": str(state_dir),
                "MSW_FAKE_GITHUB_REMOTE_ROOT": remote_root,
            }
        )
        if extra_env:
            env.update(extra_env)
        handle = _FakeGitHubHandle(env, state_dir, err_log)
        handle.start()
        try:
            yield handle
        finally:
            handle.close()


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
        for script in [PACKAGE / "bin/msw-ssh-proxy", PACKAGE / "bin/msw-git-askpass",
                       PACKAGE / "bin/msw-github-proxy", PACKAGE / "bin/msw-github-host-token"]:
            run_cmd(["sh", "-n", script])
        run_cmd(["/usr/bin/python3", "-m", "py_compile", FAKE_MSB, FAKE_CURL, FAKE_SECURITY, FAKE_GITHUB,
                 FAKE_GH, FAKE_API_CURL, FAKE_SSH_FORWARDER,
                 PACKAGE / "bin/msw-keychain-bridge",
                 PACKAGE / "lib/proxycore.py", PACKAGE / "lib/proxy-upstream.py",
                 PACKAGE / "lib/msw-port-forwarder.py"])
        plist = PACKAGE / "launchd" / "org.microsandbox.MSWMonitor.github-proxy.plist"
        run_cmd(["/usr/bin/plutil", "-lint", plist])
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
        for stale in ("msw auth", "msw selftest", "--skip-update", "msw github setup dev"):
            self.assertNotIn(stale, docs)
        self.assertIn("Connect GitHub", docs)
        self.assertIn("MSW Monitor", docs)
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
        # Setup's completion text must describe the local-mode GitHub UX, not
        # the retired connect-mode per-workspace command.
        self.assertNotIn("msw github setup dev", setup)
        # Recreated VMs regenerate host keys; only the dedicated MSW file is
        # ever touched, and only for the box being recreated.
        self.assertIn('ssh-keygen -R "${box}.msb" -f "$HOME/.ssh/msw_known_hosts"', setup)
        self.assertIn("msw_known_hosts", msw)
        # No code path may touch the GLOBAL ~/.ssh/known_hosts: bin/msw never
        # removes host keys at all, and setup's only removal names the
        # dedicated file explicitly.
        self.assertNotIn("ssh-keygen -R", msw)
        self.assertNotIn("ssh-keygen -R", setup.replace(
            'ssh-keygen -R "${box}.msb" -f "$HOME/.ssh/msw_known_hosts"', ""))
        # Fresh-home release blocker: ~/.local/state/msw is created (mode
        # 0700) BEFORE the proxy/forwarder launch agents are rendered or
        # loaded (their launchd plists log into it), and setup verifies every
        # loaded job stays alive (socket agent: idle-valid) before success.
        state_mkdir = setup.index('"$HOME/.local/state/msw"')
        self.assertLess(state_mkdir, setup.index("__proxy-plist-render"))
        self.assertLess(state_mkdir, setup.index("__port-forwarder-start"))
        self.assertIn('chmod 0700 "$HOME/.local/state/msw"', setup)
        self.assertIn("verify_launchd_job_alive", setup)
        self.assertIn("did not stay loaded and running", setup)
        self.assertIn("verify_launchd_job_alive org.microsandbox.MSWMonitor.github-proxy socket", setup)
        # Host prerequisite: the GitHub CLI is installed with the other
        # Homebrew tools so a clean Mac can sign in via gh web OAuth; no
        # OAuth client ID is invented in the installer or config.
        self.assertIn("brew install gnu-tar zstd git-lfs gh", setup)
        config_text = (PACKAGE / "config.sh").read_text()
        self.assertIn("gh", config_text)
        self.assertNotRegex(config_text, r"[Cc]lient.?[Ii]d\s*[=:]|[Ii]d\s*[=:]\s*[A-Za-z0-9]{8,}")
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
    def test_askpass_reads_schema3_installation_token(self) -> None:
        state_path = self.env.root / "askpass-app-security.json"
        service = "msw.github.app.dev.host.tokens"
        raw = json.dumps({
            "schemaVersion": 3,
            "grantID": "00000000-0000-0000-0000-000000000001",
            "accessToken": "ghs_host_installation_token",
            "accessExpiresAt": "2099-08-08T08:00:00Z",
            "generation": 1,
        })
        security_env = self.env.env.copy()
        security_env.update({
            "MSW_FAKE_SECURITY_STATE": str(state_path),
            "MSW_SECURITY_BIN": str(FAKE_SECURITY),
        })
        run_cmd(
            [FAKE_SECURITY, "add-generic-password", "-s", service, "-a", "profile", "-w", raw],
            env=security_env,
        )
        askpass_env = security_env.copy()
        askpass_env.update({
            "MSW_TEST_KEYCHAIN_DIR": "",
            "MSW_APP_KEYCHAIN_SERVICE": service,
            "MSW_APP_KEYCHAIN_ACCOUNT": "profile",
            "MSW_JQ_BIN": shutil.which("jq") or "",
            "MSW_KEYCHAIN_HOME": str(self.env.home),
            "MSW_FAKE_SECURITY_HOME": str(self.env.home),
        })
        proc = run_cmd(
            [PACKAGE / "bin/msw-git-askpass", "Password for https://github.com:"],
            env=askpass_env,
        )
        self.assertEqual(proc.stdout, "ghs_host_installation_token\n")


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
            # Published ports are forwarded host-side over SSH
            # (lib/msw-port-forwarder.py): msb is never given --port args.
            self.assertEqual(sb["ports"], [])
            self.assertNotIn("--port", sb["args"])
            self.assertEqual(sb["labels"]["msw.managed"], "true")
            args = sb["args"]
            self.assertEqual(args[args.index("--memory") + 1], expected_memory[box][0])
            self.assertEqual(args[args.index("--max-memory") + 1], expected_memory[box][1])
            # Every create records the desired port list for the forwarder.
            record = json.loads((
                self.env.home / ".config" / "msw" / "workspace-state" / f"{box}.json"
            ).read_text())
            self.assertEqual(record["schemaVersion"], 1)
            self.assertIn(f"{ip}:3000:3000", record["desiredPorts"])
            self.assertIn(f"{ip}:5173:5173", record["desiredPorts"])
            self.assertIn(f"{ip}:24678:24678", record["desiredPorts"])
            self.assertIn(f"{ip}:24679:24679", record["desiredPorts"])
            self.assertEqual(record["skippedPorts"], [])
        # Release blocker regression: the proxy and port-forwarder launch
        # agents log into ~/.local/state/msw, which setup.sh must create
        # (mode 0700) on a fresh home before any agent is rendered/loaded.
        state_dir = self.env.home / ".local" / "state" / "msw"
        self.assertTrue(state_dir.is_dir())
        self.assertEqual(oct(state_dir.stat().st_mode & 0o777), "0o700")

    def test_recreate_cleans_stale_host_key_from_dedicated_known_hosts(self) -> None:
        # Recreated VMs regenerate their host keys: the stale entry must be
        # removed from the DEDICATED MSW known-hosts file only, and only for
        # the box that is actually recreated — never from ~/.ssh/known_hosts
        # and never for other boxes or unrelated hosts.
        ssh_dir = self.env.home / ".ssh"
        ssh_dir.mkdir(parents=True, exist_ok=True)
        # macOS ssh-keygen -R validates every line, so seed real keys.
        key_dir = self.env.root / "known-hosts-key"
        key_dir.mkdir()
        run_cmd(["ssh-keygen", "-t", "ed25519", "-N", "", "-f", str(key_dir / "id")], env=self.env.env)
        pub = (key_dir / "id.pub").read_text().strip()
        known_hosts = ssh_dir / "msw_known_hosts"
        known_hosts.write_text(
            f"dev.msb {pub} stale-dev\n"
            f"playgrounds.msb {pub} stale-playgrounds\n"
            f"unrelated.example {pub} unrelated\n"
        )
        global_hosts = ssh_dir / "known_hosts"
        global_hosts.write_text(f"dev.msb {pub} global\n")
        global_sha = hashlib.sha256(global_hosts.read_bytes()).hexdigest()
        # Simulate a partial install where only dev exists: with
        # --recreate-workspaces, dev goes through the rm + host-key cleanup
        # path while the other workspaces are freshly created.
        state = self.env.state()
        state["sandboxes"].pop("playgrounds", None)
        state["sandboxes"].pop("personal", None)
        self.env.state_file.write_text(json.dumps(state, indent=2, sort_keys=True))

        self.env.setup("--recreate-workspaces")

        remaining = known_hosts.read_text()
        self.assertNotIn("dev.msb", remaining)
        self.assertIn("playgrounds.msb", remaining)
        self.assertIn("unrelated.example", remaining)
        self.assertEqual(hashlib.sha256(global_hosts.read_bytes()).hexdigest(), global_sha)
        # The ssh config routes MSW host keys to the dedicated file, which
        # host repair creates mode 0600.
        config = (ssh_dir / "config.d" / "msw.conf").read_text()
        self.assertIn("UserKnownHostsFile", config)
        self.assertIn("msw_known_hosts", config)
        self.assertEqual(oct(known_hosts.stat().st_mode & 0o777), "0o600")

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
        config.write_text(config.read_text().replace('MSW_ROOT_DISK="48G"', 'MSW_ROOT_DISK="broken"'))
        self.env.setup("--reset-config", "--rebuild-base")
        self.assertIn('MSW_ROOT_DISK="48G"', config.read_text())
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
        proc = self.env.app_bootstrap()
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

    def test_app_bootstrap_applies_typed_workspace_configuration_end_to_end(self) -> None:
        marker = self.env.root / "shell-interpolation-must-not-run"
        invalid = {
            "schemaVersion": 1,
            "workspaces": [{
                "name": f"lab$(touch {marker})", "cpu": 4, "cpuCeiling": 8,
                "memoryGiB": 16, "memoryCeilingGiB": 32,
                "workspaceStorageGiB": 60, "runtimeStorageGiB": 60,
            }],
        }
        rejected = self.env.msw(
            "app", "bootstrap", "--resume", "--workspace-config-fd", "0", "--format", "json",
            input_text=json.dumps(invalid), check=False, timeout=90,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertEqual(json.loads(rejected.stdout)["error"]["code"], "MSW_WORKSPACE_CONFIGURATION_FAILED")
        self.assertFalse(marker.exists())

        previous_configuration = json.loads(
            (self.env.home / ".config/msw/workspaces.json").read_text()
        )
        unknown_field = json.loads(json.dumps(previous_configuration))
        unknown_field["workspaces"][0]["host"] = f"dev.msw.test; touch {marker}"
        rejected = self.env.msw(
            "app", "bootstrap", "--resume", "--workspace-config-fd", "0", "--format", "json",
            input_text=json.dumps(unknown_field), check=False, timeout=90,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertEqual(json.loads(rejected.stdout)["error"]["code"], "MSW_WORKSPACE_CONFIGURATION_FAILED")
        self.assertEqual(
            json.loads((self.env.home / ".config/msw/workspaces.json").read_text()),
            previous_configuration,
        )
        self.assertFalse(marker.exists())

        policy_file = self.env.home / "Library/Application Support/MSW Monitor/github-policy.json"
        policy_file.parent.mkdir(parents=True, exist_ok=True)
        policy_file.write_text(json.dumps({
            "schemaVersion": 1,
            "workspaces": {
                "dev": {"capability": "a" * 48, "repos": []},
                "playgrounds": {"capability": "b" * 48, "repos": []},
                "personal": {"capability": "c" * 48, "repos": []},
            },
        }))
        stale_forwarder = (
            self.env.home / "Library/LaunchAgents/"
            "org.microsandbox.MSWMonitor.port-forwarder.playgrounds.plist"
        )
        stale_forwarder.parent.mkdir(parents=True, exist_ok=True)
        stale_forwarder.write_text("stale fixture")
        initial_state = self.env.state()
        personal_workspace = Path(initial_state["volumes"]["msw-personal-workspace"]["path"])
        personal_runtime = Path(initial_state["volumes"]["msw-personal-runtime"]["path"])
        (personal_workspace / "repository-data").write_text("preserved")
        (personal_runtime / "runtime-data").write_text("preserved")

        desired = {
            "schemaVersion": 1,
            "workspaces": [
                {"name": "development", "cpu": 12, "cpuCeiling": 12,
                 "memoryGiB": 48, "memoryCeilingGiB": 48,
                 "workspaceStorageGiB": 120, "runtimeStorageGiB": 100},
                {"name": "personal", "cpu": 4, "cpuCeiling": 8,
                 "memoryGiB": 16, "memoryCeilingGiB": 32,
                 "workspaceStorageGiB": 80, "runtimeStorageGiB": 60},
                {"name": "lab", "cpu": 6, "cpuCeiling": 12,
                 "memoryGiB": 32, "memoryCeilingGiB": 48,
                 "workspaceStorageGiB": 100, "runtimeStorageGiB": 80},
            ],
        }
        proc = self.env.msw(
            "app", "bootstrap", "--resume", "--workspace-config-fd", "0", "--format", "json",
            input_text=json.dumps(desired), timeout=90,
        )
        self.assertTrue(json.loads(proc.stdout)["ok"])
        state = self.env.state()
        self.assertEqual(set(state["sandboxes"]), {"development", "personal", "lab"})
        self.assertNotIn("playgrounds", state["sandboxes"])
        personal_args = state["sandboxes"]["personal"]["args"]
        self.assertEqual(personal_args[personal_args.index("--cpus") + 1], "4")
        self.assertEqual(personal_args[personal_args.index("--max-cpus") + 1], "8")
        self.assertEqual(personal_args[personal_args.index("--memory") + 1], "16G")
        self.assertEqual(personal_args[personal_args.index("--max-memory") + 1], "32G")
        self.assertIn("msw-personal-workspace:/workspace:kind=disk,size=80G", personal_args)
        self.assertIn("msw-personal-runtime:/var/lib/msw-runtime:kind=disk,size=60G", personal_args)
        self.assertEqual(state["volumes"]["msw-personal-workspace"]["size"], "80G")
        self.assertEqual(state["volumes"]["msw-personal-runtime"]["size"], "60G")
        self.assertEqual((personal_workspace / "repository-data").read_text(), "preserved")
        self.assertEqual((personal_runtime / "runtime-data").read_text(), "preserved")
        self.assertNotIn("msw-personal-workspace-resize", state["volumes"])
        self.assertNotIn("msw-personal-runtime-resize", state["volumes"])
        persisted = json.loads((self.env.home / ".config/msw/workspaces.json").read_text())
        self.assertEqual(persisted, desired)
        self.assertEqual(set(json.loads(policy_file.read_text())["workspaces"]), {"personal"})
        self.assertFalse(stale_forwarder.exists())
        self.assertIn("Host *.msb", (self.env.home / ".ssh/config.d/msw.conf").read_text())
        test_hosts = (self.env.home / ".config/msw/test-host/hosts").read_text()
        self.assertIn("127.0.0.10 development.msw.test", test_hosts)
        self.assertIn("127.0.0.11 personal.msw.test", test_hosts)
        self.assertIn("127.0.0.12 lab.msw.test", test_hosts)
        self.assertNotIn("playgrounds.msw.test", test_hosts)

        observed = json.loads(self.env.msw("app", "state", "--format", "json").stdout)
        self.assertEqual(
            [workspace["id"] for workspace in observed["result"]["workspaces"]],
            ["development", "personal", "lab"],
        )
        relaunched = self.env.msw("app", "handshake", "--format", "json")
        self.assertEqual(json.loads(relaunched.stdout)["result"]["capabilities"]["workspaceCount"], 3)

    def test_app_bootstrap_typed_reconnect_error_when_github_credential_missing(self) -> None:
        meta = self.env.home / ".config/msw/github/dev.conf"
        meta.parent.mkdir(parents=True, exist_ok=True)
        meta.write_text("verification_repo=acme/demo\naccess=host-write\n")
        proc = self.env.app_bootstrap(check=False)
        self.assertNotEqual(proc.returncode, 0)
        envelope = json.loads(proc.stdout)
        self.assertFalse(envelope["ok"])
        self.assertEqual(envelope["error"]["code"], "MSW_GITHUB_RECONNECT_REQUIRED")
        self.assertEqual(envelope["error"]["workspace"], "dev")
        self.assertIn("Connect GitHub for 'dev'", envelope["error"]["recovery"])
        self.assertTrue(envelope["error"]["retryable"])
        # An already-running workspace is verified without a false reconnect error.
        meta.unlink()
        self.env.msw("start", "dev")
        meta.write_text("verification_repo=acme/demo\naccess=host-write\n")
        proc = self.env.app_bootstrap()
        self.assertTrue(json.loads(proc.stdout)["ok"])
        meta.unlink()
        # Other verification failures carry the sanitized check output so the
        # user can see why verification failed instead of a generic message.
        quarantine = self.env.home / ".config/msw/github/dev.quarantine"
        quarantine.write_text("failed setup transaction\n")
        proc = self.env.app_bootstrap(check=False)
        self.assertNotEqual(proc.returncode, 0)
        envelope = json.loads(proc.stdout)
        self.assertFalse(envelope["ok"])
        self.assertEqual(envelope["error"]["code"], "MSW_BOOTSTRAP_VERIFICATION_FAILED")
        self.assertIn("Verification reported:", envelope["error"]["recovery"])
        self.assertIn("quarantined", envelope["error"]["recovery"])
        quarantine.unlink()

    def test_app_github_unbind_clears_legacy_metadata_so_bootstrap_completes(self) -> None:
        meta = self.env.home / ".config/msw/github/dev.conf"
        meta.parent.mkdir(parents=True, exist_ok=True)
        meta.write_text("verification_repo=acme/demo\naccess=host-write\n")
        read_record = self.env.key_file("msw.github.read", "dev")
        write_record = self.env.key_file("msw.github.write", "dev")
        read_record.write_text("legacy-read-token")
        write_record.write_text("legacy-write-token")
        # The reconnect scenario is a configured workspace whose read
        # credential is unavailable (the orphan host-write record remains).
        read_record.unlink()
        proc = self.env.app_bootstrap(check=False)
        self.assertNotEqual(proc.returncode, 0)
        envelope = json.loads(proc.stdout)
        self.assertEqual(envelope["error"]["code"], "MSW_GITHUB_RECONNECT_REQUIRED")
        self.assertEqual(envelope["error"]["workspace"], "dev")

        # A failing security backend proves the cleanup is fail-closed: the
        # unbind quarantines and reports a typed error instead of claiming
        # success while legacy records are still present.
        state_path = self.env.root / "fake-security-unbind-state.json"
        failed_env = {
            "MSW_TEST_KEYCHAIN_DIR": "",
            "MSW_SECURITY_BIN": str(FAKE_SECURITY),
            "MSW_FAKE_SECURITY_STATE": str(state_path),
            "MSW_FAKE_SECURITY_MODE": "delete-failure",
        }
        failed = json.loads(self.env.msw(
            "app", "github-unbind", "--workspace", "dev", "--format", "json",
            check=False, extra_env=failed_env,
        ).stdout)
        self.assertFalse(failed["ok"], failed)
        self.assertEqual(failed["error"]["code"], "MSW_GITHUB_LEGACY_CLEANUP_FAILED")
        quarantine = self.env.home / ".config/msw/github/dev.quarantine"
        self.assertTrue(quarantine.exists(), "a failed unbind must quarantine the workspace")
        self.assertTrue(
            write_record.exists(),
            "an unproven deletion must not be reported as success",
        )

        # A successful retry removes the legacy capability file and BOTH legacy
        # Keychain records, clears the quarantine marker (so bootstrap deep
        # verification no longer dies at assert_not_quarantined), and lets the
        # next bootstrap reach .complete — the app's "Continue without GitHub"
        # can then unblock Done.
        unbind = json.loads(self.env.msw(
            "app", "github-unbind", "--workspace", "dev", "--format", "json"
        ).stdout)
        self.assertTrue(unbind["ok"], unbind)
        self.assertTrue(unbind["result"]["unbound"])
        self.assertFalse(meta.exists() or meta.is_symlink())
        self.assertFalse(read_record.exists(), "the legacy read record must be removed")
        self.assertFalse(write_record.exists(), "the legacy host-write record must be removed")
        self.assertFalse(quarantine.exists(), "a successful unbind must clear the quarantine")
        self.env.msw("start", "dev")
        proc = self.env.app_bootstrap()
        envelope = json.loads(proc.stdout)
        self.assertTrue(envelope["ok"], envelope.get("error"))
        self.assertEqual(envelope["result"]["phase"], "complete")

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

    def test_clone_and_pull_ignore_connect_repository_names_gate(self) -> None:
        """Local-mode clone/pull ignore dormant Connect repositoryNames.

        With the SAME Connect-style dev.guest metadata (credentials.json with
        repositoryNames EXCLUDING acme/demo), default MSW_GITHUB_MODE=connect
        still enforces the metadata gate: the clone must fail with "not
        assigned", because Connect mode places a guest token in the VM and
        cannot prove anonymous forwarding. Explicit MSW_GITHUB_MODE=local
        reads NO Connect grants, so the dormant metadata must not gate the
        anonymous clone or the subsequent fast-forward pull -- the old
        repositoryNames gate fataled here.
        """
        self.env.init_remote()
        self.env.configure_tokens("dev", "acme/demo")  # read token for guest exec
        # Connect-style guest grant that does NOT include acme/demo.
        credentials = self.env.home / "Library/Application Support/MSW Monitor/credentials.json"
        credentials.parent.mkdir(parents=True, exist_ok=True)
        credentials.write_text(json.dumps({
            "schemaVersion": 2,
            "entries": {
                "dev.guest": {
                    "workspace": "dev",
                    "schemaVersion": 2,
                    "role": "guest",
                    "provider": "github-app-installation",
                    "appClientID": "guest-public",
                    "accountLogin": "alice",
                    "owner": "acme",
                    "repositoryNames": ["acme/other"],
                    "repositoryIDs": [34],
                    "accessMode": "read-only",
                    "verificationRepository": "acme/other",
                    "installationID": 123,
                    "accessExpiresAt": "2030-01-01T00:00:00Z",
                    "refreshExpiresAt": "2030-01-01T00:00:00Z",
                    "needsRestart": False,
                    "generation": 1,
                    "quarantined": False,
                    "updatedAt": "2026-08-08T00:00:00Z",
                    "recoveryState": "ready",
                }
            },
        }))
        # Connect mode (default in this suite) still enforces the metadata
        # gate: acme/demo is not in repositoryNames, so the clone fails.
        self.assertFailed(
            self.env.msw("clone", "dev", "acme/demo", "clients/acme/connect-blocked",
                         check=False),
            "not assigned")
        # acme/demo is NOT in repositoryNames: the old require_repository_access
        # gate fataled here; the read paths now clone anonymously.
        self.env.msw("clone", "dev", "acme/demo", "clients/acme/backend",
                     extra_env={"MSW_GITHUB_MODE": "local"})
        repo = self.env.guest_repo("dev", "clients/acme/backend")
        self.assertTrue((repo / ".git").is_dir())

        # an upstream commit must pull through the same anonymous read path
        updater = self.env.root / "updater"
        run_cmd([SYSTEM_GIT, "clone", str(self.env.root / "remotes" / "acme" / "demo.git"), str(updater)],
                env=self.env.env)
        run_cmd([SYSTEM_GIT, "-C", updater, "config", "user.name", "Updater"], env=self.env.env)
        run_cmd([SYSTEM_GIT, "-C", updater, "config", "user.email", "updater@example.invalid"], env=self.env.env)
        (updater / "remote.txt").write_text("remote\n")
        run_cmd([SYSTEM_GIT, "-C", updater, "add", "remote.txt"], env=self.env.env)
        run_cmd([SYSTEM_GIT, "-C", updater, "commit", "-m", "Remote update"], env=self.env.env)
        run_cmd([SYSTEM_GIT, "-C", updater, "push", "origin", "main"], env=self.env.env)

        self.env.msw("pull", "dev", "clients/acme/backend",
                     extra_env={"MSW_GITHUB_MODE": "local"})
        self.assertEqual((repo / "remote.txt").read_text(), "remote\n")


class PublishedPortWarningTests(MSWTestCase):
    """Warn-and-skip for published ports under host-managed forwarding.

    msb is never given --port args; lib/msw-port-forwarder.py forwards free
    ports over SSH and persists occupied ones as skippedPorts. MSW_TEST_PORT_CONFLICTS
    (ip:port pairs) restricts the forwarder's real probe to the port the
    fixture pre-binds, so these tests never depend on what else happens to
    listen on the host; a start without the seam probes nothing (test mode).
    """

    @contextlib.contextmanager
    def _bound_port(self, ip: str = "127.0.0.10", port: int = 3000) -> Iterator[None]:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        bound = False
        try:
            sock.bind((ip, port))
            sock.listen(1)
            bound = True
        except OSError:
            # Already occupied on the host (e.g. a leftover sandbox port
            # forwarder); the conflict the probe detects is real either way.
            sock.close()
            bound = False
        try:
            yield
        finally:
            if bound:
                sock.close()

    def _state_record(self, box: str = "dev") -> dict:
        path = self.env.home / ".config" / "msw" / "workspace-state" / f"{box}.json"
        return json.loads(path.read_text())

    def _wait_for_state(self, predicate, timeout: int = 20) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                if predicate(self._state_record()):
                    return True
            except (OSError, ValueError):
                pass
            time.sleep(0.1)
        return False

    def _root_marker(self) -> Path:
        return self.env.home / ".microsandbox" / "guests" / "dev" / "rootfs" / "msw-root-marker"

    def _event_names(self, since: int = 0) -> list[str]:
        return [e.get("event") for e in self.env.state().get("events", [])[since:]]

    def test_prebound_published_port_is_skipped_with_warning_and_surfaced(self) -> None:
        # The port stays occupied across create AND start: the forwarder only
        # skips a port while it is genuinely in use.
        with self._bound_port():
            proc = self.env.setup(
                "--recreate-workspaces",
                extra_env={"MSW_TEST_PORT_CONFLICTS": "127.0.0.10:3000"},
            )
            # Create never fails or warns about ports: msb binds none.
            self.assertNotIn("skipping published ports", proc.stdout + proc.stderr)
            # The deep check at the end of setup boots the VM and kicks the
            # forwarder, which surfaces the occupied port immediately.
            self.assertTrue(self._wait_for_state(lambda r: r["skippedPorts"] == [3000]))
            self.env.msw("start", "dev", extra_env={"MSW_TEST_PORT_CONFLICTS": "127.0.0.10:3000"})
            self.assertTrue(self._wait_for_state(lambda r: r["skippedPorts"] == [3000]))

        state = self.env.state()
        self.assertEqual(state["sandboxes"]["dev"]["ports"], [])
        self.assertEqual(state["sandboxes"]["playgrounds"]["ports"], [])
        self.assertEqual(state["sandboxes"]["personal"]["ports"], [])
        for box in ("dev", "playgrounds", "personal"):
            self.assertNotIn("--port", state["sandboxes"][box]["args"])

        record = self._state_record()
        self.assertEqual(record["schemaVersion"], 1)
        self.assertEqual(record["skippedPorts"], [3000])
        self.assertEqual(record["stillInUse"], [3000])
        self.assertIn("127.0.0.10:3000:3000", record["desiredPorts"])
        self.assertIn("127.0.0.10:5173:5173", record["desiredPorts"])
        self.assertIn("127.0.0.10:24678:24678", record["desiredPorts"])
        self.assertEqual(self._state_record("playgrounds")["skippedPorts"], [])
        self.assertEqual(self._state_record("personal")["skippedPorts"], [])

        document = json.loads(self.env.msw("app", "state", "--format", "json").stdout)
        self.assertTrue(document["ok"])
        workspaces = {w["id"]: w for w in document["result"]["workspaces"]}
        self.assertEqual(workspaces["dev"]["skippedPorts"], [3000])
        self.assertIn("3000", workspaces["dev"]["portWarning"])
        self.assertIn("127.0.0.10", workspaces["dev"]["portWarning"])
        self.assertEqual(workspaces["playgrounds"]["skippedPorts"], [])
        self.assertEqual(workspaces["playgrounds"]["portWarning"], "")
        self.assertEqual(workspaces["personal"]["skippedPorts"], [])
        self.assertEqual(workspaces["personal"]["portWarning"], "")

    def test_start_skips_bound_port_without_touching_the_sandbox(self) -> None:
        self.env.setup("--recreate-workspaces")
        marker = self._root_marker()
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text("root survives\n")
        before_events = len(self.env.state().get("events", []))
        with self._bound_port():
            proc = self.env.msw(
                "start", "dev",
                extra_env={"MSW_TEST_PORT_CONFLICTS": "127.0.0.10:3000"},
            )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        state = self.env.state()
        dev = state["sandboxes"]["dev"]
        self.assertTrue(dev["running"])
        self.assertEqual(dev["ports"], [])
        # Sandbox identity and root are untouched: no create/rm/run events
        # (only the expected msb `start`), and the root marker survives.
        self.assertEqual(self._event_names(before_events), ["start"])
        self.assertTrue(marker.exists())
        self.assertTrue(self._wait_for_state(lambda r: r["skippedPorts"] == [3000]))
        self.assertEqual(self._state_record()["stillInUse"], [3000])

    def test_restart_skips_bound_port_without_touching_the_sandbox(self) -> None:
        self.env.setup("--recreate-workspaces")
        marker = self._root_marker()
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text("root survives\n")
        before_events = len(self.env.state().get("events", []))
        with self._bound_port():
            proc = self.env.msw(
                "restart", "dev",
                extra_env={"MSW_TEST_PORT_CONFLICTS": "127.0.0.10:3000"},
            )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        state = self.env.state()
        self.assertTrue(state["sandboxes"]["dev"]["running"])
        self.assertEqual(state["sandboxes"]["dev"]["ports"], [])
        self.assertEqual(self._event_names(before_events), ["restart"])
        self.assertTrue(marker.exists())
        self.assertTrue(self._wait_for_state(lambda r: r["skippedPorts"] == [3000]))

    def test_freed_port_is_forwarded_again_on_next_start(self) -> None:
        with self._bound_port():
            self.env.setup(
                "--recreate-workspaces",
                extra_env={"MSW_TEST_PORT_CONFLICTS": "127.0.0.10:3000"},
            )
            self.env.msw("start", "dev", extra_env={"MSW_TEST_PORT_CONFLICTS": "127.0.0.10:3000"})
        self.assertTrue(self._wait_for_state(lambda r: r["skippedPorts"] == [3000]))
        self.assertIn("127.0.0.10:3000:3000", self._state_record()["desiredPorts"])
        before_events = len(self.env.state().get("events", []))
        # Port is free now: the next start (no seam -> nothing probed) must
        # restore the mapping with no sandbox changes.
        self.env.msw("start", "dev")
        self.assertTrue(self._wait_for_state(lambda r: r["skippedPorts"] == []))
        record = self._state_record()
        self.assertEqual(record["stillInUse"], [])
        self.assertIn("127.0.0.10:3000:3000", record["desiredPorts"])
        state = self.env.state()
        self.assertTrue(state["sandboxes"]["dev"]["running"])
        self.assertEqual(state["sandboxes"]["dev"]["ports"], [])
        self.assertEqual(self._event_names(before_events), [])
        document = json.loads(self.env.msw("app", "state", "--format", "json").stdout)
        workspaces = {w["id"]: w for w in document["result"]["workspaces"]}
        self.assertEqual(workspaces["dev"]["skippedPorts"], [])

    def test_all_free_create_is_unchanged(self) -> None:
        proc = self.env.setup("--recreate-workspaces")
        self.assertNotIn("skipping published ports", proc.stdout + proc.stderr)
        state = self.env.state()
        for box in ("dev", "playgrounds", "personal"):
            self.assertEqual(state["sandboxes"][box]["ports"], [])
            self.assertNotIn("--port", state["sandboxes"][box]["args"])
            record = self._state_record(box)
            self.assertEqual(record["skippedPorts"], [])
            self.assertEqual(record["stillInUse"], [])
            self.assertTrue(record["desiredPorts"])


class PortForwarderHelperTests(unittest.TestCase):
    """Unit tests for lib/msw-port-forwarder.py with fake ssh and fake msb.

    The real probe is gated by MSW_TEST_PORT_CONFLICTS (ip:port) so the suite
    never depends on what else listens on the host; MSW_TEST_PORT_CONFLICTS_FILE
    flips the occupied set deterministically to exercise the live reconcile.
    """

    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="msw-forwarder-"))
        self.home = self.root / "home"
        (self.home / ".config" / "msw").mkdir(parents=True)
        (self.home / ".config" / "msw" / "config.sh").write_text(
            'MSW_PUBLISHED_PORTS="3000,5173,8080"\n'
        )
        (self.home / ".config" / "msw" / "workspaces.json").write_text(json.dumps({
            "schemaVersion": 1,
            "workspaces": [{
                "name": "dev", "cpu": 4, "cpuCeiling": 8,
                "memoryGiB": 16, "memoryCeilingGiB": 32,
                "workspaceStorageGiB": 60, "runtimeStorageGiB": 60,
            }],
        }))
        self.state_file = self.home / ".config" / "msw" / "workspace-state" / "dev.json"
        self.ssh_log = self.root / "ssh.log"
        self.ssh_pidfile = self.root / "ssh.pid"
        self.ssh_err = self.root / "ssh.err"
        self.simulated = self.root / "simulated.conflicts"
        self.msb_state = self.root / "msb-state"
        self.msb_state.mkdir()
        self._msb(["run", "--detach", "--name", "dev", "--", "sleep", "infinity"])

    def tearDown(self) -> None:
        self._kill_ssh()
        shutil.rmtree(self.root, ignore_errors=True)

    def _env(self, **extra) -> dict:
        env = {
            "HOME": str(self.home),
            "MSW_CONFIG_FILE": str(self.home / ".config" / "msw" / "config.sh"),
            "MSW_FAKE_STATE": str(self.msb_state),
            "MSW_MSB_BIN": str(FAKE_MSB),
            "MSW_SSH_BIN": str(FAKE_SSH_FORWARDER),
            "MSW_TEST_MODE": "1",
            "MSW_PORT_FORWARDER_INTERVAL": "0.2",
            "MSW_PORT_FORWARDER_SSH_ERR": str(self.ssh_err),
            "MSW_FAKE_SSH_LOG": str(self.ssh_log),
            "MSW_FAKE_SSH_PIDFILE": str(self.ssh_pidfile),
            "PATH": "/usr/bin:/bin",
        }
        env.update(extra)
        return env

    def _msb(self, args: list[str], check: bool = True):
        return run_cmd([FAKE_MSB, *args], env=self._env(), check=check)

    def _state(self) -> dict:
        return json.loads(self.state_file.read_text())

    def _ssh_lines(self) -> list[str]:
        if not self.ssh_log.exists():
            return []
        return [line for line in self.ssh_log.read_text().splitlines() if line.strip()]

    def _ssh_pid(self) -> int:
        return int(self.ssh_pidfile.read_text().strip())

    def _ssh_alive(self) -> bool:
        try:
            os.kill(self._ssh_pid(), 0)
            return True
        except (OSError, ValueError, FileNotFoundError):
            return False

    def _kill_ssh(self) -> None:
        try:
            os.kill(self._ssh_pid(), signal.SIGKILL)
        except (OSError, ValueError, FileNotFoundError):
            pass

    def _wait_for(self, predicate, timeout: int = 20) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                if predicate():
                    return True
            except (OSError, ValueError, FileNotFoundError):
                pass
            time.sleep(0.05)
        return False

    def _run_oneshot(self, extra_env: dict | None = None):
        env = self._env(MSW_PORT_FORWARDER_ONESHOT="1")
        if extra_env:
            env.update(extra_env)
        return run_cmd(
            ["/usr/bin/python3", str(PACKAGE / "lib/msw-port-forwarder.py"), "dev"],
            env=env,
            check=False,
            timeout=60,
        )

    @contextlib.contextmanager
    def _bound_port(self, ip: str = "127.0.0.10", port: int = 3000) -> Iterator[None]:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        bound = False
        try:
            sock.bind((ip, port))
            sock.listen(1)
            bound = True
        except OSError:
            sock.close()
            bound = False
        try:
            yield
        finally:
            if bound:
                sock.close()

    def test_oneshot_skips_bound_port_and_records_state(self) -> None:
        with self._bound_port():
            proc = self._run_oneshot(extra_env={"MSW_TEST_PORT_CONFLICTS": "127.0.0.10:3000"})
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        state = self._state()
        self.assertEqual(state["skippedPorts"], [3000])
        self.assertEqual(state["stillInUse"], [3000])
        self.assertIn("127.0.0.10:3000:3000", state["desiredPorts"])
        # One-shot cycles are state-only: no ssh process is ever spawned.
        self.assertEqual(self._ssh_lines(), [])

    def test_manager_reconciles_forwarder_without_touching_the_sandbox(self) -> None:
        self.simulated.write_text("3000\n")
        proc = subprocess.Popen(
            ["/usr/bin/python3", str(PACKAGE / "lib/msw-port-forwarder.py"), "dev"],
            env=self._env(MSW_TEST_PORT_CONFLICTS_FILE=str(self.simulated)),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            self.assertTrue(self._wait_for(lambda: len(self._ssh_lines()) >= 1))
            first = self._ssh_lines()[0]
            self.assertNotIn("127.0.0.10:3000:127.0.0.1:3000", first)
            self.assertIn("127.0.0.10:5173:127.0.0.1:5173", first)
            self.assertTrue(self._wait_for(lambda: self._state().get("skippedPorts") == [3000]))
            # The manager only pings: the sandbox is never started, stopped,
            # removed, or recreated by it.
            self.assertEqual([e.get("event") for e in self.env_msb_events()], ["create"])
            # A freed port flips the -L set: ONLY the forwarder restarts.
            self.simulated.write_text("")
            self.assertTrue(self._wait_for(lambda: self._state().get("skippedPorts") == []))
            self.assertTrue(self._wait_for(lambda: len(self._ssh_lines()) >= 2))
            second = self._ssh_lines()[-1]
            self.assertIn("127.0.0.10:3000:127.0.0.1:3000", second)
            self.assertEqual([e.get("event") for e in self.env_msb_events()], ["create"])
            # Crash self-heal: killing ssh makes the manager respawn it.
            self._kill_ssh()
            self.assertTrue(self._wait_for(lambda: len(self._ssh_lines()) >= 3))
            self.assertEqual([e.get("event") for e in self.env_msb_events()], ["create"])
            # VM stop: ssh is killed, not respawned, and the state clears.
            self._msb(["stop", "dev"])
            self.assertTrue(self._wait_for(lambda: not self._ssh_alive()))
            self.assertTrue(self._wait_for(lambda: self._state().get("skippedPorts") == []))
            settled = len(self._ssh_lines())
            time.sleep(0.8)
            self.assertEqual(len(self._ssh_lines()), settled)
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)
            self._kill_ssh()

    def env_msb_events(self) -> list[dict]:
        path = self.msb_state / "state.json"
        if not path.exists():
            return []
        return json.loads(path.read_text()).get("events", [])

    def test_manager_waits_when_vm_stopped_and_never_starts_it(self) -> None:
        self._msb(["stop", "dev"])
        proc = subprocess.Popen(
            ["/usr/bin/python3", str(PACKAGE / "lib/msw-port-forwarder.py"), "dev"],
            env=self._env(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            time.sleep(1.2)
            self.assertEqual(self._ssh_lines(), [])
            # The manager only pings: the only events are the test's own
            # create and stop — never a start/restart/rm.
            self.assertEqual([e.get("event") for e in self.env_msb_events()], ["create", "stop"])
            self.assertEqual(self._state().get("skippedPorts"), [])
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)


class InstalledProxyPackagingTests(unittest.TestCase):
    """Fresh-install proof (Path C §4/§6 packaging): a clean HOME installed
    from the repo in MSW_TEST_MODE runs the proxy stack from ~/.local ONLY —
    checkout absent from PATH/PYTHONPATH/imports — and a real git clone works
    through the INSTALLED proxy against the fake GitHub + a seeded policy.
    Also proves the rendered launch agent has no __MSW_ROOT__ placeholder."""

    def _install_env(self, root: Path, home: Path) -> dict:
        (root / "remotes").mkdir()
        (root / "keychain").mkdir()
        env = os.environ.copy()
        env.update({
            "HOME": str(home),
            "MSW_TEST_MODE": "1",
            "MSW_GITHUB_MODE": "local",
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
        })
        env["PATH"] = f"{home}/.local/bin:{env.get('PATH', '/usr/bin:/bin')}"
        return env

    def _stop_proxy(self) -> None:
        proc = getattr(self, "_proxy_proc", None)
        if proc is not None:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)
            if proc.stdout is not None:
                try:
                    proc.stdout.close()
                except OSError:
                    pass
        if getattr(self, "_proxy_err", None) is not None:
            try:
                self._proxy_err.close()
            except OSError:
                pass
        self._proxy_proc = None
        self._proxy_err = None

    def _start_installed_proxy(self, installed: Path, proxy_env: dict, err_path: Path) -> int:
        self._stop_proxy()
        err = err_path.open("ab")
        proc = subprocess.Popen(
            [str(installed / "bin" / "msw-github-proxy"), "--listen", "0"],
            env=proxy_env,
            cwd="/tmp",
            stdout=subprocess.PIPE,
            stderr=err,
            text=True,
        )
        assert proc.stdout is not None
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                err.close()
                raise AssertionError(f"installed proxy exited early:\n{err_path.read_text(errors='replace')}")
            ready, _, _ = select.select([proc.stdout], [], [], 0.5)
            if not ready:
                continue
            line = proc.stdout.readline()
            match = re.match(r"PROXY_READY port=(\d+)", line)
            if match:
                self._proxy_proc = proc
                self._proxy_err = err
                return int(match.group(1))
        err.close()
        proc.kill()
        raise AssertionError("installed proxy did not become ready")

    def tearDown(self) -> None:
        self._stop_proxy()

    def _seed_policy_and_keychain(self, root: Path, home: Path) -> Path:
        policy = home / "Library/Application Support/MSW Monitor/github-policy.json"
        policy.parent.mkdir(parents=True, exist_ok=True)
        policy.write_text(json.dumps({
            "schemaVersion": 1,
            "workspaces": {
                "dev": {"capability": DEV_CAP,
                        "repos": [{"canonical": "acme/demo", "mode": "read-write"}]},
            },
        }))
        # §5 host credential record via the MSW_TEST_KEYCHAIN_DIR seam (the
        # proxy's outbound leg needs it even for reads).
        keychain_name = (
            re.sub(r"[^A-Za-z0-9_.-]", "_", HOST_KEYCHAIN_SERVICE)
            + "__"
            + re.sub(r"[^A-Za-z0-9_.-]", "_", HOST_KEYCHAIN_ACCOUNT)
        )
        (root / "keychain" / keychain_name).write_text(json.dumps({
            "schemaVersion": 1,
            "provider": "gh-cli",
            "tokenKind": "oauth",
            "accessToken": HOST_TOKEN,
            "accountLogin": "fake-user",
            "verifiedAt": "2026-01-01T00:00:00Z",
            "generation": 1,
            "storedAt": "2026-01-01T00:00:00Z",
        }))
        # §5 nonsecret activation metadata: the helper denies unless this
        # file exists with state "active" and generation/accountLogin matching
        # the Keychain record (missing metadata => 503 from the proxy).
        meta = home / "Library/Application Support/MSW Monitor/github-host.json"
        meta.write_text(json.dumps({
            "schemaVersion": 1,
            "state": "active",
            "provider": "gh-cli",
            "tokenKind": "oauth",
            "accountLogin": "fake-user",
            "verifiedAt": "2026-01-01T00:00:00Z",
            "generation": 1,
            "storedAt": "2026-01-01T00:00:00Z",
            "repoChecks": [],
        }))
        os.chmod(meta, 0o600)
        return policy

    def _proxy_env(self, root: Path, home: Path, fake_base_url: str) -> dict:
        return {
            "HOME": str(home),
            "PATH": "/usr/bin:/bin",
            "PYTHONPATH": "",
            "MSW_GITHUB_MODE": "local",
            "MSW_POLICY_FILE": str(home / "Library/Application Support/MSW Monitor/github-policy.json"),
            "MSW_PROXY_UPSTREAM_ROOT": fake_base_url,
            "MSW_PROXY_LOG_FILE": str(root / "proxy.log"),
            "MSW_HOST_KEYCHAIN_SERVICE": HOST_KEYCHAIN_SERVICE,
            "MSW_HOST_KEYCHAIN_ACCOUNT": HOST_KEYCHAIN_ACCOUNT,
            "MSW_TEST_KEYCHAIN_DIR": str(root / "keychain"),
            "MSW_HOST_META_FILE": str(home / "Library/Application Support/MSW Monitor/github-host.json"),
        }

    def _clone_through_installed_proxy(self, fake, installed: Path, root: Path, home: Path,
                                       fake_base_url: str, tag: str) -> list[dict]:
        """Start the INSTALLED proxy (--listen) against the fake GitHub and
        clone acme/demo through it. Returns the fake's request records."""
        proxy_env = self._proxy_env(root, home, fake_base_url)
        port = self._start_installed_proxy(installed, proxy_env, root / f"installed-proxy-{tag}.err")
        git_home = root / f"git-home-{tag}"
        git_home.mkdir()
        git_env = {"HOME": str(git_home), "GIT_TERMINAL_PROMPT": "0",
                   "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin"}
        url = f"http://127.0.0.1:{port}/github.com/acme/demo.git"
        clone = run_cmd(
            [SYSTEM_GIT, "-c", f"http.extraHeader=X-MSW-Capability: {DEV_CAP}",
             "clone", url, str(root / f"cloned-{tag}")],
            env=git_env,
            timeout=120,
        )
        self.assertEqual(clone.returncode, 0, clone.stdout + clone.stderr)
        self.assertTrue((root / f"cloned-{tag}" / "README.md").exists())
        return fake.requests()

    def _launchd_socket_activation_proof(self, installed: Path, root: Path, home: Path,
                                         fake_base_url: str) -> None:
        """Bootstrap a REAL launchd agent (socket activation, Wait=false) with
        a unique test label/port, then make one request THROUGH the
        launchd-owned socket — no --listen. The installed proxy must handle
        it. Bootout + cleanup happen in finally."""
        uid = os.getuid()
        label = f"org.microsandbox.MSWMonitor.github-proxy.test{os.getpid()}"
        plist = root / f"test-proxy-{os.getpid()}.plist"
        # A free port for the socket-activated listener.
        probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        probe.bind(("127.0.0.1", 0))
        launchd_port = probe.getsockname()[1]
        probe.close()
        extra_env = "\n".join([
            f"MSW_POLICY_FILE={home / 'Library/Application Support/MSW Monitor/github-policy.json'}",
            f"MSW_PROXY_UPSTREAM_ROOT={fake_base_url}",
            f"MSW_HOST_KEYCHAIN_SERVICE={HOST_KEYCHAIN_SERVICE}",
            f"MSW_HOST_KEYCHAIN_ACCOUNT={HOST_KEYCHAIN_ACCOUNT}",
            f"MSW_TEST_KEYCHAIN_DIR={root / 'keychain'}",
            # launchd's HOME is the real home, not the test home: the
            # activation-metadata path must be explicit.
            f"MSW_HOST_META_FILE={home / 'Library/Application Support/MSW Monitor/github-host.json'}",
            f"MSW_PROXY_LOG_FILE={root / 'proxy-launchd.log'}",
        ])
        render_env = {
            "HOME": str(home),
            "PATH": "/usr/bin:/bin",
            "MSW_MSB_BIN": str(FAKE_MSB),
            "MSW_PROXY_PLIST_FILE": str(plist),
            "MSW_PROXY_PLIST_LABEL": label,
            "MSW_PROXY_PLIST_ROOT": str(installed),
            "MSW_PROXY_PLIST_LOG": str(root / "proxy-launchd.stderr.log"),
            "MSW_PROXY_PLIST_EXTRA_ENV": extra_env,
            "MSW_PROXY_PLIST_PORT": str(launchd_port),
        }
        run_cmd([str(installed / "bin" / "msw"), "__proxy-plist-render"], env=render_env)
        text = plist.read_text()
        self.assertNotIn("__MSW_ROOT__", text)
        self.assertIn(f"{installed}/bin/msw-github-proxy", text)
        self.assertIn(f"<string>{launchd_port}</string>", text)
        self.assertIn("MSW_PROXY_UPSTREAM_ROOT", text)
        self.assertIn("<false/>", text)  # Wait=false: launchd accepts, proxy reads stdin/stdout
        run_cmd(["/usr/bin/plutil", "-lint", str(plist)], env={"PATH": "/usr/bin:/bin"})
        subprocess.run(["/bin/launchctl", "bootout", f"gui/{uid}/{label}"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        boot = subprocess.run(["/bin/launchctl", "bootstrap", f"gui/{uid}", str(plist)],
                              capture_output=True, text=True)
        self.assertEqual(boot.returncode, 0, boot.stderr)
        try:
            time.sleep(1.0)
            sock = socket.create_connection(("127.0.0.1", launchd_port), timeout=30)
            sock.settimeout(30)
            request = (
                f"GET /github.com/acme/demo.git/info/refs?service=git-upload-pack HTTP/1.1\r\n"
                f"Host: 127.0.0.1:{launchd_port}\r\n"
                f"X-MSW-Capability: {DEV_CAP}\r\n"
                "Connection: close\r\n\r\n"
            ).encode("ascii")
            sock.sendall(request)
            chunks = []
            while True:
                data = sock.recv(65536)
                if not data:
                    break
                chunks.append(data)
            sock.close()
            response = b"".join(chunks)
            self.assertIn(b"200", response.split(b"\r\n", 1)[0], response[:200])
            self.assertIn(b"service=git-upload-pack", response)
            # The INSTALLED proxy handled the request (structured log entry).
            log = root / "proxy-launchd.log"
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and not log.exists():
                time.sleep(0.2)
            self.assertTrue(log.exists())
            self.assertIn("git-upload-pack", log.read_text(errors="replace"))
        finally:
            subprocess.run(["/bin/launchctl", "bootout", f"gui/{uid}/{label}"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            plist.unlink(missing_ok=True)

    def _launchd_helpers(self) -> str:
        """Extract setup.sh's launchd verification functions verbatim so the
        test exercises the SHIPPED code, not a copy."""
        setup = (PACKAGE / "setup.sh").read_text()
        parts: list[str] = []
        cursor = 0
        for name in ("launchd_job_pid", "verify_launchd_job_alive"):
            marker = f"{name}() {{"
            start = setup.index(marker, cursor)
            end = setup.index("\n}\n", start) + len("\n}\n")
            parts.append(setup[start:end])
            cursor = end
        return "\n".join(parts)

    def test_setup_verifies_launchd_jobs_loaded_and_alive(self) -> None:
        """setup.sh's post-bootstrap verification (verify_launchd_job_alive)
        runs against the REAL launchd gui domain (same mechanism as
        _launchd_socket_activation_proof): a live KeepAlive job must be
        detected as alive with a stable pid, a crash-looping job must be
        rejected, and a loaded socket-activated agent must be idle-valid
        (socket mode) while failing the KeepAlive-style stability check.
        This is the fresh-home regression net for the "verify every launchd
        job stays loaded/alive before setup success" release blocker."""
        uid = os.getuid()
        helpers = self._launchd_helpers()
        root = Path(tempfile.mkdtemp(prefix="msw-launchd-verify-"))
        state_dir = root / "state"
        state_dir.mkdir()

        def write_plist(label: str, argv: list[str], *, socket: bool) -> Path:
            plist = root / f"{label.split('.')[-1]}.plist"
            prog = "".join(f"<string>{a}</string>" for a in argv)
            if socket:
                body = (
                    f"<key>Label</key><string>{label}</string>"
                    f"<key>ProgramArguments</key><array>{prog}</array>"
                    "<key>Sockets</key><dict><key>Listeners</key><dict>"
                    "<key>SockType</key><string>stream</string>"
                    "<key>SockFamily</key><string>IPv4</string>"
                    "<key>SockNodeName</key><string>127.0.0.1</string>"
                    "<key>SockServiceName</key><string>0</string>"
                    "</dict></dict>"
                    "<key>inetdCompatibility</key><dict><key>Wait</key><false/></dict>"
                )
            else:
                body = (
                    f"<key>Label</key><string>{label}</string>"
                    f"<key>ProgramArguments</key><array>{prog}</array>"
                    "<key>KeepAlive</key><true/><key>RunAtLoad</key><true/>"
                    "<key>ProcessType</key><string>Background</string>"
                    f"<key>StandardOutPath</key><string>{state_dir}/out.log</string>"
                    f"<key>StandardErrorPath</key><string>{state_dir}/err.log</string>"
                )
            plist.write_text(
                '<?xml version="1.0" encoding="UTF-8"?>\n'
                '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
                '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
                f'<plist version="1.0"><dict>{body}</dict></plist>\n'
            )
            return plist

        def verify(label: str, socket: bool = False) -> int:
            extra = " socket" if socket else ""
            proc = subprocess.run(
                ["/bin/bash", "-c", f"{helpers}\nverify_launchd_job_alive '{label}'{extra}"],
                capture_output=True, text=True, timeout=60,
            )
            return proc.returncode

        def bootstrap(label: str, plist: Path) -> None:
            subprocess.run(["/bin/launchctl", "bootout", f"gui/{uid}/{label}"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            boot = subprocess.run(["/bin/launchctl", "bootstrap", f"gui/{uid}", str(plist)],
                                  capture_output=True, text=True)
            self.assertEqual(boot.returncode, 0, boot.stderr)

        def teardown(label: str) -> None:
            subprocess.run(["/bin/launchctl", "bootout", f"gui/{uid}/{label}"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        pid_suffix = os.getpid()
        alive = f"org.microsandbox.MSWMonitor.port-forwarder.test-alive-{pid_suffix}"
        crashing = f"org.microsandbox.MSWMonitor.port-forwarder.test-crash-{pid_suffix}"
        socket_label = f"org.microsandbox.MSWMonitor.github-proxy.test-socket-{pid_suffix}"
        try:
            # Live KeepAlive job (what a healthy port forwarder looks like):
            # loaded AND stays alive (stable pid across the grace period).
            bootstrap(alive, write_plist(alive, ["/bin/sleep", "120"], socket=False))
            time.sleep(1.5)
            self.assertEqual(verify(alive), 0, "live KeepAlive job must pass verification")
            # A loaded job is also registered (socket-mode load check passes).
            self.assertEqual(verify(alive, socket=True), 0)

            # Crash-looping job (exits immediately, throttled respawn): never
            # shows a stable pid -> verification rejects it.
            bootstrap(crashing, write_plist(crashing, ["/usr/bin/false"], socket=False))
            time.sleep(1.5)
            self.assertNotEqual(verify(crashing), 0, "crash-looping job must fail verification")

            # Socket-activated agent (the GitHub proxy, Wait=false): idle is
            # valid — loaded and registered means launchd owns the listener —
            # but the KeepAlive-style stability check must not be used for it.
            bootstrap(socket_label, write_plist(socket_label, ["/usr/bin/true"], socket=True))
            time.sleep(1.0)
            self.assertEqual(verify(socket_label, socket=True), 0,
                             "idle socket-activated agent must be idle-valid")
            self.assertNotEqual(verify(socket_label), 0,
                                "idle socket agent has no pid; KeepAlive check must reject it")
        finally:
            for label in (alive, crashing, socket_label):
                teardown(label)
            shutil.rmtree(root, ignore_errors=True)

    def test_fresh_install_runs_proxy_stack_from_installed_paths(self) -> None:
        root = Path(tempfile.mkdtemp(prefix="msw-installed-"))
        home = root / "home"
        home.mkdir()
        try:
            env = self._install_env(root, home)
            run_cmd([PACKAGE / "setup.sh"], env=env, timeout=240)
            installed = home / ".local"
            for rel in ("bin/msw-github-proxy", "lib/proxycore.py", "lib/proxy-upstream.py",
                        "lib/vendor/h11/__init__.py", "lib/vendor/h11/LICENSE.txt",
                        "libexec/msw-port-forwarder.py", "share/msw/github-proxy.plist"):
                self.assertTrue((installed / rel).is_file(), rel)

            # Release blocker regression: on a fresh home the launch agents'
            # log directory must exist (0700) after setup — the port
            # forwarder plists point StandardOutPath/StandardErrorPath there.
            state_dir = home / ".local" / "state" / "msw"
            self.assertTrue(state_dir.is_dir())
            self.assertEqual(oct(state_dir.stat().st_mode & 0o777), "0o700")

            # Rendered launch agent: no placeholder, absolute paths, port, lint.
            plist = home / "Library/LaunchAgents/org.microsandbox.MSWMonitor.github-proxy.plist"
            text = plist.read_text()
            self.assertNotIn("__MSW_ROOT__", text)
            self.assertIn(f"{installed}/bin/msw-github-proxy", text)
            self.assertIn(str(home / "Library/Logs/MSWMonitor/github-proxy.log"), text)
            self.assertIn("<string>18446</string>", text)
            run_cmd(["/usr/bin/plutil", "-lint", str(plist)], env={"PATH": "/usr/bin:/bin"})

            # Import probe from /tmp with the checkout absent from PATH and
            # PYTHONPATH: vendored h11 and the core resolve under the
            # installed home, never the checkout. This import is also the
            # "normal proxy import" that leaves __pycache__ behind.
            probe = (
                "import importlib.util, os\n"
                "home = os.path.realpath(os.path.expanduser('~'))\n"
                "core = os.path.join(home, '.local/lib/proxycore.py')\n"
                "spec = importlib.util.spec_from_file_location('proxycore', core)\n"
                "m = importlib.util.module_from_spec(spec)\n"
                "spec.loader.exec_module(m)\n"
                "h11_path = os.path.realpath(m.h11.__file__)\n"
                "assert h11_path.startswith(home), h11_path\n"
                "assert os.path.realpath(m.__file__).startswith(home)\n"
                "assert os.path.isfile(os.path.join(home, '.local/lib/proxy-upstream.py'))\n"
                "print('PROBE_OK ' + h11_path)\n"
            )
            probe_out = run_cmd(
                ["/usr/bin/python3", "-c", probe],
                env={"HOME": str(home), "PATH": "/usr/bin:/bin", "PYTHONPATH": ""},
                cwd="/tmp",
                timeout=60,
            )
            self.assertIn("PROBE_OK", probe_out.stdout)
            self.assertIn(str(home), probe_out.stdout)
            self.assertNotIn(str(PACKAGE), probe_out.stdout)

            test_env = TestEnv(root, home, env)
            with test_env.start_fake_github() as fake:
                test_env.init_remote()
                self._seed_policy_and_keychain(root, home)
                records = self._clone_through_installed_proxy(fake, installed, root, home, fake.base_url, "first")
                self.assertTrue(any(r["path"] == "/acme/demo.git/info/refs" for r in records), records)

            # IDEMPOTENCE: the import left __pycache__; deliberately add a
            # stale bytecode file and reinstall. The second install must
            # succeed, replacing the subtree so the stale file is gone and the
            # vendored-h11 hash gate still passes. The policy + host
            # credential are removed first so setup's deep check skips the
            # live proxy-reachability probe (no launchd agent in test mode);
            # they are re-seeded for the post-install clone.
            policy_path = home / "Library/Application Support/MSW Monitor/github-policy.json"
            meta_path = home / "Library/Application Support/MSW Monitor/github-host.json"
            keychain_file = root / "keychain" / (
                re.sub(r"[^A-Za-z0-9_.-]", "_", HOST_KEYCHAIN_SERVICE)
                + "__" + re.sub(r"[^A-Za-z0-9_.-]", "_", HOST_KEYCHAIN_ACCOUNT)
            )
            policy_path.unlink(missing_ok=True)
            meta_path.unlink(missing_ok=True)
            keychain_file.unlink(missing_ok=True)
            h11_dir = installed / "lib" / "vendor" / "h11"
            pycache = h11_dir / "__pycache__"
            pycache.mkdir(parents=True, exist_ok=True)
            (pycache / "stale.pyc").write_bytes(b"stale")
            run_cmd([PACKAGE / "setup.sh"], env=env, timeout=240)
            self.assertFalse(pycache.exists())
            self.assertTrue((h11_dir / "__init__.py").is_file())

            # The installed proxy still clones after the second install.
            self._seed_policy_and_keychain(root, home)
            with test_env.start_fake_github() as fake2:
                records2 = self._clone_through_installed_proxy(fake2, installed, root, home, fake2.base_url, "second")
                self.assertTrue(any(r["path"] == "/acme/demo.git/info/refs" for r in records2), records2)

            # REAL launchd socket-activation mode (Wait=false): one request
            # through the launchd-owned socket, no --listen.
            with test_env.start_fake_github() as fake3:
                self._launchd_socket_activation_proof(installed, root, home, fake3.base_url)
        finally:
            shutil.rmtree(root, ignore_errors=True)


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

    def test_clear_quarantine_fails_on_undeletable_dangling_symlink(self) -> None:
        command = 'source "$1"; clear_quarantine "dev"'
        quarantine_dir = self.env.home / ".config/msw/github"
        quarantine_dir.mkdir(parents=True, exist_ok=True)
        quarantine = quarantine_dir / "dev.quarantine"
        quarantine.symlink_to(quarantine_dir / "missing-target")
        os.chmod(quarantine_dir, 0o500)
        try:
            proc = self.env.run(
                "bash", "-c", command, "msw-clear-quarantine-test",
                str(PACKAGE / "bin/msw"), check=False,
                extra_env={"MSW_SOURCE_ONLY": "1"},
            )
        finally:
            os.chmod(quarantine_dir, 0o700)
        self.assertNotEqual(
            proc.returncode, 0,
            "a quarantine marker that survives rm (dangling symlink in a "
            "read-only directory) must count as not cleared: enforcement "
            "treats -e OR -L as quarantined",
        )
        self.assertTrue(quarantine.is_symlink())

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
        # §9: the §5 host credential record lives only in the keychain (or the
        # MSW_TEST_KEYCHAIN_DIR seam) and must never appear in a backup.
        self.env.key_file("org.microsandbox.MSWMonitor.github-host", "user").write_text(
            json.dumps({"schemaVersion": 1, "accessToken": "gho_backup_secret_token",
                        "accountLogin": "fake-user"}))
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
        self.assertNotIn("gho_backup_secret_token", archive.read_bytes().decode("latin1", errors="ignore"))

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
        self.assertEqual(workspaces["dev"]["provider"], "legacy-broad-token")
        self.assertEqual(workspaces["dev"]["accessMode"], "unconfigured")
        self.assertIsNone(workspaces["dev"]["verificationRepository"])
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
            "schemaVersion": 3,
            "provider": "github-app-installation",
            "grantID": "00000000-0000-0000-0000-000000000001",
            "accountLogin": "alice",
            "owner": "acme",
            "repositoryIDs": [12],
            "repositoryNames": ["acme/demo"],
            "verificationRepository": "acme/demo",
            "installationID": 123,
            "accessExpiresAt": "2099-08-08T08:00:00Z",
            "needsRestart": False,
            "generation": 1,
            "quarantined": False,
            "recoveryState": "ready",
            "updatedAt": "2026-08-08T00:00:00Z",
        }
        credentials.write_text(json.dumps({
            "schemaVersion": 3,
            "entries": {
                "dev.guest": common | {
                    "role": "guest", "accessMode": "read-only",
                },
                "dev.host": common | {
                    "role": "host", "accessMode": "host-write",
                },
            },
        }))
        token_env = {
            "MSW_GITHUB_READ_TOKEN_DEV": "ghs_read_fixture",
            "MSW_GITHUB_WRITE_TOKEN_DEV": "ghs_write_fixture",
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


PROXY_BIN = PACKAGE / "bin" / "msw-github-proxy"
HOST_KEYCHAIN_SERVICE = "org.microsandbox.MSWMonitor.github-host.v2"
HOST_KEYCHAIN_ACCOUNT = "user"
DEV_CAP = "a" * 48
PLAY_CAP = "b" * 48
PERSONAL_CAP = "c" * 48
HOST_TOKEN = "gho_test_token_abcdefghijklmnopqrstuvwxyz0123456789"
PROXY_HOST = "127.0.0.1:18446"  # default proxy base (socketpair tests send this Host)


class GitHubProxyContractTests(MSWTestCase):
    """Path C proxy contract tests — proxy direct (MSW_TEST_MODE unset).

    Drives the per-connection proxy (bin/msw-github-proxy +
    lib/proxycore.py + lib/proxy-upstream.py) two ways:

    * socketpair: a fresh proxy process per request with the request bytes on
      stdin/stdout (the launchd per-connection model), for exact wire control
      (framing attacks, canonicalization, policy, timeouts).
    * --listen: the test-only accept/fork loop, for real git clients (git
      push) and http.client LFS flows.

    The stateful fake GitHub (tests/fake_github.py) is the upstream; every
    request it records proves the proxy forwarded it (and whether the host
    credential rode along), and an EMPTY request log proves a shape rejection
    never touched upstream ("upstream untouched"). Policy fixture per
    contract §2: dev=read-write acme/demo, playgrounds=read-only acme/demo,
    personal=no repos. The policy is a CREDENTIAL GRANT table: every valid
    request is forwarded and only a live workspace+repo+operation grant
    injects the host credential (Authorization present upstream); missing/
    malformed policy, unknown/missing capability, unticked repos, and
    read-only writes all go out ANONYMOUSLY and GitHub decides. Host
    credential per §5 seeded in MSW_TEST_KEYCHAIN_DIR.

    Named cases (contract §9): INGRESS-1..4, TIMEOUT-1, REGRESS-1/2, the
    SMUGGLE matrix (13 framing cases), the policy matrix, identity spoofing,
    canonicalization attacks, plus log-redaction and HMAC-key assertions.
    """

    def setUp(self) -> None:
        super().setUp()
        self.env.env.pop("MSW_TEST_MODE", None)
        self.env.env["MSW_GITHUB_MODE"] = "local"
        self.policy_dir = self.env.root / "policy"
        self.policy_dir.mkdir()
        self.policy_file = self.policy_dir / "github-policy.json"
        self.policy_file.write_text(json.dumps({
            "schemaVersion": 1,
            "workspaces": {
                "dev": {"capability": DEV_CAP, "repos": [{"canonical": "acme/demo", "mode": "read-write"}]},
                "playgrounds": {"capability": PLAY_CAP, "repos": [{"canonical": "acme/demo", "mode": "read-only"}]},
                "personal": {"capability": PERSONAL_CAP, "repos": []},
            },
        }))
        self.env.env["MSW_POLICY_FILE"] = str(self.policy_file)
        self.env.env["MSW_PROXY_LOG_FILE"] = str(self.env.root / "proxy.log")
        self.proxy_log = self.env.root / "proxy.log"
        # §5 host credential record via the narrow MSW_TEST_KEYCHAIN_DIR seam.
        name = (
            re.sub(r"[^A-Za-z0-9_.-]", "_", HOST_KEYCHAIN_SERVICE)
            + "__"
            + re.sub(r"[^A-Za-z0-9_.-]", "_", HOST_KEYCHAIN_ACCOUNT)
        )
        (self.env.root / "keychain" / name).write_text(json.dumps({
            "schemaVersion": 1,
            "provider": "gh-cli",
            "tokenKind": "oauth",
            "accessToken": HOST_TOKEN,
            "accountLogin": "fake-user",
            "verifiedAt": "2026-01-01T00:00:00Z",
            "generation": 1,
            "storedAt": "2026-01-01T00:00:00Z",
        }))
        # §5 nonsecret activation metadata beside the policy file, matching the
        # keychain record (generation/accountLogin) so the token helper accepts
        # the credential; the proxy forwards the seam to the helper.
        meta_file = self.env.home / "Library/Application Support/MSW Monitor" / "github-host.json"
        meta_file.parent.mkdir(parents=True, exist_ok=True)
        meta_file.write_text(json.dumps({
            "schemaVersion": 1,
            "provider": "gh-cli",
            "tokenKind": "oauth",
            "accountLogin": "fake-user",
            "verifiedAt": "2026-01-01T00:00:00Z",
            "generation": 1,
            "state": "active",
            "storedAt": "2026-01-01T00:00:00Z",
            "repoChecks": [],
        }))
        os.chmod(meta_file, 0o600)  # §5: metadata file is 0600
        self.env.env["MSW_HOST_META_FILE"] = str(meta_file)
        self._fake_ctx = None
        self.fake_github: _FakeGitHubHandle | None = None

    def _start_fake_github(self) -> _FakeGitHubHandle:
        self._fake_ctx = self.env.start_fake_github()
        self.fake_github = self._fake_ctx.__enter__()
        self.env.env["MSW_PROXY_UPSTREAM_ROOT"] = self.fake_github.base_url
        return self.fake_github

    def tearDown(self) -> None:
        if self._fake_ctx is not None:
            self._fake_ctx.__exit__(None, None, None)
            self._fake_ctx = None
            self.fake_github = None
        super().tearDown()

    # ---- harness helpers -------------------------------------------------

    def _proxy_env(self, **overrides: str) -> dict[str, str]:
        env = self.env.env.copy()
        env.update({
            "MSW_GITHUB_MODE": "local",
            "MSW_POLICY_FILE": str(self.policy_file),
            "MSW_PROXY_LOG_FILE": str(self.proxy_log),
            "MSW_HOST_KEYCHAIN_SERVICE": HOST_KEYCHAIN_SERVICE,
            "MSW_HOST_KEYCHAIN_ACCOUNT": HOST_KEYCHAIN_ACCOUNT,
            "MSW_TEST_KEYCHAIN_DIR": str(self.env.root / "keychain"),
        })
        if self.fake_github is not None:
            env["MSW_PROXY_UPSTREAM_ROOT"] = self.fake_github.base_url
        env.update(overrides)
        return env

    @staticmethod
    def _req_bytes(method: str, target: str, *, headers: Iterable[tuple[str, str]] = (),
                   body: bytes = b"", host: str = PROXY_HOST, version: str = "1.1",
                   capability: str | None = DEV_CAP) -> bytes:
        lines = [f"{method} {target} HTTP/{version}", f"Host: {host}"]
        if capability is not None:
            lines.append(f"X-MSW-Capability: {capability}")
        lines.extend(f"{name}: {value}" for name, value in headers)
        return ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1") + body

    @staticmethod
    def _status_of(raw_resp: bytes) -> int:
        head = raw_resp.split(b"\r\n\r\n", 1)[0]
        parts = head.split(b" ", 2)
        if len(parts) >= 2:
            try:
                return int(parts[1])
            except ValueError:
                return 0
        return 0

    def _proxy_request(self, raw: bytes, *, env_overrides: dict[str, str] | None = None,
                       timeout: int = 30) -> tuple[int, bytes]:
        """One request through a fresh per-connection proxy (socketpair)."""
        env = self._proxy_env()
        if env_overrides:
            env.update(env_overrides)
        sock, child = socket.socketpair()
        sock.settimeout(timeout)
        err = (self.env.root / "proxy-child.err").open("ab")
        proc = subprocess.Popen([PROXY_BIN], stdin=child, stdout=child, stderr=err,
                                env=env, cwd=str(PACKAGE))
        child.close()
        chunks: list[bytes] = []
        try:
            try:
                sock.sendall(raw)
            except OSError:
                pass  # proxy may reject mid-send (cap kills) and close
            while True:
                try:
                    data = sock.recv(65536)
                except socket.timeout:
                    break
                if not data:
                    break
                chunks.append(data)
            raw_resp = b"".join(chunks)
        finally:
            sock.close()
            try:
                proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
            err.close()
        return self._status_of(raw_resp), raw_resp

    @contextlib.contextmanager
    def _proxy_listener(self, *, env_overrides: dict[str, str] | None = None) -> Iterator[int]:
        """Test-only proxy accept/fork loop; yields the bound port."""
        env = self._proxy_env()
        if env_overrides:
            env.update(env_overrides)
        err_path = self.env.root / "proxy-listen.err"
        err_fh = err_path.open("ab")
        proc = subprocess.Popen([PROXY_BIN, "--listen", "0"], env=env, cwd=str(PACKAGE),
                                stdout=subprocess.PIPE, stderr=err_fh, text=True)
        assert proc.stdout is not None
        port = 0
        try:
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                if proc.poll() is not None:
                    raise AssertionError(
                        f"proxy listener exited early (rc={proc.returncode}):\n{err_path.read_text(errors='replace')}"
                    )
                ready, _, _ = select.select([proc.stdout], [], [], 0.5)
                if not ready:
                    continue
                line = proc.stdout.readline()
                match = re.match(r"PROXY_READY port=(\d+)", line)
                if match:
                    port = int(match.group(1))
                    break
            if not port:
                raise AssertionError("proxy listener did not become ready")
            yield port
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
            if proc.stdout is not None:
                proc.stdout.close()
            err_fh.close()

    def _http_req(self, port: int, method: str, path: str, body: bytes | str | None = None,
                  headers: dict[str, str] | None = None, capability: str = DEV_CAP,
                  timeout: int = 60) -> tuple[int, dict[str, str], bytes]:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
        h = {"Host": f"127.0.0.1:{port}", "X-MSW-Capability": capability}
        if headers:
            h.update(headers)
        try:
            conn.request(method, path, body=body, headers=h)
            resp = conn.getresponse()
            data = resp.read()
            return resp.status, dict(resp.getheaders()), data
        finally:
            conn.close()

    def _rewrite_policy(self, payload: object) -> None:
        self.policy_file.write_text(json.dumps(payload))

    @contextlib.contextmanager
    def _crafted_batch_upstream(self, response_provider, record: Path) -> Iterator[str]:
        """Mini upstream serving a caller-crafted LFS batch + object endpoints.

        Records every request (method, path, Authorization VALUE) to `record`
        so tests can assert both that a batch refusal never spawned an object
        request AND that stored action credentials were re-attached on the
        outbound objects leg only.
        """

        class Handler(http.server.BaseHTTPRequestHandler):
            def _record(self, method: str) -> None:
                with record.open("a") as fh:
                    fh.write(json.dumps({
                        "method": method,
                        "path": self.path,
                        "authorization": self.headers.get("Authorization"),
                        "cookie": self.headers.get("Cookie"),
                    }) + "\n")

            def _send(self, status: int, body: bytes, ctype: str) -> None:
                self.send_response(status)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self) -> None:
                self._record("POST")
                if self.path.endswith("/info/lfs/objects/batch"):
                    batch = response_provider()
                    self._send(200, json.dumps(batch).encode(), "application/vnd.git-lfs+json")
                else:
                    self._send(404, b"", "application/json")

            def do_PUT(self) -> None:
                self._record("PUT")
                length = int(self.headers.get("Content-Length", "0") or 0)
                if length:
                    self.rfile.read(length)
                self._send(200, b"", "application/octet-stream")

            def do_GET(self) -> None:
                self._record("GET")
                self._send(404, b"", "application/json")

            def log_message(self, fmt: str, *args: object) -> None:
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_address[1]}"
        finally:
            server.shutdown()
            server.server_close()

    def _fake_records(self) -> list[dict]:
        assert self.fake_github is not None
        return self.fake_github.requests()

    # ---- INGRESS-1: >1MiB real git push, chunked -------------------------

    def test_ingress1_real_git_push_chunked(self) -> None:
        fake = self._start_fake_github()
        self.env.init_remote()
        with self._proxy_listener() as port:
            git_home = self.env.root / "git-home"
            git_home.mkdir(exist_ok=True)
            env = self.env.env.copy()
            env.update({"HOME": str(git_home), "GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1"})
            work = self.env.root / "push-work"
            run_cmd([SYSTEM_GIT, "clone", "-q", str(self.env.root / "remotes" / "acme" / "demo.git"), str(work)], env=env)
            run_cmd([SYSTEM_GIT, "-C", str(work), "config", "user.name", "T"], env=env)
            run_cmd([SYSTEM_GIT, "-C", str(work), "config", "user.email", "t@example.invalid"], env=env)
            # 2 MiB pack > git http.postBuffer (1 MiB default) -> chunked
            (work / "big.bin").write_bytes(os.urandom(2 * 1024 * 1024))
            run_cmd([SYSTEM_GIT, "-C", str(work), "add", "big.bin"], env=env)
            run_cmd([SYSTEM_GIT, "-C", str(work), "commit", "-qm", "big file"], env=env)
            url = f"http://127.0.0.1:{port}/github.com/acme/demo.git"
            push = run_cmd(
                [SYSTEM_GIT, "-C", str(work), "-c", f"http.extraHeader=X-MSW-Capability: {DEV_CAP}",
                 "push", url, "main"],
                env=env, timeout=120,
            )
            self.assertEqual(push.returncode, 0, push.stdout + push.stderr)
        records = fake.requests()
        rpc = [r for r in records if r["path"] == "/acme/demo.git/git-receive-pack" and r["method"] == "POST"]
        self.assertTrue(any(r["transfer_encoding"] == "chunked" for r in rpc), records)
        self.assertTrue(any(r["request_bytes"] > 1024 * 1024 for r in rpc), records)
        self.assertTrue(all(r["authorization_present"] for r in rpc), records)
        self.assertTrue(all(r["response_status"] == 200 for r in rpc), records)

    # ---- INGRESS-2: ~8MiB LFS round trip through the stamped proxy URLs ---

    def test_ingress2_lfs_round_trip_stamped(self) -> None:
        fake = self._start_fake_github()
        self.env.init_remote()
        with self._proxy_listener() as port:
            payload = bytes(range(256)) * (8 * 1024 * 1024 // 256)  # exactly 8 MiB
            oid = hashlib.sha256(payload).hexdigest()

            # upload batch -> stamped upload href
            status, _, body = self._http_req(
                port, "POST", "/github.com/acme/demo.git/info/lfs/objects/batch",
                body=json.dumps({"operation": "upload", "transfers": ["basic"],
                                 "objects": [{"oid": oid, "size": len(payload)}]}),
                headers={"Content-Type": "application/vnd.git-lfs+json"})
            self.assertEqual(status, 200, body)
            data = json.loads(body)
            upload_href = data["objects"][0]["actions"]["upload"]["href"]
            u = urllib.parse.urlsplit(upload_href)
            self.assertEqual(u.path, f"/objects.githubusercontent.com/objects/{oid}")
            q = urllib.parse.parse_qs(u.query)
            for key in ("_msw_repo", "_msw_op", "_msw_exp", "_msw_sig"):
                self.assertIn(key, q)
            self.assertEqual(q["_msw_repo"], ["acme/demo"])
            self.assertEqual(q["_msw_op"], ["upload"])

            # PUT the object through the stamped URL
            status, _, body = self._http_req(port, "PUT", u.path + "?" + u.query,
                                             body=payload,
                                             headers={"Content-Type": "application/octet-stream"})
            self.assertEqual(status, 200, body)

            # download batch -> stamped download href -> GET the object back
            status, _, body = self._http_req(
                port, "POST", "/github.com/acme/demo.git/info/lfs/objects/batch",
                body=json.dumps({"operation": "download", "transfers": ["basic"],
                                 "objects": [{"oid": oid, "size": len(payload)}]}),
                headers={"Content-Type": "application/vnd.git-lfs+json"})
            self.assertEqual(status, 200, body)
            download_href = json.loads(body)["objects"][0]["actions"]["download"]["href"]
            u2 = urllib.parse.urlsplit(download_href)
            q2 = urllib.parse.parse_qs(u2.query)
            self.assertEqual(q2["_msw_op"], ["download"])
            self.assertEqual(q2["_msw_repo"], ["acme/demo"])
            status, _, body = self._http_req(port, "GET", u2.path + "?" + u2.query)
            self.assertEqual(status, 200)
            self.assertEqual(body, payload)

            # unstamped objects URL denied
            status, _, _ = self._http_req(port, "GET", f"/objects.githubusercontent.com/objects/{oid}")
            self.assertEqual(status, 403)
            # tampered stamp (malformed blob) denied
            bad_q = dict(q2)
            bad_q["_msw_sig"] = ["0" * 64]
            status, _, _ = self._http_req(
                port, "GET", u2.path + "?" + urllib.parse.urlencode(
                    {k: v[0] for k, v in bad_q.items()}))
            self.assertEqual(status, 403)
            # stamp forged with the WRONG key denied (AEAD authentication)
            key_file = self.policy_dir / "github-proxy-hmac.key"
            real_key = bytes.fromhex(key_file.read_text().strip())
            saved_path = list(sys.path)
            sys.path.insert(0, str(PACKAGE / "lib"))
            try:
                import proxycore as proxycore_mod
            finally:
                sys.path[:] = saved_path
            forged_payload = json.dumps({
                "v": 1, "href": f"{fake.base_url}/objects/{oid}", "headers": {},
                "op": "download", "repo": "acme/demo", "exp": q2["_msw_exp"][0],
            }, sort_keys=True).encode()
            forged = proxycore_mod.stamp_encode(b"w" * 32, forged_payload)
            bad_q2 = dict(q2)
            bad_q2["_msw_sig"] = [urllib.parse.quote(forged, safe="")]
            status, _, _ = self._http_req(
                port, "GET", u2.path + "?" + urllib.parse.urlencode(
                    {k: v[0] for k, v in bad_q2.items()}))
            self.assertEqual(status, 403)
            # expired stamp (self-carrying, encoded with the real key) denied
            expired = "2000-01-01T00:00:00Z"
            expired_payload = json.dumps({
                "v": 1, "href": f"{fake.base_url}/objects/{oid}", "headers": {},
                "op": "download", "repo": "acme/demo", "exp": expired,
            }, sort_keys=True).encode()
            expired_blob = proxycore_mod.stamp_encode(real_key, expired_payload)
            expired_q = urllib.parse.urlencode({
                "_msw_repo": "acme/demo", "_msw_op": "download", "_msw_exp": expired,
                "_msw_sig": urllib.parse.quote(expired_blob, safe=""),
            })
            status, _, _ = self._http_req(
                port, "GET", f"/objects.githubusercontent.com/objects/{oid}?{expired_q}")
            self.assertEqual(status, 403)

        records = fake.requests()
        batch = [r for r in records if "lfs/objects/batch" in r["path"]]
        objects = [r for r in records if r["path"].startswith("/objects/")]
        self.assertEqual(len(batch), 2, records)
        self.assertEqual(len(objects), 2, records)  # PUT + GET
        self.assertTrue(all(r["authorization_present"] for r in batch), records)
        self.assertFalse(any(r["authorization_present"] for r in objects), records)
        # HMAC key persisted 0600 beside the policy file
        key_file = self.policy_dir / "github-proxy-hmac.key"
        self.assertTrue(key_file.is_file())
        self.assertEqual(stat.S_IMODE(key_file.stat().st_mode), 0o600)
        self.assertRegex(key_file.read_text().strip(), r"^[0-9a-f]{64}$")

    def test_lfs_read_only_download_allowed_upload_forwarded_anonymously(self) -> None:
        """Read-only workspaces get AUTHENTICATED LFS downloads; their uploads
        are no longer denied locally -- they are forwarded anonymously (no
        host credential, no credentials sealed into the stamp) and GitHub
        decides. An AUTHENTICATED stamp still requires a live grant on the
        objects leg: the read-only workspace's forged credential-carrying
        PUT is denied, while the same stamp works under dev (read-write).
        """
        fake = self._start_fake_github()
        self.env.init_remote()
        payload = bytes(range(251)) * 4096  # ~1 MiB
        oid = hashlib.sha256(payload).hexdigest()
        with self._proxy_listener() as port:
            # Seed the object via the READ-WRITE workspace (dev): upload batch
            # authenticated -> stamped PUT allowed.
            status, _, body = self._http_req(
                port, "POST", "/github.com/acme/demo.git/info/lfs/objects/batch",
                body=json.dumps({"operation": "upload", "transfers": ["basic"],
                                 "objects": [{"oid": oid, "size": len(payload)}]}),
                headers={"Content-Type": "application/vnd.git-lfs+json"})
            self.assertEqual(status, 200, body)
            upload_href = json.loads(body)["objects"][0]["actions"]["upload"]["href"]
            u = urllib.parse.urlsplit(upload_href)
            q_up = urllib.parse.parse_qs(u.query)
            self.assertEqual(q_up["_msw_op"], ["upload"])
            self.assertEqual(q_up["_msw_repo"], ["acme/demo"])
            status, _, body = self._http_req(
                port, "PUT", u.path + "?" + u.query, body=payload,
                headers={"Content-Type": "application/octet-stream"})
            self.assertEqual(status, 200, body)

            # READ-ONLY workspace (playgrounds): download batch authenticated
            # (read grant) -> stamped GET returns the object bytes.
            status, _, body = self._http_req(
                port, "POST", "/github.com/acme/demo.git/info/lfs/objects/batch",
                body=json.dumps({"operation": "download", "transfers": ["basic"],
                                 "objects": [{"oid": oid, "size": len(payload)}]}),
                headers={"Content-Type": "application/vnd.git-lfs+json"},
                capability=PLAY_CAP)
            self.assertEqual(status, 200, body)
            download_href = json.loads(body)["objects"][0]["actions"]["download"]["href"]
            d = urllib.parse.urlsplit(download_href)
            q_down = urllib.parse.parse_qs(d.query)
            self.assertEqual(q_down["_msw_op"], ["download"])
            self.assertEqual(q_down["_msw_repo"], ["acme/demo"])
            status, _, body = self._http_req(
                port, "GET", d.path + "?" + d.query, capability=PLAY_CAP)
            self.assertEqual(status, 200, body[:200])
            self.assertEqual(body, payload)

            # READ-ONLY workspace: upload batch forwarded ANONYMOUSLY (no
            # local denial) and stamped WITHOUT credentials; GitHub decides.
            status, _, body = self._http_req(
                port, "POST", "/github.com/acme/demo.git/info/lfs/objects/batch",
                body=json.dumps({"operation": "upload", "transfers": ["basic"],
                                 "objects": [{"oid": oid, "size": len(payload)}]}),
                headers={"Content-Type": "application/vnd.git-lfs+json"},
                capability=PLAY_CAP)
            self.assertEqual(status, 200, body[:200])
            self.assertNotIn(b"Authorization", body)
            self.assertNotIn(b"header", body)

            # An AUTHENTICATED upload stamp (credentials sealed inside) must
            # be covered by a live write grant: forged with the real key, it
            # is denied for the read-only workspace (no write grant) ...
            key_file = self.policy_dir / "github-proxy-hmac.key"
            real_key = bytes.fromhex(key_file.read_text().strip())
            saved_path = list(sys.path)
            sys.path.insert(0, str(PACKAGE / "lib"))
            try:
                import proxycore as proxycore_mod
            finally:
                sys.path[:] = saved_path
            stamp_exp = q_up["_msw_exp"][0]
            forged_upload = json.dumps({
                "v": 1, "href": f"{fake.base_url}/objects/{oid}",
                "headers": {"Authorization": "Bearer forged-cred"},
                "op": "upload", "repo": "acme/demo", "exp": stamp_exp, "auth": True,
            }, sort_keys=True).encode()
            upload_blob = proxycore_mod.stamp_encode(real_key, forged_upload)
            put_q = urllib.parse.urlencode({
                "_msw_repo": "acme/demo", "_msw_op": "upload",
                "_msw_exp": stamp_exp, "_msw_sig": urllib.parse.quote(upload_blob, safe=""),
            })
            status, _, body = self._http_req(
                port, "PUT", f"/objects.githubusercontent.com/objects/{oid}?{put_q}",
                body=payload, headers={"Content-Type": "application/octet-stream"},
                capability=PLAY_CAP)
            self.assertEqual(status, 403, body[:200])
            self.assertIn(b"revoked", body)

            # ... but the SAME stamp is still valid for the READ-WRITE
            # workspace (dev), which forwards it with the stored credential.
            status, _, body = self._http_req(
                port, "PUT", f"/objects.githubusercontent.com/objects/{oid}?{put_q}",
                body=payload, headers={"Content-Type": "application/octet-stream"},
                capability=DEV_CAP)
            self.assertEqual(status, 200, body[:200])

        # Upstream provenance: only the forwarded legs ever leave the host.
        records = fake.requests()
        batches = [r for r in records if "lfs/objects/batch" in r["path"]]
        objects = [r for r in records if r["path"].startswith("/objects/")]
        self.assertEqual([r["method"] for r in batches], ["POST", "POST", "POST"], records)
        self.assertEqual([r["method"] for r in objects], ["PUT", "GET", "PUT"], records)
        # dev seed upload + read-only download batches used the host
        # credential; the read-only workspace's upload batch was anonymous.
        self.assertEqual([r["authorization_present"] for r in batches],
                         [True, True, False], records)
    def test_lfs_anonymous_public_download_no_host_auth(self) -> None:
        """Public LFS download needs no grant and no setup.

        Unticked, unknown-capability, and missing-policy workspaces get the
        batch AND the object bytes anonymously: the upstream never sees an
        Authorization header anywhere, and the VM never sees a credential-
        bearing header or an upstream href (stamped proxy URLs only).
        """
        fake = self._start_fake_github()
        self.env.init_remote()
        payload = bytes(range(251)) * 4096  # ~1 MiB
        oid = hashlib.sha256(payload).hexdigest()
        with self._proxy_listener() as port:
            # seed the object via dev (read-write) so it exists upstream
            status, _, body = self._http_req(
                port, "POST", "/github.com/acme/demo.git/info/lfs/objects/batch",
                body=json.dumps({"operation": "upload", "transfers": ["basic"],
                                 "objects": [{"oid": oid, "size": len(payload)}]}),
                headers={"Content-Type": "application/vnd.git-lfs+json"})
            self.assertEqual(status, 200, body[:200])
            upload_href = json.loads(body)["objects"][0]["actions"]["upload"]["href"]
            u = urllib.parse.urlsplit(upload_href)
            status, _, body = self._http_req(
                port, "PUT", u.path + "?" + u.query, body=payload,
                headers={"Content-Type": "application/octet-stream"})
            self.assertEqual(status, 200, body[:200])

            # unticked workspace and unknown capability: anonymous download
            for capability, tag in ((PERSONAL_CAP, "unticked"), ("d" * 48, "unknown")):
                status, _, body = self._http_req(
                    port, "POST", "/github.com/acme/demo.git/info/lfs/objects/batch",
                    body=json.dumps({"operation": "download", "transfers": ["basic"],
                                     "objects": [{"oid": oid, "size": len(payload)}]}),
                    headers={"Content-Type": "application/vnd.git-lfs+json"},
                    capability=capability)
                self.assertEqual(status, 200, f"{tag}: {body[:200]}")
                self.assertNotIn(b"Authorization", body)
                self.assertNotIn(b"header", body)
                download_href = json.loads(body)["objects"][0]["actions"]["download"]["href"]
                d = urllib.parse.urlsplit(download_href)
                self.assertEqual(d.path, f"/objects.githubusercontent.com/objects/{oid}")
                status, _, body = self._http_req(
                    port, "GET", d.path + "?" + d.query, capability=capability)
                self.assertEqual(status, 200, f"{tag}: {body[:200]}")
                self.assertEqual(body, payload)

        # missing policy: anonymous LFS still works end to end
        missing = str(self.env.root / "missing-policy.json")
        batch_body = json.dumps({"operation": "download", "transfers": ["basic"],
                                 "objects": [{"oid": oid, "size": len(payload)}]}).encode()
        status, resp = self._proxy_request(
            self._req_bytes("POST", "/github.com/acme/demo.git/info/lfs/objects/batch",
                            headers=[("Content-Type", "application/vnd.git-lfs+json"),
                                     ("Content-Length", str(len(batch_body)))],
                            body=batch_body),
            env_overrides={"MSW_POLICY_FILE": missing})
        self.assertEqual(status, 200, resp[:200])
        download_href = json.loads(resp.split(b"\r\n\r\n", 1)[1])[
            "objects"][0]["actions"]["download"]["href"]
        d = urllib.parse.urlsplit(download_href)
        status, resp = self._proxy_request(
            self._req_bytes("GET", d.path + "?" + d.query),
            env_overrides={"MSW_POLICY_FILE": missing})
        self.assertEqual(status, 200, resp[:200])
        self.assertEqual(resp.split(b"\r\n\r\n", 1)[1], payload)

        records = fake.requests()
        batches = [r for r in records if "lfs/objects/batch" in r["path"]]
        objects = [r for r in records if r["path"].startswith("/objects/")]
        self.assertEqual(len(batches), 4, records)
        self.assertEqual(len(objects), 4, records)
        # only the dev seed batch used the host credential
        self.assertEqual([r["authorization_present"] for r in batches],
                         [True, False, False, False], records)
        # no object leg ever carried an Authorization header
        self.assertEqual([r["authorization_present"] for r in objects],
                         [False, False, False, False], records)

    def test_lfs_stamp_cannot_bypass_later_grant_revocation(self) -> None:
        """Authenticated LFS stamps cannot outlive their grant.

        A credential-carrying stamp minted under dev's read-write grant stops
        working the moment the grant is revoked: the objects leg re-checks
        the CURRENT policy (re-read per request), so even a signature-valid,
        unexpired stamp is denied and never reaches the upstream.
        """
        fake = self._start_fake_github()
        self.env.init_remote()
        oid = hashlib.sha256(b"revoke-me").hexdigest()
        credential = "Bearer lfs-revoke-cred"
        record = self.env.root / "mini-revoke.jsonl"
        crafted = {}
        with self._crafted_batch_upstream(lambda: crafted, record) as mini:
            with self._proxy_listener(env_overrides={"MSW_PROXY_UPSTREAM_ROOT": mini}) as port:
                crafted = {"transfer": "basic", "objects": [{
                    "oid": oid, "size": 9, "authenticated": True,
                    "actions": {"upload": {"href": f"{mini}/objects/{oid}",
                                           "header": {"Authorization": credential}}}}]}
                # mint an authenticated upload stamp under dev's grant
                status, _, body = self._http_req(
                    port, "POST", "/github.com/acme/demo.git/info/lfs/objects/batch",
                    body=json.dumps({"operation": "upload", "transfers": ["basic"],
                                     "objects": [{"oid": oid, "size": 9}]}),
                    headers={"Content-Type": "application/vnd.git-lfs+json"})
                self.assertEqual(status, 200, body[:200])
                upload_href = json.loads(body)["objects"][0]["actions"]["upload"]["href"]
                u = urllib.parse.urlsplit(upload_href)
                # the stamp works while the grant exists (the stored
                # credential is re-attached host-side on the outbound leg)
                status, _, body = self._http_req(
                    port, "PUT", u.path + "?" + u.query, body=b"objdata",
                    headers={"Content-Type": "text/plain"})
                self.assertEqual(status, 200, body[:200])
                # revoke dev's grant for acme/demo
                self._rewrite_policy({
                    "schemaVersion": 1,
                    "workspaces": {
                        "dev": {"capability": DEV_CAP, "repos": []},
                        "playgrounds": {"capability": PLAY_CAP,
                                        "repos": [{"canonical": "acme/demo", "mode": "read-only"}]},
                        "personal": {"capability": PERSONAL_CAP, "repos": []},
                    },
                })
                # the SAME stamp is now denied (signature + TTL still valid)
                status, _, body = self._http_req(
                    port, "PUT", u.path + "?" + u.query, body=b"objdata",
                    headers={"Content-Type": "text/plain"})
                self.assertEqual(status, 403, body[:200])
                self.assertIn(b"revoked", body)
        entries = [json.loads(line) for line in record.read_text().splitlines() if line.strip()]
        puts = [e for e in entries if e["method"] == "PUT"]
        self.assertEqual(len(puts), 1, entries)   # the revoked PUT never left the host
        self.assertEqual(puts[0]["authorization"], credential)

    def test_lfs_anonymous_batch_keeps_github_issued_action_headers(self) -> None:
        """Real public LFS: GitHub returns object-scoped temporary action
        headers (e.g. RemoteAuth) even for ANONYMOUS batches.

        The proxy must not drop them or public object fetches break: the
        batch goes upstream without the host token, GitHub's temporary
        headers are sealed into the stamp (auth:false -- no grant recheck,
        they are not host secrets), stripped from the VM-visible response,
        and re-attached host-side on the objects leg so the fetch succeeds.
        """
        fake = self._start_fake_github()
        self.env.init_remote()
        oid = hashlib.sha256(b"anon-header").hexdigest()
        credential = "RemoteAuth anon-scoped-temp-cred"
        record = self.env.root / "mini-anon-headers.jsonl"
        crafted = {}
        with self._crafted_batch_upstream(lambda: crafted, record) as mini:
            crafted = {"transfer": "basic", "objects": [{
                "oid": oid, "size": 7, "authenticated": True,
                "actions": {"download": {"href": f"{mini}/objects/{oid}",
                                         "header": {"Authorization": credential}}}}]}
            with self._proxy_listener(env_overrides={"MSW_PROXY_UPSTREAM_ROOT": mini}) as port:
                # UNTICKED workspace (no grant): anonymous batch forward
                status, _, body = self._http_req(
                    port, "POST", "/github.com/acme/demo.git/info/lfs/objects/batch",
                    body=json.dumps({"operation": "download", "transfers": ["basic"],
                                     "objects": [{"oid": oid, "size": 7}]}),
                    headers={"Content-Type": "application/vnd.git-lfs+json"},
                    capability=PERSONAL_CAP)
                self.assertEqual(status, 200, body[:200])
                self.assertNotIn(b"Authorization", body)   # never VM-visible
                self.assertNotIn(b"header", body)
                href = json.loads(body)["objects"][0]["actions"]["download"]["href"]
                u = urllib.parse.urlsplit(href)
                # object fetch with the UNGRANTED capability: the stamp is
                # auth:false (no grant recheck) and GitHub's temporary header
                # is re-attached host-side only (the mini answers 404 for
                # GET, which propagates -- the point is the recorded header).
                status, _, body = self._http_req(
                    port, "GET", u.path + "?" + u.query, capability=PERSONAL_CAP)
                self.assertEqual(status, 404, body[:200])
        entries = [json.loads(line) for line in record.read_text().splitlines() if line.strip()]
        batches = [e for e in entries if e["method"] == "POST"]
        gets = [e for e in entries if e["method"] == "GET"]
        self.assertEqual(len(batches), 1, entries)
        self.assertIsNone(batches[0]["authorization"], entries)  # no host token
        self.assertEqual(len(gets), 1, entries)
        self.assertEqual(gets[0]["authorization"], credential)  # temp cred re-attached

    # ---- LFS batch fail-closed (never pass through upstream hrefs/headers) --

    def test_lfs_batch_foreign_href_fails_closed(self) -> None:
        """A batch action href on an unknown host refuses the WHOLE batch.

        The VM receives an LFS error and no object request ever follows (the
        upstream records the batch only).
        """
        fake = self._start_fake_github()
        self.env.init_remote()
        oid = hashlib.sha256(b"foreign").hexdigest()
        record = self.env.root / "mini-foreign.jsonl"
        crafted = {}
        batch_body = json.dumps({"operation": "upload", "transfers": ["basic"],
                                 "objects": [{"oid": oid, "size": 3}]}).encode()
        with self._crafted_batch_upstream(lambda: crafted, record) as mini:
            crafted = {"transfer": "basic", "objects": [{
                "oid": oid, "size": 3, "authenticated": True,
                "actions": {"upload": {"href": f"https://evil.example/objects/{oid}",
                                       "header": {"Authorization": "Bearer foreign-cred"}}}}]}
            status, resp = self._proxy_request(
                self._req_bytes("POST", "/github.com/acme/demo.git/info/lfs/objects/batch",
                                headers=[("Content-Type", "application/vnd.git-lfs+json"),
                                         ("Content-Length", str(len(batch_body)))],
                                body=batch_body),
                env_overrides={"MSW_PROXY_UPSTREAM_ROOT": mini})
        self.assertEqual(status, 403, resp[:200])          # LFS 4xx, never a pass-through
        self.assertIn(b'"message"', resp)
        entries = [json.loads(line) for line in record.read_text().splitlines() if line.strip()]
        self.assertEqual([e["method"] for e in entries], ["POST"], entries)
        self.assertTrue(all(e["path"].endswith("/info/lfs/objects/batch") for e in entries), entries)
        self.assertEqual(fake.requests(), [], "the fake GitHub must not see the batch")

    def test_lfs_batch_credential_header_never_reaches_vm(self) -> None:
        """Action credential headers are re-attached host-side ONLY.

        The credential never appears in any VM-visible bytes (raw batch
        response or stamped URL), while the outbound object request DOES carry
        it (recorded by the mini upstream).
        """
        fake = self._start_fake_github()
        self.env.init_remote()
        oid = hashlib.sha256(b"cred").hexdigest()
        credential = "Bearer super-secret-lfs-cred"
        record = self.env.root / "mini-cred.jsonl"
        crafted = {}
        with self._crafted_batch_upstream(lambda: crafted, record) as mini:
            crafted = {"transfer": "basic", "objects": [{
                "oid": oid, "size": 7, "authenticated": True,
                "actions": {"upload": {"href": f"{mini}/objects/{oid}",
                                       "header": {"Authorization": credential,
                                                  "Content-Type": "application/octet-stream"}}}}]}
            with self._proxy_listener(env_overrides={"MSW_PROXY_UPSTREAM_ROOT": mini}) as port:
                status, _, raw_body = self._http_req(
                    port, "POST", "/github.com/acme/demo.git/info/lfs/objects/batch",
                    body=json.dumps({"operation": "upload", "transfers": ["basic"],
                                     "objects": [{"oid": oid, "size": 7}]}),
                    headers={"Content-Type": "application/vnd.git-lfs+json"})
                self.assertEqual(status, 200, raw_body[:200])
                self.assertNotIn(credential.encode(), raw_body)   # never in VM bytes
                self.assertNotIn(b"Authorization", raw_body)      # header map stripped
                data = json.loads(raw_body)
                upload_href = data["objects"][0]["actions"]["upload"]["href"]
                self.assertNotIn("super-secret", upload_href)
                u = urllib.parse.urlsplit(upload_href)
                # The VM PUTs with NO credentials; the proxy re-attaches the
                # stored ones from the stamp on the outbound leg only.
                status, _, body = self._http_req(
                    port, "PUT", u.path + "?" + u.query, body=b"objdata",
                    headers={"Content-Type": "text/plain"})
                self.assertEqual(status, 200, body[:200])
        entries = [json.loads(line) for line in record.read_text().splitlines() if line.strip()]
        puts = [e for e in entries if e["method"] == "PUT"]
        self.assertEqual(len(puts), 1, entries)
        self.assertEqual(puts[0]["path"], f"/objects/{oid}")
        self.assertEqual(puts[0]["authorization"], credential)

    # ---- guest credentials can never authenticate an anonymous request ----

    def test_guest_credentials_cannot_authenticate_anonymous_requests(self) -> None:
        """Guest Cookie/Authorization never ride an anonymous request.

        An ungranted workspace is forwarded ANONYMOUSLY: the guest's own
        Cookie/Authorization headers are stripped on the outbound leg (the
        host token may be re-added ONLY under a live grant), so neither a
        guest Cookie nor a guest Authorization can authenticate a batch or a
        regular Git request outside the grant decision. The mini upstream
        records exactly what arrived; neither header may be present, and the
        VM-visible batch body never echoes the guest secrets.
        """
        oid = hashlib.sha256(b"anon-cred").hexdigest()
        record = self.env.root / "mini-guest-cred.jsonl"
        crafted = {}
        with self._crafted_batch_upstream(lambda: crafted, record) as mini:
            crafted = {"transfer": "basic", "objects": [{
                "oid": oid, "size": 7, "authenticated": True,
                "actions": {"download": {"href": f"{mini}/objects/{oid}"}}}]}
            with self._proxy_listener(env_overrides={"MSW_PROXY_UPSTREAM_ROOT": mini}) as port:
                guest_cookie = "session=guest-secret-cookie"
                guest_auth = "Bearer guest-token-xyz"
                # (a) LFS batch, ungranted capability (personal has no repos),
                #     guest Cookie + Authorization attached by the client.
                status, _, raw_body = self._http_req(
                    port, "POST", "/github.com/acme/demo.git/info/lfs/objects/batch",
                    body=json.dumps({"operation": "download", "transfers": ["basic"],
                                     "objects": [{"oid": oid, "size": 7}]}),
                    headers={"Content-Type": "application/vnd.git-lfs+json",
                             "Cookie": guest_cookie,
                             "Authorization": guest_auth},
                    capability=PERSONAL_CAP)
                self.assertEqual(status, 200, raw_body[:200])
                self.assertNotIn(guest_cookie.encode(), raw_body)
                self.assertNotIn(guest_auth.encode(), raw_body)
                # (b) regular Git request (info/refs), same ungranted
                #     capability with guest credentials attached. The mini
                #     answers 404 for GETs; the point is what it RECORDED.
                status, _, _ = self._http_req(
                    port, "GET", "/github.com/acme/demo.git/info/refs?service=git-upload-pack",
                    headers={"Cookie": guest_cookie, "Authorization": guest_auth},
                    capability=PERSONAL_CAP)
                self.assertEqual(status, 404)
        entries = [json.loads(line) for line in record.read_text().splitlines() if line.strip()]
        batches = [e for e in entries if e["method"] == "POST"]
        gets = [e for e in entries if e["method"] == "GET"]
        self.assertEqual(len(batches), 1, entries)
        self.assertIsNone(batches[0]["authorization"], entries)  # no host token either
        self.assertIsNone(batches[0]["cookie"], entries)         # guest Cookie stripped
        self.assertEqual(len(gets), 1, entries)
        self.assertIsNone(gets[0]["authorization"], entries)
        self.assertIsNone(gets[0]["cookie"], entries)

    # ---- LFS batch fail-closed (never pass through upstream hrefs/headers) --

    def test_lfs_batch_malformed_entries_fail_closed(self) -> None:
        """Malformed LFS batch entries refuse the WHOLE batch (fail-closed).

        A non-dict entry, a missing or invalid oid, non-dict actions, an
        unsupported action name, or a non-dict action must never pass
        through unchanged: the VM sees an LFS error, no raw upstream href or
        credential header appears in any VM-visible byte, and no object
        request ever follows (the mini records the batch POSTs only).
        """
        oid = hashlib.sha256(b"malformed").hexdigest()
        credential = "Bearer leak-me-cred"
        marker = b"127.0.0.1:1"  # the crafted upstream href host:port
        record = self.env.root / "mini-malformed.jsonl"
        crafted = {}
        cases = [
            ("non-dict entry", {"transfer": "basic", "objects": [["junk", 42]]}),
            ("missing oid", {"transfer": "basic", "objects": [{
                "size": 3, "authenticated": True,
                "actions": {"download": {"href": f"http://127.0.0.1:1/objects/{oid}",
                                         "header": {"Authorization": credential}}}}]}),
            ("invalid oid", {"transfer": "basic", "objects": [{
                "oid": "not-a-64-hex-oid", "size": 3, "authenticated": True,
                "actions": {"download": {"href": f"http://127.0.0.1:1/objects/{oid}",
                                         "header": {"Authorization": credential}}}}]}),
            ("non-dict actions", {"transfer": "basic", "objects": [{
                "oid": oid, "size": 3, "authenticated": True,
                "actions": "not-an-actions-map"}]}),
            ("unsupported action", {"transfer": "basic", "objects": [{
                "oid": oid, "size": 3, "authenticated": True,
                "actions": {"verify": {"href": f"http://127.0.0.1:1/objects/{oid}",
                                       "header": {"Authorization": credential}}}}]}),
            ("non-dict action", {"transfer": "basic", "objects": [{
                "oid": oid, "size": 3, "authenticated": True,
                "actions": {"download": "not-an-action"}}]}),
        ]
        batch_body = json.dumps({"operation": "download", "transfers": ["basic"],
                                 "objects": [{"oid": oid, "size": 3}]}).encode()
        with self._crafted_batch_upstream(lambda: crafted, record) as mini:
            for tag, batch in cases:
                crafted = batch
                status, resp = self._proxy_request(
                    self._req_bytes("POST", "/github.com/acme/demo.git/info/lfs/objects/batch",
                                    headers=[("Content-Type", "application/vnd.git-lfs+json"),
                                             ("Content-Length", str(len(batch_body)))],
                                    body=batch_body),
                    env_overrides={"MSW_PROXY_UPSTREAM_ROOT": mini})
                self.assertEqual(status, 403, f"{tag}: {resp[:200]}")
                self.assertIn(b'"message"', resp, tag)   # LFS error shape
                self.assertNotIn(credential.encode(), resp, tag)
                self.assertNotIn(marker, resp, tag)      # no raw upstream href
    def test_lfs_batch_error_only_entries_pass_through_unchanged(self) -> None:
        """Actionless valid-oid batch entries pass through unchanged.

        GitHub legitimately returns valid-oid entries WITHOUT actions: a
        missing-object download carries `error` and no actions; an upload of
        an already-present object carries neither actions nor error. Such
        entries are serialized as-is (nothing to stamp, nothing to leak),
        including an EMPTY actions map -- as long as the oid is valid and
        there is no top-level href/header; when an `error` is present it
        must be spec-shaped (a dict with an integer code and a string
        message). Every deviation (raw href/header on the entry, malformed
        error) still fails the WHOLE batch closed.
        """
        oid = hashlib.sha256(b"missing-object").hexdigest()
        record = self.env.root / "mini-error-entry.jsonl"
        crafted = {}
        good_cases = [
            ("error-only", {"transfer": "basic", "objects": [{
                "oid": oid, "size": 9, "authenticated": True,
                "error": {"code": 404, "message": "Object does not exist"}}]}),
            ("no actions no error (upload already present)",
             {"transfer": "basic", "objects": [{
                 "oid": oid, "size": 9, "authenticated": True}]}),
            ("empty actions map", {"transfer": "basic", "objects": [{
                "oid": oid, "size": 9, "authenticated": True, "actions": {}}]}),
        ]
        with self._crafted_batch_upstream(lambda: crafted, record) as mini:
            # (a) actionless entries pass through unchanged, 200
            with self._proxy_listener(env_overrides={"MSW_PROXY_UPSTREAM_ROOT": mini}) as port:
                for tag, good in good_cases:
                    crafted = good
                    status, _, body = self._http_req(
                        port, "POST", "/github.com/acme/demo.git/info/lfs/objects/batch",
                        body=json.dumps({"operation": "download", "transfers": ["basic"],
                                         "objects": [{"oid": oid, "size": 9}]}),
                        headers={"Content-Type": "application/vnd.git-lfs+json"})
                    self.assertEqual(status, 200, f"{tag}: {body[:200]}")
                    entry = json.loads(body)["objects"][0]
                    self.assertEqual(entry["oid"], oid, tag)
                    self.assertNotIn("href", entry, tag)
                    self.assertNotIn("header", entry, tag)
                    self.assertNotIn(b"/objects/", body, tag)  # no proxy/upstream URL
                    self.assertNotIn(b"http://", body, tag)
                    if tag == "error-only":
                        self.assertEqual(entry["error"],
                                         {"code": 404, "message": "Object does not exist"})
                        self.assertNotIn("actions", entry)  # unchanged: nothing stamped
                    elif tag == "empty actions map":
                        self.assertEqual(entry.get("actions"), {})
            # (b) every deviation still refuses the WHOLE batch closed
            batch_body = json.dumps({"operation": "download", "transfers": ["basic"],
                                     "objects": [{"oid": oid, "size": 9}]}).encode()
            bad_cases = [
                ("raw href on error entry", {"transfer": "basic", "objects": [{
                    "oid": oid, "size": 9, "authenticated": True,
                    "href": f"{mini}/objects/{oid}",
                    "error": {"code": 404, "message": "Object does not exist"}}]}),
                ("raw header on error entry", {"transfer": "basic", "objects": [{
                    "oid": oid, "size": 9, "authenticated": True,
                    "header": {"Authorization": "Bearer leak"},
                    "error": {"code": 404, "message": "Object does not exist"}}]}),
                ("non-dict error", {"transfer": "basic", "objects": [{
                    "oid": oid, "size": 9, "authenticated": True,
                    "error": "missing"}]}),
                ("non-int error code", {"transfer": "basic", "objects": [{
                    "oid": oid, "size": 9, "authenticated": True,
                    "error": {"code": "404", "message": "Object does not exist"}}]}),
                ("bool error code", {"transfer": "basic", "objects": [{
                    "oid": oid, "size": 9, "authenticated": True,
                    "error": {"code": True, "message": "Object does not exist"}}]}),
                ("non-str error message", {"transfer": "basic", "objects": [{
                    "oid": oid, "size": 9, "authenticated": True,
                    "error": {"code": 404, "message": {"x": 1}}}]}),
            ]
            for tag, batch in bad_cases:
                crafted = batch
                status, resp = self._proxy_request(
                    self._req_bytes("POST", "/github.com/acme/demo.git/info/lfs/objects/batch",
                                    headers=[("Content-Type", "application/vnd.git-lfs+json"),
                                             ("Content-Length", str(len(batch_body)))],
                                    body=batch_body),
                    env_overrides={"MSW_PROXY_UPSTREAM_ROOT": mini})
                self.assertEqual(status, 403, f"{tag}: {resp[:200]}")
                self.assertIn(b'"message"', resp, tag)
                self.assertNotIn(b"leak", resp, tag)
                self.assertNotIn(b"127.0.0.1", resp, tag)
        entries = [json.loads(line) for line in record.read_text().splitlines() if line.strip()]
        self.assertEqual([e["method"] for e in entries], ["POST"] * 9, entries)

    def test_lfs_and_git_query_parameters_cannot_smuggle_credentials(self) -> None:
        """Query parameters cannot authenticate outside the grant decision.

        info/refs accepts EXACTLY one `service` parameter and no other query
        keys; git smart-HTTP POST endpoints and the LFS batch accept NO query
        at all. A query that embeds credentials
        (e.g. `?service=...&access_token=...`) is refused locally as a
        request-shape violation and NEVER forwarded -- auth:false truly means
        no guest or host credential went upstream with the batch request.
        """
        fake = self._start_fake_github()
        self.env.init_remote()
        batch_body = json.dumps({"operation": "download", "transfers": ["basic"],
                                 "objects": []}).encode()
        cases = [
            ("info/refs extra param",
             self._req_bytes("GET", "/github.com/acme/demo.git/info/refs"
                                    "?service=git-upload-pack&access_token=guest-token")),
            ("info/refs bare extra key",
             self._req_bytes("GET", "/github.com/acme/demo.git/info/refs"
                                    "?service=git-upload-pack&access_token")),
            ("info/refs missing service",
             self._req_bytes("GET", "/github.com/acme/demo.git/info/refs"
                                    "?access_token=guest-token")),
            ("git POST query",
             self._req_bytes("POST", "/github.com/acme/demo.git/git-upload-pack"
                                     "?access_token=guest-token",
                             headers=[("Content-Length", "0")])),
            ("LFS batch query",
             self._req_bytes("POST", "/github.com/acme/demo.git/info/lfs/objects/batch"
                                     "?access_token=guest-token",
                             headers=[("Content-Type", "application/vnd.git-lfs+json"),
                                      ("Content-Length", str(len(batch_body)))],
                             body=batch_body)),
        ]
        for tag, raw in cases:
            status, resp = self._proxy_request(raw)
            # git-shape denials surface as HTTP 200 with an ERR pkt-line, the
            # batch denial as a JSON 403; either way the token never reaches
            # the upstream and never appears in the response.
            self.assertIn(status, (200, 403), f"{tag}: {resp[:200]}")
            self.assertNotIn(b"guest-token", resp, tag)
        self.assertEqual(fake.requests(), [], "no credential-bearing query may reach the upstream")
        # the strict shape still admits the canonical form
        status, resp = self._proxy_request(
            self._req_bytes("GET", "/github.com/acme/demo.git/info/refs?service=git-upload-pack"))
        self.assertEqual(status, 200, resp[:200])
        self.assertEqual(len(fake.requests()), 1, fake.requests())

    # ---- objects-leg redirects are resealed, never exposed raw ------------

    def test_lfs_object_redirect_resealed_stamped(self) -> None:
        """Objects-leg redirects are resealed into a fresh stamp.

        The real object endpoint answers the stamped request with a 302 whose
        Location carries the upstream-SIGNED URL. The proxy must NOT hand
        that Location to the VM (it leaks the upstream signature and is an
        unstamped URL the classifier would reject): it reseals the redirect
        href/query and the PRESERVED action headers into a fresh stamp with
        the same repo/op/oid/auth provenance, so the VM-visible Location is
        stamped and the second hop through the proxy works -- even for an
        auth:false (ungranted) workspace, proving the provenance survived.
        Non-covered redirects stay denied.
        """
        oid = hashlib.sha256(b"redirect-reseal").hexdigest()
        payload = b"redirected-object-bytes"
        credential = "RemoteAuth redirect-scoped-temp"
        signed_query = "X-Amz-Credential=upstream-signed&X-Amz-Signature=abc123"
        record = self.env.root / "mini-redirect.jsonl"
        state = {"oid": oid, "payload": payload, "credential": credential,
                 "signed_query": signed_query, "target": "signed"}

        class RedirectObjectHandler(http.server.BaseHTTPRequestHandler):
            def _record(self, method: str) -> None:
                with record.open("a") as fh:
                    fh.write(json.dumps({
                        "method": method,
                        "path": self.path,
                        "authorization": self.headers.get("Authorization"),
                    }) + "\n")

            def do_GET(self) -> None:
                self._record("GET")
                if state["target"] == "signed":
                    self.send_response(302)
                    self.send_header(
                        "Location",
                        f"{self.server.base_url}/objects/{state['oid']}?{state['signed_query']}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                elif state["target"] == "evil":
                    self.send_response(302)
                    self.send_header(
                        "Location",
                        f"https://evil.example/objects/{state['oid']}?{state['signed_query']}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                else:
                    body = state["payload"]
                    self.send_response(200)
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

            def do_POST(self) -> None:
                self._record("POST")
                length = int(self.headers.get("Content-Length", "0") or 0)
                if length:
                    self.rfile.read(length)
                batch = {"transfer": "basic", "objects": [{
                    "oid": state["oid"], "size": len(state["payload"]),
                    "authenticated": True,
                    "actions": {"download": {
                        "href": f"{self.server.base_url}/objects/{state['oid']}",
                        "header": {"Authorization": state["credential"]}}}}]}
                body = json.dumps(batch).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/vnd.git-lfs+json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, fmt: str, *args: object) -> None:
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), RedirectObjectHandler)
        server.base_url = f"http://127.0.0.1:{server.server_address[1]}"
        mini = server.base_url
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with self._proxy_listener(env_overrides={"MSW_PROXY_UPSTREAM_ROOT": mini}) as port:
                # UNGRANTED workspace: anonymous batch -> auth:false stamp.
                status, _, body = self._http_req(
                    port, "POST", "/github.com/acme/demo.git/info/lfs/objects/batch",
                    body=json.dumps({"operation": "download", "transfers": ["basic"],
                                     "objects": [{"oid": oid, "size": len(payload)}]}),
                    headers={"Content-Type": "application/vnd.git-lfs+json"},
                    capability=PERSONAL_CAP)
                self.assertEqual(status, 200, body[:200])
                self.assertNotIn(b"upstream-signed", body)
                self.assertNotIn(credential.encode(), body)
                href = json.loads(body)["objects"][0]["actions"]["download"]["href"]
                u = urllib.parse.urlsplit(href)
                # First hop: the real endpoint redirects with a SIGNED query;
                # the proxy reseals it -- the VM sees a STAMPED Location only.
                status, resp_headers, body = self._http_req(
                    port, "GET", u.path + "?" + u.query, capability=PERSONAL_CAP)
                self.assertEqual(status, 302, body[:200])
                location = resp_headers.get("Location", "")
                loc = urllib.parse.urlsplit(location)
                self.assertEqual(loc.path, f"/objects.githubusercontent.com/objects/{oid}")
                loc_q = urllib.parse.parse_qs(loc.query)
                for key in ("_msw_repo", "_msw_op", "_msw_exp", "_msw_sig"):
                    self.assertIn(key, loc_q)
                self.assertEqual(loc_q["_msw_repo"], ["acme/demo"])
                self.assertEqual(loc_q["_msw_op"], ["download"])
                self.assertNotIn("X-Amz", location)          # upstream signature sealed
                self.assertNotIn("upstream-signed", location)
                self.assertNotIn(credential, location)       # action headers sealed
                self.assertNotIn("header", location)
                # Second hop: the resealed stamp works WITHOUT any grant
                # (auth:false provenance preserved) and the preserved action
                # header is re-attached host-side.
                state["target"] = "serve"
                status, _, body = self._http_req(
                    port, "GET", loc.path + "?" + loc.query, capability=PERSONAL_CAP)
                self.assertEqual(status, 200, body[:200])
                self.assertEqual(body, payload)
                # Non-covered redirect stays denied (fresh hop on the ORIGINAL
                # stamp now redirects to an evil host).
                state["target"] = "evil"
                status, _, body = self._http_req(
                    port, "GET", u.path + "?" + u.query, capability=PERSONAL_CAP)
                self.assertEqual(status, 403, body[:200])
        finally:
            server.shutdown()
            server.server_close()
        entries = [json.loads(line) for line in record.read_text().splitlines() if line.strip()]
        posts = [e for e in entries if e["method"] == "POST"]
        gets = [e for e in entries if e["method"] == "GET"]
        self.assertEqual(len(posts), 1, entries)
        self.assertIsNone(posts[0]["authorization"], entries)  # anonymous batch
        self.assertEqual(len(gets), 3, entries)  # hop1, hop2, evil
        self.assertEqual([g["authorization"] for g in gets],
                         [credential, credential, credential], entries)

    # ---- INGRESS-3: chunked over cap killed mid-stream -------------------

    def test_ingress3_chunked_over_cap_mid_stream_kill(self) -> None:
        fake = self._start_fake_github()
        self.env.init_remote()
        cap = 1024 * 1024
        # (a) request side: a >cap chunked body is killed mid-stream; the
        #     upstream is never contacted (spool-then-forward), so a partial
        #     body can never appear complete at the upstream.
        big_chunk = b"x" * cap
        body = f"{cap:x}\r\n".encode() + big_chunk + b"\r\n" + b"100000\r\n" + b"y" * (1024 * 1024) + b"\r\n0\r\n\r\n"
        status, resp = self._proxy_request(
            self._req_bytes("POST", "/github.com/acme/demo.git/git-upload-pack",
                            headers=[("Transfer-Encoding", "chunked")], body=body),
            env_overrides={"MSW_PROXY_MAX_BODY_BYTES": str(cap)})
        self.assertEqual(status, 413, resp[:200])
        self.assertEqual(fake.requests(), [])  # upstream untouched

        # (b) response side: upstream streams a Content-Length above the cap;
        #     the proxy aborts both legs mid-stream (fake records the request
        #     before streaming; the client observes the abort).
        fake.set_control({"mode": "oversized", "oversized_bytes": 16 * 1024 * 1024,
                          "match": {"path": "/acme/demo.git/info/refs", "method": "GET"}})
        status, resp = self._proxy_request(
            self._req_bytes("GET", "/github.com/acme/demo.git/info/refs?service=git-upload-pack"),
            env_overrides={"MSW_PROXY_MAX_BODY_BYTES": str(cap)})
        self.assertEqual(status, 0, resp[:200])  # closed, no complete response
        injected = [r for r in fake.requests() if r.get("injected") == "oversized"]
        self.assertEqual(len(injected), 1, fake.requests())

        # (c) next request fine (fresh per-connection proxy, default cap)
        fake.set_control({"mode": "normal"})
        status, resp = self._proxy_request(
            self._req_bytes("GET", "/github.com/acme/demo.git/info/refs?service=git-upload-pack"))
        self.assertEqual(status, 200, resp[:200])

    # ---- streaming proof (section 4: socket-to-socket, never buffer) --------

    def test_streaming_slow_feeder_upstream_receives_during_feed(self) -> None:
        """The upstream receives body bytes BEFORE the client finishes sending.

        A spooling proxy would contact the upstream only after the full body
        arrived (fake duration ~0); a streaming proxy forwards each confirmed
        chunk as it arrives, so the fake's request duration tracks the feed.
        """
        fake = self._start_fake_github()
        self.env.init_remote()
        env = self._proxy_env()
        sock, child = socket.socketpair()
        sock.settimeout(90)
        err = (self.env.root / "proxy-slow.err").open("ab")
        proc = subprocess.Popen([PROXY_BIN], stdin=child, stdout=child, stderr=err,
                                env=env, cwd=str(PACKAGE))
        child.close()
        try:
            chunk = b"x" * (64 * 1024)
            n_chunks = 12
            head = (
                f"POST /github.com/acme/demo.git/git-upload-pack HTTP/1.1\r\n"
                f"Host: {PROXY_HOST}\r\n"
                f"X-MSW-Capability: {DEV_CAP}\r\n"
                f"Transfer-Encoding: chunked\r\n\r\n"
            ).encode()
            sock.sendall(head)
            stall = 0.4
            for i in range(n_chunks):
                sock.sendall(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
                if i < n_chunks - 1:
                    time.sleep(stall)
            sock.sendall(b"0\r\n\r\n")
            data = b""
            while True:
                try:
                    piece = sock.recv(65536)
                except socket.timeout:
                    break
                if not piece:
                    break
                data += piece
            records = fake.requests()
            post = [r for r in records if r["path"] == "/acme/demo.git/git-upload-pack"
                    and r["method"] == "POST"]
            self.assertEqual(len(post), 1, records)
            # The fake must have been reading the body while the client was
            # still feeding: the upstream opens ~one chunk-period into the
            # feed (first confirmation), so duration ≈ feed - one period.
            expected = (n_chunks - 2) * stall * 1000 - 300
            self.assertGreaterEqual(
                post[0]["duration_ms"], expected,
                f"upstream must receive body bytes before the client finishes "
                f"(duration {post[0]['duration_ms']}ms < {expected}ms)",
            )
            self.assertGreater(len(data), 0)  # the proxy answered (fake 5xx on garbage body)
        finally:
            sock.close()
            proc.wait(timeout=30)
            err.close()

    def test_concurrent_under_cap_pushes_aggregate_disk_bounded(self) -> None:
        """N concurrent bodies never spill to disk (no spooling anywhere).

        The proxy writes only its one-line log per request (plus the 0600
        HMAC key file on first use); bodies live in sockets/memory only, so
        the proxy state dir and /tmp must not grow with the body bytes.
        """
        fake = self._start_fake_github()
        self.env.init_remote()

        def du_kb(path: str) -> int | None:
            proc = subprocess.run(["/usr/bin/du", "-sk", str(path)],
                                  capture_output=True, text=True)
            if proc.returncode != 0:
                return None  # unreadable tree (other users' temp files)
            return int(proc.stdout.split()[0])

        before_state = du_kb(str(self.env.root))
        before_tmp = du_kb("/private/tmp")
        self.assertIsNotNone(before_state)
        n_clients = 4
        body_size = 8 * 1024 * 1024  # 8 MiB per push, under the 64 MiB cap

        def one_client(port: int) -> None:
            body = b"z" * body_size
            head = (
                f"POST /github.com/acme/demo.git/git-upload-pack HTTP/1.1\r\n"
                f"Host: 127.0.0.1:{port}\r\n"
                f"X-MSW-Capability: {DEV_CAP}\r\n"
                f"Transfer-Encoding: chunked\r\n\r\n"
            ).encode()
            payload = head + f"{body_size:x}\r\n".encode() + body + b"\r\n0\r\n\r\n"
            s = socket.create_connection(("127.0.0.1", port), timeout=120)
            s.settimeout(120)
            try:
                s.sendall(payload)
                while True:
                    piece = s.recv(65536)
                    if not piece:
                        break
            finally:
                s.close()

        with self._proxy_listener(env_overrides={"MSW_PROXY_MAX_BODY_BYTES": str(64 * 1024 * 1024)}) as port:
            threads = [threading.Thread(target=one_client, args=(port,)) for _ in range(n_clients)]
            for t in threads:
                t.start()
            for t in threads:
                t.join(timeout=180)
                self.assertFalse(t.is_alive(), "concurrent client hung")
        after_state = du_kb(str(self.env.root))
        after_tmp = du_kb("/private/tmp")
        # Body bytes (4 x 8 MiB) must never land on disk; only log lines and
        # request records (a few KB) are written.
        self.assertIsNotNone(after_state)
        self.assertLess(after_state - before_state, 2048,
                        f"proxy state dir grew {after_state - before_state} KiB")
        if before_tmp is not None and after_tmp is not None:
            self.assertLess(after_tmp - before_tmp, 4096,
                            f"/tmp grew {after_tmp - before_tmp} KiB")
        posts = [r for r in fake.requests() if r["path"] == "/acme/demo.git/git-upload-pack"
                 and r["method"] == "POST"]
        self.assertEqual(len(posts), n_clients, fake.requests())

    # ---- INGRESS-4: CL+TE / dup CL / stacked TE / unknown coding ---------

    def test_ingress4_framing_rejections_upstream_untouched(self) -> None:
        fake = self._start_fake_github()
        self.env.init_remote()
        target = "/github.com/acme/demo.git/git-upload-pack"
        cases = [
            ("cl+te", self._req_bytes("POST", target, headers=[
                ("Content-Length", "5"), ("Transfer-Encoding", "chunked")],
                body=b"5\r\nhello\r\n0\r\n\r\n")),
            ("dup-cl-identical", self._req_bytes("POST", target, headers=[
                ("Content-Length", "5"), ("Content-Length", "5")], body=b"hello")),
            ("dup-cl-conflicting", self._req_bytes("POST", target, headers=[
                ("Content-Length", "5"), ("Content-Length", "6")], body=b"hello")),
            ("stacked-te", self._req_bytes("POST", target, headers=[
                ("Transfer-Encoding", "chunked"), ("Transfer-Encoding", "chunked")],
                body=b"5\r\nhello\r\n0\r\n\r\n")),
            ("unknown-coding", self._req_bytes("POST", target, headers=[
                ("Transfer-Encoding", "gzip")])),
        ]
        for name, raw in cases:
            status, resp = self._proxy_request(raw)
            self.assertEqual(status, 400, f"{name}: {resp[:200]}")
        # LFS batch with the wrong Content-Type is denied (endpoint table)
        status, resp = self._proxy_request(self._req_bytes(
            "POST", "/github.com/acme/demo.git/info/lfs/objects/batch",
            headers=[("Content-Type", "application/json")],
            body=json.dumps({"operation": "upload", "transfers": ["basic"], "objects": []}).encode()))
        self.assertEqual(status, 403, resp[:200])
        self.assertEqual(fake.requests(), [])  # upstream untouched

    # ---- TIMEOUT-1: idle + deadline via fake slow, drop teardown ---------

    def test_timeout1_idle_deadline_drop(self) -> None:
        fake = self._start_fake_github()
        self.env.init_remote()
        slow = {"mode": "slow", "slow_seconds": 6.0,
                "match": {"path": "/acme/demo.git/info/refs", "method": "GET"}}
        raw = self._req_bytes("GET", "/github.com/acme/demo.git/info/refs?service=git-upload-pack")

        fake.set_control(slow)
        t0 = time.monotonic()
        status, resp = self._proxy_request(
            raw, env_overrides={"MSW_PROXY_IDLE_TIMEOUT": "1", "MSW_PROXY_TOTAL_DEADLINE": "30"})
        idle_elapsed = time.monotonic() - t0
        self.assertEqual(status, 0, resp[:200])  # torn down, no response
        self.assertLess(idle_elapsed, 3.0)
        self.assertGreater(idle_elapsed, 0.3)

        fake.set_control(slow)
        t0 = time.monotonic()
        status, resp = self._proxy_request(
            raw, env_overrides={"MSW_PROXY_IDLE_TIMEOUT": "30", "MSW_PROXY_TOTAL_DEADLINE": "2"})
        deadline_elapsed = time.monotonic() - t0
        self.assertEqual(status, 0, resp[:200])
        self.assertGreaterEqual(deadline_elapsed, 1.0)
        self.assertLess(deadline_elapsed, 4.0)

        fake.set_control({"mode": "drop", "match": {"path": "/acme/demo.git/info/refs", "method": "GET"}})
        t0 = time.monotonic()
        status, resp = self._proxy_request(raw)
        self.assertLess(time.monotonic() - t0, 10.0)  # no hang on upstream teardown
        self.assertIn(status, (0, 502), resp[:200])
        dropped = [r for r in fake.requests() if r.get("injected") == "drop"]
        self.assertEqual(len(dropped), 1, fake.requests())

    # ---- REGRESS-1: CVE-2025-43859 malformed post-chunk-CRLF classes -----

    def test_regress1_cve_malformed_post_chunk_crlf(self) -> None:
        fake = self._start_fake_github()
        self.env.init_remote()
        target = "/github.com/acme/demo.git/git-upload-pack"
        te = [("Transfer-Encoding", "chunked")]
        payloads = [
            # class 1: garbage chunk terminator (no CRLF after chunk data)
            b"5\r\nhelloXX",
            # class 2: wrong terminator, then a clean end
            b"5\r\nhelloXY\r\n0\r\n\r\n",
            # class 3: malformed terminator followed by a smuggled second request
            b"5\r\nhelloXXGET /github.com/acme/demo.git/info/refs?service=git-receive-pack HTTP/1.1\r\n"
            b"Host: 127.0.0.1:18446\r\n\r\n",
        ]
        for i, body in enumerate(payloads):
            status, resp = self._proxy_request(self._req_bytes("POST", target, headers=te, body=body))
            self.assertEqual(status, 400, f"class {i + 1}: {resp[:200]}")
        self.assertEqual(fake.requests(), [])  # never contacts upstream

    # ---- REGRESS-2: vendored h11 pin + advisory record -------------------

    def test_regress2_vendored_h11_pin_and_advisory_record(self) -> None:
        saved = list(sys.path)
        try:
            sys.path.insert(0, str(PACKAGE / "lib" / "vendor"))
            import h11 as vendored_h11
        finally:
            sys.path[:] = saved
        vendored_file = Path(vendored_h11.__file__ or "").resolve()
        self.assertTrue(str(vendored_file).startswith(str(PACKAGE / "lib" / "vendor")),
                        vendored_file)
        version = tuple(int(p) for p in vendored_h11.__version__.split("."))
        self.assertGreaterEqual(version, (0, 16, 0), "vendored h11 must be >= 0.16.0")

        vendored = (PACKAGE / "VENDORED.md").read_text()
        self.assertIn("GHSA-vqfr-h8mv-ghfj", vendored)
        self.assertIn("CVE-2025-43859", vendored)
        self.assertIn("curl -sS -X POST https://api.osv.dev/v1/query", vendored)
        self.assertIn("-H 'Content-Type: application/json'", vendored)
        self.assertIn("4e35b956cf45792e4caa5885e69fba00bdbc6ffafbfa020300e549b208ee5ff1", vendored)
        self.assertIn("HARD FLOOR", vendored)
        self.assertIn("Never lower the pin", vendored)
        self.assertRegex(vendored, r"checked 20\d\d-\d\d-\d\d")
        manifest = (PACKAGE / "MANIFEST.txt").read_text()
        self.assertIn("# Vendored h11 0.16.0", manifest)
        for module in ("_connection", "_readers", "_writers", "_headers", "_abnf", "_state",
                       "_util", "_events", "_receivebuffer", "_version", "__init__"):
            self.assertIn(f"lib/vendor/h11/{module}.py", manifest)

    # ---- SMUGGLE matrix: 13 framing cases, upstream untouched ------------

    def test_smuggle_matrix_13_framing_cases(self) -> None:
        fake = self._start_fake_github()
        self.env.init_remote()
        post = "/github.com/acme/demo.git/git-upload-pack"
        adv = "/github.com/acme/demo.git/info/refs?service=git-upload-pack"
        cases = [
            ("cl+te", self._req_bytes("POST", post, headers=[
                ("Content-Length", "5"), ("Transfer-Encoding", "chunked")],
                body=b"5\r\nhello\r\n0\r\n\r\n")),
            ("dup-cl-identical", self._req_bytes("POST", post, headers=[
                ("Content-Length", "5"), ("Content-Length", "5")], body=b"hello")),
            ("dup-cl-conflicting", self._req_bytes("POST", post, headers=[
                ("Content-Length", "5"), ("Content-Length", "6")], body=b"hello")),
            ("stacked-te", self._req_bytes("POST", post, headers=[
                ("Transfer-Encoding", "chunked"), ("Transfer-Encoding", "chunked")],
                body=b"5\r\nhello\r\n0\r\n\r\n")),
            ("te-unknown-coding", self._req_bytes("POST", post, headers=[
                ("Transfer-Encoding", "gzip")])),
            ("te-stacked-in-one-value", self._req_bytes("POST", post, headers=[
                ("Transfer-Encoding", "chunked, chunked")])),
            ("body-on-get", self._req_bytes("GET", adv, headers=[
                ("Content-Length", "5")], body=b"hello")),
            ("invalid-chunk-size", self._req_bytes("POST", post, headers=[
                ("Transfer-Encoding", "chunked")], body=b"ZZ\r\nrest")),
            ("malformed-trailer", self._req_bytes("POST", post, headers=[
                ("Transfer-Encoding", "chunked")], body=b"1\r\na\r\n0\r\nBad Header\r\n\r\n")),
            ("absolute-form-target", self._req_bytes("GET", f"http://{PROXY_HOST}{adv}")),
            ("authority-form-target", self._req_bytes("GET", "github.com:443")),
            ("asterisk-form-target", self._req_bytes("GET", "*")),
            ("http-1.0-request", self._req_bytes("GET", adv, version="1.0")),
        ]
        for name, raw in cases:
            status, resp = self._proxy_request(raw)
            self.assertIn(status, (400, 405), f"{name}: {resp[:200]}")
        self.assertEqual(fake.requests(), [])

    def test_smuggle_pipelined_second_request_closed(self) -> None:
        fake = self._start_fake_github()
        self.env.init_remote()
        first = self._req_bytes("POST", "/github.com/acme/demo.git/git-upload-pack",
                                headers=[("Content-Length", "0")])
        second = self._req_bytes("GET", "/github.com/acme/demo.git/info/refs?service=git-receive-pack")
        status, _ = self._proxy_request(first + second)
        self.assertIn(status, (200, 500), "first request must be processed")
        records = fake.requests()
        upload = [r for r in records if r["path"] == "/acme/demo.git/git-upload-pack"]
        receive_adv = [r for r in records if r["path"] == "/acme/demo.git/info/refs"
                       and r["query"] == "service=git-receive-pack"]
        self.assertEqual(len(upload), 1, records)
        self.assertEqual(receive_adv, [], "pipelined second request must not be processed")

    def test_smuggle_header_and_transport_limits(self) -> None:
        fake = self._start_fake_github()
        self.env.init_remote()
        adv = "/github.com/acme/demo.git/info/refs?service=git-upload-pack"
        # header name outside ^[A-Za-z0-9-]+$ allowlist
        status, _ = self._proxy_request(self._req_bytes("GET", adv, headers=[("X_Bad", "1")]))
        self.assertEqual(status, 400)
        # header value with a control byte
        status, _ = self._proxy_request(self._req_bytes("GET", adv, headers=[("X-Test", "a\x01b")]))
        self.assertEqual(status, 400)
        # >64 headers
        many = [(f"X-H{i}", "1") for i in range(65)]
        status, _ = self._proxy_request(self._req_bytes("GET", adv, headers=many))
        self.assertEqual(status, 400)
        # >8KiB header value
        status, _ = self._proxy_request(self._req_bytes("GET", adv, headers=[("X-Big", "x" * 9000)]))
        self.assertEqual(status, 400)
        # >16KiB header block
        status, _ = self._proxy_request(self._req_bytes("GET", adv, headers=[("X-Big", "x" * 17000)]))
        self.assertEqual(status, 400)
        # wrong Host header
        status, _ = self._proxy_request(self._req_bytes("GET", adv, host="evil.example"))
        self.assertEqual(status, 400)
        # CONNECT always 405
        status, _ = self._proxy_request(self._req_bytes("CONNECT", "github.com:443"))
        self.assertEqual(status, 405)
        self.assertEqual(fake.requests(), [])

    # ---- policy matrix ----------------------------------------------------

    def test_policy_matrix(self) -> None:
        """Policy is a CREDENTIAL GRANT, never a reachability gate.

        Every valid git request reaches the upstream. Only a live
        workspace+repo+operation grant injects the host credential
        (Authorization present upstream); every other state -- read-only
        workspace, unticked repo, unknown capability, missing or malformed
        policy -- forwards ANONYMOUSLY and GitHub decides.
        """
        fake = self._start_fake_github()
        self.env.init_remote()
        read_adv = "/github.com/acme/demo.git/info/refs?service=git-upload-pack"
        write_adv = "/github.com/acme/demo.git/info/refs?service=git-receive-pack"

        def req(capability: str, target: str) -> tuple[int, bytes]:
            return self._proxy_request(self._req_bytes("GET", target, capability=capability))

        # read-only workspace: the READ rides the host credential (read-only
        # permits reads); the WRITE is forwarded anonymously (no write grant)
        # and GitHub decides.
        status, resp = req(PLAY_CAP, read_adv)
        self.assertEqual(status, 200, resp[:200])
        self.assertNotIn(b"ERR ", resp)
        status, resp = req(PLAY_CAP, write_adv)
        self.assertEqual(status, 200, resp[:200])
        self.assertNotIn(b"ERR ", resp)
        # read-write workspace: both forwarded WITH the host credential
        status, _ = req(DEV_CAP, read_adv)
        self.assertEqual(status, 200)
        status, resp = req(DEV_CAP, write_adv)
        self.assertEqual(status, 200, resp[:200])
        self.assertNotIn(b"ERR ", resp)
        # unticked workspace (no repos): anonymous, forwarded
        status, resp = req(PERSONAL_CAP, read_adv)
        self.assertEqual(status, 200, resp[:200])
        self.assertNotIn(b"ERR ", resp)
        # unknown workspace capability: anonymous, forwarded
        status, resp = req("d" * 48, read_adv)
        self.assertEqual(status, 200, resp[:200])
        self.assertNotIn(b"ERR ", resp)
        # missing policy file: anonymous, forwarded
        status, resp = self._proxy_request(
            self._req_bytes("GET", read_adv),
            env_overrides={"MSW_POLICY_FILE": str(self.env.root / "missing-policy.json")})
        self.assertEqual(status, 200, resp[:200])
        self.assertNotIn(b"ERR ", resp)
        # malformed policy file: anonymous, forwarded
        bad = self.env.root / "bad-policy.json"
        bad.write_text("{not json!!")
        status, resp = self._proxy_request(
            self._req_bytes("GET", read_adv),
            env_overrides={"MSW_POLICY_FILE": str(bad)})
        self.assertEqual(status, 200, resp[:200])
        self.assertNotIn(b"ERR ", resp)

        records = fake.requests()
        self.assertEqual(len(records), 8, records)
        # upstream saw every request; the host credential rode only with live
        # grants: playgrounds' READ (read-only allows reads), dev's read and
        # write. The read-only workspace's WRITE, unticked, unknown, and
        # missing/malformed-policy requests were anonymous.
        self.assertEqual(
            [r["authorization_present"] for r in records],
            [True, False, True, True, False, False, False, False], records,
        )
        self.assertTrue(all(r["response_status"] == 200 for r in records), records)
        write_records = [r for r in records if r["query"] == "service=git-receive-pack"]
        self.assertEqual(len(write_records), 2, records)
        self.assertEqual(
            [r["authorization_present"] for r in write_records], [False, True], records,
        )

    def test_proxy_policy_uses_persisted_non_default_workspace_list(self) -> None:
        fake = self._start_fake_github()
        self.env.init_remote()
        workspace_file = self.env.home / ".config/msw/workspaces.json"
        workspace_file.write_text(json.dumps({
            "schemaVersion": 1,
            "workspaces": [
                {"name": "development", "cpu": 12, "cpuCeiling": 12,
                 "memoryGiB": 48, "memoryCeilingGiB": 48,
                 "workspaceStorageGiB": 120, "runtimeStorageGiB": 100},
                {"name": "personal", "cpu": 4, "cpuCeiling": 8,
                 "memoryGiB": 16, "memoryCeilingGiB": 32,
                 "workspaceStorageGiB": 80, "runtimeStorageGiB": 60},
                {"name": "lab", "cpu": 6, "cpuCeiling": 12,
                 "memoryGiB": 32, "memoryCeilingGiB": 48,
                 "workspaceStorageGiB": 100, "runtimeStorageGiB": 80},
            ],
        }))
        lab_capability = "d" * 48
        self.policy_file.write_text(json.dumps({
            "schemaVersion": 1,
            "workspaces": {
                "lab": {"capability": lab_capability,
                        "repos": [{"canonical": "acme/demo", "mode": "read-only"}]},
            },
        }))
        target = "/github.com/acme/demo.git/info/refs?service=git-upload-pack"
        status, response = self._proxy_request(
            self._req_bytes("GET", target, capability=lab_capability)
        )
        self.assertEqual(status, 200, response[:200])
        self.assertEqual(len(fake.requests()), 1)

        self.policy_file.write_text(json.dumps({
            "schemaVersion": 1,
            "workspaces": {
                "dev": {"capability": DEV_CAP,
                        "repos": [{"canonical": "acme/demo", "mode": "read-only"}]},
            },
        }))
        # "dev" is not a configured workspace in this workspaces.json, so the
        # whole policy is unloadable: the request is forwarded ANONYMOUSLY
        # (never a local denial) and GitHub decides.
        status, response = self._proxy_request(self._req_bytes("GET", target))
        self.assertEqual(status, 200, response[:200])
        self.assertNotIn(b"ERR ", response)
        records = fake.requests()
        self.assertEqual(len(records), 2, records)
        self.assertTrue(records[0]["authorization_present"], records)   # lab read grant
        self.assertFalse(records[1]["authorization_present"], records)  # unloadable policy

    def test_policy_strict_shapes_degrade_to_anonymous(self) -> None:
        """The proxy's policy validator mirrors the host's strict rules.

        Every malformed shape (unknown workspace, uppercase repo/capability,
        duplicate repo/capability, invalid mode, .git suffix, short/non-hex
        capability, shape deviations) makes the WHOLE policy unloadable: no
        workspace can hold a grant, so every valid request is forwarded
        ANONYMOUSLY (never a local denial) and GitHub decides.
        """
        fake = self._start_fake_github()
        self.env.init_remote()
        read_adv = "/github.com/acme/demo.git/info/refs?service=git-upload-pack"
        base = {
            "schemaVersion": 1,
            "workspaces": {
                "dev": {"capability": DEV_CAP, "repos": [{"canonical": "acme/demo", "mode": "read-write"}]},
                "playgrounds": {"capability": PLAY_CAP, "repos": []},
                "personal": {"capability": PERSONAL_CAP, "repos": []},
            },
        }

        def with_ws(ws: dict) -> dict:
            payload = json.loads(json.dumps(base))
            payload["workspaces"] = ws
            return payload

        dev = base["workspaces"]["dev"]
        playgrounds = base["workspaces"]["playgrounds"]
        personal = base["workspaces"]["personal"]
        malformed = [
            ("unknown-workspace", with_ws({
                "dev": dev, "evil": {"capability": "d" * 48, "repos": []},
                "playgrounds": playgrounds, "personal": personal})),
            ("uppercase-repo", with_ws({
                "dev": {"capability": DEV_CAP, "repos": [{"canonical": "Acme/Demo", "mode": "read-write"}]},
                "playgrounds": playgrounds, "personal": personal})),
            ("uppercase-capability", with_ws({
                "dev": {"capability": "A" * 48, "repos": [{"canonical": "acme/demo", "mode": "read-write"}]},
                "playgrounds": playgrounds, "personal": personal})),
            ("newline-capability", with_ws({
                "dev": {"capability": ("a" * 48) + "\n", "repos": [{"canonical": "acme/demo", "mode": "read-write"}]},
                "playgrounds": playgrounds, "personal": personal})),
            ("duplicate-capability", with_ws({
                "dev": dev, "playgrounds": {"capability": DEV_CAP, "repos": []}, "personal": personal})),
            ("duplicate-repo", with_ws({
                "dev": {"capability": DEV_CAP, "repos": [
                    {"canonical": "acme/demo", "mode": "read-only"},
                    {"canonical": "acme/demo", "mode": "read-write"}]},
                "playgrounds": playgrounds, "personal": personal})),
            ("invalid-mode", with_ws({
                "dev": {"capability": DEV_CAP, "repos": [{"canonical": "acme/demo", "mode": "admin"}]},
                "playgrounds": playgrounds, "personal": personal})),
            ("git-suffix", with_ws({
                "dev": {"capability": DEV_CAP, "repos": [{"canonical": "acme/demo.git", "mode": "read-write"}]},
                "playgrounds": playgrounds, "personal": personal})),
            ("short-capability", with_ws({
                "dev": {"capability": "short", "repos": []},
                "playgrounds": playgrounds, "personal": personal})),
            ("non-hex-capability", with_ws({
                "dev": {"capability": "not-hex", "repos": []},
                "playgrounds": playgrounds, "personal": personal})),
            # bool True == 1 must be rejected (schemaVersion must be the int 1)
            ("schema-bool-true", {"schemaVersion": True, "workspaces": base["workspaces"]}),
            # leading "." or "-" in a segment violates the exact repo grammar
            ("leading-dot-owner", with_ws({
                "dev": {"capability": DEV_CAP, "repos": [{"canonical": "org/.github", "mode": "read-write"}]},
                "playgrounds": playgrounds, "personal": personal})),
            ("leading-dot-repo", with_ws({
                "dev": {"capability": DEV_CAP, "repos": [{"canonical": ".org/repo", "mode": "read-write"}]},
                "playgrounds": playgrounds, "personal": personal})),
            ("workspace-null", with_ws({
                "dev": None, "playgrounds": playgrounds, "personal": personal})),
            ("workspaces-not-object", {"schemaVersion": 1, "workspaces": []}),
            ("repos-not-list", with_ws({
                "dev": {"capability": DEV_CAP, "repos": "acme/demo"},
                "playgrounds": playgrounds, "personal": personal})),
            ("repo-entry-not-object", with_ws({
                "dev": {"capability": DEV_CAP, "repos": ["acme/demo"]},
                "playgrounds": playgrounds, "personal": personal})),
            ("schema-version-2", {"schemaVersion": 2, "workspaces": base["workspaces"]}),
        ]
        for name, payload in malformed:
            self._rewrite_policy(payload)
            status, resp = self._proxy_request(self._req_bytes("GET", read_adv))
            self.assertEqual(status, 200, f"{name}: {resp[:200]}")
            self.assertNotIn(b"ERR ", resp, f"{name}: {resp[:200]}")
        # every malformed shape still reached the upstream -- anonymously
        records = fake.requests()
        self.assertEqual(len(records), len(malformed), records)
        self.assertTrue(all(not r["authorization_present"] for r in records), records)
        self.assertTrue(all(r["response_status"] == 200 for r in records), records)
        # sanity: both JSON numeric spellings accepted by jq (`1` and `1.0`)
        # are accepted by the proxy too; a valid policy authenticates again.
        for schema_version in (1, 1.0):
            valid = json.loads(json.dumps(base))
            valid["schemaVersion"] = schema_version
            self._rewrite_policy(valid)
            status, resp = self._proxy_request(self._req_bytes("GET", read_adv))
            self.assertEqual(status, 200, resp[:200])
            self.assertNotIn(b"ERR ", resp)
        records = fake.requests()
        self.assertEqual(len(records), len(malformed) + 2, records)
        self.assertTrue(records[-1]["authorization_present"], records)
        self.assertTrue(records[-2]["authorization_present"], records)

    def _bridge_procs(self) -> list[str]:
        proc = subprocess.run(["/usr/bin/pgrep", "-f", "msw-keychain-bridge"],
                              capture_output=True, text=True)
        if proc.returncode != 0:
            return []
        return [line for line in proc.stdout.splitlines() if line.strip()]

    def test_proxy_host_token_bridge_hang_bounded_no_descendants(self) -> None:
        """Closure re-review: a wedged keychain-bridge worker must not hang
        the proxy or leave descendants behind.

        The request DEGRADES to anonymous forwarding (public access keeps
        working) bounded by the helper watchdog -- never a local denial; no
        bridge/worker process survives; the next request works; the
        credential record is unchanged. The requested proxy deadline is
        deliberately lower than the helper's two-read budget; production code
        must clamp it above both complete helper cleanup deadlines.
        """
        fake = self._start_fake_github()
        self.env.init_remote()
        hang_env = {
            "MSW_TEST_KEYCHAIN_DIR": "",  # force the real bridge path
            "MSW_FAKE_BRIDGE_HANG": "1",
            "MSW_KEYCHAIN_TIMEOUT_SECS": "30",   # worker would outlive caller
            "MSW_HOST_TOKEN_TIMEOUT_SECS": "3", # helper kills bridge group
            "MSW_HOST_TOKEN_TIMEOUT": "1",      # proxy must clamp to >= 11
        }
        t0 = time.monotonic()
        status, resp = self._proxy_request(
            self._req_bytes("GET", "/github.com/acme/demo.git/info/refs?service=git-upload-pack"),
            env_overrides=hang_env, timeout=20)
        elapsed = time.monotonic() - t0
        self.assertEqual(status, 200, resp[:200])
        self.assertLess(elapsed, 12, f"must be bounded by the helper watchdog, took {elapsed:.1f}s")
        self.assertEqual(self._bridge_procs(), [], "no bridge/worker may survive the request")
        # the credential record is unchanged
        name = (
            re.sub(r"[^A-Za-z0-9_.-]", "_", HOST_KEYCHAIN_SERVICE)
            + "__" + re.sub(r"[^A-Za-z0-9_.-]", "_", HOST_KEYCHAIN_ACCOUNT)
        )
        record = json.loads((self.env.root / "keychain" / name).read_text())
        self.assertEqual(record["accessToken"], HOST_TOKEN)
        # the next request works normally (token now loads -> authenticated)
        status, resp = self._proxy_request(
            self._req_bytes("GET", "/github.com/acme/demo.git/info/refs?service=git-upload-pack"))
        self.assertEqual(status, 200, resp[:200])
        records = fake.requests()
        self.assertEqual(len(records), 2, records)
        # the wedged-bridge request reached the upstream WITHOUT the host
        # credential; the healthy one carried it
        self.assertFalse(records[0]["authorization_present"], records)
        self.assertTrue(records[1]["authorization_present"], records)
        self.assertEqual(self._bridge_procs(), [])

    def test_read_only_push_forwarded_anonymously_to_github(self) -> None:
        """A read-only workspace's push is no longer denied locally: it
        reaches GitHub anonymously (no host credential anywhere) and GitHub's
        decision is what the git client sees -- against the permissive fake
        the push succeeds."""
        fake = self._start_fake_github()
        self.env.init_remote()
        with self._proxy_listener() as port:
            git_home = self.env.root / "git-home"
            git_home.mkdir(exist_ok=True)
            env = self.env.env.copy()
            env.update({"HOME": str(git_home), "GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1"})
            work = self.env.root / "anon-push-work"
            run_cmd([SYSTEM_GIT, "clone", "-q",
                     str(self.env.root / "remotes" / "acme" / "demo.git"), str(work)], env=env)
            run_cmd([SYSTEM_GIT, "-C", str(work), "config", "user.name", "T"], env=env)
            run_cmd([SYSTEM_GIT, "-C", str(work), "config", "user.email", "t@example.invalid"], env=env)
            (work / "note.txt").write_text("anon\n")
            run_cmd([SYSTEM_GIT, "-C", str(work), "add", "note.txt"], env=env)
            run_cmd([SYSTEM_GIT, "-C", str(work), "commit", "-qm", "anon push"], env=env)
            url = f"http://127.0.0.1:{port}/github.com/acme/demo.git"
            push = run_cmd(
                [SYSTEM_GIT, "-C", str(work), "-c", f"http.extraHeader=X-MSW-Capability: {PLAY_CAP}",
                 "push", url, "main"],
                env=env, timeout=120)
            self.assertEqual(push.returncode, 0, push.stdout + push.stderr)
        records = fake.requests()
        receive = [r for r in records if r["query"] == "service=git-receive-pack"]
        self.assertTrue(receive, records)
        self.assertTrue(all(not r["authorization_present"] for r in receive), records)
        self.assertTrue(all(r["response_status"] == 200 for r in receive), records)

    def test_private_style_upstream_denial_propagates(self) -> None:
        """A GitHub-side denial for a grant-less request is passed through
        unchanged: no local 403->ERR conversion, no host credential added --
        GitHub's 403 (private-repo style) is exactly what the guest sees."""
        fake = self._start_fake_github()
        self.env.init_remote()
        record = self.env.root / "mini-deny.jsonl"

        class DenyHandler(http.server.BaseHTTPRequestHandler):
            def _send(self, status: int, body: bytes) -> None:
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self) -> None:
                with record.open("a") as fh:
                    fh.write(json.dumps({
                        "method": "GET",
                        "path": self.path,
                        "authorization": self.headers.get("Authorization"),
                    }) + "\n")
                self._send(403, json.dumps({"message": "Not Found"}).encode())

            def log_message(self, fmt: str, *args: object) -> None:
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), DenyHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            mini = f"http://127.0.0.1:{server.server_address[1]}"
            # an unticked workspace's read of a private-style repo: the
            # upstream's 403 reaches the guest as a plain 403
            status, resp = self._proxy_request(
                self._req_bytes("GET", "/github.com/acme/demo.git/info/refs?service=git-upload-pack",
                                capability=PERSONAL_CAP),
                env_overrides={"MSW_PROXY_UPSTREAM_ROOT": mini})
            self.assertEqual(status, 403, resp[:200])
            self.assertIn(b'"message"', resp)
            self.assertNotIn(b"ERR ", resp)
        finally:
            server.shutdown()
            server.server_close()
        entries = [json.loads(line) for line in record.read_text().splitlines() if line.strip()]
        self.assertEqual(len(entries), 1, entries)
        self.assertEqual(entries[0]["method"], "GET")
        self.assertIsNone(entries[0]["authorization"], entries)

    # ---- identity spoofing ------------------------------------------------

    def test_identity_spoofing_workspace_capability_not_interchangeable(self) -> None:
        """Capabilities map to POLICY GRANTS, not to each other.

        playgrounds' capability never injects dev's read-write credential:
        its write is forwarded anonymously and GitHub decides, while dev's
        capability authenticates the same request. A MISSING capability is
        likewise anonymous (public access needs no setup); duplicate
        capability headers remain a local shape denial.
        """
        fake = self._start_fake_github()
        self.env.init_remote()
        write_adv = "/github.com/acme/demo.git/info/refs?service=git-receive-pack"

        # playgrounds is read-only; its capability must NOT inject the host
        # credential (anonymous forward; GitHub decides)
        status, resp = self._proxy_request(
            self._req_bytes("GET", write_adv, capability=PLAY_CAP))
        self.assertEqual(status, 200, resp[:200])
        self.assertNotIn(b"ERR ", resp)
        # the same request with dev's capability IS authenticated
        status, _ = self._proxy_request(
            self._req_bytes("GET", write_adv, capability=DEV_CAP))
        self.assertEqual(status, 200)
        # missing capability: anonymous, forwarded (git ERR would be a denial)
        status, resp = self._proxy_request(self._req_bytes("GET", write_adv, capability=None))
        self.assertEqual(status, 200, resp[:200])
        self.assertNotIn(b"ERR ", resp)
        # duplicate capability headers: ambiguous identity stays a local
        # shape denial (git ERR on a git endpoint)
        status, resp = self._proxy_request(
            self._req_bytes("GET", write_adv, capability=None, headers=[
                ("X-MSW-Capability", DEV_CAP), ("X-MSW-Capability", PLAY_CAP)]))
        self.assertEqual(status, 200, resp[:200])
        self.assertIn(b"ERR ", resp)
        records = fake.requests()
        self.assertEqual(len(records), 3, records)  # duplicate-header one denied
        self.assertEqual(
            [r["authorization_present"] for r in records],
            [False, True, False], records,
        )

    # ---- canonicalization attacks -----------------------------------------

    def test_canonicalization_attacks(self) -> None:
        fake = self._start_fake_github()
        self.env.init_remote()

        # case + .git: canonicalized to acme/demo and allowed
        status, resp = self._proxy_request(
            self._req_bytes("GET", "/github.com/ACME/Demo.git/info/refs?service=git-upload-pack"))
        self.assertEqual(status, 200, resp[:200])
        # bare repo (no .git) also canonicalized
        status, _ = self._proxy_request(
            self._req_bytes("GET", "/github.com/acme/demo/info/refs?service=git-upload-pack"))
        self.assertEqual(status, 200)
        # double slash: empty path segment rejected (git ERR on a git endpoint)
        status, resp = self._proxy_request(
            self._req_bytes("GET", "/github.com//acme/demo.git/info/refs?service=git-upload-pack"))
        self.assertEqual(status, 200, resp[:200])
        self.assertIn(b"ERR ", resp)
        # percent-encoding inside the repo path rejected (git ERR)
        status, resp = self._proxy_request(
            self._req_bytes("GET", "/github.com/acme%2Fdemo.git/info/refs?service=git-upload-pack"))
        self.assertEqual(status, 200, resp[:200])
        self.assertIn(b"ERR ", resp)
        # trailing dot canonicalizes to a DISTINCT repo (acme./demo, never
        # acme/demo): not granted, so the read is forwarded ANONYMOUSLY and
        # GitHub decides (the fake 404s; its record proves no host credential
        # rode along)
        status, resp = self._proxy_request(
            self._req_bytes("GET", "/github.com/acme./demo.git/info/refs?service=git-upload-pack"))
        self.assertEqual(status, 404, resp[:200])
        records = fake.requests()
        self.assertEqual(records[-1]["path"], "/acme./demo.git/info/refs")
        self.assertFalse(records[-1]["authorization_present"], records)
        # absolute-form target rejected at ingress
        status, _ = self._proxy_request(
            self._req_bytes("GET", f"http://{PROXY_HOST}/github.com/acme/demo.git/info/refs?service=git-upload-pack"))
        self.assertEqual(status, 400)
        # wrong Host rejected at ingress
        status, _ = self._proxy_request(
            self._req_bytes("GET", "/github.com/acme/demo.git/info/refs?service=git-upload-pack",
                            host="evil.example"))
        self.assertEqual(status, 400)

        # redirects to other hosts are refused; covered-host redirects are
        # rewritten to the proxy form (no redirect following).
        handler = None

        class RedirectHandler(http.server.BaseHTTPRequestHandler):
            target = ""

            def do_GET(self) -> None:
                self.send_response(302)
                self.send_header("Location", type(self).target)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, fmt: str, *args: object) -> None:
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), RedirectHandler)
        mini_port = server.server_address[1]
        redirect_target = [f"http://127.0.0.1:{mini_port}/elsewhere"]

        class SetTargetHandler(RedirectHandler):
            target = redirect_target[0]

        server.RequestHandlerClass = SetTargetHandler
        import threading
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            # covered-host redirect -> rewritten to the proxy form
            status, resp = self._proxy_request(
                self._req_bytes("GET", "/github.com/acme/demo.git/info/refs?service=git-upload-pack"),
                env_overrides={"MSW_PROXY_UPSTREAM_ROOT": f"http://127.0.0.1:{mini_port}"})
            self.assertEqual(status, 302)
            self.assertIn(f"Location: http://{PROXY_HOST}/github.com/elsewhere", resp.decode("latin-1", "replace"))
            # other-host redirect -> 403 (surfaced as a git ERR pkt-line)
            SetTargetHandler.target = "https://evil.example/x"
            status, resp = self._proxy_request(
                self._req_bytes("GET", "/github.com/acme/demo.git/info/refs?service=git-upload-pack"),
                env_overrides={"MSW_PROXY_UPSTREAM_ROOT": f"http://127.0.0.1:{mini_port}"})
            self.assertEqual(status, 200, resp[:200])
            self.assertIn(b"ERR redirect to a non-covered host", resp)
        finally:
            server.shutdown()
            server.server_close()

    # ---- log redaction + structured record --------------------------------

    def test_proxy_log_redaction_and_structured_record(self) -> None:
        fake = self._start_fake_github()
        self.env.init_remote()
        # one allowed git request, one denied non-git request (JSON 403), one
        # denied git request (git ERR, HTTP 200 with an error reason), one batch
        status, _ = self._proxy_request(
            self._req_bytes("GET", "/github.com/acme/demo.git/info/refs?service=git-upload-pack"))
        self.assertEqual(status, 200)
        status, _ = self._proxy_request(
            self._req_bytes("GET", f"/objects.githubusercontent.com/objects/{'0' * 64}",
                            capability="d" * 48))
        self.assertEqual(status, 403)
        # a shape denial on a git endpoint (canonicalization attack) still
        # surfaces as a git ERR (HTTP 200 with an error reason)
        status, resp = self._proxy_request(
            self._req_bytes("GET", "/github.com//acme/demo.git/info/refs?service=git-receive-pack",
                            capability="d" * 48))
        self.assertEqual(status, 200, resp[:200])
        self.assertIn(b"ERR ", resp)
        batch_body = json.dumps({"operation": "upload", "transfers": ["basic"], "objects": []}).encode()
        status, resp = self._proxy_request(
            self._req_bytes("POST", "/github.com/acme/demo.git/info/lfs/objects/batch",
                            headers=[("Content-Type", "application/vnd.git-lfs+json"),
                                     ("Content-Length", str(len(batch_body)))],
                            body=batch_body))
        self.assertEqual(status, 200, resp[:200])

        log_text = self.proxy_log.read_text()
        self.assertNotIn(DEV_CAP, log_text)      # capability never logged
        self.assertNotIn("d" * 48, log_text)
        self.assertNotIn(HOST_TOKEN, log_text)   # token never logged
        lines = [json.loads(line) for line in log_text.splitlines() if line.strip()]
        allowed = [line for line in lines if line.get("box") == "dev" and line.get("repo") == "acme/demo"]
        self.assertTrue(allowed, lines)
        self.assertTrue(any(line.get("status") == 403 for line in lines), lines)
        self.assertTrue(any(line.get("status") == 200 and line.get("error") for line in lines), lines)
        self.assertTrue(any(line.get("status") == 200 and line.get("op") == "read" for line in lines), lines)
        self.assertTrue(any(line.get("status") == "start" for line in lines), lines)

    # ---- fixture lifecycle (Phase 0 shell kept) ---------------------------

    def test_fake_github_fixture_lifecycle(self) -> None:
        fake = self._start_fake_github()
        self.assertGreater(fake.port, 0)
        self.assertEqual(fake.state_dir, self.env.root / "fake-github")
        try:
            with urllib.request.urlopen(fake.base_url + "/user", timeout=10) as resp:
                self.assertEqual(resp.status, 200)
                user = json.loads(resp.read())
            self.assertEqual(user["login"], "fake-user")

            self.env.init_remote()
            refs = run_cmd(
                [SYSTEM_GIT, "-c", "protocol.version=2", "ls-remote", fake.base_url + "/acme/demo.git"],
                env={**self.env.env, "GIT_TERMINAL_PROMPT": "0"},
                timeout=30,
            ).stdout
            self.assertIn("refs/heads/main", refs)

            records = fake.requests()
            user_records = [r for r in records if r["path"] == "/user"]
            self.assertEqual(len(user_records), 1, records)
            self.assertEqual(user_records[0]["method"], "GET")
            self.assertEqual(user_records[0]["response_status"], 200)
            self.assertFalse(user_records[0]["authorization_present"])
            info_refs = [r for r in records if r["path"] == "/acme/demo.git/info/refs"]
            self.assertEqual(len(info_refs), 1, records)
            self.assertEqual(info_refs[0]["method"], "GET")
            self.assertEqual(info_refs[0]["query"], "service=git-upload-pack")
            self.assertEqual(info_refs[0]["response_status"], 200)
            self.assertGreater(info_refs[0]["response_bytes"], 0)
            rpc = [r for r in records if r["path"] == "/acme/demo.git/git-upload-pack" and r["method"] == "POST"]
            self.assertEqual(len(rpc), 1, records)
            self.assertEqual(rpc[0]["response_status"], 200)
        finally:
            fake.close()
        self.assertIsNotNone(fake.proc)
        self.assertEqual(fake.proc.poll(), 0)


class _LocalModeGitHubBase(MSWTestCase):
    """Shared fixtures for Path C §5/§8/§11 local-mode CLI tests."""

    POLICY_DIR_NAME = "Library/Application Support/MSW Monitor"

    def setUp(self) -> None:
        super().setUp()
        self.env.env["MSW_GITHUB_MODE"] = "local"
        self.env.env["MSW_JQ_BIN"] = "/usr/bin/jq"
        self.env.env["MSW_HOST_KEYCHAIN_SERVICE"] = HOST_KEYCHAIN_SERVICE
        self.env.env["MSW_HOST_KEYCHAIN_ACCOUNT"] = HOST_KEYCHAIN_ACCOUNT

    @property
    def policy_path(self) -> Path:
        return self.env.home / self.POLICY_DIR_NAME / "github-policy.json"

    @property
    def host_meta_path(self) -> Path:
        return self.env.home / self.POLICY_DIR_NAME / "github-host.json"

    @property
    def host_key_path(self) -> Path:
        return self.env.key_file(HOST_KEYCHAIN_SERVICE, HOST_KEYCHAIN_ACCOUNT)

    @property
    def github_meta_dir(self) -> Path:
        return self.env.home / ".config/msw/github"

    def set_policy(self, payload: object) -> None:
        self.policy_path.parent.mkdir(parents=True, exist_ok=True)
        self.policy_path.write_text(json.dumps(payload))

    def empty_policy(self) -> None:
        self.set_policy({"schemaVersion": 1, "workspaces": {
            "dev": {"capability": DEV_CAP, "repos": []},
            "playgrounds": {"capability": PLAY_CAP, "repos": []},
            "personal": {"capability": PERSONAL_CAP, "repos": []},
        }})

    def host_record(self, *, token: str = HOST_TOKEN, generation: int = 1,
                    provider: str = "gh-cli", kind: str = "oauth",
                    login: str = "fake-user") -> dict:
        return {
            "schemaVersion": 1,
            "provider": provider,
            "tokenKind": kind,
            "accessToken": token,
            "accountLogin": login,
            "verifiedAt": "2026-01-01T00:00:00Z",
            "generation": generation,
            "storedAt": "2026-01-01T00:00:00Z",
        }

    def seed_host_credential(self, record: dict | None = None,
                             meta: dict | None = None) -> Path:
        record = record or self.host_record()
        self.host_key_path.parent.mkdir(parents=True, exist_ok=True)
        self.host_key_path.write_text(json.dumps(record))
        if meta is None:
            meta = {
                "schemaVersion": 1,
                "state": "active",
                "generation": record.get("generation", 1),
                "accountLogin": record.get("accountLogin", "fake-user"),
            }
        self.host_meta_path.parent.mkdir(parents=True, exist_ok=True)
        self.host_meta_path.write_text(json.dumps(meta))
        return self.host_key_path

    def seed_host_meta(self, *, generation: int = 1, login: str = "fake-user",
                       state: str = "active", token_kind: str = "oauth",
                       provider: str = "gh-cli") -> Path:
        """Write the nonsecret activation metadata (blocker 4: state active +
        generation/accountLogin matching the Keychain record)."""
        self.host_meta_path.parent.mkdir(parents=True, exist_ok=True)
        meta = {
            "schemaVersion": 1,
            "state": state,
            "provider": provider,
            "tokenKind": token_kind,
            "accountLogin": login,
            "verifiedAt": "2026-01-01T00:00:00Z",
            "generation": generation,
            "storedAt": "2026-01-01T00:00:00Z",
            "repoChecks": [],
        }
        self.host_meta_path.write_text(json.dumps(meta))
        return self.host_meta_path

    def fake_gh_state(self, *, authed: bool = True, token: str = HOST_TOKEN,
                      account: str = "fake-user") -> Path:
        path = self.env.root / "fake-gh-state.json"
        path.write_text(json.dumps({"authed": authed, "token": token, "account": account}))
        return path

    def host_tool_env(self) -> dict[str, str]:
        env = self.env.env.copy()
        env.update({
            "MSW_GITHUB_MODE": "local",
            "MSW_HOST_KEYCHAIN_SERVICE": HOST_KEYCHAIN_SERVICE,
            "MSW_HOST_KEYCHAIN_ACCOUNT": HOST_KEYCHAIN_ACCOUNT,
            "MSW_TEST_KEYCHAIN_DIR": str(self.env.root / "keychain"),
            "MSW_HOST_META_FILE": str(self.host_meta_path),
            "MSW_JQ_BIN": "/usr/bin/jq",
            "MSW_HOST_TOKEN_BIN": str(PACKAGE / "bin" / "msw-github-host-token"),
        })
        return env

    def prepare_guest_repo(self, *, box: str = "dev", path: str = "repo") -> Path:
        self.env.init_remote()
        self.env.msw("clone", box, "acme/demo", path)
        repo = self.env.guest_repo(box, path)
        self.env.git(repo, "config", "user.name", "Test")
        self.env.git(repo, "config", "user.email", "test@example.invalid")
        (self.env.workspace(box) / path / "one.txt").write_text("one\n")
        self.env.git(repo, "add", "one.txt")
        self.env.git(repo, "commit", "-m", "one")
        return repo


class GitHubProxyTests(_LocalModeGitHubBase):
    """Path C CLI-driven local-mode tests: host credential lifecycle, verify,
    remove, policy get/set, push gates (§8), askpass and host-token helpers."""

    # ---- host credential helpers (bin/msw-github-host-token) ------------

    def test_host_token_helper_fail_closed_matrix(self) -> None:
        helper = PACKAGE / "bin" / "msw-github-host-token"
        env = self.host_tool_env()
        # missing record -> empty stdout, exit 1
        proc = run_cmd([helper], env=env, check=False)
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(proc.stdout, "")
        # ghs_ installation token -> rejected (wrong kind)
        self.seed_host_credential(self.host_record(token="ghs_install_abcdefghijklmnopqrstuvwxyz0123456789"))
        proc = run_cmd([helper], env=env, check=False)
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(proc.stdout, "")
        # ghr_ refresh token -> rejected
        self.seed_host_credential(self.host_record(token="ghr_refresh_abcdefghijklmnopqrstuvwxyz0123456789"))
        proc = run_cmd([helper], env=env, check=False)
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(proc.stdout, "")
        # malformed JSON -> rejected
        self.host_key_path.write_text("{not json")
        proc = run_cmd([helper], env=env, check=False)
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(proc.stdout, "")
        # wrong schemaVersion / missing fields -> rejected
        self.seed_host_credential({"schemaVersion": 2, "accessToken": HOST_TOKEN})
        proc = run_cmd([helper], env=env, check=False)
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(proc.stdout, "")

        # blocker 4 activation gate: a valid record WITHOUT matching active
        # metadata denies (no token).
        self.seed_host_credential()
        self.host_meta_path.unlink(missing_ok=True)
        proc = run_cmd([helper], env=env, check=False)
        self.assertEqual(proc.returncode, 1, "record without metadata must deny")
        self.assertEqual(proc.stdout, "")
        # revoked tombstone -> global deny
        self.seed_host_meta(state="revoked")
        proc = run_cmd([helper], env=env, check=False)
        self.assertEqual(proc.returncode, 1, "revoked tombstone must deny")
        self.assertEqual(proc.stdout, "")
        # revocation-uncertain tombstone -> global deny
        self.seed_host_meta(state="revocation-uncertain")
        proc = run_cmd([helper], env=env, check=False)
        self.assertEqual(proc.returncode, 1, "revocation-uncertain tombstone must deny")
        self.assertEqual(proc.stdout, "")
        # generation mismatch -> deny
        self.seed_host_meta(generation=99)
        proc = run_cmd([helper], env=env, check=False)
        self.assertEqual(proc.returncode, 1, "generation mismatch must deny")
        self.assertEqual(proc.stdout, "")
        # accountLogin mismatch -> deny
        self.seed_host_meta(login="someone-else")
        proc = run_cmd([helper], env=env, check=False)
        self.assertEqual(proc.returncode, 1, "accountLogin mismatch must deny")
        self.assertEqual(proc.stdout, "")
        # malformed metadata JSON -> deny
        self.host_meta_path.write_text("{not json")
        proc = run_cmd([helper], env=env, check=False)
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(proc.stdout, "")

        # global deny marker (re-review) denies FIRST, even with a valid
        # record + active metadata
        marker = self.env.root / "credential-disabled"
        marker.write_text("revoked\n")
        marker_env = dict(env)
        marker_env["MSW_CREDENTIAL_DENY_MARKER"] = str(marker)
        proc = run_cmd([helper], env=marker_env, check=False)
        self.assertEqual(proc.returncode, 1, "global deny marker must deny first")
        self.assertEqual(proc.stdout, "")
        marker.unlink()

        # valid record + matching active metadata -> token only, exit 0
        self.seed_host_credential()
        self.seed_host_meta()
        proc = run_cmd([helper], env=env, check=False)
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, HOST_TOKEN + "\n")
        # the helper needs NO jq (stdlib parse; jq absent from PATH)
        no_jq_env = {k: v for k, v in env.items() if k != "MSW_JQ_BIN"}
        no_jq_env["PATH"] = "/usr/bin:/bin"
        proc = run_cmd([helper], env=no_jq_env, check=False)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, HOST_TOKEN + "\n")

    def test_host_token_helper_watchdog_bounds_worker_hang(self) -> None:
        """Closure re-review: an injected bridge worker hang THROUGH the
        host-token helper completes within the outer bound, leaves no
        descendant process, and preserves the v2 record/metadata."""
        self.seed_host_credential()
        self.seed_host_meta()
        record_before = self.host_key_path.read_text()
        meta_before = self.host_meta_path.read_text()
        env = self.host_tool_env()
        env["MSW_TEST_KEYCHAIN_DIR"] = ""
        env["MSW_HOST_META_FILE"] = str(self.host_meta_path)
        env["MSW_FAKE_BRIDGE_HANG"] = "1"
        env["MSW_KEYCHAIN_TIMEOUT_SECS"] = "30"   # bridge watchdog longer
        env["MSW_HOST_TOKEN_TIMEOUT_SECS"] = "5"  # the helper OUTER bounds it
        start = time.monotonic()
        proc = run_cmd([PACKAGE / "bin" / "msw-github-host-token"], env=env, check=False, timeout=30)
        elapsed = time.monotonic() - start
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertEqual(proc.stdout, "")  # fail-closed: no token
        self.assertLess(elapsed, 15, "host-token outer timeout must bound the hang")
        # the v2 record/metadata are untouched (nothing was mutated)
        self.assertEqual(self.host_key_path.read_text(), record_before)
        self.assertEqual(self.host_meta_path.read_text(), meta_before)
        # no descendant bridge/worker processes remain
        time.sleep(0.3)
        leftover = subprocess.run(["pgrep", "-f", "msw-keychain-bridge"],
                                  stdout=subprocess.PIPE, text=True)
        self.assertNotEqual(leftover.returncode, 0, "bridge descendants must be killed")

    def test_askpass_watchdog_bounds_worker_hang(self) -> None:
        """Closure re-review: askpass (which uses the host-token helper) is
        equally bounded when the bridge worker hangs; it emits nothing and
        leaves no descendant process."""
        self.seed_host_credential()
        self.seed_host_meta()
        env = self.host_tool_env()
        env["MSW_TEST_KEYCHAIN_DIR"] = ""
        env["MSW_FAKE_BRIDGE_HANG"] = "1"
        env["MSW_KEYCHAIN_TIMEOUT_SECS"] = "2"
        env["MSW_HOST_TOKEN_TIMEOUT_SECS"] = "5"
        start = time.monotonic()
        proc = run_cmd([PACKAGE / "bin" / "msw-git-askpass", "Password for 'https://user@github.com': "],
                       env=env, check=False, timeout=30)
        elapsed = time.monotonic() - start
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertEqual(proc.stdout, "")
        self.assertLess(elapsed, 15, "askpass must be bounded via the helper")
        time.sleep(0.3)
        leftover = subprocess.run(["pgrep", "-f", "msw-keychain-bridge"],
                                  stdout=subprocess.PIPE, text=True)
        self.assertNotEqual(leftover.returncode, 0, "bridge descendants must be killed")

    def test_askpass_local_emits_token_only_for_github(self) -> None:
        askpass = PACKAGE / "bin" / "msw-git-askpass"
        env = self.host_tool_env()
        self.seed_host_credential()
        self.seed_host_meta()
        # github.com password prompt -> token
        proc = run_cmd([askpass, "Password for 'https://user@github.com': "], env=env, check=False)
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, HOST_TOKEN + "\n")
        # github.com username prompt -> x-access-token
        proc = run_cmd([askpass, "Username for 'https://github.com': "], env=env, check=False)
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, "x-access-token\n")
        # non-github host -> fail closed (nothing emitted)
        for prompt in ("Password for 'https://evil.example': ", "Username for 'https://gitlab.com': "):
            proc = run_cmd([askpass, prompt], env=env, check=False)
            self.assertEqual(proc.returncode, 1, prompt)
            self.assertEqual(proc.stdout, "", prompt)
        # missing record -> fail closed
        self.host_key_path.unlink()
        proc = run_cmd([askpass, "Password for 'https://user@github.com': "], env=env, check=False)
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(proc.stdout, "")

    # ---- acquisition / rotation / revocation ----------------------------

    def test_auth_acquires_via_gh_verifies_repos_and_writes_single_record(self) -> None:
        self.env.init_remote()
        self.empty_policy()
        self.set_policy({"schemaVersion": 1, "workspaces": {
            "dev": {"capability": DEV_CAP, "repos": [{"canonical": "acme/demo", "mode": "read-write"}]},
            "playgrounds": {"capability": PLAY_CAP, "repos": []},
            "personal": {"capability": PERSONAL_CAP, "repos": []},
        }})
        with self.env.start_fake_github() as fake:
            env = self.env.env.copy()
            env.update({
                "MSW_GH_BIN": str(FAKE_GH),
                "MSW_FAKE_GH_STATE": str(self.fake_gh_state()),
                "MSW_CURL_BIN": str(FAKE_API_CURL),
                "MSW_PROXY_UPSTREAM_ROOT": fake.base_url,
            })
            proc = self.env.msw("github", "auth", "--json", extra_env=env)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            result = json.loads(proc.stdout)
            self.assertEqual(result["provider"], "gh-cli")
            self.assertEqual(result["tokenKind"], "oauth")
            self.assertEqual(result["accountLogin"], "fake-user")
            self.assertEqual(result["generation"], 1)
            self.assertNotIn("accessToken", result)
            checks = {c["canonical"]: c for c in result["repoChecks"]}
            self.assertEqual(checks["acme/demo"]["mode"], "read-write")
            self.assertTrue(checks["acme/demo"]["push"])
            # one single-record keychain file with the token
            record = json.loads(self.host_key_path.read_text())
            self.assertEqual(record["schemaVersion"], 1)
            self.assertEqual(record["accessToken"], HOST_TOKEN)
            self.assertEqual(record["generation"], 1)
            # nonsecret metadata beside the policy file, no token bytes
            meta = json.loads(self.host_meta_path.read_text())
            self.assertEqual(meta["accountLogin"], "fake-user")
            self.assertNotIn("accessToken", meta)
            self.assertNotIn(HOST_TOKEN, self.host_meta_path.read_text())
            # the fake github saw authenticated /user + /repos calls
            records = fake.requests()
            user = [r for r in records if r["path"] == "/user"]
            self.assertTrue(user, records)
            self.assertTrue(user[0]["authorization_present"])
            repo = [r for r in records if r["path"] == "/repos/acme/demo"]
            self.assertTrue(repo, records)
            self.assertTrue(repo[0]["authorization_present"])

    def test_auth_rotates_generation_and_keeps_single_record(self) -> None:
        self.empty_policy()
        self.seed_host_credential(self.host_record(generation=1))
        with self.env.start_fake_github() as fake:
            env = self.env.env.copy()
            env.update({
                "MSW_GH_BIN": str(FAKE_GH),
                "MSW_FAKE_GH_STATE": str(self.fake_gh_state()),
                "MSW_CURL_BIN": str(FAKE_API_CURL),
                "MSW_PROXY_UPSTREAM_ROOT": fake.base_url,
            })
            proc = self.env.msw("github", "auth", "--force", "--json", extra_env=env)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            result = json.loads(proc.stdout)
            self.assertEqual(result["generation"], 2)
            record = json.loads(self.host_key_path.read_text())
            self.assertEqual(record["generation"], 2)
            self.assertEqual(record["accessToken"], HOST_TOKEN)

    def test_auth_idempotent_without_force(self) -> None:
        self.seed_host_credential(self.host_record(generation=7))
        self.seed_host_meta(generation=7)
        before = self.host_key_path.read_text()
        proc = self.env.msw("github", "auth", "--json")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        result = json.loads(proc.stdout)
        self.assertEqual(result["generation"], 7)
        self.assertEqual(self.host_key_path.read_text(), before)

    def test_auth_not_configured_fails_closed_without_persisting(self) -> None:
        env = self.env.env.copy()
        env["MSW_GH_BIN"] = "/nonexistent/gh"
        proc = self.env.msw("github", "auth", check=False, extra_env=env)
        self.assertFailed(proc, "MSW_HOST_OAUTH_CLIENT_ID")
        self.assertFalse(self.host_key_path.exists())
        self.assertFalse(self.host_meta_path.exists())

    def test_auth_verification_failure_persists_nothing(self) -> None:
        self.env.init_remote()
        self.empty_policy()
        self.set_policy({"schemaVersion": 1, "workspaces": {
            "dev": {"capability": DEV_CAP, "repos": [{"canonical": "acme/demo", "mode": "read-write"}]},
            "playgrounds": {"capability": PLAY_CAP, "repos": []},
            "personal": {"capability": PERSONAL_CAP, "repos": []},
        }})
        with self.env.start_fake_github() as fake:
            (fake.state_dir / "repos.json").write_text(json.dumps(
                {"acme/demo": {"permissions": {"push": False}}}))
            env = self.env.env.copy()
            env.update({
                "MSW_GH_BIN": str(FAKE_GH),
                "MSW_FAKE_GH_STATE": str(self.fake_gh_state()),
                "MSW_CURL_BIN": str(FAKE_API_CURL),
                "MSW_PROXY_UPSTREAM_ROOT": fake.base_url,
            })
            proc = self.env.msw("github", "auth", check=False, extra_env=env)
            self.assertFailed(proc, "verification failed")
            self.assertFalse(self.host_key_path.exists())
            self.assertFalse(self.host_meta_path.exists())

    def test_remove_local_revokes_metadata_first_and_keeps_legacy_items(self) -> None:
        self.seed_host_credential()
        self.seed_host_meta()
        legacy = self.env.key_file("msw.github.read", "dev")
        legacy.write_text("github_pat_LEGACY_abcdefghijklmnopqrstuvwxyz0123456789")
        proc = self.env.msw("github", "remove", "dev")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertFalse(self.host_meta_path.exists())
        self.assertFalse(self.host_key_path.exists())
        self.assertTrue(legacy.exists())  # §1: legacy items never deleted
        # idempotent
        proc = self.env.msw("github", "remove", "dev")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_remove_local_unproven_metadata_deletion_quarantines(self) -> None:
        self.seed_host_credential()
        self.seed_host_meta()
        # Inject a metadata-write failure so the revocation metadata tombstone
        # cannot be recorded. The global deny marker + proven Keychain
        # deletion still make the credential unusable; the unrecorded
        # tombstone is surfaced as a failure with a quarantine, and every
        # helper keeps denying.
        env = self.env.env.copy()
        env["MSW_FAKE_HOST_META_WRITE_FAIL"] = "1"
        proc = self.env.msw("github", "remove", "dev", check=False, extra_env=env)
        self.assertFailed(proc, "removal failed")
        quarantine = self.github_meta_dir / "dev.quarantine"
        self.assertTrue(quarantine.exists())
        self.assertIn("Host GitHub credential removal failed", quarantine.read_text())
        # the KEYCHAIN RECORD is proven deleted (the token cannot be emitted)
        self.assertFalse(self.host_key_path.exists())
        # the global deny marker remains (helpers deny even with stale state)
        self.assertTrue((self.env.home / ".config/msw/credential-disabled").exists())

    # ---- verify (local probe) -------------------------------------------

    def test_verify_local_probes_user_and_read_write_repo(self) -> None:
        self.env.init_remote()
        self.empty_policy()
        self.set_policy({"schemaVersion": 1, "workspaces": {
            "dev": {"capability": DEV_CAP, "repos": [{"canonical": "acme/demo", "mode": "read-write"}]},
            "playgrounds": {"capability": PLAY_CAP, "repos": []},
            "personal": {"capability": PERSONAL_CAP, "repos": []},
        }})
        self.seed_host_credential()
        self.seed_host_meta()
        with self.env.start_fake_github() as fake:
            env = self.env.env.copy()
            env.update({
                "MSW_CURL_BIN": str(FAKE_API_CURL),
                "MSW_PROXY_UPSTREAM_ROOT": fake.base_url,
            })
            proc = self.env.msw("github", "verify", "dev", "acme/demo", extra_env=env)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertIn("Account:          fake-user", proc.stdout)
            self.assertIn("push=true", proc.stdout)
            self.assertIn("GitHub access verified for dev (local)", proc.stdout)
            records = fake.requests()
            self.assertTrue(any(r["path"] == "/user" for r in records), records)
            self.assertTrue(any(r["path"] == "/repos/acme/demo" for r in records), records)

    def test_verify_local_fails_when_credential_missing(self) -> None:
        self.empty_policy()
        self.set_policy({"schemaVersion": 1, "workspaces": {
            "dev": {"capability": DEV_CAP, "repos": [{"canonical": "acme/demo", "mode": "read-only"}]},
            "playgrounds": {"capability": PLAY_CAP, "repos": []},
            "personal": {"capability": PERSONAL_CAP, "repos": []},
        }})
        proc = self.env.msw("github", "verify", "dev", check=False)
        self.assertFailed(proc, "host GitHub credential is missing")
        self.assertIn("msw github auth", proc.stdout + proc.stderr)

    def test_verify_local_fails_on_push_probe_rejection(self) -> None:
        self.empty_policy()
        self.set_policy({"schemaVersion": 1, "workspaces": {
            "dev": {"capability": DEV_CAP, "repos": [{"canonical": "acme/demo", "mode": "read-write"}]},
            "playgrounds": {"capability": PLAY_CAP, "repos": []},
            "personal": {"capability": PERSONAL_CAP, "repos": []},
        }})
        self.seed_host_credential()
        self.seed_host_meta()
        with self.env.start_fake_github() as fake:
            (fake.state_dir / "repos.json").write_text(json.dumps(
                {"acme/demo": {"permissions": {"push": False}}}))
            env = self.env.env.copy()
            env.update({
                "MSW_CURL_BIN": str(FAKE_API_CURL),
                "MSW_PROXY_UPSTREAM_ROOT": fake.base_url,
            })
            proc = self.env.msw("github", "verify", "dev", "acme/demo", check=False, extra_env=env)
            self.assertFailed(proc, "verification failed")
            self.assertIn("auth --force", proc.stdout + proc.stderr)

    # ---- status ---------------------------------------------------------

    def test_status_json_includes_host_credential_and_repos_array(self) -> None:
        self.empty_policy()
        self.set_policy({"schemaVersion": 1, "workspaces": {
            "dev": {"capability": DEV_CAP, "repos": [{"canonical": "acme/demo", "mode": "read-only"}]},
            "playgrounds": {"capability": PLAY_CAP, "repos": []},
            "personal": {"capability": PERSONAL_CAP, "repos": []},
        }})
        proc = self.env.msw("github", "status", "--format", "json")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        result = json.loads(proc.stdout)
        self.assertEqual(result["mode"], "local")
        dev = next(w for w in result["workspaces"] if w["workspace"] == "dev")
        self.assertEqual(dev["capability"], "minted")
        self.assertEqual(dev["repos"], [{"canonical": "acme/demo", "mode": "read-only"}])
        self.assertEqual(dev["hostCredential"], "missing")
        # missing policy still yields a repos array
        (self.policy_path).unlink()
        proc = self.env.msw("github", "status", "--format", "json")
        result = json.loads(proc.stdout)
        dev = next(w for w in result["workspaces"] if w["workspace"] == "dev")
        self.assertEqual(dev["capability"], "missing")
        self.assertEqual(dev["repos"], [])
        self.assertEqual(dev["hostCredential"], "missing")

    # ---- app github-policy-get/set (journaled) --------------------------

    def test_app_policy_set_get_roundtrip_capability_preserved_and_journal(self) -> None:
        proc = self.env.msw("app", "github-policy-set", "--workspace", "dev",
                            "--repository", "Acme/Demo.git", "--mode", "read-write",
                            "--format", "json")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        result = json.loads(proc.stdout)
        self.assertTrue(result["ok"])
        self.assertEqual(result["command"], "github-policy-set")
        data = result["result"]
        self.assertEqual(data["action"], "set")
        self.assertEqual(data["repository"], "acme/demo")
        self.assertEqual(data["mode"], "read-write")
        self.assertRegex(data["capability"], r"^[0-9a-f]{48}$")
        self.assertEqual(data["repos"], [{"canonical": "acme/demo", "mode": "read-write"}])
        capability = data["capability"]

        # get round-trip
        proc = self.env.msw("app", "github-policy-get", "--workspace", "dev", "--format", "json")
        result = json.loads(proc.stdout)
        self.assertTrue(result["ok"])
        dev = next(w for w in result["result"]["workspaces"] if w["workspace"] == "dev")
        self.assertEqual(dev["capability"], capability)
        self.assertEqual(dev["repos"], [{"canonical": "acme/demo", "mode": "read-write"}])

        # mode update preserves capability
        proc = self.env.msw("app", "github-policy-set", "--workspace", "dev",
                            "--repository", "acme/demo", "--mode", "read-only", "--format", "json")
        data = json.loads(proc.stdout)["result"]
        self.assertEqual(data["mode"], "read-only")
        self.assertEqual(data["capability"], capability)

        # remove
        proc = self.env.msw("app", "github-policy-set", "--workspace", "dev",
                            "--repository", "acme/demo", "--remove", "--format", "json")
        data = json.loads(proc.stdout)["result"]
        self.assertEqual(data["repos"], [])
        self.assertEqual(data["capability"], capability)

        # set again, then clear
        self.env.msw("app", "github-policy-set", "--workspace", "dev",
                     "--repository", "acme/demo", "--mode", "read-write", "--format", "json")
        proc = self.env.msw("app", "github-policy-set", "--workspace", "dev", "--clear", "--format", "json")
        data = json.loads(proc.stdout)["result"]
        self.assertEqual(data["action"], "clear")
        self.assertEqual(data["repos"], [])
        self.assertEqual(data["capability"], capability)

        # journal recorded started + committed
        journal = (self.github_meta_dir / "policy-journal.jsonl").read_text()
        self.assertIn('"status":"started"', journal)
        self.assertIn('"status":"committed"', journal)
        self.assertIn('"action":"clear"', journal)

    def test_app_policy_errors_are_typed(self) -> None:
        # missing policy -> MSW_POLICY_MISSING
        proc = self.env.msw("app", "github-policy-get", "--format", "json", check=False)
        self.assertEqual(proc.returncode, 78)
        err = json.loads(proc.stdout)["error"]
        self.assertEqual(err["code"], "MSW_POLICY_MISSING")
        # invalid mode -> MSW_INVALID_REQUEST
        proc = self.env.msw("app", "github-policy-set", "--workspace", "dev",
                            "--repository", "acme/demo", "--mode", "bogus", "--format", "json",
                            check=False)
        self.assertEqual(proc.returncode, 64)
        self.assertEqual(json.loads(proc.stdout)["error"]["code"], "MSW_INVALID_REQUEST")
        # invalid repository -> MSW_INVALID_REQUEST
        proc = self.env.msw("app", "github-policy-set", "--workspace", "dev",
                            "--repository", "not-a-repo", "--mode", "read-only", "--format", "json",
                            check=False)
        self.assertEqual(proc.returncode, 64)
        self.assertEqual(json.loads(proc.stdout)["error"]["code"], "MSW_INVALID_REQUEST")
        # connect mode -> MSW_GITHUB_MODE_MISMATCH
        proc = self.env.msw("app", "github-policy-set", "--workspace", "dev",
                            "--repository", "acme/demo", "--mode", "read-only", "--format", "json",
                            check=False, extra_env={"MSW_GITHUB_MODE": "connect"})
        self.assertEqual(proc.returncode, 69)
        self.assertEqual(json.loads(proc.stdout)["error"]["code"], "MSW_GITHUB_MODE_MISMATCH")

    def test_app_policy_set_refuses_when_lock_held(self) -> None:
        lock = self.github_meta_dir / "dev.lock"
        lock.parent.mkdir(parents=True, exist_ok=True)
        holder = subprocess.Popen(
            ["bash", "-c", f'exec 9>>"{lock}"; /usr/bin/lockf -s -t 0 9 && echo READY; sleep 30'],
            stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(holder.stdout.readline().strip(), "READY")
            proc = self.env.msw("app", "github-policy-set", "--workspace", "dev",
                                "--repository", "acme/demo", "--mode", "read-write",
                                "--format", "json", check=False)
            self.assertEqual(proc.returncode, 73)
            err = json.loads(proc.stdout)["error"]
            self.assertEqual(err["code"], "MSW_OPERATION_CONFLICT")
            self.assertTrue(err["retryable"])
        finally:
            holder.kill()
            holder.wait()

    # ---- push gates (§8 corrected rule) ---------------------------------

    def test_push_local_ticked_read_only_repo_with_credential_succeeds(self) -> None:
        # §8: host push is allowed for EVERY ticked repo in BOTH modes; only
        # VM-originated push is gated by read-write (enforced by the proxy).
        self.empty_policy()
        self.set_policy({"schemaVersion": 1, "workspaces": {
            "dev": {"capability": DEV_CAP, "repos": [{"canonical": "acme/demo", "mode": "read-only"}]},
            "playgrounds": {"capability": PLAY_CAP, "repos": []},
            "personal": {"capability": PERSONAL_CAP, "repos": []},
        }})
        self.seed_host_credential()
        self.seed_host_meta()
        self.prepare_guest_repo()
        proc = self.env.msw("push", "dev", "repo", "--yes")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("pushed main from dev:repo", proc.stdout)

    def test_push_local_unticked_repo_blocked(self) -> None:
        self.empty_policy()
        self.seed_host_credential()
        self.prepare_guest_repo()
        proc = self.env.msw("push", "dev", "repo", "--yes", check=False)
        self.assertFailed(proc, "has no credential grant on workspace 'dev'")
        self.assertIn("github-policy-set", proc.stdout + proc.stderr)

    def test_push_local_missing_host_credential_blocked(self) -> None:
        self.empty_policy()
        self.set_policy({"schemaVersion": 1, "workspaces": {
            "dev": {"capability": DEV_CAP, "repos": [{"canonical": "acme/demo", "mode": "read-write"}]},
            "playgrounds": {"capability": PLAY_CAP, "repos": []},
            "personal": {"capability": PERSONAL_CAP, "repos": []},
        }})
        self.prepare_guest_repo()
        proc = self.env.msw("push", "dev", "repo", "--yes", check=False)
        self.assertFailed(proc, "host GitHub credential is not provisioned")
        self.assertIn("msw github auth", proc.stdout + proc.stderr)

    def test_auth_gh_reuse_is_fully_noninteractive_non_tty(self) -> None:
        self.env.init_remote()
        self.empty_policy()
        with self.env.start_fake_github() as fake:
            env = self.env.env.copy()
            env.update({
                "MSW_GH_BIN": str(FAKE_GH),
                "MSW_FAKE_GH_STATE": str(self.fake_gh_state()),
                "MSW_CURL_BIN": str(FAKE_API_CURL),
                "MSW_PROXY_UPSTREAM_ROOT": fake.base_url,
            })
            # stdin is a pipe (not a TTY); the gh-reuse path must still work
            proc = self.env.msw("github", "auth", "--json", input_text="", extra_env=env)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertEqual(json.loads(proc.stdout)["provider"], "gh-cli")

    def test_auth_gh_reuses_token_when_gh_status_times_out(self) -> None:
        """§8 UX: `gh auth status --active` makes a networked round-trip and
        can time out while the local keyring token is readable. Acquisition
        must NOT gate on it — the token is read from the local keyring and
        verified via our own /user probe."""
        self.env.init_remote()
        self.empty_policy()
        with self.env.start_fake_github() as fake:
            state_path = self.fake_gh_state()
            state = json.loads(state_path.read_text())
            state["status_timeout"] = True  # status fails; token still works
            state_path.write_text(json.dumps(state))
            env = self.env.env.copy()
            env.update({
                "MSW_GH_BIN": str(FAKE_GH),
                "MSW_FAKE_GH_STATE": str(state_path),
                "MSW_CURL_BIN": str(FAKE_API_CURL),
                "MSW_PROXY_UPSTREAM_ROOT": fake.base_url,
            })
            proc = self.env.msw("github", "auth", "--json", extra_env=env)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            result = json.loads(proc.stdout)
            self.assertEqual(result["provider"], "gh-cli")
            self.assertEqual(result["accountLogin"], "fake-user")
            self.assertEqual(result["generation"], 1)
            # the token was reused and verified against /user
            record = json.loads(self.host_key_path.read_text())
            self.assertEqual(record["accessToken"], HOST_TOKEN)
            records = fake.requests()
            self.assertTrue(any(r["path"] == "/user" and r["authorization_present"] for r in records), records)

    def test_auth_gh_no_token_routes_to_remedy(self) -> None:
        """gh present but with no local token: acquisition reports the
        not-configured remedy (gh auth login / device flow), never a
        network claim, and persists nothing."""
        env = self.env.env.copy()
        env.update({
            "MSW_GH_BIN": str(FAKE_GH),
            "MSW_FAKE_GH_STATE": str(self.fake_gh_state(authed=False, token="")),
        })
        proc = self.env.msw("github", "auth", "--json", check=False, extra_env=env)
        self.assertEqual(proc.returncode, 66)
        error = json.loads(proc.stdout)["error"]
        self.assertEqual(error["code"], "MSW_HOST_OAUTH_NOT_CONFIGURED")
        joined = " ".join(error["remedies"])
        self.assertIn("gh auth login", joined)
        self.assertIn("MSW_HOST_OAUTH_CLIENT_ID", joined)
        self.assertFalse(self.host_key_path.exists())
        self.assertFalse(self.host_meta_path.exists())

    def test_auth_user_verification_timeout_typed_and_persists_nothing(self) -> None:
        """§8 UX: when gh has a token but our /user verification times out,
        the failure is the typed verification/network error — never 'gh not
        authenticated' — and nothing is persisted."""
        self.env.init_remote()
        self.empty_policy()
        # fake curl that stalls and exits 28 (curl timeout) after touching the
        # network path — proving the timeout, not a local token problem.
        curl_bin = self.env.root / "timeout-curl"
        curl_bin.write_text(
            "#!/bin/sh\n"
            "echo 'fake curl timed out' >&2\n"
            "exit 28\n"
        )
        curl_bin.chmod(0o755)
        env = self.env.env.copy()
        env.update({
            "MSW_GH_BIN": str(FAKE_GH),
            "MSW_FAKE_GH_STATE": str(self.fake_gh_state()),
            "MSW_CURL_BIN": str(curl_bin),
        })
        proc = self.env.msw("github", "auth", "--json", check=False, extra_env=env)
        self.assertEqual(proc.returncode, 68, proc.stdout + proc.stderr)
        error = json.loads(proc.stdout)["error"]
        self.assertEqual(error["code"], "MSW_HOST_CREDENTIAL_VERIFICATION_FAILED")
        joined = " ".join(error["remedies"])
        self.assertIn("verification failed", error["message"])
        self.assertNotIn("not authenticated", error["message"])
        self.assertIn("auth --force", joined)
        # nothing was persisted on the unproven verification
        self.assertFalse(self.host_key_path.exists())
        self.assertFalse(self.host_meta_path.exists())

    def test_auth_not_configured_json_error_names_both_remedies(self) -> None:
        env = self.env.env.copy()
        env["MSW_GH_BIN"] = "/nonexistent/gh"
        proc = self.env.msw("github", "auth", "--json", check=False, extra_env=env)
        self.assertEqual(proc.returncode, 66)
        error = json.loads(proc.stdout)["error"]
        self.assertEqual(error["code"], "MSW_HOST_OAUTH_NOT_CONFIGURED")
        joined = " ".join(error["remedies"])
        self.assertIn("gh auth login", joined)
        self.assertIn("MSW_HOST_OAUTH_CLIENT_ID", joined)
        self.assertFalse(self.host_key_path.exists())

    def test_auth_device_start_and_complete(self) -> None:
        self.empty_policy()
        with self.env.start_fake_github() as fake:
            env = self.env.env.copy()
            env.update({
                "MSW_HOST_OAUTH_CLIENT_ID": "test-client-id",
                "MSW_CURL_BIN": str(FAKE_API_CURL),
                "MSW_PROXY_UPSTREAM_ROOT": fake.base_url,
            })
            # start: one POST /login/device/code, no polling, no token exchange
            proc = self.env.msw("github", "auth", "--device", "--format", "json", extra_env=env)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            start = json.loads(proc.stdout)
            self.assertTrue(start["ok"])
            self.assertEqual(start["deviceId"], "dev-1")
            self.assertEqual(start["code"], "ABCD-EFGH")
            self.assertEqual(start["verificationUri"], "https://github.com/login/device")
            self.assertEqual(start["interval"], 5)
            self.assertRegex(start["expiresAt"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
            records = fake.requests()
            self.assertEqual([r for r in records if r["path"] == "/login/device/code"],
                             [records[-1]], records)
            self.assertFalse([r for r in records if r["path"] == "/login/oauth/access_token"], records)

            # pending poll: one exchange attempt, exit 0, status pending
            proc = self.env.msw("github", "auth", "--device-complete", "dev-1", "--format", "json",
                                extra_env=env)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertEqual(json.loads(proc.stdout), {"ok": True, "status": "pending"})

            # flip the fixture to ready, then the poll authorizes and stores
            (fake.state_dir / "device.json").write_text(json.dumps({
                "device_code": "dev-1", "user_code": "ABCD-EFGH",
                "verification_uri": "https://github.com/login/device",
                "expires_in": 900, "interval": 5,
                "status": "ready", "access_token": HOST_TOKEN,
            }))
            proc = self.env.msw("github", "auth", "--device-complete", "dev-1", "--format", "json",
                                extra_env=env)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            result = json.loads(proc.stdout)
            self.assertEqual(result["ok"], True)
            self.assertEqual(result["status"], "authorized")
            self.assertEqual(result["metadata"]["provider"], "oauth-device-flow")
            self.assertEqual(result["metadata"]["generation"], 1)
            self.assertEqual(result["metadata"]["accountLogin"], "fake-user")
            record = json.loads(self.host_key_path.read_text())
            self.assertEqual(record["provider"], "oauth-device-flow")
            self.assertEqual(record["accessToken"], HOST_TOKEN)
            self.assertTrue(self.host_meta_path.exists())
            # the token exchange hit the fixture; verification hit /user + /repos
            records = fake.requests()
            self.assertTrue([r for r in records if r["path"] == "/login/oauth/access_token"], records)
            self.assertTrue([r for r in records if r["path"] == "/user"], records)

    def test_auth_device_start_requires_client_id(self) -> None:
        env = self.env.env.copy()
        env["MSW_GH_BIN"] = "/nonexistent/gh"
        proc = self.env.msw("github", "auth", "--device", "--format", "json", check=False,
                            extra_env=env)
        self.assertEqual(proc.returncode, 66)
        error = json.loads(proc.stdout)["error"]
        self.assertEqual(error["code"], "MSW_HOST_OAUTH_NOT_CONFIGURED")
        # device-complete without a client id is equally typed
        proc = self.env.msw("github", "auth", "--device-complete", "dev-1", "--format", "json",
                            check=False, extra_env=env)
        self.assertEqual(proc.returncode, 66)
        self.assertEqual(json.loads(proc.stdout)["error"]["code"], "MSW_HOST_OAUTH_NOT_CONFIGURED")

    def test_repos_discovery_paginated_orgs_and_inpolicy(self) -> None:
        self.empty_policy()
        self.set_policy({"schemaVersion": 1, "workspaces": {
            "dev": {"capability": DEV_CAP, "repos": [{"canonical": "acme/demo", "mode": "read-write"}]},
            "playgrounds": {"capability": PLAY_CAP, "repos": []},
            "personal": {"capability": PERSONAL_CAP, "repos": []},
        }})
        self.seed_host_credential()
        self.seed_host_meta()
        with self.env.start_fake_github() as fake:
            user_repos = [{
                "full_name": "acme/demo" if n == 0 else f"acme/repo-{n:03d}",
                "name": "demo" if n == 0 else f"repo-{n:03d}",
                "owner": {"login": "acme"},
                "private": n % 2 == 0,
                "permissions": {"pull": True, "push": n % 3 == 0},
            } for n in range(150)]  # 2 pages at per_page=100
            (fake.state_dir / "user-repos.json").write_text(json.dumps(user_repos))
            (fake.state_dir / "orgs.json").write_text(json.dumps([{"login": "myorg"}]))
            (fake.state_dir / "org-repos.json").write_text(json.dumps({
                "myorg": [{
                    "full_name": "myorg/toolkit",
                    "name": "toolkit",
                    "owner": {"login": "myorg"},
                    "private": True,
                    "permissions": {"pull": True, "push": True},
                }],
            }))
            env = self.env.env.copy()
            env.update({
                "MSW_CURL_BIN": str(FAKE_API_CURL),
                "MSW_PROXY_UPSTREAM_ROOT": fake.base_url,
            })
            proc = self.env.msw("github", "repos", "--format", "json", extra_env=env)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            result = json.loads(proc.stdout)
            self.assertTrue(result["ok"])
            repos = result["repos"]
            self.assertEqual(len(repos), 151, [r["canonical"] for r in repos])
            canonicals = [r["canonical"] for r in repos]
            self.assertEqual(canonicals, sorted(canonicals))
            self.assertEqual(len(set(canonicals)), len(canonicals))  # deduped
            demo = next(r for r in repos if r["canonical"] == "acme/demo")
            self.assertTrue(demo["inPolicy"])
            self.assertEqual(demo["permissions"], {"pull": True, "push": True})
            self.assertEqual(demo["owner"], "acme")
            toolkit = next(r for r in repos if r["canonical"] == "myorg/toolkit")
            self.assertFalse(toolkit["inPolicy"])
            self.assertTrue(toolkit["private"])
            self.assertTrue(toolkit["permissions"]["push"])
            # pagination: the fake saw both /user/repos pages and the org page
            records = fake.requests()
            user_pages = [r for r in records if r["path"] == "/user/repos"]
            self.assertEqual(len(user_pages), 2, records)
            self.assertEqual(user_pages[0]["query"], "per_page=100&visibility=all&affiliation=owner,collaborator,organization_member&page=1")
            self.assertEqual(user_pages[1]["query"].split("&")[-1], "page=2")
            self.assertTrue([r for r in records if r["path"] == "/orgs/myorg/repos"], records)
            # owner filter
            proc = self.env.msw("github", "repos", "--owner", "myorg", "--format", "json",
                                extra_env=env)
            filtered = json.loads(proc.stdout)["repos"]
            self.assertEqual([r["canonical"] for r in filtered], ["myorg/toolkit"])
            proc = self.env.msw("github", "repos", "--owner", "ACME", "--format", "json",
                                extra_env=env)
            self.assertEqual(len(json.loads(proc.stdout)["repos"]), 150)

    def test_repos_discovery_missing_credential_json_error(self) -> None:
        proc = self.env.msw("github", "repos", "--format", "json", check=False)
        self.assertEqual(proc.returncode, 1)
        error = json.loads(proc.stdout)["error"]
        self.assertEqual(error["code"], "MSW_HOST_CREDENTIAL_MISSING")

    # ---- blocker 1: secret hygiene (argv/stdin/tempfiles) ---------------

    def test_auth_token_never_in_argv_or_tempfiles(self) -> None:
        """Blocker 1 (bridge architecture): jq/curl never receive the token in
        argv; no Authorization tempfile is created; the Authorization header
        reaches curl via stdin (-H @-); the keychain record is written by the
        bridge with ONLY nonsecret argv (the record rides stdin)."""
        self.env.init_remote()
        self.empty_policy()
        self.set_policy({"schemaVersion": 1, "workspaces": {
            "dev": {"capability": DEV_CAP, "repos": [{"canonical": "acme/demo", "mode": "read-write"}]},
            "playgrounds": {"capability": PLAY_CAP, "repos": []},
            "personal": {"capability": PERSONAL_CAP, "repos": []},
        }})
        curl_argv_log = self.env.root / "curl-argv.log"
        tmpdir = self.env.root / "isolated-tmp"
        tmpdir.mkdir()
        with self.env.start_fake_github() as fake:
            env = self.env.env.copy()  # MSW_TEST_KEYCHAIN_DIR stays the file seam
            env.update({
                "MSW_GH_BIN": str(FAKE_GH),
                "MSW_FAKE_GH_STATE": str(self.fake_gh_state()),
                "MSW_CURL_BIN": str(FAKE_API_CURL),
                "MSW_PROXY_UPSTREAM_ROOT": fake.base_url,
                "MSW_FAKE_API_CURL_ARGV_LOG": str(curl_argv_log),
                "TMPDIR": str(tmpdir),
            })
            proc = self.env.msw("github", "auth", "--json", extra_env=env)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            result = json.loads(proc.stdout)
            self.assertEqual(result["provider"], "gh-cli")
            self.assertEqual(result["generation"], 1)
            # the versioned record landed in the Keychain (file seam) with the
            # token; the activation metadata carries NO token bytes
            record = json.loads(self.host_key_path.read_text())
            self.assertEqual(record["accessToken"], HOST_TOKEN)
            self.assertEqual(record["generation"], 1)
            meta = json.loads(self.host_meta_path.read_text())
            self.assertEqual(meta["state"], "active")
            self.assertNotIn("accessToken", meta)
            self.assertNotIn(HOST_TOKEN, self.host_meta_path.read_text())
            # no curl argv carries the token; the header went via stdin
            self.assertTrue(curl_argv_log.exists(), "curl argv log missing")
            self.assertNotIn(HOST_TOKEN, curl_argv_log.read_text())
            self.assertIn("@-", curl_argv_log.read_text())
            # no Authorization tempfile was created
            self.assertEqual(list(tmpdir.iterdir()), [], list(tmpdir.iterdir()))
            # the fake github saw the Bearer header (delivered via stdin)
            records = fake.requests()
            user = [r for r in records if r["path"] == "/user"]
            self.assertTrue(user and user[0]["authorization_present"], records)

        # Bridge hygiene (re-review): the record reaches the bridge ONLY
        # through stdin — `put SERVICE ACCOUNT` argv is nonsecret — proven on
        # a REAL keychain with an ephemeral service and a >128-byte record.
        if sys.platform == "darwin":
            bridge = PACKAGE / "bin/msw-keychain-bridge"
            argv_log = self.env.root / "bridge-argv.log"
            wrapper = self.env.root / "bridge-wrapper"
            wrapper.write_text(
                "#!/bin/sh\n"
                f"printf '%s\\n' \"$*\" >>\"{argv_log}\"\n"
                f"exec /usr/bin/python3 {bridge} \"$@\"\n"
            )
            wrapper.chmod(0o755)
            svc = f"org.msw.hygiene.arg.{os.getpid()}.{int(time.time() * 1000)}"
            record = json.dumps(self.host_record(token="gho_hyg_" + "b" * 40))
            home = {"HOME": os.environ["HOME"]}
            run_cmd([wrapper, "put", svc, "user"], env=home, input_text=record)
            try:
                self.assertTrue(argv_log.exists(), "bridge argv log missing")
                self.assertNotIn("gho_hyg", argv_log.read_text())
                got = run_cmd(["/usr/bin/python3", bridge, "get", svc, "user"], env=home)
                self.assertEqual(got.stdout, record)
            finally:
                run_cmd(["/usr/bin/python3", bridge, "delete", svc, "user"], env=home, check=False)

    @unittest.skipUnless(sys.platform == "darwin", "real macOS Keychain only")
    def test_keychain_bridge_real_keychain_roundtrip(self) -> None:
        """macOS-only, mandatory: the standalone keychain bridge stores a
        >128-byte JSON record (realistic token) on a REAL Keychain via stdin
        (put), a NEW helper process reads it back byte-for-byte (get), delete
        removes it, and get then fails — with a unique ephemeral service."""
        svc = f"org.msw.hygiene.test.{os.getpid()}.{int(time.time() * 1000)}"
        record = json.dumps({
            "schemaVersion": 1,
            "provider": "gh-cli",
            "tokenKind": "oauth",
            "accessToken": "gho_rt_" + "a" * 40,  # >128-byte total payload
            "accountLogin": "fake-user",
            "verifiedAt": "2026-01-01T00:00:00Z",
            "generation": 1,
            "storedAt": "2026-01-01T00:00:00Z",
        })
        self.assertGreater(len(record), 128, "record must exceed security's prompted-stdin limit")
        bridge = PACKAGE / "bin/msw-keychain-bridge"
        env = self.env.env.copy()
        env["HOME"] = os.environ["HOME"]  # real login keychain
        # The real login keychain may be locked or absent on headless/CI
        # machines; probe the exact bridge write path and skip when it is
        # unavailable so the suite does not depend on a manual unlock.
        probe_svc = f"{svc}.probe"
        probe = run_cmd(["/usr/bin/python3", bridge, "put", probe_svc, "user"],
                        env=env, input_text="x", check=False)
        run_cmd(["/usr/bin/python3", bridge, "delete", probe_svc, "user"], env=env, check=False)
        if probe.returncode != 0:
            self.skipTest(f"real login keychain unavailable (bridge rc={probe.returncode}); skipping real-keychain roundtrip")
        try:
            # put via stdin (a fresh process)
            put = run_cmd(["/usr/bin/python3", bridge, "put", svc, "user"],
                          env=env, input_text=record, check=False)
            self.assertEqual(put.returncode, 0, put.stdout + put.stderr)
            # get from a NEW helper process: byte-for-byte
            got = run_cmd(["/usr/bin/python3", bridge, "get", svc, "user"],
                          env=env, check=False)
            self.assertEqual(got.returncode, 0, got.stdout + got.stderr)
            self.assertEqual(got.stdout, record)
            # delete, then get must fail (item proven gone)
            dele = run_cmd(["/usr/bin/python3", bridge, "delete", svc, "user"],
                           env=env, check=False)
            self.assertEqual(dele.returncode, 0, dele.stdout + dele.stderr)
            gone = run_cmd(["/usr/bin/python3", bridge, "get", svc, "user"],
                           env=env, check=False)
            self.assertEqual(gone.returncode, 44, gone.stdout + gone.stderr)
            self.assertEqual(gone.stdout, "")
        finally:
            run_cmd(["/usr/bin/python3", bridge, "delete", svc, "user"], env=env, check=False)

    @unittest.skipUnless(sys.platform == "darwin", "real macOS Keychain only")
    def test_host_credential_write_real_keychain_roundtrip(self) -> None:
        """macOS-only: the exact host_credential_write/read path (bin/msw ->
        the keychain bridge) stores the versioned JSON record on a REAL
        Keychain and reads it back byte-for-byte; the ephemeral item is
        deleted in finally."""
        svc = f"org.msw.hygiene.path.{os.getpid()}.{int(time.time() * 1000)}"
        record = json.dumps(self.host_record(token="gho_rt_abcdefghijklmnopqrstuvwxyz0123456789"))
        meta_file = self.env.root / "rt-meta.json"
        meta_file.write_text(json.dumps({"schemaVersion": 1, "state": "active"}))
        env = self.env.env.copy()
        env["HOME"] = os.environ["HOME"]  # real login keychain
        env["MSW_CONFIG_FILE"] = str(self.env.home / ".config/msw/config.sh")
        # The real login keychain may be locked or absent on headless/CI
        # machines; probe the exact bridge write path and skip when it is
        # unavailable so the suite does not depend on a manual unlock.
        probe_svc = f"{svc}.probe"
        bridge = PACKAGE / "bin/msw-keychain-bridge"
        probe = run_cmd(["/usr/bin/python3", bridge, "put", probe_svc, "user"],
                        env=env, input_text="x", check=False)
        run_cmd(["/usr/bin/python3", bridge, "delete", probe_svc, "user"], env=env, check=False)
        if probe.returncode != 0:
            self.skipTest(f"real login keychain unavailable (bridge rc={probe.returncode}); skipping real-keychain roundtrip")
        script = (
            "set -euo pipefail\n"
            f'export MSW_SOURCE_ONLY=1\n'
            f'source "{PACKAGE / "bin/msw"}"\n'
            f'export MSW_HOST_KEYCHAIN_SERVICE="{svc}"\n'
            f'export MSW_HOST_KEYCHAIN_ACCOUNT="user"\n'
            f'export MSW_HOST_META_FILE="{meta_file}"\n'
            "unset MSW_TEST_KEYCHAIN_DIR\n"
            f"if ! host_credential_write '{record}'; then echo WRITE_FAILED >&2; exit 1; fi\n"
            "host_credential_read\n"
        )
        proc = run_cmd(["bash", "-c", script], env=env, check=False)
        try:
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertEqual(proc.stdout.strip(), record)
        finally:
            run_cmd(["/usr/bin/python3", bridge, "delete", svc, "user"], env=env, check=False)

    def test_keychain_bridge_hang_injection_times_out(self) -> None:
        """Re-review: a hidden keychain ACL prompt must never hang the CLI —
        the parent watchdog bounds the worker, kills it, and reports a typed
        timeout (no SIGALRM reliance)."""
        bridge = PACKAGE / "bin/msw-keychain-bridge"
        svc = f"org.msw.hang.{os.getpid()}.{int(time.time() * 1000)}"
        env = self.env.env.copy()
        env["HOME"] = os.environ["HOME"]
        env["MSW_FAKE_BRIDGE_HANG"] = "1"
        env["MSW_KEYCHAIN_TIMEOUT_SECS"] = "2"
        start = time.monotonic()
        proc = run_cmd(["/usr/bin/python3", bridge, "put", svc, "user"],
                       env=env, input_text="x", check=False, timeout=30)
        elapsed = time.monotonic() - start
        self.assertNotEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("timed out", proc.stderr)
        self.assertLess(elapsed, 12, "watchdog must bound the worker hang")

    @unittest.skipUnless(sys.platform == "darwin", "real macOS Keychain only")
    def test_keychain_bridge_put_timeout_preserves_existing_record(self) -> None:
        """Re-review: a put that times out (wedged worker) must NEVER
        overwrite the existing v2 credential — the old record stays
        byte-identical and a subsequent get still works."""
        bridge = PACKAGE / "bin/msw-keychain-bridge"
        svc = f"org.msw.preserve.{os.getpid()}.{int(time.time() * 1000)}"
        env = self.env.env.copy()
        env["HOME"] = os.environ["HOME"]
        record = json.dumps(self.host_record(token="gho_preserve_" + "c" * 30))
        try:
            put = run_cmd(["/usr/bin/python3", bridge, "put", svc, "user"],
                          env=env, input_text=record, check=False)
            self.assertEqual(put.returncode, 0, put.stdout + put.stderr)
            got1 = run_cmd(["/usr/bin/python3", bridge, "get", svc, "user"], env=env, check=False)
            self.assertEqual(got1.stdout, record)
            # wedged worker on the UPDATE path: bounded failure, record intact
            hang_env = dict(env)
            hang_env["MSW_FAKE_BRIDGE_HANG"] = "1"
            hang_env["MSW_KEYCHAIN_TIMEOUT_SECS"] = "2"
            start = time.monotonic()
            proc = run_cmd(["/usr/bin/python3", bridge, "put", svc, "user"],
                           env=hang_env, input_text="overwrite-me", check=False, timeout=30)
            self.assertNotEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertIn("timed out", proc.stderr)
            self.assertLess(time.monotonic() - start, 12)
            # the existing record is byte-identical; get still works
            got2 = run_cmd(["/usr/bin/python3", bridge, "get", svc, "user"], env=env, check=False)
            self.assertEqual(got2.returncode, 0, got2.stdout + got2.stderr)
            self.assertEqual(got2.stdout, record)
        finally:
            run_cmd(["/usr/bin/python3", bridge, "delete", svc, "user"], env=env, check=False)

    @unittest.skipUnless(sys.platform == "darwin", "real macOS Keychain only")
    def test_auth_store_v2_never_touches_legacy_security_created_item(self) -> None:
        """Real regression (re-review): a legacy keychain item created by
        security(1) (old security-CLI ACL) must NEVER be SecItemUpdate'd /
        CopyMatching'd by the bridge. The .v2 store path completes bounded,
        the v2 record round-trips, and the legacy item stays byte-identical."""
        old_svc = f"org.msw.legacy.{os.getpid()}.{int(time.time() * 1000)}"
        new_svc = f"{old_svc}.v2"
        env = self.env.env.copy()
        env["HOME"] = os.environ["HOME"]
        env["MSW_CONFIG_FILE"] = str(self.env.home / ".config/msw/config.sh")
        # legacy item created by security(1) with the security-CLI ACL
        run_cmd(["bash", "-c",
                 f'printf "x\\nx\\n" | /usr/bin/security add-generic-password -U -s "{old_svc}" -a user -w'],
                env=env, check=False)
        legacy = run_cmd(["/usr/bin/security", "find-generic-password", "-w", "-s", old_svc, "-a", "user"],
                         env=env, check=False)
        if legacy.returncode != 0:
            run_cmd(["/usr/bin/security", "delete-generic-password", "-s", old_svc, "-a", "user"],
                    env=env, check=False)
            self.skipTest("real login keychain unavailable; skipping legacy-ACL regression")
        meta_file = self.env.root / "legacy-meta.json"
        script = (
            "set -euo pipefail\n"
            f'export MSW_SOURCE_ONLY=1\n'
            f'source "{PACKAGE / "bin/msw"}"\n'
            f'export MSW_HOST_KEYCHAIN_SERVICE="{new_svc}"\n'
            f'export MSW_HOST_KEYCHAIN_ACCOUNT="user"\n'
            f'export MSW_HOST_META_FILE="{meta_file}"\n'
            f'export MSW_CREDENTIAL_DENY_MARKER="{self.env.root / "legacy-marker"}"\n'
            "unset MSW_TEST_KEYCHAIN_DIR\n"
            f"host_credential_store 'gh-cli' 'oauth' '{HOST_TOKEN}' 'fake-user' 1 '[]'\n"
        )
        try:
            proc = run_cmd(["bash", "-c", script], env=env, check=False, timeout=45)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            # the v2 record round-trips through the bridge
            bridge = PACKAGE / "bin/msw-keychain-bridge"
            got = run_cmd(["/usr/bin/python3", bridge, "get", new_svc, "user"], env=env, check=False)
            self.assertEqual(got.returncode, 0, got.stdout + got.stderr)
            self.assertEqual(json.loads(got.stdout)["accessToken"], HOST_TOKEN)
            # the legacy item is byte-identical (never read/updated by the bridge)
            legacy2 = run_cmd(["/usr/bin/security", "find-generic-password", "-w", "-s", old_svc, "-a", "user"],
                              env=env, check=False)
            self.assertEqual(legacy2.returncode, 0, legacy2.stdout + legacy2.stderr)
            self.assertEqual(legacy2.stdout.strip(), "x")
            # active activation metadata written (seam path), no deny marker
            meta = json.loads(meta_file.read_text())
            self.assertEqual(meta["state"], "active")
            self.assertFalse((self.env.root / "legacy-marker").exists())
        finally:
            run_cmd(["/usr/bin/security", "delete-generic-password", "-s", old_svc, "-a", "user"],
                    env=env, check=False)
            run_cmd(["/usr/bin/python3", PACKAGE / "bin/msw-keychain-bridge", "delete", new_svc, "user"],
                    env=env, check=False)

    # ---- blocker 4: revocation deletion failure denies globally ---------

    def test_remove_local_keychain_deletion_failure_denies_globally(self) -> None:
        """Blocker 4 + re-review: if the Keychain deletion fails, the global
        deny marker (recorded first) plus the revocation-uncertain tombstone
        keep every helper denying — no other workspace can remain live on the
        credential."""
        self.seed_host_credential()
        self.seed_host_meta()
        env = self.env.env.copy()
        # exercise the production bridge path (not the file seam) with the
        # delete-failure injection; keep the bridge watchdog short
        env["MSW_TEST_KEYCHAIN_DIR"] = ""
        env["MSW_FAKE_KC_DELETE_FAIL"] = "1"
        env["MSW_KEYCHAIN_TIMEOUT_SECS"] = "2"
        proc = self.env.msw("github", "remove", "dev", check=False, extra_env=env)
        self.assertFailed(proc, "removal failed")
        # at least one durable deny gate was recorded: the file marker
        marker = self.env.home / ".config/msw/credential-disabled"
        self.assertTrue(marker.exists())
        # the tombstone records the uncertain revocation (still a GLOBAL deny)
        meta = json.loads(self.host_meta_path.read_text())
        self.assertEqual(meta["state"], "revocation-uncertain")
        self.assertIn("revokedAt", meta)
        # the workspace is quarantined (fail-closed)
        quarantine = self.github_meta_dir / "dev.quarantine"
        self.assertTrue(quarantine.exists())
        # every helper denies: the marker is checked before the Keychain, so
        # no token is emitted even though the record may still exist
        helper = PACKAGE / "bin" / "msw-github-host-token"
        helper_env = {
            "MSW_HOST_META_FILE": str(self.host_meta_path),
            "MSW_HOST_KEYCHAIN_SERVICE": HOST_KEYCHAIN_SERVICE,
            "MSW_HOST_KEYCHAIN_ACCOUNT": HOST_KEYCHAIN_ACCOUNT,
        }
        proc = run_cmd([helper], env=helper_env, check=False)
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(proc.stdout, "")
        # host_credential_available also denies: auth without --force re-acquires
        # (would need gh) instead of reporting the stale record as present
        proc = self.env.msw("github", "status", "--format", "json", extra_env=env, check=False)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        dev = next(w for w in json.loads(proc.stdout)["workspaces"] if w["workspace"] == "dev")
        self.assertEqual(dev["hostCredential"], "missing")

    def test_remove_local_primary_marker_failure_uses_deny_item_safely(self) -> None:
        """If the primary file marker cannot be written, the independent
        Keychain deny item still gates the credential before deletion, so a
        fully proven removal may complete safely."""
        self.seed_host_credential()
        self.seed_host_meta()
        blocker = self.env.root / "blocker-file"
        blocker.write_text("x")
        env = self.env.env.copy()
        env["MSW_CREDENTIAL_DENY_MARKER"] = str(blocker / "nested" / "credential-disabled")
        proc = self.env.msw("github", "remove", "dev", check=False, extra_env=env)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("removed the host GitHub credential", proc.stdout + proc.stderr)
        self.assertFalse(self.host_key_path.exists())
        self.assertFalse(self.host_meta_path.exists())
        self.assertFalse((self.github_meta_dir / "dev.quarantine").exists())
        self.assertFalse((self.env.home / ".config/msw/credential-disabled").exists())

    def test_remove_local_deny_item_blocks_helper_when_primary_marker_fails(self) -> None:
        """Closure re-review: if the primary FILE marker cannot be recorded,
        the dedicated Keychain deny item (.v2.deny) is the durable deny gate —
        it is written + verified first and keeps the helper denying GLOBALLY
        even with old ACTIVE metadata + token still present."""
        self.seed_host_credential()
        self.seed_host_meta()
        blocker = self.env.root / "blocker-file"
        blocker.write_text("x")
        env = self.env.env.copy()
        env["MSW_CREDENTIAL_DENY_MARKER"] = str(blocker / "nested" / "credential-disabled")
        env["MSW_FAKE_KC_DELETE_FAIL"] = "1"  # token deletion fails: gates stay
        proc = self.env.msw("github", "remove", "dev", check=False, extra_env=env)
        self.assertFailed(proc, "removal failed")
        # the primary file marker was NOT recorded (impossible path)...
        self.assertFalse((self.env.home / ".config/msw/credential-disabled").exists())
        # ...but the Keychain deny item was (file seam) and denies the helper
        deny_file = self.env.key_file("org.microsandbox.MSWMonitor.github-host.v2.deny", "user")
        self.assertTrue(deny_file.exists())
        helper = PACKAGE / "bin/msw-github-host-token"
        helper_env = self.host_tool_env()
        proc = run_cmd([helper], env=helper_env, check=False)
        self.assertEqual(proc.returncode, 1, "deny item must block the helper globally")
        self.assertEqual(proc.stdout, "")
        # availability also denies (status reports missing)
        proc = self.env.msw("github", "status", "--format", "json", extra_env=env, check=False)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        dev = next(w for w in json.loads(proc.stdout)["workspaces"] if w["workspace"] == "dev")
        self.assertEqual(dev["hostCredential"], "missing")

    def test_remove_local_no_primary_deny_uses_global_quarantine(self) -> None:
        """If every earlier deny/deletion path fails, a durable global
        quarantine still blocks every helper and workspace."""
        self.seed_host_credential()
        self.seed_host_meta()
        blocker = self.env.root / "blocker-file"
        blocker.write_text("x")
        keychain_dir = self.env.root / "keychain"
        keychain_dir.chmod(0o500)
        env = self.env.env.copy()
        env["MSW_CREDENTIAL_DENY_MARKER"] = str(blocker / "nested" / "credential-disabled")
        env["MSW_HOST_KEYCHAIN_DENY_SERVICE"] = "org.msw.unwritable.deny"
        env["MSW_FAKE_HOST_META_WRITE_FAIL"] = "1"
        try:
            proc = self.env.msw("github", "remove", "dev", check=False, extra_env=env)
            self.assertFailed(proc, "quarantined")
            self.assertTrue(self.host_key_path.exists())
            self.assertTrue(self.host_meta_path.exists())
            global_quarantine = self.github_meta_dir / "credential.quarantine"
            self.assertTrue(global_quarantine.exists())
            self.assertTrue((self.github_meta_dir / "dev.quarantine").exists())
            helper_env = self.host_tool_env()
            helper_env["MSW_GLOBAL_CREDENTIAL_QUARANTINE"] = str(global_quarantine)
            denied = run_cmd(
                [PACKAGE / "bin" / "msw-github-host-token"],
                env=helper_env, check=False,
            )
            self.assertNotEqual(denied.returncode, 0)
            self.assertEqual(denied.stdout, "")
        finally:
            keychain_dir.chmod(0o700)

    # ---- blocker 4: global credential lock serializes store/rotate/remove

    def test_credential_lock_serializes_store(self) -> None:
        self.empty_policy()
        lock = self.github_meta_dir / "credential.lock"
        lock.parent.mkdir(parents=True, exist_ok=True)
        holder = subprocess.Popen(
            ["bash", "-c", f'exec 8>>"{lock}"; /usr/bin/lockf -s -t 0 8 && echo READY; sleep 30'],
            stdout=subprocess.PIPE, text=True,
        )
        try:
            self.assertEqual(holder.stdout.readline().strip(), "READY")
            with self.env.start_fake_github() as fake:
                env = self.env.env.copy()
                env.update({
                    "MSW_GH_BIN": str(FAKE_GH),
                    "MSW_FAKE_GH_STATE": str(self.fake_gh_state()),
                    "MSW_CURL_BIN": str(FAKE_API_CURL),
                    "MSW_PROXY_UPSTREAM_ROOT": fake.base_url,
                })
                proc = self.env.msw("github", "auth", "--json", check=False, extra_env=env)
                self.assertNotEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                self.assertIn("global host credential lock", proc.stderr)
                self.assertFalse(self.host_key_path.exists())
                self.assertFalse(self.host_meta_path.exists())
        finally:
            holder.kill()
            holder.stdout.close()
            holder.wait()

    # ---- high-risk: strict policy validator at host gates ---------------

    def test_strict_policy_rejects_malformed_at_host_push_gate(self) -> None:
        """High-risk: a corrupt policy denies host push exactly like the
        proxy's fail-closed rule — bad capability, bad mode, duplicate
        canonicals, unknown workspace, non-canonical repo all fail."""
        self.seed_host_credential()
        self.seed_host_meta()
        self.prepare_guest_repo()
        malformed = [
            {"schemaVersion": 1, "workspaces": {
                "dev": {"capability": "short", "repos": [{"canonical": "acme/demo", "mode": "read-only"}]},
                "playgrounds": {"capability": PLAY_CAP, "repos": []},
                "personal": {"capability": PERSONAL_CAP, "repos": []}}},
            {"schemaVersion": 1, "workspaces": {
                "dev": {"capability": DEV_CAP, "repos": [{"canonical": "acme/demo", "mode": "admin"}]},
                "playgrounds": {"capability": PLAY_CAP, "repos": []},
                "personal": {"capability": PERSONAL_CAP, "repos": []}}},
            {"schemaVersion": 1, "workspaces": {
                "dev": {"capability": DEV_CAP, "repos": [
                    {"canonical": "acme/demo", "mode": "read-only"},
                    {"canonical": "acme/demo", "mode": "read-write"}]},
                "playgrounds": {"capability": PLAY_CAP, "repos": []},
                "personal": {"capability": PERSONAL_CAP, "repos": []}}},
            {"schemaVersion": 1, "workspaces": {
                "dev": {"capability": DEV_CAP, "repos": [{"canonical": "acme/demo", "mode": "read-only"}]},
                "evil": {"capability": "d" * 48, "repos": []},
                "playgrounds": {"capability": PLAY_CAP, "repos": []},
                "personal": {"capability": PERSONAL_CAP, "repos": []}}},
            {"schemaVersion": 1, "workspaces": {
                "dev": {"capability": DEV_CAP, "repos": [{"canonical": "Acme/Demo", "mode": "read-only"}]},
                "playgrounds": {"capability": PLAY_CAP, "repos": []},
                "personal": {"capability": PERSONAL_CAP, "repos": []}}},
            {"schemaVersion": 1, "workspaces": {
                "dev": {"capability": DEV_CAP, "repos": [{"canonical": "acme/demo.git", "mode": "read-only"}]},
                "playgrounds": {"capability": PLAY_CAP, "repos": []},
                "personal": {"capability": PERSONAL_CAP, "repos": []}}},
            {"schemaVersion": 1, "workspaces": {
                "dev": {"capability": ("a" * 48) + "\n", "repos": [{"canonical": "acme/demo", "mode": "read-only"}]},
                "playgrounds": {"capability": PLAY_CAP, "repos": []},
                "personal": {"capability": PERSONAL_CAP, "repos": []}}},
            # closure: duplicate capability across workspaces -> deny
            {"schemaVersion": 1, "workspaces": {
                "dev": {"capability": DEV_CAP, "repos": []},
                "playgrounds": {"capability": DEV_CAP, "repos": []},
                "personal": {"capability": PERSONAL_CAP, "repos": []}}},
            # closure: repo segment must start [a-z0-9] (leading dot/'-' denied)
            {"schemaVersion": 1, "workspaces": {
                "dev": {"capability": DEV_CAP, "repos": [{"canonical": ".hidden/name", "mode": "read-only"}]},
                "playgrounds": {"capability": PLAY_CAP, "repos": []},
                "personal": {"capability": PERSONAL_CAP, "repos": []}}},
            {"schemaVersion": 1, "workspaces": {
                "dev": {"capability": DEV_CAP, "repos": [{"canonical": "-dash/name", "mode": "read-only"}]},
                "playgrounds": {"capability": PLAY_CAP, "repos": []},
                "personal": {"capability": PERSONAL_CAP, "repos": []}}},
            # jq `$` also matches before a final newline; reject CR/LF
            # explicitly so host and proxy full-match semantics stay equal.
            {"schemaVersion": 1, "workspaces": {
                "dev": {"capability": DEV_CAP, "repos": [{"canonical": "acme/demo\n", "mode": "read-only"}]},
                "playgrounds": {"capability": PLAY_CAP, "repos": []},
                "personal": {"capability": PERSONAL_CAP, "repos": []}}},
        ]
        for payload in malformed:
            self.set_policy(payload)
            proc = self.env.msw("push", "dev", "repo", "--yes", check=False)
            self.assertNotEqual(proc.returncode, 0, payload)
            self.assertIn("malformed", proc.stdout + proc.stderr, payload)
        # sanity: a valid policy (read-write repo) pushes fine
        self.set_policy({"schemaVersion": 1, "workspaces": {
            "dev": {"capability": DEV_CAP, "repos": [{"canonical": "acme/demo", "mode": "read-write"}]},
            "playgrounds": {"capability": PLAY_CAP, "repos": []},
            "personal": {"capability": PERSONAL_CAP, "repos": []},
        }})
        proc = self.env.msw("push", "dev", "repo", "--yes")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("pushed main from dev:repo", proc.stdout)

    def test_strict_policy_rejects_malformed_at_verify_gate(self) -> None:
        self.seed_host_credential()
        self.seed_host_meta()
        self.set_policy({"schemaVersion": 1, "workspaces": {
            "dev": {"capability": "not-hex", "repos": [{"canonical": "acme/demo", "mode": "read-write"}]},
            "playgrounds": {"capability": PLAY_CAP, "repos": []},
            "personal": {"capability": PERSONAL_CAP, "repos": []},
        }})
        proc = self.env.msw("github", "verify", "dev", check=False)
        self.assertFailed(proc, "missing or malformed")

    # ---- app github-state local branch ----------------------------------

    def test_app_github_state_local_mode_reports_policy(self) -> None:
        self.empty_policy()
        self.set_policy({"schemaVersion": 1, "workspaces": {
            "dev": {"capability": DEV_CAP, "repos": [{"canonical": "acme/demo", "mode": "read-write"}]},
            "playgrounds": {"capability": PLAY_CAP, "repos": []},
            "personal": {"capability": PERSONAL_CAP, "repos": []},
        }})
        proc = self.env.msw("app", "github-state", "--format", "json")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        result = json.loads(proc.stdout)
        dev = next(w for w in result["result"]["workspaces"] if w["workspace"] == "dev")
        self.assertEqual(dev["provider"], "local-policy")
        self.assertTrue(dev["configured"])
        self.assertEqual(dev["accessMode"], "read-write")
        self.assertEqual(dev["verificationRepository"], "acme/demo")
        self.assertEqual(dev["capability"], "minted")
        self.assertEqual(dev["hostCredential"], "missing")
        self.assertFalse(dev["quarantined"])


class MigrationTests(_LocalModeGitHubBase):
    """Path C §11 local-mode entry migration matrix (fixture state only)."""

    def seed_legacy_state(self, box: str = "dev", *, conf: bool = True,
                          quarantine: bool = False, secret: bool = True,
                          keychain: bool = True) -> None:
        meta_dir = self.github_meta_dir
        meta_dir.mkdir(parents=True, exist_ok=True)
        if conf:
            (meta_dir / f"{box}.conf").write_text(
                "verification_repo=acme/demo\naccess=host-write\nconfigured_at=2026-08-07T00:00:00Z\n")
        if quarantine:
            (meta_dir / f"{box}.quarantine").write_text("pre-existing credential failure\n")
        if secret:
            state = self.env.state()
            state["sandboxes"][box].setdefault("secrets", {})["GH_TOKEN"] = "GH_TOKEN@github.com,api.github.com"
            self.env.state_file.write_text(json.dumps(state, indent=2, sort_keys=True))
        if keychain:
            self.env.key_file("msw.github.read", box).write_text(
                "github_pat_LEGACY_READ_abcdefghijklmnopqrstuvwxyz0123456789")
            self.env.key_file("msw.github.write", box).write_text(
                "github_pat_LEGACY_WRITE_abcdefghijklmnopqrstuvwxyz0123456789")

    def test_migration_full_transaction_and_lock_reacquisition(self) -> None:
        self.seed_legacy_state()
        meta_dir = self.github_meta_dir
        proc = self.env.msw("github", "migrate", "dev")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("legacy GitHub state migrated for dev", proc.stdout)
        # conf archived (never blind-deleted), original gone
        self.assertFalse((meta_dir / "dev.conf").exists())
        archived = list((meta_dir / "migrated-local").glob("dev.conf.*"))
        self.assertEqual(len(archived), 1, [p.name for p in archived])
        self.assertIn("verification_repo=acme/demo", archived[0].read_text())
        # secret removed and PROVEN via inspect
        state = self.env.state()
        self.assertNotIn("GH_TOKEN", state["sandboxes"]["dev"].get("secrets", {}))
        # migration-owned quarantine marker cleared
        self.assertFalse((meta_dir / "dev.quarantine").exists())
        # policy skeleton with minted capability, empty repos
        policy = json.loads(self.policy_path.read_text())
        self.assertEqual(policy["schemaVersion"], 1)
        self.assertRegex(policy["workspaces"]["dev"]["capability"], r"^[0-9a-f]{48}$")
        self.assertEqual(policy["workspaces"]["dev"]["repos"], [])
        # journal: intent (with discovered state) then committed
        journal_dir = meta_dir / "migrated-local"
        journal = (journal_dir / "journal.jsonl").read_text()
        self.assertIn('"event":"intent"', journal)
        self.assertIn('\\"confPresent\\":true', journal)
        self.assertIn('\\"quarantinePreExisted\\":false', journal)
        self.assertIn('\\"secretBound\\":true', journal)
        self.assertIn('"event":"committed"', journal)
        # journal durability: dir 0700, file 0600, tmp+rename path exercised
        self.assertEqual(stat.S_IMODE(journal_dir.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((journal_dir / "journal.jsonl").stat().st_mode), 0o600)
        # legacy keychain items preserved (§1)
        self.assertTrue(self.env.key_file("msw.github.read", "dev").exists())
        self.assertTrue(self.env.key_file("msw.github.write", "dev").exists())
        # lock re-acquisition: a second migration is a no-op success, and a
        # normal GitHub operation can re-acquire the same lock
        proc = self.env.msw("github", "migrate", "dev")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("nothing to migrate", proc.stdout)
        self.env.msw("github", "status", "dev")

    def test_migration_refuses_when_lock_held(self) -> None:
        self.seed_legacy_state(secret=False, keychain=False)
        lock = self.github_meta_dir / "dev.lock"
        lock.parent.mkdir(parents=True, exist_ok=True)
        holder = subprocess.Popen(
            ["bash", "-c", f'exec 9>>"{lock}"; /usr/bin/lockf -s -t 0 9 && echo READY; sleep 30'],
            stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(holder.stdout.readline().strip(), "READY")
            proc = self.env.msw("github", "migrate", "dev", check=False)
            self.assertFailed(proc, "already in progress")
            # nothing changed: conf untouched, no policy skeleton, no journal
            self.assertTrue((self.github_meta_dir / "dev.conf").exists())
            self.assertFalse(self.policy_path.exists())
        finally:
            holder.kill()
            holder.wait()

    def test_migration_surfaces_stale_legacy_lock_directory(self) -> None:
        self.seed_legacy_state(secret=False, keychain=False)
        lock = self.github_meta_dir / "dev.lock"
        lock.mkdir()
        (lock / "pid").write_text("99999999\n")
        proc = self.env.msw("github", "migrate", "dev", check=False)
        self.assertFailed(proc, "manual review")
        self.assertTrue(lock.is_dir())  # never unlinked directly
        self.assertTrue((self.github_meta_dir / "dev.conf").exists())

    def test_migration_preserves_preexisting_quarantine(self) -> None:
        self.seed_legacy_state(quarantine=True, secret=False, keychain=False)
        proc = self.env.msw("github", "migrate", "dev")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("remains quarantined", proc.stdout + proc.stderr)
        quarantine = self.github_meta_dir / "dev.quarantine"
        self.assertTrue(quarantine.exists())
        self.assertEqual(quarantine.read_text(), "pre-existing credential failure\n")
        # the rest of the transaction still ran
        self.assertFalse((self.github_meta_dir / "dev.conf").exists())
        policy = json.loads(self.policy_path.read_text())
        self.assertRegex(policy["workspaces"]["dev"]["capability"], r"^[0-9a-f]{48}$")
        journal = (self.github_meta_dir / "migrated-local" / "journal.jsonl").read_text()
        self.assertIn('\\"quarantinePreExisted\\":true', journal)
        self.assertIn('"event":"committed"', journal)

    def test_migration_quarantines_when_secret_removal_fails(self) -> None:
        self.seed_legacy_state(keychain=False)
        proc = self.env.msw("github", "migrate", "dev", check=False,
                            extra_env={"MSW_FAKE_SECRET_REMOVE_FAIL": "1"})
        self.assertFailed(proc, "quarantined")
        quarantine = self.github_meta_dir / "dev.quarantine"
        self.assertTrue(quarantine.exists())
        self.assertIn("secret removal failed", quarantine.read_text())
        # the transaction stopped before archiving the conf
        self.assertTrue((self.github_meta_dir / "dev.conf").exists())
        # the secret is still bound
        state = self.env.state()
        self.assertIn("GH_TOKEN", state["sandboxes"]["dev"].get("secrets", {}))

    def test_migration_refuses_when_journal_unwritable(self) -> None:
        self.seed_legacy_state()
        journal_dir = self.github_meta_dir / "migrated-local"
        journal_dir.mkdir(parents=True, exist_ok=True)
        journal_dir.chmod(0o500)
        try:
            proc = self.env.msw("github", "migrate", "dev", check=False)
            self.assertFailed(proc, "journal")
            self.assertIn("no state was changed", proc.stdout + proc.stderr)
            # untouched: conf present, secret still bound, no marker, no policy
            self.assertTrue((self.github_meta_dir / "dev.conf").exists())
            state = self.env.state()
            self.assertIn("GH_TOKEN", state["sandboxes"]["dev"].get("secrets", {}))
            self.assertFalse((self.github_meta_dir / "dev.quarantine").exists())
            self.assertFalse(self.policy_path.exists())
        finally:
            journal_dir.chmod(0o700)

    def test_migration_quarantines_when_journal_write_fails_mid_transaction(self) -> None:
        self.seed_legacy_state(secret=True, keychain=False)
        # write #1 = mandatory intent (succeeds); write #2 = quarantine-set
        # event, which lands AFTER the migration-owned marker (a mutation).
        proc = self.env.msw("github", "migrate", "dev", check=False,
                            extra_env={"MSW_FAKE_JOURNAL_FAIL_ON": "2"})
        self.assertFailed(proc, "journal")
        quarantine = self.github_meta_dir / "dev.quarantine"
        self.assertTrue(quarantine.exists())
        self.assertIn("journal write failed", quarantine.read_text())
        # stopped before archiving the conf or removing the secret
        self.assertTrue((self.github_meta_dir / "dev.conf").exists())
        state = self.env.state()
        self.assertIn("GH_TOKEN", state["sandboxes"]["dev"].get("secrets", {}))

    def test_migration_trigger_on_first_local_operation(self) -> None:
        self.seed_legacy_state(secret=False, keychain=False)
        proc = self.env.msw("github", "status", "dev")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("legacy GitHub state migrated for dev", proc.stdout + proc.stderr)
        self.assertFalse((self.github_meta_dir / "dev.conf").exists())
        self.assertRegex(json.loads(self.policy_path.read_text())["workspaces"]["dev"]["capability"],
                         r"^[0-9a-f]{48}$")
        # the operation that triggered the migration proceeded normally
        self.assertIn("HOST_CRED", proc.stdout)

    def test_migration_trigger_keeps_status_json_clean(self) -> None:
        self.seed_legacy_state(secret=False, keychain=False)
        proc = self.env.msw("github", "status", "--format", "json", "dev")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        result = json.loads(proc.stdout)  # stdout stays pure JSON despite the trigger
        dev = next(w for w in result["workspaces"] if w["workspace"] == "dev")
        self.assertEqual(dev["capability"], "minted")
        self.assertEqual(dev["hostCredential"], "missing")
        self.assertFalse((self.github_meta_dir / "dev.conf").exists())

    def test_migration_trigger_on_first_push(self) -> None:
        self.set_policy({"schemaVersion": 1, "workspaces": {
            "dev": {"capability": DEV_CAP, "repos": [{"canonical": "acme/demo", "mode": "read-write"}]},
            "playgrounds": {"capability": PLAY_CAP, "repos": []},
            "personal": {"capability": PERSONAL_CAP, "repos": []},
        }})
        self.seed_host_credential()
        self.seed_host_meta()
        self.seed_legacy_state(secret=False, keychain=False)
        # The first local-mode operation that starts the workspace (the clone)
        # retires the legacy state; the push then proceeds on the migrated state.
        self.prepare_guest_repo()
        self.assertFalse((self.github_meta_dir / "dev.conf").exists())
        self.assertRegex(json.loads(self.policy_path.read_text())["workspaces"]["dev"]["capability"],
                         r"^[0-9a-f]{48}$")
        proc = self.env.msw("push", "dev", "repo", "--yes")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("pushed main from dev:repo", proc.stdout)

    # ---- blocker 6: journal durability + quarantine preservation ---------

    def test_migration_journal_concurrent_cross_workspace(self) -> None:
        """Blocker 6: concurrent migrations of different workspaces share one
        journal; O_APPEND under the journal-wide flock must not lose or
        corrupt a single line from either workspace. (Legacy state is conf-only
        so the two processes never race on the shared fake state file.)"""
        self.seed_legacy_state(box="dev", secret=False, keychain=False)
        self.seed_legacy_state(box="playgrounds", secret=False, keychain=False)
        env = self.env.env.copy()
        procs = [
            subprocess.Popen([str(self.env.msw_bin), "github", "migrate", "dev"],
                             env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True),
            subprocess.Popen([str(self.env.msw_bin), "github", "migrate", "playgrounds"],
                             env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True),
        ]
        for p in procs:
            out, err = p.communicate(timeout=120)
            self.assertEqual(p.returncode, 0, out + err)
        journal = (self.github_meta_dir / "migrated-local" / "journal.jsonl").read_text()
        # every line is complete, valid JSON (no torn/interleaved lines)
        lines = [json.loads(l) for l in journal.splitlines() if l.strip()]
        intents = [l for l in lines if l["event"] == "intent"]
        committed = [l for l in lines if l["event"] == "committed"]
        self.assertEqual(len(intents), 2, journal)
        self.assertEqual(len(committed), 2, journal)
        self.assertEqual({l["workspace"] for l in intents}, {"dev", "playgrounds"})
        self.assertEqual({l["workspace"] for l in committed}, {"dev", "playgrounds"})
        # both confs archived, neither migration lost its events
        self.assertFalse((self.github_meta_dir / "dev.conf").exists())
        self.assertFalse((self.github_meta_dir / "playgrounds.conf").exists())
        archived = list((self.github_meta_dir / "migrated-local").glob("*.conf.*"))
        self.assertEqual(len(archived), 2, [p.name for p in archived])
        self.assertFalse((self.github_meta_dir / "dev.quarantine").exists())
        self.assertFalse((self.github_meta_dir / "playgrounds.quarantine").exists())

    def test_migration_crash_mid_transaction_leaves_recoverable_journal(self) -> None:
        """Blocker 6 crash seam: SIGKILL the migration right after the
        quarantine-set event. The durable journal + migration-owned marker
        survive; a re-run completes the transaction and preserves the marker
        (fail-closed) with the original reason byte-for-byte."""
        self.seed_legacy_state(secret=True, keychain=False)
        journal_file = self.github_meta_dir / "migrated-local" / "journal.jsonl"
        env = self.env.env.copy()
        proc = subprocess.Popen([str(self.env.msw_bin), "github", "migrate", "dev"],
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                if proc.poll() is not None:
                    break
                if journal_file.exists() and '"event":"quarantine-set"' in journal_file.read_text():
                    break
                time.sleep(0.05)
            self.assertIsNone(proc.poll(), "migration finished before the kill point")
            proc.kill()
            proc.wait(timeout=30)
            journal = journal_file.read_text()
            self.assertIn('"event":"intent"', journal)
            self.assertIn('"event":"quarantine-set"', journal)
            self.assertNotIn('"event":"committed"', journal)
            # the migration-owned marker exists (written before quarantine-set)
            marker = self.github_meta_dir / "dev.quarantine"
            self.assertTrue(marker.exists())
            self.assertEqual(marker.read_text(), "Legacy GitHub state migration in progress\n")
            # re-run: completes, keeps the marker, archives the conf, journal
            # records a second intent + committed
            proc2 = self.env.msw("github", "migrate", "dev")
            self.assertEqual(proc2.returncode, 0, proc2.stdout + proc2.stderr)
            self.assertIn("remains quarantined", proc2.stdout + proc2.stderr)
            self.assertEqual(marker.read_text(), "Legacy GitHub state migration in progress\n")
            self.assertFalse((self.github_meta_dir / "dev.conf").exists())
            journal2 = journal_file.read_text()
            self.assertGreaterEqual(journal2.count('"event":"intent"'), 2, journal2)
            self.assertIn('"event":"committed"', journal2)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=30)

    def test_migration_preexisting_quarantine_preserved_byte_for_byte_on_failure(self) -> None:
        """Blocker 6: a failure after a PRE-EXISTING quarantine marker must
        never truncate/overwrite it — the marker stays byte-for-byte and the
        new failure lands in the durable journal."""
        self.seed_legacy_state(quarantine=True, keychain=False)
        marker = self.github_meta_dir / "dev.quarantine"
        marker.write_text("original reason line one\nline two\n")
        before = marker.read_bytes()
        proc = self.env.msw("github", "migrate", "dev", check=False,
                            extra_env={"MSW_FAKE_SECRET_REMOVE_FAIL": "1"})
        self.assertFailed(proc, "quarantined")
        self.assertEqual(marker.read_bytes(), before, "pre-existing marker must be byte-identical")
        journal = (self.github_meta_dir / "migrated-local" / "journal.jsonl").read_text()
        self.assertIn("secret removal failed", journal)
        self.assertIn('"event":"failed"', journal)


    def test_migration_sigterm_preserves_preexisting_marker(self) -> None:
        """Re-review item 4: SIGTERM mid-transaction with a PRE-EXISTING
        quarantine marker must never truncate it — the marker stays
        byte-for-byte and the interrupt is recorded only in the durable
        journal (never the truncating quarantine writer)."""
        self.seed_legacy_state(quarantine=True, secret=False, keychain=False)
        marker = self.github_meta_dir / "dev.quarantine"
        marker.write_text("original reason line one\nline two\n")
        before = marker.read_bytes()
        pause = self.env.root / "migrate-pause"
        reached = self.env.root / "migrate-pause-reached"
        pause.touch()
        env = self.env.env.copy()
        env["MSW_FAKE_MIGRATION_PAUSE_FILE"] = str(pause)
        env["MSW_FAKE_MIGRATION_PAUSE_REACHED"] = str(reached)
        proc = subprocess.Popen([str(self.env.msw_bin), "github", "migrate", "dev"],
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            journal = self.github_meta_dir / "migrated-local" / "journal.jsonl"
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline and not reached.exists():
                time.sleep(0.05)
            self.assertTrue(reached.exists(), "migration never reached the pause point")
            self.assertIn('"event":"intent"', journal.read_text() if journal.exists() else "")
            proc.send_signal(signal.SIGTERM)
            out, err = proc.communicate(timeout=60)
            self.assertNotEqual(proc.returncode, 0, out + err)
            # the pre-existing marker is byte-for-byte untouched
            self.assertEqual(marker.read_bytes(), before)
            # the interrupt was recorded in the durable journal (the trap
            # names the signal it received: TERM)
            journal_text = journal.read_text()
            self.assertIn('"event":"interrupted"', journal_text)
            self.assertIn("TERM", journal_text)
            self.assertIn("pre-existing quarantine marker preserved", journal_text)
        finally:
            pause.unlink(missing_ok=True)
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=30)

    def test_migration_signal_at_arm_hook_preserves_preexisting_marker(self) -> None:
        """Closure re-review: MIGRATION_PREEXISTING_QUARANTINE is recorded by
        setup_transaction_arm BEFORE the traps are installed, so a signal
        delivered at the arm hook (no mutation yet) still preserves the
        original marker byte-for-byte and journals the interrupt."""
        self.seed_legacy_state(quarantine=True, secret=False, keychain=False)
        marker = self.github_meta_dir / "dev.quarantine"
        marker.write_text("original reason line one\nline two\n")
        before = marker.read_bytes()
        pause = self.env.root / "migrate-arm-pause"
        reached = self.env.root / "migrate-arm-reached"
        pause.touch()
        env = self.env.env.copy()
        env["MSW_FAKE_MIGRATION_ARM_PAUSE_FILE"] = str(pause)
        env["MSW_FAKE_MIGRATION_ARM_PAUSE_REACHED"] = str(reached)
        proc = subprocess.Popen([str(self.env.msw_bin), "github", "migrate", "dev"],
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline and not reached.exists():
                time.sleep(0.05)
            self.assertTrue(reached.exists(), "migration never reached the arm hook")
            proc.send_signal(signal.SIGTERM)
            out, err = proc.communicate(timeout=60)
            self.assertNotEqual(proc.returncode, 0, out + err)
            self.assertEqual(marker.read_bytes(), before)
            journal = self.github_meta_dir / "migrated-local" / "journal.jsonl"
            journal_text = journal.read_text() if journal.exists() else ""
            self.assertIn('"event":"interrupted"', journal_text)
        finally:
            pause.unlink(missing_ok=True)
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=30)

    def test_migration_journal_zero_write_fails_closed(self) -> None:
        """Re-review item 4: the journal writer treats a zero write as a
        failure — the mandatory intent never lands, so the migration aborts
        before any mutation."""
        self.seed_legacy_state()
        proc = self.env.msw("github", "migrate", "dev", check=False,
                            extra_env={"MSW_FAKE_JOURNAL_ZERO_WRITE": "1"})
        self.assertFailed(proc, "journal")
        self.assertIn("no state was changed", proc.stdout + proc.stderr)
        self.assertTrue((self.github_meta_dir / "dev.conf").exists())
        state = self.env.state()
        self.assertIn("GH_TOKEN", state["sandboxes"]["dev"].get("secrets", {}))
        self.assertFalse((self.github_meta_dir / "dev.quarantine").exists())
        self.assertFalse(self.policy_path.exists())

    def test_migration_journal_short_write_completes(self) -> None:
        """Re-review item 4: the journal writer loops os.write until every
        byte lands — a simulated short write must not lose or corrupt the
        line."""
        self.seed_legacy_state()
        proc = self.env.msw("github", "migrate", "dev",
                            extra_env={"MSW_FAKE_JOURNAL_SHORT_WRITE": "1"})
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        journal = (self.github_meta_dir / "migrated-local" / "journal.jsonl").read_text()
        lines = [json.loads(l) for l in journal.splitlines() if l.strip()]
        self.assertIn("committed", [l["event"] for l in lines])
        self.assertIn("intent", [l["event"] for l in lines])


class LocalModeSSHTests(_LocalModeGitHubBase):
    """Blocker 7: local-mode SSH resolves MSW_GITHUB_MODE FIRST, never reads
    Connect credentials.json, and never exports GH_TOKEN; legacy/Connect state
    yields a migration remedy / token-free SSH."""

    def _guest_secret_state(self) -> dict:
        state = self.env.state()
        return state["sandboxes"]["dev"].get("secrets", {})

    def test_ssh_proxy_local_never_reads_connect_credentials_or_exports_token(self) -> None:
        # Plant dormant Connect state (credentials.json + schema-3 keychain
        # record) exactly like an upgraded machine.
        cred = self.env.home / "Library/Application Support/MSW Monitor"
        cred.mkdir(parents=True, exist_ok=True)
        (cred / "credentials.json").write_text(json.dumps({
            "entries": {
                "dev.guest": {
                    "provider": "github-app-installation",
                    "workspace": "dev",
                    "recoveryState": "ready",
                    "accessExpiresAt": "2099-01-01T00:00:00Z",
                    "repositoryNames": ["acme/demo"],
                },
            },
        }))
        self.env.key_file("msw.github.app.dev.guest.tokens", "profile").write_text(json.dumps({
            "schemaVersion": 3,
            "grantID": "grant-1",
            "accessToken": "ghs_connect_abcdefghijklmnopqrstuvwxyz0123456789",
            "accessExpiresAt": "2099-01-01T00:00:00Z",
            "generation": 1,
        }))
        env = self.env.env.copy()
        env["MSW_FAKE_RECORD_CREDENTIAL_ENV"] = "1"
        proxy = self.env.home / ".local/bin/msw-ssh-proxy"
        proc = self.env.run(proxy, "dev.msb", extra_env=env)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        events = self.env.state()["events"]
        credential_events = [e for e in events if e["event"] == "credential-env"]
        self.assertTrue(credential_events, events)
        self.assertTrue(all(e["gh_token_present"] is False for e in credential_events),
                        "local-mode SSH must never export GH_TOKEN")
        # the workspace came up (token-free path)
        self.assertTrue(self.env.state()["sandboxes"]["dev"]["running"])

    def test_ssh_proxy_local_legacy_conf_fails_with_migration_remedy(self) -> None:
        meta_dir = self.github_meta_dir
        meta_dir.mkdir(parents=True, exist_ok=True)
        (meta_dir / "dev.conf").write_text("verification_repo=acme/demo\naccess=host-write\n")
        proxy = self.env.home / ".local/bin/msw-ssh-proxy"
        proc = self.env.run(proxy, "dev.msb", check=False)
        self.assertNotEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        joined = proc.stdout + proc.stderr
        self.assertIn("migrate", joined)
        self.assertIn("legacy", joined)
        # the workspace was NOT started (fail-closed, no token, no side effect)
        self.assertFalse(self.env.state()["sandboxes"]["dev"]["running"])

    def test_ssh_proxy_local_quarantine_fails_closed(self) -> None:
        meta_dir = self.github_meta_dir
        meta_dir.mkdir(parents=True, exist_ok=True)
        (meta_dir / "dev.quarantine").write_text("pre-existing credential failure\n")
        proxy = self.env.home / ".local/bin/msw-ssh-proxy"
        proc = self.env.run(proxy, "dev.msb", check=False)
        self.assertFailed(proc, "quarantined")
        self.assertFalse(self.env.state()["sandboxes"]["dev"]["running"])

    def test_ssh_proxy_local_starts_stopped_workspace_token_free(self) -> None:
        self.env.msw("stop", "dev")
        self.assertFalse(self.env.state()["sandboxes"]["dev"]["running"])
        env = self.env.env.copy()
        env["MSW_FAKE_RECORD_CREDENTIAL_ENV"] = "1"
        proxy = self.env.home / ".local/bin/msw-ssh-proxy"
        proc = self.env.run(proxy, "dev.msb", extra_env=env)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        events = self.env.state()["events"]
        credential_events = [e for e in events if e["event"] == "credential-env"]
        self.assertTrue(all(e["gh_token_present"] is False for e in credential_events), events)
        self.assertTrue(self.env.state()["sandboxes"]["dev"]["running"])


class GitHubPolicyApplyTests(_LocalModeGitHubBase):
    """Blocker 3: `msw app github-policy-apply` — full policy on stdin, strict
    validation, transport provisioned BEFORE one atomic policy commit, typed
    rollback on partial failure, idempotent."""

    def tearDown(self) -> None:
        # Transport provisioning spawns real shuttle processes per workspace;
        # tear them down so the suite leaves no stray background processes.
        for box in ("dev", "playgrounds", "personal"):
            pidfile = self.env.home / ".local/state/msw" / f"shuttle-{box}.pid"
            if pidfile.exists():
                pid = pidfile.read_text().strip()
                if pid.isdigit():
                    try:
                        os.kill(int(pid), signal.SIGTERM)
                    except ProcessLookupError:
                        continue
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        try:
                            os.kill(int(pid), 0)
                        except ProcessLookupError:
                            break
                        time.sleep(0.1)
                    else:
                        try:
                            os.kill(int(pid), signal.SIGKILL)
                        except ProcessLookupError:
                            pass
        super().tearDown()

    def _apply(self, payload: dict, *, check: bool = True, extra_env: dict | None = None,
               input_text: str | None = None, probe: bool = True):
        """probe=True simulates the bounded transport readiness probe with the
        expected deny code (the fake msb stubs the relay, so the full
        relay->shuttle->proxy path is only exercised by the real-fixture test)."""
        env = dict(extra_env or {})
        if probe:
            env.setdefault("MSW_FAKE_TRANSPORT_PROBE", "403")
        return self.env.msw("app", "github-policy-apply", "--format", "json",
                            input_text=input_text if input_text is not None else json.dumps(payload),
                            check=check, extra_env=env, timeout=180)

    def test_policy_apply_provisions_transport_and_commits_once(self) -> None:
        desired = {"schemaVersion": 1, "workspaces": {
            "dev": {"repos": [{"canonical": "acme/demo", "mode": "read-write"}]},
            "playgrounds": {"repos": [{"canonical": "acme/toolkit", "mode": "read-only"}]},
        }}
        proc = self._apply(desired)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        result = json.loads(proc.stdout)
        self.assertTrue(result["ok"])
        self.assertEqual(result["command"], "github-policy-apply")
        data = result["result"]
        self.assertTrue(data["applied"])
        self.assertTrue(data["provisioned"])
        self.assertTrue(data["committed"])
        workspaces = {w["workspace"]: w for w in data["workspaces"]}
        self.assertEqual(workspaces["dev"]["repos"], [{"canonical": "acme/demo", "mode": "read-write"}])
        self.assertEqual(workspaces["playgrounds"]["repos"], [{"canonical": "acme/toolkit", "mode": "read-only"}])
        self.assertRegex(workspaces["dev"]["capability"], r"^[0-9a-f]{48}$")
        self.assertRegex(workspaces["playgrounds"]["capability"], r"^[0-9a-f]{48}$")
        # the policy file is the committed full desired state
        policy = json.loads(self.policy_path.read_text())
        self.assertEqual(policy["schemaVersion"], 1)
        self.assertEqual(set(policy["workspaces"]), {"dev", "playgrounds"})
        self.assertEqual(policy["workspaces"]["dev"]["capability"], workspaces["dev"]["capability"])
        # transport was provisioned: the shuttle is running per workspace
        for box in ("dev", "playgrounds"):
            pidfile = self.env.home / ".local/state/msw" / f"shuttle-{box}.pid"
            self.assertTrue(pidfile.exists(), f"{box} shuttle pidfile missing")
            pid = pidfile.read_text().strip()
            self.assertRegex(pid, r"^[0-9]+$")
        # exactly one commit in the journal (started + committed, no failed)
        journal = (self.github_meta_dir / "policy-journal.jsonl").read_text()
        self.assertIn('"status":"started"', journal)
        self.assertIn('"status":"committed"', journal)
        self.assertNotIn('"status":"failed"', journal)

    def test_policy_apply_idempotent_preserves_capabilities(self) -> None:
        desired = {"schemaVersion": 1, "workspaces": {
            "dev": {"repos": [{"canonical": "acme/demo", "mode": "read-only"}]},
            "playgrounds": {"repos": []},
            "personal": {"repos": []},
        }}
        proc = self._apply(desired)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        cap = json.loads(proc.stdout)["result"]["workspaces"][0]["capability"]
        # same request again: same capabilities, success, one more commit
        proc = self._apply(desired)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        data = json.loads(proc.stdout)["result"]
        self.assertTrue(data["applied"])
        self.assertEqual([w["capability"] for w in data["workspaces"] if w["workspace"] == "dev"][0], cap)

    def test_policy_apply_full_object_touches_only_changed_non_empty_and_restores_lifecycle(self) -> None:
        """The app sends all three keys, but that must not provision all
        three. Empty changes are policy-only and a temporarily started VM is
        restored to its prior stopped lifecycle before activation."""
        self.empty_policy()
        for box in ("dev", "playgrounds", "personal"):
            self.env.msw("stop", box)
        desired = {"schemaVersion": 1, "workspaces": {
            "dev": {"repos": [{"canonical": "acme/demo", "mode": "read-only"}]},
            "playgrounds": {"repos": []},
            "personal": {"repos": []},
        }}
        proc = self._apply(
            desired,
            extra_env={"MSW_FAKE_APPLY_PROVISION_FAIL": "playgrounds"},
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        state = self.env.state()
        self.assertFalse(state["sandboxes"]["dev"]["running"])
        self.assertFalse(state["sandboxes"]["playgrounds"]["running"])
        self.assertFalse(state["sandboxes"]["personal"]["running"])

        # Clearing dev is a semantic change but has no non-empty transport to
        # provision. Injecting failure for dev therefore cannot affect it.
        cleared = {"schemaVersion": 1, "workspaces": {
            "dev": {"repos": []},
            "playgrounds": {"repos": []},
            "personal": {"repos": []},
        }}
        proc = self._apply(cleared, extra_env={"MSW_FAKE_APPLY_PROVISION_FAIL": "dev"})
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_policy_apply_cancellation_restores_lifecycle_preserves_policy_and_releases_locks(self) -> None:
        self.empty_policy()
        self.env.msw("stop", "dev")
        before = self.policy_path.read_bytes()
        desired = {"schemaVersion": 1, "workspaces": {
            "dev": {"repos": [{"canonical": "acme/demo", "mode": "read-only"}]},
            "playgrounds": {"repos": []},
            "personal": {"repos": []},
        }}
        pause = self.env.root / "apply-provision-pause"
        reached = self.env.root / "apply-provision-pause-reached"
        pause.touch()
        env = self.env.env.copy()
        env["MSW_FAKE_APPLY_PROVISION_PAUSE_FILE"] = str(pause)
        env["MSW_FAKE_APPLY_PROVISION_PAUSE_REACHED"] = str(reached)
        env["MSW_FAKE_TRANSPORT_PROBE"] = "403"
        proc = subprocess.Popen(
            [str(self.env.msw_bin), "app", "github-policy-apply", "--format", "json"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=env, start_new_session=True)
        assert proc.stdin is not None
        proc.stdin.write(json.dumps(desired))
        proc.stdin.close()
        try:
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline and not reached.exists():
                time.sleep(0.05)
            self.assertTrue(reached.exists(), "apply never reached the provisioning cancellation seam")
            self.assertTrue(self.env.state()["sandboxes"]["dev"]["running"])
            os.killpg(proc.pid, signal.SIGTERM)
            proc.wait(timeout=90)
            self.assertNotEqual(proc.returncode, 0)
            self.assertFalse(self.env.state()["sandboxes"]["dev"]["running"])
            self.assertEqual(self.policy_path.read_bytes(), before)
            journal = (self.github_meta_dir / "policy-journal.jsonl").read_text()
            self.assertIn('"status":"cancelled"', journal)

            # A follow-up apply can immediately acquire all three locks.
            follow_up = self._apply({"schemaVersion": 1, "workspaces": {
                "dev": {"repos": []}, "playgrounds": {"repos": []}, "personal": {"repos": []},
            }})
            self.assertEqual(follow_up.returncode, 0, follow_up.stdout + follow_up.stderr)
        finally:
            pause.unlink(missing_ok=True)
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait(timeout=30)
            if proc.stdout is not None:
                proc.stdout.close()
            if proc.stderr is not None:
                proc.stderr.close()

    def test_policy_apply_partial_failure_rolls_back_policy(self) -> None:
        before = "BEFORE_POLICY"
        self.policy_path.parent.mkdir(parents=True, exist_ok=True)
        self.policy_path.write_text(before)
        desired = {"schemaVersion": 1, "workspaces": {
            "dev": {"repos": [{"canonical": "acme/demo", "mode": "read-write"}]},
            "playgrounds": {"repos": [{"canonical": "acme/toolkit", "mode": "read-only"}]},
        }}
        proc = self._apply(desired, check=False, extra_env={"MSW_FAKE_APPLY_PROVISION_FAIL": "dev"})
        self.assertEqual(proc.returncode, 77, proc.stdout + proc.stderr)
        err = json.loads(proc.stdout)["error"]
        self.assertEqual(err["code"], "MSW_TRANSPORT_PROVISION_FAILED")
        self.assertTrue(err["retryable"])
        # rollback: the policy file is byte-identical to the pre-apply state
        self.assertEqual(self.policy_path.read_text(), before)
        # the OTHER workspace's transport was still provisioned (dev failed
        # before any provisioning; playgrounds came first? order is
        # dev<playgrounds — dev fails first, so playgrounds never ran).
        # Order is fixed dev -> playgrounds, so dev's failure means
        # playgrounds was NOT provisioned; re-apply after clearing the seam
        # must succeed and provision everything.
        proc = self._apply(desired)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(json.loads(proc.stdout)["result"]["committed"], True)

    def test_policy_apply_transport_probe_broken_typed_and_untouched(self) -> None:
        """Re-review item 3: transport readiness is validated with the expected
        `<repo>.git/info/refs` request shape where `service=` is intentionally
        omitted; a malformed/broken proxy request fails readiness as
        `MSW_TRANSPORT_VERIFY_FAILED` and leaves policy untouched."""
        before = "BEFORE_POLICY"
        self.policy_path.parent.mkdir(parents=True, exist_ok=True)
        self.policy_path.write_text(before)
        desired = {"schemaVersion": 1, "workspaces": {
            "dev": {"repos": [{"canonical": "acme/demo", "mode": "read-write"}]},
        }}
        proc = self._apply(desired, check=False, probe=False,
                           extra_env={"MSW_FAKE_TRANSPORT_PROBE": "fail"})
        self.assertEqual(proc.returncode, 77, proc.stdout + proc.stderr)
        err = json.loads(proc.stdout)["error"]
        self.assertEqual(err["code"], "MSW_TRANSPORT_VERIFY_FAILED")
        self.assertTrue(err["retryable"])
        self.assertEqual(self.policy_path.read_text(), before)

    def test_policy_apply_transport_probe_wrong_codes_fail(self) -> None:
        """Re-review item 3: transport readiness depends on a fixed bare
        `info/refs` probe request (no `service=`). A `403` response for that
        request shape is expected; 200/404/500/503 or any other non-403 response
        fails as `MSW_TRANSPORT_VERIFY_FAILED`, leaving policy untouched."""
        desired = {"schemaVersion": 1, "workspaces": {
            "dev": {"repos": [{"canonical": "acme/demo", "mode": "read-write"}]},
        }}
        for code in ("200", "404", "500", "503"):
            before = f"BEFORE_POLICY_{code}"
            self.policy_path.parent.mkdir(parents=True, exist_ok=True)
            self.policy_path.write_text(before)
            proc = self._apply(desired, check=False, probe=False,
                               extra_env={"MSW_FAKE_TRANSPORT_PROBE": code})
            self.assertEqual(proc.returncode, 77, (code, proc.stdout, proc.stderr))
            err = json.loads(proc.stdout)["error"]
            self.assertEqual(err["code"], "MSW_TRANSPORT_VERIFY_FAILED", code)
            self.assertEqual(self.policy_path.read_text(), before, code)
        # 403 for the malformed bare `info/refs` request is the expected readiness
        # signal for the missing `service=` request shape.
        self.policy_path.write_text("BEFORE_POLICY_403_OK")
        proc = self._apply(desired, probe=False,
                           extra_env={"MSW_FAKE_TRANSPORT_PROBE": "403"})
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertTrue(json.loads(proc.stdout)["result"]["committed"])

    def test_policy_apply_transport_probe_real_fixture(self) -> None:
        """Re-review item 3: the bounded readiness probe runs against a REAL
        proxy (bin/msw-github-proxy --listen) via a real guest HTTP request
        carrying the desired capability; the proxy answers with the expected
        403 (uncommitted capability) and the apply then commits."""
        self.empty_policy()  # valid policy; the apply's capabilities are not
        # committed yet, so the probe is denied by the proxy (expected 403)
        err_path = self.env.root / "apply-proxy.err"
        err = err_path.open("ab")
        proxy_env = self.env.env.copy()
        proxy_env.update({
            "MSW_GITHUB_MODE": "local",
            "MSW_POLICY_FILE": str(self.policy_path),
            "MSW_PROXY_LOG_FILE": str(self.env.root / "apply-proxy.log"),
            "MSW_HOST_KEYCHAIN_SERVICE": HOST_KEYCHAIN_SERVICE,
            "MSW_HOST_KEYCHAIN_ACCOUNT": HOST_KEYCHAIN_ACCOUNT,
            "MSW_TEST_KEYCHAIN_DIR": str(self.env.root / "keychain"),
        })
        proxy_proc = subprocess.Popen([str(PROXY_BIN), "--listen", "0"],
                                      env=proxy_env, cwd=str(PACKAGE),
                                      stdout=subprocess.PIPE, stderr=err, text=True)
        try:
            assert proxy_proc.stdout is not None
            deadline = time.monotonic() + 30
            port = None
            while time.monotonic() < deadline:
                if proxy_proc.poll() is not None:
                    break
                ready, _, _ = select.select([proxy_proc.stdout], [], [], 0.5)
                if not ready:
                    continue
                line = proxy_proc.stdout.readline()
                m = re.match(r"PROXY_READY port=(\d+)", line)
                if m:
                    port = int(m.group(1))
                    break
            self.assertIsNotNone(port, "real proxy fixture did not become ready")
            desired = {"schemaVersion": 1, "workspaces": {
                "dev": {"repos": [{"canonical": "acme/demo", "mode": "read-write"}]},
            }}
            proc = self._apply(desired, probe=False,
                               extra_env={"MSW_TRANSPORT_PROBE_PORT": str(port)})
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            result = json.loads(proc.stdout)["result"]
            self.assertTrue(result["provisioned"])
            self.assertTrue(result["committed"])
            # the proxy actually served the probe request with the expected
            # 403 deny (capability not yet committed)
            log = (self.env.root / "apply-proxy.log").read_text()
            self.assertIn('"status": 403', log, log)
            self.assertIn("github.com/acme/demo.git/info/refs", log, log)
        finally:
            proxy_proc.terminate()
            try:
                proxy_proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proxy_proc.kill()
                proxy_proc.wait(timeout=5)
            if proxy_proc.stdout is not None:
                proxy_proc.stdout.close()
            try:
                err.close()
            except OSError:
                pass

    def test_policy_apply_locks_protect_omitted_workspaces(self) -> None:
        """Re-review item 2: the apply locks ALL THREE workspaces before the
        snapshot, so a concurrent per-repo edit of an OMITTED workspace is
        serialized (rejected) and can never be resurrected into the final
        policy."""
        desired = {"schemaVersion": 1, "workspaces": {
            "dev": {"repos": [{"canonical": "acme/demo", "mode": "read-write"}]},
        }}
        pause = self.env.root / "apply-pause"
        reached = self.env.root / "apply-pause-reached"
        pause.touch()
        env = self.env.env.copy()
        env["MSW_FAKE_APPLY_PAUSE_FILE"] = str(pause)
        env["MSW_FAKE_APPLY_PAUSE_REACHED"] = str(reached)
        env.setdefault("MSW_FAKE_TRANSPORT_PROBE", "403")
        proc = subprocess.Popen(
            [str(self.env.msw_bin), "app", "github-policy-apply", "--format", "json"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=env)
        assert proc.stdin is not None
        proc.stdin.write(json.dumps(desired))
        proc.stdin.close()
        try:
            # wait until the apply is PARKED at the pause with all locks held
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline and not reached.exists():
                time.sleep(0.05)
            self.assertTrue(reached.exists(), "apply never reached the pause point")
            # personal is OMITTED from the apply; a concurrent per-repo edit
            # of personal must be refused while the apply holds the locks
            set_proc = self.env.msw("app", "github-policy-set", "--workspace", "personal",
                                    "--repository", "acme/other", "--mode", "read-write",
                                    "--format", "json", check=False)
            self.assertEqual(set_proc.returncode, 73, set_proc.stdout + set_proc.stderr)
            err = json.loads(set_proc.stdout)["error"]
            self.assertEqual(err["code"], "MSW_OPERATION_CONFLICT")
            pause.unlink()
            proc.wait(timeout=120)
            assert proc.stdout is not None and proc.stderr is not None
            out = proc.stdout.read()
            err_out = proc.stderr.read()
            self.assertEqual(proc.returncode, 0, out + err_out)
            result = json.loads(out)["result"]
            self.assertTrue(result["committed"])
            # final policy is exactly the apply's full desired state; the
            # concurrent set never landed (personal omitted -> cleared)
            policy = json.loads(self.policy_path.read_text())
            self.assertEqual(set(policy["workspaces"]), {"dev"})
            self.assertNotIn("acme/other",
                             json.dumps(policy.get("personal", {}).get("repos", [])))
        finally:
            pause.unlink(missing_ok=True)
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=30)
            if proc.stdout is not None:
                proc.stdout.close()
            if proc.stderr is not None:
                proc.stderr.close()

    def test_policy_apply_invalid_request_typed_error(self) -> None:
        for bad in (
            "not json",
            json.dumps({"schemaVersion": 2, "workspaces": {}}),
            json.dumps({"schemaVersion": 1, "workspaces": {
                "dev": {"repos": [{"canonical": "Acme/Demo", "mode": "read-only"}]}}}),
            json.dumps({"schemaVersion": 1, "workspaces": {
                "dev": {"repos": [{"canonical": "acme/demo", "mode": "bogus"}]}}}),
            json.dumps({"schemaVersion": 1, "workspaces": {
                "dev": {"repos": [
                    {"canonical": "acme/demo", "mode": "read-only"},
                    {"canonical": "acme/demo", "mode": "read-write"}]}}}),
            json.dumps({"schemaVersion": 1, "workspaces": {"evil": {"repos": []}}}),
        ):
            proc = self._apply(bad, check=False, input_text=bad)
            self.assertEqual(proc.returncode, 64, (bad, proc.stdout, proc.stderr))
            self.assertEqual(json.loads(proc.stdout)["error"]["code"], "MSW_INVALID_REQUEST", bad)
        self.assertFalse(self.policy_path.exists())

    def test_policy_apply_connect_mode_mismatch(self) -> None:
        desired = {"schemaVersion": 1, "workspaces": {"dev": {"repos": []}}}
        proc = self._apply(desired, check=False, extra_env={"MSW_GITHUB_MODE": "connect"})
        self.assertEqual(proc.returncode, 69)
        self.assertEqual(json.loads(proc.stdout)["error"]["code"], "MSW_GITHUB_MODE_MISMATCH")
        self.assertFalse(self.policy_path.exists())


if __name__ == "__main__":
    ReleaseBase.create()
    try:
        unittest.main(verbosity=2)
    finally:
        shutil.rmtree(ReleaseBase.root, ignore_errors=True)
