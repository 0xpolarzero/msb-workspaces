import { useState } from "react"

import { OnboardingApp } from "@/features/onboarding/onboarding-app"
import { FixtureSelector } from "@/fixtures/fixture-selector"
import { githubStateFromSearch, onboardingScenarios, repositoryFixtures, scenarioFromSearch } from "@/fixtures/scenarios"

export default function App() {
  const scenario = scenarioFromSearch(window.location.search)
  const githubState = githubStateFromSearch(window.location.search)
  const [source, setSource] = useState(onboardingScenarios[scenario])
  return (
    <>
      <OnboardingApp
        key={`${scenario}:${githubState}`}
        source={source}
        initialGitHubConnectionState={githubState}
        repositoryOptions={repositoryFixtures}
        actions={{
          repairRuntime: () => setSource(onboardingScenarios.running),
          retryWorkspaceSetup: () => setSource(onboardingScenarios.running),
          finishSetup: () => undefined,
        }}
      />
      {import.meta.env.DEV && <FixtureSelector scenario={scenario} githubState={githubState} />}
    </>
  )
}
