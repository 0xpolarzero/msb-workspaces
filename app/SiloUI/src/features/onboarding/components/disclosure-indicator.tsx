import { ChevronDown } from "lucide-react"

export const disclosureTriggerStateClass = "[&[data-state=open]_.disclosure-caret]:rotate-180"

export function DisclosureIndicator() {
  return <ChevronDown className="disclosure-caret size-4 justify-self-center text-muted-foreground transition-transform" aria-hidden="true" />
}
