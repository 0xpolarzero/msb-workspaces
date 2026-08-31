# Silo for macOS 26+: native setup, GitHub App OAuth, and menu-bar operations

**Status:** implementation plan

**Target:** macOS 26 or later, Apple Silicon, direct Developer ID distribution

**Working product name:** Silo

**Decision summary:** Build a real, signed macOS application that owns first-run setup, GitHub authorization, workspace configuration, monitoring, and guarded daily operations. Keep `msw` as the policy and mutation boundary. Use a native `NSStatusItem`/`NSPopover` shell with SwiftUI content, a separate detail window, a resumable setup assistant, and a narrowly scoped privileged host helper. Use expiring GitHub App user access tokens obtained through Device Flow; do not ask users to create or paste fine-grained PATs in the normal path.

This plan intentionally replaces the previous terminal-first direction. A terminal remains an explicit escape hatch for arbitrary commands and recovery, not a prerequisite for installation or normal setup.

---

## 1. Product promise and non-negotiables

### 1.1 User promise

After downloading and launching the app, the user can:

1. Install or repair the MSW host toolchain without opening a terminal.
2. Create and verify the three persistent workspaces: `dev`, `playgrounds`, and `personal`.
3. Connect GitHub through a browser-based authorization flow instead of manually creating tokens.
4. See trustworthy workspace state in the menu bar without waking stopped VMs.
5. Start, stop, restart, inspect, open, and maintain workspaces through native UI.
6. Open Ghostty, Zed, websites, repositories, logs, and diagnostics from obvious actions.
7. Review and authorize host-only pushes without exposing the write credential to a VM.
8. Recover from stale data, failed setup, expired authorization, quarantine, and interrupted operations without guessing what happened.

### 1.2 Security and behavior invariants

These are requirements, not suggestions:

- The app never starts a VM merely because it launched, opened its popover, or is polling.
- `msw` remains the authority for lifecycle validation, quarantine, GitHub secret binding, host-only pushes, path validation, backup/restore transactions, and other policy-bearing mutations.
- The app never invokes `msb` directly for a mutation.
- The app never interpolates user input into a shell command. Every child process uses an executable URL plus an argument array.
- Guest read credentials and host push credentials are separate capabilities. A write-capable credential must never be placed in a guest environment or MicroSandbox secret binding.
- No token, refresh token, authorization header, Keychain value, or raw credential-bearing environment is written to logs, diagnostics, notifications, crash reports, preferences, backups, argv, or pasteboard.
- Quarantine is an independent state that dominates action availability. The app must not add a “clear quarantine” button or edit quarantine markers directly.
- A transport error, timeout, parse error, schema mismatch, or unknown runtime result is never displayed as `Stopped`.
- Closing the popover never cancels an operation that is not explicitly cancel-safe.
- A process exit is not treated as proof of the resulting VM state until a fresh authoritative observation succeeds.
- Any setup or migration failure that leaves credential cleanup uncertain fails closed and leaves the affected workspace quarantined.
- The app is allowed to be convenient; it is not allowed to weaken the existing trust boundary to avoid an authorization screen or a restart.

### 1.3 Explicit non-goals

The first release will not:

- Embed a GitHub App private key or any other publisher secret.
- Claim that a signed desktop app makes tokens non-extractable from a compromised macOS account.
- Provide data-loss prevention against an internet-enabled agent that can read source files.
- Expose arbitrary `msw exec` commands inside a custom terminal view.
- Silently run `clean --volumes`, `restore`, force pushes, reset/recreate operations, or guest upgrades.
- Depend on App Store distribution. The required child-process, host-integration, and privileged-helper model is a Developer ID product.
- Make a single global write-capable GitHub token available to all three trust domains.

---

## 2. Repository baseline and constraints

The repository is MSW 3.1.0 and currently defines three fixed workspaces with separate MicroSandbox VMs, persistent `/workspace` and Docker runtime volumes, distinct loopback addresses/hostnames, and separate GitHub credential state.

Observed baseline:

- Workspace defaults and resource ceilings are in `config.sh`.
- The installer installs tools, writes the user MSW configuration, repairs host integration, builds a reusable snapshot, creates all three workspaces, and runs a deep check (`setup.sh:38-98`, `setup.sh:130-160`, `setup.sh:251-317`).
- `msw` discovers configuration from `~/.config/msw/config.sh` and tools primarily through `PATH` (`bin/msw:4-31`). A Finder-launched app cannot assume the interactive shell PATH.
- `msw status` is human-readable and combines a MicroSandbox process table with port text (`bin/msw:563-567`).
- `msw metrics` currently enters a blocking `--watch` table (`bin/msw:569-574`). It is not an app telemetry contract.
- `msw logs` is a passthrough to `msb` (`bin/msw:576-580`).
- `msw repos`, `disk`, `pull`, `clone`, `identity`, and several other commands call `ensure_running`, so a stopped VM can be started by an apparently read-only-looking detail action.
- `msw host repair` changes loopback aliases, `/etc/hosts`, a LaunchDaemon, SSH keys/configuration, and uses an interactive administrator boundary (`bin/msw:655-741`).
- `msw github setup` currently asks for two fine-grained PATs, stores them in separate Keychain services, binds only the read token into the guest, verifies guest push rejection and host push success, and rolls back or quarantines on failure (`bin/msw:1204-1319`).
- `msw push` transfers a verified Git bundle through the host, uses an isolated temporary Git home, preserves fast-forward/force-with-lease rules, and prompts for `PUSH` (`bin/msw:984-1099`).
- Backups exclude Keychain tokens; restore validates archive paths, maintains rollback state, leaves VMs stopped, and does not change Keychain credentials (`bin/msw:1480-1749`).
- The test suite has 46 release scenarios covering the current CLI, GitHub boundaries, quarantine, rollback, backup/restore, Git LFS, and failure paths (`docs/TEST-REPORT.md`).

The app plan must extend these invariants rather than bypass them.

---

## 3. GitHub authentication decision

### 3.1 Use GitHub Apps, not a classic OAuth App or pasted PATs

The normal setup uses GitHub App user access tokens obtained with OAuth 2.0 Device Flow.

GitHub documents that:

- GitHub App user access tokens use the intersection of app permissions and user access.
- GitHub App user access tokens can authenticate HTTP-based Git when the app requests the `Contents` repository permission; the token is used as the HTTP password.
- Device Flow is intended for desktop/headless applications and does not require a client secret in the device-code exchange.
- Expiring user tokens last eight hours by default; the refresh token lasts six months. Refreshing a device-flow token does not require the client secret.
- Installation and user authorization are separate concepts. An app must be installed on the relevant user/organization account and the user must authorize the app.
- GitHub App permissions are more granular than classic OAuth scopes.

The app embeds only public GitHub App client IDs. It never embeds a client secret or GitHub App private key.

### 3.2 One app cannot safely provide both guest-read and host-write credentials

A single write-capable GitHub App user token cannot be downgraded to read-only by changing OAuth scopes. GitHub App user tokens do not use classic OAuth scopes for this purpose; their effective permissions are determined by the app and the user.

Therefore these designs are rejected:

- One classic OAuth App with `repo`: too broad and write-capable for a guest VM.
- One GitHub App with `Contents: write` used for both host and guest: the VM could push directly.
- A desktop binary containing a GitHub App private key and minting installation tokens: the private key is recoverable from the distributed app.
- A global app pair installed across all workspaces when strict workspace repository separation is required: a token could see repositories selected for another trust domain.

### 3.3 Recommended registration model: two apps per trust domain

To preserve the repository's existing three trust domains without operating a backend, register two GitHub Apps for each workspace:

| Trust domain | Guest app | Host app | Guest permissions | Host permissions |
|---|---|---|---|---|
| `dev` | `MSW Dev Guest` | `MSW Dev Host` | Metadata read, Contents read | Metadata read, Contents read/write |
| `playgrounds` | `MSW Playgrounds Guest` | `MSW Playgrounds Host` | Metadata read, Contents read | Metadata read, Contents read/write |
| `personal` | `MSW Personal Guest` | `MSW Personal Host` | Metadata read, Contents read | Metadata read, Contents read/write |

