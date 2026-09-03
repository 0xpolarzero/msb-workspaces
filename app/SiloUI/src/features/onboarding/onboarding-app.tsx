import { useEffect, useMemo, useRef, useState } from "react"

import { TabsContent } from "@/components/ui/tabs"
import { OnboardingShell } from "@/features/onboarding/components/onboarding-shell"
import type { OnboardingActions, OnboardingSource } from "@/features/onboarding/model/onboarding-source"
import { onboardingSteps, projectOnboarding, type OnboardingStep } from "@/features/onboarding/model/onboarding-state"
import { DependenciesStep } from "@/features/onboarding/steps/dependencies-step"
import {
  GitHubStep,
  type GitHubConnectionState,
  type WorkspaceGitIdentity,
  type WorkspaceRepositorySelection,
} from "@/features/onboarding/steps/github-step"
import { ReviewStep } from "@/features/onboarding/steps/review-step"
import { WorkspacesStep } from "@/features/onboarding/steps/workspaces-step"

interface OnboardingAppProps {
  source: OnboardingSource
  actions: OnboardingActions
  initialGitHubConnectionState?: GitHubConnectionState
  repositoryOptions?: readonly string[]
}

function repositoryKey(repository: string): string {
  return repository.toLowerCase()
}

function uniqueRepositoryOptions(repositories: readonly string[]): string[] {
  const seen = new Set<string>()
  return repositories.filter((repository) => {
    const key = repositoryKey(repository)
    if (seen.has(key)) return false
    seen.add(key)
    return true
  })
}

function uniqueWorkspaceSelections(selections: readonly WorkspaceRepositorySelection[]): WorkspaceRepositorySelection[] {
  const seen = new Set<string>()
  return selections.filter(({ repository }) => {
    const key = repositoryKey(repository)
    if (seen.has(key)) return false
    seen.add(key)
    return true
  })
}

function initialWorkspaceSelections(source: OnboardingSource): Record<string, WorkspaceRepositorySelection[]> {
  return Object.fromEntries(source.bootstrapConfiguration.workspaces.map(({ name }) => {
    const repositories = source.githubPolicies
      .filter(({ workspace }) => workspace === name)
      .flatMap(({ repositories: policyRepositories }) => policyRepositories)
    return [name, uniqueWorkspaceSelections(repositories.map((repository) => ({
      repository: repository.fullName,
      allowPushes: repository.mode === "read-write",
    })))]
  }))
}

function initialWorkspaceIdentities(source: OnboardingSource): Record<string, WorkspaceGitIdentity> {
  const { name = "", email = "" } = source.currentHostGitIdentity ?? {}
  return Object.fromEntries(source.bootstrapConfiguration.workspaces.map((workspace) => [
    workspace.name,
    { name, email, apply: true },
  ]))
}

function gitIdentityLabel(identity: WorkspaceGitIdentity): string {
  return `${identity.name || "No name"} <${identity.email || "No email"}>`
}

function workspaceIdentitySummary(
  identities: Record<string, WorkspaceGitIdentity>,
  workspaceNames: readonly string[],
): string {
  const appliedGroups = new Map<string, { identity: WorkspaceGitIdentity; workspaces: string[] }>()
  const notApplied: string[] = []

  for (const workspace of workspaceNames) {
    const identity = identities[workspace]
    if (!identity?.apply) {
      notApplied.push(workspace)
      continue
    }
    const key = JSON.stringify([identity.name, identity.email])
    const group = appliedGroups.get(key)
    if (group) group.workspaces.push(workspace)
    else appliedGroups.set(key, { identity, workspaces: [workspace] })
  }

  const summaries = [...appliedGroups.values()].map(({ identity, workspaces }) => {
    const target = workspaces.length === workspaceNames.length
      ? `all ${workspaceNames.length} workspaces`
      : workspaces.join(", ")
    return `${gitIdentityLabel(identity)} → ${target}`
  })
  if (notApplied.length > 0) {
    summaries.push(`not applied → ${notApplied.join(", ")}`)
  }
  return summaries.join("; ")
}

