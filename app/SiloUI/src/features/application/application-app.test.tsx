import { act, render, screen, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it, vi } from "vitest"

import { ApplicationApp } from "@/features/application/application-app"
import type { ApplicationActions, ApplicationSource } from "@/features/application/model/application-source"
import { applicationSourceForScenario } from "@/fixtures/application-scenarios"
import type { WorkspaceFixtureMode } from "@/fixtures/application-scenarios"

function renderApplication(scenario: Parameters<typeof applicationSourceForScenario>[0] = "running", source?: ApplicationSource) {
  const actions: ApplicationActions = {
    repairRuntime: vi.fn(),
    saveMachineConfiguration: vi.fn(),
    retryMachineConfiguration: vi.fn(),
    startWorkspace: vi.fn(),
    pauseWorkspace: vi.fn(),
    stopWorkspace: vi.fn(),
    restartWorkspace: vi.fn(),
    openTerminal: vi.fn(),
    openEditor: vi.fn(),
  }

  return {
    actions,
    user: userEvent.setup(),
    ...render(<ApplicationApp source={source ?? applicationSourceForScenario(scenario)} actions={actions} />),
  }
}

function appNavigation() {
  return screen.getByRole("navigation", { name: "Silo navigation" })
}

function appPanel(name: string) {
  return screen.getByRole("region", { name })
}

