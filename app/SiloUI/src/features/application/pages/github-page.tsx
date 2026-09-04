import { useEffect, useMemo, useState } from "react"
import { Check, Loader2, RotateCcw, TriangleAlert } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip"
import type {
  ApplicationActions,
  ApplicationGitHubConfiguration,
  ApplicationSource,
  GitHubManagementOperation,
} from "@/features/application/model/application-source"
import {
  GitHubAccessEditor,
  type GitHubIdentity,
  type GitHubRepositorySelection,
} from "@/features/github/components/github-access-editor"

type WorkspaceSelections = Record<string, GitHubRepositorySelection[]>
type WorkspaceIdentities = Record<string, GitHubIdentity>

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

function GitHubOperationFooter({
  operation,
  onSave,
  onCancel,
  onRetry,
}: {
  operation: GitHubManagementOperation
  onSave: () => void
  onCancel: () => void
  onRetry: () => void
}) {
  if (operation.status === "idle") return null

  if (operation.status === "dirty") {
    return (
      <div className="flex min-h-9 items-center gap-3 rounded-md border border-amber-500/25 bg-amber-500/8 px-3 py-2">
        <span className="size-1.5 shrink-0 rounded-full bg-amber-500" aria-hidden="true" />
        <span className="min-w-0 flex-1 text-xs font-medium">{operation.message}</span>
        <Button type="button" variant="ghost" size="xs" onClick={onCancel}>Cancel</Button>
        <Button type="button" size="xs" onClick={onSave}>Save changes</Button>
      </div>
    )
  }

  if (operation.status === "saving") {
    return (
      <div className="flex min-h-9 items-center gap-3 rounded-md border border-border px-3 py-2" role="status" aria-live="polite">
        <Loader2 className="size-3.5 shrink-0 animate-spin text-muted-foreground" aria-hidden="true" />
        <span className="min-w-0 flex-1 text-xs">{operation.message}</span>
        {operation.canCancel && <Button type="button" variant="ghost" size="xs" onClick={onCancel}>Cancel</Button>}
      </div>
    )
  }

  if (operation.status === "succeeded") {
    return (
      <div className="flex min-h-9 items-center gap-3 rounded-md border border-emerald-500/20 bg-emerald-500/8 px-3 py-2" role="status" aria-live="polite">
        <Check className="size-3.5 shrink-0 text-emerald-600 dark:text-emerald-400" aria-hidden="true" />
        <span className="text-xs font-medium text-emerald-700 dark:text-emerald-400">{operation.message}</span>
      </div>
    )
  }

  if (operation.status === "failed") {
    return (
      <div className="grid grid-cols-[auto_minmax(0,1fr)_auto_auto] items-center gap-x-3 gap-y-1 rounded-md border border-destructive/25 bg-destructive/8 px-3 py-2" role="alert">
        <TriangleAlert className="size-3.5 text-destructive" aria-hidden="true" />
        <span className="min-w-0 text-xs font-medium text-destructive">{operation.message}</span>
        {operation.canRetry && <Button type="button" variant="outline" size="xs" onClick={onRetry}>Retry</Button>}
        {operation.canCancel && <Button type="button" variant="ghost" size="xs" onClick={onCancel}>Cancel</Button>}
        {operation.diagnosticDetails && <p className="col-start-2 col-span-3 whitespace-pre-wrap text-[11px] leading-4 text-destructive/80">{operation.diagnosticDetails}</p>}
      </div>
    )
  }

  return (
    <div className="flex min-h-9 items-center gap-3 rounded-md border border-border bg-muted/40 px-3 py-2" role="status">
      <span className="size-1.5 shrink-0 rounded-full bg-muted-foreground" aria-hidden="true" />
      <span className="text-xs">{operation.message}</span>
    </div>
  )
}

