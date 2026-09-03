import { AlertCircle, Check, ChevronsUpDown, Copy, TerminalSquare } from "lucide-react"
import { useMemo, useState } from "react"

import { Button } from "@/components/ui/button"
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible"
import type { SiloProgressEvent } from "@/contracts/silo"

function eventLine(event: SiloProgressEvent): string {
  return [event.phase, event.workspace, event.message].filter(Boolean).join("  ")
}

export function ActivityOutput({ events }: { events: SiloProgressEvent[] }) {
  const [open, setOpen] = useState(true)
  const [copyStatus, setCopyStatus] = useState<"idle" | "copied" | "failed">("idle")
  const output = useMemo(() => events.map(eventLine).join("\n"), [events])

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
    <Collapsible open={open} onOpenChange={setOpen} className="rounded-lg border border-border bg-card">
      <div className="flex items-center justify-between gap-3 px-3 py-2">
        <div className="flex items-center gap-2 text-xs font-medium"><TerminalSquare className="size-4" />Live activity</div>
        <div className="flex items-center gap-1">
          <Button variant="ghost" size="xs" onClick={copyOutput} disabled={!output} aria-label="Copy activity" aria-live="polite">
            {copyStatus === "copied" ? <Check /> : copyStatus === "failed" ? <AlertCircle /> : <Copy />}
            {copyStatus === "copied" ? "Copied" : copyStatus === "failed" ? "Copy failed" : "Copy"}
          </Button>
          <CollapsibleTrigger asChild>
            <Button variant="ghost" size="icon-xs" aria-label={open ? "Collapse activity" : "Expand activity"}>
              <ChevronsUpDown />
            </Button>
          </CollapsibleTrigger>
        </div>
      </div>
      <CollapsibleContent>
        <pre className="max-h-36 overflow-auto whitespace-pre-wrap break-words border-t border-border bg-zinc-950 px-3 py-2.5 font-mono text-[11px] leading-5 text-zinc-200 select-text dark:bg-black" aria-label="Workspace activity">{output || "No activity yet."}</pre>
      </CollapsibleContent>
    </Collapsible>
  )
}
