import { Pause, Play, RotateCw, Square } from "lucide-react"

import { Button } from "@/components/ui/button"
import { InlineNotice, SectionHeader } from "@/features/application/components/application-ui"
import type { ApplicationActions, ApplicationSource, ApplicationWorkspace } from "@/features/application/model/application-source"
import {
  SandboxAction,
  SandboxList,
  SandboxListItem,
  SandboxListRow,
  type SandboxIconState,
} from "@/features/sandboxes/components/sandbox-list"

const attentionPriority: Record<SandboxIconState, number> = {
  error: 0,
  warning: 1,
  normal: 2,
}

function iconState(workspace: ApplicationWorkspace): SandboxIconState {
  if (workspace.state === "failed") return "error"
  return workspace.attention?.level ?? "normal"
}

function stateLabel(workspace: ApplicationWorkspace) {
  return workspace.state.charAt(0).toUpperCase() + workspace.state.slice(1)
}

function WorkspaceActions({ workspace, actions }: { workspace: ApplicationWorkspace; actions: ApplicationActions }) {
  if (workspace.state === "running") {
    return (
      <>
        <SandboxAction label={`Pause ${workspace.id}`} onClick={() => actions.pauseWorkspace(workspace.id)}><Pause /></SandboxAction>
        <SandboxAction label={`Stop ${workspace.id}`} onClick={() => actions.stopWorkspace(workspace.id)}><Square /></SandboxAction>
        <SandboxAction label={`Restart ${workspace.id}`} onClick={() => actions.restartWorkspace(workspace.id)}><RotateCw /></SandboxAction>
      </>
    )
  }
  if (workspace.state === "starting") {
    return (
      <>
        <SandboxAction label={`Stop ${workspace.id}`} onClick={() => actions.stopWorkspace(workspace.id)}><Square /></SandboxAction>
        <SandboxAction label={`Restart ${workspace.id}`} onClick={() => actions.restartWorkspace(workspace.id)}><RotateCw /></SandboxAction>
      </>
    )
  }
  if (workspace.state === "failed") {
    return <SandboxAction label={`Restart ${workspace.id}`} onClick={() => actions.restartWorkspace(workspace.id)}><RotateCw /></SandboxAction>
  }
  return <SandboxAction label={`Start ${workspace.id}`} onClick={() => actions.startWorkspace(workspace.id)}><Play /></SandboxAction>
}

export function OverviewPage({ source, actions }: { source: ApplicationSource; actions: ApplicationActions }) {
  const workspaces = source.workspaces
    .map((workspace, index) => ({ workspace, index, iconState: iconState(workspace) }))
    .sort((a, b) => attentionPriority[a.iconState] - attentionPriority[b.iconState] || a.index - b.index)
  const workspaceAttention = workspaces.filter(({ iconState: visualState }) => visualState !== "normal")

  return (
    <div className="mx-auto grid w-full max-w-4xl gap-3 px-4 py-5 sm:px-6 sm:py-6">
      <div className="grid gap-2" aria-labelledby="overview-sandboxes">
        <SectionHeader id="overview-sandboxes" title="Sandboxes" />
        <SandboxList label="Sandboxes">
          {workspaces.map(({ workspace, iconState: visualState }) => (
            <SandboxListItem key={workspace.id} data-sandbox-name={workspace.id}>
              <SandboxListRow
                name={workspace.id}
                kind={workspace.kind}
                iconState={visualState}
                detail={stateLabel(workspace)}
                actions={<WorkspaceActions workspace={workspace} actions={actions} />}
              />
            </SandboxListItem>
          ))}
        </SandboxList>
      </div>

      {(workspaceAttention.length > 0 || source.runtimeRepairRequired) && (
        <div className="grid gap-2" aria-label="Sandbox attention">
          {workspaceAttention.map(({ workspace, iconState: visualState }) => (
            <InlineNotice key={workspace.id} tone={visualState === "error" ? "danger" : "warning"} title={`${workspace.id} needs attention`}>
              {workspace.attention?.message ?? workspace.stateDetail}
            </InlineNotice>
          ))}
          {source.runtimeRepairRequired && (
            <InlineNotice
              title="Silo installation needs repair"
              tone="danger"
              action={<Button variant="outline" size="sm" onClick={actions.repairRuntime}>Repair…</Button>}
            >
              The bundled runtime could not be verified. Existing sandbox information remains visible.
            </InlineNotice>
          )}
        </div>
      )}
    </div>
  )
}
