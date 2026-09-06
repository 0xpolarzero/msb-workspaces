import { ListCard } from "@/components/list-row"
import { DependencyDisclosure } from "@/features/onboarding/components/dependency-disclosure"
import type { DependencyGroupView } from "@/features/onboarding/model/onboarding-state"
import { ApplicationPreferenceFields } from "@/features/preferences/components/application-preference-fields"
import type { ApplicationPreferenceSelection } from "@/features/preferences/model/application-preferences"

export function DependenciesStep({
  groups,
  applicationPreferences,
  onApplicationPreferencesChange,
  onRepairRuntime,
}: {
  groups: DependencyGroupView[]
  applicationPreferences: ApplicationPreferenceSelection
  onApplicationPreferencesChange: (preferences: ApplicationPreferenceSelection) => void
  onRepairRuntime: () => void
}) {
  return (
    <section aria-labelledby="dependencies-title" className="mx-auto max-w-3xl">
      <h2 id="dependencies-title" className="sr-only" data-visual-heading="hidden">Dependencies</h2>
      <div className="grid gap-2">
        {groups.map((group) => <DependencyDisclosure key={group.id} group={group} onRepairRuntime={onRepairRuntime} />)}
      </div>
      <section aria-labelledby="onboarding-applications-title" className="mt-5 grid gap-2">
        <h3 id="onboarding-applications-title" className="text-xs font-medium">Applications</h3>
        <ListCard>
          <ApplicationPreferenceFields compact value={applicationPreferences} onChange={onApplicationPreferencesChange} />
        </ListCard>
      </section>
    </section>
  )
}