Rules:

- Enable Device Flow and expiring user-to-server tokens for every app.
- Request no webhooks, organization administration, account, enterprise, issues, pull request, or secrets permissions unless a later feature demonstrates a concrete need.
- Request `Workflows: read/write` only for the host app of a workspace when the user explicitly wants to push `.github/workflows` files. It is not a default permission.
- Install each app only on the repositories that belong to that workspace. If repositories belong to multiple owners, the user installs the app on each required owner and completes any organization approval/SAML step.
- The verification repository must be visible to both the guest and host app for that workspace and must permit the host app to create/delete the temporary branch used by verification.
- A workspace may remain public-only or unconfigured; it does not need a GitHub connection to exist or to start.

This is more authorization work than a two-app design, but it is the only backend-free design that keeps the existing per-workspace repository credential grants and guest-read/host-write split while using user OAuth. The setup wizard groups the work and makes the repeated steps explicit rather than hiding them.

### 3.4 Future alternative, not v1

A hosted credential broker could use private keys server-side, mint one-hour installation tokens down-scoped by repository and permission, and route credentials per workspace. That would reduce the number of GitHub App registrations but introduces a service dependency, a new high-value backend, account/session management, privacy obligations, and a new outage mode. It is not part of this local-first app plan.

### 3.5 Device Flow UX and protocol

For each required guest/host app:

1. POST to `https://github.com/login/device/code` with the public client ID.
2. Display the returned user code, verification URL, expiry countdown, and a clear `Open GitHub` button.
3. Poll `https://github.com/login/oauth/access_token` no faster than the returned interval.
4. Handle `authorization_pending`, `slow_down` (increase the interval), `expired_token`, `access_denied`, `device_flow_disabled`, and cancellation as distinct UI states.
5. On success, use the access token to fetch the authenticated user and authorized installations/repositories. Never accept a token solely because the exchange succeeded.
6. If the app is not installed on the requested owner, guide the user to the GitHub installation page, then refresh installations. If organization policy or SAML blocks access, show the exact GitHub recovery action.
7. Let the user select the owner, installation, repositories, and verification repository. Do not ask the user to copy a token.
8. Import the access/refresh pair into the credential broker through a pipe or XPC request, never argv or a persisted intermediate file.
9. Run the MSW transactional configure/verify operation and show its stage-by-stage result.

Access and refresh tokens are stored together in one versioned Keychain record per workspace/role; they are never split across separate Keychain items. A refresh operation holds the per-profile lock, asks GitHub for the replacement pair, validates it, then writes the complete record in one Keychain item update/replace before publishing the new generation to file metadata. `SecItem` does not provide a transaction spanning multiple items, which is why the pair is one item.

GitHub invalidates the old pair as soon as it accepts a refresh. If the app crashes or the single-record Keychain write fails after that point, the old pair can remain stored locally but cannot be rolled back remotely. The broker marks the profile `Reauthorization required`, does not present the stored generation as usable, and directs the user through explicit Device Flow reauthorization. It must never claim that token rotation rolled back.

### 3.6 Token refresh and MicroSandbox secret binding

The current MicroSandbox secret contract reads a host environment variable when starting/configuring a sandbox. Until MicroSandbox provides a credential-handle or live broker API, the following is the safest compatible design:

- `msw-auth` owns one versioned access/refresh Keychain record per profile and refreshes it under a per-profile lock.
- `msw` asks `msw-auth` for a valid short-lived guest token immediately before `msb modify --secret` and `msb start/restart`. The token exists transiently in the tightly scoped `msw`/`msb` process environment only because the current `msb` API requires that source environment; it is never logged, placed in argv, written to the guest filesystem, or persisted in MSW metadata.
- The host push path obtains a valid host token through the askpass/broker pipe. The host token is never bound as `GH_TOKEN` in a guest.
- If a guest access token is refreshed while a VM is running and the runtime does not dynamically re-resolve the secret, the app must not silently restart the VM. It marks the credential as `Ready after restart`, shows the expiry, and offers an explicit restart with impact disclosure. A stopped workspace can be rebound without a user-visible restart.
- If a refresh or rebind fails, the VM remains in its observed state, GitHub status becomes `Needs authorization` or `Needs restart`, and the app does not guess.

This makes token expiry visible instead of pretending that an eight-hour token is permanent.

---

## 4. First-run app experience: no terminal prerequisite

The first launch opens a normal setup window, not the compact popover. Setup is resumable and stateful; closing the window pauses the UI without abandoning the operation.

### Phase A: welcome and trust explanation

Show:

- The three workspaces and their purposes.
- The fact that each VM has its own repositories, Docker state, credentials, processes, and internet connection.
- The guest-read/host-write GitHub boundary in plain language.
- What the app will install or modify: host tools, MSW files, MicroSandbox state, loopback names, SSH integration, workspace volumes, and optional GitHub access.
- What remains unavoidable: GitHub browser authorization/install approval and macOS administrator consent for host networking integration.

The user can continue without GitHub and connect a workspace later.

### Phase B: preflight

Check without starting a workspace:

- macOS major version >= 26.
- Apple Silicon architecture.
- Available disk space and an estimate based on the configured root/workspace/runtime sizes.
- Memory pressure and the aggregate default live memory budget.
- Virtualization/MicroSandbox prerequisites.
- Network access to the configured release and GitHub endpoints.
- Existing `msw`, `msb`, `git`, `git-lfs`, `zstd`, and tar capabilities.
- Existing MSW config, snapshot, workspaces, Keychain credential presence, quarantine markers, and host integration.

Every check reports `Pass`, `Needs action`, or `Unavailable`; a missing status result is not silently treated as a clean machine.

### Phase C: host toolchain and MSW installation

The app must not execute `curl | sh` or rely on a shell profile to install itself.

Preferred distribution model:

- Ship or download an arm64, pinned, signed MSW toolchain bundle described by a signed manifest: `msb`, MicroSandbox runtime components, `zstd`, GNU tar where required, Git LFS, the MSW CLI, SSH proxy, askpass helper, bootstrap scripts, and documentation.
- Verify the manifest signature, each artifact checksum, architecture, and expected code signature before execution.
- Install versioned toolchain files under an app-managed support directory and expose stable user-level links/configuration for terminal compatibility.
- Use the system Git when present; show a native install/repair path for Command Line Tools if absent. Do not silently install unrelated developer tools.
- Do not require Homebrew for the app path. Existing Homebrew installations may be used when explicitly selected in Advanced Settings, but Homebrew is not the only setup route.
- Keep `setup.sh` as a terminal-compatible wrapper around the same idempotent bootstrap implementation so the existing CLI workflow does not fork permanently from the app workflow.

The app streams structured progress such as `Downloading`, `Verifying`, `Installing`, and `Ready`; raw output is behind an expandable, redacted details disclosure.

### Phase D: host integration

Split `msw host repair` into a user-space portion and an authorized host portion:

- User-space: SSH key/configuration, MSW config, docs, and per-user directories.
- Privileged helper: only the fixed loopback aliases, the MSW-managed `/etc/hosts` block, and the required launchd record.

Use a separately signed `SMWHostAgent` registered as an `SMAppService` launch daemon. The helper exposes a versioned XPC interface with typed methods such as `inspect`, `ensureFixedLoopbackAliases`, and `installFixedHostRecords`. It accepts no arbitrary command, path, script, environment, or file-write request. It validates all inputs again, performs atomic bounded writes, and has no Keychain access.

The app displays the macOS administrator approval UI through the supported ServiceManagement path. If approval is denied, setup remains resumable with an exact explanation; it does not open a terminal and does not retry in a loop.

