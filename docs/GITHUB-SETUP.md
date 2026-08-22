# GitHub access in MSW Monitor

GitHub is optional. The default local mode (`MSW_GITHUB_MODE=local`) keeps the
GitHub credential on this Mac: git inside a workspace reaches GitHub through a
host-side proxy on `127.0.0.1:18446` that enforces a per-workspace capability
(`X-MSW-Capability`) against the policy file
(`~/Library/Application Support/MSW Monitor/github-policy.json`). No GitHub
token is ever bound into a VM.

## First run

Open **MSW Monitor** → **Settings** → **GitHub** and connect the account on
this Mac:

- The app reuses an authenticated `gh` CLI when one is present (verifying
  `GET /user`, and `permissions.push` for every repository ticked for VM
  push).
- When configured for it, the app falls back to the OAuth Device Flow and
  prints the code on screen.
- The credential is stored as one versioned record in the login Keychain
  (`org.microsandbox.MSWMonitor.github-host.v2`); the token never appears in
  argv, logs, journals, or backups. A pre-v2 item is left dormant and unread.

The policy starts empty: until you tick repositories, no workspace can reach
GitHub through the proxy.

## Selecting repositories

The repository picker shows **paginated checkboxes grouped by owner**:

- Check a repository to assign it to the workspace being edited.
- Every new assignment defaults to **Clone/pull (push from Mac)**.
- Toggle **Clone/pull + Push from VM** only for repositories that must accept
  pushes initiated inside the VM.

| Mode | Clone/pull | Local edit & commit | Host push (`msw push`, app Push) | Push from inside the VM |
|---|---|---|---|---|
| **Clone/pull (push from Mac)** (read-only) | yes | always works | yes | no |
| **Clone/pull + Push from VM** (read-write) | yes | always works | yes | yes |

- **Local editing and commits always work**, in either mode.
- **Host push is allowed for every selected repository** in either mode.
- **Push from inside a VM is allowed only for repositories ticked
  **Clone/pull + Push from VM****; the proxy's receive-pack rules enforce
  this, so a workspace cannot write a repository it was not given.
- Nothing changes until the policy is reviewed and applied. Policy writes are
  journaled and transactional; the proxy re-reads the policy on every request,
  so a mode flip applies on the next request without a restart. A missing,
  malformed, or unknown policy entry denies access (fail-closed).

## Daily use and recovery

- `msw github status [WORKSPACE|all] [--format json|text]` — mode, capability,
  ticked repositories, host credential, and shuttle state.
- `msw github verify WORKSPACE [REPO]` — probes policy, capability, and host
  credential without touching the VM.
- `msw github auth --force` — rotates the host credential (generation+1).
- `msw github capability rotate WORKSPACE` — mints a fresh capability; the old
  one is denied immediately.
- `msw github remove WORKSPACE` — revokes the host credential metadata-first,
  then removes the Keychain record; if either step cannot be proven, the state
  stays quarantined (fail-closed). The app never claims removal it cannot
  verify.
- Port warnings during setup/start are nonfatal: unavailable published ports
  are recorded as `skippedPorts`/`portWarning` and never block the workspace.

## What works from a workspace (v1)

- `git clone`, `fetch`, `pull`, and `git push` for ticked repositories,
  including Git LFS (batch and object endpoints through the proxy).
- **GitHub API and GraphQL calls from inside a workspace are not supported**
  in v1; use git, or run API operations from the Mac.
- The guest git config sends the workspace capability only to the proxy
  prefix; no credential leaves the Mac.

## Security properties

- The VM has no GitHub credential of any kind — not in env, git config,
  keychain, or backups. `msw check --deep` asserts the guest holds no
  `GH_TOKEN`.
- The proxy's identity gate is the per-workspace capability (constant-time
  compare); enforcement is fail-closed for unknown workspaces, unknown
  repositories, and any endpoint outside the GitHub git/LFS surface.
- The host credential is used by the proxy (outbound leg) and by the explicit
  `msw push` path only; the askpass helper emits a token only for `github.com`
  prompts.
- Deleting or corrupting the policy file denies all proxy and host-push access;
  no repository remains selected.
- Connect mode (`MSW_GITHUB_MODE=connect`) remains available as a rollback
  alternative; local mode is the default and never reads or writes Connect
  grants.

## CLI fallback

The same surface is available from the terminal (the app remains the
recommended path):

```bash
msw github auth [--force] [--json]
msw github repos [--owner OWNER] [--format json]   # picker repository list
msw github status [WORKSPACE|all] [--format json|text]
msw github verify WORKSPACE [OWNER/REPO]
msw github remove WORKSPACE
msw app github-policy-get [--workspace W] --format json
msw app github-policy-set --workspace W --repository OWNER/REPO --mode read-only|read-write [--remove] [--clear]
```

Advanced: `msw github proxy-configure [WORKSPACE]` installs/repairs the
transport idempotently, `msw github capability rotate WORKSPACE` rotates a
capability, and `msw github migrate [WORKSPACE|all]` retires legacy
Connect-era state on first local-mode use (archives
`~/.config/msw/github/<box>.conf` under `migrated-local/`, proves any old
guest secret removed, and preserves pre-existing quarantine markers).
