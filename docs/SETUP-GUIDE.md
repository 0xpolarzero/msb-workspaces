# Silo setup guide

This guide installs configurable persistent MicroSandbox development workspaces on an Apple Silicon Mac. The packaged defaults are:

- `dev`
- `playgrounds`
- `personal`

The packaged defaults allow up to 80 GB of live VM memory across the default workspaces, with resize ceilings up to 128 GB. Ensure the Mac has sufficient RAM. All commands below run in Ghostty unless stated otherwise.

## 1. Install

Unzip the package and run the installer:

```bash
cd ~/Downloads
unzip silo-v3.1.0.zip
cd silo
./setup.sh
```

The installer may request your macOS administrator password to add three private loopback addresses and local browser names. It then:

1. Installs Homebrew when missing.
2. Installs GNU tar, zstd, Git LFS, the GitHub CLI (`gh`), and MicroSandbox.
3. Runs MicroSandbox diagnostics.
4. Builds one reusable Ubuntu 24.04 ARM64 development snapshot.
5. Creates every workspace in the validated schema-v1 workspace configuration (`dev`, `playgrounds`, and `personal` by default) from that snapshot.
6. Attaches a separate persistent ext4 workspace volume and Docker-runtime volume to each VM.
7. Configures Docker Engine, Compose, Buildx, Git, GitHub CLI, mise, Node LTS, pnpm, uv, Python, zsh, and common development tools.
8. Enables local TLS interception so MicroSandbox can substitute host-held secrets only at their allow-listed HTTPS endpoints.
9. Configures fixed local browser names and SSH aliases.
10. Runs `silo check --deep` against every configured VM.

When it finishes:

```bash
exec zsh -l
```

The installation is complete only when the installer prints:

```text
all live VM, Docker, SSH, internet, and published-port checks passed
```

## 2. Set your Git identity

Apply one identity to every configured workspace:

```bash
silo identity "Your Full Name" you@example.com
```

Or configure one workspace only:

```bash
silo identity "Your Full Name" work@example.com dev
```

## 3. Connect GitHub

GitHub is optional, and the GitHub credential always stays on this Mac. No
GitHub token is ever bound into a workspace. Git inside a VM reaches GitHub
through a private host-side proxy on `127.0.0.1:18446` — loopback only, with
no LAN listener — that checks every request against the workspace's capability
and repository policy. Each workspace runs one host “shuttle” bridged to a
guest relay over the existing SSH transport, so GitHub requests are checked
on the Mac and a workspace cannot mutate repositories it was not given.

### Set up access (app)

Open **Silo** → **Settings** → **GitHub**:

1. **Connect the account on this Mac.** The installer includes the GitHub CLI
   (`gh`); if it is not already signed in, run `gh auth login` once (web
   OAuth in your browser). The app reuses the authenticated `gh` session,
   verifying `GET /user` and `permissions.push` for every repository ticked
   for VM push; a Device Flow fallback is available when a client ID is
   configured. The credential is stored as one versioned record in the
   login Keychain
   (`org.silo.Silo.github-host.v2`); the token never appears in
   command arguments, logs, journals, or backups. Any pre-v2 item remains
   dormant and unread.
2. **Tick repositories per workspace.** The policy starts empty: until a
   repository is selected, that workspace cannot reach GitHub through the
   proxy. A new assignment defaults to **Clone/pull (push from Mac)**; toggle
   **Clone/pull + Push from VM** only for repositories that must accept pushes
   initiated inside the VM.
3. **Review and apply.** Nothing changes until the reviewed policy is applied.
   Policy writes are journaled and atomic; the proxy re-reads the policy on
   every request, so a mode flip applies on the next request.

The two modes mean exactly this — local editing and commits always work in
both:

| Mode | Clone/pull | Local edit & commit | Host push (`silo push`, app Push) | Push from inside the VM |
|---|---|---|---|---|
| **Clone/pull (push from Mac)** (read-only) | yes | always | yes | no |
| **Clone/pull + Push from VM** (read-write) | yes | always | yes | yes |

Host push is allowed for every selected repository in either mode. Only push
originating inside a VM is gated by the mode, enforced by the proxy's
receive-pack rules. A missing, malformed, or unknown policy entry denies
access — for the proxy and for host push alike.

GitHub API and GraphQL calls from inside a workspace are not supported in this
version; use git, or run API operations from the Mac.

### Recovery and CLI

The same surface is available from the terminal:

