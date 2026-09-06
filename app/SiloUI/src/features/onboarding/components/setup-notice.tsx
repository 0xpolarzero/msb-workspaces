import { CircleAlert } from "lucide-react"
import { useState, type ReactNode } from "react"

import { CopyButton } from "@/components/copy-button"
import { DisclosureIndicator, disclosureTriggerStateClass } from "@/components/disclosure-indicator"
import { ListCard, ListRow, ListRowDetails, ListRowIcon } from "@/components/list-row"
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible"

export function SetupNotice({ title, detail, recovery, technicalDetails, action }: {
  title: string
  detail: string
  recovery?: string
  technicalDetails?: string
  action?: ReactNode
}) {
  const [detailsOpen, setDetailsOpen] = useState(false)

  return (
    <ListCard role="alert">
      <ListRow
        className="grid grid-cols-[auto_minmax(0,1fr)] gap-y-2 sm:flex"
        icon={<ListRowIcon className="bg-destructive/10 text-destructive" aria-hidden="true"><CircleAlert className="size-3.5" /></ListRowIcon>}
        title={<h3>{title}</h3>}
        detail={detail}
        detailClassName="whitespace-normal break-words select-text"
        actions={action && <div className="col-start-2 shrink-0">{action}</div>}
      />
      {(recovery || technicalDetails) && (
        <ListRowDetails label={`${title} details`}>
          {recovery && <p className="text-[11px] leading-4 text-muted-foreground select-text">{recovery}</p>}
          {technicalDetails && (
            <Collapsible open={detailsOpen} onOpenChange={setDetailsOpen} className="collapsible-motion group rounded-md border border-border">
              <div className="flex items-center gap-1 px-2 py-1">
                <CollapsibleTrigger className={`${disclosureTriggerStateClass} flex min-w-0 flex-1 items-center justify-between gap-2 rounded-sm py-1 text-left text-[11px] text-muted-foreground outline-none hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring/60`} aria-label={detailsOpen ? "Hide technical details" : "Show technical details"}>
                  Technical details<DisclosureIndicator />
                </CollapsibleTrigger>
                <CopyButton variant="ghost" size="icon-xs" value={technicalDetails} labels={{ idle: "Copy technical details", copied: "Technical details copied", failed: "Copy technical details failed" }} />
              </div>
              <CollapsibleContent className="collapsible-content-motion">
                <pre className="max-h-32 overflow-auto whitespace-pre-wrap break-words border-t border-border bg-zinc-950 px-3 py-2.5 font-mono text-[11px] leading-5 text-zinc-200 select-text dark:bg-black">{technicalDetails}</pre>
              </CollapsibleContent>
            </Collapsible>
          )}
        </ListRowDetails>
      )}
    </ListCard>
  )
}
