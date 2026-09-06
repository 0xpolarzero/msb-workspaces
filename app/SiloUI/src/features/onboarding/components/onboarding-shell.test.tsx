import { act, cleanup, fireEvent, render, screen, within } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { OnboardingShell } from "./onboarding-shell"
import { projectOnboarding, type OnboardingViewModel } from "@/features/onboarding/model/onboarding-state"
import { onboardingScenarios } from "@/fixtures/scenarios"

function renderShell({ completed = false, onOpenApp, viewModel = projectOnboarding(onboardingScenarios.complete, "connected") }: {
  completed?: boolean
  onOpenApp?: () => void
  viewModel?: OnboardingViewModel
} = {}) {
  const onStepChange = vi.fn()
  render(<OnboardingShell
    activeStep="review"
    viewModel={viewModel}
    onStepChange={onStepChange}
    onBack={vi.fn()}
    onContinue={vi.fn()}
    completed={completed}
    onOpenApp={onOpenApp}
  ><button>Step content</button></OnboardingShell>)
  return { onStepChange, sidebar: screen.getByRole("navigation", { name: "Setup steps" }), footer: screen.getByRole("contentinfo", { name: "Onboarding actions" }) }
}

function wait(milliseconds: number) {
  act(() => vi.advanceTimersByTime(milliseconds))
}

describe("onboarding shell", () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => {
    cleanup()
    vi.useRealTimers()
  })

  it("previews its collapsed steps over the content and pins them on click", () => {
    const { sidebar } = renderShell()
    const stepIcon = screen.getByRole("tab", { name: "Dependencies" }).querySelector("svg")
    fireEvent.click(screen.getByRole("button", { name: "Collapse sidebar" }))
    const toggle = screen.getByRole("button", { name: "Expand sidebar" })
    expect(sidebar).toHaveAttribute("data-collapsed", "true")
    expect(screen.getByRole("tab", { name: "Dependencies" }).querySelector("svg")).toBe(stepIcon)
    fireEvent.pointerEnter(toggle)
    wait(200)
    expect(sidebar).toHaveAttribute("data-previewing", "true")
    expect(sidebar.parentElement).toHaveAttribute("data-sidebar-layout", "collapsed")
    fireEvent.click(toggle)
    fireEvent.pointerLeave(toggle)
    wait(200)
    expect(sidebar).toHaveAttribute("data-previewing", "false")
    expect(sidebar.parentElement).toHaveAttribute("data-sidebar-layout", "expanded")
    expect(screen.queryByRole("textbox", { name: "Search or jump to" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Go back" })).not.toBeInTheDocument()
  })

  it("describes step status separately from stable navigation labels", () => {
    const viewModel = projectOnboarding(onboardingScenarios.running, "connecting")
    renderShell({ viewModel })
    expect(screen.getByRole("tab", { name: "Dependencies" })).toHaveAccessibleDescription("Complete")
    expect(screen.getByRole("tab", { name: "GitHub" })).toHaveAccessibleDescription("In progress")
    expect(screen.getByRole("tab", { name: "GitHub" })).toHaveAttribute("aria-busy", "true")
    fireEvent.click(screen.getByRole("button", { name: "Collapse sidebar" }))
    expect(screen.getByRole("tab", { name: "GitHub" })).toHaveAccessibleName("GitHub")
  })

  it("shows collapsed step tooltips without leaving one behind after hover preview", () => {
    const { sidebar } = renderShell()
    fireEvent.click(screen.getByRole("button", { name: "Collapse sidebar" }))
    const item = screen.getByRole("tab", { name: "GitHub" })
    fireEvent.pointerMove(item)
    wait(350)
    expect(screen.getByRole("tooltip")).toHaveTextContent("GitHub · Complete")
    fireEvent.pointerLeave(item)
    fireEvent.pointerMove(screen.getByRole("button", { name: "Step content" }), { clientX: 500, clientY: 500 })
    const toggle = screen.getByRole("button", { name: "Expand sidebar" })
    fireEvent.pointerEnter(toggle)
    wait(200)
    fireEvent.pointerLeave(toggle)
    fireEvent.pointerEnter(sidebar)
    fireEvent.pointerMove(item)
    wait(350)
    expect(screen.queryByRole("tooltip")).not.toBeInTheDocument()
    fireEvent.pointerLeave(item)
    fireEvent.pointerLeave(sidebar)
    fireEvent.pointerMove(screen.getByRole("button", { name: "Step content" }), { clientX: 500, clientY: 500 })
    wait(200)
    expect(screen.queryByRole("tooltip")).not.toBeInTheDocument()
  })

  it("does not announce completion when only sandbox operations are complete", () => {
    const viewModel = projectOnboarding(onboardingScenarios.complete, "connected")
    viewModel.queueItems = viewModel.queueItems.map((item) => item.id === "githubVerify" ? { ...item, status: "queued" } : item)
    viewModel.finishEnabled = false
    const { footer } = renderShell({ viewModel })
    expect(footer).toHaveTextContent("Waiting")
    expect(footer).not.toHaveTextContent("Complete")
    expect(within(footer).getByRole("button", { name: "Finish" })).toBeDisabled()
  })

  it("reports a non-sandbox failure in the footer", () => {
    const viewModel = projectOnboarding(onboardingScenarios.complete, "connected")
    viewModel.queueItems = viewModel.queueItems.map((item) => item.id === "githubVerify" ? { ...item, status: "failed", failure: "Reconnect GitHub to continue" } : item)
    viewModel.finishEnabled = false
    const { footer } = renderShell({ viewModel })
    expect(footer).toHaveTextContent("Failed · Reconnect GitHub to continue")
    expect(footer).not.toHaveTextContent("Complete")
  })

  it("replaces setup actions with the handoff and locks completed steps", () => {
    const onOpenApp = vi.fn()
    const { footer, onStepChange } = renderShell({ completed: true, onOpenApp })
    expect(within(footer).getAllByRole("button")).toHaveLength(1)
    expect(within(footer).queryByRole("button", { name: "Finish" })).not.toBeInTheDocument()
    for (const tab of screen.getAllByRole("tab")) expect(tab).toBeDisabled()
    fireEvent.click(screen.getByRole("tab", { name: "Dependencies" }))
    expect(onStepChange).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole("button", { name: "Open Silo" }))
    expect(onOpenApp).toHaveBeenCalledOnce()
    expect(screen.getByRole("button", { name: "Collapse sidebar" })).toBeEnabled()
  })

  it("disables handoff when no application callback is supplied", () => {
    renderShell({ completed: true })
    expect(screen.getByRole("button", { name: "Open Silo" })).toBeDisabled()
  })
})
