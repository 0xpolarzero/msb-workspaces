# GitHub authorization: scoped Connect grants

GitHub authorization is managed by **MSW Monitor** and the MSW Connect service. The legacy CLI flow that prompted for personal access tokens was removed. Do not paste a GitHub token into `msw` or into the app.

The result is still two separate capabilities for each workspace:

1. A **guest-read grant**. It is limited to the selected GitHub owner and repositories and is usable only through the VM's read path. GitHub rejects guest-authenticated pushes.
2. A **host-write grant**. It is limited to the reviewed repository set, remains host-held, and is used only by the explicit `msw push` path.

The Connect service issues short-lived, workspace-scoped grant material. MSW Monitor stores grant metadata and the host-side credentials needed to deliver those capabilities; it never stores a broad user token as a substitute for a scoped grant. The app does not contain a GitHub App private key or client secret.

## Before connecting

Choose the GitHub owner and repositories that each workspace may access. Keep workspace scopes separate when they represent different trust domains.

For a workspace that needs a host-only push path, select:

- The GitHub owner whose App installation provides the repositories.
- Every repository the VM may clone, fetch, or pull.
- Every repository the host may push, including the verification repository.
- A non-empty verification repository with an existing branch, normally `main`, when the Connect service requests one.

The owner must have installed the MSW GitHub App. Organization policy, SAML enforcement, or an unapproved installation can prevent authorization; MSW Monitor reports the recovery action instead of accepting an incomplete grant.

### Recover when no installation is available

If Connect returns an account with no GitHub App installation, MSW Monitor shows
an **Install MSW App in GitHub** action when the signed build has a verified
installation URL configured. Follow that action, approve the app for the
intended owner, and return to MSW Monitor to connect GitHub again; the owner
list is refreshed only by a new authorization session.

The action is supplied through the `MSWConnectInstallationURL` Info.plist key
and the `MSW_CONNECT_INSTALLATION_URL` build setting. Empty or malformed values
are treated as absent, so the app does not open an arbitrary URL. This source
tree intentionally leaves the release URL as a deployment input rather than
publishing an unverified GitHub App slug. If no verified URL is present, the
setup window explains that the release administrator must provide the approved
installation link; continue without GitHub or use an existing assignment.
For a local or release build, pass the approved installation URL explicitly:

```bash
MSW_CONNECT_INSTALLATION_URL="https://github.com/apps/<approved-slug>/installations/new" \
  app/MSWMonitor/Scripts/build.sh
```

The placeholder must be replaced by the release administrator with the verified MSW GitHub App slug. Do not publish or ship an unverified slug; an empty setting is intentionally safe and keeps the install action unavailable.

## Connect a workspace

Open **MSW Monitor** and choose **Settings** → **GitHub** → **Connect GitHub**. The first-run setup window exposes the same action.

The flow is:

1. MSW Monitor starts a Connect authorization session with a fresh state value.
2. The authorization page opens in your default browser. Complete GitHub authorization there; GitHub sends the callback back to MSW Monitor through the registered `msw://` URL scheme.
3. Return to MSW Monitor. The app verifies the callback/session, account, and service issuer.
4. Select the installed GitHub owner.
5. Select the repositories available from that installation and choose the verification repository when required.
6. Review the guest-read and host-write scope for each workspace.
7. Apply the assignment. The service validates the scope and returns a grant; the app commits the grant metadata and credential material transactionally.
8. If the workspace is running, MSW Monitor reports whether a restart is required before the new guest capability is active. It never silently restarts a VM.

Repeat the flow for `dev`, `playgrounds`, and `personal` when their repository scopes differ. A workspace that does not use private GitHub repositories needs no grant.

The GitHub step is always present in setup. Builds without a configured MSW Connect endpoint (an empty `MSW_CONNECT_BASE_URL`) show "GitHub connection isn't available yet" on that step, so onboarding never offers a page that cannot connect and always continues without GitHub. A build configured with a real endpoint shows **Connect GitHub**, which opens the authorization page in the default browser; provide the endpoint and client ID at build time through the `MSW_CONNECT_BASE_URL` and `MSW_CONNECT_CLIENT_ID` environment variables passed to `app/MSWMonitor/Scripts/build.sh`.


The app shows an explicit state for each workspace:

