import { Pause, Play, RotateCw, Square } from "lucide-react"

import { Button } from "@/components/ui/button"
import type { SetupMachineConfiguration } from "@/contracts/silo"
import { InlineNotice, WorkspaceStateLabel } from "@/features/application/components/application-ui"
import type { ApplicationActions, ApplicationSource, ApplicationWorkspace, WorkspaceState } from "@/features/application/model/application-source"
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

function WorkspaceActions({ machine, state, actions }: { machine: SetupMachineConfiguration; state: WorkspaceState; actions: ApplicationActions }) {
  if (state === "running") {
    return (
      <>
        <SandboxAction label={`Pause ${machine.name}`} onClick={() => actions.pauseWorkspace(machine.name)}><Pause /></SandboxAction>
        <SandboxAction label={`Stop ${machine.name}`} onClick={() => actions.stopWorkspace(machine.name)}><Square /></SandboxAction>
        <SandboxAction label={`Restart ${machine.name}`} onClick={() => actions.restartWorkspace(machine.name)}><RotateCw /></SandboxAction>
      </>
    )
  }
  if (state === "starting") {
    return (
      <>
        <SandboxAction label={`Stop ${machine.name}`} onClick={() => actions.stopWorkspace(machine.name)}><Square /></SandboxAction>
        <SandboxAction label={`Restart ${machine.name}`} onClick={() => actions.restartWorkspace(machine.name)}><RotateCw /></SandboxAction>
      </>
    )
  }
  if (state === "failed") {
    return <SandboxAction label={`Restart ${machine.name}`} onClick={() => actions.restartWorkspace(machine.name)}><RotateCw /></SandboxAction>
  }
  return <SandboxAction label={`Start ${machine.name}`} onClick={() => actions.startWorkspace(machine.name)}><Play /></SandboxAction>
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
  const workspaces = new Map(source.workspaces.map((workspace) => [workspace.machine.id, workspace]))
  const machines = source.workspaces.map(({ machine }) => machine)

  return (
    <div className="mx-auto h-full w-full max-w-4xl px-4 py-5 sm:px-6 sm:py-6">
      <MachineList
        machines={machines}
        onMachinesChange={onMachinesChange}
        sortPriority={(machine) => attentionPriority[iconState(workspaces.get(machine.id))]}
        getRowPresentation={(machine) => {
          const workspace = workspaces.get(machine.id)
          const state = workspace?.state ?? "stopped"
          const visualState = iconState(workspace)
          return {
            iconState: visualState,
            tone: rowTone(workspace),
            detail: (
              <span title={workspace?.attention?.message}>
                <WorkspaceStateLabel state={state} />
                {workspace?.attention && <> · {workspace.attention.message}</>}
              </span>
            ),
            actions: <WorkspaceActions machine={machine} state={state} actions={actions} />,
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
