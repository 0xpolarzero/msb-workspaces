import { AlertCircle, Check, RotateCw } from "lucide-react"
import { useState } from "react"

import { DisclosureIndicator, disclosureTriggerStateClass } from "@/components/disclosure-indicator"
import { ListCard, ListRow, ListRowDetails, ListRowIcon } from "@/components/list-row"
import { Button } from "@/components/ui/button"
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible"
import { SetupNotice } from "@/features/onboarding/components/setup-notice"
import type { DependencyGroupView } from "@/features/onboarding/model/onboarding-state"

export function DependencyDisclosure({ group, onRepairRuntime }: { group: DependencyGroupView; onRepairRuntime: () => void }) {
  const [open, setOpen] = useState(group.status === "failed")
  const failedItems = group.items.filter(({ check }) => check && check.status !== "pass")
  const caption = failedItems.length > 0
    ? `${failedItems.length} ${failedItems.length === 1 ? "check needs" : "checks need"} attention`
    : `${group.items.length} components ready`

  return (
    <Collapsible open={open} onOpenChange={setOpen} asChild>
      <ListCard>
        <ListRow
          className="relative pr-8 hover:bg-muted/35 focus-within:bg-muted/35"
          icon={
            <ListRowIcon className={group.status === "failed" ? "bg-destructive/10 text-destructive" : "bg-emerald-500/10 text-emerald-700 dark:text-emerald-400"}>
              {group.status === "failed"
                ? <AlertCircle className="size-3.5" aria-label="Needs action" />
                : <Check className="size-3.5" aria-label="All checks passed" />}
            </ListRowIcon>
          }
          title={
            <CollapsibleTrigger className={`${disclosureTriggerStateClass} text-left outline-none after:absolute after:inset-0 after:rounded-md focus-visible:after:ring-2 focus-visible:after:ring-inset focus-visible:after:ring-ring/60`}>
              {group.title}
              <span className="absolute top-1/2 right-2 -translate-y-1/2"><DisclosureIndicator /></span>
            </CollapsibleTrigger>
          }
          detail={caption}
        />
        <CollapsibleContent className="collapsible-content-motion">
          <ListRowDetails label={`${group.title} checks`} className="gap-3">
            <div className="grid gap-x-5 gap-y-3 sm:grid-cols-2">
              {group.items.map((item) => {
                const failed = item.check && item.check.status !== "pass"
                return (
                  <div key={item.name} className="grid grid-cols-[1rem_1fr] gap-1.5">
                    {failed
                      ? <AlertCircle className="mt-0.5 size-3.5 text-destructive" aria-label="Failed" />
                      : <Check className="mt-0.5 size-3.5 text-muted-foreground" aria-label="Checked" />}
                    <div className="min-w-0">
                      <div className="text-[13px] leading-4 font-medium text-foreground">{item.name}</div>
                      <div className="text-[11px] leading-4 text-muted-foreground">{item.role}</div>
                    </div>
                  </div>
                )
              })}
            </div>
            {failedItems.map(({ name, check }) => check && (
              <SetupNotice
                key={name}
                title={check.id === "silo-runtime" ? "Silo runtime needs repair" : `${check.title} needs attention`}
                detail={check.detail}
                recovery={check.id === "silo-runtime" ? undefined : check.remediation ?? undefined}
                action={check.id === "silo-runtime" && (
                  <Button type="button" variant="outline" size="xs" onClick={onRepairRuntime}>
                    <RotateCw aria-hidden="true" />Repair…
                  </Button>
                )}
              />
            ))}
          </ListRowDetails>
        </CollapsibleContent>
      </ListCard>
    </Collapsible>
  )
}
