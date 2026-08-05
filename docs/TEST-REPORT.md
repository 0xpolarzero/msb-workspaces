# MSW 3.1.0 test report

## Result

**35 automated release scenarios passed.** The suite drives the actual packaged `setup.sh` and installed `msw` CLI against a stateful MicroSandbox simulator, while using real local Git repositories and bare remotes for clone, fetch, pull, bundle, push, force-with-lease, and Git LFS behavior.

After the final least-privilege change to restrict guest-token substitution to `github.com` and `api.github.com`, and after adding strict 1–65535 tunnel-port validation, every directly affected scenario was rerun successfully. The exact packaged archive is also extracted into a clean directory and subjected to syntax, documentation, installation, GitHub-boundary, and deep-check smoke tests before release.

## Automated coverage

### Syntax and release invariants — 2 scenarios

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

### GitHub and host-only push — 15 scenarios

- Complete GitHub setup transaction: read token binding, guest push rejection, host push success, temporary-branch cleanup, token secrecy, status, and removal.
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
- The write token is retrieved only by the host askpass helper from macOS Keychain.
- The privileged push process uses an empty environment, temporary home, no system/global Git config, no custom hooks, no SSH agent, and no ambient GitHub token.
- Git bundles are verified and checked against the exact guest commit before push.
- Git LFS object IDs, file types, and SHA-256 contents are verified on the host.
- GitHub setup and restore are transactional and roll back on failure.
- Normal Docker cleanup never deletes volumes unless explicitly requested.
- Backups exclude macOS Keychain tokens and remove partial output on failure.

## What cannot be reproduced in this Linux execution environment

The release environment cannot instantiate Apple's Virtualization framework, alter macOS loopback/LaunchDaemon state, access macOS Keychain, open Ghostty/Zed, or contact GitHub with your real tokens.

Those interfaces are tested automatically on your Mac by the normal setup commands; no separate manual test plan is required.

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
