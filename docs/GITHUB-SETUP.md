# GitHub access in MSW Monitor

GitHub can be connected during setup or skipped.

## Current availability

**Connect GitHub** and **Skip GitHub** are the only choices in first-run
setup. A configured MSW Connect service and trusted token-bound scope
attestations are required to complete authorization. If connection cannot start,
setup says so concisely and leaves both choices available; it does not expose
release configuration, credential, or repository diagnostics. Settings shows the
connection status when configuration or existing access needs attention.

## Scoped workspace grants with MSW Connect

When the build is configured for MSW Connect, **Connect GitHub** opens the
hosted browser authorization flow. After GitHub returns, MSW Monitor lists the
repositories exposed by each GitHub App installation in one compact,
workspace-first editor:

- Each workspace lists the repositories it may use.
- Checking a repository assigns it to that workspace.
- Every new assignment defaults to **Read-only**.
- A selected repository shows exactly **Read-only** and **Read & write**.
- A workspace can currently select repositories from one installation/owner at
  a time. The MSW host protocol carries one credential per workspace and role,
  so the editor blocks combinations that protocol cannot represent.

Nothing changes until the policy is reviewed and applied. Each policy row
carries the stable repository ID, full name, installation ID, owner ID/login,
and access mode. Grant creation is partitioned by workspace and installation:

- the guest read grant contains every selected repository;
- the host write grant contains only repositories marked **Read & write**;
- each generated role uses the first repository in deterministic name/ID order
  that is eligible for that role as its verification repository.

MSW Connect must return short-lived installation credentials scoped to those
exact repository sets with a token-bound signed scope attestation. The
attestation binds the policy digest, grant ID, credential digest, generation,
and issue/expiry timestamps. MSW Monitor rejects broader, mismatched, unsigned,
or token-swapped responses, stores credentials in separate guest/host Keychain
records, and persists only non-secret metadata. The guest capability is bound
through MSW's verified workspace path; the host credential is used only for
explicit host pushes.

Applying policy is journaled and transactional. Replacement grant revocation,
local credential rollback, quarantine, cancellation, lifecycle restoration,
session renewal, and reconnect recovery remain fail-closed.


## Recovery and disconnect

Settings summarizes a connected account once and lists the effective scoped
workspace grants without displaying credentials. Actions have distinct
meanings:

- **Connect** appears only when the service is ready and there is no access.
- **Edit** changes an already healthy repository scope.
- **Retry** handles a temporary service/network or renewal outage and never
  opens a browser.
- **Reconnect _workspace_** replaces a proven revoked, missing, removed, or
  scope-mismatched grant and names the affected workspace and reason.
- **Remove** explicitly unbinds workspace access, revokes remote grants, and
  cleans up local records only after those steps are proven.

Short-lived token expiry is normal and renews silently. A successful renewal
stays Ready; a temporary renewal outage becomes Retry; revoked, missing, or
mismatched grants become Reconnect. If revocation or cleanup cannot be proven,
the old record remains visible and quarantined. The app never claims removal,
and an unconfigured build cannot offer a destructive cleanup action it cannot
verify.

The MSW Connect endpoint, client, installation URL, and token-bound
scope-attestation public key are release inputs. No GitHub App private key
belongs in the desktop app. This repository verifies the client-side contract;
release remains blocked until the deployed Connect service issues and is
integration-tested with matching token-bound attestations.
