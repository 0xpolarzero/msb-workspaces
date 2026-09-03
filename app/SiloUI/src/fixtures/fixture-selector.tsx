import type { ScenarioName } from "@/fixtures/scenarios"
import { scenarioNames } from "@/fixtures/scenarios"

export function FixtureSelector({ scenario }: { scenario: ScenarioName }) {
  return (
    <label className="fixed right-3 bottom-16 z-50 flex items-center gap-2 rounded-md border border-border bg-background/95 px-2 py-1 text-[11px] shadow-lg backdrop-blur sm:bottom-3">
      Fixture
      <select
        aria-label="Fixture scenario"
        className="rounded border border-border bg-background px-1.5 py-1 outline-none focus-visible:ring-2 focus-visible:ring-ring"
        value={scenario}
        onChange={(event) => {
          const url = new URL(window.location.href)
          url.searchParams.set("scenario", event.target.value)
          window.location.assign(url)
        }}
      >
        {scenarioNames.map((name) => <option key={name} value={name}>{name}</option>)}
      </select>
    </label>
  )
}
