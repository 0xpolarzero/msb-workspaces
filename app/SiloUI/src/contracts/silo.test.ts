import { describe, expect, it } from "vitest"

import {
  githubWorkspacePolicySchema,
  setupWorkspaceConfigurationSchema,
  siloProgressEventSchema,
} from "@/contracts/silo"
import { onboardingSourceSchema } from "@/features/onboarding/model/onboarding-source"
import { onboardingScenarios, scenarioNames } from "@/fixtures/scenarios"

describe("Silo contract fixtures", () => {
  it("parses every scenario through strict runtime contracts", () => {
    for (const name of scenarioNames) {
      expect(onboardingSourceSchema.parse(onboardingScenarios[name])).toEqual(onboardingScenarios[name])
    }
  })

  it("keeps progress events on the exact schema-version 1 contract", () => {
    const event = onboardingScenarios.running.progressEvents.at(-1)
    expect(event).toMatchObject({
      schemaVersion: 1,
      type: "progress",
      requestId: "setup-bootstrap-20260903",
      phase: "verification",
      step: "workspace-verification",
      workspace: "docs-build",
      fraction: 0,
      message: "Verifying 'docs-build'.",
      safeForDisplay: true,
    })
    expect(event?.revision).toMatch(/^[0-9a-f]{64}$/)
    expect(onboardingScenarios.running.bootstrapState).toMatchObject({
      phase: "workspaces",
      startedAt: expect.any(Number),
      updatedAt: expect.any(Number),
      phaseDurations: expect.any(Object),
    })
  })

  it("rejects unknown keys and a numeric progress revision", () => {
    const valid = onboardingScenarios.running.progressEvents.at(-1)
    expect(() => siloProgressEventSchema.parse({ ...valid, inventedCaption: "no" })).toThrow()
    expect(() => siloProgressEventSchema.parse({ ...valid, revision: 1 })).toThrow()
  })

  it("enforces the native workspace and repository invariants", () => {
    expect(() => setupWorkspaceConfigurationSchema.parse({
      ...onboardingScenarios.complete.bootstrapState.workspaceConfigurations?.[0],
      cpus: 12,
      maxCPUs: 4,
    })).toThrow("cpus must not exceed maxCPUs")

    expect(() => githubWorkspacePolicySchema.parse({
      ...onboardingScenarios.running.githubPolicies[0],
      repositories: [{
        ...onboardingScenarios.running.githubPolicies[0].repositories[0],
        workspace: "personal",
      }],
    })).toThrow("repository workspaces must match the policy workspace")
  })
})
