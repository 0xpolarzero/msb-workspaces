# MSW 3.1.0 test report

## Result

**52 automated release scenarios passed.** The suite drives the actual packaged `setup.sh` and installed `msw` CLI against a stateful MicroSandbox simulator, while using real local Git repositories and bare remotes for clone, fetch, pull, bundle, push, force-with-lease, and Git LFS behavior.

The release suite covers strict 1–65535 tunnel-port validation, GitHub least-privilege boundaries, transactional Keychain cleanup, host-write metadata authorization, stale-token rejection in read-only workspaces, fail-closed `security(1)` deletion handling, metadata revocation before fallible credential cleanup, rollback safety when credential deletion fails, interruption-safe setup transactions, and fail-closed workspace quarantine. The exact packaged archive is also extracted into a clean directory and subjected to syntax, documentation, installation, GitHub-boundary, and deep-check smoke tests before release.

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

### GitHub and host-only push — 31 scenarios

- TLS-interception preflight rejects incompatible workspaces before token prompts or Keychain mutation and gives the recreation command.
- Complete GitHub setup transaction: read token binding, guest push rejection, host push success, temporary-branch cleanup, token secrecy, status, and removal.
- Verifier subprocesses retain the host-side read-token source required for MicroSandbox secret substitution during guest exec, clone, and cleanup commands.
- Fresh `msw clone`, `msw exec`, SSH proxy, and `msw github remove` invocations source the read token from Keychain independently of the setup process lifetime.
- Installer reruns and recreates GitHub-bound workspaces with secret-aware inspect, exec, remove, modify, and stop calls.
- Quarantined workspace SSH proxy access is rejected before token use or VM startup.
- Identical read/write token rejection.
- Failed verification restoring the previous working tokens and metadata.
- Detection and rollback when the guest token has write permission.
- New-branch push transferring only the current committed branch—not dirty files, tags, or other branches.
- Repeated fast-forward pushes and guest remote-tracking refresh.
- Non-fast-forward rejection followed by exact lease-protected force push.
- Concurrent remote update causing force-with-lease rejection.
- Detached HEAD, non-GitHub origin, missing host token, and user-cancel failure paths.
- Isolation from hostile host global Git configuration and hooks.
- Valid Git LFS object transfer and host-only upload.
- Invalid LFS pointer rejection.
- Missing LFS object rejection.
- Corrupted LFS transfer rejection by SHA-256.
- Symlink/nonregular LFS object rejection.
- Read-only setup retains guest read access without a host token and blocks stale write-token pushes using workspace metadata.
- Read-only conversion revokes existing host-write metadata before downgrade cleanup; failure leaves subsequent pushes blocked.
- Keychain deletion rejects delete failures, post-delete lookup failures, and still-present items while accepting explicit missing-item results.
- Remove revokes host-write metadata before credential cleanup; a failed Keychain delete leaves subsequent pushes blocked.
- Failed setup rollback revokes active metadata before credential cleanup; deletion failures leave subsequent pushes blocked.
- Failed guest-secret removal stops and quarantines the workspace so normal starts, restarts, pushes, and guest commands cannot rebind or use the secret.
- Proven-stop quarantine handling is fail-closed when ping or inspect is unavailable, or stop fails.
- Per-workspace GitHub setup/remove locks serialize credential, metadata, and quarantine mutations.
- Dead-owner recovery migrates legacy lock directories and uses kernel-held `lockf` ownership, so stale or empty lock files do not wedge future operations.
- Standalone verification blocks removal through `SIGKILL`, and an orphaned setup verifier retains the lock after its parent dies.
- An interrupted verification followed by a failed repair never restores tainted credentials or metadata and leaves the quarantine marker in place.
- Interruption coverage pauses after a completed verification clone and confirms signal cleanup removes its checkout.

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

- The real guest read token is absent from simulated VM state; only the MicroSandbox placeholder is visible in the guest.
- The write token is retrieved only by the host askpass helper from macOS Keychain, including when host Git runs with an isolated temporary `HOME`.
- The privileged push process uses an empty environment, temporary home, no system/global Git config, no custom hooks, no SSH agent, and no ambient GitHub token.
- Push authorization requires both host-write workspace metadata and the host write credential.
- Remove revokes host-write metadata before secret and Keychain cleanup, so cleanup failures cannot leave pushes authorized.
- Failed setup rollback restores old metadata only after all credential operations succeed; any rollback failure leaves the metadata gate absent.
- Failed rollback secret cleanup stops and quarantines the workspace; normal start, restart, and exec paths refuse the quarantined workspace.
- Setup writes and retains a quarantine marker before credential mutation, and clears it only after verification or a fully successful rollback.
- Git bundles are verified and checked against the exact guest commit before push.
- Git LFS object IDs, file types, and SHA-256 contents are verified on the host.
- GitHub setup and restore are transactional and roll back on failure.
- Keychain deletion accepts only an explicit missing-item result or confirmed removal; other failures abort the transaction.
- Normal Docker cleanup never deletes volumes unless explicitly requested.
- Backups exclude macOS Keychain tokens and remove partial output on failure.

## Environment boundaries

### Portable simulator coverage

The portable simulator suite cannot instantiate Apple's Virtualization framework, alter macOS loopback/LaunchDaemon state, access macOS Keychain, open Ghostty/Zed, or contact GitHub with real credentials. It validates the packaged shell/Python behavior, state transitions, local Git flows, and security boundaries using simulated MicroSandbox state, a fake `security(1)` command, and local remotes.

### Real macOS canary

A real Apple Silicon macOS run against MicroSandbox v0.6.8 independently passed VM startup, systemd, Docker/containerd, SSH, GitHub connectivity, and published-port checks. The full host setup did not complete workspace recreation: it reached browser/loopback configuration and then stopped because `sudo` requires an interactive terminal and password. Rerun `./setup.sh --recreate-workspaces` from an interactive terminal.

## The only checks you need to run

### 1. Install

```bash
./setup.sh
```

The installer ends by running `msw check --deep`. Continue only when it reports:

```text
all live VM, Docker, SSH, internet, and published-port checks passed
```

### 2. Configure each GitHub trust domain

```bash
msw github setup dev OWNER/VERIFICATION-REPO
msw github setup playgrounds OWNER/VERIFICATION-REPO
msw github setup personal OWNER/VERIFICATION-REPO
```

Each command automatically proves against GitHub that the VM can read, the VM cannot push, the Mac-only path can push, and its temporary branch can be deleted.

That is the complete user-side verification set.

## Re-running the portable test suite

Optional, not required for normal installation:

```bash
./tests/run-tests.sh
```

The suite uses temporary directories, simulated MicroSandbox state, and local Git remotes. It does not use your production VMs or GitHub credentials.
