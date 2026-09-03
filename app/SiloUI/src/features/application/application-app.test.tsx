import { render, screen, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it, vi } from "vitest"

import { ApplicationApp } from "@/features/application/application-app"
import type { ApplicationActions, ApplicationSource } from "@/features/application/model/application-source"
import { applicationSourceForScenario } from "@/fixtures/application-scenarios"

function renderApplication(scenario: Parameters<typeof applicationSourceForScenario>[0] = "running", source?: ApplicationSource) {
  const actions: ApplicationActions = {
    repairRuntime: vi.fn(),
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
    expect(overview.getByRole("list", { name: "Sandboxes" })).toBeVisible()
    expect(screen.queryByRole("group", { name: "Settings sections" })).not.toBeInTheDocument()
  })

  it("lets each caret expand or collapse without navigating", async () => {
    const { user } = renderApplication()
    const navigation = within(appNavigation())
    const sandboxes = navigation.getByRole("button", { name: "Sandboxes" })

    await user.click(navigation.getByRole("button", { name: "Collapse Sandboxes menu" }))
    expect(navigation.queryByRole("group", { name: "Sandbox sections" })).not.toBeInTheDocument()
    expect(sandboxes).toHaveAttribute("aria-current", "page")
    expect(within(appPanel("Sandboxes")).getByRole("list", { name: "Sandboxes" })).toBeVisible()
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

  it("sorts attention first and uses the shared compact sandbox rows", () => {
    const source = applicationSourceForScenario("running")
    const [dev, playgrounds, personal] = source.workspaces
    source.workspaces = [
      { ...dev, id: "normal", state: "running", stateDetail: "Running for 2h 18m", attention: undefined },
      { ...playgrounds, id: "warning", kind: "ssh", state: "stopped", stateDetail: "Waiting for verification", attention: { level: "warning", message: "Storage is almost full." } },
      { ...personal, id: "error", state: "failed", stateDetail: "Start failed 3m ago", attention: { level: "warning", message: "Candidate networking did not become ready." } },
    ]
    renderApplication("running", source)

    const overview = within(appPanel("Sandboxes"))
    const list = overview.getByRole("list", { name: "Sandboxes" })
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

    const attention = overview.getByText("Candidate networking did not become ready.").closest("[role='alert']")
    expect(attention).not.toBeNull()
    expect(list.compareDocumentPosition(attention as HTMLElement) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })

  it("routes compact lifecycle and repair actions with the exact sandbox", async () => {
    const running = renderApplication()
    const overview = within(appPanel("Sandboxes"))

    expect(overview.queryByText("Silo is ready")).not.toBeInTheDocument()
    expect(overview.queryByText(/items? need attention/)).not.toBeInTheDocument()
    await running.user.click(overview.getByRole("button", { name: "Pause dev" }))
    expect(running.actions.pauseWorkspace).toHaveBeenCalledWith("dev")
    await running.user.click(overview.getByRole("button", { name: "Stop dev" }))
    expect(running.actions.stopWorkspace).toHaveBeenCalledWith("dev")
    await running.user.click(overview.getByRole("button", { name: "Restart dev" }))
    expect(running.actions.restartWorkspace).toHaveBeenCalledWith("dev")
    await running.user.click(overview.getByRole("button", { name: "Start playgrounds" }))
    expect(running.actions.startWorkspace).toHaveBeenCalledWith("playgrounds")
    running.unmount()

    const failed = renderApplication("dependency-failure")
    const failedOverview = within(appPanel("Sandboxes"))
    const list = failedOverview.getByRole("list", { name: "Sandboxes" })
    const repair = failedOverview.getByRole("alert")
    expect(repair).toHaveTextContent("Silo installation needs repair")
    expect(list.compareDocumentPosition(repair) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    await failed.user.click(failedOverview.getByRole("button", { name: "Repair…" }))
    expect(failed.actions.repairRuntime).toHaveBeenCalledOnce()
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
