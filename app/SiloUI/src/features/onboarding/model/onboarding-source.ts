import { z } from "zod"

import {
  githubWorkspacePolicySchema,
  setupIdentityQueueInputSchema,
  siloBootstrapConfigurationSchema,
  siloBootstrapResultSchema,
  siloBootstrapStateSchema,
  siloPreflightCheckSchema,
  siloProgressEventSchema,
  siloProtocolErrorSchema,
} from "@/contracts/silo"

// This is the frontend's narrow input seam, not a Silo wire object. Each field
// remains an unmodified current protocol or app-state shape so a future bridge
// only has to replace the provider.
export const onboardingSourceSchema = z.object({
  bootstrapConfiguration: siloBootstrapConfigurationSchema,
  bootstrapState: siloBootstrapStateSchema,
  preflightChecks: z.array(siloPreflightCheckSchema),
  progressEvents: z.array(siloProgressEventSchema),
  githubPolicies: z.array(githubWorkspacePolicySchema),
  identityInput: setupIdentityQueueInputSchema,
  bootstrapResult: siloBootstrapResultSchema.nullable(),
  error: siloProtocolErrorSchema.nullable(),
}).strict()

export type OnboardingSource = z.infer<typeof onboardingSourceSchema>

export interface OnboardingActions {
  repairRuntime: () => void
  retryWorkspaceSetup: () => void
  finishSetup: () => void
}

export function parseOnboardingSource(input: unknown): OnboardingSource {
  return onboardingSourceSchema.parse(input)
}
