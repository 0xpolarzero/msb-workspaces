import { AlertCircle, Check, Copy, TerminalSquare } from "lucide-react"
import { useMemo, useState } from "react"

import { Button } from "@/components/ui/button"
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible"
import { DisclosureIndicator, disclosureTriggerStateClass } from "@/features/onboarding/components/disclosure-indicator"
import type { SiloProgressEvent } from "@/contracts/silo"

function eventLine(event: SiloProgressEvent): string {
  return [event.phase, event.workspace, event.message].filter(Boolean).join("  ")
}

export function ActivityOutput({ events }: { events: SiloProgressEvent[] }) {
  const [open, setOpen] = useState(true)
  const [copyStatus, setCopyStatus] = useState<"idle" | "copied" | "failed">("idle")
  const output = useMemo(() => events.map(eventLine).join("\n"), [events])
  const copyLabel = copyStatus === "copied" ? "Activity copied" : copyStatus === "failed" ? "Copy activity failed" : "Copy activity"

  async function copyOutput() {
    try {
      await navigator.clipboard.writeText(output)
      setCopyStatus("copied")
    } catch {
      setCopyStatus("failed")
    }
    window.setTimeout(() => setCopyStatus("idle"), 1200)
  }

  return (
    <Collapsible open={open} onOpenChange={setOpen} className="activity-output-collapsible group rounded-lg border border-border bg-card">
      <div className="grid grid-cols-[1.25rem_minmax(0,1fr)_1.5rem_1.5rem] items-center gap-1 px-3 py-2" role="group" aria-label="Live activity controls">
        <TerminalSquare className="size-4" aria-hidden="true" />
        <span className="text-xs font-medium">Live activity</span>
        <Button
          type="button"
          variant="ghost"
          size="icon-xs"
          onClick={copyOutput}
          disabled={!output}
          aria-label={copyLabel}
          aria-live="polite"
        >
          {copyStatus === "copied" ? <Check aria-hidden="true" /> : copyStatus === "failed" ? <AlertCircle aria-hidden="true" /> : <Copy aria-hidden="true" />}
        </Button>
        <CollapsibleTrigger
          aria-label={open ? "Collapse activity" : "Expand activity"}
          className={`${disclosureTriggerStateClass} grid size-6 place-items-center rounded-[min(var(--radius-md),10px)] text-muted-foreground transition-colors hover:bg-muted hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/60`}
        >
          <DisclosureIndicator />
        </CollapsibleTrigger>
      </div>
      <CollapsibleContent className="activity-output-content">
        <pre className="max-h-36 overflow-auto whitespace-pre-wrap break-words border-t border-border bg-zinc-950 px-3 py-2.5 font-mono text-[11px] leading-5 text-zinc-200 select-text dark:bg-black" aria-label="Workspace activity">{output || "No activity yet."}</pre>
      </CollapsibleContent>
    </Collapsible>
  )
}
