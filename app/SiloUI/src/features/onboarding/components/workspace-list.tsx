import { AlertCircle, Check, LoaderCircle } from "lucide-react"

import { ScrollArea } from "@/components/ui/scroll-area"
import type { WorkspaceProgressView, WorkspaceView } from "@/features/onboarding/model/onboarding-state"

function WorkspaceStateIcon({ workspace }: { workspace: WorkspaceView }) {
  if (workspace.status === "ready") return <Check className="size-3.5 text-emerald-600 dark:text-emerald-400" aria-label="Ready" />
  if (workspace.status === "failed") return <AlertCircle className="size-3.5 text-destructive" aria-label="Failed" />
  if (workspace.status === "working") return <LoaderCircle className="size-3.5 animate-spin text-primary" aria-label="Working" />
  return <span className="size-2 rounded-full border border-border" aria-label="Waiting" />
}

export function WorkspaceList({ progress }: { progress: WorkspaceProgressView }) {
  return (
    <section aria-labelledby="workspace-list-heading" className="flex h-full min-h-0 flex-col">
      <div className="mb-2 flex flex-wrap items-center justify-between gap-2 text-xs">
        <h3 id="workspace-list-heading" className="font-medium">Virtual machines</h3>
        <span className="text-muted-foreground">
          {progress.readyCount} ready · {progress.workingCount} working · {progress.waitingCount} waiting
          {progress.failedCount > 0 && ` · ${progress.failedCount} failed`}
        </span>
      </div>
      <ScrollArea className="min-h-0 flex-1" data-testid="workspace-list">
        <div className="grid grid-cols-1 gap-1.5 p-2 sm:grid-cols-2 lg:grid-cols-3">
          {progress.workspaces.map((workspace) => (
            <div key={workspace.name} className="min-w-0 rounded-md border border-border bg-background px-2.5 py-2 text-xs">
              <div className="flex min-w-0 items-center gap-2">
                <WorkspaceStateIcon workspace={workspace} />
                <span className="truncate font-medium" title={workspace.name}>{workspace.name}</span>
              </div>
              <div className="mt-1 truncate pl-[1.375rem] text-[11px] text-muted-foreground" title={workspace.detail}>{workspace.detail}</div>
            </div>
          ))}
        </div>
      </ScrollArea>
    </section>
  )
}
