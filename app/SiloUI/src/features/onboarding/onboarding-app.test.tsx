import { render, screen, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it, vi } from "vitest"

import { OnboardingApp } from "@/features/onboarding/onboarding-app"
import { projectOnboarding } from "@/features/onboarding/model/onboarding-state"
import type { GitHubConnectionState } from "@/features/onboarding/steps/github-step"
import { githubStateFromSearch, onboardingScenarios, repositoryFixtures } from "@/fixtures/scenarios"

function renderScenario(name: keyof typeof onboardingScenarios = "running", githubState?: GitHubConnectionState) {
  return render(<OnboardingApp source={onboardingScenarios[name]} initialGitHubConnectionState={githubState} repositoryOptions={repositoryFixtures} actions={{
    repairRuntime: vi.fn(),
    retryWorkspaceSetup: vi.fn(),
    finishSetup: vi.fn(),
  }} />)
}

describe("onboarding", () => {
  it("only applies valid explicit GitHub fixture overrides", () => {
    expect(githubStateFromSearch("")).toBeUndefined()
    expect(githubStateFromSearch("?github=unknown")).toBeUndefined()
    expect(githubStateFromSearch("?github=disconnected")).toBe("disconnected")
    expect(githubStateFromSearch("?github=connecting")).toBe("connecting")
    expect(githubStateFromSearch("?github=connected")).toBe("connected")
  })

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

    for (const step of [/GitHub/, /Git identity/, /Review/]) {
      await user.click(screen.getByRole("tab", { name: step }))
      expect(screen.getByLabelText("Workspace progress")).toHaveTextContent("Creating workspaces · 3 of 12 ready")
    }
    expect(screen.getByRole("tab", { name: /Workspaces/ })).toHaveTextContent("Workspaces")
    await user.click(within(screen.getByLabelText("Workspace progress")).getByRole("button", { name: "View" }))
    expect(screen.getByRole("heading", { name: "Creating your workspaces" })).toBeVisible()
  })

  it("places contextual Skip before Back and records both skipped choices", async () => {
    const user = userEvent.setup()
    renderScenario("running", "disconnected")

    await user.click(screen.getByRole("tab", { name: /GitHub/ }))
    const githubFooter = screen.getByLabelText("Onboarding actions")
    expect(within(githubFooter).getAllByRole("button").map(({ textContent }) => textContent)).toEqual(["Skip", "Back", "Continue"])
    expect(within(githubFooter).getByRole("button", { name: "Continue" })).toBeDisabled()
    expect(screen.queryByText("Skip for now")).not.toBeInTheDocument()
    await user.click(within(githubFooter).getByRole("button", { name: "Skip" }))
    expect(screen.getByRole("heading", { name: "Git identity" })).toBeVisible()

    const identityFooter = screen.getByLabelText("Onboarding actions")
    expect(within(identityFooter).getAllByRole("button").map(({ textContent }) => textContent)).toEqual(["Skip", "Back", "Continue"])
    await user.click(within(identityFooter).getByRole("button", { name: "Skip" }))
    expect(screen.getByRole("heading", { name: "Review setup" })).toBeVisible()
    expect(screen.getByText("GitHub access skipped")).toBeVisible()
    expect(screen.getByText("Git identity skipped")).toBeVisible()
  })

  it("renders stable disconnected, connecting, and connected GitHub states", async () => {
    const user = userEvent.setup()
    const disconnected = renderScenario("running", "disconnected")
    await user.click(screen.getByRole("tab", { name: /GitHub/ }))

    expect(screen.getByRole("heading", { name: "Not connected" })).toBeVisible()
    await user.click(screen.getByRole("button", { name: "Connect GitHub" }))
    expect(screen.getByRole("heading", { name: "Connecting to GitHub…" })).toBeVisible()
    expect(await screen.findByRole("heading", { name: "Connected to GitHub" }, { timeout: 1500 })).toBeVisible()
    disconnected.unmount()

    const connecting = renderScenario("running", "connecting")
    await user.click(screen.getByRole("tab", { name: /GitHub/ }))
    expect(screen.getByRole("heading", { name: "Connecting to GitHub…" })).toBeVisible()
    connecting.unmount()

    renderScenario("running", "connected")
    await user.click(screen.getByRole("tab", { name: /GitHub/ }))
    expect(screen.getByRole("heading", { name: "Connected to GitHub" })).toBeVisible()
  })

  it("derives the default GitHub state and repository catalog from the native source", async () => {
    const user = userEvent.setup()
    const devPolicy = onboardingScenarios.running.githubPolicies[0]
    const source = {
      ...onboardingScenarios.running,
      githubPolicies: [{
        ...devPolicy,
        repositories: [
          devPolicy.repositories[0],
          {
            ...devPolicy.repositories[0],
            repositoryID: 1002,
            fullName: "acme/design-system",
            mode: "read-write" as const,
          },
        ],
      }],
    }
    render(<OnboardingApp source={source} actions={{
      repairRuntime: vi.fn(),
      retryWorkspaceSetup: vi.fn(),
      finishSetup: vi.fn(),
    }} />)

    await user.click(screen.getByRole("tab", { name: /GitHub/ }))
    expect(screen.getByRole("heading", { name: "Connected to GitHub" })).toBeVisible()
    const selected = screen.getByRole("table", { name: "Selected repositories for dev" })
    expect(within(selected).getByText("acme/silo")).toBeVisible()
    expect(within(selected).getByText("acme/design-system")).toBeVisible()
    expect(within(selected).getByRole("checkbox", { name: "Allow pushes for acme/silo" })).not.toBeChecked()
    expect(within(selected).getByRole("checkbox", { name: "Allow pushes for acme/design-system" })).toBeChecked()

    await user.click(screen.getByLabelText("Add repository to playgrounds"))
    expect(screen.getAllByRole("option").map(({ textContent }) => textContent)).toEqual(["acme/silo", "acme/design-system"])
  })

  it("searches, adds multiple repositories, prevents duplicates, and retains push choices", async () => {
    const user = userEvent.setup()
    renderScenario("running", "connected")
    await user.click(screen.getByRole("tab", { name: /GitHub/ }))

    expect(screen.getByRole("region", { name: "Workspace repository access" })).toBeVisible()
    expect(screen.getAllByRole("combobox")).toHaveLength(12)
    expect(screen.queryByText(/read only|read-write/i)).not.toBeInTheDocument()

    const picker = screen.getByLabelText("Add repository to playgrounds")
    await user.type(picker, "design")
    expect(screen.getByRole("option", { name: "acme/design-system" })).toBeVisible()
    expect(screen.queryByRole("option", { name: "acme/platform-tools" })).not.toBeInTheDocument()
    await user.click(screen.getByRole("option", { name: "acme/design-system" }))

    await user.click(picker)
    expect(screen.queryByRole("option", { name: "acme/design-system" })).not.toBeInTheDocument()
    await user.type(picker, "platform")
    await user.keyboard("{Enter}")

    const selected = screen.getByRole("table", { name: "Selected repositories for playgrounds" })
    expect(within(selected).getByText("acme/design-system")).toBeVisible()
    expect(within(selected).getByText("acme/platform-tools")).toBeVisible()
    const pushes = within(selected).getByRole("checkbox", { name: "Allow pushes for acme/platform-tools" })
    expect(pushes).not.toBeChecked()
    await user.click(pushes)
    expect(pushes).toBeChecked()

    await user.click(screen.getByRole("tab", { name: /Git identity/ }))
    const name = screen.getByLabelText("Name")
    await user.clear(name)
    await user.type(name, "Morgan Example")
    await user.click(screen.getByRole("tab", { name: /GitHub/ }))
    const retained = screen.getByRole("table", { name: "Selected repositories for playgrounds" })
    expect(within(retained).getByText("acme/design-system")).toBeVisible()
    expect(within(retained).getByText("acme/platform-tools")).toBeVisible()
    expect(within(retained).getByRole("checkbox", { name: "Allow pushes for acme/platform-tools" })).toBeChecked()

    await user.click(screen.getByRole("tab", { name: /Review/ }))
    expect(screen.getByText("3 repositories across 2 of 12 workspaces · 1 push-enabled repository")).toBeVisible()
    expect(screen.getByText("Morgan Example · taylor@example.com · all workspaces")).toBeVisible()
  })

  it("removes repositories and keeps the review summary truthful", async () => {
    const user = userEvent.setup()
    renderScenario("running", "connected")
    await user.click(screen.getByRole("tab", { name: /GitHub/ }))

    await user.click(screen.getByRole("button", { name: "Remove acme/silo from dev" }))
    expect(screen.queryByRole("table", { name: "Selected repositories for dev" })).not.toBeInTheDocument()
    await user.click(screen.getByRole("tab", { name: /Review/ }))

    expect(screen.getByText("0 repositories across 0 of 12 workspaces · 0 push-enabled repositories")).toBeVisible()
  })

  it("exposes the Allow pushes explanation to keyboard users", async () => {
    const user = userEvent.setup()
    renderScenario("running", "connected")
    await user.click(screen.getByRole("tab", { name: /GitHub/ }))

    const tooltipTrigger = screen.getByRole("button", { name: "About Allow pushes" })
    screen.getByRole("checkbox", { name: "Allow pushes for acme/silo" }).focus()
    await user.tab({ shift: true })

    expect(tooltipTrigger).toHaveFocus()
    expect(await screen.findByRole("tooltip")).toHaveTextContent("Enabled allows pushes from the VM. Disabled does not.")
  })

  it("preserves and truthfully summarizes the native identity target", async () => {
    const user = userEvent.setup()
    render(<OnboardingApp
      source={{
        ...onboardingScenarios.running,
        identityInput: { ...onboardingScenarios.running.identityInput, target: "personal" },
      }}
      actions={{ repairRuntime: vi.fn(), retryWorkspaceSetup: vi.fn(), finishSetup: vi.fn() }}
    />)

    await user.click(screen.getByRole("tab", { name: /Git identity/ }))
    const applyToAll = screen.getByRole("checkbox", { name: "Apply identity to all workspaces" })
    expect(applyToAll).not.toBeChecked()
    expect(screen.getByText("Currently limited to personal.")).toBeVisible()
    await user.click(screen.getByRole("tab", { name: /Review/ }))
    expect(screen.getByText("Taylor Example · taylor@example.com · personal only")).toBeVisible()

    await user.click(screen.getByRole("tab", { name: /Git identity/ }))
    await user.click(screen.getByRole("checkbox", { name: "Apply identity to all workspaces" }))
    await user.click(screen.getByRole("tab", { name: /Review/ }))
    expect(screen.getByText("Taylor Example · taylor@example.com · all workspaces")).toBeVisible()

    await user.click(screen.getByRole("tab", { name: /Git identity/ }))
    await user.click(screen.getByRole("checkbox", { name: "Apply identity to all workspaces" }))
    await user.click(screen.getByRole("tab", { name: /Review/ }))
    expect(screen.getByText("Taylor Example · taylor@example.com · personal only")).toBeVisible()
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
    expect(screen.queryByText("Complete the dependency checks before workspace creation starts.")).not.toBeInTheDocument()
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