```bash
silo github auth [--force] [--json]          # provision or rotate the host credential
silo github status [WORKSPACE|all]           # mode, capability, repos, credential, shuttle
silo github verify WORKSPACE [OWNER/REPO]    # probe policy, capability, credential (no VM writes)
silo github remove WORKSPACE                 # revoke the host credential (fail-closed)
silo github capability rotate WORKSPACE      # mint a fresh capability; the old one is denied immediately
silo github proxy-configure [WORKSPACE]      # install or repair the proxy transport idempotently
silo github repos [--owner OWNER] [--json]   # discover repositories for the picker
silo app github-policy-set --workspace WORKSPACE --repository OWNER/REPO --mode read-only|read-write
```

Troubleshoot with `silo github status`, then `silo github verify`; repair the
transport with `silo github proxy-configure`, and rotate a compromised
credential with `silo github auth --force`. `silo check --deep` asserts that no
guest holds a `GH_TOKEN` and probes proxy reachability from the guest. Legacy
Connect-era state is retired automatically on first local-mode use as one
journaled transaction (archiving `~/.config/silo/github/<box>.conf` and proving
old guest secrets are removed); run `silo github migrate [WORKSPACE|all]` to do
it explicitly.

Connect mode (`SILO_GITHUB_MODE=connect`) remains available as a rollback
alternative; local mode is the default and never reads or writes Connect
grants.

### Host-held API secrets

Open **Silo → Secrets** to manage non-GitHub API keys. For each key,
choose its workspaces and HTTPS destinations: an exact host, `*.example.com`,
or `*`. The real value stays in macOS Keychain. The VM receives only a
placeholder, and MicroSandbox substitutes the value at the allowed destination.
Using `*` requires an explicit warning acknowledgement because any HTTPS host
could then receive the credential.

Adding, editing, or removing a key creates pending configuration. Running
workspaces show **Restart required**; stopped workspaces show **Applies on next
start**. Multiple edits can be staged before using **Restart affected
workspaces…**. Removal disables the old binding immediately and deletes the
Keychain value only after Silo verifies the binding is absent.

## 4. Enter a workspace from Ghostty

```bash
silo dev
silo playgrounds
silo personal
```

Each command starts a stopped VM automatically and opens a zsh login shell in `/workspace`.

Enter a nested project directly:

```bash
silo dev clients/acme/backend
silo personal apps/my-site
```

## 5. Clone repositories

Clone at the workspace root:

```bash
silo clone dev OWNER/backend
```

Clone into any nested folder; missing parent folders are created:

```bash
silo clone dev OWNER/backend clients/acme/backend
silo clone dev OWNER/frontend clients/acme/frontend
silo clone personal OWNER/site apps/site
```

List every repository in a workspace:

```bash
silo repos dev
```

You can also clone normally from inside a workspace:

```bash
silo dev
mkdir -p clients/acme
cd clients/acme
git clone https://github.com/OWNER/backend.git
```

Different repositories never require Git worktrees. A worktree is useful only when two actors need separate checkouts of different branches of the same repository at the same time.

## 6. Open projects in Zed

In Zed, run `cli: install cli binary` once from the command palette.

Then open a project from Ghostty:

```bash
silo zed dev clients/acme/backend
silo zed personal apps/site
```

Open the whole workspace when useful:

```bash
silo zed playgrounds
```

Zed's interface stays on macOS. Files, terminals, language servers, tasks, builds, tests, and remote agent processes run inside the selected VM.

## 7. Run websites and Docker projects

Run services normally inside the VM:

```bash
silo dev clients/acme/backend
docker compose up --build
```

For background services:

```bash
docker compose up -d --build
```

Open a published port from macOS:

```bash
silo open dev 3000
silo open dev 5173
silo open personal 8080
```

Equivalent URLs include:

```text
http://dev.silo.test:3000
http://playgrounds.silo.test:3000
http://personal.silo.test:3000
```

The same port can be active in every configured VM because each workspace has its own loopback IP.

Published ports are forwarded host-side: while a VM runs, the Mac keeps an SSH forward per free desired port. A port already in use on the Mac is skipped with a warning (`skippedPorts`/`portWarning` in `silo app state`) and never blocks, stops, or recreates the workspace.

The server inside the VM must bind to `0.0.0.0`, not only `127.0.0.1`. Examples:

```bash
# Vite
npm run dev -- --host 0.0.0.0

# Next.js
npm run dev -- --hostname 0.0.0.0

# Uvicorn
uv run uvicorn app:app --host 0.0.0.0 --port 8000
```

