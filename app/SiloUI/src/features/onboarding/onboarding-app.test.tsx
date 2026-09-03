import { render, screen, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it, vi } from "vitest"

import { OnboardingApp } from "@/features/onboarding/onboarding-app"
import { projectOnboarding } from "@/features/onboarding/model/onboarding-state"
import { onboardingScenarios } from "@/fixtures/scenarios"

function renderScenario(name: keyof typeof onboardingScenarios = "running") {
  return render(<OnboardingApp source={onboardingScenarios[name]} actions={{
    repairRuntime: vi.fn(),
    retryWorkspaceSetup: vi.fn(),
    finishSetup: vi.fn(),
  }} />)
}

describe("onboarding", () => {
  it("navigates all five steps with tabs, Back, and Continue", async () => {
    const user = userEvent.setup()
    renderScenario()

    expect(screen.getByRole("heading", { name: "Dependencies" })).toBeVisible()
    await user.click(screen.getByRole("button", { name: "Continue" }))
    expect(screen.getByRole("heading", { name: "Creating your workspaces" })).toBeVisible()
    await user.click(screen.getByRole("button", { name: "Continue" }))
    expect(screen.getByRole("heading", { name: "GitHub access" })).toBeVisible()
    await user.click(screen.getByRole("tab", { name: /Git identity/ }))
    expect(screen.getByRole("heading", { name: "Git identity" })).toBeVisible()
    await user.click(screen.getByRole("tab", { name: /Review/ }))
    expect(screen.getByRole("heading", { name: "Review setup" })).toBeVisible()
    await user.click(screen.getByRole("button", { name: "Back" }))
    expect(screen.getByRole("heading", { name: "Git identity" })).toBeVisible()
  })

  it("supports arrow-key navigation across the responsive tab list", async () => {
    const user = userEvent.setup()
    renderScenario()
    const dependencies = screen.getByRole("tab", { name: /Dependencies/ })

    dependencies.focus()
    await user.keyboard("{ArrowRight}")

    expect(screen.getByRole("tab", { name: /Workspaces/ })).toHaveAttribute("aria-selected", "true")
    expect(screen.getByRole("heading", { name: "Creating your workspaces" })).toBeVisible()
  })

  it("keeps background workspace progress visible on later steps and View returns to Workspaces", async () => {
    const user = userEvent.setup()
    renderScenario()

    await user.click(screen.getByRole("tab", { name: /GitHub/ }))
    expect(screen.getByLabelText("Workspace progress")).toHaveTextContent("Creating workspaces · 3 of 12 ready")
    expect(screen.getByRole("tab", { name: /Workspaces/ })).toHaveTextContent("Workspaces")
    await user.click(within(screen.getByLabelText("Workspace progress")).getByRole("button", { name: "View" }))
    expect(screen.getByRole("heading", { name: "Creating your workspaces" })).toBeVisible()
  })

  it("retains GitHub and identity choices while navigating", async () => {
    const user = userEvent.setup()
    renderScenario()

    await user.click(screen.getByRole("tab", { name: /GitHub/ }))
    await user.click(screen.getByRole("radio", { name: /Skip for now/ }))
    expect(screen.getByRole("radio", { name: /Skip for now/ })).toHaveAttribute("aria-checked", "true")

    await user.click(screen.getByRole("tab", { name: /Git identity/ }))
    const name = screen.getByLabelText("Name")
    await user.clear(name)
    await user.type(name, "Morgan Example")
    await user.click(screen.getByRole("tab", { name: /GitHub/ }))
    expect(screen.getByRole("radio", { name: /Skip for now/ })).toHaveAttribute("aria-checked", "true")
    await user.click(screen.getByRole("tab", { name: /Git identity/ }))
    expect(screen.getByLabelText("Name")).toHaveValue("Morgan Example")
  })

  it("expands dependency groups and exposes real remediation", async () => {
    const user = userEvent.setup()
    renderScenario("dependency-failure")

    expect(screen.getByText("silo-ssh-proxy")).toBeVisible()
    expect(screen.getByText("Use Repair… to reinstall the bundled Silo runtime.")).toBeVisible()
    expect(screen.getByRole("button", { name: "Continue" })).toBeDisabled()
    await user.click(screen.getByRole("button", { name: /Silo tools/ }))
    expect(screen.queryByText("silo-ssh-proxy")).not.toBeInTheDocument()
    await user.click(screen.getByRole("button", { name: /Silo tools/ }))
    expect(screen.getByText("silo-ssh-proxy")).toBeVisible()
  })

  it("filters unsafe activity and renders a bounded many-workspace list", async () => {
    const user = userEvent.setup()
    renderScenario()
    await user.click(screen.getByRole("tab", { name: /Workspaces/ }))

    expect(screen.getByLabelText("Workspace activity")).toHaveTextContent("Verifying 'docs-build'.")
    expect(screen.queryByText(/Internal verification path/)).not.toBeInTheDocument()
    const list = screen.getByTestId("workspace-list")
    expect(within(list).getByText("client-alpha-integration")).toBeVisible()
    expect(within(list).getByText("security-review")).toBeVisible()
    expect(screen.getByText("27 of 36 operations complete")).toBeVisible()
    expect(screen.getByText("3 ready · 1 working · 8 waiting")).toBeVisible()
    const copy = vi.spyOn(navigator.clipboard, "writeText")
    await user.click(screen.getByRole("button", { name: "Copy activity" }))
    expect(copy).toHaveBeenCalledWith(expect.stringContaining("Verifying 'docs-build'."))
    expect(copy).not.toHaveBeenCalledWith(expect.stringContaining("Internal verification path"))
    await user.click(screen.getByRole("button", { name: "Collapse activity" }))
    expect(screen.queryByLabelText("Workspace activity")).not.toBeInTheDocument()
  })

  it("reports a clipboard denial without an unhandled interaction failure", async () => {
    const user = userEvent.setup()
    vi.spyOn(navigator.clipboard, "writeText").mockRejectedValueOnce(new DOMException("Denied", "NotAllowedError"))
    renderScenario()
    await user.click(screen.getByRole("tab", { name: /Workspaces/ }))

    await user.click(screen.getByRole("button", { name: "Copy activity" }))

    expect(screen.getByRole("button", { name: "Copy activity" })).toHaveTextContent("Copy failed")
  })

  it("enables Finish only after every queue operation succeeds", async () => {
    const user = userEvent.setup()
    const running = renderScenario()
    await user.click(screen.getByRole("tab", { name: /Review/ }))
    expect(screen.getByRole("button", { name: "Finish" })).toBeDisabled()
    running.unmount()

    renderScenario("complete")
    await user.click(screen.getByRole("tab", { name: /Review/ }))
    expect(screen.getByRole("button", { name: "Finish" })).toBeEnabled()
    expect(screen.getAllByRole("listitem")).toHaveLength(7)
    await user.click(screen.getByRole("button", { name: "Finish" }))
    expect(screen.getByRole("status")).toHaveTextContent("Setup complete")
  })

  it("does not treat CLI workspace completion as completion of later setup work", () => {
    const source = onboardingScenarios.complete
    const workspaceOnly = projectOnboarding({
      ...source,
      bootstrapState: {
        ...source.bootstrapState,
        completedPhases: ["preflight", "toolchain", "hostIntegration", "workspaces"],
      },
    })

    expect(workspaceOnly.queueItems.find(({ id }) => id === "workspaceVerify")?.status).toBe("succeeded")
    expect(workspaceOnly.queueItems.find(({ id }) => id === "githubRun")?.status).toBe("queued")
    expect(workspaceOnly.finishEnabled).toBe(false)
  })

  it("presents the bootstrap failure with its exact recovery", async () => {
    const user = userEvent.setup()
    renderScenario("bootstrap-failure")
    await user.click(screen.getByRole("tab", { name: /Review/ }))
    expect(screen.getByRole("alert")).toHaveTextContent("Candidate networking could not become ready for 'client-alpha-integration'.")
    expect(screen.getByRole("alert")).toHaveTextContent("Repair workspace startup or SSH forwarding for 'client-alpha-integration', then resume Setup.")
    expect(screen.getByRole("button", { name: "Finish" })).toBeDisabled()
  })

  it("does not claim workspace creation started while dependencies are blocked", async () => {
    const user = userEvent.setup()
    renderScenario("dependency-failure")

    await user.click(screen.getByRole("tab", { name: /Workspaces/ }))
    expect(screen.getByRole("heading", { name: "Workspaces are waiting" })).toBeVisible()
    expect(screen.getByText("Complete the dependency checks before workspace creation starts.")).toBeVisible()
  })

  it("routes actionable failures through the narrow action seam", async () => {
    const user = userEvent.setup()
    const repairRuntime = vi.fn()
    const retryWorkspaceSetup = vi.fn()
    const actions = { repairRuntime, retryWorkspaceSetup, finishSetup: vi.fn() }
    const dependency = render(<OnboardingApp source={onboardingScenarios["dependency-failure"]} actions={actions} />)

    await user.click(screen.getByRole("button", { name: "Repair…" }))
    expect(repairRuntime).toHaveBeenCalledOnce()
    dependency.unmount()

    render(<OnboardingApp source={onboardingScenarios["bootstrap-failure"]} actions={actions} />)
    await user.click(screen.getByRole("tab", { name: /Workspaces/ }))
    await user.click(screen.getByRole("button", { name: "Retry" }))
    expect(retryWorkspaceSetup).toHaveBeenCalledOnce()
  })
})
