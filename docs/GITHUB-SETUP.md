# GitHub access in MSW Monitor

GitHub is optional. MSW Monitor supports two connection capabilities and keeps
their UI deliberately distinct.

## Scoped workspace grants with MSW Connect

When the build is configured for MSW Connect, **Connect GitHub** opens the
hosted browser authorization flow. After GitHub returns, MSW Monitor lists the
repositories exposed by each GitHub App installation and shows one compact,
repository-first editor:

- Select the workspaces that may read a repository.
- Every new selection defaults to **Read-only**.
- The mode menu appears only after a repository is selected and offers exactly
  **Read-only** and **Read & write**.
- A workspace can currently select repositories from one installation/owner at
  a time. The MSW host protocol carries one credential per workspace and role,
  so the UI blocks combinations that protocol cannot represent.

Nothing changes until the policy is reviewed and applied. Each policy row
carries the stable repository ID, full name, installation ID, owner ID/login,
and access mode. Grant creation is partitioned by workspace and installation:

- the guest read grant contains every selected repository;
- the host write grant contains only repositories marked **Read & write**;
- each generated role uses the first repository in deterministic name/ID order
  that is eligible for that role as its verification repository.

MSW Connect returns short-lived installation credentials scoped to those exact
repository sets. MSW Monitor rejects broader or mismatched responses, stores
credentials in separate guest/host Keychain records, and persists only
non-secret metadata. The guest capability is bound through MSW's verified
workspace path; the host credential is used only for explicit host pushes.

Applying policy is journaled and transactional. Replacement grant revocation,
local credential rollback, quarantine, cancellation, lifecycle restoration,
session renewal, and reauthorization remain fail-closed.

## Direct GitHub device connection

Some builds expose GitHub's device flow directly. It stores the user session in
the macOS Keychain and uses GitHub's App installation page to choose the
repositories visible to that session. The direct protocol does not mint the
separate repository-scoped guest and host grants consumed by MSW.

For that reason, Setup and Settings do not show per-workspace or write controls
for a direct connection. They show the connected account, repository-selection
status, and an actionable **Reconnect GitHub** state when refresh can no longer
continue safely. Repository selection remains on GitHub. This is connection
metadata, not workspace authorization.

## Recovery and disconnect

Settings summarizes a connected account once and lists the effective scoped
workspace grants without displaying credentials. **Edit repository access**
reopens the same setup editor. Reconnect is used for expired, revoked, removed,
or otherwise unrecoverable authorization. Removing a workspace grant or
disconnecting a Connect account revokes remote grants before local cleanup;
uncertain cleanup quarantines the affected roles.

The direct-device client ID and installation URL are public build inputs
(`MSW_GITHUB_CLIENT_ID`, `MSW_GITHUB_INSTALLATION_URL`). MSW Connect endpoint,
client, installation URL, and scope-attestation key are separate release
inputs. No GitHub App private key belongs in the desktop app.
