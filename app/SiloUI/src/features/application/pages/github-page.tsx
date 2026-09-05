import { useEffect, useMemo, useRef, useState } from "react"
import { Check, Loader2, TriangleAlert } from "lucide-react"

import { InlineConfirmation } from "@/components/inline-confirmation"
import { Button } from "@/components/ui/button"
import type {
  ApplicationActions,
  ApplicationGitHubConfiguration,
  ApplicationSource,
  GitHubWorkspaceOperation,
} from "@/features/application/model/application-source"
import {
  GitHubAccessEditor,
  type GitHubIdentity,
  type GitHubRepositorySelection,
} from "@/features/github/components/github-access-editor"

type WorkspaceSelections = Record<string, GitHubRepositorySelection[]>
type WorkspaceIdentities = Record<string, GitHubIdentity>
type WorkspaceOperations = Record<string, GitHubWorkspaceOperation>

interface GitHubDraft {
  selections: WorkspaceSelections
  identities: WorkspaceIdentities
}

function draftFromSource(
  policiesSnapshot: ApplicationSource["github"]["workspaces"],
  hostIdentity: ApplicationSource["github"]["hostIdentity"],
  workspaces: ApplicationSource["workspaces"],
): GitHubDraft {
  const policies = policiesSnapshot ?? workspaces.map((workspace) => ({
    workspace: workspace.machine.name,
    identity: {
      name: hostIdentity?.name ?? "",
      email: hostIdentity?.email ?? "",
      apply: true,
    },
    repositories: workspace.githubRepositories.map((repository) => ({ repository, allowPushes: false })),
  }))

  return {
    selections: Object.fromEntries(policies.map((policy) => [
      policy.workspace,
      policy.repositories.map((repository) => ({ ...repository })),
    ])),
    identities: Object.fromEntries(policies.map((policy) => [policy.workspace, { ...policy.identity }])),
  }
}

function copyDraft(draft: GitHubDraft): GitHubDraft {
  return {
    selections: Object.fromEntries(Object.entries(draft.selections).map(([workspace, selections]) => [
      workspace,
      selections.map((selection) => ({ ...selection })),
    ])),
    identities: Object.fromEntries(Object.entries(draft.identities).map(([workspace, identity]) => [workspace, { ...identity }])),
  }
}

function configurationFromDraft(source: ApplicationSource, draft: GitHubDraft, accessEnabled: boolean): ApplicationGitHubConfiguration {
  return {
    accessEnabled,
    hostIdentity: source.github.hostIdentity ?? null,
    workspaces: source.workspaces.map(({ machine }) => ({
      workspace: machine.name,
      identity: draft.identities[machine.name] ?? { name: "", email: "", apply: true },
      repositories: draft.selections[machine.name] ?? [],
    })),
  }
}

function operationsFromSource(operations: readonly GitHubWorkspaceOperation[] | undefined): WorkspaceOperations {
  return Object.fromEntries((operations ?? []).map((operation) => [operation.workspace, operation]))
}

function sameIdentity(left: GitHubIdentity | undefined, right: GitHubIdentity) {
  return left?.name === right.name && left.email === right.email && left.apply === right.apply
}

function WorkspaceSyncFeedback({
  operation,
  onRetry,
}: {
  operation: GitHubWorkspaceOperation
  onRetry: () => void
}) {
  if (operation.status === "applying") {
    return (
      <div className="flex min-h-8 items-center gap-2 rounded-md border border-border bg-muted/25 px-2.5 py-1.5 text-[11px]" role="status" aria-live="polite">
        <Loader2 className="size-3.5 shrink-0 animate-spin text-muted-foreground" aria-hidden="true" />
        <span>{operation.message}</span>
      </div>
    )
  }

  if (operation.status === "succeeded") {
    return (
      <div className="flex min-h-8 items-center gap-2 rounded-md border border-emerald-500/20 bg-emerald-500/[0.07] px-2.5 py-1.5 text-[11px] text-emerald-700 dark:text-emerald-400" role="status" aria-live="polite">
        <Check className="size-3.5 shrink-0" aria-hidden="true" />
        <span>{operation.message}</span>
      </div>
    )
  }

  if (operation.status === "failed") {
    return (
      <div className="grid min-h-8 grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-x-2 gap-y-1 rounded-md border border-destructive/25 bg-destructive/[0.07] px-2.5 py-1.5 text-[11px]" role="alert">
        <TriangleAlert className="size-3.5 shrink-0 text-destructive" aria-hidden="true" />
        <span className="text-destructive">{operation.message}</span>
        <Button type="button" variant="outline" size="xs" onClick={onRetry}>Retry</Button>
        {operation.diagnosticDetails && <p className="col-start-2 col-span-2 whitespace-pre-wrap text-[10px] leading-4 text-destructive/80">{operation.diagnosticDetails}</p>}
      </div>
    )
  }
}

