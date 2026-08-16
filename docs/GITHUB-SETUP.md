# GitHub access in MSW Monitor

GitHub is optional. MSW Monitor uses MSW Connect to apply one scoped
repository policy to every workspace.

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
session renewal, and reauthorization remain fail-closed.


## Recovery and disconnect

Settings summarizes a connected account once and lists the effective scoped
workspace grants without displaying credentials. **Edit repository access**
reopens the same setup editor. Reconnect is used for expired, revoked, removed,
or otherwise unrecoverable authorization. Removing a workspace grant or
disconnecting a Connect account revokes remote grants before local cleanup;
uncertain cleanup quarantines the affected roles.

The MSW Connect endpoint, client, installation URL, and token-bound
scope-attestation public key are release inputs. No GitHub App private key
belongs in the desktop app. This repository verifies the client-side contract;
release remains blocked until the deployed Connect service issues and is
integration-tested with matching token-bound attestations.