A pre-implementation spike must prove `SMAppService.daemon(plistName:)`, XPC code-signing requirements, idempotent `/etc/hosts` updates, and clean uninstall behavior on macOS 26. If the daemon registration path cannot perform the required authorization on a clean system, use a signed notarized installer package launched by the app as the fallback. Do not hide `sudo` behind a pseudo-terminal.

### Phase E: base snapshot and workspace creation

Run the existing idempotent creation semantics through a structured bootstrap coordinator:

1. Reuse or build the common Ubuntu ARM64 base snapshot.
2. Create/update `dev`, `playgrounds`, and `personal` with the configured CPU, memory, root disk, ports, labels, and persistent volumes.
3. Configure guest profile, hostname, Docker, Compose, Buildx, and the fixed browser host.
4. Apply a guest read secret only when the workspace has been configured for GitHub.
5. Run the complete deep check.
6. Restore the pre-operation running set, or leave all VMs stopped on first install as the current installer does.

The setup UI explicitly says that deep verification temporarily starts VMs and may pull/run test containers. It never presents a newly created VM as “running” merely because creation succeeded.

### Phase F: GitHub connection wizard

For each workspace, offer:

- `No GitHub credential grants`.
- `Read from GitHub` (guest app only).
- `Read and push from this Mac` (guest app plus host app).

Public repositories are anonymously cloneable from any workspace without any selection; these options only grant authenticated (credential) access. The wizard handles the repeated app-specific Device Flow/installation steps described in Section 3.5. It displays the selected owner and repository credential grants before applying them.

The verification step visibly states:

- Guest token: Contents read-only, bound to this workspace only.
- Host token: Contents read/write, kept in the Mac Keychain only.
- Direct VM push: must be rejected by GitHub.
- Host push: transfers only the reviewed committed branch and must succeed when authorized.
- Verification: creates and deletes a temporary branch and empty commit.

If verification fails, show the failed stage and the final safety result: previous credentials restored, new credentials removed, or workspace quarantined. Never tell the user “setup failed” without saying which of those states is true.

### Phase G: identity and finish

Offer per-workspace Git identity fields, prefilled from the GitHub account only when available and clearly editable. Save only the chosen name/email through `msw identity`; never infer or store a GitHub token in preferences.

The finish screen confirms:

- All three workspaces exist.
- Which workspaces are configured for GitHub and with which access mode.
- Which workspaces are stopped/running.
- Host integration and toolchain health.
- The exact location of Settings and the menu-bar item.

---

## 5. Steady-state menu-bar UX

### 5.1 Status item

Use one monochrome template SF Symbol in an `NSStatusItem`. Do not put workspace names, CPU percentages, memory counts, or action icons in the menu bar.

Aggregate states:

- Normal: neutral icon; stopped is normal, not an error.
- Busy: a restrained activity indicator only while an app operation is running.
- Attention: amber marker for actionable stale data, expiring authorization, or a recoverable warning.
- Critical: red marker plus a distinct glyph/shape for quarantine, broken setup, or an unrecoverable observed error.

Every state also has localized text and a tooltip with aggregate status and observation age. Color is never the only signal. Respect Reduce Motion and Differentiate Without Color.

### 5.2 Popover

Use a fixed-width, keyboard-navigable popover around 380–420 points wide. The first view is intentionally calm:

1. Header: `MSW`, aggregate health, last updated/stale age, Refresh, Activity, Settings, and Quit.
2. Three fixed-order workspace cards: `dev`, `playgrounds`, `personal`.
3. A compact footer with `Open Details` and `Diagnostics` when relevant.

Each card contains:

- Workspace name and purpose.
- Lifecycle state: `Running`, `Stopped`, `Starting`, `Stopping`, `Restarting`, `Unavailable`, `Unknown`, or `Quarantined`.
- Credential state when configured: `Ready`, `Expiring`, `Needs restart`, `Needs authorization`, or `Read-only`.
- Last observed time and stale marker.
- Numeric CPU/memory values only when a fresh metric exists and the VM is running.
- One best next action: Start, Open Terminal, Open in Zed, Open Site, Retry, or Repair.
- A labeled actions menu for Stop, Restart, ports, repositories, logs, pull, clone, and maintenance. Do not hide recovery behind an unlabeled ellipsis.

Starting, stopping, and restarting disable conflicting controls for the affected workspace and show a named progress state (`Starting dev…`). Other cards remain usable.

### 5.3 Detail window

Open a normal resizable window, initially about 760×520 points, for data-rich work. Use a sidebar or navigation split view with:

- Overview.
- Metrics.
- Logs.
- Repositories.
- Ports and tunnels.
- GitHub Access.
- Activity.
- Backup.
- Diagnostics and Maintenance.

The detail window is not a terminal emulator. It gives the user understandable summaries and explicit handoffs to Ghostty/Zed when the terminal is the correct tool.

### 5.3.1 Repository change view and convenient pushes

The Repositories view is a first-class daily workflow, not just a list:

- It can show every repository's workspace-relative path, canonical remote, current branch, nullable `upstreamRef`, last checked time, and freshness state.
- A worktree status scan reports `clean`, `localChanges`, `detached`, or `unavailable`; a separate destination state reports `absent`, `upToDate`, `ahead`, `behind`, `diverged`, or `unavailable`. A missing `upstreamRef` is reported independently and does not imply that the same-name destination is absent. For `localChanges`, show staged, modified, deleted, and untracked counts. For `ahead` or `diverged`, show ahead/behind counts and the local/remote commit IDs needed for a push plan. Never collect file contents or diffs into the app's activity store.
- A dirty worktree does not by itself disable `Push`. If committed `HEAD` is ahead and ordinary push preconditions are valid, show `Push N commits` with a prominent `Uncommitted changes will not be included` warning. `Review changes` opens the repository in Zed or opens Ghostty with an exact safe handoff; the app does not auto-commit, discard, stash, or invent a commit message.
- A repository whose committed `HEAD` is ahead and whose remote state is pushable gets a prominent `Push N commits` action even when untracked or modified files exist. The push sheet shows branch, commit range/subjects, local SHA, current remote SHA, fast-forward status, repository path, the exact host-only effect, and the warning that only committed `HEAD` transfers. After the push, the app re-observes the repository and displays the resulting worktree/remote state.
- A repository whose destination state is `absent` gets a separate `Publish branch` action; `upstreamRef == null` alone never triggers it. If a same-name destination exists, label and gate the action from its actual `upToDate`/`ahead`/`behind`/`diverged` relation. Block ordinary push only for detached/unknown state, diverged or non-fast-forward destinations, unavailable authorization, quarantine, or another MSW policy failure. `Review ready pushes` can select several repositories whose committed `HEAD` is pushable, including dirty worktrees; it presents one plan row and one uncommitted-change warning per repository, applies them in a fixed order, and reports independent success/failure. It is never a blind `push all` shortcut and never bypasses per-repository preconditions.
The UI therefore distinguishes uncommitted local changes from committed changes that have not reached the remote. Both are visible; uncommitted changes do not block pushing a pushable committed `HEAD`, and they are never included in the host-only transfer.

### 5.4 Settings

Use a native Settings scene and `OpenSettingsAction`/`SettingsLink`:

- General: launch at login, polling cadence, appearance, reduced-motion behavior, and quit behavior.
- Workspaces: resource defaults, favorite ports, browser scheme, and per-workspace identity.
- GitHub: connected account/installations, repository scope, expiration, reauthorize, verify, rotate, and remove.
- Integrations: Ghostty path, Zed path, MSW executable/toolchain path.
- Notifications: explicit opt-in categories and current authorization state.
- Backup: default destination and retention policy (path only, never archive contents).
- Diagnostics: versions, host integration, copy-redacted diagnostics, open docs.
- About: app/MSW/MicroSandbox versions, release notes, support links.

No raw token field is present in normal Settings. A legacy PAT presence is shown as `Legacy credential configured`; migration is a guided replacement, not a token display.

---

## 6. Complete MSW capability matrix

The app must classify every command in `msw help`. No command is silently omitted.

