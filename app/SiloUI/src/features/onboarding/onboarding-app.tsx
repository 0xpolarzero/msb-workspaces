import { useEffect, useMemo, useRef, useState } from "react"

import { TabsContent } from "@/components/ui/tabs"
import type { SetupMachineConfiguration } from "@/contracts/silo"
import { OnboardingShell } from "@/features/onboarding/components/onboarding-shell"
import type {
  GitHubConnectionState,
  OnboardingActions,
  OnboardingSource,
  WorkspaceGitIdentity,
  WorkspaceRepositorySelection,
} from "@/features/onboarding/model/onboarding-source"
import { onboardingSteps, projectOnboarding, type OnboardingStep, type WorkspaceView } from "@/features/onboarding/model/onboarding-state"
import { configurationRequest } from "@/features/onboarding/model/machine-configuration"
import { DependenciesStep } from "@/features/onboarding/steps/dependencies-step"
import { GitHubStep } from "@/features/onboarding/steps/github-step"
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
  return Object.fromEntries(source.machineConfigurations.map(({ name }) => {
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
  return Object.fromEntries(source.machineConfigurations.map((workspace) => [
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
      ? `all ${workspaceNames.length} machines`
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
  const [activeStep, setActiveStep] = useState<OnboardingStep>("dependencies")
  const [githubConnectionState, setGithubConnectionState] = useState<GitHubConnectionState>(
    initialGitHubConnectionState ?? (source.githubPolicies.some(({ repositories }) => repositories.length > 0) ? "connected" : "disconnected"),
  )
  const viewModel = useMemo(() => projectOnboarding(source, githubConnectionState), [githubConnectionState, source])
  const [workspaceSelections, setWorkspaceSelections] = useState(() => initialWorkspaceSelections(source))
  const [workspaceIdentities, setWorkspaceIdentities] = useState(() => initialWorkspaceIdentities(source))
  const [machines, setMachines] = useState<SetupMachineConfiguration[]>(() => source.machineConfigurations.map((machine) => ({ ...machine })))
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

  function saveMachines(updated: SetupMachineConfiguration[]) {
    const request = configurationRequest(updated)
    const previousNameByID = new Map(machines.map(({ id, name }) => [id, name]))
    setWorkspaceSelections((current) => Object.fromEntries(request.machines.map(({ id, name }) => {
      const previousName = previousNameByID.get(id)
      return [name, current[name] ?? (previousName ? current[previousName] : undefined) ?? []]
    })))
    setWorkspaceIdentities((current) => Object.fromEntries(request.machines.map(({ id, name }) => {
      const previousName = previousNameByID.get(id)
      return [name, current[name] ?? (previousName ? current[previousName] : undefined)
        ?? { ...(source.currentHostGitIdentity ?? { name: "", email: "" }), apply: true }]
    })))
    setMachines(request.machines)
    actions.saveMachineConfiguration(request)
  }

  function connectGitHub() {
    window.clearTimeout(connectTimer.current)
    setGithubConnectionState("connecting")
    connectTimer.current = window.setTimeout(() => setGithubConnectionState("connected"), 700)
  }

  function updateWorkspaceSelections(workspace: string, selections: WorkspaceRepositorySelection[]) {
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

  function continueSetup() {
    if (activeStep === "review") {
      if (viewModel.finishEnabled) {
        actions.finishSetup({
          machineConfiguration: configurationRequest(machines),
          github: {
            connectionState: githubConnectionState,
            workspaces: machines.map(({ name }) => ({
              workspace: name,
              repositories: [...(workspaceSelections[name] ?? [])],
              identity: { ...workspaceIdentities[name] },
            })),
          },
        })
        setFinished(true)
      }
      return
    }
    move(1)
  }

  const machineNames = machines.map(({ name }) => name)
  const configuredWorkspaceCount = machineNames.filter((name) => (workspaceSelections[name] ?? []).length > 0).length
  const repositoryCount = machineNames.reduce((total, name) => total + (workspaceSelections[name] ?? []).length, 0)
  const pushEnabledRepositoryCount = machineNames.reduce(
    (total, name) => total + (workspaceSelections[name] ?? []).filter(({ allowPushes }) => allowPushes).length,
    0,
  )
  const repositoryLabel = repositoryCount === 1 ? "repository" : "repositories"
  const pushRepositoryLabel = pushEnabledRepositoryCount === 1 ? "repository" : "repositories"
  const githubSummary = githubConnectionState === "connected"
    ? `${repositoryCount} ${repositoryLabel} across ${configuredWorkspaceCount} of ${machines.length} machines · ${pushEnabledRepositoryCount} push-enabled ${pushRepositoryLabel}`
    : "GitHub not connected"
  const identitySummary = workspaceIdentitySummary(
    workspaceIdentities,
    machineNames,
  )
  const machineWorkspaceViews = machines.map((machine): WorkspaceView => (
    viewModel.workspaceProgress.workspaces.find(({ name }) => name === machine.name)
      ?? { name: machine.name, status: "waiting", detail: machine.kind === "ssh" ? "Remote via SSH" : "Waiting" }
  ))
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
      <TabsContent value="workspaces" className="mt-0 h-full min-h-0 overflow-hidden outline-none">
        <WorkspacesStep key={activeStep} machines={machines} progress={viewModel.workspaceProgress} onMachinesChange={saveMachines} onRetry={actions.retryWorkspaceSetup} />
      </TabsContent>
      <TabsContent value="github" className="mt-0 h-full outline-none">
        <GitHubStep
          workspaces={machineWorkspaceViews}
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
          machines={machines}
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
