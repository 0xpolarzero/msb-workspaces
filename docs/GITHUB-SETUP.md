# GitHub setup: read-only inside VMs, explicit pushes from the Mac

This setup uses two different fine-grained personal access tokens for each workspace:

1. A **guest read token**. It lets the VM clone, fetch, and pull selected private repositories. GitHub rejects pushes made with it.
2. A **host write token**. It stays in macOS Keychain and is used only when you explicitly run `msw push` or the permission verifier.

Agents can create branches, edit, commit, merge, rebase, and inspect history locally without any write credential.

For a workspace that only needs private read access, omit the host credential:

```bash
msw github setup playgrounds OWNER/msw-verification --read-only
```

The command stores only the guest read token and removes any host write token for that workspace.

## Before creating tokens

Choose one repository that will be used to verify permissions. It must:

- Belong to the same resource owner as the other selected repositories.
- Be selected in both tokens.
- Permit the host token to create and delete a temporary branch.
- Be safe for a temporary empty verification commit and branch; the branch is deleted automatically.

A small private repository such as `OWNER/msw-verification` is ideal.

Fine-grained tokens are scoped to one resource owner. A workspace that needs private repositories from two different owners normally needs to be split by owner, or one set of repositories must use another authentication mechanism. Public repositories do not require the private read token.

## Token 1: guest read-only token

In GitHub, create a new **fine-grained personal access token** with:

```text
Token name:          msw-dev-read       (or msw-personal-read, etc.)
Expiration:          your preferred rotation period
Resource owner:      the user or organization owning the repositories
Repository access:  Only select repositories
Selected repos:      every repository this VM may read, including verification repo
```

Repository permissions:

```text
Contents:  Read-only
Metadata:  Read-only (GitHub adds this automatically)
```

Leave every other permission at **No access** unless a tool genuinely needs read access. Optional examples are Issues: Read-only or Pull requests: Read-only. Do not grant any write permission.

An organization may require an administrator to approve the token before private-repository access works.

## Token 2: host write token

Create a second fine-grained token:

```text
Token name:          msw-dev-host-write
Expiration:          your preferred rotation period
Resource owner:      same owner as the read token
Repository access:  Only select repositories
Selected repos:      only repositories you are willing to push from this workspace,
                     including the verification repo
```

Repository permissions:

```text
Contents:   Read and write
Metadata:   Read-only (automatic)
```

Only when you need to push changes under `.github/workflows/`, also grant:

```text
Workflows:  Read and write
```

No administration, secrets, webhooks, organization, or other write permissions are required by MSW.

The host token's selected repository list is the definitive set of repositories `msw push` can modify.

## Configure a workspace

Run:

```bash
msw github setup dev OWNER/msw-verification
```

Paste the guest read token, then the host write token. Input is hidden.

For a read-only workspace, add `--read-only`:

```bash
msw github setup playgrounds OWNER/msw-verification --read-only
```

This prompts for only the guest token. `msw github verify playgrounds` reruns the read-only check.

The command performs all of these checks automatically:

1. Stores both tokens in macOS Keychain under separate services.
2. Binds only the read token to the VM through MicroSandbox secret substitution.
3. Clones the verification repository from inside the VM.
4. Creates a temporary local branch and commit.
5. Confirms that a direct guest push is rejected by GitHub.
6. Transfers the committed branch through the host-only push path.
7. Confirms the branch exists remotely.
8. Deletes the temporary branch with the host-only credential.
9. Confirms cleanup.

If any step fails, the newly entered credentials are removed and the previously working credential pair is restored.

Repeat for all groups:

```bash
msw github setup dev OWNER/msw-verification
msw github setup playgrounds OWNER/msw-verification
msw github setup personal OWNER/msw-verification
```

Using different selected-repository lists for each pair provides meaningful separation. You may use tokens from the same GitHub account.

A workspace that does not use GitHub needs no `msw github setup` command.

## Check or rotate credentials

Show only credential presence and the recorded verification repository; tokens are never printed:

```bash
msw github status all
```

Rerun the permission test:

```bash
msw github verify dev
```

Rotate either token by running setup again:

```bash
msw github setup dev OWNER/msw-verification
```

Remove both credentials and the guest secret binding:

```bash
msw github remove dev
```

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

The guest sees a MicroSandbox placeholder, not the real token. The real read token remains host-held and is substituted only for requests to `github.com` and `api.github.com`.

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

This is enforced by the token's server-side GitHub permissions, not merely by a local hook or Git setting.

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
- The host write token in the VM

Git LFS objects referenced by the outgoing commits are copied one by one, checked as regular files, verified against their SHA-256 object IDs, and uploaded through the host-only credential path.

The privileged host Git process runs with an isolated temporary home and no system/global Git configuration, no custom hooks, no SSH agent, and no ambient GitHub token environment variable.

## Where credentials live

```text
Guest read token:  macOS Keychain + MicroSandbox host-side secret binding
Guest filesystem:  placeholder only
Host write token:  macOS Keychain only
Backups:           neither Keychain token is included
```

Every agent in a VM can use that VM's read capability, but cannot retrieve the actual read token through the designed interface and has no host write token.

## Limits of this model

- It prevents guest-authenticated pushes to repositories selected in GitHub.
- It limits host pushes to repositories selected in the host write token.
- It does not stop an internet-enabled agent from uploading readable source files to an unrelated service.
- It does not protect one repository from another process inside the same workspace.
- GitHub repository rules or organization policies can still reject an otherwise authorized host push.
