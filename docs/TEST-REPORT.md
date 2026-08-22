# MSW 3.1.0 verification report

Verification is split between the native MSW Monitor app and the portable `msw` release suite. Local mode (`MSW_GITHUB_MODE=local`) is the default and the Connect service is dormant in this build; the current GitHub acceptance covers the proxy transport, host credential, and policy tests (portable suite, against a fake GitHub) plus the app build, Swift unit tests, and UI smoke test. The portable suite also covers installer, VM lifecycle, local Git, host-only push, backup/restore, and security behavior.

The token-prompt GitHub setup scenarios described in older release reports are historical. The legacy `msw github setup` surface is removed and must not be treated as a supported setup or rotation path.

Run the app checks after source changes:

```bash
app/MSWMonitor/Scripts/build.sh
app/MSWMonitor/Scripts/test.sh
app/MSWMonitor/Scripts/smoke-test.sh
```

The smoke flow proves the app bundle and status-item/popover UI. The app's workspace state and observation counter remain deterministic fixture values; they are not live sandbox telemetry.

## Native macOS app evidence

- Bundle exercised: `app/MSWMonitor/build/MSWMonitor.app`.
- UI smoke mode: `--ui-test-open-popover`; production mode remains `.transient`.
- UI result bundle: `app/MSWMonitor/build/DerivedData/Smoke/Logs/Test/Test-MSWMonitor-2026.08.14_14-54-25-+0200.xcresult`.
- Complete UI output: `app/MSWMonitor/build/logs/smoke-ui.log`.
- Result: all 3 `MSWMonitorUITests` cases passed with zero failures (`testSetupCanReviewAndFinishInFixtureMode()`, `testSetupReviewExplainsCompletionState()`, and `testStatusItemPopoverRefreshAndQuit()`).
  - Model suite: `app/MSWMonitor/Scripts/test.sh` passed 54 tests with zero failures. Result: `app/MSWMonitor/build/DerivedData/Tests/Logs/Test/Test-MSWMonitor-2026.08.14_14-53-55-+0200.xcresult`.
- Observed semantic values:
  - `statusItem.button`: accessibility label `MSW Monitor`.
  - Application menu title: `MSW Monitor`.
  - Application menu items: `About MSW Monitor`, `Settings…`, `Hide MSW Monitor`, and `Quit MSW Monitor`.
  - `monitor.title`: `MSW Monitor`.
  - `workspace.dev.name/state`: `dev` / `Stopped`.
  - `workspace.playgrounds.name/state`: `playgrounds` / `Stopped`.
  - `workspace.personal.name/state`: `personal` / `Stopped`.
  - `observation.value`: `Not yet refreshed`, then `Observation #1` after `refresh.button` (`Refresh`).
  - `quit.button`: `Quit`; the app reached `notRunning`.
- Cleanup: the app was quit through the UI, and the subsequent `pgrep -x MSWMonitor` check returned no remaining instance.
- Unified-log queries actually run after the smoke test used `log show --last 3m --style compact --info --debug` (a three-minute window):
  - `process == "MSWMonitor"`
  - `process == "MSWMonitor" AND (messageType == error OR messageType == fault)`
  No narrower wall-clock interval was recorded. These logs are framework diagnostics; the app has no intentional application-level logger.

- Live-service limit: historical — the configured MSW Connect endpoint was unavailable from this machine during probing (DNS resolution failed), and Connect is dormant in the current build. Current GitHub verification is local mode: the proxy contract and integration suites run against `tests/fake_github.py`; no real GitHub account or credential was used.

The native app values above are deterministic fixture values from the current scaffold, not live sandbox telemetry. The smoke test does not prove VM health, `msw` integration, lifecycle actions, telemetry, signing, notarization, or release readiness.

## Automated coverage

### Syntax and release invariants — 3 scenarios

- Bash syntax for installer, CLI, bootstrap, SSH proxy, and askpass helper.
- Python compilation for simulators.
- Bash 3.2 compatibility checks.
- Published-port configuration and duplicate prevention.
- Documentation consistency and stale-command detection.
- Host Git isolation invariants.
- Exact force-with-lease construction.
- LFS SHA-256 verification.
- No SSH-agent forwarding or host Docker-socket sharing.
- Read secret limited to the configured GitHub hosts.
- Current `msb self update` command path.

### Installer and daily operation — 11 scenarios

- Fresh installation of all three workspaces, six persistent volumes, common snapshot, resources, labels, and fixed port maps.
- Idempotent installer rerun.
- VM-root recreation while preserving repository and Docker volumes.
- Version migration while preserving both persistent data volumes.
- Config reset and base-snapshot rebuild.
- Published URLs, browser open, Zed URI, Ghostty/SSH shell, and temporary tunnel flows.
- Tunnel-port rejection for invalid, zero, and out-of-range values.
- Docker cleanup preserving volumes unless `--volumes` is explicit.
- Supported MicroSandbox self-update flow.
- Start, stop, restart, resize, missing-token guard, and SSH proxy behavior.
- Nested clone paths, direct in-VM cloning, repository listing, identity, fast-forward pull, path containment, and duplicate-destination rejection.

### GitHub proxy, transport, credential, and policy (local mode)

Current acceptance — `GitHubProxyContractTests` (proxy direct) and
`GitHubProxyTests` (CLI-driven integration, local mode), backed by
`tests/fake_github.py` (stateful fake GitHub with git smart-HTTP, `/user`,
`/repos/{o}/{r}` permissions, and LFS batch/object endpoints):

- INGRESS-1: real >1 MiB git push, chunked end-to-end through the proxy.
- INGRESS-2: ~100 MB Git LFS round-trip (batch and object endpoints).
- INGRESS-3: a chunked body over the size cap is killed mid-stream, the
  upstream is torn down, and the next request succeeds.
