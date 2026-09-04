import { render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import {
  applicationSourceForScenario,
  repositoryPushFixtureModeFromSearch,
  repositoryPushFixtureModes,
  sandboxConfigurationFixtureModeFromSearch,
  sandboxConfigurationFixtureModes,
  systemIssueFixtureModeFromSearch,
  systemIssueFixtureModes,
  workspaceFixtureModeFromSearch,
  workspaceFixtureModes,
} from "@/fixtures/application-scenarios"
import { FixtureSelector } from "@/fixtures/fixture-selector"
import {
  activityCatalog,
  activityFixtureModeFromSearch,
  activityFixtureModes,
  activityFixtureStepCount,
  applicationActivitiesForFixture,
} from "@/fixtures/application-activity"

describe("application state fixtures", () => {
  it("parses and applies every sandbox state mode", () => {
    for (const mode of workspaceFixtureModes) {
      expect(workspaceFixtureModeFromSearch(`?sandbox-state=${mode}`)).toBe(mode)
      const source = applicationSourceForScenario("running", undefined, mode)
      const expectedState = mode === "error" ? "failed" : mode === "warning" ? "stopped" : mode
      expect(source.workspaces.every(({ state }) => state === expectedState)).toBe(true)
      expect(source.workspaces.every(({ attention }) => attention?.level === (mode === "warning" ? "warning" : mode === "error" ? "error" : undefined))).toBe(true)
    }
    expect(workspaceFixtureModeFromSearch("?sandbox-state=unknown")).toBeUndefined()
  })

  it("shows every state mode only for the application fixture", () => {
    const app = render(<FixtureSelector surface="app" scenario="running" workspaceMode="starting" sandboxConfigurationMode="add-verifying" systemIssueMode="verifying" repositoryPushMode="pushing" activityMode="backup-live" />)
    const controls = screen.getByLabelText("Development fixtures")
    expect(controls).toHaveClass("max-w-[calc(100vw-1.5rem)]", "flex-wrap")
    expect(within(screen.getByRole("combobox", { name: "Sandbox state fixture" })).getAllByRole("option").map(({ textContent }) => textContent)).toEqual([
      "source",
      "running",
      "starting",
      "stopped",
      "warning",
      "error",
    ])
    expect(within(screen.getByRole("combobox", { name: "Sandbox change fixture" })).getAllByRole("option").map(({ textContent }) => textContent)).toEqual([
      "source",
      ...sandboxConfigurationFixtureModes,
    ])
    expect(within(screen.getByRole("combobox", { name: "System issue fixture" })).getAllByRole("option").map(({ textContent }) => textContent)).toEqual([
      "source",
      ...systemIssueFixtureModes,
    ])
    expect(within(screen.getByRole("combobox", { name: "Repository push fixture" })).getAllByRole("option").map(({ textContent }) => textContent)).toEqual([
      "source",
      ...repositoryPushFixtureModes,
    ])
    expect(within(screen.getByRole("combobox", { name: "Activity fixture" })).getAllByRole("option").map(({ textContent }) => textContent)).toEqual([
      "source",
      ...activityFixtureModes,
    ])
    app.unmount()

    render(<FixtureSelector surface="onboarding" scenario="running" />)
    expect(screen.queryByRole("combobox", { name: "Sandbox state fixture" })).not.toBeInTheDocument()
    expect(screen.queryByRole("combobox", { name: "Sandbox change fixture" })).not.toBeInTheDocument()
    expect(screen.queryByRole("combobox", { name: "System issue fixture" })).not.toBeInTheDocument()
    expect(screen.queryByRole("combobox", { name: "Repository push fixture" })).not.toBeInTheDocument()
    expect(screen.queryByRole("combobox", { name: "Activity fixture" })).not.toBeInTheDocument()
  })

  it("parses every sandbox configuration fixture independently from runtime state", () => {
    for (const mode of sandboxConfigurationFixtureModes) {
      expect(sandboxConfigurationFixtureModeFromSearch(`?sandbox-change=${mode}`)).toBe(mode)
      expect(applicationSourceForScenario("running", undefined, undefined, mode).sandboxConfigurationOperation).not.toBeNull()
    }
    expect(sandboxConfigurationFixtureModeFromSearch("?sandbox-change=unknown")).toBeUndefined()
  })

  it("parses and applies every system issue state independently", () => {
    for (const mode of systemIssueFixtureModes) {
      expect(systemIssueFixtureModeFromSearch(`?system-issue=${mode}`)).toBe(mode)
      expect(applicationSourceForScenario("running", undefined, undefined, undefined, mode).runtimeRepair).not.toBeNull()
    }
    expect(systemIssueFixtureModeFromSearch("?system-issue=unknown")).toBeUndefined()
    expect(applicationSourceForScenario("running").runtimeRepair).toBeNull()
    expect(applicationSourceForScenario("dependency-failure").runtimeRepair?.status).toBe("needed")
  })

  it("parses and applies every repository push state independently", () => {
    for (const mode of repositoryPushFixtureModes) {
      expect(repositoryPushFixtureModeFromSearch(`?repository-push=${mode}`)).toBe(mode)
      const source = applicationSourceForScenario("running", undefined, undefined, undefined, undefined, mode)
      expect(source.repositoryPushOperations).toEqual([expect.objectContaining({
        workspace: "dev",
        repositoryPath: "acme/silo",
        commitCount: 2,
        status: mode,
      })])
    }
    expect(repositoryPushFixtureModeFromSearch("?repository-push=unknown")).toBeUndefined()
    expect(applicationSourceForScenario("running").repositoryPushOperations).toEqual([])
    expect(applicationSourceForScenario("running", undefined, undefined, undefined, undefined, "succeeded").workspaces[0].repositories[0].ahead).toBe(0)
  })

  it("covers every activity category and presentation state", () => {
    expect(new Set(activityCatalog.map(({ category }) => category))).toEqual(new Set([
      "sandbox",
      "git",
      "backup",
      "secrets",
      "github",
      "system",
    ]))
    expect(new Set(activityCatalog.map(({ tone }) => tone))).toEqual(new Set([
      "neutral",
      "success",
      "danger",
      "warning",
    ]))
    expect(activityCatalog.every(({ status }) => status === "completed")).toBe(true)
  })

  it("parses every activity fixture and keeps one stable live row while it updates", () => {
    for (const mode of activityFixtureModes) {
      expect(activityFixtureModeFromSearch(`?activity=${mode}`)).toBe(mode)
      expect(applicationSourceForScenario("running", undefined, undefined, undefined, undefined, undefined, mode).activities.length).toBeGreaterThan(0)
    }
    expect(activityFixtureModeFromSearch("?activity=unknown")).toBeUndefined()

    for (const mode of activityFixtureModes.filter((candidate) => candidate !== "catalog")) {
      const first = applicationActivitiesForFixture(mode, 0, [])
      const final = applicationActivitiesForFixture(mode, activityFixtureStepCount(mode) - 1, [])
      expect(first[0].id).toBe(final[0].id)
      expect(first[0].status).toBe("running")
      expect(final[0].status).toBe("completed")
    }
  })
})
