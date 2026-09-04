import { CircleAlert, Loader2, Pause, Play, RotateCw, Square } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Progress } from "@/components/ui/progress"
import type { SetupMachineConfiguration, SiloProgressEvent } from "@/contracts/silo"
import { InlineNotice, WorkspaceStateLabel } from "@/features/application/components/application-ui"
import type {
  ApplicationActions,
  ApplicationSource,
  ApplicationWorkspace,
  SandboxConfigurationOperation,
  WorkspaceState,
} from "@/features/application/model/application-source"
import { MachineList } from "@/features/sandboxes/components/machine-list"
import { SandboxAction, type SandboxIconState, type SandboxRowTone } from "@/features/sandboxes/components/sandbox-list"

const attentionPriority: Record<SandboxIconState, number> = {
  error: 0,
  warning: 1,
  normal: 2,
}

function iconState(workspace?: ApplicationWorkspace): SandboxIconState {
  if (workspace?.state === "failed") return "error"
  return workspace?.attention?.level ?? "normal"
}

function rowTone(workspace?: ApplicationWorkspace): SandboxRowTone {
  if (workspace?.state === "failed" || workspace?.attention?.level === "error") return "error"
  if (workspace?.attention?.level === "warning") return "warning"
  return workspace?.state ?? "stopped"
}

interface ConfigurationRowView {
  status: "running" | "failed"
  message: string
  completedSteps?: number
  recovery?: string
  retryable: boolean
}

const configurationSteps = new Set([
  "workspace-configuration",
  "workspace-networking",
  "workspace-verification",
])

function emptyWorkspace(machine: SetupMachineConfiguration): ApplicationWorkspace {
  return {
    machine,
    purpose: "New sandbox",
    state: "stopped",
    stateDetail: "Not configured",
    freshness: "fresh",
    host: machine.kind === "ssh" ? machine.host : `${machine.name}.silo.test`,
    repositories: [],
    ports: [],
    logs: [],
    activities: [],
    githubRepositories: [],
    secretNames: [],
  }
}

function displayWorkspaces(source: ApplicationSource): ApplicationWorkspace[] {
  const operation = source.sandboxConfigurationOperation
  if (!operation) return source.workspaces
  const committedIDs = new Set(source.workspaces.map(({ machine }) => machine.id))
  const candidatesByID = new Map(operation.candidate.machines.map((machine) => [machine.id, machine]))
  return [
    ...source.workspaces.map((workspace) => ({
      ...workspace,
      machine: candidatesByID.get(workspace.machine.id) ?? workspace.machine,
    })),
    ...operation.candidate.machines
      .filter(({ id }) => !committedIDs.has(id))
      .map(emptyWorkspace),
  ]
}

function latestSafeEvent(operation: SandboxConfigurationOperation, workspace: string): SiloProgressEvent | undefined {
  const activeRevision = operation.progressEvents.findLast(({ revision }) => revision)?.revision
  return operation.progressEvents.findLast((event) => (
    event.safeForDisplay
    && event.workspace === workspace
    && (!activeRevision || !event.revision || event.revision === activeRevision)
  ))
}

function configurationRowView(
  workspace: ApplicationWorkspace,
  committedWorkspace: ApplicationWorkspace | undefined,
  operation: SandboxConfigurationOperation,
): ConfigurationRowView | undefined {
  const candidate = operation.candidate.machines.find(({ id }) => id === workspace.machine.id)
  const candidateName = candidate?.name ?? workspace.machine.name
  const removed = Boolean(committedWorkspace && !candidate)
  const addedOrChanged = !committedWorkspace || JSON.stringify(committedWorkspace.machine) !== JSON.stringify(candidate)
  const errorTargetsWorkspace = operation.status === "failed"
    && operation.error.workspace === candidateName

  if (errorTargetsWorkspace) {
    return {
      status: "failed",
      message: operation.error.message,
      recovery: operation.error.recovery ?? undefined,
      retryable: operation.error.retryable,
    }
  }
  if (removed) {
    return {
      status: "running",
      message: "Removing sandbox from Silo. Persistent volumes will be retained.",
      retryable: false,
    }
  }

  const latest = latestSafeEvent(operation, candidateName)
  if (!latest && !addedOrChanged) return undefined
  if (!latest) {
    return {
      status: "running",
      message: "Preparing sandbox configuration.",
      completedSteps: 0,
      retryable: false,
    }
  }

  const completedSteps = new Set(operation.progressEvents
    .filter((event) => event.workspace === candidateName && event.step && event.fraction === 1 && configurationSteps.has(event.step))
    .map(({ step }) => step)).size
  return {
    status: "running",
    message: latest.message,
    completedSteps,
    retryable: false,
  }
}

function ConfigurationIcon({ failed }: { failed: boolean }) {
  return (
    <span className={failed
      ? "grid size-7 shrink-0 place-items-center rounded-md bg-destructive/10 text-destructive"
      : "grid size-7 shrink-0 place-items-center rounded-md bg-muted text-muted-foreground"}
    >
      {failed
        ? <CircleAlert className="size-3.5" aria-hidden="true" />
        : <Loader2 className="size-3.5 animate-spin" aria-hidden="true" />}
    </span>
  )
}

