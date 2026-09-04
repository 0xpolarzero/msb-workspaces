import type { GitHubFixtureState, ScenarioName } from "@/fixtures/scenarios"
import { githubFixtureStates, scenarioNames } from "@/fixtures/scenarios"
import {
  sandboxConfigurationFixtureModes,
  workspaceFixtureModes,
  type SandboxConfigurationFixtureMode,
  type WorkspaceFixtureMode,
} from "@/fixtures/application-scenarios"
import type { SurfaceName } from "@/fixtures/surfaces"
import { surfaceNames } from "@/fixtures/surfaces"

import { ThemeToggle } from "@/features/onboarding/components/theme-toggle"

export function FixtureSelector({ surface, scenario, githubState, workspaceMode, sandboxConfigurationMode }: {
  surface: SurfaceName
  scenario: ScenarioName
  githubState?: GitHubFixtureState
  workspaceMode?: WorkspaceFixtureMode
  sandboxConfigurationMode?: SandboxConfigurationFixtureMode
}) {
  function selectFixture(parameter: string, value: string) {
    const url = new URL(window.location.href)
    if (value === "source") url.searchParams.delete(parameter)
    else url.searchParams.set(parameter, value)
    window.location.assign(url)
  }

  return (
    <aside className="fixed right-3 bottom-16 z-50 flex max-w-[calc(100vw-1.5rem)] flex-wrap items-center justify-end gap-3 rounded-md border border-border bg-background/95 px-2 py-1 text-[11px] shadow-lg backdrop-blur sm:bottom-3" aria-label="Development fixtures">
      <label className="flex items-center gap-2">
        View
        <select
          aria-label="Product view"
          className="rounded border border-border bg-background px-1.5 py-1 outline-none focus-visible:ring-2 focus-visible:ring-ring"
          value={surface}
          onChange={(event) => selectFixture("view", event.target.value)}
        >
          {surfaceNames.map((name) => <option key={name} value={name}>{name}</option>)}
        </select>
      </label>
      {surface === "app" && (
        <>
          <label className="flex items-center gap-2">
            State
            <select
              aria-label="Sandbox state fixture"
              className="rounded border border-border bg-background px-1.5 py-1 outline-none focus-visible:ring-2 focus-visible:ring-ring"
              value={workspaceMode ?? "source"}
              onChange={(event) => selectFixture("sandbox-state", event.target.value)}
            >
              <option value="source">source</option>
              {workspaceFixtureModes.map((mode) => <option key={mode} value={mode}>{mode}</option>)}
            </select>
          </label>
          <label className="flex items-center gap-2">
            Change
            <select
              aria-label="Sandbox change fixture"
              className="rounded border border-border bg-background px-1.5 py-1 outline-none focus-visible:ring-2 focus-visible:ring-ring"
              value={sandboxConfigurationMode ?? "source"}
              onChange={(event) => selectFixture("sandbox-change", event.target.value)}
            >
              <option value="source">source</option>
              {sandboxConfigurationFixtureModes.map((mode) => <option key={mode} value={mode}>{mode}</option>)}
            </select>
          </label>
        </>
      )}
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
      <ThemeToggle />
    </aside>
  )
}
