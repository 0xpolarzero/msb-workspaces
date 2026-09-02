# GitHub access in Silo

GitHub is optional. The default local mode (`SILO_GITHUB_MODE=local`) keeps the
GitHub credential on this Mac: git inside a workspace reaches GitHub through a
host-side proxy on `127.0.0.1:18446` that enforces a per-workspace capability
(`X-Silo-Capability`) against the policy file
(`~/Library/Application Support/Silo/github-policy.json`). No GitHub
token is ever bound into a VM.

## First run

Open **Silo** → **Settings** → **GitHub** and connect the account on
this Mac:

- The app reuses an authenticated `gh` CLI when one is present (verifying
  `GET /user`, and `permissions.push` for every repository ticked for VM
  push).
- When configured for it, the app falls back to the OAuth Device Flow and
  prints the code on screen.
- The credential is stored as one versioned record in the login Keychain
  (`org.silo.Silo.github-host.v2`); the token never appears in
  argv, logs, journals, or backups. A pre-v2 item is left dormant and unread.

The policy starts empty: until you tick repositories, no workspace can reach
GitHub through the proxy.

## Selecting repositories

The repository picker shows **paginated checkboxes grouped by owner**:

- Check a repository to assign it to the workspace being edited.
- Every new assignment defaults to **Clone/pull (push from Mac)**.
- Toggle **Clone/pull + Push from VM** only for repositories that must accept
  pushes initiated inside the VM.

| Mode | Clone/pull | Local edit & commit | Host push (`silo push`, app Push) | Push from inside the VM |
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

- `silo github status [WORKSPACE|all] [--format json|text]` — mode, capability,
  ticked repositories, host credential, and shuttle state.
- `silo github verify WORKSPACE [REPO]` — probes policy, capability, and host
  credential without touching the VM.
- `silo github auth --force` — rotates the host credential (generation+1).
- `silo github capability rotate WORKSPACE` — mints a fresh capability; the old
  one is denied immediately.
- `silo github remove WORKSPACE` — revokes the host credential metadata-first,
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
  keychain, or backups. `silo check --deep` asserts the guest holds no
  `GH_TOKEN`.
- The proxy's identity gate is the per-workspace capability (constant-time
  compare); enforcement is fail-closed for unknown workspaces, unknown
  repositories, and any endpoint outside the GitHub git/LFS surface.
- The host credential is used by the proxy (outbound leg) and by the explicit
  `silo push` path only; the askpass helper emits a token only for `github.com`
  prompts.
- Deleting or corrupting the policy file denies all proxy and host-push access;
  no repository remains selected.
- Connect mode (`SILO_GITHUB_MODE=connect`) remains available as a rollback
  alternative; local mode is the default and never reads or writes Connect
  grants.

## CLI fallback

The same surface is available from the terminal (the app remains the
recommended path):

```bash
silo github auth [--force] [--json]
silo github repos [--owner OWNER] [--format json]   # picker repository list
silo github status [WORKSPACE|all] [--format json|text]
silo github verify WORKSPACE [OWNER/REPO]
silo github remove WORKSPACE
silo app github-policy-get [--workspace W] --format json
silo app github-policy-set --workspace W --repository OWNER/REPO --mode read-only|read-write [--remove] [--clear]
```

Advanced: `silo github proxy-configure [WORKSPACE]` installs or repairs the
transport idempotently, and `silo github capability rotate WORKSPACE` rotates
a capability.
