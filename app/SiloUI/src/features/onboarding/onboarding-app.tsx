import { useMemo, useState } from "react"

import { TabsContent } from "@/components/ui/tabs"
import { OnboardingShell } from "@/features/onboarding/components/onboarding-shell"
import type { OnboardingActions, OnboardingSource } from "@/features/onboarding/model/onboarding-source"
import { onboardingSteps, projectOnboarding, type OnboardingStep } from "@/features/onboarding/model/onboarding-state"
import { DependenciesStep } from "@/features/onboarding/steps/dependencies-step"
import { GitHubStep, type GitHubChoice } from "@/features/onboarding/steps/github-step"
import { IdentityStep, type IdentityChoice } from "@/features/onboarding/steps/identity-step"
import { ReviewStep } from "@/features/onboarding/steps/review-step"
import { WorkspacesStep } from "@/features/onboarding/steps/workspaces-step"

export function OnboardingApp({ source, actions }: { source: OnboardingSource; actions: OnboardingActions }) {
  const viewModel = useMemo(() => projectOnboarding(source), [source])
  const [activeStep, setActiveStep] = useState<OnboardingStep>("dependencies")
  const [githubChoice, setGithubChoice] = useState<GitHubChoice>("connect")
  const [repositorySelected, setRepositorySelected] = useState(true)
  const [identity, setIdentity] = useState<IdentityChoice>({
    name: source.identityInput.name,
    email: source.identityInput.email,
    applyToAll: source.identityInput.target === null,
  })
  const [finished, setFinished] = useState(false)
  const repository = source.githubPolicies[0]?.repositories[0]

  function move(offset: -1 | 1) {
    const current = onboardingSteps.indexOf(activeStep)
    const next = onboardingSteps[current + offset]
    if (next) setActiveStep(next)
  }

  function continueSetup() {
    if (activeStep === "review") {
      if (viewModel.finishEnabled) {
        actions.finishSetup()
        setFinished(true)
      }
      return
    }
    move(1)
  }

  return (
    <OnboardingShell
      activeStep={activeStep}
      viewModel={viewModel}
      onStepChange={setActiveStep}
      onBack={() => move(-1)}
      onContinue={continueSetup}
    >
      <TabsContent value="dependencies" className="mt-0 outline-none">
        <DependenciesStep groups={viewModel.dependencies} onRepairRuntime={actions.repairRuntime} />
      </TabsContent>
      <TabsContent value="workspaces" className="mt-0 outline-none">
        <WorkspacesStep progress={viewModel.workspaceProgress} onRetry={actions.retryWorkspaceSetup} />
      </TabsContent>
      <TabsContent value="github" className="mt-0 outline-none">
        {repository && (
          <GitHubStep
            progress={viewModel.workspaceProgress}
            choice={githubChoice}
            repositorySelected={repositorySelected}
            repository={repository}
            onChoiceChange={setGithubChoice}
            onRepositoryChange={setRepositorySelected}
            onViewProgress={() => setActiveStep("workspaces")}
          />
        )}
      </TabsContent>
      <TabsContent value="identity" className="mt-0 outline-none">
        <IdentityStep progress={viewModel.workspaceProgress} identity={identity} onIdentityChange={setIdentity} onViewProgress={() => setActiveStep("workspaces")} />
      </TabsContent>
      <TabsContent value="review" className="mt-0 outline-none">
        <ReviewStep
          progress={viewModel.workspaceProgress}
          queueItems={viewModel.queueItems}
          githubSummary={githubChoice === "skip" ? "GitHub access skipped" : `${repositorySelected ? repository?.fullName : "No repositories"} retained`}
          identitySummary={`${identity.name || "No name"} · ${identity.applyToAll ? "all workspaces" : "dev only"}`}
          errorMessage={viewModel.error?.message}
          errorRecovery={viewModel.error?.recovery ?? undefined}
          onViewProgress={() => setActiveStep("workspaces")}
          onRetryWorkspaceSetup={actions.retryWorkspaceSetup}
        />
        {finished && <p className="mt-3 text-center text-sm font-medium text-emerald-600" role="status">Setup complete</p>}
      </TabsContent>
    </OnboardingShell>
  )
}
