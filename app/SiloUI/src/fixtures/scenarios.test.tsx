import { render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import { projectOnboarding } from "@/features/onboarding/model/onboarding-state"
import { productionMachineDefaults } from "@/features/onboarding/model/machine-configuration"
import { FixtureSelector } from "@/fixtures/fixture-selector"
import { onboardingScenarios, scenarioFromSearch, scenarioNames } from "@/fixtures/scenarios"

// Fixtures must exercise the UI with the same machines that progress describes.
describe("onboarding scenario coherence", () => {
  it.each(scenarioNames)("keeps configuration and progress machines aligned in %s", (name) => {
    const source = onboardingScenarios[name]
    const machines = source.machineConfigurations.filter((machine) => machine.kind === "vm")
    const names = machines.map((machine) => machine.name)
    expect(source.bootstrapConfiguration.workspaces.map((workspace) => workspace.name)).toEqual(names)
    expect(source.bootstrapConfiguration.workspaces).toEqual(machines.map((machine) => ({
      name: machine.name,
      cpu: machine.cpus,
      cpuCeiling: machine.maxCPUs,
      memoryGiB: machine.memoryGiB,
      memoryCeilingGiB: machine.maxMemoryGiB,
      workspaceStorageGiB: machine.workspaceStorageGiB,
      runtimeStorageGiB: machine.runtimeStorageGiB,
    })))
    for (const event of source.progressEvents) {
      if (event.workspace) expect(names).toContain(event.workspace)
    }
    if (source.error?.workspace) expect(names).toContain(source.error.workspace)
    if (name !== "stress-running") expect(source.machineConfigurations).toEqual(productionMachineDefaults)
  })

  it("shows the default three machines and an unfinished verification", () => {
    const { workspaceProgress: progress } = projectOnboarding(onboardingScenarios.running, "connected")
    expect(progress).toMatchObject({
      completedOperations: 8, totalOperations: 9, fraction: 8 / 9,
      currentWorkspace: "personal", readyCount: 2, workingCount: 1, waitingCount: 0, failedCount: 0,
    })
    expect(progress.workspaces.find(({ name }) => name === "personal")?.status).toBe("working")
    expect(progress.visibleEvents.every(({ safeForDisplay }) => safeForDisplay)).toBe(true)
  })

  it("fails the visible playgrounds machine and completes only real operations", () => {
    const { workspaceProgress: progress } = projectOnboarding(onboardingScenarios["bootstrap-failure"], "connected")
    expect(progress).toMatchObject({
      completedOperations: 4, totalOperations: 9, currentWorkspace: "playgrounds", failedCount: 1,
    })
    expect(progress.workspaces.find(({ name }) => name === "playgrounds")?.status).toBe("failed")
    expect(projectOnboarding(onboardingScenarios.complete, "connected").workspaceProgress).toMatchObject({
      completedOperations: 9, totalOperations: 9, fraction: 1, readyCount: 3,
    })
  })

  it("keeps the twelve-machine stress scenario explicit and selectable", () => {
    expect(scenarioFromSearch("?scenario=stress-running")).toBe("stress-running")
    expect(onboardingScenarios["stress-running"].machineConfigurations).toHaveLength(12)
    expect(projectOnboarding(onboardingScenarios["stress-running"], "connected").workspaceProgress).toMatchObject({
      completedOperations: 27, totalOperations: 36, currentWorkspace: "docs-build",
      readyCount: 3, workingCount: 1, waitingCount: 8,
    })
    render(<FixtureSelector surface="onboarding" scenario="stress-running" />)
    expect(within(screen.getByRole("combobox", { name: "Fixture scenario" })).getByRole("option", { name: "stress-running" })).toBeInTheDocument()
  })
})