| Command | Native surface | Guard and behavior | Required contract/notes |
|---|---|---|---|
| `msw dev [PATH]`, `playgrounds`, `personal`, `shell` | Workspace card `Open Terminal` | Launch Ghostty with a validated argv; the shell itself remains interactive in Ghostty. | Do not invoke the SSH TTY from a non-TTY app process. |
| `msw zed WORKSPACE [PATH]` | Card/repository `Open in Zed` | Explicit user action; MSW validates workspace-relative path and starts the VM if needed. | Invoke the installed Zed CLI or exact supported `msw zed` argv; no shell string. |
| `msw exec WORKSPACE COMMAND…` | Terminal escape hatch only | Arbitrary guest command execution is not exposed as a GUI text field. | Offer a copyable exact command and `Open in Ghostty`; never build a mini-terminal. |
| `msw clone WORKSPACE OWNER/REPO [PATH]` | Repositories → Clone | Repository picker, validated relative destination, explicit confirmation, per-result progress. | Requires structured repository scope and a noninteractive stdin/FD contract. |
| `msw repos WORKSPACE` | Repositories tab | On-demand repository listing and worktree-status scan; disclose that the current implementation starts a stopped VM, while the app contract's `--if-running` probe never does. | Return repository path, remote, branch, nullable `upstreamRef`, destination state, dirty counts, ahead/behind, freshness, and `needsStart`; no file contents or diffs. |
| `msw pull WORKSPACE [PATH\|all]` | Repository row or bulk action | Fast-forward-only; explicit action, per-repository result, no force mode. | Add JSON results and stable path errors. |
| `msw push WORKSPACE PATH` | Repository push review sheet | Show `Push N commits` when committed `HEAD` is ahead and the destination state is pushable, even if the worktree is dirty; show `Uncommitted changes will not be included`. Show `Publish branch` only when the same-name destination state is `absent`; a missing `upstreamRef` alone is not enough. Block detached, unknown, diverged, non-fast-forward, quarantined, or unauthorized states. Review workspace, canonical repo, path, branch, SHA, remote SHA, commits, and fast-forward status; require `PUSH`. | App must not pass `--yes`; add plan/apply or FD confirmation bound to the reviewed SHA. |
| `msw push … --force-with-lease` | Advanced push review | Separate higher-risk choice; exact remote SHA lease is displayed and revalidated. | Never combine with ordinary push button. |
| `msw identity NAME EMAIL [TARGET]` | Settings → Workspaces | Direct field-based edit; show target workspaces before applying. | Structured success/failure; no token handling. |
| `msw github setup …` | Setup/GitHub wizard replacement | No PAT prompt in app. Device Flow, installation selection, credential import, transactional verification. | Add `msw app github configure`/equivalent; preserve human `github setup` compatibility. |
| `msw github verify WORKSPACE [REPO]` | GitHub Access → Verify | Explicit confirmation because it creates/pushes/deletes a temporary remote branch. | JSON progress and final safety state. |
| `msw github status [WORKSPACE\|all]` | Popover badges and GitHub Settings | Show provider, account, installation, access mode, expiry, verification age, and quarantine; never values. | Add versioned JSON. |
| `msw github remove WORKSPACE` | GitHub Settings | Explain guest secret removal, host credential removal, possible restart, and quarantine on uncertain cleanup; require workspace-name confirmation. | Metadata is revoked before fallible cleanup. |
| `msw open WORKSPACE [PORT] [SCHEME]` | Card `Open Site` | Explicit click may start a stopped VM; show that effect and use `msw start` then `msw url`. | Validate the returned HTTP(S) URL before opening. |
| `msw url WORKSPACE [PORT] [SCHEME]` | Ports and favorite links | Read-only URL resolution; only HTTP/HTTPS and configured/tunnel ports. | Add JSON URL/result and do not reconstruct policy in Swift. |
| `msw ports [WORKSPACE\|all]` | Ports tab | Distinguish configured/published from active/listening. | Add JSON; current text is not parseable safely. |
| `msw tunnel WORKSPACE REMOTE [LOCAL]` | Ports → Tunnels | Validate both ports; tracked process with visible lifetime and Stop; explicit action may start VM. | Run a non-TTY-safe tracked variant or launch Ghostty when interactive SSH is required. |
| `msw start [TARGET]` | Per-card Start; separate Start All | Safe explicit action; no implicit starts from polling. | JSON progress/result; per-workspace lock. |
| `msw stop [TARGET]` | Card Stop; global menu | Confirm effect on active processes; stronger confirmation for all. | Preserve no-force graceful timeout and observed final state. |
| `msw restart [TARGET]` | Card Restart; global menu | Confirm interruption; show pending GitHub secret rebind if required. | JSON progress/result; do not claim success before refresh. |
| `msw status` / alias `ps` | Background polling and Refresh | Must never start a VM. Preserve last good snapshot as stale on error. | Add schema-versioned JSON envelope. |
| `msw metrics [TARGET]` | Metrics tab/card summary | One-shot snapshots when visible; streaming only while the view is visible. | Add `--format json --once` and `--follow`; never parse `--watch` table. |
| `msw logs WORKSPACE [OPTIONS]` | Logs tab | Bounded, searchable, pausable, memory-safe; raw output behind explicit disclosure/copy. | Add sanitized JSONL adapter; cap bytes/lines and redact capture boundary. |
| `msw disk [TARGET]` | Diagnostics/Resources | On-demand and clearly labeled as starting stopped VMs under current behavior. | Add structured filesystem/Docker usage and effect metadata. |
| `msw resize WORKSPACE MEMORY [CPUS]` | Resources | Show configured ceilings and aggregate host pressure; confirm before mutation. | Return normalized requested/effective/max resources. |
| `msw clean [TARGET]` | Maintenance | Confirmation; preserve volumes by default. | Structured preview/result. |
| `msw clean … --volumes` | Maintenance advanced | Typed `DELETE VOLUMES` confirmation; explain unused database volumes are deleted. | Never expose as the default cleanup button. |
| `msw upgrade [TARGET]` | Maintenance advanced | Confirm guest package changes and duration; show per-VM progress. | Structured phases; no hidden apt output. |
| `msw update` | Maintenance → Runtime update | Confirm host runtime update; keep separate from app update and guest upgrade. | Signed toolchain compatibility check, progress, rollback guidance. |
| `msw check` | Diagnostics | Quick check can be a native action; result must identify each failed subsystem. | Add JSON checks and recovery actions. |
| `msw check --deep` | Diagnostics advanced | Explicit confirmation because it starts VMs and creates test services/containers. | Progress and cleanup result; preserve previous running set. |
| `msw host repair` | Setup/Recovery | Native helper path; no terminal prerequisite. | Split helper and user-space work; typed XPC contract. |
| `msw backup [DIRECTORY]` | Backup wizard | Show destination, archive sensitivity, running set, temporary stops, checksum, and restart result. | Structured paths/results; never include Keychain tokens. |
| `msw restore ARCHIVE [--yes]` | Recovery window only | Validate archive/checksum/path safety, preview replacement, require typed `RESTORE`, leave VMs stopped. | App invokes a confirmation-bound API, not `--yes`. |
| `msw docs [TOPIC]` | Settings → Documentation | Open installed guides in a native reader or external viewer. | No setup dependency; preserve docs installation. |
| `msw version` | Settings → About/Diagnostics | Show MSW, MicroSandbox, toolchain, and app versions. | Machine-readable handshake includes versions. |
| `msw help` | Settings → Help | Show command reference and exact terminal handoffs. | Never expose internal transaction command. |
| `./setup.sh` and installer flags | Setup/Advanced Recovery | Normal app setup uses the structured bootstrap coordinator; rebuild/recreate/reset are explicit advanced actions. | Keep shell wrapper; app does not parse its human output. |
| `__github-verify-transaction` | Never | Internal implementation detail. | Exclude from UI, docs command palette, and app allowlist. |

