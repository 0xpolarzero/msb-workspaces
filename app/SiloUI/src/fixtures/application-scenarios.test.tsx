import { render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import {
  applicationSourceForScenario,
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
    const app = render(<FixtureSelector surface="app" scenario="running" workspaceMode="starting" />)
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
    app.unmount()

    render(<FixtureSelector surface="onboarding" scenario="running" />)
    expect(screen.queryByRole("combobox", { name: "Sandbox state fixture" })).not.toBeInTheDocument()
  })
})