A Docker Compose service typically needs both an internal all-interface bind and a published port:

```yaml
services:
  app:
    build: .
    ports:
      - "3000:3000"
    volumes:
      - .:/app
```

For an uncommon unlisted port:

```bash
silo tunnel dev 12345
```

Then open `http://localhost:12345`. Keep that tunnel command running until finished.

## 8. Pull, commit, and push

Inside a workspace, normal local Git operations work:

```bash
git switch -c feature/example
# edit files
git add .
git commit -m "Implement example"
git pull --ff-only
```

The VM has no GitHub credential of its own. Clone, fetch, and pull inside a workspace are served by the Mac through the private host proxy (`127.0.0.1:18446`), which authenticates with the Keychain-held host credential and enforces the workspace's repository policy. `git push` from inside the VM succeeds only for repositories ticked **Clone/pull + Push from VM**; the proxy denies it for read-only entries. GitHub API calls from inside a workspace are not supported; run API operations from the Mac.

Push explicitly from a Mac terminal:

```bash
silo push dev clients/acme/backend
```

Review the displayed repository, branch, commit, and commits, then type `PUSH`.

For an automation-friendly confirmation:

```bash
silo push dev clients/acme/backend --yes
```

A non-fast-forward push is refused. After deliberate review, use an exact lease-protected force push:

```bash
silo push dev clients/acme/backend --force-with-lease
```

Only the current committed branch is transferred. Dirty files, other local branches, and tags are not pushed.

## 9. Lifecycle and resource use

```bash
silo status
silo start dev
silo stop dev
silo restart personal
silo stop all
```

All three can run together with the defaults. Monitor them with:

```bash
silo metrics dev
silo disk all
```

Resize within the configured ceiling:

```bash
silo resize dev 32G 10
```

## 10. Back up everything

Create a cold compressed backup:

```bash
silo backup
```

Default destination:

```text
~/Backups/silo/
```

Use encrypted external storage for a disaster-recovery copy:

```bash
silo backup /Volumes/EncryptedBackup/Silo
```

The command records which workspaces are running, flushes and stops them, archives all VM roots and persistent volumes with sparse-file support, writes a SHA-256 checksum and info file, and restarts only the workspaces that were previously running.

The archive includes code, Docker images, Docker volumes, databases, guest credentials, and VM state. macOS Keychain tokens are deliberately excluded. Treat the archive as sensitive anyway.

Restore:

```bash
silo restore ~/Backups/silo/silo-all-YYYYMMDD-HHMMSS.tar.zst
```

Type `RESTORE` after reviewing the warning. The restore validates the checksum and archive paths, installs into a transaction, checks the restored MicroSandbox state, and rolls back automatically if health checks fail. Workspaces remain stopped afterward:

```bash
silo host repair
silo check --deep
silo start all
```

For best compatibility, restore with the same Silo/MicroSandbox generation used to make the backup.

## 11. Updates and maintenance

```bash
# Update MicroSandbox and run diagnostics
silo update

# Upgrade Ubuntu packages
silo upgrade all

# Prune unused Docker objects, preserving volumes
silo clean all

# Also delete unused Docker volumes—destructive for unused database volumes
silo clean all --volumes

# Full live verification
silo check --deep
```

Re-run the packaged installer safely at any time:

```bash
./setup.sh
```

Useful repair/rebuild modes:

```bash
# Rebuild the reusable tool snapshot, preserving existing VM data
./setup.sh --rebuild-base

# Recreate VM roots while preserving workspace and Docker volumes
./setup.sh --recreate-workspaces

# Restore packaged config and recreate roots; persistent data volumes survive
./setup.sh --reset-config
```

## 12. Important boundaries

- `dev`, `playgrounds`, and `personal` are separate trust domains.
- Within one workspace, agents can access all repositories, processes, guest credentials, and Docker resources in that workspace.
- No host directory, host Docker socket, or host SSH agent is shared by this setup.
- The public network profile permits internet access but blocks direct host/private-network access.
- The GitHub credential is host-held in the Mac Keychain and is never bound into VM traffic. Workspaces reach GitHub only through the private host proxy, which enforces the per-workspace policy: a workspace can mutate exactly the repositories ticked **Clone/pull + Push from VM**, and host push from the Mac covers every selected repository. GitHub API and GraphQL calls from inside a workspace are not supported in this version. Unrestricted internet still permits source-code exfiltration to unrelated services.
- Prefer ARM64 or multi-architecture container images for native M4 performance.