function defaultRepositoryOptions(source: OnboardingSource): string[] {
  return source.githubPolicies.flatMap(({ repositories }) => repositories.map(({ fullName }) => fullName))
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
  const [repositoryAccessSkipped, setRepositoryAccessSkipped] = useState(false)
  const [workspaceSelections, setWorkspaceSelections] = useState(() => initialWorkspaceSelections(source))
  const [workspaceIdentities, setWorkspaceIdentities] = useState(() => initialWorkspaceIdentities(source))
  const [finished, setFinished] = useState(false)
  const connectTimer = useRef<number | undefined>(undefined)
  const availableRepositories = useMemo(
    () => uniqueRepositoryOptions(repositoryOptions ?? defaultRepositoryOptions(source)),
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
    setRepositoryAccessSkipped(false)
    setGithubConnectionState("connecting")
    connectTimer.current = window.setTimeout(() => setGithubConnectionState("connected"), 700)
  }

  function updateWorkspaceSelections(workspace: string, selections: WorkspaceRepositorySelection[]) {
    setRepositoryAccessSkipped(false)
    setWorkspaceSelections((current) => ({ ...current, [workspace]: uniqueWorkspaceSelections(selections) }))
  }

  function updateWorkspaceIdentity(workspace: string, identity: WorkspaceGitIdentity) {
    setWorkspaceIdentities((current) => ({ ...current, [workspace]: identity }))
  }

  function resetWorkspaceIdentity(workspace: string) {
    if (!source.currentHostGitIdentity) return
    setWorkspaceIdentities((current) => ({
      ...current,
      [workspace]: { ...current[workspace], ...source.currentHostGitIdentity },
    }))
  }

  function skipSetup() {
    if (activeStep === "github") {
      if (githubConnectionState === "connecting") {
        window.clearTimeout(connectTimer.current)
        setGithubConnectionState("disconnected")
      }
      setRepositoryAccessSkipped(true)
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
    if (activeStep === "github") setRepositoryAccessSkipped(false)
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
  const githubSummary = repositoryAccessSkipped
    ? "Repository access skipped"
    : githubConnectionState === "connected"
      ? `${repositoryCount} ${repositoryLabel} across ${configuredWorkspaceCount} of ${viewModel.workspaceProgress.workspaces.length} workspaces · ${pushEnabledRepositoryCount} push-enabled ${pushRepositoryLabel}`
      : "GitHub not connected"
  const identitySummary = workspaceIdentitySummary(
    workspaceIdentities,
    viewModel.workspaceProgress.workspaces.map(({ name }) => name),
  )

  return (
    <OnboardingShell
      activeStep={activeStep}
      viewModel={viewModel}
      onStepChange={setActiveStep}
      onBack={() => move(-1)}
      onContinue={continueSetup}
      onSkip={skipSetup}
    >
      <TabsContent value="dependencies" className="mt-0 outline-none">
        <DependenciesStep groups={viewModel.dependencies} onRepairRuntime={actions.repairRuntime} />
      </TabsContent>
      <TabsContent value="workspaces" className="mt-0 h-full min-h-0 overflow-hidden outline-none">
        <WorkspacesStep progress={viewModel.workspaceProgress} onRetry={actions.retryWorkspaceSetup} />
      </TabsContent>
      <TabsContent value="github" className="mt-0 h-full outline-none">
        <GitHubStep
          workspaces={viewModel.workspaceProgress.workspaces}
          connectionState={githubConnectionState}
          repositoryOptions={availableRepositories}
          workspaceSelections={workspaceSelections}
          workspaceIdentities={workspaceIdentities}
          currentHostGitIdentity={source.currentHostGitIdentity}
          onConnect={connectGitHub}
          onWorkspaceSelectionsChange={updateWorkspaceSelections}
          onWorkspaceIdentityChange={updateWorkspaceIdentity}
          onResetWorkspaceIdentity={resetWorkspaceIdentity}
        />
      </TabsContent>
      <TabsContent value="review" className="mt-0 outline-none">
        <ReviewStep
          workspaceRetryable={viewModel.workspaceProgress.retryable}
          queueItems={viewModel.queueItems}
          githubSummary={githubSummary}
          identitySummary={identitySummary}
          errorMessage={viewModel.error?.message}
          errorRecovery={viewModel.error?.recovery ?? undefined}
          onRetryWorkspaceSetup={actions.retryWorkspaceSetup}
        />
        {finished && <p className="mt-3 text-center text-sm font-medium text-emerald-600" role="status">Setup complete</p>}
      </TabsContent>
    </OnboardingShell>
  )
}
