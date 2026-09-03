import { z } from "zod"

import {
  githubWorkspacePolicySchema,
  siloBootstrapConfigurationSchema,
  siloBootstrapResultSchema,
  siloBootstrapStateSchema,
  siloPreflightCheckSchema,
  siloProgressEventSchema,
  siloProtocolErrorSchema,
  setupMachineConfigurationSchema,
} from "@/contracts/silo"
import type { SetupMachineConfigurationRequest } from "@/contracts/silo"

// This is the frontend's narrow input seam, not a Silo wire object. Each field
// remains an unmodified current protocol or app-state shape so a future bridge
// only has to replace the provider.
export const onboardingSourceSchema = z.object({
  machineConfigurations: z.array(setupMachineConfigurationSchema).min(1).max(64),
  bootstrapConfiguration: siloBootstrapConfigurationSchema,
  bootstrapState: siloBootstrapStateSchema,
  preflightChecks: z.array(siloPreflightCheckSchema),
  progressEvents: z.array(siloProgressEventSchema),
  githubPolicies: z.array(githubWorkspacePolicySchema),
  currentHostGitIdentity: z.object({
    name: z.string(),
    email: z.string(),
  }).strict().nullable(),
  bootstrapResult: siloBootstrapResultSchema.nullable(),
  error: siloProtocolErrorSchema.nullable(),
}).strict()

export type OnboardingSource = z.infer<typeof onboardingSourceSchema>

export interface OnboardingActions {
  saveMachineConfiguration: (request: SetupMachineConfigurationRequest) => void
  repairRuntime: () => void
  retryWorkspaceSetup: () => void
  finishSetup: (request: SetupMachineConfigurationRequest) => void
}

export function parseOnboardingSource(input: unknown): OnboardingSource {
  return onboardingSourceSchema.parse(input)
}
