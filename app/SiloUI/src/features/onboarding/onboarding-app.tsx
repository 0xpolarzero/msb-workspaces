import { useEffect, useMemo, useRef, useState } from "react"

import { TabsContent } from "@/components/ui/tabs"
import { OnboardingShell } from "@/features/onboarding/components/onboarding-shell"
import type { OnboardingActions, OnboardingSource } from "@/features/onboarding/model/onboarding-source"
import { onboardingSteps, projectOnboarding, type OnboardingStep } from "@/features/onboarding/model/onboarding-state"
import { DependenciesStep } from "@/features/onboarding/steps/dependencies-step"
import {
  GitHubStep,
  type GitHubConnectionState,
  type WorkspaceRepositorySelection,
} from "@/features/onboarding/steps/github-step"
import { IdentityStep, type IdentityChoice } from "@/features/onboarding/steps/identity-step"
import { ReviewStep } from "@/features/onboarding/steps/review-step"
import { WorkspacesStep } from "@/features/onboarding/steps/workspaces-step"

interface OnboardingAppProps {
  source: OnboardingSource
  actions: OnboardingActions
  initialGitHubConnectionState?: GitHubConnectionState
  repositoryOptions?: readonly string[]
}

function initialWorkspaceSelections(source: OnboardingSource): Record<string, WorkspaceRepositorySelection[]> {
  return Object.fromEntries(source.bootstrapConfiguration.workspaces.map(({ name }) => {
    const repositories = source.githubPolicies
      .filter(({ workspace }) => workspace === name)
      .flatMap(({ repositories: policyRepositories }) => policyRepositories)
    const selections = new Map<string, WorkspaceRepositorySelection>()
    for (const repository of repositories) {
      selections.set(repository.fullName, {
        repository: repository.fullName,
        allowPushes: repository.mode === "read-write",
      })
    }
    return [name, [...selections.values()]]
  }))
}

function defaultRepositoryOptions(source: OnboardingSource): string[] {
  return [...new Set(source.githubPolicies.flatMap(({ repositories }) => repositories.map(({ fullName }) => fullName)))]
}

