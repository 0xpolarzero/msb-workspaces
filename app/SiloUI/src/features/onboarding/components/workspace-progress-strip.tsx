import { AlertCircle, Check, Clock3, LoaderCircle } from "lucide-react"

import { Button } from "@/components/ui/button"
import type { WorkspaceProgressView } from "@/features/onboarding/model/onboarding-state"

export function WorkspaceProgressStrip({ progress, onView }: { progress: WorkspaceProgressView; onView: () => void }) {
  const title = progress.status === "failed"
    ? "Workspace setup needs action"
    : progress.status === "succeeded"
      ? `Workspaces ready · ${progress.readyCount} of ${progress.workspaces.length}`
      : progress.status === "running"
        ? `Creating workspaces · ${progress.readyCount} of ${progress.workspaces.length} ready`
        : "Workspace setup is waiting"

  return (
    <div className="mb-5 grid grid-cols-[auto_1fr_auto] items-center gap-2.5 rounded-lg border border-border bg-muted/45 px-3 py-2" aria-label="Workspace progress">
      {progress.status === "failed" ? (
        <AlertCircle className="size-4 text-destructive" aria-hidden="true" />
      ) : progress.status === "succeeded" ? (
        <Check className="size-4 text-emerald-600 dark:text-emerald-400" aria-hidden="true" />
      ) : progress.status === "running" ? (
        <LoaderCircle className="size-4 animate-spin text-primary" aria-hidden="true" />
      ) : (
        <Clock3 className="size-4 text-muted-foreground" aria-hidden="true" />
      )}
      <div className="min-w-0 text-xs">
        <div className="font-medium">{title}</div>
        <div className="truncate text-muted-foreground">
          {progress.currentWorkspace && `${progress.currentWorkspace} · `}{progress.currentMessage}
        </div>
      </div>
      <Button variant="ghost" size="xs" onClick={onView}>View</Button>
    </div>
  )
}
