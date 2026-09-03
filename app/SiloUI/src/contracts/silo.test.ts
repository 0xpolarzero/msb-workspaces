import { describe, expect, it } from "vitest"

import {
  githubWorkspacePolicySchema,
  setupMachineConfigurationRequestSchema,
  setupWorkspaceConfigurationSchema,
  siloProgressEventSchema,
} from "@/contracts/silo"
import { onboardingSourceSchema } from "@/features/onboarding/model/onboarding-source"
import { productionMachineDefaults } from "@/features/onboarding/model/machine-configuration"
import { onboardingScenarios, scenarioNames } from "@/fixtures/scenarios"

describe("Silo contract fixtures", () => {
  it("parses every scenario through strict runtime contracts", () => {
    for (const name of scenarioNames) {
      expect(onboardingSourceSchema.parse(onboardingScenarios[name])).toEqual(onboardingScenarios[name])
    }
  })

  it("accepts an explicit optional host Git identity without reading local configuration", () => {
    expect(onboardingSourceSchema.parse({
      ...onboardingScenarios.running,
      currentHostGitIdentity: null,
    }).currentHostGitIdentity).toBeNull()
    expect(onboardingScenarios.running.currentHostGitIdentity).toEqual({
      name: "Taylor Example",
      email: "taylor@example.com",
    })
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

  it("keeps the machine host-boundary request discriminated, ordered, and strict", () => {
    const request = setupMachineConfigurationRequestSchema.parse({
      schemaVersion: 1,
      machines: [
        productionMachineDefaults[1],
        {
          id: "00000000-0000-4000-8000-000000000100",
          kind: "ssh",
          name: "remote",
          host: "remote.example.com",
          user: "developer",
          port: 22,
        },
      ],
    })
    expect(request.machines.map(({ name }) => name)).toEqual(["playgrounds", "remote"])
    expect(request.machines.map(({ kind }) => kind)).toEqual(["vm", "ssh"])
    expect(() => setupMachineConfigurationRequestSchema.parse({
      ...request,
      machines: [{ ...request.machines[1], ignoredCredential: "secret" }],
    })).toThrow()
    expect(() => setupMachineConfigurationRequestSchema.parse({
      ...request,
      machines: [request.machines[0], { ...request.machines[1], name: "PLAYGROUNDS" }],
    })).toThrow()
    expect(() => setupMachineConfigurationRequestSchema.parse({
      ...request,
      machines: [request.machines[0], { ...request.machines[1], id: request.machines[0].id }],
    })).toThrow("machine IDs must be unique")
  })
})
