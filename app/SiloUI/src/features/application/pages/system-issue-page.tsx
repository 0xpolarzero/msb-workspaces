import { useState } from "react"
import { AlertCircle, Check, Circle, CircleAlert, Copy, ExternalLink, Loader2, RotateCw } from "lucide-react"

import { DisclosureIndicator, disclosureTriggerStateClass } from "@/components/disclosure-indicator"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from "@/components/ui/card"
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible"
import { PageHeader } from "@/features/application/components/application-ui"
import type { ActiveRuntimeRepairPresentation, ApplicationActions, RuntimeRepairPhase } from "@/features/application/model/application-source"
import { cn } from "@/lib/utils"

const repairSteps: ReadonlyArray<{ phase: RuntimeRepairPhase; label: string }> = [
  { phase: "installing-runtime", label: "Bundled Silo tools" },
  { phase: "installing-configuration", label: "Default configuration" },
  { phase: "verifying", label: "Installation verification" },
]

const siloIssuesURL = "https://github.com/0xpolarzero/silo/issues"

type StepState = "complete" | "active" | "failed" | "waiting"

function stepState(issue: ActiveRuntimeRepairPresentation, index: number): StepState {
  if (issue.status !== "repairing" && issue.status !== "failed") return "waiting"
  const activeIndex = repairSteps.findIndex(({ phase }) => phase === issue.phase)
  if (index < activeIndex) return "complete"
  if (index > activeIndex) return "waiting"
  return issue.status === "failed" ? "failed" : "active"
}

const stepStateLabel: Record<StepState, string> = {
  complete: "Complete",
  active: "In progress",
  failed: "Failed",
  waiting: "Waiting",
}

function StepIcon({ state }: { state: StepState }) {
  if (state === "complete") return <Check className="size-3.5" aria-hidden="true" />
  if (state === "active") return <Loader2 className="size-3.5 animate-spin" aria-hidden="true" />
  if (state === "failed") return <AlertCircle className="size-3.5" aria-hidden="true" />
  return <Circle className="size-3" aria-hidden="true" />
}

function RepairProgress({ issue }: { issue: ActiveRuntimeRepairPresentation }) {
  return (
    <ol className="grid gap-2" aria-label="Repair progress">
      {repairSteps.map((step, index) => {
        const state = stepState(issue, index)
        return (
          <li key={step.phase} data-step-state={state} className="grid grid-cols-[1.75rem_minmax(0,1fr)_auto] items-center gap-2 text-sm">
            <span className={cn(
              "grid size-7 place-items-center rounded-full",
              state === "complete" && "bg-emerald-500/10 text-emerald-600 dark:text-emerald-400",
              state === "active" && "bg-amber-500/10 text-amber-700 dark:text-amber-400",
              state === "failed" && "bg-destructive/10 text-destructive",
              state === "waiting" && "bg-muted text-muted-foreground/65",
            )}>
              <StepIcon state={state} />
            </span>
            <span className={cn("font-medium", state === "waiting" && "text-muted-foreground")}>{step.label}</span>
            <span className={cn(
              "text-xs",
              state === "complete" && "text-emerald-700 dark:text-emerald-400",
              state === "active" && "text-amber-700 dark:text-amber-400",
              state === "failed" && "text-destructive",
              state === "waiting" && "text-muted-foreground",
            )}>{stepStateLabel[state]}</span>
          </li>
        )
      })}
    </ol>
  )
}

function TechnicalDetails({ details }: { details: string }) {
  const [open, setOpen] = useState(false)
  const [copyStatus, setCopyStatus] = useState<"idle" | "copied" | "failed">("idle")
  const copyLabel = copyStatus === "copied" ? "Technical details copied" : copyStatus === "failed" ? "Copy technical details failed" : "Copy technical details"

  async function copyDetails() {
    try {
      await navigator.clipboard.writeText(details)
      setCopyStatus("copied")
    } catch {
      setCopyStatus("failed")
    }
    window.setTimeout(() => setCopyStatus("idle"), 1200)
  }

  return (
    <Collapsible open={open} onOpenChange={setOpen} className="group rounded-lg border border-border">
      <CollapsibleTrigger
        aria-label={open ? "Hide technical details" : "Show technical details"}
        className={`${disclosureTriggerStateClass} flex w-full items-center justify-between gap-3 rounded-lg px-3 py-2 text-left text-xs font-medium text-muted-foreground transition-colors hover:bg-muted hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/60`}
      >
        Technical details
        <DisclosureIndicator />
      </CollapsibleTrigger>
      <CollapsibleContent>
        <div className="relative border-t border-border bg-zinc-950 text-zinc-200 dark:bg-black">
          <Button
            type="button"
            variant="ghost"
            size="xs"
            className="absolute top-2 right-2 text-zinc-400 hover:bg-white/10 hover:text-white"
            onClick={copyDetails}
            aria-label={copyLabel}
            aria-live="polite"
          >
            {copyStatus === "copied" ? <Check aria-hidden="true" /> : copyStatus === "failed" ? <AlertCircle aria-hidden="true" /> : <Copy aria-hidden="true" />}
            {copyStatus === "copied" ? "Copied" : copyStatus === "failed" ? "Copy failed" : "Copy"}
          </Button>
          <pre className="max-h-40 overflow-auto whitespace-pre-wrap break-words px-3 py-2.5 pr-20 font-mono text-[11px] leading-5 select-text">{details}</pre>
        </div>
      </CollapsibleContent>
    </Collapsible>
  )
}

