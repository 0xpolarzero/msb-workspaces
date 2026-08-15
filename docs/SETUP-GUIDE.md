# MSW setup guide

This guide installs three persistent MicroSandbox development workspaces on an Apple Silicon Mac:

- `dev`
- `playgrounds`
- `personal`

The packaged defaults allow up to 80 GB of live VM memory across the three workspaces, with resize ceilings up to 128 GB. Ensure the Mac has sufficient RAM. All commands below run in Ghostty unless stated otherwise.

## 1. Install

Unzip the package and run the installer:

```bash
cd ~/Downloads
unzip microsandbox-workspaces-v3.1.0.zip
cd microsandbox-workspaces
./setup.sh
```

The installer may request your macOS administrator password to add three private loopback addresses and local browser names. It then:

1. Installs Homebrew when missing.
2. Installs GNU tar, zstd, Git LFS, and MicroSandbox.
3. Runs MicroSandbox diagnostics.
4. Builds one reusable Ubuntu 24.04 ARM64 development snapshot.
5. Creates `dev`, `playgrounds`, and `personal` from that snapshot.
6. Attaches a separate persistent ext4 workspace volume and Docker-runtime volume to each VM.
7. Configures Docker Engine, Compose, Buildx, Git, GitHub CLI, mise, Node LTS, pnpm, uv, Python, zsh, and common development tools.
8. Enables local TLS interception so MicroSandbox can substitute host-held secrets only at their allow-listed HTTPS endpoints.
9. Configures fixed local browser names and SSH aliases.
10. Runs `msw check --deep` against all three VMs.

When it finishes:

```bash
exec zsh -l
```

The installation is complete only when the installer prints:

```text
all live VM, Docker, SSH, internet, and published-port checks passed
```

## 2. Set your Git identity

Apply one identity to all three workspaces:

```bash
msw identity "Your Full Name" you@example.com
```

Or configure one workspace only:

```bash
msw identity "Your Full Name" work@example.com dev
```

## 3. Connect GitHub

GitHub authorization is completed in **MSW Monitor**, not in the CLI. Open **Settings** → **GitHub** → **Connect GitHub** (the first-run setup window exposes the same action). The authorization page opens in your default browser; builds without a configured Connect endpoint show the connection as unavailable instead of offering a page that cannot connect. After authorizing, select the GitHub owner and repositories, and review the guest-read/host-write assignments before applying them.

If the connected account has no installed MSW GitHub App, the setup window offers **Install MSW App in GitHub** when the signed build has a verified installation URL configured. Approve the app for the intended owner, then return to MSW Monitor and connect GitHub again. Builds without that release-supplied URL show a safe unavailable-link message instead of opening an arbitrary address; ask the release administrator for the approved installation action.

The Connect service issues short-lived grants scoped to the selected owner, repositories, and workspace. Repeat the flow for `dev`, `playgrounds`, and `personal` when their repository scopes differ. The legacy `msw github setup` token prompt was removed; invoking it only reports the migration path.

## 4. Enter a workspace from Ghostty

```bash
msw dev
msw playgrounds
msw personal
```

Each command starts a stopped VM automatically and opens a zsh login shell in `/workspace`.

Enter a nested project directly:

```bash
msw dev clients/acme/backend
msw personal apps/my-site
```

## 5. Clone repositories

Clone at the workspace root:

```bash
msw clone dev OWNER/backend
```

Clone into any nested folder; missing parent folders are created:

```bash
msw clone dev OWNER/backend clients/acme/backend
msw clone dev OWNER/frontend clients/acme/frontend
msw clone personal OWNER/site apps/site
```

List every repository in a workspace:

```bash
msw repos dev
```

You can also clone normally from inside a workspace:

```bash
msw dev
mkdir -p clients/acme
cd clients/acme
git clone https://github.com/OWNER/backend.git
```

Different repositories never require Git worktrees. A worktree is useful only when two actors need separate checkouts of different branches of the same repository at the same time.

## 6. Open projects in Zed

In Zed, run `cli: install cli binary` once from the command palette.

Then open a project from Ghostty:

```bash
msw zed dev clients/acme/backend
msw zed personal apps/site
```

Open the whole workspace when useful:

```bash
msw zed playgrounds
```

Zed's interface stays on macOS. Files, terminals, language servers, tasks, builds, tests, and remote agent processes run inside the selected VM.

## 7. Run websites and Docker projects

Run services normally inside the VM:

```bash
msw dev clients/acme/backend
docker compose up --build
```

For background services:

```bash
docker compose up -d --build
```

Open a published port from macOS:

```bash
msw open dev 3000
msw open dev 5173
msw open personal 8080
```

Equivalent URLs include:

```text
http://dev.msw.test:3000
http://playgrounds.msw.test:3000
http://personal.msw.test:3000
```

The same port can be active in all three VMs because each workspace has its own loopback IP.

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
msw tunnel dev 12345
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

The VM can fetch and pull private repositories selected in its read token. Direct guest pushes are rejected by GitHub.

Push explicitly from a Mac terminal:

```bash
msw push dev clients/acme/backend
```

Review the displayed repository, branch, commit, and commits, then type `PUSH`.

For an automation-friendly confirmation:

```bash
msw push dev clients/acme/backend --yes
```

A non-fast-forward push is refused. After deliberate review, use an exact lease-protected force push:

```bash
msw push dev clients/acme/backend --force-with-lease
```

Only the current committed branch is transferred. Dirty files, other local branches, and tags are not pushed.

## 9. Lifecycle and resource use

```bash
msw status
msw start dev
msw stop dev
msw restart personal
msw stop all
```

All three can run together with the defaults. Monitor them with:

```bash
msw metrics dev
msw disk all
```

Resize within the configured ceiling:

```bash
msw resize dev 32G 10
```

## 10. Back up everything

Create a cold compressed backup:

```bash
msw backup
```

Default destination:

```text
~/Backups/microsandbox/
```

Use encrypted external storage for a disaster-recovery copy:

```bash
msw backup /Volumes/EncryptedBackup/MicroSandbox
```

The command records which workspaces are running, flushes and stops them, archives all VM roots and persistent volumes with sparse-file support, writes a SHA-256 checksum and info file, and restarts only the workspaces that were previously running.

The archive includes code, Docker images, Docker volumes, databases, guest credentials, and VM state. macOS Keychain tokens are deliberately excluded. Treat the archive as sensitive anyway.

Restore:

```bash
msw restore ~/Backups/microsandbox/microsandbox-all-YYYYMMDD-HHMMSS.tar.zst
```

Type `RESTORE` after reviewing the warning. The restore validates the checksum and archive paths, installs into a transaction, checks the restored MicroSandbox state, and rolls back automatically if health checks fail. Workspaces remain stopped afterward:

```bash
msw host repair
msw check --deep
msw start all
```

For best compatibility, restore with the same MSW/MicroSandbox generation used to make the backup.

## 11. Updates and maintenance

```bash
# Update MicroSandbox and run diagnostics
msw update

# Upgrade Ubuntu packages
msw upgrade all

# Prune unused Docker objects, preserving volumes
msw clean all

# Also delete unused Docker volumes—destructive for unused database volumes
msw clean all --volumes

# Full live verification
msw check --deep
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
- A guest-read grant cannot push to GitHub, but unrestricted internet still permits source-code exfiltration to unrelated services.
- Prefer ARM64 or multi-architecture container images for native M4 performance.