`msb` remains an implementation dependency. The app may use `msb` read-only JSON through the MSW adapter during diagnostics or while bootstrapping, but it must not expose raw `msb modify`, `remove`, `volume`, `snapshot`, `doctor --fix`, or arbitrary `exec` as unguarded app actions.

---

## 7. Machine-readable integration contract

Human CLI output remains for terminals. The app gets a parallel, versioned contract rather than parsing ANSI tables.

### 7.1 Command namespace

Add a stable `msw app` namespace or equivalent machine mode:

```text
msw app handshake --format json
msw app state [--workspace WORKSPACE] --format json
msw app metrics --workspace WORKSPACE --format json --once
msw app metrics --workspace WORKSPACE --format json --follow
msw app logs --workspace WORKSPACE --format jsonl
msw app repositories --workspace WORKSPACE --if-running --format json
msw app repositories --workspace WORKSPACE --include-worktree-status --format json
msw app push-plan --workspace WORKSPACE --repositories PATH... --format json
msw app ports [--workspace WORKSPACE] --format json
msw app github-state [--workspace WORKSPACE] --format json
msw app plan ACTION ... --format json
msw app apply PLAN_ID --confirmation-fd FD --format json
msw app bootstrap --resume --workspace-config-fd FD [--events-fd FD] --format json
```

The `logs` stream classifies records by session ORIGIN, never by message
content: the MSW adapter removes every record of a session that carries the
reserved internal-session marker (control conn-id 0, length 1, payload "H" —
the GitHub relay heartbeat frame) and emits only unmarked workload sessions.
Directory, repository, setup, storage, health, and relay exec sessions emit
the marker as their first write, so control-plane output — including
incomplete relay failures that never heartbeated — stays out of the default
Logs view while identical user output (e.g. `[]`, `{}`, arbitrary JSON)
remains visible verbatim. Typed operation diagnostics remain available
through each command's finite envelope.

### 7.2 Finite response envelope

Every finite command emits exactly one UTF-8 JSON object on stdout:

```json
{
  "schemaVersion": 1,
  "requestId": "uuid",
  "ok": true,
  "command": "state",
  "observedAt": "2026-08-07T00:00:00Z",
  "result": {},
  "warnings": []
}
```

Failure response:

```json
{
  "schemaVersion": 1,
  "requestId": "uuid",
  "ok": false,
  "command": "state",
  "error": {
    "code": "MSW_CONFIG_MISSING",
    "message": "MSW configuration is not installed.",
    "recovery": "Run Setup in Silo.",
    "workspace": null,
    "retryable": false
  }
}
```

Errors never include raw stderr, tokens, paths containing secrets, or arbitrary command text.

### 7.3 Progress/event channel

Long operations emit JSON Lines on an inherited event FD or a dedicated pipe, not mixed with the final response:

```json
{
  "schemaVersion": 1,
  "type": "progress",
  "requestId": "uuid",
  "phase": "github.verify.host_push",
  "workspace": "dev",
  "fraction": 0.66,
  "message": "Verifying host-only push",
  "safeForDisplay": true
}
```

Events include `progress`, `notice`, `warning`, `requiresConfirmation`, `completed`, and `failed`. The app can show human text but must rely on codes and fields for behavior.

### 7.4 State model

`state` includes:

- `schemaVersion`, MSW version, MicroSandbox version, capability flags.
- Workspace ID, purpose, observed lifecycle, configured resources, port mappings, quarantine state, and last observation timestamp.
- Separate `statusObservedAt`, `metricsObservedAt`, `githubObservedAt`, and `activityObservedAt` values.
- GitHub provider/account/installation/access-mode metadata, verification age, expiry, and `needsRestart`; no credential value.
- `fresh`, `stale`, `unknown`, or `unavailable` freshness state.
- Action capabilities calculated by MSW, not inferred by SwiftUI.
- Repository snapshots when requested: workspace-relative path, canonical remote, branch, nullable `upstreamRef`, independent `worktreeState` and `destinationState` (`absent`, `upToDate`, `ahead`, `behind`, `diverged`, or `unavailable`), staged/modified/deleted/untracked counts, ahead/behind counts, local/remote commit IDs, `pushability`, `needsStart`, `freshness`, and `checkedAt`; never file contents or diffs.

### 7.5 Exit status taxonomy

Use stable exits for the app runner:

- `0`: success.
- `1`: operation failed.
- `64`: usage/invalid request.
- `69`: dependency or runtime unavailable.
- `73`: lock/conflict.
- `77`: authorization/permission denied.
- `78`: configuration or migration required.
- `130`: cancelled.

The app displays structured recovery and retains bounded redacted stderr only as a diagnostic disclosure.

### 7.6 Plans and confirmations

High-impact actions use a plan/apply protocol:

- `plan` validates arguments, current state, affected workspaces, expected effects, current remote SHA (for push), and preconditions.
- The plan returns an opaque short-lived confirmation ID bound to the exact normalized request and observed state.
- The UI presents that plan and asks for the action-specific phrase where required.
- `apply` rejects expired plans, changed remote state, changed quarantine, and changed workspace state.
- The app never uses `--yes` to bypass a policy confirmation.

---

## 8. Native app architecture

### 8.1 Targets and modules

Proposed project layout:

```text
app/Silo/
  Silo.xcodeproj
  Sources/SiloApp/
    AppDelegate.swift
    StatusItemController.swift
    PopoverView.swift
    SetupWindow.swift
    DetailWindow.swift
    SettingsView.swift
  Sources/MSWCore/
    MSWClient.swift
    MSWCommandRunner.swift
    MSWJSONProtocol.swift
    MSWModels.swift
    MSWOperationCoordinator.swift
    MSWActivityStore.swift
    MSWDiagnostics.swift
  Sources/MSWAuth/
    GitHubDeviceFlow.swift
    GitHubAPIClient.swift
    CredentialBroker.swift
    KeychainStore.swift
    TokenRefreshCoordinator.swift
  Sources/MSWInstaller/
    BootstrapCoordinator.swift
    ToolchainInstaller.swift
    HostAgentClient.swift
    BootstrapStateStore.swift
  Sources/SiloHostAgent/
    main.swift
    HostAgentXPC.swift
    HostRecordManager.swift
  Resources/
    ToolchainManifest.json
    Localizable.xcstrings
    LaunchDaemons/com.msw.monitor.host-agent.plist
```

Keep the app target arm64-only for the first release because the repository and installer target Apple Silicon. Add universal builds only if distribution requirements change.

### 8.2 Status bar shell choice

Use `NSStatusItem` + transient `NSPopover` with SwiftUI hosted by `NSHostingController` rather than making `MenuBarExtra` the primary shell.

`MenuBarExtra` with `.window` is a valid macOS 26 option and can remain a prototype/reference implementation, but the explicit AppKit shell is safer for this product because it provides direct control over status-item lifetime, popover anchoring, closing, focus restoration, long-operation error presentation, and keyboard behavior. The app remains SwiftUI-first; AppKit is only the lifecycle/hosting boundary.

Use a regular macOS application (`LSUIElement=false`) so macOS presents a standard `Silo` application menu and Dock/Cmd-Tab identity while the monitor remains available from the status item. The status item and transient popover are still the primary steady-state monitor surface; detail, setup, and settings windows may activate normally when opened.

### 8.3 State and process layers

- `@MainActor` `AppModel`: UI-facing snapshots, operation summaries, settings, status-item severity, and navigation.
- `MSWClient` actor: typed calls to the machine-readable `msw app` interface.
- `ProcessRunner` actor: executable discovery, sanitized environment, concurrent stdout/stderr draining, JSON framing, bounded buffers, command-specific deadlines, process-group cancellation, and credential-shaped redaction at capture time.
- `OperationCoordinator`: one mutation per workspace; global operations acquire affected workspaces in fixed order; reads are coalesced.
- `CredentialBroker`: Keychain access, Device Flow token import, refresh, expiry, and profile locking. It is not a generic secret printer.
- `BootstrapCoordinator`: idempotent setup phases and durable nonsecret progress state.
- `HostAgentClient`: authenticated XPC connection to the fixed-operation root helper.
- `ActivityStore`: bounded sanitized completed activity; no raw guest logs by default.

