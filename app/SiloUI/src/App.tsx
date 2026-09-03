import { useState } from "react"

import { OnboardingApp } from "@/features/onboarding/onboarding-app"
import { FixtureSelector } from "@/fixtures/fixture-selector"
import { onboardingScenarios, scenarioFromSearch } from "@/fixtures/scenarios"

export default function App() {
  const scenario = scenarioFromSearch(window.location.search)
  const [source, setSource] = useState(onboardingScenarios[scenario])
  return (
    <>
      <OnboardingApp
        key={scenario}
        source={source}
        actions={{
          repairRuntime: () => setSource(onboardingScenarios.running),
          retryWorkspaceSetup: () => setSource(onboardingScenarios.running),
          finishSetup: () => undefined,
        }}
      />
      {import.meta.env.DEV && <FixtureSelector scenario={scenario} />}
    </>
  )
}