- **Ready** — the grant is present, scoped, and usable.
- **Needs authorization** — Connect must be completed again.
- **Needs restart** — the grant is valid but the running VM has not rebound it yet.
- **Quarantined** — cleanup or verification was uncertain; stop the workspace and follow the recovery action shown by MSW Monitor.

The app must not treat a successful browser callback as proof of repository access. It verifies the returned account, installation owner, repository IDs/names, role, expiry, and scope digest before committing the assignment.

## Reauthorize, rotate, or disconnect

Use the **Reauthorize** action in MSW Monitor Settings to obtain a new service grant. Existing assignments remain unchanged until the replacement grant passes validation and the transaction commits.

Use **Disconnect** for one workspace when its GitHub access should be removed. MSW Monitor first removes the VM-held secret, then revokes the service grant and local metadata. If either cleanup step cannot be proven, the workspace remains quarantined instead of presenting a successful disconnect with an uncertain credential state.

The CLI commands are limited to inspecting and verifying the current scoped Connect grants:

```text
msw github setup …       removed; use MSW Monitor → Settings → GitHub
msw github status …      current scoped-grant status
msw github verify …      current scoped-grant verification
msw github remove …      refuses Connect grants; disconnect them in MSW Monitor
```

`msw github verify WORKSPACE [OWNER/REPO]` exercises the selected guest-read
grant and, for a host-write assignment, the host-only push path. It does not
accept a GitHub user token. `msw github status` reports whether the app-managed
guest and host grant records are usable; it never prints credential material.
`msw github remove` remains only for legacy local-token metadata and refuses to
delete a current Connect grant without revoking it from the service.

## Clone and pull from the VM

```bash
msw clone dev OWNER/backend clients/acme/backend
msw pull dev clients/acme/backend
msw pull dev all
```

Inside the VM, ordinary commands work too:

```bash
msw dev clients/acme/backend
git fetch --prune
git pull --ff-only
```

The guest sees a MicroSandbox placeholder, not the service-issued credential. The actual guest-read grant remains host-held and is substituted only for requests to `github.com` and `api.github.com`.

## Commit locally

No GitHub credential is needed to commit:

```bash
git switch -c feature/new-api
git add .
git commit -m "Add the API"
```

A direct push from the VM is expected to fail:

```bash
git push
```

This is enforced by the guest grant's server-side GitHub permissions, not merely by a local hook or Git setting.

## Push from the Mac

From any macOS terminal:

```bash
msw push dev clients/acme/backend
```

MSW displays:

- Workspace
- Canonical GitHub repository
- Workspace-relative path
- Current branch
- Exact commit
- Fast-forward status
- Commits to be sent

Type `PUSH` to approve.

Skip the prompt only when intended:

```bash
msw push dev clients/acme/backend --yes
```

The default push is fast-forward-only. For a deliberate history rewrite:

```bash
msw push dev clients/acme/backend --force-with-lease
```

The force operation is tied to the exact remote SHA observed immediately before transfer. A concurrent remote change causes the push to fail rather than overwrite it.

## What the host-only push transfers

`msw push` transfers only the current committed branch through a verified Git bundle. It does not include:

- Uncommitted or untracked files
- Other local branches
- Local tags
- Your normal Mac Git configuration or hooks
- The host-write grant in the VM

Git LFS objects referenced by the outgoing commits are copied one by one, checked as regular files, verified against their SHA-256 object IDs, and uploaded through the host-only credential path.

The privileged host Git process runs with an isolated temporary home and no system/global Git configuration, no custom hooks, no SSH agent, and no ambient GitHub token environment variable.

## Where credentials live

```text
Guest-read grant:   macOS Keychain + MicroSandbox host-side secret binding
Guest filesystem:   placeholder only
Host-write grant:   macOS Keychain only
Grant metadata:     MSW Monitor application support state; no token values
Backups:            no grant secret or Keychain credential is included
```

Every agent in a VM can use that VM's selected read capability, but cannot retrieve the actual credential through the designed interface and has no host-write capability.

## Limits of this model

- It prevents guest-authenticated pushes to repositories selected in GitHub.
- It limits host pushes to the repositories selected in the service-issued host grant.
- It does not stop an internet-enabled agent from uploading readable source files to an unrelated service.
- It does not protect one repository from another process inside the same workspace.
- GitHub repository rules or organization policies can still reject an otherwise authorized host push.