### 8.4 Process rules

- Resolve `~/.local/bin/msw`, the app-managed toolchain, and explicitly configured absolute paths. Do not trust Finder PATH.
- Construct a deterministic environment with explicit `HOME`, `PATH`, `NO_COLOR=1`, locale, and only the variables required for a specific operation.
- Never pass user input through `/bin/sh -c`, zsh, AppleScript, or shell quoting.
- Drain stdout and stderr concurrently to avoid deadlocks.
- Keep process groups uniquely owned; send SIGTERM once, wait for confirmed exit, and escalate only after a bounded grace period.
- Closing a window does not cancel durable lifecycle, credential, backup, or restore operations, but it invalidates the setup window's UI-scoped device-flow work: the device-code poll, token verification, and repository re-check refresh tasks are cancelled and the setup-lifecycle generation is bumped, so a late token or refresh can never republish status, stamp the schedule, or restart polling after teardown. Credential-actor work (Keychain rotation/save on the shared refresher) may still complete; its result is simply never re-published to the closed UI.
- Use a PTY only when handing an interactive shell to Ghostty.
- Use `NSWorkspace.OpenConfiguration` to open Ghostty/Zed/URLs. Do not use Apple Events for arbitrary app automation.

### 8.5 Host helper rules

The privileged helper:

- Is separately signed, bundled, and code-signing-identity constrained on both XPC sides.
- Has no Keychain access, network client, arbitrary subprocess API, or user-provided path write API.
- Writes only the MSW-owned host records and loopback aliases.
- Makes atomic edits and preserves non-MSW host content.
- Returns structured errors and does not log request payloads containing user paths or credentials.
- Has an explicit unregister/uninstall path and is tested after app removal.

---

## 9. Credential data model and migration

### 9.1 Profiles

Represent each workspace role as an independent profile:

```text
workspace: dev
role: guest | host
provider: github-app-user
appClientID: public identifier
accountLogin: nonsecret GitHub login
installationID: nonsecret identifier
owner: nonsecret owner login
repositoryIDs: nonsecret selected IDs
verificationRepository: OWNER/REPO
accessMode: read-only | host-write
accessExpiresAt: timestamp
refreshExpiresAt: timestamp
needsRestart: boolean
schemaVersion: 2
```

Raw `access_token` and `refresh_token` values live together in one Keychain record per profile, controlled by the credential broker. File metadata is `0600`, contains no token, and is excluded from backup-sensitive claims.

### 9.2 Keychain layout

Store each workspace/role's complete token pair in one versioned Keychain generic-password record:

- `msw.github.app.<workspace>.<role>.tokens` — one item containing the access token, refresh token, access expiry, refresh expiry, schema version, and generation.

The broker uses a stable nonsecret account/label to locate the record and writes the complete payload with one `SecItemUpdate` or one-item replacement. `SecItem` has no transaction spanning multiple items, so separate access and refresh records are prohibited. The app never treats two independent Keychain writes as a committed token rotation.

The refresh path must account for GitHub's remote state: GitHub invalidates the old pair when it accepts a refresh. If the process crashes or the single-record Keychain write fails afterward, the old pair can remain stored locally but cannot be restored remotely. The broker marks the profile `Reauthorization required`, does not present the stored generation as usable, and sends the user through explicit Device Flow reauthorization. It must not claim rollback or silently retry with an invalidated pair.

Use `SecItem` APIs with a designated requirement/access group that is stable across app updates and the signed helper tools. Do not call `security -w` from the app to print credentials.

The existing `msw.github.read` and `msw.github.write` items remain detectable for migration but are never displayed or copied.

### 9.3 Legacy PAT migration

On first app launch:

1. Detect legacy presence without reading or displaying PAT values.
2. Report `provider: legacy-pat`, `migrationRequired: true`, and the affected workspace.
3. Continue using the legacy setup only if the current CLI can prove it is healthy; do not break a working installation merely because the app launched.
4. When the user completes OAuth for a workspace, acquire the per-workspace lock, quarantine before mutation, preserve the old legacy-PAT metadata/credentials as rollback state, import the new profile, bind only the guest credential, and run the full permission verification.
5. Commit the new metadata only after guest push rejection, host push success (when enabled), branch deletion, and cleanup succeed.
6. Delete old PAT items only after the new profile is proven. If any cleanup or rollback step is uncertain, keep the workspace quarantined and show the exact repair state.
The rollback language above applies only to legacy PAT migration before the new OAuth profile is proven. It does not apply to refresh-token rotation: once GitHub accepts a refresh, recovery is explicit reauthorization because the old pair is already invalidated.


### 9.4 Removal and revocation

`Remove GitHub access` must:

- Require a workspace-name confirmation.
- Revoke app metadata and host-write capability first.
- Remove the guest secret binding and Keychain items through the transactional MSW path.
- Preserve quarantine if deletion, inspection, or stopped-state proof fails.
- Explain that the app cannot silently revoke every GitHub authorization without the credentials required by GitHub's revocation endpoint; provide an explicit `Open GitHub authorization settings` action for remote revocation.

---

## 10. State machine, freshness, and reliability

Represent these dimensions independently:

1. **Lifecycle:** running, stopped, starting, stopping, restarting, exited, unknown.
2. **Freshness:** fresh, stale, unavailable, never-observed.
3. **Quarantine:** clear, quarantined with reason, quarantine state unknown.
4. **Credential:** unconfigured, legacy, ready, expiring, needs authorization, needs restart, removal pending.
5. **Operation:** idle, queued, running phase, succeeded, failed, outcome unknown.

Rules:

- Quarantine disables start, restart, exec/SSH-derived actions, push, and credential rebinding regardless of lifecycle.
- Status polling begins with `Unknown` until a fresh baseline succeeds.
- A late response from an older request generation cannot overwrite newer state.
- A hidden metrics view is `Not monitoring`, not `Stale` merely because it is not collecting.
- Transport or schema failure preserves the last good snapshot with an observed-at timestamp and an explicit stale banner.
- A mutation result is not rendered as final until a read-only refresh confirms it.
- On app relaunch, an in-flight operation becomes `Outcome unknown`; the app reconciles it and never replays it automatically.
- Launch at login, wake, and crash recovery never start VMs.
- Closing the popover does not cancel start/stop/restart/push/setup/backup/restore.
- Only telemetry, log streaming, metrics streaming, and tracked tunnel processes are cancel-safe by default.
- A workspace operation lock is authoritative; a lingering lock file is not proof that a process is still alive.

Polling policy:

- Status: approximately every 5 seconds while the popover/detail window is visible; 30–60 seconds while hidden.
- Metrics: collect only while Metrics is visible or an explicit threshold monitor is enabled.
- Logs: stream only while Logs is visible; cap lines/bytes and pause when hidden.
- Refresh immediately after a user action and after system wake/reconnect.
- Suspend polling during sleep and establish a new baseline after wake.

---

## 11. macOS 26 design, accessibility, and notifications

### 11.1 Liquid Glass

Target the macOS 26 SDK. Use system SwiftUI/AppKit controls and system chrome first. Use `glassEffect`/Glass containers sparingly for one header or primary action group, never as a separate glass card behind every workspace row. Dense cards, logs, and metrics need stable contrast and readability more than decoration.

When Reduce Transparency or increased contrast is enabled, replace custom translucent surfaces with opaque system backgrounds. Do not animate or morph glass surfaces for operational state.

### 11.2 Accessibility

