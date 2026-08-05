# MicroSandbox Workspaces (`msw`) 3.1.0

A ready-to-run development setup for an Apple Silicon Mac with three isolated, persistent Linux microVM workspaces:

| Workspace | Purpose | Normal live limit | Resize ceiling | Browser name |
|---|---|---:|---:|---|
| `dev` | Main/work development | 8 CPU, 32 GB RAM | 48 GB RAM | `dev.msw.test` |
| `playgrounds` | Experiments | 4 CPU, 32 GB RAM | 48 GB RAM | `playgrounds.msw.test` |
| `personal` | Personal projects | 6 CPU, 16 GB RAM | 32 GB RAM | `personal.msw.test` |

Each workspace has its own Ubuntu system, repositories, Docker daemon, images, volumes, credentials, processes, and public-internet connection. Code and Docker data live on independent persistent ext4 volumes. Zed and Ghostty remain native macOS applications and connect over SSH.

## Install

```bash
unzip microsandbox-workspaces-v3.1.0.zip
cd microsandbox-workspaces
./setup.sh
exec zsh -l
```

`setup.sh` installs the host tools, builds the common development image, creates all three workspaces, publishes the configured localhost ports, configures SSH/Zed integration, and finishes with a live deep check.

Then set your commit identity:

```bash
msw identity "Your Name" you@example.com
```

Configure GitHub separately for each workspace:

```bash
msw github setup dev OWNER/VERIFICATION-REPO
msw github setup playgrounds OWNER/VERIFICATION-REPO
msw github setup personal OWNER/VERIFICATION-REPO
```

Each command asks for two fine-grained GitHub tokens and verifies the complete permission boundary automatically: read/clone from the VM, rejected guest push, successful host-only push, and cleanup. See [`docs/GITHUB-SETUP.md`](docs/GITHUB-SETUP.md).

## Daily use

```bash
# Enter /workspace in Ghostty
msw dev
msw playgrounds
msw personal

# Enter a nested repository
msw dev clients/acme/backend

# Clone into a nested folder
msw clone dev OWNER/REPO clients/acme/backend

# Open in Zed
msw zed dev clients/acme/backend

# Open a running website in your Mac browser
msw open dev 3000
msw open playgrounds 5173

# Explicitly push the current committed branch from the Mac
msw push dev clients/acme/backend

# Back up every VM and persistent volume
msw backup
```

A service must listen on `0.0.0.0` inside the VM or container. The common development ports are already published to each workspace's dedicated loopback IP, so all three can use port 3000 simultaneously.

## Documentation

- [Complete setup guide](docs/SETUP-GUIDE.md)
- [GitHub permissions and push guide](docs/GITHUB-SETUP.md)
- [Command cheatsheet](docs/MSW-CHEATSHEET.md)
- [Test report](docs/TEST-REPORT.md)

Installed documentation is also available from any terminal:

```bash
msw docs setup
msw docs github
msw docs cheatsheet
msw docs tests
```

## Trust boundary

Every process and agent inside one workspace can access everything in that workspace. The three workspaces are separate from one another and no Mac folder, Mac Docker socket, or Mac SSH agent is mounted into them. The guest GitHub credential is read-only and host-held; the write credential remains in macOS Keychain and is used only by the explicit `msw push` path.

Full public internet access means an untrusted agent can still transmit files it can read to an unrelated internet service. This setup prevents direct access to your Mac and prevents GitHub pushes with the guest credential; it is not a data-loss-prevention system.
