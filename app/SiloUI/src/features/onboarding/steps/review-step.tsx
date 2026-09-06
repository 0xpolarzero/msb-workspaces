import { GitBranch, Pencil, RotateCw, UserRound } from "lucide-react"

import { ListCard, ListRow, ListRowIcon } from "@/components/list-row"
import { Button } from "@/components/ui/button"
import { SetupNotice } from "@/features/onboarding/components/setup-notice"
import { StatusIcon } from "@/features/onboarding/components/status-icon"
import { SandboxList, SandboxListItem, SandboxListRow } from "@/features/sandboxes/components/sandbox-list"
import { machineSummary } from "@/features/sandboxes/model/machine-summary"
import type { SetupMachineConfiguration } from "@/contracts/silo"
import type { ReviewQueueItemView } from "@/features/onboarding/model/onboarding-state"
import { cn } from "@/lib/utils"

interface ReviewStepProps {
  workspaceRetryable: boolean
  queueItems: ReviewQueueItemView[]
  machines: readonly SetupMachineConfiguration[]
  identitySummary: string
  githubSummary: string
  errorMessage?: string
  errorRecovery?: string
  onRetryWorkspaceSetup: () => void
  onEditStep?: (step: "workspaces" | "github") => void
}

const detailById: Record<ReviewQueueItemView["id"], string> = {
  workspaceRun: "Create each sandbox with your chosen resources",
  workspaceVerify: "Check that every sandbox is ready to use",
  githubRun: "Save your repository access choices",
  githubVerify: "Check access to your selected repositories",
  identityRun: "Save your Git author name and email",
  identityVerify: "Check your Git identity in every sandbox",
  completion: "Open Silo when all setup checks are complete",
}

const statusLabel: Record<ReviewQueueItemView["status"], string> = {
  queued: "Waiting",
  running: "In progress",
  succeeded: "Complete",
  failed: "Failed",
}

export function ReviewStep({ workspaceRetryable, queueItems, machines, identitySummary, githubSummary, errorMessage, errorRecovery, onRetryWorkspaceSetup, onEditStep }: ReviewStepProps) {
  return (
    <section aria-labelledby="review-title" className="mx-auto grid w-full max-w-4xl gap-4">
      <h2 id="review-title" className="sr-only" data-visual-heading="hidden">Review setup</h2>

      {errorMessage && <SetupNotice
        title="Setup couldn’t finish"
        detail={errorMessage}
        recovery={errorRecovery}
        action={workspaceRetryable && <Button type="button" variant="outline" size="xs" onClick={onRetryWorkspaceSetup}><RotateCw aria-hidden="true" />Retry</Button>}
      />}

      <section aria-labelledby="review-machines-heading" className="min-w-0">
        <div className="mb-2 flex items-center justify-between gap-2">
          <h3 id="review-machines-heading" className="text-xs font-medium">Sandboxes in setup order</h3>
          {onEditStep && <Button type="button" variant="ghost" size="xs" onClick={() => onEditStep("workspaces")} aria-label="Edit sandboxes"><Pencil aria-hidden="true" />Edit</Button>}
        </div>
        <SandboxList label="Sandboxes in setup order">
          {machines.map((machine, index) => (
            <SandboxListItem key={machine.id}>
              <SandboxListRow
                name={machine.name}
                kind={machine.kind}
                leading={<span className="w-5 shrink-0 text-center font-mono text-[10px] tabular-nums text-muted-foreground">{index + 1}</span>}
                detail={machineSummary(machine)}
                detailClassName="whitespace-normal break-words"
              />
            </SandboxListItem>
          ))}
        </SandboxList>
      </section>

      <section aria-labelledby="review-preferences-heading">
        <h3 id="review-preferences-heading" className="mb-2 text-xs font-medium">GitHub and Git identity</h3>
        <ListCard>
          {[
            { title: "GitHub access", detail: githubSummary, Icon: GitBranch },
            { title: "Git author", detail: identitySummary, Icon: UserRound },
          ].map(({ title, detail, Icon }) => <ListRow
            key={title}
            icon={<ListRowIcon aria-hidden="true"><Icon className="size-3.5" /></ListRowIcon>}
            title={title}
            detail={detail}
            detailClassName="whitespace-normal break-words"
            actions={onEditStep && <Button type="button" variant="ghost" size="xs" onClick={() => onEditStep("github")} aria-label={`Edit ${title}`}><Pencil aria-hidden="true" />Edit</Button>}
          />)}
        </ListCard>
      </section>

      <section aria-labelledby="review-operations-heading">
        <h3 id="review-operations-heading" className="mb-2 text-xs font-medium">Setup operations</h3>
        <ListCard>
          <ol className="divide-y divide-border" aria-label="Setup operations">
            {queueItems.map((item, index) => <li key={item.id}>
              <ListRow
                icon={<ListRowIcon className={cn(
                  item.status === "failed" && "bg-destructive/10",
                  item.status === "running" && "bg-amber-500/10",
                  item.status === "succeeded" && "bg-emerald-500/10",
                )}><StatusIcon status={item.status === "queued" ? "waiting" : item.status} waitingLabel={String(index + 1)} className="size-3.5" /></ListRowIcon>}
                title={item.label}
                detail={item.failure ?? detailById[item.id]}
                detailClassName="whitespace-normal break-words select-text"
                actions={<span className={cn(
                  "shrink-0 text-[10px]",
                  item.status === "failed" ? "text-destructive" : item.status === "running" ? "text-amber-700 dark:text-amber-400" : item.status === "succeeded" ? "text-emerald-700 dark:text-emerald-400" : "text-muted-foreground",
                )}>{statusLabel[item.status]}</span>}
              />
            </li>)}
          </ol>
        </ListCard>
      </section>
    </section>
  )
}