function issueHeader(issue: ActiveRuntimeRepairPresentation) {
  if (issue.status === "repairing") {
    return {
      icon: Loader2,
      title: "Repairing installation",
      description: undefined,
      tone: "warning" as const,
    }
  }
  if (issue.status === "failed") {
    return { icon: CircleAlert, title: "Repair couldn’t finish", description: issue.summary, tone: "danger" as const }
  }
  if (issue.status === "unavailable") {
    return { icon: CircleAlert, title: "Silo runtime is unavailable", description: issue.reason, tone: "danger" as const }
  }
  return { icon: CircleAlert, title: "Silo installation needs repair", description: issue.reason, tone: "danger" as const }
}

export function SystemIssuePage({ issue, actions }: { issue: ActiveRuntimeRepairPresentation; actions: ApplicationActions }) {
  const header = issueHeader(issue)
  const Icon = header.icon
  const showsProgress = issue.status === "repairing" || (issue.status === "failed" && issue.phase !== undefined)
  const showsContent = issue.status === "failed" || showsProgress
  const footerNote = issue.status === "unavailable"
    ? issue.recovery
    : "Sandbox data, host integration, and GitHub access are not changed."

  return (
    <div className="mx-auto grid w-full max-w-2xl gap-6 px-4 py-5 sm:px-6 sm:py-6">
      <PageHeader title="System issue" />

      <Card
        size="sm"
        className={cn(
          header.tone === "danger" && "ring-destructive/25",
          header.tone === "warning" && "ring-amber-500/25",
        )}
        role={header.tone === "danger" ? "alert" : "status"}
        aria-live="polite"
      >
        <CardHeader className="grid-cols-[auto_minmax(0,1fr)] items-start gap-x-3">
          <span className={cn(
            "grid size-8 place-items-center rounded-lg",
            header.description && "row-span-2",
            header.tone === "danger" && "bg-destructive/10 text-destructive",
            header.tone === "warning" && "bg-amber-500/10 text-amber-700 dark:text-amber-400",
          )}>
            <Icon className={cn("size-4", issue.status === "repairing" && "animate-spin")} aria-hidden="true" />
          </span>
          <CardTitle><h3>{header.title}</h3></CardTitle>
          {header.description && <CardDescription>{header.description}</CardDescription>}
        </CardHeader>

        {showsContent && (
          <CardContent className="grid gap-4 border-t border-border pt-3">
            {showsProgress && <RepairProgress issue={issue} />}
            {issue.status === "repairing" && (
              <p className="text-xs text-muted-foreground">Step {issue.completedSteps + 1} of {issue.totalSteps}</p>
            )}
            {issue.status === "failed" && (
              <>
                <p className="text-sm text-muted-foreground">{issue.recovery}</p>
                {issue.diagnosticDetails && <TechnicalDetails details={issue.diagnosticDetails} />}
              </>
            )}
          </CardContent>
        )}

        {(footerNote || issue.status === "needed" || issue.status === "repairing" || issue.status === "failed") && (
          <CardFooter className="flex-wrap justify-between gap-3 bg-muted/25">
            {footerNote && <p className="min-w-0 flex-1 text-xs text-muted-foreground">{footerNote}</p>}
            {issue.status === "needed" && <Button onClick={actions.repairRuntime}><RotateCw aria-hidden="true" />Repair Installation</Button>}
            {issue.status === "repairing" && <Button variant="outline" disabled aria-label="Repair in progress"><Loader2 className="animate-spin" aria-hidden="true" />Repairing…</Button>}
            {issue.status === "failed" && (
              <div className="flex flex-wrap items-center gap-2">
                <Button variant="outline" asChild>
                  <a href={siloIssuesURL} target="_blank" rel="noreferrer">
                    <ExternalLink aria-hidden="true" />
                    Open GitHub Issues
                  </a>
                </Button>
                <Button onClick={actions.repairRuntime}><RotateCw aria-hidden="true" />Retry Repair</Button>
              </div>
            )}
          </CardFooter>
        )}
      </Card>
    </div>
  )
}
