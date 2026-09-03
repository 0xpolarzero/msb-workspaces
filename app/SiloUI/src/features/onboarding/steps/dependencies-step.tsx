import { DependencyDisclosure } from "@/features/onboarding/components/dependency-disclosure"
import type { DependencyGroupView } from "@/features/onboarding/model/onboarding-state"

export function DependenciesStep({ groups, onRepairRuntime }: { groups: DependencyGroupView[]; onRepairRuntime: () => void }) {
  return (
    <section aria-labelledby="dependencies-title" className="mx-auto max-w-3xl">
      <div className="mb-5">
        <h2 id="dependencies-title" className="text-xl font-semibold tracking-tight">Dependencies</h2>
      </div>
      <div className="grid gap-2">
        {groups.map((group) => <DependencyDisclosure key={group.id} group={group} onRepairRuntime={onRepairRuntime} />)}
      </div>
    </section>
  )
}