- Every workspace card is a named accessibility group; its controls remain separate VoiceOver targets.
- VoiceOver labels include workspace name, lifecycle, freshness, credential state, and next action.
- Use standard `Button`, `Label`, `Menu`, `Picker`, `TextField`, `SecureField`, `Toggle`, `ProgressView`, `Table`, and navigation controls.
- Every icon-only control has a visible tooltip and localized accessibility label/value.
- Full Keyboard Access reaches every action without hover, drag, or gesture-only interaction.
- Standard shortcuts: Refresh, Settings, Quit, Escape, Return, and Space where meaningful. Destructive confirmations initially focus Cancel.
- Charts expose a text summary of current/min/max/unit and observation time.
- Status uses text and glyph/shape as well as color; CPU/memory bars include numeric units.
- Observe Reduce Motion live: remove pulse, rotation, chart interpolation, and spatial transitions; retain static progress, phase, and elapsed time.
- Test dark mode, increased contrast, reduced transparency, Differentiate Without Color, VoiceOver, Full Keyboard Access, large text, pseudolocalized strings, French, and right-to-left layout.

### 11.3 Localization

Use a String Catalog for UI, accessibility, notification, and recovery strings. Use plural-aware and locale-aware `FormatStyle` APIs for bytes, percentages, dates, and durations. Do not assemble sentences from translated fragments. Keep workspace IDs, GitHub owner/repo identifiers, and CLI commands as technical left-to-right tokens within localized explanatory text.

### 11.4 Notifications

Request notification permission only after the user enables a notification category in Settings. Establish a baseline after launch/wake/reconnect. Notify only for:

- Sustained unexpected unavailability.
- Newly observed quarantine.
- Unexpected lifecycle loss.
- Opted-in long-operation completion/failure.
- Backup failure or credential reauthorization deadline.

Do not notify for polling, initial discovery, sleep/offline transitions, metrics movement, or the app's own visible action. Deduplicate by workspace/event/generation and include a deep link to the affected view. Notifications contain no stderr, repository content, branch, SHA, username, token, or credential metadata.

---

## 12. Distribution and installation

### 12.1 Distribution choice

Distribute a Developer ID-signed, notarized, stapled DMG or ZIP. Do not target the Mac App Store in v1 because App Sandbox conflicts with the required user-level toolchain, external executable launching, host configuration, and privileged-helper design.

Build requirements:

- Hardened Runtime for the app, embedded command tools, and helper.
- Developer ID Application signing with secure timestamps.
- Inside-out signing of nested code.
- No JIT, unsigned executable memory, arbitrary Apple Events, DYLD injection, or library-validation exceptions unless a later audited dependency requires one.
- Notarize the app, helper/package, and distribution artifact; staple tickets and verify Gatekeeper assessment on a clean macOS 26 machine.
- Do not include GitHub client secrets, app private keys, user tokens, refresh tokens, or the `.gazette` credential in the app or build artifacts.

### 12.2 Updates

Keep three update channels separate:

1. Silo app update.
2. Host MicroSandbox/toolchain update (`msw update`).
3. Guest Ubuntu package update (`msw upgrade`).

The app may show update availability and release notes. It must not silently run the latter two. Use signed manifests and compatibility checks. A future signed app update feed can use a mature updater, but v1 must at minimum support a verified Developer ID/notarized replacement with rollback guidance.

### 12.3 Login item

Use `SMAppService` for an opt-in login item and expose registration status plus a direct System Settings link when approval is required. Do not install a duplicate LaunchAgent solely to launch the menu app. Login launch observes state; it does not start VMs.

---

## 13. Implementation phases

### M0 — contracts and security freeze

- Record current CLI behavior and trust invariants as fixtures.
- Add the `msw app` envelope, schema version, capabilities/handshake, stable exits, and JSON/JSONL progress channel.
- Add schema rejection tests and command-inventory completeness tests.
- Define six GitHub App registrations and client-ID configuration strategy.
- Build the credential broker/keychain schema and redaction library before UI uses secrets.

**Exit:** app can obtain a typed handshake and state response without parsing human text; no existing CLI safety test regresses.

### M1 — native setup foundation

- Create the macOS 26 Xcode project and signed Developer ID build pipeline.
- Implement setup window, preflight, resumable activity, toolchain manifest verification, and user-space installation.
- Implement and test the `SMWHostAgent` spike/XPC helper.
- Refactor `setup.sh` to share the structured bootstrap implementation.

**Exit:** clean-machine setup completes without a terminal, with explicit macOS/GitHub user approvals and all VMs left in the documented final state.

### M2 — read-only menu-bar monitor

- Implement `NSStatusItem`, popover, three cards, stale/unknown/quarantine semantics, status polling, settings, and detail window shell.
- Add Start/Stop/Restart with per-workspace operation locks and authoritative refresh.
- Add URL, Ghostty, and Zed launchers.
- Add keyboard/VoiceOver support, notifications, login item, and reduced-motion behavior.

**Exit:** 24-hour idle soak starts zero stopped VMs; healthy status appears quickly; all lifecycle actions converge or show a specific failure; accessibility acceptance passes.

### M3 — GitHub OAuth and repository workflows

- Implement six-app Device Flow wizard, installation/repository selection, token refresh, credential import, migration detection, guest binding, host askpass, and transactional verification.
- Add GitHub status/expiry/restart-needed UI.
- Add repositories, explicit stopped-VM scan prompting, worktree dirty/ahead/behind status, clone, fast-forward pull, identity, bounded logs, metrics, and ports.

**Exit:** disposable GitHub repositories prove guest push rejection, host-only push, cleanup, per-workspace credential-grant isolation while retaining anonymous public access, refresh error handling, and zero credential leakage.

### M4 — guarded daily operations

- Add push plan/review/apply with `PUSH` confirmation and separate force-with-lease flow, including convenient multi-repository review for clean branches ahead of their remotes.
- Add disk/resource view and bounded resize.
- Add normal clean and typed volume cleanup.
- Add backup wizard with running-set restoration and archive/checksum/info results.

**Exit:** all destructive fake-path tests prove confirmation cannot be bypassed; backup and push invariants match the CLI suite.

### M5 — native recovery and maintenance

- Add deep check, guest upgrade, MicroSandbox update, GitHub removal/rotation, and restore through structured preview/result APIs.
- Add native recovery for setup repair/rebuild/recreate/reset only after transactional tests exist.
- Keep terminal handoff permanently available for unsupported or ambiguous paths.

**Exit:** clean-machine crash/interruption/sleep/wake/relaunch tests show no replay, false success, token leakage, or unsafe auto-start.

---

## 14. Risks and mitigations

| Risk | Impact | Mitigation/decision |
|---|---|---|
| Six GitHub Apps create publisher and setup overhead | More registration and authorization steps | Use two apps per trust domain; group flows in one wizard. Reduce only if the user explicitly accepts weaker cross-domain isolation or a backend is introduced. |
| GitHub App user tokens expire after eight hours | Guest access may require a workspace restart to rebind | Refresh early, show `Needs restart`, never silently restart; plan a future live broker/credential-handle integration. |
| Refresh-token rotation is one-time | A local failure can occur after GitHub accepts the refresh | Store the complete pair in one Keychain record; if the post-acceptance write fails, require explicit reauthorization and never assume remote rollback. |
| Organization approval/SAML/policy blocks access | Setup can appear to “hang” or partially authorize | Enumerate installations, show GitHub-specific recovery, never retry blindly. |
| Current `msb --secret` requires source environment | A short-lived token must exist in a process environment | Keep it transient and tightly scoped; no logs/argv/guest storage. Replace when MSB offers a handle/broker API. |
| Host repair needs privileged writes | GUI setup cannot safely run arbitrary root shell | Typed signed XPC helper, no arbitrary command API, clean-machine spike before implementation. |
| Current CLI output is human-oriented | Fragile parsing could report false state | Add schema-versioned MSW JSON/JSONL before UI; reject unknown schema. |
| Finder PATH differs from shell PATH | App works in terminal but not after launch | Explicit executable discovery and toolchain manifest; show resolved paths in Diagnostics. |
| App crashes during setup or mutation | State may be uncertain | Durable nonsecret phase state, authoritative reconciliation, no automatic replay, fail-closed credential transactions. |
| No App Sandbox | Larger blast radius if app is compromised | Developer ID only, Hardened Runtime, code-signing constrained helper, no arbitrary command/path APIs, minimize entitlements. |
| GitHub permissions change later | Push or clone can fail after setup | Report installation/permission drift separately from VM state and provide reauthorize/verify. |
| Backup contains sensitive VM/repository data | User may expose an archive | Label backups sensitive, show destination, never include Keychain, offer checksum and explicit export. |
| External app CLI behavior differs | Ghostty/Zed handoff can break | Detect installed apps/CLI versions, use Launch Services/OpenConfiguration, retain exact terminal fallback. |