describe("application", () => {
  it("opens on the nested sandbox Overview with compact navigation", () => {
    renderApplication()

    const navigation = appNavigation()
    const primaryItems = [...navigation.querySelectorAll<HTMLElement>("[data-navigation-level='primary']")]
    expect(primaryItems.map(({ textContent }) => textContent)).toEqual(["Sandboxes", "GitHub", "Secrets", "Backup", "Settings"])
    for (const item of primaryItems) expect(item).toHaveClass("flex-none", "md:w-full")

    expect(within(navigation).getByRole("button", { name: "Sandboxes" })).toHaveAttribute("aria-current", "page")
    const sandboxSections = within(navigation).getByRole("group", { name: "Sandbox sections" })
    expect(within(sandboxSections).getAllByRole("button").map(({ textContent }) => textContent)).toEqual(["Overview", "Files", "Logs", "Network", "Activity"])
    expect(within(sandboxSections).getByRole("button", { name: "Overview" })).toHaveAttribute("aria-current", "page")
    expect(sandboxSections).toHaveClass("md:ml-3", "md:w-[calc(100%-0.75rem)]", "md:border-l", "md:pl-2")

    const overview = within(appPanel("Sandboxes"))
    expect(overview.queryByRole("heading", { name: "Overview" })).not.toBeInTheDocument()
    expect(overview.queryByText(/3 sandboxes/)).not.toBeInTheDocument()
    expect(overview.queryByText(/Updated just now/)).not.toBeInTheDocument()
    expect(overview.getByRole("heading", { name: "Sandboxes" })).toBeVisible()
    expect(overview.getByText("3 configured · 3 VM · 0 SSH")).toBeVisible()
    expect(overview.getByRole("button", { name: "Add" })).toBeVisible()
    expect(overview.getByRole("list", { name: "Configured sandboxes" })).toBeVisible()
    expect(screen.queryByRole("group", { name: "Settings sections" })).not.toBeInTheDocument()
  })

  it("lets each caret expand or collapse without navigating", async () => {
    const { user } = renderApplication()
    const navigation = within(appNavigation())
    const sandboxes = navigation.getByRole("button", { name: "Sandboxes" })

    await user.click(navigation.getByRole("button", { name: "Collapse Sandboxes menu" }))
    expect(navigation.queryByRole("group", { name: "Sandbox sections" })).not.toBeInTheDocument()
    expect(sandboxes).toHaveAttribute("aria-current", "page")
    expect(within(appPanel("Sandboxes")).getByRole("list", { name: "Configured sandboxes" })).toBeVisible()
    const sandboxCaret = navigation.getByRole("button", { name: "Expand Sandboxes menu" })
    expect(sandboxCaret).toBeVisible()
    expect(sandboxCaret.querySelector("svg")).toBeVisible()

    const settingsCaret = navigation.getByRole("button", { name: "Expand Settings menu" })
    expect(settingsCaret).toBeVisible()
    expect(settingsCaret.querySelector("svg")).toBeVisible()
    await user.click(settingsCaret)
    expect(navigation.getByRole("group", { name: "Settings sections" })).toBeVisible()
    expect(sandboxes).toHaveAttribute("aria-current", "page")
    expect(navigation.getByRole("button", { name: "Settings" })).not.toHaveAttribute("aria-current")

    await user.click(within(navigation.getByRole("group", { name: "Settings sections" })).getByRole("button", { name: "Notifications" }))
    expect(within(appPanel("Settings")).getByRole("heading", { name: "Notifications", level: 2 })).toBeVisible()

    await user.click(navigation.getByRole("button", { name: "Collapse Settings menu" }))
    expect(navigation.queryByRole("group", { name: "Settings sections" })).not.toBeInTheDocument()
    expect(within(appPanel("Settings")).getByRole("heading", { name: "Notifications", level: 2 })).toBeVisible()
  })

  it("keeps the selected sandbox and section while navigating", async () => {
    const { user } = renderApplication()
    const navigation = within(appNavigation())

    await user.click(within(navigation.getByRole("group", { name: "Sandbox sections" })).getByRole("button", { name: "Files" }))
    await user.click(within(appPanel("Sandboxes")).getByRole("button", { name: /^playgrounds/i }))
    expect(within(appPanel("Sandboxes")).getByText("acme/platform-tools")).toBeVisible()

    await user.click(navigation.getByRole("button", { name: "GitHub" }))
    await user.click(navigation.getByRole("button", { name: "Sandboxes" }))

    const sandboxSections = within(navigation.getByRole("group", { name: "Sandbox sections" }))
    expect(sandboxSections.getByRole("button", { name: "Files" })).toHaveAttribute("aria-current", "page")
    expect(within(appPanel("Sandboxes")).getByText("acme/platform-tools")).toBeVisible()
  })

  it("sorts attention first without letting health order rewrite configuration order", async () => {
    const source = applicationSourceForScenario("running")
    const [dev, playgrounds, personal] = source.workspaces
    source.workspaces = [
      { ...dev, machine: { ...dev.machine, name: "normal" }, state: "running", stateDetail: "Running for 2h 18m", attention: undefined },
      { ...playgrounds, machine: { id: playgrounds.machine.id, kind: "ssh", name: "warning", host: "warning.example.com", user: "silo", port: 22 }, state: "stopped", stateDetail: "Waiting for verification", attention: { level: "warning", message: "Storage is almost full." } },
      { ...personal, machine: { ...personal.machine, name: "error" }, state: "failed", stateDetail: "Start failed 3m ago", attention: { level: "warning", message: "Candidate networking did not become ready." } },
    ]
    const { actions, user } = renderApplication("running", source)

    const overview = within(appPanel("Sandboxes"))
    const list = overview.getByRole("list", { name: "Configured sandboxes" })
    const rows = within(list).getAllByRole("listitem")
    expect(rows.map((row) => row.getAttribute("data-sandbox-name"))).toEqual(["error", "warning", "normal"])
    expect(rows[0].querySelector("[data-sandbox-icon-state='error']")).toBeVisible()
    expect(rows[1].querySelector("[data-sandbox-icon-state='warning']")).toBeVisible()
    expect(rows[2].querySelector("[data-sandbox-icon-state='normal']")).toBeVisible()
    expect(within(rows[0]).getByRole("img", { name: "error status" })).toBeVisible()
    expect(within(rows[1]).getByRole("img", { name: "warning status" })).toBeVisible()
    expect(rows[1]).toHaveTextContent("ssh")
    expect(rows[0]).toHaveTextContent("Failed")
    expect(rows[1]).toHaveTextContent("Stopped")
    expect(rows[2]).toHaveTextContent("Running")
    expect(overview.queryByText("Running for 2h 18m")).not.toBeInTheDocument()
    expect(overview.queryByText("Waiting for verification")).not.toBeInTheDocument()

    expect(within(rows[0]).getByText(/Candidate networking did not become ready/)).toBeVisible()
    expect(within(rows[1]).getByText(/Storage is almost full/)).toBeVisible()
    expect(overview.queryByLabelText("Sandbox attention")).not.toBeInTheDocument()
    expect(overview.queryByText(/needs attention/i)).not.toBeInTheDocument()

    await user.click(within(rows[0]).getByRole("button", { name: "Duplicate error" }))
    expect(within(list).getAllByRole("listitem").map((row) => row.getAttribute("data-sandbox-name"))).toEqual(["error", "error-copy", "warning", "normal"])
    await user.click(overview.getByRole("button", { name: "Cancel" }))

    within(rows[0]).getByRole("button", { name: "Reorder error" }).focus()
    await user.keyboard("{ArrowDown}")
    expect(screen.getByText("error can only be reordered within its status group.")).toBeInTheDocument()
    expect(actions.saveMachineConfiguration).not.toHaveBeenCalled()
  })

  it("uses subtle row tones and readable labels for every fixture state", async () => {
    const cases: Array<{ mode: WorkspaceFixtureMode; state: string; tone: string; labelClass: string; hoverClass: string; stopEnabled: boolean; restartEnabled: boolean }> = [
      { mode: "running", state: "running", tone: "running", labelClass: "text-emerald-700", hoverClass: "hover:bg-emerald-500/[0.07]", stopEnabled: true, restartEnabled: true },
      { mode: "starting", state: "starting", tone: "starting", labelClass: "text-amber-700", hoverClass: "hover:bg-amber-500/[0.07]", stopEnabled: true, restartEnabled: false },
      { mode: "stopped", state: "stopped", tone: "stopped", labelClass: "text-muted-foreground", hoverClass: "hover:bg-muted/35", stopEnabled: false, restartEnabled: false },
      { mode: "warning", state: "stopped", tone: "warning", labelClass: "text-muted-foreground", hoverClass: "hover:bg-amber-500/[0.08]", stopEnabled: false, restartEnabled: false },
      { mode: "error", state: "failed", tone: "error", labelClass: "text-destructive", hoverClass: "hover:bg-destructive/[0.07]", stopEnabled: false, restartEnabled: true },
    ]

    for (const { mode, state, tone, labelClass, hoverClass, stopEnabled, restartEnabled } of cases) {
      const source = applicationSourceForScenario("running", undefined, mode)
      const application = renderApplication("running", source)
      const overview = within(appPanel("Sandboxes"))
      const rows = within(overview.getByRole("list", { name: "Configured sandboxes" })).getAllByRole("listitem")
      for (const row of rows) {
        expect(row.querySelector(`[data-sandbox-row-tone="${tone}"]`)).toHaveClass(hoverClass)
        expect(row.querySelector(`[data-workspace-state="${state}"]`)).toHaveClass(labelClass)
      }
      if (mode === "warning") expect(overview.getAllByText(/Storage is almost full/)).toHaveLength(3)
      if (mode === "error") expect(overview.getAllByText(/Candidate networking did not become ready/)).toHaveLength(3)
      const devRow = rows.find((row) => row.getAttribute("data-sandbox-name") === "dev") as HTMLElement
      const controls = within(devRow).getByLabelText("Controls for dev")
      const stop = within(controls).getByRole("button", { name: "Stop dev" })
      const restart = within(controls).getByRole("button", { name: "Restart dev" })
      if (stopEnabled) expect(stop).toBeEnabled()
      else expect(stop).toBeDisabled()
      if (restartEnabled) expect(restart).toBeEnabled()
      else expect(restart).toBeDisabled()
      application.unmount()
    }
  })

  it.each([
    ["add-configuring", "scratch", "Configuring workspace 'scratch'.", "0 of 3 steps complete"],
    ["add-networking", "scratch", "Starting candidate networking for 'scratch'.", "1 of 3 steps complete"],
    ["add-verifying", "scratch", "Verifying 'scratch'.", "2 of 3 steps complete"],
  ] as const)("shows %s progress inside only the affected sandbox", (fixture, workspace, message, progressLabel) => {
    renderApplication("running", applicationSourceForScenario("running", undefined, undefined, fixture))
    const overview = within(appPanel("Sandboxes"))
    const row = overview.getByText(workspace).closest("li") as HTMLElement

    expect(row).toHaveAttribute("aria-busy", "true")
    expect(within(row).getByRole("status")).toHaveTextContent(message)
    expect(within(row).getByRole("progressbar", { name: progressLabel })).toBeVisible()
    expect(within(row).queryByLabelText(`Controls for ${workspace}`)).not.toBeInTheDocument()
    expect(within(row).queryByLabelText(`Manage ${workspace}`)).not.toBeInTheDocument()
    expect(within(row).queryByRole("button", { name: `Reorder ${workspace}` })).not.toBeInTheDocument()
    expect(overview.getByRole("button", { name: "Add" })).toBeDisabled()
    expect(overview.queryByText(/Creating your sandboxes/)).not.toBeInTheDocument()
  })

  it("keeps removal feedback inside the retained sandbox row", () => {
    renderApplication("running", applicationSourceForScenario("running", undefined, undefined, "remove-pending"))
    const overview = within(appPanel("Sandboxes"))
    const row = overview.getByText("playgrounds").closest("li") as HTMLElement

    expect(row).toHaveAttribute("aria-busy", "true")
    expect(within(row).getByRole("status")).toHaveTextContent("Removing")
    expect(within(row).getByRole("status")).toHaveTextContent("Persistent volumes will be retained")
    expect(within(row).queryByRole("progressbar")).not.toBeInTheDocument()
    expect(within(row).queryByLabelText("Controls for playgrounds")).not.toBeInTheDocument()
    expect(within(row).queryByLabelText("Manage playgrounds")).not.toBeInTheDocument()
  })

  it("puts a retryable configuration failure and recovery inside its sandbox", async () => {
    const { actions, user } = renderApplication("running", applicationSourceForScenario("running", undefined, undefined, "workspace-error"))
    const overview = within(appPanel("Sandboxes"))
    const row = overview.getByText("scratch").closest("li") as HTMLElement

    expect(row).not.toHaveAttribute("aria-busy")
    expect(within(row).getByRole("alert")).toHaveTextContent("Networking failed")
    expect(within(row).getByRole("alert")).toHaveTextContent("Repair workspace startup or SSH forwarding, then retry.")
    expect(within(row).queryByLabelText("Manage scratch")).not.toBeInTheDocument()
    await user.click(within(row).getByRole("button", { name: "Retry scratch configuration" }))
    expect(actions.retryMachineConfiguration).toHaveBeenCalledWith("scratch")
    expect(overview.queryByText(/needs attention/i)).not.toBeInTheDocument()
  })

  it("starts a new sandbox as an in-card configuration operation", async () => {
    const { user, actions } = renderApplication()
    const overview = within(appPanel("Sandboxes"))
    const list = overview.getByRole("list", { name: "Configured sandboxes" })
    const devRow = within(list).getByText("dev").closest("li")
    expect(devRow).not.toBeNull()

    const management = within(devRow as HTMLElement).getByLabelText("Manage dev")
    expect(management).toHaveClass("sandbox-hover-actions")
    expect(within(management).getByRole("button", { name: "Edit dev" })).toBeVisible()
    expect(within(management).getByRole("button", { name: "Duplicate dev" })).toBeVisible()
    expect(within(management).getByRole("button", { name: "Delete dev" })).toBeVisible()
    await user.hover(devRow as HTMLElement)

    await user.click(overview.getByRole("button", { name: "Add" }))
    await user.click(screen.getByRole("menuitem", { name: "New sandbox" }))
    const name = overview.getByRole("textbox", { name: "Machine name" })
    expect(name).toHaveValue("workspace-4")
    expect(name).toHaveFocus()
    await user.clear(name)
    await user.type(name, "scratch")
    await user.click(overview.getByRole("button", { name: "Save" }))

    expect(overview.getByText("3 configured · Applying sandbox changes")).toBeVisible()
    const scratchRow = within(overview.getByRole("list", { name: "Configured sandboxes" })).getByText("scratch").closest("li") as HTMLElement
    expect(scratchRow).toHaveAttribute("aria-busy", "true")
    expect(within(scratchRow).getByRole("status")).toHaveTextContent("Preparing sandbox configuration.")
    expect(within(scratchRow).queryByText("Stopped")).not.toBeInTheDocument()
    expect(actions.saveMachineConfiguration).toHaveBeenCalledWith(expect.objectContaining({
      machines: expect.arrayContaining([expect.objectContaining({ name: "scratch", kind: "vm" })]),
    }))
  })

  it("keeps committed detail pages stable while an edit is being applied", async () => {
    const { user, actions } = renderApplication()
    const navigation = within(appNavigation())
    const overview = within(appPanel("Sandboxes"))

    await user.click(overview.getByRole("button", { name: "Edit dev" }))
    const name = overview.getByRole("textbox", { name: "Machine name" })
    await user.clear(name)
    await user.type(name, "development")
    await user.click(overview.getByRole("button", { name: "Save" }))

    const developmentRow = overview.getByText("development").closest("li") as HTMLElement
    expect(developmentRow).toHaveAttribute("aria-busy", "true")
    expect(within(developmentRow).getByRole("status")).toHaveTextContent("Preparing sandbox configuration.")
    expect(overview.getByRole("button", { name: "Add" })).toBeDisabled()

    const sandboxSections = within(navigation.getByRole("group", { name: "Sandbox sections" }))
    await user.click(sandboxSections.getByRole("button", { name: "Files" }))
    expect(within(appPanel("Sandboxes")).getByRole("heading", { name: "dev", level: 3 })).toBeVisible()

    await user.click(navigation.getByRole("button", { name: "Settings" }))
    const settings = within(appPanel("Settings"))
    await user.click(settings.getByRole("switch", { name: "Start sandboxes at launch" }))
    expect(settings.getByRole("checkbox", { name: "dev" })).toBeChecked()
    expect(actions.saveMachineConfiguration).toHaveBeenLastCalledWith(expect.objectContaining({
      machines: expect.arrayContaining([expect.objectContaining({ name: "development" })]),
    }))
  })

  it("keeps a removed sandbox as a progress tombstone until the native snapshot changes", async () => {
    const { actions, user } = renderApplication()
    const overview = within(appPanel("Sandboxes"))

    await user.click(overview.getByRole("button", { name: "Delete playgrounds" }))
    await user.click(overview.getByRole("button", { name: "Confirm deletion of playgrounds" }))

    const row = overview.getByText("playgrounds").closest("li") as HTMLElement
    expect(row).toHaveAttribute("aria-busy", "true")
    expect(within(row).getByRole("status")).toHaveTextContent("Removing")
    expect(within(row).getByRole("status")).toHaveTextContent("Persistent volumes will be retained")
    expect(actions.saveMachineConfiguration).toHaveBeenLastCalledWith(expect.objectContaining({
      machines: expect.not.arrayContaining([expect.objectContaining({ name: "playgrounds" })]),
    }))
  })

  it("routes compact lifecycle actions with the exact sandbox", async () => {
    const running = renderApplication()
    const overview = within(appPanel("Sandboxes"))
    const list = overview.getByRole("list", { name: "Configured sandboxes" })
    const devRow = within(list).getByText("dev").closest("li") as HTMLElement
    const devControls = within(devRow).getByLabelText("Controls for dev")
    const playgroundsRow = within(list).getByText("playgrounds").closest("li") as HTMLElement
    const playgroundsControls = within(playgroundsRow).getByLabelText("Controls for playgrounds")

    expect(overview.queryByText("Silo is ready")).not.toBeInTheDocument()
    expect(overview.queryByText(/items? need attention/)).not.toBeInTheDocument()
    await running.user.click(within(devControls).getByRole("button", { name: "Pause dev" }))
    expect(running.actions.pauseWorkspace).toHaveBeenCalledWith("dev")
    await running.user.click(within(devControls).getByRole("button", { name: "Stop dev" }))
    expect(running.actions.stopWorkspace).toHaveBeenCalledWith("dev")
    await running.user.click(within(devControls).getByRole("button", { name: "Restart dev" }))
    expect(running.actions.restartWorkspace).toHaveBeenCalledWith("dev")
    const startPlaygrounds = within(playgroundsControls).getByRole("button", { name: "Start playgrounds" })
    const stopPlaygrounds = within(playgroundsControls).getByRole("button", { name: "Stop playgrounds" })
    const restartPlaygrounds = within(playgroundsControls).getByRole("button", { name: "Restart playgrounds" })
    expect(startPlaygrounds).toBeEnabled()
    expect(stopPlaygrounds).toBeDisabled()
    expect(restartPlaygrounds).toBeDisabled()
    await running.user.click(startPlaygrounds)
    await running.user.click(stopPlaygrounds)
    await running.user.click(restartPlaygrounds)
    expect(running.actions.startWorkspace).toHaveBeenCalledWith("playgrounds")
    expect(running.actions.stopWorkspace).not.toHaveBeenCalledWith("playgrounds")
    expect(running.actions.restartWorkspace).not.toHaveBeenCalledWith("playgrounds")
    running.unmount()
  })

  it("routes a global runtime failure to a dedicated item above Settings", async () => {
    const failed = renderApplication("dependency-failure")
    const navigationElement = appNavigation()
    const navigation = within(navigationElement)
    const primaryItems = [...navigationElement.querySelectorAll<HTMLElement>("[data-navigation-level='primary']")]

    expect(primaryItems.map(({ textContent }) => textContent)).toEqual([
      "Sandboxes",
      "GitHub",
      "Secrets",
      "Backup",
      "System issue",
      "Settings",
    ])
    expect(primaryItems.at(-2)).toHaveAttribute("data-navigation-tone", "danger")
    expect(within(appPanel("Sandboxes")).queryByText("Silo installation needs repair")).not.toBeInTheDocument()

    await failed.user.click(navigation.getByRole("button", { name: "System issue" }))

    expect(navigation.getByRole("button", { name: "System issue" })).toHaveAttribute("aria-current", "page")
    const systemIssue = within(appPanel("System issue"))
    expect(systemIssue.getByRole("heading", { name: "System issue", level: 2 })).toBeVisible()
    expect(systemIssue.getByRole("heading", { name: "Silo installation needs repair", level: 3 })).toBeVisible()
    expect(systemIssue.getByText("Silo could not verify the bundled runtime used to manage sandboxes.")).toBeVisible()
    expect(systemIssue.queryByText(/Repair reinstalls Silo/)).not.toBeInTheDocument()
    expect(systemIssue.getByText("Sandbox data, host integration, and GitHub access are not changed.")).toBeVisible()

    await failed.user.click(systemIssue.getByRole("button", { name: "Repair Installation" }))
    expect(failed.actions.repairRuntime).toHaveBeenCalledOnce()
  })

  it("removes a resolved system issue and returns to Sandboxes", async () => {
    const source = applicationSourceForScenario("dependency-failure")
    const application = renderApplication("dependency-failure", source)
    const navigation = within(appNavigation())

    await application.user.click(navigation.getByRole("button", { name: "System issue" }))
    expect(appPanel("System issue")).toBeVisible()

    application.rerender(
      <ApplicationApp
        source={{ ...source, runtimeRepair: null }}
        actions={application.actions}
      />,
    )

    expect(navigation.queryByRole("button", { name: "System issue" })).not.toBeInTheDocument()
    expect(within(appPanel("Sandboxes")).getByRole("list", { name: "Configured sandboxes" })).toBeVisible()
  })

  it.each([
    ["installing", "Bundled Silo tools", "Step 1 of 3", "Installing bundled Silo tools…"],
    ["configuring", "Default configuration", "Step 2 of 3", "Checking default configuration…"],
    ["verifying", "Installation verification", "Step 3 of 3", "Verifying the installation…"],
  ] as const)("shows concise %s repair progress", async (mode, phase, step, omittedCaption) => {
    const source = applicationSourceForScenario("running", undefined, undefined, undefined, mode)
    const application = renderApplication("running", source)
    const navigation = within(appNavigation())

    await application.user.click(navigation.getByRole("button", { name: "System issue" }))
    expect(navigation.getByRole("button", { name: "System issue" })).toHaveAttribute("data-navigation-tone", "warning")
    const page = within(appPanel("System issue"))
    expect(page.getByRole("heading", { name: "Repairing installation", level: 3 })).toBeVisible()
    expect(page.queryByText(omittedCaption)).not.toBeInTheDocument()
    expect(page.getByText(step)).toBeVisible()
    const progress = page.getByRole("list", { name: "Repair progress" })
    expect(within(progress).getAllByRole("listitem")).toHaveLength(3)
    expect(within(progress).getByText(phase).closest("li")).toHaveAttribute("data-step-state", "active")
    expect(page.getByRole("button", { name: "Repair in progress" })).toBeDisabled()
  })

  it("shows retry and optional technical details after repair fails", async () => {
    const source = applicationSourceForScenario("running", undefined, undefined, undefined, "failed")
    const application = renderApplication("running", source)
    const navigation = within(appNavigation())

    await application.user.click(navigation.getByRole("button", { name: "System issue" }))
    const page = within(appPanel("System issue"))
    expect(page.getByRole("heading", { name: "Repair couldn’t finish", level: 3 })).toBeVisible()
    expect(page.getByText("The activated runtime did not pass verification.")).toBeVisible()
    expect(page.getByText("Retry the repair. If it fails again, open a GitHub issue and paste the technical details below.")).toBeVisible()
    expect(page.getByRole("link", { name: "Open GitHub Issues" })).toHaveAttribute("href", "https://github.com/0xpolarzero/silo/issues")
    expect(page.getByRole("link", { name: "Open GitHub Issues" })).toHaveAttribute("target", "_blank")
    expect(page.queryByText(/version handshake/)).not.toBeInTheDocument()

    await application.user.click(page.getByRole("button", { name: "Show technical details" }))
    expect(page.getByText(/version handshake/)).toBeVisible()
    const copy = vi.spyOn(navigator.clipboard, "writeText")
    await application.user.click(page.getByRole("button", { name: "Copy technical details" }))
    expect(copy).toHaveBeenCalledWith(expect.stringContaining("version handshake"))
    expect(page.getByRole("button", { name: "Technical details copied" })).toBeVisible()
    await application.user.click(page.getByRole("button", { name: "Retry Repair" }))
    expect(application.actions.repairRuntime).toHaveBeenCalledOnce()
  })

  it("removes a repaired issue, returns to Sandbox Overview, and confirms success there", async () => {
    const source = applicationSourceForScenario("running", undefined, undefined, undefined, "verifying")
    const application = renderApplication("running", source)
    const navigation = within(appNavigation())

    await application.user.click(within(navigation.getByRole("group", { name: "Sandbox sections" })).getByRole("button", { name: "Files" }))
    await application.user.click(navigation.getByRole("button", { name: "System issue" }))
    expect(appPanel("System issue")).toBeVisible()

    application.rerender(
      <ApplicationApp
        source={applicationSourceForScenario("running", undefined, undefined, undefined, "succeeded")}
        actions={application.actions}
      />,
    )

    expect(navigation.queryByRole("button", { name: "System issue" })).not.toBeInTheDocument()
    expect(screen.queryByRole("region", { name: "System issue" })).not.toBeInTheDocument()
    const sandboxes = within(appPanel("Sandboxes"))
    expect(within(navigation.getByRole("group", { name: "Sandbox sections" })).getByRole("button", { name: "Overview" })).toHaveAttribute("aria-current", "page")
    expect(sandboxes.getByRole("status")).toHaveTextContent("Installation repaired")
    expect(sandboxes.getByRole("list", { name: "Configured sandboxes" })).toBeVisible()
  })

  it("removes the repair confirmation after four seconds", () => {
    vi.useFakeTimers()
    const application = renderApplication("running", applicationSourceForScenario("running", undefined, undefined, undefined, "succeeded"))

    try {
      expect(within(appPanel("Sandboxes")).getByRole("status")).toHaveTextContent("Installation repaired")
      act(() => vi.advanceTimersByTime(4_000))
      expect(within(appPanel("Sandboxes")).queryByRole("status")).not.toBeInTheDocument()
    } finally {
      application.unmount()
      vi.useRealTimers()
    }
  })

  it("gives reinstall guidance when the bundled runtime is unavailable", async () => {
    const source = applicationSourceForScenario("running", undefined, undefined, undefined, "runtime-missing")
    const application = renderApplication("running", source)

    await application.user.click(within(appNavigation()).getByRole("button", { name: "System issue" }))
    const page = within(appPanel("System issue"))
    expect(page.getByRole("heading", { name: "Silo runtime is unavailable", level: 3 })).toBeVisible()
    expect(page.getByText("This app build is missing its bundled Silo runtime.")).toBeVisible()
    expect(page.getByText("Reinstall Silo from a complete app bundle.")).toBeVisible()
    expect(page.queryByRole("button", { name: /repair/i })).not.toBeInTheDocument()
  })

  it("renders the native app domains in the polished Silo shell", async () => {
    const { user } = renderApplication()
    const navigation = within(appNavigation())

    await user.click(navigation.getByRole("button", { name: "GitHub" }))
    const github = within(appPanel("GitHub"))
    expect(github.getByText("Connected as @taylor")).toBeVisible()
    await user.click(github.getByRole("button", { name: "Edit access" }))
    expect(github.getAllByRole("checkbox")).toHaveLength(4)
    await user.click(github.getByRole("button", { name: "Save changes" }))

    await user.click(navigation.getByRole("button", { name: "Secrets" }))
    const secrets = within(appPanel("Secrets"))
    expect(secrets.getByText("DATABASE_URL")).toBeVisible()
    expect(secrets.getByRole("alert")).toHaveTextContent("1 secret change requires a restart")

    await user.click(navigation.getByRole("button", { name: "Backup" }))
    expect(within(appPanel("Backup")).getByText("silo-2026-09-02.silo-backup")).toBeVisible()
  })

  it("preserves notification and general preferences across app sections", async () => {
    const { user } = renderApplication()
    const navigation = within(appNavigation())

    await user.click(navigation.getByRole("button", { name: "Expand Settings menu" }))
    const settingsNavigation = within(navigation.getByRole("group", { name: "Settings sections" }))
    await user.click(settingsNavigation.getByRole("button", { name: "Notifications" }))
    const settings = within(appPanel("Settings"))
    await user.click(settings.getByRole("switch", { name: "Enable notifications" }))
    expect(settings.getByRole("switch", { name: "Sandbox health" })).toBeDisabled()

    await user.click(settingsNavigation.getByRole("button", { name: "General" }))
    await user.click(settings.getByRole("switch", { name: "Start sandboxes at launch" }))
    const playgrounds = settings.getByRole("checkbox", { name: "playgrounds" })
    await user.click(playgrounds)
    expect(playgrounds).toBeChecked()

    await user.click(navigation.getByRole("button", { name: "GitHub" }))
    await user.click(navigation.getByRole("button", { name: "Settings" }))
    expect(settings.getByRole("checkbox", { name: "playgrounds" })).toBeChecked()

    await user.click(settingsNavigation.getByRole("button", { name: "Notifications" }))
    expect(settings.getByRole("switch", { name: "Enable notifications" })).not.toBeChecked()
  })
})
