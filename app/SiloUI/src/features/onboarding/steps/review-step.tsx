import { AlertCircle } from "lucide-react"

import { Button } from "@/components/ui/button"
import { StatusIcon } from "@/features/onboarding/components/status-icon"
import type { SetupMachineConfiguration } from "@/contracts/silo"
import type { ReviewQueueItemView } from "@/features/onboarding/model/onboarding-state"

interface ReviewStepProps {
  workspaceRetryable: boolean
  queueItems: ReviewQueueItemView[]
  machines: readonly SetupMachineConfiguration[]
  identitySummary: string
  githubSummary: string
  errorMessage?: string
  errorRecovery?: string
  onRetryWorkspaceSetup: () => void
}

const detailById: Record<ReviewQueueItemView["id"], string> = {
  workspaceRun: "Applies the submitted machine boundary",
  workspaceVerify: "Runs complete deep verification and restores lifecycle state",
  githubRun: "Saves the retained repository policy",
  githubVerify: "Verifies scoped access and restored lifecycle state",
  identityRun: "Saves each applied machine author name and email",
  identityVerify: "Reads each applied machine identity back independently",
  completion: "Closes setup after every required verification succeeds",
}

export function ReviewStep({ workspaceRetryable, queueItems, machines, identitySummary, githubSummary, errorMessage, errorRecovery, onRetryWorkspaceSetup }: ReviewStepProps) {
  return (
    <section aria-labelledby="review-title" className="mx-auto max-w-3xl">
      <h2 id="review-title" className="sr-only" data-visual-heading="hidden">Review setup</h2>

      {errorMessage && (
        <div className="mb-3 flex gap-2 rounded-lg border border-destructive/25 bg-destructive/8 p-3 text-xs text-destructive" role="alert">
          <AlertCircle className="mt-0.5 size-4 shrink-0" />
          <div className="min-w-0 flex-1 select-text"><div className="font-medium">{errorMessage}</div>{errorRecovery && <div className="mt-1">{errorRecovery}</div>}</div>
          {workspaceRetryable && (
            <Button type="button" variant="outline" size="xs" className="shrink-0 self-start text-foreground" onClick={onRetryWorkspaceSetup}>
              Retry
            </Button>
          )}
        </div>
      )}

      <section aria-labelledby="review-machines-heading" className="mb-3 rounded-lg border border-border bg-card p-3">
        <h3 id="review-machines-heading" className="text-xs font-medium">Machines in setup order</h3>
        <ol className="mt-2 grid gap-1" aria-label="Machines in setup order">
          {machines.map((machine, index) => (
            <li key={machine.id} className="flex min-w-0 items-center gap-2 text-xs">
              <span className="w-5 shrink-0 text-right font-mono text-[10px] text-muted-foreground">{index + 1}</span>
              <span className="min-w-0 flex-1 truncate font-medium">{machine.name}</span>
              <span className="shrink-0 rounded-full bg-muted px-2 py-0.5 text-[10px] uppercase text-muted-foreground">{machine.kind}</span>
              <span className="hidden min-w-0 max-w-64 truncate text-[10px] text-muted-foreground sm:block">
                {machine.kind === "vm"
                  ? `${machine.cpus} CPU · ${machine.memoryGiB} GB RAM`
                  : `${machine.user}@${machine.host}:${machine.port}`}
              </span>
            </li>
          ))}
        </ol>
      </section>

      <ol className="grid gap-2" aria-label="Setup operations">
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
