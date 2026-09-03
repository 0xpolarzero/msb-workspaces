import type { GitHubFixtureState, ScenarioName } from "@/fixtures/scenarios"
import { githubFixtureStates, scenarioNames } from "@/fixtures/scenarios"

export function FixtureSelector({ scenario, githubState }: { scenario: ScenarioName; githubState?: GitHubFixtureState }) {
  function selectFixture(parameter: string, value: string) {
    const url = new URL(window.location.href)
    if (value === "source") url.searchParams.delete(parameter)
    else url.searchParams.set(parameter, value)
    window.location.assign(url)
  }

  return (
    <aside className="fixed right-3 bottom-16 z-50 flex items-center gap-3 rounded-md border border-border bg-background/95 px-2 py-1 text-[11px] shadow-lg backdrop-blur sm:bottom-3" aria-label="Development fixtures">
      <label className="flex items-center gap-2">
        Fixture
        <select
          aria-label="Fixture scenario"
          className="rounded border border-border bg-background px-1.5 py-1 outline-none focus-visible:ring-2 focus-visible:ring-ring"
          value={scenario}
          onChange={(event) => selectFixture("scenario", event.target.value)}
        >
          {scenarioNames.map((name) => <option key={name} value={name}>{name}</option>)}
        </select>
      </label>
      <label className="flex items-center gap-2">
        GitHub
        <select
          aria-label="GitHub fixture state"
          className="rounded border border-border bg-background px-1.5 py-1 outline-none focus-visible:ring-2 focus-visible:ring-ring"
          value={githubState ?? "source"}
          onChange={(event) => selectFixture("github", event.target.value)}
        >
          <option value="source">source</option>
          {githubFixtureStates.map((state) => <option key={state} value={state}>{state}</option>)}
        </select>
      </label>
    </aside>
  )
}