function ConfigurationDetail({ view }: { view: ConfigurationRowView }) {
  const failed = view.status === "failed"
  const progressLabel = view.completedSteps === undefined ? undefined : `${view.completedSteps} of 3 steps complete`
  return (
    <div
      role={failed ? "alert" : "status"}
      aria-live={failed ? "assertive" : "polite"}
      aria-atomic="true"
      className="grid gap-1.5 py-0.5"
    >
      <div className="flex min-w-0 items-start justify-between gap-3">
        <p className={failed ? "text-destructive" : "text-muted-foreground"}>{view.message}</p>
        {progressLabel && <span className="shrink-0 text-[10px] text-muted-foreground">{progressLabel}</span>}
      </div>
      {view.completedSteps !== undefined && (
        <Progress aria-label={progressLabel} value={(view.completedSteps / 3) * 100} className="mt-0.5" />
      )}
      {view.recovery && <p className="text-[10px] text-muted-foreground">{view.recovery}</p>}
    </div>
  )
}

function WorkspaceActions({ machine, state, actions, disabled = false }: { machine: SetupMachineConfiguration; state: WorkspaceState; actions: ApplicationActions; disabled?: boolean }) {
  if (state === "running") {
    return (
      <>
        <SandboxAction label={`Pause ${machine.name}`} disabled={disabled} onClick={() => actions.pauseWorkspace(machine.name)}><Pause /></SandboxAction>
        <SandboxAction label={`Stop ${machine.name}`} disabled={disabled} onClick={() => actions.stopWorkspace(machine.name)}><Square /></SandboxAction>
        <SandboxAction label={`Restart ${machine.name}`} disabled={disabled} onClick={() => actions.restartWorkspace(machine.name)}><RotateCw /></SandboxAction>
      </>
    )
  }
  if (state === "starting") {
    return (
      <>
        <SandboxAction label={`Stop ${machine.name}`} disabled={disabled} onClick={() => actions.stopWorkspace(machine.name)}><Square /></SandboxAction>
        <SandboxAction label={`Restart ${machine.name}`} disabled onClick={() => actions.restartWorkspace(machine.name)}><RotateCw /></SandboxAction>
      </>
    )
  }
  if (state === "failed") {
    return (
      <>
        <SandboxAction label={`Stop ${machine.name}`} disabled onClick={() => actions.stopWorkspace(machine.name)}><Square /></SandboxAction>
        <SandboxAction label={`Restart ${machine.name}`} disabled={disabled} onClick={() => actions.restartWorkspace(machine.name)}><RotateCw /></SandboxAction>
      </>
    )
  }
  return (
    <>
      <SandboxAction label={`Start ${machine.name}`} disabled={disabled} onClick={() => actions.startWorkspace(machine.name)}><Play /></SandboxAction>
      <SandboxAction label={`Stop ${machine.name}`} disabled onClick={() => actions.stopWorkspace(machine.name)}><Square /></SandboxAction>
      <SandboxAction label={`Restart ${machine.name}`} disabled onClick={() => actions.restartWorkspace(machine.name)}><RotateCw /></SandboxAction>
    </>
  )
}

export function OverviewPage({
  source,
  actions,
  onMachinesChange,
}: {
  source: ApplicationSource
  actions: ApplicationActions
  onMachinesChange: (machines: SetupMachineConfiguration[]) => void
}) {
  const visibleWorkspaces = displayWorkspaces(source)
  const workspaces = new Map(visibleWorkspaces.map((workspace) => [workspace.machine.id, workspace]))
  const committedWorkspaces = new Map(source.workspaces.map((workspace) => [workspace.machine.id, workspace]))
  const machines = visibleWorkspaces.map(({ machine }) => machine)
  const configurationOperation = source.sandboxConfigurationOperation
  const configurationLocked = configurationOperation !== null

  return (
    <div className="mx-auto h-full w-full max-w-4xl px-4 py-5 sm:px-6 sm:py-6">
      <MachineList
        machines={machines}
        onMachinesChange={onMachinesChange}
        interactionDisabled={configurationLocked}
        summary={configurationOperation ? <>{source.workspaces.length} configured · Applying sandbox changes</> : undefined}
        sortPriority={(machine) => attentionPriority[iconState(workspaces.get(machine.id))]}
        getRowPresentation={(machine) => {
          const workspace = workspaces.get(machine.id)
          const state = workspace?.state ?? "stopped"
          const visualState = iconState(workspace)
          const configuration = workspace && configurationOperation
            ? configurationRowView(workspace, committedWorkspaces.get(machine.id), configurationOperation)
            : undefined
          if (configuration) {
            const failed = configuration.status === "failed"
            return {
              busy: !failed,
              suppressInteractions: true,
              icon: <ConfigurationIcon failed={failed} />,
              iconState: failed ? "error" as const : "normal" as const,
              tone: failed ? "error" as const : "starting" as const,
              detailClassName: "overflow-visible whitespace-normal text-xs",
              detail: <ConfigurationDetail view={configuration} />,
              actions: failed && configuration.retryable
                ? <SandboxAction label={`Retry ${machine.name} configuration`} onClick={() => actions.retryMachineConfiguration(machine.name)}><RotateCw /></SandboxAction>
                : undefined,
            }
          }
          return {
            iconState: visualState,
            tone: rowTone(workspace),
            detail: (
              <span title={workspace?.attention?.message}>
                <WorkspaceStateLabel state={state} />
                {workspace?.attention && <> · {workspace.attention.message}</>}
              </span>
            ),
            actions: <WorkspaceActions machine={machine} state={state} actions={actions} disabled={configurationLocked} />,
          }
        }}
        footer={source.runtimeRepairRequired ? (
          <InlineNotice
            title="Silo installation needs repair"
            tone="danger"
            action={<Button variant="outline" size="sm" onClick={actions.repairRuntime}>Repair…</Button>}
          >
            The bundled runtime could not be verified. Existing sandbox information remains visible.
          </InlineNotice>
        ) : undefined}
      />
    </div>
  )
}
