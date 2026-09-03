import { AlertCircle } from "lucide-react"

import { Button } from "@/components/ui/button"
import { WorkspaceProgressStrip } from "@/features/onboarding/components/workspace-progress-strip"
import { StatusIcon } from "@/features/onboarding/components/status-icon"
import type { ReviewQueueItemView, WorkspaceProgressView } from "@/features/onboarding/model/onboarding-state"

interface ReviewStepProps {
  progress: WorkspaceProgressView
  queueItems: ReviewQueueItemView[]
  identitySummary: string
  githubSummary: string
  errorMessage?: string
  errorRecovery?: string
  onViewProgress: () => void
  onRetryWorkspaceSetup: () => void
}

const detailById: Record<ReviewQueueItemView["id"], string> = {
  workspaceRun: "Applies the submitted workspace boundary",
  workspaceVerify: "Runs complete deep verification and restores lifecycle state",
  githubRun: "Saves the retained repository policy",
  githubVerify: "Verifies scoped access and restored lifecycle state",
  identityRun: "Saves each applied workspace author name and email",
  identityVerify: "Reads each applied workspace identity back independently",
  completion: "Closes setup after every required verification succeeds",
}

export function ReviewStep({ progress, queueItems, identitySummary, githubSummary, errorMessage, errorRecovery, onViewProgress, onRetryWorkspaceSetup }: ReviewStepProps) {
  return (
    <section aria-labelledby="review-title" className="mx-auto max-w-3xl">
      <WorkspaceProgressStrip progress={progress} onView={onViewProgress} />
      <div className="mb-5">
        <h2 id="review-title" className="text-xl font-semibold tracking-tight">Review setup</h2>
      </div>

      {errorMessage && (
        <div className="mb-3 flex gap-2 rounded-lg border border-destructive/25 bg-destructive/8 p-3 text-xs text-destructive" role="alert">
          <AlertCircle className="mt-0.5 size-4 shrink-0" />
          <div className="min-w-0 flex-1 select-text"><div className="font-medium">{errorMessage}</div>{errorRecovery && <div className="mt-1">{errorRecovery}</div>}</div>
          {progress.retryable && (
            <Button type="button" variant="outline" size="xs" className="shrink-0 self-start text-foreground" onClick={onRetryWorkspaceSetup}>
              Retry
            </Button>
          )}
        </div>
      )}

      <ol className="grid gap-2">
        {queueItems.map((item, index) => {
          const status = item.status === "queued" ? "waiting" : item.status
          const choiceDetail = item.id === "githubRun" ? githubSummary : item.id === "identityRun" ? identitySummary : detailById[item.id]
          return (
            <li key={item.id} className="grid grid-cols-[1.25rem_1fr_auto] items-center gap-3 rounded-lg border border-border bg-card px-3 py-2.5 text-xs">
              <StatusIcon status={status} waitingLabel={String(index + 1)} />
              <div className="min-w-0"><div className="font-medium">{item.label}</div><div className="break-words text-[11px] text-muted-foreground" title={item.failure ?? choiceDetail}>{item.failure ?? choiceDetail}</div></div>
              <span className="rounded-full bg-muted px-2 py-1 text-[10px] capitalize text-muted-foreground">{item.status}</span>
            </li>
          )
        })}
      </ol>
    </section>
  )
}