export function GitHubPage({
  source,
  actions,
  onBusyChange,
}: {
  source: ApplicationSource
  actions: ApplicationActions
  onBusyChange?: (busy: boolean) => void
}) {
  const sourceDraft = useMemo(
    () => draftFromSource(source.github.workspaces, source.github.hostIdentity, source.workspaces),
    [source.github.hostIdentity, source.github.workspaces, source.workspaces],
  )
  const [draft, setDraft] = useState(() => copyDraft(sourceDraft))
  const [connectionState, setConnectionState] = useState(source.github.state)
  const [accessEnabled, setAccessEnabled] = useState(source.github.accessEnabled ?? true)
  const [workspaceOperations, setWorkspaceOperations] = useState<WorkspaceOperations>(() => operationsFromSource(source.github.workspaceOperations))
  const [confirmingDisconnect, setConfirmingDisconnect] = useState(false)
  const identityIntent = useRef<WorkspaceIdentities>(copyDraft(sourceDraft).identities)
  const catalogAvailable = source.github.repositoryCatalogStatus?.status !== "unavailable"
  const applying = Object.values(workspaceOperations).some((operation) => operation.status === "applying")
  const busy = connectionState === "connecting" || applying

  useEffect(() => {
    onBusyChange?.(busy)
  }, [busy, onBusyChange])

  useEffect(() => {
    // The bridge-provided snapshot is authoritative after a completed mutation.
    // oxlint-disable-next-line react/set-state-in-effect
    setDraft(copyDraft(sourceDraft))
    identityIntent.current = copyDraft(sourceDraft).identities
  }, [sourceDraft])

  useEffect(() => {
    // oxlint-disable-next-line react/set-state-in-effect
    setConnectionState(source.github.state)
    // oxlint-disable-next-line react/set-state-in-effect
    setAccessEnabled(source.github.accessEnabled ?? true)
    // oxlint-disable-next-line react/set-state-in-effect
    setConfirmingDisconnect(false)
  }, [source.github.accessEnabled, source.github.state])

  useEffect(() => {
    // A native replacement publishes the latest desired-versus-runtime state per workspace.
    // oxlint-disable-next-line react/set-state-in-effect
    setWorkspaceOperations(operationsFromSource(source.github.workspaceOperations))
  }, [source.github.workspaceOperations])

  useEffect(() => {
    const timers = Object.values(workspaceOperations)
      .filter((operation) => operation.status === "succeeded")
      .map((operation) => window.setTimeout(() => {
        setWorkspaceOperations((current) => {
          if (current[operation.workspace] !== operation) return current
          const next = { ...current }
          delete next[operation.workspace]
          return next
        })
      }, 4_000))
    return () => timers.forEach((timer) => window.clearTimeout(timer))
  }, [workspaceOperations])

  function applyWorkspaceDraft(workspace: string, nextDraft: GitHubDraft, message: string) {
    setDraft(nextDraft)
    setWorkspaceOperations((current) => ({
      ...current,
      [workspace]: { workspace, status: "applying", message },
    }))
    actions.saveGitHubConfiguration?.(configurationFromDraft(source, nextDraft, accessEnabled))
  }

  function updateSelections(workspace: string, selections: GitHubRepositorySelection[]) {
    applyWorkspaceDraft(workspace, {
      ...draft,
      selections: { ...draft.selections, [workspace]: selections },
    }, "Applying repository access…")
  }

  function updateIdentity(workspace: string, identity: GitHubIdentity) {
    const previous = draft.identities[workspace]
    const nextDraft = {
      ...draft,
      identities: { ...draft.identities, [workspace]: identity },
    }
    setDraft(nextDraft)
    if (previous?.apply !== identity.apply) commitIdentity(workspace, identity, nextDraft)
  }

  function commitIdentity(workspace: string, identity: GitHubIdentity, currentDraft = draft) {
    if (!identity.name.trim() || !identity.email.trim() || sameIdentity(identityIntent.current[workspace], identity)) return
    identityIntent.current = { ...identityIntent.current, [workspace]: { ...identity } }
    applyWorkspaceDraft(workspace, {
      ...currentDraft,
      identities: { ...currentDraft.identities, [workspace]: identity },
    }, "Applying Git identity…")
  }

  function resetIdentity(workspace: string) {
    if (!source.github.hostIdentity) return
    const identity = { ...source.github.hostIdentity, apply: true }
    const nextDraft = {
      ...draft,
      identities: { ...draft.identities, [workspace]: identity },
    }
    identityIntent.current = { ...identityIntent.current, [workspace]: identity }
    applyWorkspaceDraft(workspace, nextDraft, "Applying Git identity…")
  }

  function retryWorkspace(workspace: string) {
    setWorkspaceOperations((current) => ({
      ...current,
      [workspace]: { workspace, status: "applying", message: "Retrying GitHub access…" },
    }))
    actions.retryGitHubConfiguration?.(workspace)
  }

  function toggleAccess() {
    const nextEnabled = !accessEnabled
    setAccessEnabled(nextEnabled)
    actions.setGitHubAccessEnabled?.(nextEnabled)
  }

  function disconnect() {
    setConfirmingDisconnect(false)
    setConnectionState("disconnected")
    setWorkspaceOperations({})
    actions.disconnectGitHub?.()
  }

  const catalogNotice = source.github.repositoryCatalogStatus?.status === "unavailable" ? (
    <div className="flex items-center gap-3 rounded-md border border-destructive/25 bg-destructive/8 px-3 py-2 text-xs" role="alert">
      <TriangleAlert className="size-3.5 shrink-0 text-destructive" aria-hidden="true" />
      <span className="min-w-0 flex-1">{source.github.repositoryCatalogStatus.message}</span>
      <Button type="button" variant="outline" size="xs" onClick={() => actions.retryGitHubRepositoryCatalog?.()}>Retry repositories</Button>
    </div>
  ) : undefined

  const connectedActions = (
    <InlineConfirmation active={confirmingDisconnect} onDismiss={() => setConfirmingDisconnect(false)}>
      {confirmingDisconnect ? (
        <>
          <Button type="button" variant="ghost" size="xs" onClick={() => setConfirmingDisconnect(false)}>Cancel</Button>
          <Button type="button" variant="destructive" size="xs" onClick={disconnect}>Disconnect</Button>
        </>
      ) : (
        <>
          <Button type="button" variant="outline" size="xs" disabled={applying} onClick={toggleAccess}>{accessEnabled ? "Disable access" : "Enable access"}</Button>
          <Button type="button" variant="ghost" size="xs" disabled={applying} onClick={() => setConfirmingDisconnect(true)}>Disconnect</Button>
        </>
      )}
    </InlineConfirmation>
  )

  return (
    <div className="mx-auto flex h-full min-h-0 w-full max-w-3xl flex-col px-4 py-5 sm:px-6 sm:py-6">
      <GitHubAccessEditor
        compactConnection
        workspaces={source.workspaces.map(({ machine }) => ({ name: machine.name }))}
        connectionState={connectionState}
        repositoryOptions={source.github.repositoryCatalog ?? []}
        workspaceSelections={draft.selections}
        workspaceIdentities={draft.identities}
        currentHostGitIdentity={source.github.hostIdentity ?? null}
        onConnect={() => {
          setConnectionState("connecting")
          actions.connectGitHub?.()
        }}
        onWorkspaceSelectionsChange={updateSelections}
        onWorkspaceIdentityChange={updateIdentity}
        onCommitWorkspaceIdentity={commitIdentity}
        onResetWorkspaceIdentity={resetIdentity}
        connectedTitle={`Connected as @${source.github.account ?? "unknown"}`}
        connectedDetail={accessEnabled
          ? "Repository credentials are scoped to each workspace."
          : "Repository access is disabled."}
        connectedActions={connectedActions}
        notice={catalogNotice}
        renderWorkspaceNotice={({ name }) => {
          const operation = workspaceOperations[name]
          return operation
            ? <WorkspaceSyncFeedback operation={operation} onRetry={() => retryWorkspace(name)} />
            : undefined
        }}
        disabled={!accessEnabled}
        repositoryControlsAvailable={catalogAvailable}
        confirmRepositoryClear
        busy={applying}
      />
    </div>
  )
}
