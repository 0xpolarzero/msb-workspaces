import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it, vi } from "vitest"

import { OnboardingApp } from "@/features/onboarding/onboarding-app"
import type { GitHubConnectionState } from "@/features/onboarding/model/onboarding-source"
import { projectOnboarding } from "@/features/onboarding/model/onboarding-state"
import { githubStateFromSearch, onboardingScenarios, repositoryFixtures } from "@/fixtures/scenarios"

function renderScenario(name: keyof typeof onboardingScenarios = "running", githubState?: GitHubConnectionState) {
  return render(<OnboardingApp source={onboardingScenarios[name]} initialGitHubConnectionState={githubState} repositoryOptions={repositoryFixtures} actions={{
    saveMachineConfiguration: vi.fn(),
    repairRuntime: vi.fn(),
    retryWorkspaceSetup: vi.fn(),
    finishSetup: vi.fn(),
  }} />)
}

async function renderMachineScenario() {
  const saveMachineConfiguration = vi.fn()
  const user = userEvent.setup()
  render(<OnboardingApp
    source={onboardingScenarios.running}
    repositoryOptions={repositoryFixtures}
    actions={{
      saveMachineConfiguration,
      repairRuntime: vi.fn(),
      retryWorkspaceSetup: vi.fn(),
      finishSetup: vi.fn(),
    }}
  />)
  await user.click(screen.getByRole("tab", { name: /Workspaces/ }))
  return { user, saveMachineConfiguration }
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
      await user.click(screen.getByRole("tab", { name: new RegExp(step) }))
      expect(screen.queryByLabelText("Workspace progress")).not.toBeInTheDocument()
      expect(screen.queryByText(/Creating workspaces ·/)).not.toBeInTheDocument()
      expect(within(screen.getByRole("tab", { name: /Workspaces/ })).getByLabelText("In progress")).toBeVisible()
    }
  })

  it("continues from disconnected GitHub without marking it complete", async () => {
    const user = userEvent.setup()
    renderScenario("running", "disconnected")

    await user.click(screen.getByRole("tab", { name: /GitHub/ }))
    const githubFooter = screen.getByLabelText("Onboarding actions")
    const githubTab = screen.getByRole("tab", { name: /GitHub/ })
    expect(within(githubFooter).getAllByRole("button").map(({ textContent }) => textContent)).toEqual(["Back", "Continue"])
    expect(within(githubFooter).getByRole("button", { name: "Continue" })).toBeEnabled()
    expect(within(githubFooter).queryByRole("button", { name: /skip/i })).not.toBeInTheDocument()
    expect(within(githubTab).queryByLabelText("Complete")).not.toBeInTheDocument()
    expect(within(githubTab).queryByLabelText("In progress")).not.toBeInTheDocument()

    await user.click(within(githubFooter).getByRole("button", { name: "Continue" }))
    expectHiddenPanelHeading("Review setup")
    expect(screen.getByText("GitHub not connected")).toBeVisible()
    expect(screen.getByText("Taylor Example <taylor@example.com> → all 3 workspaces")).toBeVisible()
  })

  it("continues while GitHub is connecting and marks it in progress", async () => {
    const user = userEvent.setup()
    renderScenario("running", "connecting")

    await user.click(screen.getByRole("tab", { name: /GitHub/ }))
    const githubTab = screen.getByRole("tab", { name: /GitHub/ })
    expect(within(githubTab).getByLabelText("In progress")).toBeVisible()
    expect(within(githubTab).queryByLabelText("Complete")).not.toBeInTheDocument()
    const continueButton = screen.getByRole("button", { name: "Continue" })
    expect(continueButton).toBeEnabled()

    await user.click(continueButton)
    expectHiddenPanelHeading("Review setup")
  })

  it("continues with zero repository access and keeps connected GitHub complete", async () => {
    const user = userEvent.setup()
    renderScenario("running", "connected")

    await user.click(screen.getByRole("tab", { name: /GitHub/ }))
    const githubTab = screen.getByRole("tab", { name: /GitHub/ })
    expect(within(githubTab).getByLabelText("Complete")).toBeVisible()
    expect(within(githubTab).queryByLabelText("In progress")).not.toBeInTheDocument()

    await user.click(screen.getByRole("button", { name: "Remove acme/silo from dev" }))
    expect(within(githubTab).getByLabelText("Complete")).toBeVisible()
    const continueButton = screen.getByRole("button", { name: "Continue" })
    expect(continueButton).toBeEnabled()
    await user.click(continueButton)

    expectHiddenPanelHeading("Review setup")
    expect(screen.getByText("0 repositories across 0 of 3 workspaces · 0 push-enabled repositories")).toBeVisible()
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
      saveMachineConfiguration: vi.fn(),
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
    expect(screen.getAllByRole("combobox")).toHaveLength(3)
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
    expect(screen.getByText("3 repositories across 2 of 3 workspaces · 1 push-enabled repository")).toBeVisible()
    expect(screen.getByText("Taylor Example <taylor@example.com> → dev, personal; Morgan Example <taylor@example.com> → playgrounds")).toBeVisible()
  })

  it("treats repository names as case-insensitive when preventing duplicates", async () => {
    const user = userEvent.setup()
    render(<OnboardingApp
      source={onboardingScenarios.running}
      initialGitHubConnectionState="connected"
      repositoryOptions={["ACME/SILO", "acme/silo", "acme/design-system"]}
      actions={{ saveMachineConfiguration: vi.fn(), repairRuntime: vi.fn(), retryWorkspaceSetup: vi.fn(), finishSetup: vi.fn() }}
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

    expect(screen.getByText("0 repositories across 0 of 3 workspaces · 0 push-enabled repositories")).toBeVisible()
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

    expect(screen.getAllByRole("checkbox", { name: /^Apply Git identity to / })).toHaveLength(3)
    for (const checkbox of screen.getAllByRole("checkbox", { name: /^Apply Git identity to / })) {
      expect(checkbox).toBeChecked()
    }
    const identityRows = screen.getAllByRole("group", { name: /^Git identity for / })
    expect(identityRows).toHaveLength(3)
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
    expect(screen.getByLabelText("Git name for personal")).toHaveValue("Taylor Example")
    expect(screen.getByLabelText("Git email for personal")).toHaveValue("taylor@example.com")
    expect(screen.getByRole("button", { name: "Reset Git identity for personal" })).toBeEnabled()
  })

  it("uses one custom tooltip for each Git identity Reset control", async () => {
    const user = userEvent.setup()
    renderScenario("running", "disconnected")
    await user.click(screen.getByRole("tab", { name: /GitHub/ }))

    for (const workspace of ["dev", "playgrounds", "personal"]) {
      const name = `Reset Git identity for ${workspace}`
      const reset = screen.getByRole("button", { name })
      const trigger = reset.parentElement
      expect(trigger).not.toBeNull()
      expect(reset).toHaveAccessibleName(name)
      expect(reset).not.toHaveAttribute("title")
      expect(trigger).not.toHaveAttribute("title")

      fireEvent.focus(reset)
      expect(await screen.findByRole("tooltip")).toHaveTextContent(name)
      expect(screen.getAllByRole("tooltip")).toHaveLength(1)
      fireEvent.blur(reset)
      await user.keyboard("{Escape}")
      await waitFor(() => expect(screen.queryByRole("tooltip")).not.toBeInTheDocument())

      await user.hover(reset)
      expect(await screen.findByRole("tooltip")).toHaveTextContent(name)
      expect(screen.getAllByRole("tooltip")).toHaveLength(1)
      await user.unhover(reset)
      await user.keyboard("{Escape}")
      await waitFor(() => expect(screen.queryByRole("tooltip")).not.toBeInTheDocument())
    }
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
    expect(screen.getByText("Taylor Example <taylor@example.com> → dev; Morgan Example <taylor@example.com> → playgrounds; not applied → personal")).toBeVisible()
  })

  it("starts blank and leaves Reset safely unavailable without a host identity", async () => {
    const user = userEvent.setup()
    render(<OnboardingApp
      source={{ ...onboardingScenarios.running, currentHostGitIdentity: null }}
      initialGitHubConnectionState="disconnected"
      actions={{ saveMachineConfiguration: vi.fn(), repairRuntime: vi.fn(), retryWorkspaceSetup: vi.fn(), finishSetup: vi.fn() }}
    />)
    await user.click(screen.getByRole("tab", { name: /GitHub/ }))

    const name = screen.getByLabelText("Git name for dev")
    const email = screen.getByLabelText("Git email for dev")
    const reset = screen.getByRole("button", { name: "Reset Git identity for dev" })
    expect(name).toHaveValue("")
    expect(email).toHaveValue("")
    expect(reset).toBeDisabled()
    expect(reset).toHaveAccessibleName("Reset Git identity for dev")
    expect(reset).not.toHaveAttribute("title")
    expect(screen.getByText("No host Git identity is available. Enter values manually; Reset is unavailable.")).toBeVisible()

    const resetTooltipTrigger = reset.parentElement
    expect(resetTooltipTrigger).not.toBeNull()
    expect(resetTooltipTrigger).toHaveAccessibleName("Reset Git identity for dev")
    expect(resetTooltipTrigger).not.toHaveAttribute("title")
    fireEvent.focus(resetTooltipTrigger!)
    expect(await screen.findByRole("tooltip")).toHaveTextContent("Reset Git identity for dev")
    expect(screen.getAllByRole("tooltip")).toHaveLength(1)
    fireEvent.blur(resetTooltipTrigger!)
    await user.keyboard("{Escape}")
    await waitFor(() => expect(screen.queryByRole("tooltip")).not.toBeInTheDocument())

    await user.hover(resetTooltipTrigger!)
    expect(await screen.findByRole("tooltip")).toHaveTextContent("Reset Git identity for dev")
    expect(screen.getAllByRole("tooltip")).toHaveLength(1)
    await user.unhover(resetTooltipTrigger!)
    await user.keyboard("{Escape}")
    await waitFor(() => expect(screen.queryByRole("tooltip")).not.toBeInTheDocument())

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
    const list = screen.getByTestId("machine-list")
    expect(within(list).getByText("dev")).toBeVisible()
    expect(within(list).getByText("personal")).toBeVisible()
    expect(within(list).queryByText("client-alpha-integration")).not.toBeInTheDocument()
    expect(screen.getByText("27 of 36 operations complete")).toBeVisible()
    expect(screen.getByText("3 configured · 3 VM · 0 SSH")).toBeVisible()
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

    const finishSetup = vi.fn()
    render(<OnboardingApp source={onboardingScenarios.complete} actions={{
      saveMachineConfiguration: vi.fn(),
      repairRuntime: vi.fn(),
      retryWorkspaceSetup: vi.fn(),
      finishSetup,
    }} />)
    await user.click(screen.getByRole("tab", { name: /Review/ }))
    expect(screen.getByRole("button", { name: "Finish" })).toBeEnabled()
    expect(within(screen.getByRole("list", { name: "Setup operations" })).getAllByRole("listitem")).toHaveLength(7)
    await user.click(screen.getByRole("button", { name: "Finish" }))
    expect(finishSetup).toHaveBeenCalledWith({
      machineConfiguration: {
        schemaVersion: 1,
        machines: onboardingScenarios.complete.machineConfigurations,
      },
      github: {
        connectionState: "connected",
        workspaces: [
          {
            workspace: "dev",
            repositories: [{ repository: "acme/silo", allowPushes: false }],
            identity: { name: "Taylor Example", email: "taylor@example.com", apply: true },
          },
          {
            workspace: "playgrounds",
            repositories: [],
            identity: { name: "Taylor Example", email: "taylor@example.com", apply: true },
          },
          {
            workspace: "personal",
            repositories: [],
            identity: { name: "Taylor Example", email: "taylor@example.com", apply: true },
          },
        ],
      },
    })
    expect(screen.getByRole("status")).toHaveTextContent("Setup complete")
  })

  it("finishes connected setup with explicit zero repository access and no skip state", async () => {
    const user = userEvent.setup()
    const finishSetup = vi.fn()
    render(<OnboardingApp
      source={onboardingScenarios.complete}
      initialGitHubConnectionState="connected"
      repositoryOptions={repositoryFixtures}
      actions={{
        saveMachineConfiguration: vi.fn(),
        repairRuntime: vi.fn(),
        retryWorkspaceSetup: vi.fn(),
        finishSetup,
      }}
    />)

    await user.click(screen.getByRole("tab", { name: /GitHub/ }))
    await user.click(screen.getByRole("button", { name: "Remove acme/silo from dev" }))
    await user.click(screen.getByRole("button", { name: "Continue" }))
    expect(screen.getByText("0 repositories across 0 of 3 workspaces · 0 push-enabled repositories")).toBeVisible()
    await user.click(screen.getByRole("button", { name: "Finish" }))

    expect(finishSetup).toHaveBeenCalledOnce()
    const request = finishSetup.mock.lastCall?.[0]
    expect(request.github.connectionState).toBe("connected")
    expect(request.github.workspaces.map(({ workspace, repositories }: { workspace: string; repositories: unknown[] }) => ({ workspace, repositories }))).toEqual([
      { workspace: "dev", repositories: [] },
      { workspace: "playgrounds", repositories: [] },
      { workspace: "personal", repositories: [] },
    ])
    expect(request.github).not.toHaveProperty("skipped")
    expect(request).not.toHaveProperty("repositoryAccessSkipped")
  })

  it("does not treat CLI workspace completion as completion of later setup work", () => {
    const source = onboardingScenarios.complete
    const workspaceOnly = projectOnboarding({
      ...source,
      bootstrapState: {
        ...source.bootstrapState,
        completedPhases: ["preflight", "toolchain", "hostIntegration", "workspaces"],
      },
    }, "connected")

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
    const actions = { saveMachineConfiguration: vi.fn(), repairRuntime, retryWorkspaceSetup, finishSetup: vi.fn() }
    const dependency = render(<OnboardingApp source={onboardingScenarios["dependency-failure"]} actions={actions} />)

    await user.click(screen.getByRole("button", { name: "Repair…" }))
    expect(repairRuntime).toHaveBeenCalledOnce()
    dependency.unmount()

    render(<OnboardingApp source={onboardingScenarios["bootstrap-failure"]} actions={actions} />)
    await user.click(screen.getByRole("tab", { name: /Workspaces/ }))
    await user.click(screen.getByRole("button", { name: "Retry" }))
    expect(retryWorkspaceSetup).toHaveBeenCalledOnce()
  })

  it("starts from the exact three production machine defaults instead of the activity stress fixture", async () => {
    await renderMachineScenario()
    const list = screen.getByRole("list", { name: "Configured machines" })
    const rows = within(list).getAllByRole("listitem")

    expect(rows).toHaveLength(3)
    expect(rows.map((row) => within(row).getByText(/^(dev|playgrounds|personal)$/).textContent)).toEqual(["dev", "playgrounds", "personal"])
    expect(rows[0]).toHaveTextContent("8 CPU · 32 GB RAM · 120 GB workspace")
    expect(rows[1]).toHaveTextContent("4 CPU · 32 GB RAM · 60 GB workspace")
    expect(rows[2]).toHaveTextContent("6 CPU · 16 GB RAM · 100 GB workspace")
    expect(within(list).queryByText("docs-build")).not.toBeInTheDocument()
  })

  it("adds, cancels, and saves a virtual machine through the typed configuration action", async () => {
    const { user, saveMachineConfiguration } = await renderMachineScenario()

    await user.click(screen.getByRole("button", { name: "Add" }))
    await user.click(screen.getByRole("menuitem", { name: "New virtual machine" }))
    const draftName = screen.getByRole("textbox", { name: "Machine name" })
    expect(draftName).toHaveValue("workspace-4")
    expect(draftName).toHaveFocus()
    expect(screen.getByRole("combobox", { name: "CPU limit" })).toHaveValue("8")
    await user.click(screen.getByRole("button", { name: "Cancel" }))
    expect(screen.queryByDisplayValue("workspace-4")).not.toBeInTheDocument()
    expect(saveMachineConfiguration).not.toHaveBeenCalled()

    await user.click(screen.getByRole("button", { name: "Add" }))
    await user.click(screen.getByRole("menuitem", { name: "New virtual machine" }))
    await user.clear(screen.getByRole("textbox", { name: "Machine name" }))
    await user.type(screen.getByRole("textbox", { name: "Machine name" }), "build")
    await user.selectOptions(screen.getByRole("combobox", { name: "CPU limit" }), "4")
    await user.click(screen.getByRole("button", { name: "Save" }))

    expect(saveMachineConfiguration).toHaveBeenCalledOnce()
    expect(saveMachineConfiguration.mock.lastCall?.[0]).toMatchObject({
      schemaVersion: 1,
      machines: [
        { kind: "vm", name: "dev" },
        { kind: "vm", name: "playgrounds" },
        { kind: "vm", name: "personal" },
        { kind: "vm", name: "build", cpus: 4, maxCPUs: 12, memoryGiB: 32, maxMemoryGiB: 48, workspaceStorageGiB: 120, runtimeStorageGiB: 100 },
      ],
    })
    expect(screen.getByRole("list", { name: "Configured machines" })).toHaveTextContent("build")
  })

  it("adds, validates, cancels, and saves an SSH machine without claiming a connection", async () => {
    const { user, saveMachineConfiguration } = await renderMachineScenario()

    await user.click(screen.getByRole("button", { name: "Add" }))
    await user.click(screen.getByRole("menuitem", { name: "Add via SSH" }))
    expect(screen.getByRole("textbox", { name: "Machine name" })).toHaveValue("remote-1")
    expect(screen.getByRole("spinbutton", { name: "SSH port" })).toHaveValue(22)
    await user.click(screen.getByRole("button", { name: "Save" }))
    expect(screen.getByText("Enter an SSH host.")).toBeVisible()
    expect(screen.getByText("Enter an SSH user.")).toBeVisible()
    expect(saveMachineConfiguration).not.toHaveBeenCalled()
    await user.click(screen.getByRole("button", { name: "Cancel" }))
    expect(screen.queryByDisplayValue("remote-1")).not.toBeInTheDocument()

    await user.click(screen.getByRole("button", { name: "Add" }))
    await user.click(screen.getByRole("menuitem", { name: "Add via SSH" }))
    await user.clear(screen.getByRole("textbox", { name: "Machine name" }))
    await user.type(screen.getByRole("textbox", { name: "Machine name" }), "staging")
    await user.type(screen.getByRole("textbox", { name: "SSH host" }), "staging.example.com")
    await user.type(screen.getByRole("textbox", { name: "SSH user" }), "deploy")
    await user.clear(screen.getByRole("spinbutton", { name: "SSH port" }))
    await user.type(screen.getByRole("spinbutton", { name: "SSH port" }), "2222")
    await user.click(screen.getByRole("button", { name: "Save" }))

    expect(saveMachineConfiguration.mock.lastCall?.[0].machines.at(-1)).toMatchObject({
      kind: "ssh",
      name: "staging",
      host: "staging.example.com",
      user: "deploy",
      port: 2222,
    })
    expect(screen.getByText("deploy@staging.example.com:2222")).toBeVisible()
    expect(screen.queryByText(/connected/i)).not.toBeInTheDocument()
  })

  it("restores an existing VM exactly on Cancel and persists a valid edit on Save", async () => {
    const { user, saveMachineConfiguration } = await renderMachineScenario()

    await user.click(screen.getByRole("button", { name: "Edit dev" }))
    const name = screen.getByRole("textbox", { name: "Machine name" })
    expect(name).toHaveFocus()
    await user.clear(name)
    await user.type(name, "changed")
    await user.selectOptions(screen.getByRole("combobox", { name: "Memory limit" }), "16")
    await user.click(screen.getByRole("button", { name: "Cancel" }))
    expect(saveMachineConfiguration).not.toHaveBeenCalled()
    expect(screen.getByRole("button", { name: "Edit dev" })).toBeVisible()

    await user.click(screen.getByRole("button", { name: "Edit dev" }))
    await user.clear(screen.getByRole("textbox", { name: "Machine name" }))
    await user.type(screen.getByRole("textbox", { name: "Machine name" }), "development")
    await user.selectOptions(screen.getByRole("combobox", { name: "Memory limit" }), "16")
    await user.click(screen.getByRole("button", { name: "Save" }))
    expect(saveMachineConfiguration.mock.lastCall?.[0].machines[0]).toMatchObject({ name: "development", memoryGiB: 16 })
    expect(screen.getByRole("button", { name: "Edit development" })).toBeVisible()
  })

  it("keeps machine actions on one custom tooltip and the drag handle tooltip-free", async () => {
    const { user } = await renderMachineScenario()
    const dragHandle = screen.getByRole("button", { name: "Reorder dev" })
    expect(dragHandle).toHaveAccessibleName("Reorder dev")
    expect(dragHandle).not.toHaveAttribute("title")
    fireEvent.focus(dragHandle)
    await user.keyboard("{ArrowDown}")
    fireEvent.blur(dragHandle)
    await waitFor(() => expect(screen.queryByRole("tooltip")).not.toBeInTheDocument())

    const tooltipCases = [
      ["Edit dev", "Edit dev"],
      ["Duplicate dev", "Duplicate dev"],
      ["Delete dev", "Delete dev"],
    ] as const

    for (const [name, explanation] of tooltipCases) {
      const trigger = screen.getByRole("button", { name })
      expect(trigger).toHaveAccessibleName(name)
      expect(trigger).not.toHaveAttribute("title")
      fireEvent.focus(trigger)
      expect(await screen.findByRole("tooltip")).toHaveTextContent(explanation)
      expect(screen.getAllByRole("tooltip")).toHaveLength(1)
      fireEvent.blur(trigger)
      await user.keyboard("{Escape}")
      await waitFor(() => expect(screen.queryByRole("tooltip")).not.toBeInTheDocument())

      await user.hover(trigger)
      expect(await screen.findByRole("tooltip")).toHaveTextContent(explanation)
      expect(screen.getAllByRole("tooltip")).toHaveLength(1)
      await user.unhover(trigger)
      await user.keyboard("{Escape}")
      await waitFor(() => expect(screen.queryByRole("tooltip")).not.toBeInTheDocument())
    }

    await user.click(screen.getByRole("button", { name: "Delete dev" }))
    await waitFor(() => expect(screen.queryByRole("tooltip")).not.toBeInTheDocument())
    const confirm = screen.getByRole("button", { name: "Confirm deletion of dev" })
    expect(confirm).not.toHaveAttribute("title")
    expect(confirm).toHaveAccessibleName("Confirm deletion of dev")
    fireEvent.focus(confirm)
    expect(await screen.findByRole("tooltip")).toHaveTextContent("Confirm deletion of dev")
    expect(screen.getAllByRole("tooltip")).toHaveLength(1)
  })

  it("preserves GitHub policy and identity settings when a stable machine is renamed", async () => {
    const user = userEvent.setup()
    renderScenario("running", "connected")
    await user.click(screen.getByRole("tab", { name: /GitHub/ }))
    await user.clear(screen.getByLabelText("Git name for dev"))
    await user.type(screen.getByLabelText("Git name for dev"), "Renamed Author")
    expect(within(screen.getByRole("table", { name: "Selected repositories for dev" })).getByText("acme/silo")).toBeVisible()

    await user.click(screen.getByRole("tab", { name: /Workspaces/ }))
    await user.click(screen.getByRole("button", { name: "Edit dev" }))
    await user.clear(screen.getByRole("textbox", { name: "Machine name" }))
    await user.type(screen.getByRole("textbox", { name: "Machine name" }), "development")
    await user.click(screen.getByRole("button", { name: "Save" }))

    await user.click(screen.getByRole("tab", { name: /GitHub/ }))
    expect(screen.getByLabelText("Git name for development")).toHaveValue("Renamed Author")
    expect(within(screen.getByRole("table", { name: "Selected repositories for development" })).getByText("acme/silo")).toBeVisible()
  })

  it("duplicates after the source, cancels drafts, and generates collision-free copy names", async () => {
    const { user, saveMachineConfiguration } = await renderMachineScenario()

    await user.click(screen.getByRole("button", { name: "Duplicate dev" }))
    expect(screen.getByRole("textbox", { name: "Machine name" })).toHaveValue("dev-copy")
    await user.click(screen.getByRole("button", { name: "Cancel" }))
    expect(saveMachineConfiguration).not.toHaveBeenCalled()

    await user.click(screen.getByRole("button", { name: "Duplicate dev" }))
    await user.click(screen.getByRole("button", { name: "Save" }))
    expect(saveMachineConfiguration.mock.lastCall?.[0].machines.map(({ name }: { name: string }) => name)).toEqual(["dev", "dev-copy", "playgrounds", "personal"])

    await user.click(screen.getByRole("button", { name: "Duplicate dev" }))
    expect(screen.getByRole("textbox", { name: "Machine name" })).toHaveValue("dev-copy-2")
    await user.click(screen.getByRole("button", { name: "Save" }))
    expect(saveMachineConfiguration.mock.lastCall?.[0].machines.map(({ name }: { name: string }) => name)).toEqual(["dev", "dev-copy-2", "dev-copy", "playgrounds", "personal"])
  })

  it("places a replacement duplicate after its source when another draft is open", async () => {
    const { user, saveMachineConfiguration } = await renderMachineScenario()

    await user.click(screen.getByRole("button", { name: "Duplicate dev" }))
    await user.click(screen.getByRole("button", { name: "Duplicate playgrounds" }))
    expect(screen.getByRole("textbox", { name: "Machine name" })).toHaveValue("playgrounds-copy")
    await user.click(screen.getByRole("button", { name: "Save" }))

    expect(saveMachineConfiguration.mock.lastCall?.[0].machines.map(({ name }: { name: string }) => name)).toEqual([
      "dev", "playgrounds", "playgrounds-copy", "personal",
    ])
  })

  it("arms inline deletion, cancels with Escape or outside input, and deletes only after confirmation", async () => {
    const { user, saveMachineConfiguration } = await renderMachineScenario()

    await user.click(screen.getByRole("button", { name: "Delete dev" }))
    expect(screen.getByRole("button", { name: "Confirm deletion of dev" })).toBeVisible()
    expect(saveMachineConfiguration).not.toHaveBeenCalled()
    await user.keyboard("{Escape}")
    expect(screen.queryByRole("button", { name: "Confirm deletion of dev" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Delete dev" })).toBeVisible()

    await user.click(screen.getByRole("button", { name: "Delete dev" }))
    fireEvent.pointerDown(screen.getByRole("heading", { name: "Creating your workspaces" }))
    expect(screen.queryByRole("button", { name: "Confirm deletion of dev" })).not.toBeInTheDocument()
    expect(saveMachineConfiguration).not.toHaveBeenCalled()

    await user.click(screen.getByRole("button", { name: "Delete dev" }))
    await user.click(screen.getByRole("button", { name: "Confirm deletion of dev" }))
    expect(saveMachineConfiguration.mock.lastCall?.[0].machines.map(({ name }: { name: string }) => name)).toEqual(["playgrounds", "personal"])
    expect(screen.queryByRole("button", { name: "Edit dev" })).not.toBeInTheDocument()
  })

  it("persists pointer drag reorder and the quiet keyboard reorder path", async () => {
    const { user, saveMachineConfiguration } = await renderMachineScenario()
    const data = new Map<string, string>()
    const dataTransfer = {
      effectAllowed: "none",
      setData: (type: string, value: string) => data.set(type, value),
      getData: (type: string) => data.get(type) ?? "",
    }
    const target = screen.getByRole("button", { name: "Edit personal" }).closest("li")
    expect(target).not.toBeNull()

    fireEvent.dragStart(screen.getByRole("button", { name: "Reorder dev" }), { dataTransfer })
    fireEvent.dragOver(target!, { dataTransfer })
    fireEvent.drop(target!, { dataTransfer })
    expect(saveMachineConfiguration.mock.lastCall?.[0].machines.map(({ name }: { name: string }) => name)).toEqual(["playgrounds", "personal", "dev"])

    const devHandle = screen.getByRole("button", { name: "Reorder dev" })
    devHandle.focus()
    await user.keyboard("{ArrowUp}")
    expect(saveMachineConfiguration.mock.lastCall?.[0].machines.map(({ name }: { name: string }) => name)).toEqual(["playgrounds", "dev", "personal"])
    expect(screen.getByText("dev moved to position 2 of 3.")).toBeInTheDocument()
  })

  it("blocks duplicate names and invalid VM resource ranges", async () => {
    const { user, saveMachineConfiguration } = await renderMachineScenario()
    await user.click(screen.getByRole("button", { name: "Edit dev" }))
    await user.clear(screen.getByRole("textbox", { name: "Machine name" }))
    await user.type(screen.getByRole("textbox", { name: "Machine name" }), "personal")
    await user.selectOptions(screen.getByRole("combobox", { name: "CPU limit" }), "12")
    await user.selectOptions(screen.getByRole("combobox", { name: "CPU ceiling" }), "4")
    await user.click(screen.getByRole("button", { name: "Save" }))

    expect(screen.getByText("Machine names must be unique.")).toBeVisible()
    expect(screen.getByText("CPU limit cannot exceed its ceiling.")).toBeVisible()
    expect(saveMachineConfiguration).not.toHaveBeenCalled()
  })

  it("reports the machine capacity in the draft instead of throwing across the action boundary", async () => {
    const source = {
      ...onboardingScenarios.running,
      machineConfigurations: Array.from({ length: 64 }, (_, index) => ({
        ...onboardingScenarios.running.machineConfigurations[0],
        id: `00000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`,
        name: `machine-${index + 1}`,
      })),
    }
    const saveMachineConfiguration = vi.fn()
    const user = userEvent.setup()
    render(<OnboardingApp source={source} actions={{
      saveMachineConfiguration,
      repairRuntime: vi.fn(),
      retryWorkspaceSetup: vi.fn(),
      finishSetup: vi.fn(),
    }} />)
    await user.click(screen.getByRole("tab", { name: /Workspaces/ }))
    await user.click(screen.getByRole("button", { name: "Add" }))
    await user.click(screen.getByRole("menuitem", { name: "New virtual machine" }))
    await user.click(screen.getByRole("button", { name: "Save" }))

    expect(screen.getByRole("alert")).toHaveTextContent("Configure no more than 64 machines.")
    expect(saveMachineConfiguration).not.toHaveBeenCalled()
  })

  it("mirrors final machine order and kind in Review while preserving activity collapse", async () => {
    const { user } = await renderMachineScenario()
    await user.click(screen.getByRole("button", { name: "Add" }))
    await user.click(screen.getByRole("menuitem", { name: "Add via SSH" }))
    await user.clear(screen.getByRole("textbox", { name: "Machine name" }))
    await user.type(screen.getByRole("textbox", { name: "Machine name" }), "remote")
    await user.type(screen.getByRole("textbox", { name: "SSH host" }), "remote.example.com")
    await user.type(screen.getByRole("textbox", { name: "SSH user" }), "ops")
    await user.click(screen.getByRole("button", { name: "Save" }))
    await user.click(screen.getByRole("button", { name: "Reorder remote" }))
    await user.keyboard("{ArrowUp}{ArrowUp}{ArrowUp}")

    const activity = screen.getByRole("button", { name: "Collapse activity" })
    await user.click(activity)
    expect(screen.queryByLabelText("Workspace activity")).not.toBeInTheDocument()
    expect(screen.getByTestId("machine-list")).toBeVisible()

    await user.click(screen.getByRole("tab", { name: /Review/ }))
    const review = screen.getByRole("list", { name: "Machines in setup order" })
    expect(within(review).getAllByRole("listitem").map((row) => row.textContent)).toEqual([
      expect.stringContaining("remotesshops@remote.example.com:22"),
      expect.stringContaining("devvm8 CPU · 32 GB RAM"),
      expect.stringContaining("playgroundsvm4 CPU · 32 GB RAM"),
      expect.stringContaining("personalvm6 CPU · 16 GB RAM"),
    ])
  })
})
