import { useEffect, useState } from "react"

import { ApplicationApp } from "@/features/application/application-app"
import { OnboardingApp } from "@/features/onboarding/onboarding-app"
import {
  applicationSourceForScenario,
  githubManagementFixtureModeFromSearch,
  repositoryPushFixtureModeFromSearch,
  sandboxConfigurationFixtureModeFromSearch,
  systemIssueFixtureModeFromSearch,
  workspaceFixtureModeFromSearch,
} from "@/fixtures/application-scenarios"
import { FixtureSelector } from "@/fixtures/fixture-selector"
import { activityFixtureModeFromSearch, activityFixtureStepCount } from "@/fixtures/application-activity"
import { githubStateFromSearch, onboardingScenarios, repositoryFixtures, scenarioFromSearch } from "@/fixtures/scenarios"
import { surfaceFromSearch } from "@/fixtures/surfaces"

export default function App() {
  const surface = surfaceFromSearch(window.location.search)
  const scenario = scenarioFromSearch(window.location.search)
  const githubState = import.meta.env.DEV ? githubStateFromSearch(window.location.search) : undefined
  const workspaceMode = import.meta.env.DEV ? workspaceFixtureModeFromSearch(window.location.search) : undefined
  const sandboxConfigurationMode = import.meta.env.DEV ? sandboxConfigurationFixtureModeFromSearch(window.location.search) : undefined
  const systemIssueMode = import.meta.env.DEV ? systemIssueFixtureModeFromSearch(window.location.search) : undefined
  const repositoryPushMode = import.meta.env.DEV ? repositoryPushFixtureModeFromSearch(window.location.search) : undefined
  const githubManagementMode = import.meta.env.DEV ? githubManagementFixtureModeFromSearch(window.location.search) : undefined
  const activityMode = import.meta.env.DEV ? activityFixtureModeFromSearch(window.location.search) : undefined
  const [activityStep, setActivityStep] = useState(0)
  const [source, setSource] = useState(onboardingScenarios[scenario])

  useEffect(() => {
    const stepCount = activityFixtureStepCount(activityMode)
    if (stepCount <= 1) return
    const timer = window.setInterval(() => {
      setActivityStep((current) => {
        if (current >= stepCount - 1) {
          window.clearInterval(timer)
          return current
        }
        return current + 1
      })
    }, 1_600)
    return () => window.clearInterval(timer)
  }, [activityMode])
  return (
    <>
      {surface === "app" ? (
        <ApplicationApp
          key={`${scenario}:${githubState ?? "source"}:${workspaceMode ?? "source"}:${sandboxConfigurationMode ?? "source"}:${systemIssueMode ?? "source"}:${repositoryPushMode ?? "source"}:${activityMode ?? "source"}:${githubManagementMode ?? "source"}`}
          source={applicationSourceForScenario(scenario, githubState, workspaceMode, sandboxConfigurationMode, systemIssueMode, repositoryPushMode, activityMode, activityStep, githubManagementMode)}
          actions={{
            repairRuntime: () => undefined,
            saveMachineConfiguration: (_request) => undefined,
            retryMachineConfiguration: (_workspace) => undefined,
            pushRepository: (_workspace, _repositoryPath) => undefined,
            startWorkspace: (_workspace) => undefined,
            pauseWorkspace: (_workspace) => undefined,
            stopWorkspace: (_workspace) => undefined,
            restartWorkspace: (_workspace) => undefined,
            openTerminal: (_workspace) => undefined,
            openEditor: (_workspace) => undefined,
            disconnectGitHub: () => undefined,
            clearGitHubRepositoryAccess: () => undefined,
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
      {import.meta.env.DEV && <FixtureSelector surface={surface} scenario={scenario} githubState={githubState} workspaceMode={workspaceMode} sandboxConfigurationMode={sandboxConfigurationMode} systemIssueMode={systemIssueMode} repositoryPushMode={repositoryPushMode} githubManagementMode={githubManagementMode} activityMode={activityMode} />}
    </>
  )
}
