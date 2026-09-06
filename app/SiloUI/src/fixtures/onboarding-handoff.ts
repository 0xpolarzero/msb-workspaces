import type { ApplicationSource } from "@/features/application/model/application-source"
import type { OnboardingCompletionRequest } from "@/features/onboarding/model/onboarding-source"
import { applicationSourceForScenario } from "./application-scenarios"

// The web preview carries setup choices into its application fixture. Native
// completion and live sandbox state remain the responsibility of the provider.
export function applicationPreviewAfterSetup(request: OnboardingCompletionRequest): ApplicationSource {
  const base = applicationSourceForScenario("complete", request.github.connectionState)
  return {
    ...base,
    workspaces: request.machineConfiguration.machines.map((machine) => ({
      machine: { ...machine },
      purpose: machine.kind === "ssh" ? "Remote sandbox" : "Local sandbox",
      state: "stopped",
      stateDetail: "Ready",
      freshness: "fresh",
      host: machine.kind === "ssh" ? machine.host : `${machine.name}.silo.test`,
      repositories: [],
      files: [],
      ports: [],
      logs: [],
      githubRepositories: request.github.workspaces.find(({ workspace }) => workspace === machine.name)?.repositories.map(({ repository }) => repository) ?? [],
      secretNames: [],
    })),
    activities: [],
    secrets: [],
    backup: { lastArchive: "", completedLabel: "", compressedSize: "", destination: "" },
    runtimeRepair: null,
    sandboxConfigurationOperation: null,
    repositoryPushOperations: [],
    preferences: { ...base.preferences, ...request.applications },
    github: {
      ...base.github,
      accessEnabled: request.github.connectionState === "connected",
      workspaces: request.github.workspaces.map(({ workspace, identity, repositories }) => ({
        workspace, identity: { ...identity }, repositories: repositories.map((repository) => ({ ...repository })),
      })),
      workspaceOperations: [],
    },
  }
}
