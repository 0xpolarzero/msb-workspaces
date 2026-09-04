import { ChevronDown } from "lucide-react"

export const disclosureTriggerStateClass = "[&[data-state=open]_.disclosure-caret]:rotate-180"

export function DisclosureIndicator() {
  return <ChevronDown className="disclosure-caret size-4 shrink-0 transition-transform duration-200" aria-hidden="true" />
}