export function GitHubPage({ source, actions }: { source: ApplicationSource; actions: ApplicationActions }) {
  const sourceDraft = useMemo(
    () => draftFromSource(source.github.workspaces, source.github.hostIdentity, source.workspaces),
    [source.github.hostIdentity, source.github.workspaces, source.workspaces],
  )
  const [savedDraft, setSavedDraft] = useState(() => copyDraft(sourceDraft))
  const [draft, setDraft] = useState(() => copyDraft(sourceDraft))
  const [connectionState, setConnectionState] = useState(source.github.state)
  const [accessEnabled, setAccessEnabled] = useState(source.github.accessEnabled ?? true)
  const [operation, setOperation] = useState<GitHubManagementOperation>(source.github.operation ?? { status: "idle" })
  const [confirmingClear, setConfirmingClear] = useState(false)
  const catalogAvailable = source.github.repositoryCatalogStatus?.status !== "unavailable"
  const editorBusy = operation.status === "saving"
  const editorDisabled = editorBusy || !accessEnabled

  useEffect(() => {
    // The bridge-provided GitHub snapshot becomes the new edit baseline.
    // oxlint-disable-next-line react/set-state-in-effect
    setSavedDraft(copyDraft(sourceDraft))
    // oxlint-disable-next-line react/set-state-in-effect
    setDraft(copyDraft(sourceDraft))
    // oxlint-disable-next-line react/set-state-in-effect
    setConnectionState(source.github.state)
    // oxlint-disable-next-line react/set-state-in-effect
    setAccessEnabled(source.github.accessEnabled ?? true)
    // oxlint-disable-next-line react/set-state-in-effect
    setOperation(source.github.operation ?? { status: "idle" })
    // oxlint-disable-next-line react/set-state-in-effect
    setConfirmingClear(false)
  }, [source.github.accessEnabled, source.github.operation, source.github.state, sourceDraft])

  function markDirty(nextDraft: GitHubDraft) {
    setDraft(nextDraft)
    setOperation({ status: "dirty", message: "GitHub access has unsaved changes.", canCancel: true })
  }

  function cancelChanges() {
    setDraft(copyDraft(savedDraft))
    setOperation({ status: "idle" })
    actions.cancelGitHubConfiguration?.()
  }

  function saveChanges() {
    setOperation({ status: "saving", message: `Applying GitHub access to ${source.workspaces.length} sandboxes…`, canCancel: true })
    actions.saveGitHubConfiguration?.(configurationFromDraft(source, draft, accessEnabled))
  }

  function retrySave() {
    setOperation({ status: "saving", message: `Applying GitHub access to ${source.workspaces.length} sandboxes…`, canCancel: true })
    actions.retryGitHubConfiguration?.()
  }

  function toggleAccess() {
    const nextEnabled = !accessEnabled
    setAccessEnabled(nextEnabled)
    setOperation(nextEnabled
      ? { status: "idle" }
      : { status: "disabled", message: "Repository access is disabled. Existing selections are preserved." })
    actions.setGitHubAccessEnabled?.(nextEnabled)
  }

  function disconnect() {
    setConfirmingClear(false)
    setConnectionState("disconnected")
    setOperation({ status: "idle" })
    actions.disconnectGitHub?.()
  }

  function confirmClear() {
    setConfirmingClear(false)
    setDraft((current) => ({
      ...current,
      selections: Object.fromEntries(source.workspaces.map(({ machine }) => [machine.name, []])),
    }))
    setOperation({ status: "saving", message: "Clearing repository access…", canCancel: true })
    actions.clearGitHubRepositoryAccess?.()
  }

  const catalogNotice = source.github.repositoryCatalogStatus?.status === "unavailable" ? (
    <div className="flex items-center gap-3 rounded-md border border-destructive/25 bg-destructive/8 px-3 py-2 text-xs" role="alert">
      <TriangleAlert className="size-3.5 shrink-0 text-destructive" aria-hidden="true" />
      <span className="min-w-0 flex-1">{source.github.repositoryCatalogStatus.message}</span>
      <Button type="button" variant="outline" size="xs" onClick={() => actions.retryGitHubRepositoryCatalog?.()}>Retry repositories</Button>
    </div>
  ) : undefined

  const connectedActions = confirmingClear ? (
    <>
      <Button type="button" variant="ghost" size="xs" onClick={() => setConfirmingClear(false)}>Cancel</Button>
      <Button type="button" variant="destructive" size="xs" onClick={confirmClear}>Clear repositories</Button>
    </>
  ) : (
    <>
      <Button type="button" variant="outline" size="xs" disabled={editorBusy} onClick={toggleAccess}>{accessEnabled ? "Disable access" : "Enable access"}</Button>
      <Button type="button" variant="ghost" size="xs" disabled={editorBusy} onClick={disconnect}>Disconnect</Button>
      <TooltipProvider delayDuration={150}>
        <Tooltip>
          <TooltipTrigger asChild>
            <Button type="button" variant="ghost" size="icon-xs" aria-label="Clear repositories" disabled={editorBusy} onClick={() => setConfirmingClear(true)}>
              <RotateCcw className="size-3" aria-hidden="true" />
            </Button>
          </TooltipTrigger>
          <TooltipContent>Clear repositories from every sandbox</TooltipContent>
        </Tooltip>
      </TooltipProvider>
    </>
  )

  return (
    <div className="mx-auto flex h-full min-h-0 w-full max-w-3xl flex-col px-4 py-5 sm:px-6 sm:py-6">
      <GitHubAccessEditor
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
        onWorkspaceSelectionsChange={(workspace, selections) => markDirty({
          ...draft,
          selections: { ...draft.selections, [workspace]: selections },
        })}
        onWorkspaceIdentityChange={(workspace, identity) => markDirty({
          ...draft,
          identities: { ...draft.identities, [workspace]: identity },
        })}
        onResetWorkspaceIdentity={(workspace) => {
          if (!source.github.hostIdentity) return
          markDirty({
            ...draft,
            identities: {
              ...draft.identities,
              [workspace]: { ...source.github.hostIdentity, apply: true },
            },
          })
        }}
        connectedTitle={`Connected as @${source.github.account ?? "unknown"}`}
        connectedDetail={accessEnabled
          ? "Repository credentials remain scoped to each workspace."
          : "Repository access is disabled. Existing selections are preserved."}
        connectedActions={connectedActions}
        notice={catalogNotice}
        footer={<GitHubOperationFooter operation={operation} onSave={saveChanges} onCancel={cancelChanges} onRetry={retrySave} />}
        disabled={editorDisabled}
        repositoryControlsAvailable={catalogAvailable}
        busy={editorBusy}
      />
    </div>
  )
}
