# GitHub: direct connection through the MSW GitHub App

GitHub access is managed by **MSW Monitor** through the MSW GitHub App
(`https://github.com/apps/microsandbox-workspaces/installations/new`). The
previous Connect-service/scoped-grant design was removed from onboarding. No
personal access token, no client secret, and no GitHub App private key are ever
needed or stored.

## How connecting works

1. In **MSW Monitor** (Settings → GitHub → Connect GitHub, or the first-run
   setup window), choose **Connect GitHub**.
2. GitHub opens in your default browser with a short code. Approve it.
3. Choose your repositories on the App installation page (App-wide selection;
   per-workspace routing is part of the pending host mediation).
4. MSW Monitor stores the session in the **macOS Keychain**: the account
   identity, an access token, and its refresh token.
5. Signing in alone does not complete the GitHub step: MSW Monitor verifies
   that the App is installed with selected repositories. Until then the step
   shows "no repositories are selected yet" with **Choose repositories on
   GitHub** and **Check again**, and setup can continue without GitHub.
6. The access token expires after eight hours. While setup is open, the app
   renews it with the refresh token. If the refresh token expires or is
   revoked, GitHub approval is required again.

## Security model

- The session lives **host-side only**, in the macOS Keychain.
- Workspaces never receive the token, and the token is **never bound into VM
  traffic**. A single user token is not both read and write: reusing it in the
  VM path would give a workspace write access.
- Workspace GitHub operations are **host-mediated**: clone, fetch, and pull
  run on the Mac (which holds the session) and deliver files into the
  workspace; push runs on the Mac as an explicit `msw push`. The repository
  selection made on GitHub constrains what the session can reach.
- **Not yet implemented:** the host-mediated workspace operations and their
  verification steps. Until they land, `msw push` and workspace
  clone/fetch/pull do not consume this session, and the per-workspace
  allowlist is saved but not yet enforced — the checkboxes are UI and
  persistence only, not access control yet.

## Setup behavior

The GitHub step is always present in setup (Readiness → GitHub → Identity →
Review). It shows one of:

- **Connect GitHub** — the build has the GitHub App configured; clicking it
  starts the device flow in the default browser.
- **Connected as @login** — a session exists; the step offers **Choose
  repositories on GitHub** and Continue.
- **Signed in as @login, but repository status could not be refreshed.** —
  a re-check failed. A genuinely retryable transport failure keeps **Check
  again**; a consumed or expired session that cannot be refreshed instead
  offers **Reconnect GitHub**, which starts a fresh device flow — the
  reauthorization-required state has no retry path, and the previous
  credential is discarded.
- **GitHub connection isn't available yet** — the build has no App
  configured; setup continues without GitHub.

The client ID and installation URL are build inputs (`MSW_GITHUB_CLIENT_ID`,
`MSW_GITHUB_INSTALLATION_URL`). The client ID is public by GitHub's design and
may be embedded; the private key must never be generated for this flow.

## Disconnect

Not yet implemented in this build. Until a Disconnect action ships, revoke the
authorization from your GitHub settings (Applications → Authorized OAuth Apps
/ GitHub Apps) and delete the Keychain item
`org.microsandbox.MSWMonitor.github-device-session`.
