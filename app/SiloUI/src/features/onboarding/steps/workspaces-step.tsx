import { AlertCircle, Check, Clock3, LoaderCircle } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Progress } from "@/components/ui/progress"
import { ActivityOutput } from "@/features/onboarding/components/activity-output"
import { WorkspaceList } from "@/features/onboarding/components/workspace-list"
import type { WorkspaceProgressView } from "@/features/onboarding/model/onboarding-state"

function formatElapsed(seconds: number): string {
  const minutes = Math.floor(seconds / 60)
  const remainder = Math.floor(seconds % 60)
  return `${String(minutes).padStart(2, "0")}:${String(remainder).padStart(2, "0")} elapsed`
}

export function WorkspacesStep({ progress, onRetry }: { progress: WorkspaceProgressView; onRetry: () => void }) {
  return (
    <section aria-labelledby="workspaces-title" className="mx-auto max-w-4xl">
      <div className="mb-4 flex items-start justify-between gap-4">
        <div>
          <h2 id="workspaces-title" className="text-xl font-semibold tracking-tight">
            {progress.status === "failed" ? "Workspace setup needs action" : progress.status === "succeeded" ? "Workspaces are ready" : progress.status === "running" ? "Creating your workspaces" : "Workspaces are waiting"}
          </h2>
        </div>
        <span className="shrink-0 pt-1 font-mono text-[11px] text-muted-foreground">{formatElapsed(progress.elapsedSeconds)}</span>
      </div>

      <div className="mb-4 space-y-4">
        <div className="grid grid-cols-[auto_1fr] gap-3">
          {progress.status === "failed" ? <AlertCircle className="mt-0.5 size-5 text-destructive" aria-hidden="true" />
            : progress.status === "succeeded" ? <Check className="mt-0.5 size-5 text-emerald-600 dark:text-emerald-400" aria-hidden="true" />
              : progress.status === "running" ? <LoaderCircle className="mt-0.5 size-5 animate-spin text-primary" aria-hidden="true" />
                : <Clock3 className="mt-0.5 size-5 text-muted-foreground" aria-hidden="true" />}
          <div className="min-w-0">
            <div className="font-medium">{progress.currentWorkspace ? `${progress.currentWorkspace}` : "Workspace setup"}</div>
            <div className="select-text text-xs text-muted-foreground">{progress.currentMessage}</div>
          </div>
        </div>
        {progress.fraction !== undefined && (
          <div aria-label={`${progress.completedOperations} of ${progress.totalOperations} operations complete`}>
            <Progress value={progress.fraction * 100} />
            <div className="mt-1.5 flex justify-between text-[11px] text-muted-foreground">
              <span>{progress.completedOperations} of {progress.totalOperations} operations complete</span>
              <span>{Math.round(progress.fraction * 100)}%</span>
            </div>
          </div>
        )}
        <div className="border-t border-border pt-4">
          <WorkspaceList progress={progress} />
        </div>
      </div>

      {progress.status === "failed" && (
        <div className="mb-3 flex items-start justify-between gap-3 rounded-lg border border-destructive/25 bg-destructive/8 p-3 text-xs text-destructive" role="alert">
          <span className="select-text">{progress.recovery ?? "Resolve the reported workspace issue, then resume Setup."}</span>
          {progress.retryable && (
            <Button type="button" variant="outline" size="xs" className="shrink-0 text-foreground" onClick={onRetry}>
              Retry
            </Button>
          )}
        </div>
      )}
      <ActivityOutput events={progress.visibleEvents} />
    </section>
  )
}
