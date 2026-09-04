import { render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import {
  applicationSourceForScenario,
  sandboxConfigurationFixtureModeFromSearch,
  sandboxConfigurationFixtureModes,
  systemIssueFixtureModeFromSearch,
  systemIssueFixtureModes,
  workspaceFixtureModeFromSearch,
  workspaceFixtureModes,
} from "@/fixtures/application-scenarios"
import { FixtureSelector } from "@/fixtures/fixture-selector"

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
    const app = render(<FixtureSelector surface="app" scenario="running" workspaceMode="starting" sandboxConfigurationMode="add-verifying" systemIssueMode="verifying" />)
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
    app.unmount()

    render(<FixtureSelector surface="onboarding" scenario="running" />)
    expect(screen.queryByRole("combobox", { name: "Sandbox state fixture" })).not.toBeInTheDocument()
    expect(screen.queryByRole("combobox", { name: "Sandbox change fixture" })).not.toBeInTheDocument()
    expect(screen.queryByRole("combobox", { name: "System issue fixture" })).not.toBeInTheDocument()
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
})
