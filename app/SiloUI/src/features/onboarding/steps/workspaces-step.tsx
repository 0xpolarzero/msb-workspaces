import { LoaderCircle, RotateCw } from "lucide-react"

import { ListCard, ListRow, ListRowDetails, ListRowIcon } from "@/components/list-row"
import { Button } from "@/components/ui/button"
import { Progress } from "@/components/ui/progress"
import { ActivityOutput } from "@/features/onboarding/components/activity-output"
import { StatusIcon } from "@/features/onboarding/components/status-icon"
import { MachineList } from "@/features/sandboxes/components/machine-list"
import { machineSummary } from "@/features/sandboxes/model/machine-summary"
import type { SetupMachineConfiguration } from "@/contracts/silo"
import type { WorkspaceProgressView, WorkspaceView } from "@/features/onboarding/model/onboarding-state"
import { cn } from "@/lib/utils"

function formatElapsed(seconds: number): string {
  const minutes = Math.floor(seconds / 60)
  const remainder = Math.floor(seconds % 60)
  return `${String(minutes).padStart(2, "0")}:${String(remainder).padStart(2, "0")}`
}

const workspaceStatusLabel: Record<WorkspaceView["status"], string> = {
  waiting: "Waiting",
  working: "In progress",
  ready: "Complete",
  failed: "Failed",
}

export function WorkspacesStep({ machines, progress, onMachinesChange, onRetry }: {
  machines: readonly SetupMachineConfiguration[]
  progress: WorkspaceProgressView
  onMachinesChange: (machines: SetupMachineConfiguration[]) => void
  onRetry: () => void
}) {
  const failed = progress.status === "failed"
  const running = progress.status === "running"
  const complete = progress.status === "succeeded"
  const title = failed ? "Sandbox setup couldn’t finish" : complete ? "Sandboxes are ready" : running ? "Creating your sandboxes" : "Sandboxes are waiting"

  return (
    <section aria-labelledby="workspaces-title" className="mx-auto flex h-full min-h-[28rem] w-full max-w-4xl flex-col gap-4">
      <h2 id="workspaces-title" className="sr-only" data-visual-heading="hidden">
        {failed ? "Sandbox setup needs action" : title}
      </h2>

      <ListCard className="shrink-0" aria-label="Sandbox setup progress">
        <ListRow
          className="grid grid-cols-[auto_minmax(0,1fr)] gap-y-2 sm:flex"
          role={failed ? "alert" : "status"}
          aria-live="polite"
          icon={<ListRowIcon className={cn(
            failed && "bg-destructive/10 text-destructive",
            running && "bg-amber-500/10 text-amber-700 dark:text-amber-400",
            complete && "bg-emerald-500/10 text-emerald-600 dark:text-emerald-400",
          )}><StatusIcon status={progress.status} className="size-3.5" /></ListRowIcon>}
          title={<h3>{title}</h3>}
          detail={<>{progress.currentWorkspace && <span className="font-medium">{progress.currentWorkspace} · </span>}{progress.currentMessage}</>}
          detailClassName="whitespace-normal break-words select-text"
          actions={failed && progress.retryable && (
            <div className="col-start-2 shrink-0"><Button type="button" variant="outline" size="xs" onClick={onRetry}><RotateCw aria-hidden="true" />Retry</Button></div>
          )}
        />
        <ListRowDetails label="Sandbox setup details">
          {progress.fraction !== undefined && <Progress value={progress.fraction * 100} aria-label="Sandbox setup progress" />}
          <div className="flex flex-wrap items-center justify-between gap-x-3 gap-y-1 text-[11px] text-muted-foreground">
            <span>{progress.completedOperations} of {progress.totalOperations} operations complete</span>
            <span aria-label="Elapsed time" className="shrink-0 font-mono tabular-nums">{formatElapsed(progress.elapsedSeconds)}</span>
          </div>
          {failed && <p className="text-[11px] leading-4 text-muted-foreground select-text">{progress.recovery ?? "Resolve the reported sandbox issue, then retry setup."}</p>}
        </ListRowDetails>
        <ActivityOutput events={progress.visibleEvents} embedded />
      </ListCard>

      <div className="min-h-48 flex-1">
        <MachineList
          machines={machines}
          onMachinesChange={onMachinesChange}
          getRowPresentation={(machine) => {
            const status = progress.workspaces.find(({ name }) => name === machine.name)
            const state = status?.status ?? "waiting"
            const summary = machineSummary(machine)
            return {
              busy: state === "working",
              tone: state === "failed" ? "error" : state === "working" ? "starting" : state === "ready" ? "running" : "stopped",
              iconState: state === "failed" ? "error" : "normal",
              badge: <span className={cn(
                "inline-flex shrink-0 items-center gap-1 text-[10px] font-normal",
                state === "failed" ? "text-destructive" : state === "working" ? "text-amber-700 dark:text-amber-400" : state === "ready" ? "text-emerald-700 dark:text-emerald-400" : "text-muted-foreground",
              )}>{state === "working" && <LoaderCircle className="size-2.5 animate-spin motion-reduce:animate-none" aria-hidden="true" />}{workspaceStatusLabel[state]}</span>,
              detail: <span title={summary}>{summary}{status && state !== "ready" && status.detail !== "Waiting" ? ` · ${status.detail}` : ""}</span>,
              detailClassName: state === "failed" ? "whitespace-normal break-words" : undefined,
            }
          }}
        />
      </div>
    </section>
  )
}
