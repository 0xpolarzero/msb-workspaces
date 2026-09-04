import { useState } from "react"

import { ApplicationApp } from "@/features/application/application-app"
import { OnboardingApp } from "@/features/onboarding/onboarding-app"
import {
  applicationSourceForScenario,
  sandboxConfigurationFixtureModeFromSearch,
  workspaceFixtureModeFromSearch,
} from "@/fixtures/application-scenarios"
import { FixtureSelector } from "@/fixtures/fixture-selector"
import { githubStateFromSearch, onboardingScenarios, repositoryFixtures, scenarioFromSearch } from "@/fixtures/scenarios"
import { surfaceFromSearch } from "@/fixtures/surfaces"

export default function App() {
  const surface = surfaceFromSearch(window.location.search)
  const scenario = scenarioFromSearch(window.location.search)
  const githubState = import.meta.env.DEV ? githubStateFromSearch(window.location.search) : undefined
  const workspaceMode = import.meta.env.DEV ? workspaceFixtureModeFromSearch(window.location.search) : undefined
  const sandboxConfigurationMode = import.meta.env.DEV ? sandboxConfigurationFixtureModeFromSearch(window.location.search) : undefined
  const [source, setSource] = useState(onboardingScenarios[scenario])
  return (
    <>
      {surface === "app" ? (
        <ApplicationApp
          key={`${scenario}:${githubState ?? "source"}:${workspaceMode ?? "source"}:${sandboxConfigurationMode ?? "source"}`}
          source={applicationSourceForScenario(scenario, githubState, workspaceMode, sandboxConfigurationMode)}
          actions={{
            repairRuntime: () => undefined,
            saveMachineConfiguration: (_request) => undefined,
            retryMachineConfiguration: (_workspace) => undefined,
            startWorkspace: (_workspace) => undefined,
            pauseWorkspace: (_workspace) => undefined,
            stopWorkspace: (_workspace) => undefined,
            restartWorkspace: (_workspace) => undefined,
            openTerminal: (_workspace) => undefined,
            openEditor: (_workspace) => undefined,
          }}
        />
      ) : (
        <OnboardingApp
          key={`${scenario}:${githubState ?? "source"}`}
          source={source}
          initialGitHubConnectionState={githubState}
          repositoryOptions={repositoryFixtures}
          actions={{
            saveMachineConfiguration: (request) => setSource((current) => ({ ...current, machineConfigurations: request.machines })),
            repairRuntime: () => setSource(onboardingScenarios.running),
            retryWorkspaceSetup: () => setSource(onboardingScenarios.running),
            finishSetup: (_request) => undefined,
          }}
        />
      )}
      {import.meta.env.DEV && <FixtureSelector surface={surface} scenario={scenario} githubState={githubState} workspaceMode={workspaceMode} sandboxConfigurationMode={sandboxConfigurationMode} />}
    </>
  )
}