export function OnboardingApp({
  source,
  actions,
  initialGitHubConnectionState,
  repositoryOptions,
}: OnboardingAppProps) {
  const viewModel = useMemo(() => projectOnboarding(source), [source])
  const [activeStep, setActiveStep] = useState<OnboardingStep>("dependencies")
  const [githubConnectionState, setGithubConnectionState] = useState<GitHubConnectionState>(
    initialGitHubConnectionState ?? (source.githubPolicies.some(({ repositories }) => repositories.length > 0) ? "connected" : "disconnected"),
  )
  const [githubSkipped, setGithubSkipped] = useState(false)
  const [workspaceSelections, setWorkspaceSelections] = useState(() => initialWorkspaceSelections(source))
  const defaultIdentityTarget = source.identityInput.target ?? source.bootstrapConfiguration.workspaces[0]?.name ?? null
  const [identity, setIdentity] = useState<IdentityChoice>({
    name: source.identityInput.name,
    email: source.identityInput.email,
    target: source.identityInput.target,
  })
  const [identitySkipped, setIdentitySkipped] = useState(false)
  const [finished, setFinished] = useState(false)
  const connectTimer = useRef<number | undefined>(undefined)
  const availableRepositories = useMemo(
    () => [...new Set(repositoryOptions ?? defaultRepositoryOptions(source))],
    [repositoryOptions, source],
  )

  useEffect(() => () => window.clearTimeout(connectTimer.current), [])

  function move(offset: -1 | 1) {
    const current = onboardingSteps.indexOf(activeStep)
    const next = onboardingSteps[current + offset]
    if (next) setActiveStep(next)
  }

  function connectGitHub() {
    window.clearTimeout(connectTimer.current)
    setGithubSkipped(false)
    setGithubConnectionState("connecting")
    connectTimer.current = window.setTimeout(() => setGithubConnectionState("connected"), 700)
  }

  function updateWorkspaceSelections(workspace: string, selections: WorkspaceRepositorySelection[]) {
    setGithubSkipped(false)
    setWorkspaceSelections((current) => ({ ...current, [workspace]: selections }))
  }

  function updateIdentity(nextIdentity: IdentityChoice) {
    setIdentitySkipped(false)
    setIdentity(nextIdentity)
  }

  function skipSetup() {
    if (activeStep === "github") {
      if (githubConnectionState === "connecting") {
        window.clearTimeout(connectTimer.current)
        setGithubConnectionState("disconnected")
      }
      setGithubSkipped(true)
      setActiveStep("identity")
    } else if (activeStep === "identity") {
      setIdentitySkipped(true)
      setActiveStep("review")
    }
  }

  function continueSetup() {
    if (activeStep === "review") {
      if (viewModel.finishEnabled) {
        actions.finishSetup()
        setFinished(true)
      }
      return
    }
    if (activeStep === "github") setGithubSkipped(false)
    if (activeStep === "identity") setIdentitySkipped(false)
    move(1)
  }

  const configuredWorkspaceCount = Object.values(workspaceSelections).filter((repositories) => repositories.length > 0).length
  const repositoryCount = Object.values(workspaceSelections).reduce((total, repositories) => total + repositories.length, 0)
  const pushEnabledRepositoryCount = Object.values(workspaceSelections).reduce(
    (total, repositories) => total + repositories.filter(({ allowPushes }) => allowPushes).length,
    0,
  )
  const repositoryLabel = repositoryCount === 1 ? "repository" : "repositories"
  const pushRepositoryLabel = pushEnabledRepositoryCount === 1 ? "repository" : "repositories"
  const githubSummary = githubSkipped
    ? "GitHub access skipped"
    : githubConnectionState === "connected"
      ? `${repositoryCount} ${repositoryLabel} across ${configuredWorkspaceCount} of ${viewModel.workspaceProgress.workspaces.length} workspaces · ${pushEnabledRepositoryCount} push-enabled ${pushRepositoryLabel}`
      : "GitHub not connected"
  const identitySummary = identitySkipped
    ? "Git identity skipped"
    : `${identity.name || "No name"} · ${identity.email || "No email"} · ${identity.target === null ? "all workspaces" : `${identity.target} only`}`

  return (
    <OnboardingShell
      activeStep={activeStep}
      viewModel={viewModel}
      onStepChange={setActiveStep}
      onBack={() => move(-1)}
      onContinue={continueSetup}
      onSkip={skipSetup}
      continueDisabled={activeStep === "github" && githubConnectionState !== "connected"}
    >
      <TabsContent value="dependencies" className="mt-0 outline-none">
        <DependenciesStep groups={viewModel.dependencies} onRepairRuntime={actions.repairRuntime} />
      </TabsContent>
      <TabsContent value="workspaces" className="mt-0 outline-none">
        <WorkspacesStep progress={viewModel.workspaceProgress} onRetry={actions.retryWorkspaceSetup} />
      </TabsContent>
      <TabsContent value="github" className="mt-0 outline-none">
        <GitHubStep
          progress={viewModel.workspaceProgress}
          connectionState={githubConnectionState}
          repositoryOptions={availableRepositories}
          workspaceSelections={workspaceSelections}
          onConnect={connectGitHub}
          onWorkspaceSelectionsChange={updateWorkspaceSelections}
          onViewProgress={() => setActiveStep("workspaces")}
        />
      </TabsContent>
      <TabsContent value="identity" className="mt-0 outline-none">
        <IdentityStep progress={viewModel.workspaceProgress} identity={identity} defaultTarget={defaultIdentityTarget} onIdentityChange={updateIdentity} onViewProgress={() => setActiveStep("workspaces")} />
      </TabsContent>
      <TabsContent value="review" className="mt-0 outline-none">
        <ReviewStep
          progress={viewModel.workspaceProgress}
          queueItems={viewModel.queueItems}
          githubSummary={githubSummary}
          identitySummary={identitySummary}
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
