import { AlertCircle, Check, ChevronDown } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible"
import type { DependencyGroupView } from "@/features/onboarding/model/onboarding-state"

export function DependencyDisclosure({ group, onRepairRuntime }: { group: DependencyGroupView; onRepairRuntime: () => void }) {
  return (
    <Collapsible defaultOpen={group.status === "failed"} className="group rounded-lg border border-border bg-card">
      <CollapsibleTrigger className="grid w-full grid-cols-[1.25rem_1fr_1.25rem] items-center px-3 py-3 text-left text-sm font-medium focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/60 [&[data-state=open]_.disclosure-caret]:rotate-180">
        {group.status === "succeeded" ? (
          <Check className="size-4 text-emerald-600 dark:text-emerald-400" aria-label="All checks passed" />
        ) : (
          <AlertCircle className="size-4 text-destructive" aria-label="Needs action" />
        )}
        <span>{group.title}</span>
        <ChevronDown className="disclosure-caret size-4 justify-self-center text-muted-foreground transition-transform" aria-hidden="true" />
      </CollapsibleTrigger>
      <CollapsibleContent>
        <div className="grid gap-x-5 gap-y-3 border-t border-border px-3 py-3 sm:grid-cols-2">
          {group.items.map((item) => {
            const failed = item.check && item.check.status !== "pass"
            return (
              <div key={item.name} className="grid grid-cols-[1rem_1fr] gap-2 text-xs">
                {failed ? (
                  <AlertCircle className="mt-0.5 size-3.5 text-destructive" aria-label="Failed" />
                ) : (
                  <Check className="mt-0.5 size-3.5 text-muted-foreground" aria-label="Checked" />
                )}
                <div className="min-w-0">
                  <div className="font-medium text-foreground">{item.name}</div>
                  <div className="text-muted-foreground">{item.role}</div>
                  {failed && (
                    <div className="mt-2 select-text rounded-md bg-destructive/8 p-2 text-destructive" role="alert">
                      <div>{item.check?.detail}</div>
                      {item.check?.remediation && <div className="mt-1 font-medium">{item.check.remediation}</div>}
                      {item.check?.id === "silo-runtime" && item.check.remediation?.includes("Repair…") && (
                        <Button type="button" variant="outline" size="xs" className="mt-2 text-foreground" onClick={onRepairRuntime}>
                          Repair…
                        </Button>
                      )}
                    </div>
                  )}
                </div>
              </div>
            )
          })}
        </div>
      </CollapsibleContent>
    </Collapsible>
  )
}