- INGRESS-4: Content-Length + Transfer-Encoding, duplicate Content-Length,
  stacked Transfer-Encoding, and unknown TE codings are rejected pre-auth with
  the upstream untouched.
- TIMEOUT-1: idle timeout and total deadline tear down both legs.
- REGRESS-1: CVE-2025-43859 malformed post-chunk-CRLF payload classes (x3) are
  rejected pre-auth with the upstream untouched.
- REGRESS-2: the vendored h11 `__version__` is `>= 0.16.0` (read from the
  module) and VENDORED.md records the advisory check.
- SMUGGLE matrix (13 framing cases), policy matrix (read-only/read-write/
  unticked/unknown-workspace/missing/malformed policy), identity spoofing
  (workspace A's capability on workspace B), and canonicalization attacks
  (case, `.git`, double-slash, percent-encoding, trailing dot, redirects).
- No-credential-in-guest assertions (the guest holds no GitHub token at all)
  and backup exclusion of the host-credential record.
- Host-only push transfers only the current committed branch, enforces
  fast-forward or exact lease-protected force updates, and isolates host Git
  configuration; the privileged push process uses an empty environment,
  temporary home, no custom hooks, no SSH agent, and no ambient GitHub token.
- Git LFS object IDs, file types, and SHA-256 contents are verified on the
  host.
- Quarantined workspace access fails closed until the recovery state is
  resolved.

Historical (Connect-era, exercised by the app's Swift unit tests; Connect is
dormant in this build): callback state/session/issuer/client/redirect
validation, scoped assignment verification, distinct guest-read/host-write
grants, transactional assignment writes, `Needs authorization`/`Needs
restart`/`Revoked`/`Quarantined` recovery states, and the legacy CLI token
prompt reporting the migration path without reading a pasted token.

### Backup and restore — 6 scenarios

- Cold backup restoring only the previously running VM set and excluding Keychain credentials.
- Full backup/restore of workspace files, Docker runtime data, and MSW configuration.
- Corrupt-checksum rejection before mutation.
- Rejection of traversal, duplicate, incomplete, unexpected, and absolute-symlink archive content.
- Failed restored-state health check rolling back to the previous installation.
- Interrupted/failing compression restarting prior VMs and leaving no partial archive.

### Packaged behavior — 1 scenario

- Help, version, and installed documentation without a functioning `msb` binary.
- Complete simulated `msw check --deep` covering each VM, Docker Engine, Compose bind mounts, SSH, public internet, direct process port publication, and Docker-published port publication.
- Health-test process/container cleanup.

## Security properties exercised

- The guest holds no GitHub credential at all; its only identity is the per-workspace capability sent to the host proxy, and local mode asserts the guest has no token anywhere in VM state.
- The host credential is retrieved from macOS Keychain only by the proxy's outbound leg and the host push path, including when host Git runs with an isolated temporary `HOME`.
- The privileged push process uses an empty environment, temporary home, no system/global Git config, no custom hooks, no SSH agent, and no ambient GitHub token.
- Push authorization requires the canonical repository to be on the workspace's ticked list and the host credential to be available; VM-initiated push additionally requires the repository ticked as **read-write**, enforced by the proxy's receive-pack rules.
- Credential revocation fails closed before any uncertain cleanup can leave a usable authorization.
- Failed policy write or credential cleanup leaves explicit recovery state; it never silently restores an unvalidated credential.
- Git bundles are verified and checked against the exact guest commit before push.
- Git LFS object IDs, file types, and SHA-256 contents are verified on the host.
- Keychain deletion accepts only an explicit missing-item result or confirmed removal; other failures abort the transaction.
- Normal Docker cleanup never deletes volumes unless explicitly requested.
- Backups exclude macOS Keychain tokens and remove partial output on failure.

## Environment boundaries

### Portable simulator coverage

The portable simulator suite cannot instantiate Apple's Virtualization framework, alter macOS loopback/LaunchDaemon state, access macOS Keychain, open Ghostty/Zed, or contact GitHub with real credentials. It validates the packaged shell/Python behavior, state transitions, local Git flows, and security boundaries using simulated MicroSandbox state, a fake `security(1)` command, and local remotes.

### Real macOS canary

A prior real Apple Silicon macOS canary against MicroSandbox v0.6.8 independently passed VM startup, systemd, Docker/containerd, SSH, GitHub connectivity, and published-port checks. This is historical evidence, not part of the current run; current verification used no GitHub credentials (local mode; the Connect service is dormant).

## The only checks you need to run

### 1. Install

```bash
./setup.sh
```

The installer ends by running `msw check --deep`. Continue only when it reports:

```text
all live VM, Docker, SSH, internet, and published-port checks passed
```

### 2. Configure GitHub in local mode

Open **MSW Monitor** → **Settings** → **GitHub**, connect the account on this
Mac, tick the repositories each workspace may use (new assignments default to
**Clone/pull (push from Mac)**), and toggle **Clone/pull + Push from VM** only
where VM-initiated push is needed. Local editing and commits always work; host
push (`msw push` or the app's Push button) works for every selected
repository, and no GitHub credential enters any workspace.

The user-side verification set is the installer deep check plus the app build,
Swift tests, and UI smoke test, and the proxy/transport/credential/policy
contract suite passing (see the GitHub coverage section above).

## Re-running the portable test suite

Optional, not required for normal installation:

```bash
./tests/run-tests.sh
```

The suite uses temporary directories, simulated MicroSandbox state, and local Git remotes. It does not use your production VMs or GitHub credentials.
