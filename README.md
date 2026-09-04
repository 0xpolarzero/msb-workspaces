# Silo

<img src="assets/silo-logo.svg" alt="Silo" width="96">

**Silo** is the native macOS control surface for these MicroSandbox workspaces.

A ready-to-run development setup for an Apple Silicon Mac with configurable, isolated, persistent Linux microVM workspaces. A fresh setup starts with these defaults:

| Workspace | Purpose | Normal live limit | Resize ceiling | Browser name |
|---|---|---:|---:|---|
| `dev` | Main/work development | 8 CPU, 32 GB RAM | 48 GB RAM | `dev.silo.test` |
| `playgrounds` | Experiments | 4 CPU, 32 GB RAM | 48 GB RAM | `playgrounds.silo.test` |
| `personal` | Personal projects | 6 CPU, 16 GB RAM | 32 GB RAM | `personal.silo.test` |

Each workspace has its own Ubuntu system, repositories, Docker daemon, images, volumes, credentials, processes, and public-internet connection. Code and Docker data live on independent persistent ext4 volumes. Zed and Ghostty remain native macOS applications and connect over SSH.

## Install

```bash
unzip silo-v3.1.0.zip
cd silo
./setup.sh
exec zsh -l
```

`setup.sh` installs the host tools, builds the common development image, creates every workspace in the validated schema-v1 `~/.config/silo/workspaces.json`, publishes the configured localhost ports, configures SSH/Zed integration, and finishes with a live deep check. Silo supplies that JSON through `silo app bootstrap --resume --workspace-config-fd FD --format json`; names and numeric limits are decoded as data rather than shell syntax.

Native onboarding treats that bootstrap as background work. **Continue** on Workspaces validates and saves the selected configuration, enqueues one idempotent bootstrap operation, and advances immediately to GitHub; it never waits for VM creation or verification. Progress and failures remain visible through the later steps. Review is the only synchronization barrier, and **Done** stays unavailable until every required operation has completed and verified successfully.

Then set your commit identity:

```bash
silo identity "Your Name" you@example.com
```

GitHub is optional. Silo never binds a GitHub token into a workspace: git
inside a workspace reaches GitHub
through a host-side proxy on `127.0.0.1:18446`. Public repositories are
cloneable anonymously with no setup at all. A per-workspace policy file
controls host-credential injection only: it decides, per workspace and
canonical repository, whether the host OAuth/token may be attached to a
request and whether that grant is read-only or read-write. The Mac holds ONE
host credential (reusing an authenticated `gh` CLI, or OAuth Device Flow when
configured); no GitHub credential ever enters a VM.

Set up authenticated access in **Silo** → **Settings** → **GitHub**:
connect the account on this Mac, then grant repositories to each workspace and
pick a mode per repository — **Clone/pull (push from Mac)** or **Clone/pull +
Push from VM**. Selections grant the host credential to those repositories;
they are not required for public repositories, which remain anonymously
cloneable. Local editing and commits always work; host push (`silo push` or the
app's Push button) is allowed for every granted repository, while push from
inside a VM is allowed only for repositories granted for VM push. The policy
starts empty — no credential is injected anywhere until you grant
repositories. Port warnings during setup are nonfatal. The CLI mirrors this
surface: `silo github auth|repos|status|verify|disconnect`. See
[`docs/GITHUB-SETUP.md`](docs/GITHUB-SETUP.md).

### Host-held API secrets

Use **Silo → Secrets** to add, edit, remove, and scope API keys to
workspaces and exact domains, `*.example.com`, or all HTTPS hosts (`*`). Values
stay in macOS Keychain; VMs receive placeholders that MicroSandbox substitutes
only at the configured HTTPS destinations. Every change is staged and shows
**Restart required** or **Applies on next start** until Silo verifies it.

## Daily use

```bash
# Enter /workspace in Ghostty
silo dev
silo playgrounds
silo personal

# Enter a nested repository
silo dev clients/acme/backend

# Clone into a nested folder
silo clone dev OWNER/REPO clients/acme/backend

# Open in Zed
silo zed dev clients/acme/backend

# Open a running website in your Mac browser
silo open dev 3000
silo open playgrounds 5173

# Explicitly push the current committed branch from the Mac
silo push dev clients/acme/backend

# Back up every VM and persistent volume
silo backup
```

A service must listen on `0.0.0.0` inside the VM or container. The common development ports are already published to each workspace's dedicated loopback IP, so every configured workspace can use port 3000 simultaneously.

## Documentation

- [Complete setup guide](docs/SETUP-GUIDE.md)
- [GitHub permissions and push guide](docs/GITHUB-SETUP.md)
- [Command cheatsheet](docs/Silo-CHEATSHEET.md)
- [Test report](docs/TEST-REPORT.md)

Installed documentation is also available from any terminal:

```bash
silo docs setup
silo docs github
silo docs cheatsheet
silo docs tests
```

Every process and agent inside one workspace can access everything in that workspace. Configured workspaces are separate from one another and no Mac folder, Mac Docker socket, or Mac SSH agent is mounted into them. GitHub credential grants are owner/repository scoped: the host credential is injected only for the exact canonical repositories granted to a workspace (read-only by default), it stays in macOS Keychain and is used only by the proxy and the explicit `silo push` path, and no GitHub credential exists inside any workspace. Public repositories remain reachable anonymously regardless of grants; GitHub itself decides whether an unauthenticated request succeeds.

Full public internet access means an untrusted agent can still transmit files it can read to an unrelated internet service. This setup prevents direct access to your Mac and gates GitHub pushes to the repositories each workspace is allowed to write; it is not a data-loss-prevention system.
