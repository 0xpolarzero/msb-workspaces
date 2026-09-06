import { render, screen, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it, vi } from "vitest"

import { OnboardingApp } from "./onboarding-app"
import { onboardingScenarios } from "@/fixtures/scenarios"

function setup(complete = false) {
  const finishSetup = vi.fn()
  const onOpenApp = vi.fn()
  render(<OnboardingApp source={onboardingScenarios[complete ? "complete" : "running"]} onOpenApp={onOpenApp} actions={{
    saveMachineConfiguration: vi.fn(), repairRuntime: vi.fn(), retryWorkspaceSetup: vi.fn(), finishSetup,
  }} />)
  return { user: userEvent.setup(), finishSetup, onOpenApp }
}

describe("onboarding continuity", () => {
  it("retains an unsaved sandbox draft and only exposes the active panel", async () => {
    const { user } = setup()
    await user.click(screen.getByRole("tab", { name: /Sandboxes/ }))
    await user.click(screen.getByRole("button", { name: "Add" }))
    await user.click(screen.getByRole("menuitem", { name: "New sandbox" }))
    await user.clear(screen.getByRole("textbox", { name: "Machine name" }))
    await user.type(screen.getByRole("textbox", { name: "Machine name" }), "unfinished")
    await user.click(screen.getByRole("tab", { name: /GitHub/ }))
    expect(screen.queryByRole("textbox", { name: "Machine name" })).not.toBeInTheDocument()
    expect(screen.getAllByRole("tabpanel")).toHaveLength(1)
    await user.click(screen.getByRole("tab", { name: /Sandboxes/ }))
    expect(screen.getByRole("textbox", { name: "Machine name" })).toHaveValue("unfinished")
  })

  it("retains expanded dependency details when returning to the step", async () => {
    const { user } = setup()
    await user.click(screen.getByRole("button", { name: /Silo tools/ }))
    expect(screen.getByRole("button", { name: /Silo tools/ })).toHaveAttribute("aria-expanded", "true")
    await user.click(screen.getByRole("tab", { name: /GitHub/ }))
    await user.click(screen.getByRole("tab", { name: /Dependencies/ }))
    expect(screen.getByRole("button", { name: /Silo tools/ })).toHaveAttribute("aria-expanded", "true")
  })

  it("replaces the finished queue with a single handoff and submits setup once", async () => {
    const { user, finishSetup, onOpenApp } = setup(true)
    await user.click(screen.getByRole("tab", { name: /Review/ }))
    await user.click(screen.getByRole("button", { name: "Finish" }))
    expect(finishSetup).toHaveBeenCalledOnce()
    expect(screen.getByRole("status")).toHaveTextContent("Setup complete")
    expect(screen.queryByRole("list", { name: "Setup operations" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Finish" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Back" })).not.toBeInTheDocument()
    for (const tab of within(screen.getByRole("navigation", { name: "Setup steps" })).getAllByRole("tab")) expect(tab).toBeDisabled()
    await user.click(screen.getByRole("button", { name: "Open Silo" }))
    expect(onOpenApp).toHaveBeenCalledOnce()
    expect(finishSetup).toHaveBeenCalledOnce()
  })
})
