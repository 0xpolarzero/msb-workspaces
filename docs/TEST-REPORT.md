# MSW 3.1.0 verification report

Verification is split between the native MSW Monitor app and the portable `msw` release suite. The Connect authorization contract is exercised by the app's Swift unit tests; the portable suite covers installer, VM lifecycle, local Git, host-only push, backup/restore, and security behavior.

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

- Live-service limit: the configured MSW Connect endpoint was unavailable from this machine during probing (DNS resolution failed). Deterministic transport tests cover successful authorization, unavailable callback exchange, scope validation, and verified Connect-to-Apply rollback; no real GitHub account or credential was used.

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

### GitHub authorization and host-only push

- Connect authorization validates the callback state, session expiry, service issuer, client identity, redirect URI, and callback payload before accepting a grant.
- Account, installation owner, repository IDs/names, role, expiry, and scope digest are verified before a workspace assignment is committed.
- Guest-read and host-write capabilities remain distinct; a grant for one workspace cannot be reused for another workspace or repository set.
- Assignment writes are transactional: a failed service commit, credential write, or scope validation leaves the previous usable state intact or marks the workspace for explicit recovery.
- Reauthorization and expiry use explicit `Needs authorization`, `Needs restart`, `Revoked`, and `Quarantined` recovery states; the app never silently restarts a running VM.
- Disconnect/revocation removes the VM-held secret before revoking the service grant and local metadata; if cleanup or revocation is uncertain, the workspace remains quarantined.
- The legacy CLI token prompt reports the MSW Monitor migration path and never reads, stores, or forwards a pasted token.
- Guest secret substitution remains limited to `github.com` and `api.github.com`; the guest sees only the MicroSandbox placeholder.
- Host-only push still transfers only the current committed branch, enforces fast-forward or exact lease-protected force updates, and isolates host Git configuration.
- Git LFS object IDs, file types, and SHA-256 contents are verified on the host.
- Quarantined workspace access fails closed until the recovery state is resolved.

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

- The guest receives only the selected read capability; the actual service-issued credential is absent from simulated VM state and the MicroSandbox placeholder is all the guest can inspect.
- The host-write credential is retrieved only by the host push path from macOS Keychain, including when host Git runs with an isolated temporary `HOME`.
- The privileged push process uses an empty environment, temporary home, no system/global Git config, no custom hooks, no SSH agent, and no ambient GitHub token.
- Assignment and push authorization require the workspace, role, owner, installation, repository set, expiry, and scope metadata to match.
- Disconnect/revocation fails closed before any uncertain cleanup can leave a usable workspace authorization.
- Failed grant commit or cleanup leaves explicit recovery state; it never silently restores an unvalidated credential.
- Git bundles are verified and checked against the exact guest commit before push.
- Git LFS object IDs, file types, and SHA-256 contents are verified on the host.
- Keychain deletion accepts only an explicit missing-item result or confirmed removal; other failures abort the transaction.
- Normal Docker cleanup never deletes volumes unless explicitly requested.
- Backups exclude macOS Keychain tokens and remove partial output on failure.

## Environment boundaries

### Portable simulator coverage

The portable simulator suite cannot instantiate Apple's Virtualization framework, alter macOS loopback/LaunchDaemon state, access macOS Keychain, open Ghostty/Zed, or contact GitHub with real credentials. It validates the packaged shell/Python behavior, state transitions, local Git flows, and security boundaries using simulated MicroSandbox state, a fake `security(1)` command, and local remotes.

### Real macOS canary

A prior real Apple Silicon macOS canary against MicroSandbox v0.6.8 independently passed VM startup, systemd, Docker/containerd, SSH, GitHub connectivity, and published-port checks. This is historical evidence, not part of the current 2026-08-14 run; current verification used no GitHub credentials and the configured Connect endpoint was unavailable from this machine.

## The only checks you need to run

### 1. Install

```bash
./setup.sh
```

The installer ends by running `msw check --deep`. Continue only when it reports:

```text
all live VM, Docker, SSH, internet, and published-port checks passed
```

### 2. Connect each GitHub trust domain

Open **MSW Monitor** → **Settings** → **GitHub** → **Connect GitHub**. Complete authorization, select the owner and repositories, review the scoped guest-read/host-write grants, and apply them for each workspace that needs GitHub.

Do not run `msw github setup`; the former token prompt is removed and the CLI reports the MSW Monitor migration path instead.

The user-side verification set is the installer deep check plus the app build, Swift tests, and UI smoke test. The Connect flow must leave each assignment in an explicit `Ready`, `Needs authorization`, `Needs restart`, `Revoked`, or `Quarantined` state.

## Re-running the portable test suite

Optional, not required for normal installation:

```bash
./tests/run-tests.sh
```

The suite uses temporary directories, simulated MicroSandbox state, and local Git remotes. It does not use your production VMs or GitHub credentials.