---

## 15. Verification and acceptance strategy

### 15.1 CLI and protocol tests

Extend the existing Python/fake-MicroSandbox suite with:

- JSON envelope/schema fixtures for every app command.
- Unknown-schema rejection and stable error-code tests.
- JSONL progress framing with split lines, huge output, interleaved stdout/stderr, hangs, SIGTERM, and cancellation races.
- No-start polling tests: repeated status/metrics/launch/idle cycles on stopped VMs prove zero `start` events.
- State freshness tests for malformed output, timeout, unavailable MSB, out-of-order responses, and stale snapshots.
- Command-inventory coverage asserting every `msw help` command has a classification.
- Plan/apply stale-state and confirmation-binding tests.

### 15.2 GitHub auth/security tests

Use a deterministic HTTP fixture for GitHub Device Flow and API responses:

- Device Flow success, pending, slow-down, denial, expiry, cancellation, malformed response, and account mismatch.
- Installation/repository enumeration, multi-owner selection, missing organization approval, SAML guidance, and permission drift.
- Expiring access/refresh token rotation with one-time invalidation and a single-record Keychain write.
- A crash or Keychain write failure after GitHub accepts a refresh must lead to explicit reauthorization; tests must reject any rollback claim or retry with the invalidated pair.
- Legacy PAT detection and atomic migration rollback.
- Dirty-worktree and destination-state push: a new branch with an untracked file transfers only committed `HEAD`, leaves the untracked file out of the remote, and surfaces the warning; a missing `upstreamRef` with an existing same-name destination exercises that destination's actual ahead/diverged relation; `Publish branch` is offered only for `absent`; detached/diverged/non-fast-forward states remain blocked.
- Guest token never appears in host-write path; host token never appears in guest secret/environment.
- Guest direct push rejection, host bundle push, force-with-lease, branch cleanup, and failed cleanup quarantine.
- Redaction seeded with `ghu_`, `ghr_`, `ghp_`, `github_pat_`, bearer/basic headers, URL credentials, `GH_TOKEN`, and fake Keychain output; assert zero leakage in stdout, stderr, activity, notifications, diagnostics, crash payloads, and backups.

### 15.3 Setup and host integration tests

On clean disposable macOS 26 machines:

- Install from the notarized artifact with no terminal.
- Resume after app termination at every bootstrap phase.
- Deny and later approve helper/Login Item authorization.
- Verify loopback/hosts/SSH integration is idempotent and does not alter unmanaged records.
- Verify helper XPC rejects untrusted clients and arbitrary paths/commands.
- Re-run setup with existing snapshot, existing workspaces, legacy credentials, and quarantine.
- Verify uninstall removes the helper and app-owned records without deleting persistent workspace data unless explicitly selected.

### 15.4 UI/accessibility tests

Use SwiftUI unit tests, controlled state fixtures, and manual macOS accessibility passes:

- Cold launch, popover opening, setup, detail navigation, settings, all workspace actions, confirmations, errors, stale states, and quarantine via VoiceOver and Full Keyboard Access.
- Reduce Motion, Reduce Transparency, increased contrast, Differentiate Without Color, dark mode, large text, long translations, French, and RTL.
- Popover closing during every operation; app relaunch after child termination; sleep/wake; logout/login; denied notifications.
- Verify focus transfer to errors and confirmations and focus restoration to the invoking control.
- Verify no workspace card becomes unusable when another card fails.

### 15.5 Performance and release checks

- 24-hour hidden-idle soak with no VM starts and bounded CPU/memory/file descriptors.
- Visible metrics/log load with bounded memory and backpressure.
- Concurrent actions against one workspace are serialized; independent workspace actions remain responsive.
- Verify signing, nested code, Hardened Runtime, notarization, Gatekeeper, update verification, and rollback.
- Test the app with missing CLI, missing config, missing Ghostty/Zed, missing Git LFS, unavailable network, and incompatible MSW schema.

---

## 16. Open decisions before implementation

The plan is actionable without blocking, using these defaults:

1. **GitHub App ownership:** assume a publisher-owned public app family with six app registrations and placeholder client IDs. A personal-only build can use private/personal-owned registrations, but the app configuration and installation UX must be selected before release.
2. **Trust boundary:** assume the existing three-workspace separation is required. If the user explicitly accepts shared repository credential grants, the registration count can be reduced to two apps, but that is a security change and must be documented as such.
3. **Distribution:** assume arm64-only Developer ID/notarized distribution for macOS 26+. No App Store target.
4. **Toolchain:** default to an app-managed signed toolchain bundle; Homebrew support is optional compatibility, not a prerequisite.
5. **Token policy:** use expiring GitHub App user tokens and explicit restart/rebind state rather than opting out of expiration for convenience.
6. **Privileged setup:** proceed with the `SMAppService`/XPC helper spike first. Do not implement a hidden sudo/PTY fallback.

Implementation cannot finalize the GitHub OAuth wizard until the six app client IDs, app names, requested permissions, public installation URLs, and publisher signing identity are available. Those are release inputs, not reasons to weaken the design.

---

## 17. Evidence and sources

### Repository evidence

- `README.md` — three workspaces, resource defaults, trust boundary.
- `docs/MSW-CHEATSHEET.md` — complete user command inventory.
- `docs/SETUP-GUIDE.md` — installer lifecycle, maintenance, backup/restore, boundaries.
- `docs/GITHUB-SETUP.md` — current guest-read/host-write model, token storage, verification, and limitations.
- `docs/TEST-REPORT.md` — existing release scenarios and security coverage.
- `config.sh` — workspace resources, loopback hosts, ports, secret-host policy.
- `setup.sh` — installation and workspace creation behavior.
- `bin/msw` — command dispatch, lifecycle, credential transaction, quarantine, host-only push, backup/restore.
- `tests/test_suite.py` and `tests/fake_msb.py` — current simulator and failure-path contracts.

### Official Apple sources

- [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)
- [NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem)
- [NSPopover](https://developer.apple.com/documentation/appkit/nspopover)
- [NSWorkspace.OpenConfiguration](https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration)
- [ServiceManagement](https://developer.apple.com/documentation/servicemanagement)
- [Updating package installers with ServiceManagement](https://developer.apple.com/documentation/servicemanagement/updating-your-app-package-installer-to-use-the-new-service-management-api)
- [Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
- [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [SwiftUI Settings and OpenSettingsAction](https://developer.apple.com/documentation/swiftui/opensettingsaction)

### Official GitHub sources

- [Authorizing OAuth apps, including Device Flow](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps)
- [Differences between GitHub Apps and OAuth apps](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/differences-between-github-apps-and-oauth-apps)
- [Authenticating with a GitHub App on behalf of a user](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-with-a-github-app-on-behalf-of-a-user)
- [Generating a user access token for a GitHub App](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app)
- [Refreshing user access tokens](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens)
- [Choosing permissions for a GitHub App](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app)
- [Generating an installation access token](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app)

---

## Final recommendation

Build the app as a native macOS 26 product, not as a graphical wrapper around a terminal. Make setup, OAuth, and routine workspace operations first-class native experiences. Preserve the current safety boundary with six per-trust-domain GitHub Apps, expiring user tokens, transactional MSW credential handling, a narrow host helper, typed machine interfaces, and explicit confirmation for irreversible actions. Keep the terminal as a reliable escape hatch, never as a prerequisite.
