import { z } from "zod"

import {
  githubWorkspacePolicySchema,
  siloBootstrapConfigurationSchema,
  siloBootstrapResultSchema,
  siloBootstrapStateSchema,
  siloPreflightCheckSchema,
  siloProgressEventSchema,
  siloProtocolErrorSchema,
  setupMachineConfigurationRequestSchema,
} from "@/contracts/silo"
import type { SetupMachineConfigurationRequest } from "@/contracts/silo"
import { applicationPreferenceSelectionSchema, type ApplicationPreferenceSelection } from "@/features/preferences/model/application-preferences"

// This is the frontend's narrow input seam, not a Silo wire object. Each field
// remains an unmodified current protocol or app-state shape so a future bridge
// only has to replace the provider.
export const onboardingSourceSchema = z.object({
  machineConfigurations: setupMachineConfigurationRequestSchema.shape.machines,
  bootstrapConfiguration: siloBootstrapConfigurationSchema,
  bootstrapState: siloBootstrapStateSchema,
  preflightChecks: z.array(siloPreflightCheckSchema),
  progressEvents: z.array(siloProgressEventSchema),
  githubPolicies: z.array(githubWorkspacePolicySchema),
  currentHostGitIdentity: z.object({
    name: z.string(),
    email: z.string(),
  }).strict().nullable(),
  applicationPreferences: applicationPreferenceSelectionSchema,
  bootstrapResult: siloBootstrapResultSchema.nullable(),
  error: siloProtocolErrorSchema.nullable(),
}).strict().superRefine((source, context) => {
  const result = setupMachineConfigurationRequestSchema.safeParse({
    schemaVersion: 1,
    machines: source.machineConfigurations,
  })
  if (!result.success) {
    for (const issue of result.error.issues) {
      context.addIssue({ ...issue, path: ["machineConfigurations", ...issue.path.slice(1)] })
    }
  }
})

export type OnboardingSource = z.infer<typeof onboardingSourceSchema>

export type GitHubConnectionState = "disconnected" | "connecting" | "connected"

export interface WorkspaceRepositorySelection {
  repository: string
  allowPushes: boolean
}

export interface WorkspaceGitIdentity {
  name: string
  email: string
  apply: boolean
}

export interface OnboardingCompletionRequest {
  machineConfiguration: SetupMachineConfigurationRequest
  applications: ApplicationPreferenceSelection
  github: {
    connectionState: GitHubConnectionState
    workspaces: Array<{
      workspace: string
      repositories: WorkspaceRepositorySelection[]
      identity: WorkspaceGitIdentity
    }>
  }
}

export interface OnboardingActions {
  saveMachineConfiguration: (request: SetupMachineConfigurationRequest) => void
  repairRuntime: () => void
  retryWorkspaceSetup: () => void
  finishSetup: (request: OnboardingCompletionRequest) => void
}

export function parseOnboardingSource(input: unknown): OnboardingSource {
  return onboardingSourceSchema.parse(input)
}
