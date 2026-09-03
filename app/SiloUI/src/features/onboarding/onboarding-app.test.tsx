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

function expectHiddenPanelHeading(name: string) {
  const heading = screen.getByRole("heading", { name, level: 2 })
  expect(heading).toHaveAttribute("data-visual-heading", "hidden")
  expect(heading.parentElement?.tagName).toBe("SECTION")
}

function expectDisclosureIndicator(trigger: HTMLElement) {
  const indicator = trigger.querySelector("svg.lucide-chevron-down")
  expect(indicator).not.toBeNull()
  expect(indicator).toHaveAttribute("aria-hidden", "true")
}

describe("onboarding", () => {
  it("only applies valid explicit GitHub fixture overrides", () => {
    expect(githubStateFromSearch("")).toBeUndefined()
    expect(githubStateFromSearch("?github=unknown")).toBeUndefined()
    expect(githubStateFromSearch("?github=disconnected")).toBe("disconnected")
    expect(githubStateFromSearch("?github=connecting")).toBe("connecting")
    expect(githubStateFromSearch("?github=connected")).toBe("connected")
  })

  it("navigates four steps with GitHub going directly to Review", async () => {
    const user = userEvent.setup()
    renderScenario()

    expectHiddenPanelHeading("Dependencies")
    await user.click(screen.getByRole("button", { name: "Continue" }))
    expectHiddenPanelHeading("Creating your workspaces")
    await user.click(screen.getByRole("button", { name: "Continue" }))
    expectHiddenPanelHeading("GitHub")
    expect(screen.queryByRole("tab", { name: "Git" })).not.toBeInTheDocument()
    await user.click(screen.getByRole("button", { name: "Continue" }))
    expectHiddenPanelHeading("Review setup")
    await user.click(screen.getByRole("tab", { name: /Review/ }))
    expectHiddenPanelHeading("Review setup")
    await user.click(screen.getByRole("button", { name: "Back" }))
    expectHiddenPanelHeading("GitHub")
  })

  it("renders four borderless setup navigation items", () => {
    renderScenario()

    const navigation = screen.getByRole("navigation", { name: "Setup steps" })
    const tabs = within(navigation).getAllByRole("tab")
    expect(tabs).toHaveLength(4)
    for (const tab of tabs) expect(tab).toHaveAttribute("data-appearance", "borderless")
  })

  it("supports arrow-key navigation across the responsive tab list", async () => {
    const user = userEvent.setup()
    renderScenario()
    const dependencies = screen.getByRole("tab", { name: /Dependencies/ })

    dependencies.focus()
    await user.keyboard("{ArrowRight}")

    expect(screen.getByRole("tab", { name: /Workspaces/ })).toHaveAttribute("aria-selected", "true")
    expectHiddenPanelHeading("Creating your workspaces")
  })

  it("shows running workspace feedback only in the sidebar outside Workspaces", async () => {
    const user = userEvent.setup()
    renderScenario()

    for (const step of ["GitHub", "Review"]) {
      await user.click(screen.getByRole("tab", { name: step }))
      expect(screen.queryByLabelText("Workspace progress")).not.toBeInTheDocument()
      expect(screen.queryByText(/Creating workspaces ·/)).not.toBeInTheDocument()
      expect(within(screen.getByRole("tab", { name: /Workspaces/ })).getByLabelText("In progress")).toBeVisible()
    }
  })

  it("places contextual Skip before Back and skips only GitHub repository access", async () => {
    const user = userEvent.setup()
    renderScenario("running", "disconnected")

    await user.click(screen.getByRole("tab", { name: /GitHub/ }))
    const githubFooter = screen.getByLabelText("Onboarding actions")
    expect(within(githubFooter).getAllByRole("button").map(({ textContent }) => textContent)).toEqual(["Skip repository access", "Back", "Continue"])
    expect(within(githubFooter).getByRole("button", { name: "Continue" })).toBeEnabled()
    expect(screen.queryByText("Skip for now")).not.toBeInTheDocument()
    await user.click(within(githubFooter).getByRole("button", { name: "Skip repository access" }))
    expectHiddenPanelHeading("Review setup")
    expect(screen.getByText("Repository access skipped")).toBeVisible()
    expect(screen.getByText("Taylor Example <taylor@example.com> → all 12 workspaces")).toBeVisible()
  })

  it("renders stable disconnected, connecting, and connected GitHub states", async () => {
    const user = userEvent.setup()
    const disconnected = renderScenario("running", "disconnected")
    await user.click(screen.getByRole("tab", { name: /GitHub/ }))

    expect(screen.getByRole("heading", { name: "Not connected" })).toBeVisible()
    expect(screen.getByLabelText("Git name for dev")).toHaveValue("Taylor Example")
    expect(screen.getByLabelText("Git email for dev")).toHaveValue("taylor@example.com")
    expect(screen.queryByLabelText("Add repository to dev")).not.toBeInTheDocument()
    await user.click(screen.getByRole("button", { name: "Connect GitHub" }))
    expect(screen.getByRole("heading", { name: "Connecting to GitHub…" })).toBeVisible()
    expect(screen.getByLabelText("Git name for dev")).toBeEnabled()
    expect(screen.queryByLabelText("Add repository to dev")).not.toBeInTheDocument()
    expect(await screen.findByRole("heading", { name: "Connected to GitHub" }, { timeout: 1500 })).toBeVisible()
    expect(screen.getByLabelText("Add repository to dev")).toBeVisible()
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

    expect(screen.getByRole("region", { name: "Workspace Git identity and repository access" })).toBeVisible()
    expect(screen.queryByRole("heading", { name: "Workspace Git identity and repository access" })).not.toBeInTheDocument()
    expect(screen.queryByText("Selected repositories always allow local writes and commits.")).not.toBeInTheDocument()
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

    const name = screen.getByLabelText("Git name for playgrounds")
    await user.clear(name)
    await user.type(name, "Morgan Example")
    const retained = screen.getByRole("table", { name: "Selected repositories for playgrounds" })
    expect(within(retained).getByText("acme/design-system")).toBeVisible()
    expect(within(retained).getByText("acme/platform-tools")).toBeVisible()
    expect(within(retained).getByRole("checkbox", { name: "Allow pushes for acme/platform-tools" })).toBeChecked()

    await user.click(screen.getByRole("tab", { name: /Review/ }))
    expect(screen.getByText("3 repositories across 2 of 12 workspaces · 1 push-enabled repository")).toBeVisible()
    expect(screen.getByText("Taylor Example <taylor@example.com> → dev, personal, docs-build, client-alpha-integration, qa-macos, qa-linux, release, data-lab, api-benchmarks, customer-demo, security-review; Morgan Example <taylor@example.com> → playgrounds")).toBeVisible()
  })

  it("treats repository names as case-insensitive when preventing duplicates", async () => {
    const user = userEvent.setup()
    render(<OnboardingApp
      source={onboardingScenarios.running}
      initialGitHubConnectionState="connected"
      repositoryOptions={["ACME/SILO", "acme/silo", "acme/design-system"]}
      actions={{ repairRuntime: vi.fn(), retryWorkspaceSetup: vi.fn(), finishSetup: vi.fn() }}
    />)
    await user.click(screen.getByRole("tab", { name: /GitHub/ }))

    const picker = screen.getByLabelText("Add repository to playgrounds")
    await user.click(picker)
    expect(screen.getAllByRole("option").map(({ textContent }) => textContent)).toEqual(["ACME/SILO", "acme/design-system"])

    await user.click(screen.getByRole("option", { name: "ACME/SILO" }))
    await user.click(picker)

    expect(screen.getAllByRole("option").map(({ textContent }) => textContent)).toEqual(["acme/design-system"])
    expect(within(screen.getByRole("table", { name: "Selected repositories for playgrounds" })).getAllByRole("row")).toHaveLength(2)
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
    expect(await screen.findByRole("tooltip")).toHaveTextContent("Checked: the VM can push. Unchecked: it can’t.")
  })

  it("prefills and enables every workspace identity from the optional host identity", async () => {
    const user = userEvent.setup()
    renderScenario("running", "disconnected")
    await user.click(screen.getByRole("tab", { name: /GitHub/ }))

    expect(screen.getAllByRole("checkbox", { name: /^Apply Git identity to / })).toHaveLength(12)
    for (const checkbox of screen.getAllByRole("checkbox", { name: /^Apply Git identity to / })) {
      expect(checkbox).toBeChecked()
    }
    const identityRows = screen.getAllByRole("group", { name: /^Git identity for / })
    expect(identityRows).toHaveLength(12)
    for (const row of identityRows) expect(row).toHaveAttribute("data-layout", "compact-row")
    const devIdentity = screen.getByRole("group", { name: "Git identity for dev" })
    expect(within(devIdentity).getByPlaceholderText("Name")).toHaveAccessibleName("Git name for dev")
    expect(within(devIdentity).getByPlaceholderText("Email")).toHaveAccessibleName("Git email for dev")
    expect(within(devIdentity).getByRole("checkbox")).toHaveAccessibleName("Apply Git identity to dev")
    expect(within(devIdentity).getByRole("button")).toHaveAccessibleName("Reset Git identity for dev")
    const identityTooltipTrigger = within(devIdentity).getByLabelText("About Git identity for dev")
    identityTooltipTrigger.focus()
    expect(identityTooltipTrigger).toHaveFocus()
    expect(await screen.findByRole("tooltip")).toHaveTextContent("Name and email used for Git commits in this VM.")
    expect(screen.queryByText("Git name")).not.toBeInTheDocument()
    expect(screen.queryByText("Git email")).not.toBeInTheDocument()
    expect(screen.getByLabelText("Git name for security-review")).toHaveValue("Taylor Example")
    expect(screen.getByLabelText("Git email for security-review")).toHaveValue("taylor@example.com")
    expect(screen.getByRole("button", { name: "Reset Git identity for security-review" })).toBeEnabled()
  })

  it("keeps workspace identity edits and apply choices independent and resets one workspace", async () => {
    const user = userEvent.setup()
    renderScenario("running", "connected")
    await user.click(screen.getByRole("tab", { name: /GitHub/ }))

    const playgroundsName = screen.getByLabelText("Git name for playgrounds")
    const playgroundsEmail = screen.getByLabelText("Git email for playgrounds")
    await user.clear(playgroundsName)
    await user.type(playgroundsName, "Morgan Example")
    await user.clear(playgroundsEmail)
    await user.type(playgroundsEmail, "morgan@example.com")
    await user.click(screen.getByRole("checkbox", { name: "Apply Git identity to personal" }))

    expect(screen.getByLabelText("Git name for dev")).toHaveValue("Taylor Example")
    expect(screen.getByRole("checkbox", { name: "Apply Git identity to dev" })).toBeChecked()
    expect(screen.getByRole("checkbox", { name: "Apply Git identity to personal" })).not.toBeChecked()

    await user.click(screen.getByRole("button", { name: "Reset Git identity for playgrounds" }))
    expect(playgroundsName).toHaveValue("Taylor Example")
    expect(playgroundsEmail).toHaveValue("taylor@example.com")
    expect(screen.getByRole("checkbox", { name: "Apply Git identity to personal" })).not.toBeChecked()

    await user.clear(playgroundsName)
    await user.type(playgroundsName, "Morgan Example")
    await user.click(screen.getByRole("tab", { name: /Review/ }))
    expect(screen.getByText("Taylor Example <taylor@example.com> → dev, docs-build, client-alpha-integration, qa-macos, qa-linux, release, data-lab, api-benchmarks, customer-demo, security-review; Morgan Example <taylor@example.com> → playgrounds; not applied → personal")).toBeVisible()
  })

  it("starts blank and leaves Reset safely unavailable without a host identity", async () => {
    const user = userEvent.setup()
    render(<OnboardingApp
      source={{ ...onboardingScenarios.running, currentHostGitIdentity: null }}
      initialGitHubConnectionState="disconnected"
      actions={{ repairRuntime: vi.fn(), retryWorkspaceSetup: vi.fn(), finishSetup: vi.fn() }}
    />)
    await user.click(screen.getByRole("tab", { name: /GitHub/ }))

    const name = screen.getByLabelText("Git name for dev")
    const email = screen.getByLabelText("Git email for dev")
    const reset = screen.getByRole("button", { name: "Reset Git identity for dev" })
    expect(name).toHaveValue("")
    expect(email).toHaveValue("")
    expect(reset).toBeDisabled()
    expect(screen.getByText("No host Git identity is available. Enter values manually; Reset is unavailable.")).toBeVisible()
    await user.type(name, "Local User")
    await user.click(reset)
    expect(name).toHaveValue("Local User")
  })

  it("expands dependency groups and exposes real remediation", async () => {
    const user = userEvent.setup()
    renderScenario("dependency-failure")

    expect(screen.getByText("silo-ssh-proxy")).toBeVisible()
    expect(screen.getByText("Use Repair… to reinstall the bundled Silo runtime.")).toBeVisible()
    expect(screen.getByRole("button", { name: "Continue" })).toBeDisabled()
    const disclosure = screen.getByRole("button", { name: /Silo tools/ })
    expectDisclosureIndicator(disclosure)
    await user.click(disclosure)
    expect(screen.queryByText("silo-ssh-proxy")).not.toBeInTheDocument()
    await user.click(disclosure)
    expect(screen.getByText("silo-ssh-proxy")).toBeVisible()
  })

  it("filters unsafe activity and renders a bounded many-workspace list", async () => {
    const user = userEvent.setup()
    renderScenario()
    await user.click(screen.getByRole("tab", { name: /Workspaces/ }))

    expect(screen.getByLabelText("Workspace activity")).toHaveTextContent("Verifying 'docs-build'.")
    const elapsedTime = screen.getByLabelText("Elapsed time")
    expect(elapsedTime.parentElement).toHaveTextContent("docs-build02:18")
    expect(elapsedTime).toHaveTextContent("02:18")
    expect(screen.queryByText(/elapsed/i)).not.toBeInTheDocument()
    expect(screen.queryByText(/Internal verification path/)).not.toBeInTheDocument()
    const list = screen.getByTestId("workspace-list")
    expect(within(list).getByText("client-alpha-integration")).toBeVisible()
    expect(within(list).getByText("security-review")).toBeVisible()
    expect(screen.getByText("27 of 36 operations complete")).toBeVisible()
    expect(screen.getByText("3 ready · 1 working · 8 waiting")).toBeVisible()
    const activityControls = screen.getByRole("group", { name: "Live activity controls" })
    const activityCard = activityControls.parentElement
    const activitySlot = activityCard?.parentElement
    expect(activityCard).toHaveAttribute("data-state", "open")
    expect(activitySlot).toHaveClass("mt-4", "shrink-0")
    expect(activitySlot?.children).toHaveLength(1)
    expect(activitySlot?.firstElementChild).toBe(activityCard)
    const activityContent = activityCard?.children[1]
    const [activityIcon, activityLabel, copyButton, disclosureButton] = [...activityControls.children]
    const activityButtons = within(activityControls).getAllByRole("button")
    expect(activityIcon).toHaveClass("lucide-square-terminal")
    expect(activityLabel).toHaveTextContent("Live activity")
    expect(copyButton).toBe(activityButtons[0])
    expect(disclosureButton).toBe(activityButtons[1])
    expect(activityButtons.map((button) => button.getAttribute("aria-label"))).toEqual(["Copy activity", "Collapse activity"])
    expect(within(activityControls).getAllByRole("button", { expanded: true })).toHaveLength(1)
    expect(activityControls.querySelector("button button")).not.toBeInTheDocument()
    expect(activityButtons[0].textContent).toBe("")
    expect(activityButtons[0].querySelector("svg")).not.toBeNull()
    expect(within(activityControls).queryByText(/^(Copy|Copied|Copy failed)$/)).not.toBeInTheDocument()
    const copy = vi.spyOn(navigator.clipboard, "writeText")
    await user.click(screen.getByRole("button", { name: "Copy activity" }))
    expect(copy).toHaveBeenCalledWith(expect.stringContaining("Verifying 'docs-build'."))
    expect(copy).not.toHaveBeenCalledWith(expect.stringContaining("Internal verification path"))
    expect(screen.getByRole("button", { name: "Activity copied" })).toBeInTheDocument()
    expect(activityButtons[0].textContent).toBe("")
    expect(activityButtons[0].querySelector("svg")).not.toBeNull()
    expect(within(activityControls).queryByText(/^(Copy|Copied|Copy failed)$/)).not.toBeInTheDocument()
    const disclosure = screen.getByRole("button", { name: "Collapse activity" })
    expectDisclosureIndicator(disclosure)
    await user.click(disclosure)
    expect(screen.queryByLabelText("Workspace activity")).not.toBeInTheDocument()
    expect(disclosure).toHaveAttribute("aria-expanded", "false")
    expect(activityCard).toHaveAttribute("data-state", "closed")
    expect(activityContent).toHaveAttribute("data-state", "closed")
    expect(activityContent).toHaveAttribute("hidden")
    expect(activityContent?.children).toHaveLength(0)
    expect(activityCard?.firstElementChild).toBe(activityControls)
    expect(activitySlot?.firstElementChild).toBe(activityCard)
    expect(activitySlot?.style.minHeight).toBe("")
    const expand = screen.getByRole("button", { name: "Expand activity" })
    await user.click(expand)
    expect(expand).toHaveAttribute("aria-expanded", "true")
    expect(screen.getByLabelText("Workspace activity")).toBeVisible()
    expect(activityContent).not.toHaveAttribute("hidden")
    expect(activityContent?.children).toHaveLength(1)
  })

  it("reports a clipboard denial without an unhandled interaction failure", async () => {
    const user = userEvent.setup()
    vi.spyOn(navigator.clipboard, "writeText").mockRejectedValueOnce(new DOMException("Denied", "NotAllowedError"))
    renderScenario()
    await user.click(screen.getByRole("tab", { name: /Workspaces/ }))

    await user.click(screen.getByRole("button", { name: "Copy activity" }))

    const failedCopy = screen.getByRole("button", { name: "Copy activity failed" })
    expect(failedCopy.textContent).toBe("")
    expect(failedCopy.querySelector("svg")).not.toBeNull()
    expect(screen.queryByText("Copy failed")).not.toBeInTheDocument()
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
    expectHiddenPanelHeading("Workspaces are waiting")
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
