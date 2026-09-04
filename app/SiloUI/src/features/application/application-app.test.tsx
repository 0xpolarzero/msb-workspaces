import { act, fireEvent, render, screen, within } from "@testing-library/react"
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
    pushRepository: vi.fn(),
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
    const sandboxList = overview.getByRole("list", { name: "Configured sandboxes" })
    expect(sandboxList).toBeVisible()
    expect(appPanel("Sandboxes")).toHaveClass("h-full", "min-h-0", "overflow-hidden")
    expect(appPanel("Sandboxes").parentElement).toHaveClass("overflow-hidden")
    expect(sandboxList.closest('[data-slot="scroll-area"]')).toHaveClass("max-h-full", "min-h-0")
    expect(sandboxList.closest('[data-slot="scroll-area"]')).not.toHaveClass("flex-1")
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

  it("uses one global sandbox filter across Files, Logs, Network, and Activity", async () => {
    const { actions, user } = renderApplication()
    const navigation = within(appNavigation())
    const sandboxSections = within(navigation.getByRole("group", { name: "Sandbox sections" }))

    await user.click(sandboxSections.getByRole("button", { name: "Files" }))
    const panel = within(appPanel("Sandboxes"))
    const filters = within(panel.getByRole("group", { name: "Sandbox filters" }))
    expect(panel.queryByRole("heading", { name: "Sandboxes" })).not.toBeInTheDocument()
    expect(panel.queryByText("Inspect state, files, logs, networking, and recent activity.")).not.toBeInTheDocument()
    expect(filters.getByRole("combobox", { name: "Filter sandboxes" })).toHaveAttribute("placeholder", "Filter sandboxes…")
    expect(filters.queryByRole("button", { name: /^Remove / })).not.toBeInTheDocument()
    expect(filters.getByRole("button", { name: "Clear" })).toBeDisabled()
    expect(filters.queryByRole("button", { name: "All" })).not.toBeInTheDocument()

    const filesLayout = panel.getByRole("button", { name: "Collapse repositories" }).closest("[data-files-layout]") as HTMLElement
    const repositoriesPane = panel.getByRole("button", { name: "Collapse repositories" }).closest('[data-files-pane="repositories"]') as HTMLElement
    const fileTreePane = panel.getByRole("button", { name: "Collapse file tree" }).closest('[data-files-pane="file-tree"]') as HTMLElement
    expect(filesLayout).toHaveClass("h-full", "min-h-0", "flex-col", "lg:grid", "lg:grid-cols-2", "lg:grid-rows-1")
    expect(repositoriesPane).toHaveAttribute("data-pane-position", "top")
    expect(fileTreePane).toHaveAttribute("data-pane-position", "bottom")
    const repositoryPaneControls = within(repositoriesPane).getByRole("group", { name: "Repository pane controls" })
    const fileTreePaneControls = within(fileTreePane).getByRole("group", { name: "File tree pane controls" })
    expect(repositoryPaneControls).toContainElement(panel.getByRole("button", { name: "Collapse repositories" }))
    expect(fileTreePaneControls).toContainElement(panel.getByRole("button", { name: "Collapse file tree" }))
    expect(repositoryPaneControls.children).toHaveLength(2)
    expect(fileTreePaneControls.children).toHaveLength(2)
    expect(panel.getByRole("button", { name: "Collapse repositories" }).querySelector("svg")).toHaveClass("lucide-chevron-down", "disclosure-caret")
    expect(panel.getByRole("button", { name: "Collapse file tree" }).querySelector("svg")).toHaveClass("lucide-chevron-down", "disclosure-caret")
    expect(repositoriesPane).toHaveClass("max-h-[50%]", "shrink-0")
    expect(fileTreePane).toHaveClass("flex-1")
    expect(repositoriesPane).toHaveClass("collapsible-motion")
    expect(fileTreePane).toHaveClass("collapsible-motion")
    expect(repositoriesPane.querySelector('[data-files-pane-content="repositories"]')).toHaveClass("file-pane-content-motion", "min-h-0", "flex-1")
    expect(fileTreePane.querySelector('[data-files-pane-content="file-tree"]')).toHaveClass("file-pane-content-motion", "min-h-0", "flex-1")
    expect(repositoriesPane.querySelector('[data-files-pane-scroll="repositories"]')).toHaveClass("h-full", "overflow-y-auto")
    expect(fileTreePane.querySelector('[data-files-pane-scroll="file-tree"]')).toHaveClass("h-full", "overflow-y-auto")

    await user.click(panel.getByRole("button", { name: "Collapse repositories" }))
    expect(panel.getByRole("button", { name: "Expand repositories" })).toHaveAttribute("aria-expanded", "false")
    expect(panel.queryByRole("list", { name: "Repositories" })).not.toBeInTheDocument()
    expect(repositoriesPane).toHaveClass("max-h-8", "shrink-0", "transition-[max-height]")
    expect(fileTreePane).toHaveClass("flex-1")
    await user.click(panel.getByRole("button", { name: "Expand repositories" }))

    await user.click(panel.getByRole("button", { name: "Collapse file tree" }))
    expect(panel.getByRole("button", { name: "Expand file tree" })).toHaveAttribute("aria-expanded", "false")
    expect(panel.queryByRole("list", { name: "File tree" })).not.toBeInTheDocument()
    expect(repositoriesPane).toHaveClass("flex-1")
    expect(fileTreePane).toHaveClass("max-h-8", "flex-1", "transition-[max-height]")
    await user.click(panel.getByRole("button", { name: "Expand file tree" }))

    const repositories = panel.getByRole("list", { name: "Repositories" })
    const fileTree = panel.getByRole("list", { name: "File tree" })
    const repositoriesSection = panel.getByRole("region", { name: "Repositories" })
    const fileTreeSection = panel.getByRole("region", { name: "File tree" })
    expect(repositoriesSection.closest('[data-slot="card"]')).toBeNull()
    expect(fileTreeSection.closest('[data-slot="card"]')).toBeNull()
    expect(fileTreePane).toHaveClass("lg:border-l", "lg:pl-5")
    expect(fileTreePane).not.toHaveClass("border-l")
    const devRepository = within(repositories).getByText("acme/silo").closest('[role="listitem"]') as HTMLElement
    const playgroundsRepository = within(repositories).getByText("acme/platform-tools").closest('[role="listitem"]') as HTMLElement
    const devBadge = within(devRepository).getByLabelText("dev, Running")
    expect(devBadge).toBeVisible()
    expect(devBadge).toHaveAttribute("data-slot", "status-badge")
    expect(devBadge).toHaveClass("h-5", "items-center", "justify-center", "text-[10px]", "leading-none")
    expect(devBadge.querySelector('[data-slot="status-badge-indicator"]')).toHaveClass("grid", "size-2", "place-items-center")
    expect(devBadge.querySelector('[data-slot="status-badge-label"]')).toHaveClass("-translate-y-px", "leading-none")
    expect(devRepository.querySelector('[data-workspace-state-dot="running"]')).toHaveClass("bg-emerald-500")
    expect(within(playgroundsRepository).getByLabelText("playgrounds, Stopped")).toBeVisible()
    expect(playgroundsRepository.querySelector('[data-workspace-state-dot="stopped"]')).toHaveClass("bg-muted-foreground/55")
    const repositoryHeader = devRepository.querySelector("[data-repository-header]") as HTMLElement
    const repositoryActions = devRepository.querySelector("[data-repository-actions]") as HTMLElement
    const pushButton = within(repositoryActions).getByRole("button", { name: "Push 2 commits" })
    expect(repositoryActions).toHaveClass("flex", "min-h-6", "items-start")
    expect(pushButton).toHaveClass("h-6")
    expect(repositoryHeader).toContainElement(devBadge)
    expect(repositoryHeader).not.toContainElement(pushButton)
    expect(within(playgroundsRepository).queryByRole("button", { name: /^Push / })).not.toBeInTheDocument()

    await user.click(pushButton)
    expect(actions.pushRepository).toHaveBeenCalledWith("dev", "acme/silo")
    expect(devRepository).toHaveAttribute("aria-busy", "true")
    expect(within(devRepository).getByRole("status")).toHaveClass("h-6")
    expect(within(devRepository).getByRole("status")).toHaveTextContent("Pushing 2 commits…")
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()

    const devFolder = within(fileTree).getByRole("button", { name: "dev" })
    expect(devFolder).toHaveAttribute("aria-expanded", "true")
    expect(panel.getByRole("list", { name: "Files in dev" })).toBeVisible()
    await user.click(devFolder)
    expect(devFolder).toHaveAttribute("aria-expanded", "false")
    expect(panel.queryByRole("list", { name: "Files in dev" })).not.toBeInTheDocument()
    await user.click(devFolder)

    await user.click(filters.getByRole("combobox", { name: "Filter sandboxes" }))
    await user.click(screen.getByRole("option", { name: "dev" }))
    expect(filters.getByRole("button", { name: "Remove dev" })).toBeVisible()
    expect(within(repositories).getByText("acme/silo")).toBeVisible()
    expect(within(fileTree).getByRole("button", { name: "dev" })).toBeVisible()
    expect(within(repositories).queryByText("acme/platform-tools")).not.toBeInTheDocument()
    expect(within(fileTree).queryByRole("button", { name: "personal" })).not.toBeInTheDocument()

    await user.click(filters.getByRole("button", { name: "Remove dev" }))
    expect(within(repositories).getByText("acme/platform-tools")).toBeVisible()
    expect(within(fileTree).getByRole("button", { name: "personal" })).toBeVisible()

    await user.click(filters.getByRole("combobox", { name: "Filter sandboxes" }))
    await user.click(screen.getByRole("option", { name: "playgrounds" }))
    await user.click(filters.getByRole("combobox", { name: "Filter sandboxes" }))
    await user.click(screen.getByRole("option", { name: "personal" }))
    await user.click(sandboxSections.getByRole("button", { name: "Logs" }))
    const logs = panel.getByRole("table", { name: "Logs" })
    expect(logs.closest('[data-slot="card"]')).toBeNull()
    expect(logs).toHaveClass("max-h-full", "min-h-0", "overflow-hidden")
    expect(logs).not.toHaveClass("flex-1")
    expect(logs.querySelector('[data-table-scroll="logs"]')).toHaveClass("min-h-0", "overflow-y-auto")
    expect(logs.querySelector('[data-table-scroll="logs"]')).not.toHaveClass("flex-1")
    expect(within(logs).getAllByRole("columnheader")[0].parentElement).toHaveClass("shrink-0")
    expect(panel.queryByRole("heading", { name: "Logs" })).not.toBeInTheDocument()
    expect(within(logs).queryByText("dev")).not.toBeInTheDocument()
    expect(within(logs).getAllByRole("columnheader").map((header) => header.textContent)).toEqual(["Time", "Message", "Sandbox", "Actions"])
    expect(within(logs).getByLabelText("playgrounds, Stopped")).toBeVisible()
    expect(within(logs).getByLabelText("personal, Stopped")).toBeVisible()

    const playgroundsRow = within(logs).getByLabelText("playgrounds, Stopped").closest('[role="row"]') as HTMLElement
    expect(playgroundsRow).toHaveClass("hover:bg-muted/55", "focus-within:bg-muted/55")
    const playgroundsCells = within(playgroundsRow).getAllByRole("cell")
    expect(playgroundsCells[0]).toHaveTextContent("17:02:11")
    expect(playgroundsCells[1]).toHaveTextContent("silo Workspace stopped cleanly")
    expect(playgroundsCells[2]).toContainElement(within(playgroundsRow).getByLabelText("playgrounds, Stopped"))
    const copyLine = within(playgroundsRow).getByRole("button", { name: "Copy log line from playgrounds at 17:02:11" })
    expect(copyLine).toHaveClass("opacity-0", "group-hover/log-row:opacity-100", "group-focus-within/log-row:opacity-100")
    const copy = vi.spyOn(navigator.clipboard, "writeText")
    await user.click(copyLine)
    expect(copy).toHaveBeenCalledWith("17:02:11  silo  Workspace stopped cleanly")
    const copiedLine = within(playgroundsRow).getByRole("button", { name: "Log line copied" })
    expect(copiedLine).toHaveAttribute("data-copy-status", "copied")
    expect(copiedLine.querySelector("svg")).toHaveClass("lucide-check")

    await user.click(panel.getByRole("button", { name: "Copy all logs" }))
    expect(copy).toHaveBeenLastCalledWith("17:02:11  silo  Workspace stopped cleanly\n09:41:02  silo  Workspace stopped cleanly")
    const copiedLogs = panel.getByRole("button", { name: "All logs copied" })
    expect(copiedLogs).toHaveTextContent("Copied")
    expect(copiedLogs.querySelector("svg")).toHaveClass("lucide-check")

    await user.click(sandboxSections.getByRole("button", { name: "Network" }))
    expect(panel.queryByRole("region", { name: "Network for dev" })).not.toBeInTheDocument()
    expect(panel.getByText("No configured ports")).toBeVisible()

    await user.click(sandboxSections.getByRole("button", { name: "Activity" }))
    const activity = panel.getByRole("list", { name: "Recent activity" })
    expect(activity.closest('[data-slot="card"]')).toBeNull()
    expect(activity).toHaveClass("max-h-full", "min-h-0", "overflow-y-auto")
    expect(activity).not.toHaveClass("flex-1")
    expect(panel.queryByRole("heading", { name: "Activity" })).not.toBeInTheDocument()
    expect(within(activity).queryByText("dev")).not.toBeInTheDocument()
    expect(within(activity).getByText("playgrounds")).toBeVisible()
    expect(within(activity).getByText("Backup completed")).toBeVisible()
    const activityRows = within(activity).getAllByRole("listitem")
    expect(activityRows).toHaveLength(2)
    expect(activityRows[0]).toHaveTextContent("Stop verified2m agoA fresh observation confirmed that the sandbox is stopped.playgroundsSandbox")
    expect(within(activityRows[0]).getByLabelText("playgrounds, Stopped")).toBeVisible()
    const activityContent = activityRows[0].querySelector('[data-activity-content]') as HTMLElement
    const activityMeta = activityRows[0].querySelector('[data-activity-meta]') as HTMLElement
    expect(activityContent).toHaveClass("grid", "gap-1")
    expect(activityContent).toHaveTextContent("2m ago")
    expect(activityContent).not.toContainElement(within(activityRows[0]).getByLabelText("Category: Sandbox"))
    expect(activityMeta).toHaveClass("items-end")
    expect(activityMeta).toContainElement(within(activityRows[0]).getByLabelText("Category: Sandbox"))

    const categoryFilters = within(panel.getByRole("group", { name: "Activity category filters" }))
    const categoryCombobox = categoryFilters.getByRole("combobox", { name: "Add category filter" })
    expect(categoryCombobox).toHaveClass("h-7", "w-36")
    expect(categoryFilters.queryByRole("button", { name: /^Remove / })).not.toBeInTheDocument()
    expect(categoryFilters.getByRole("button", { name: "Clear" })).toBeDisabled()
    expect(categoryFilters.getByRole("button", { name: "Clear" })).toBe(categoryFilters.getByRole("button", { name: "Clear" }).parentElement?.lastElementChild)
    expect(categoryFilters.queryByRole("button", { name: "All" })).not.toBeInTheDocument()

    await user.click(categoryCombobox)
    await user.click(screen.getByRole("option", { name: "Backup" }))
    expect(categoryFilters.getByRole("button", { name: "Remove Backup" })).toBeVisible()
    expect(within(activity).getAllByRole("listitem")).toHaveLength(1)
    expect(within(activity).getByText("Backup completed")).toBeVisible()

    await user.click(categoryCombobox)
    await user.click(screen.getByRole("option", { name: "Sandbox" }))
    expect(within(activity).getAllByRole("listitem")).toHaveLength(2)
    await user.click(categoryFilters.getByRole("button", { name: "Remove Backup" }))
    expect(within(activity).getAllByRole("listitem")).toHaveLength(1)
    expect(within(activity).getByText("Stop verified")).toBeVisible()
    await user.click(categoryFilters.getByRole("button", { name: "Clear" }))
    expect(within(activity).getAllByRole("listitem")).toHaveLength(2)

    await user.click(filters.getByRole("button", { name: "Clear" }))
    expect(filters.getByRole("button", { name: "Clear" })).toBeDisabled()
    expect(filters.queryByRole("button", { name: /^Remove / })).not.toBeInTheDocument()
    const allActivity = panel.getByRole("list", { name: "Recent activity" })
    expect(allActivity).toBeVisible()
    expect(within(allActivity).getAllByRole("listitem").map((row) => row.textContent)).toEqual([
      expect.stringContaining("Start verified"),
      expect.stringContaining("Stop verified"),
      expect.stringContaining("Push completed"),
      expect.stringContaining("Backup completed"),
    ])
    expect(filters.queryByRole("button", { name: "All" })).not.toBeInTheDocument()
  })

  it("orders logs newest first independently of workspace configuration order", async () => {
    const source = applicationSourceForScenario("running")
    source.workspaces.reverse()
    const application = renderApplication("running", source)
    const sandboxSections = within(within(appNavigation()).getByRole("group", { name: "Sandbox sections" }))

    await application.user.click(sandboxSections.getByRole("button", { name: "Logs" }))

    const rows = within(within(appPanel("Sandboxes")).getByRole("table", { name: "Logs" })).getAllByRole("row").slice(1)
    expect(rows.map((row) => within(row).getAllByRole("cell")[0].textContent)).toEqual(["19:18:42", "19:18:40", "19:18:37", "17:02:11", "09:41:02"])
  })

  it("shows one truthful network table and uses the selected browser for opening ports", async () => {
    const application = renderApplication()
    const navigation = within(appNavigation())

    await application.user.click(navigation.getByRole("button", { name: "Settings" }))
    const settings = within(appPanel("Settings"))
    const browser = settings.getByRole("combobox", { name: "Browser" })
    await application.user.click(browser)
    await application.user.click(screen.getByRole("option", { name: "Firefox" }))

    await application.user.click(navigation.getByRole("button", { name: "Sandboxes" }))
    const sandboxSections = within(navigation.getByRole("group", { name: "Sandbox sections" }))
    await application.user.click(sandboxSections.getByRole("button", { name: "Network" }))

    const panel = within(appPanel("Sandboxes"))
    const network = panel.getByRole("table", { name: "Network" })
    expect(network.closest('[data-slot="card"]')).toBeNull()
    expect(network).toHaveClass("min-h-0")
    expect(network).not.toHaveClass("flex-1")
    expect(network.parentElement).toHaveClass("max-h-full", "self-start")
    expect(network.querySelector('[data-table-scroll="network"]')).toHaveClass("min-h-0", "overflow-y-auto")
    expect(network.querySelector('[data-table-scroll="network"]')).not.toHaveClass("flex-1")
    expect(within(network).getAllByRole("columnheader")[0].parentElement).toHaveClass("shrink-0")
    expect(network).not.toHaveClass("min-w-[42rem]")
    expect(network.parentElement).not.toHaveClass("overflow-x-auto")
    expect(panel.queryByRole("heading", { name: "Network" })).not.toBeInTheDocument()
    expect(panel.queryByText("Each sandbox has its own .silo.test address, so the same port can be active in multiple sandboxes.")).not.toBeInTheDocument()
    expect(within(network).queryByText(/^(web|vite|api)$/)).not.toBeInTheDocument()

    const rows = within(network).getAllByRole("row").slice(1)
    expect(rows).toHaveLength(3)
    expect(within(rows[0]).getByText("3000")).toBeVisible()
    expect(within(rows[0]).getByText("Listening")).toHaveClass("text-emerald-700")
    expect(within(rows[0]).getByText("http://dev.silo.test:3000")).toBeVisible()
    expect(within(rows[0]).getByLabelText("dev, Running")).toBeVisible()
    expect(within(rows[1]).getByText("Configured")).toBeVisible()

    expect(rows[0]).toHaveClass("hover:bg-muted/55", "focus-within:bg-muted/55")
    const open = within(rows[0]).getByRole("button", { name: "Open http://dev.silo.test:3000 in Firefox" })
    const actions = open.closest('[role="cell"]') as HTMLElement
    expect(actions).not.toHaveClass("opacity-0", "group-hover/network-row:opacity-100", "group-focus-within/network-row:opacity-100")
    expect(within(rows[1]).getByRole("button", { name: "Copy http://dev.silo.test:5173" })).toBeVisible()
    await application.user.hover(open)
    expect(await screen.findByRole("tooltip")).toHaveTextContent("Open in Firefox")
    await application.user.unhover(open)

    const copy = vi.spyOn(navigator.clipboard, "writeText")
    await application.user.click(within(rows[0]).getByRole("button", { name: "Copy http://dev.silo.test:3000" }))
    expect(copy).toHaveBeenCalledWith("http://dev.silo.test:3000")
    const copiedURL = within(rows[0]).getByRole("button", { name: "URL copied" })
    expect(copiedURL).toHaveAttribute("data-copy-status", "copied")
    expect(copiedURL.querySelector("svg")).toHaveClass("lucide-check")
  })

  it("shows the newest activity first and keeps failure context in its row", async () => {
    const application = renderApplication("bootstrap-failure")
    const sandboxSections = within(within(appNavigation()).getByRole("group", { name: "Sandbox sections" }))

    await application.user.click(sandboxSections.getByRole("button", { name: "Activity" }))

    const activity = within(appPanel("Sandboxes")).getByRole("list", { name: "Recent activity" })
    const firstRow = within(activity).getAllByRole("listitem")[0]
    expect(firstRow).toHaveTextContent("Start failed3m agoCandidate networking did not become ready.devSandbox")
    expect(firstRow.querySelector("svg")).toHaveClass("lucide-circle-alert", "text-destructive")
    expect(within(firstRow).getByLabelText("dev, Failed")).toBeVisible()
  })

  it("shows all six production-backed activity categories", async () => {
    const source = applicationSourceForScenario("running", undefined, undefined, undefined, undefined, undefined, "catalog")
    const application = renderApplication("running", source)
    const sandboxSections = within(within(appNavigation()).getByRole("group", { name: "Sandbox sections" }))

    await application.user.click(sandboxSections.getByRole("button", { name: "Activity" }))

    const panel = within(appPanel("Sandboxes"))
    const filters = within(panel.getByRole("group", { name: "Activity category filters" }))
    await application.user.click(filters.getByRole("combobox", { name: "Add category filter" }))
    expect(screen.getAllByRole("option").map(({ textContent }) => textContent)).toEqual([
      "Sandbox",
      "Git",
      "Backup",
      "Secrets",
      "GitHub",
      "System",
    ])

    const activity = panel.getByRole("list", { name: "Recent activity" })
    for (const category of ["Sandbox", "Git", "Backup", "Secrets", "GitHub", "System"]) {
      expect(within(activity).getAllByLabelText(`Category: ${category}`).length).toBeGreaterThan(0)
    }
    expect(within(activity).getByText("Restart outcome unknown")).toBeVisible()
    expect(within(activity).getByText("Push failed")).toBeVisible()
    expect(within(activity).getByText("Backup completed · restart required")).toBeVisible()
    expect(within(activity).getByText("Secret verification failed")).toBeVisible()
    expect(within(activity).getByText("Grant quarantined")).toBeVisible()
    expect(within(activity).getByText("Deep check failed")).toBeVisible()
  })

  it("updates a live activity in place through progress and completion", async () => {
    const sourceAt = (step: number) => applicationSourceForScenario(
      "running",
      undefined,
      undefined,
      undefined,
      undefined,
      undefined,
      "backup-live",
      step,
    )
    const application = renderApplication("running", sourceAt(0))
    const sandboxSections = within(within(appNavigation()).getByRole("group", { name: "Sandbox sections" }))

    await application.user.click(sandboxSections.getByRole("button", { name: "Activity" }))

    const panel = within(appPanel("Sandboxes"))
    const firstRow = panel.getByRole("list", { name: "Recent activity" }).querySelector<HTMLElement>('[data-activity-id="live-backup"]')
    expect(firstRow).not.toBeNull()
    expect(firstRow).toHaveAttribute("aria-busy", "true")
    expect(firstRow).toHaveTextContent("Preparing backup")
    expect(within(firstRow!).getByRole("progressbar")).toHaveAttribute("aria-valuenow", "10")

    application.rerender(<ApplicationApp source={sourceAt(2)} actions={application.actions} />)
    const progressingRow = panel.getByRole("list", { name: "Recent activity" }).querySelector<HTMLElement>('[data-activity-id="live-backup"]')
    expect(progressingRow).toBe(firstRow)
    expect(progressingRow).toHaveTextContent("Checksumming archive")
    expect(within(progressingRow!).getByRole("progressbar")).toHaveAttribute("aria-valuenow", "75")

    application.rerender(<ApplicationApp source={sourceAt(4)} actions={application.actions} />)
    const completedRow = panel.getByRole("list", { name: "Recent activity" }).querySelector<HTMLElement>('[data-activity-id="live-backup"]')
    expect(completedRow).toBe(firstRow)
    expect(completedRow).not.toHaveAttribute("aria-busy")
    expect(completedRow).toHaveTextContent("Backup completed")
    expect(completedRow?.querySelector("svg")).toHaveClass("lucide-check")
    expect(within(completedRow!).queryByRole("progressbar")).not.toBeInTheDocument()
    expect(panel.getByRole("list", { name: "Recent activity" }).querySelectorAll('[data-activity-id="live-backup"]')).toHaveLength(1)
    expect(within(panel.getByRole("list", { name: "Recent activity" })).getAllByText("Backup completed")).toHaveLength(1)
  })

  it.each([
    ["pushing", "Pushing 2 commits…", true],
    ["succeeded", "Pushed 2 commits.", false],
  ] as const)("shows repository push %s feedback inside its row", async (mode, message, busy) => {
    const source = applicationSourceForScenario("running", undefined, undefined, undefined, undefined, mode)
    const application = renderApplication("running", source)
    const sandboxSections = within(within(appNavigation()).getByRole("group", { name: "Sandbox sections" }))

    await application.user.click(sandboxSections.getByRole("button", { name: "Files" }))
    const row = within(appPanel("Sandboxes")).getByText("acme/silo").closest('[role="listitem"]') as HTMLElement
    expect(within(row).getByRole("status")).toHaveClass("h-6")
    expect(within(row).getByRole("status")).toHaveTextContent(message)
    if (busy) expect(row).toHaveAttribute("aria-busy", "true")
    else {
      expect(row).not.toHaveAttribute("aria-busy")
      expect(row).toHaveTextContent("main · 0 ahead, 0 behind")
    }
    expect(within(row).queryByRole("button", { name: /^Push / })).not.toBeInTheDocument()
  })

  it("shows a repository push error with details and immediate retry", async () => {
    const source = applicationSourceForScenario("running", undefined, undefined, undefined, undefined, "failed")
    const application = renderApplication("running", source)
    const sandboxSections = within(within(appNavigation()).getByRole("group", { name: "Sandbox sections" }))

    await application.user.click(sandboxSections.getByRole("button", { name: "Files" }))
    const row = within(appPanel("Sandboxes")).getByText("acme/silo").closest('[role="listitem"]') as HTMLElement
    expect(within(row).getByRole("alert")).toHaveTextContent("Push failed because the remote branch changed.")
    expect(within(row).queryByText(/no longer matches/)).not.toBeInTheDocument()

    await application.user.click(within(row).getByRole("button", { name: "Toggle push error details for acme/silo" }))
    expect(within(row).getByText(/no longer matches/)).toBeVisible()

    await application.user.click(within(row).getByRole("button", { name: "Retry push for acme/silo" }))
    expect(application.actions.pushRepository).toHaveBeenCalledWith("dev", "acme/silo")
    expect(row).toHaveAttribute("aria-busy", "true")
    expect(within(row).getByRole("status")).toHaveTextContent("Pushing 2 commits…")
  })

  it("clears repository push success after four seconds", () => {
    vi.useFakeTimers()
    const source = applicationSourceForScenario("running", undefined, undefined, undefined, undefined, "succeeded")
    const application = renderApplication("running", source)

    try {
      const sandboxSections = within(within(appNavigation()).getByRole("group", { name: "Sandbox sections" }))
      fireEvent.click(sandboxSections.getByRole("button", { name: "Files" }))
      const row = within(appPanel("Sandboxes")).getByText("acme/silo").closest('[role="listitem"]') as HTMLElement
      expect(within(row).getByRole("status")).toHaveTextContent("Pushed 2 commits.")

      act(() => vi.advanceTimersByTime(4_000))

      expect(within(row).queryByRole("status")).not.toBeInTheDocument()
      expect(row).toHaveTextContent("main · 0 ahead, 0 behind")
      expect(within(row).queryByRole("button", { name: /^Push / })).not.toBeInTheDocument()
    } finally {
      application.unmount()
      vi.useRealTimers()
    }
  })

  it.each([
    ["running", "Running", "running", "bg-emerald-500"],
    ["starting", "Starting", "starting", "bg-amber-500"],
    ["stopped", "Stopped", "stopped", "bg-muted-foreground/55"],
    ["error", "Failed", "failed", "bg-destructive"],
  ] as const)("colors repository VM badges for the %s fixture", async (mode, label, state, className) => {
    const application = renderApplication("running", applicationSourceForScenario("running", undefined, mode satisfies WorkspaceFixtureMode))
    const navigation = within(appNavigation())
    const sandboxSections = within(navigation.getByRole("group", { name: "Sandbox sections" }))

    await application.user.click(sandboxSections.getByRole("button", { name: "Files" }))
    const repositories = within(appPanel("Sandboxes")).getByRole("list", { name: "Repositories" })
    const badge = within(repositories).getAllByLabelText(`dev, ${label}`)[0]
    expect(badge.querySelector(`[data-workspace-state-dot="${state}"]`)).toHaveClass(className)
    application.unmount()
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
    const { actions, user } = renderApplication("running", applicationSourceForScenario("running", undefined, "warning", "workspace-error"))
    const overview = within(appPanel("Sandboxes"))
    const list = overview.getByRole("list", { name: "Configured sandboxes" })
    const rows = within(list).getAllByRole("listitem")
    expect(rows.map((item) => item.getAttribute("data-sandbox-name"))).toEqual(["scratch", "dev", "playgrounds", "personal"])
    const row = rows[0]

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
    const files = within(appPanel("Sandboxes"))
    const repositories = files.getByRole("list", { name: "Repositories" })
    expect(within(repositories).getByText("acme/silo")).toBeVisible()
    expect(within(repositories).getAllByLabelText("dev, Running")[0]).toBeVisible()

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
    const copiedDetails = page.getByRole("button", { name: "Technical details copied" })
    expect(copiedDetails).toBeVisible()
    expect(copiedDetails).toHaveTextContent("Copied")
    expect(copiedDetails.querySelector("svg")).toHaveClass("lucide-check")
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
    const browser = settings.getByRole("combobox", { name: "Browser" })
    expect(browser).toHaveTextContent("Safari")
    await user.click(browser)
    await user.click(screen.getByRole("option", { name: "Firefox" }))

    await user.click(navigation.getByRole("button", { name: "GitHub" }))
    await user.click(navigation.getByRole("button", { name: "Settings" }))
    expect(settings.getByRole("checkbox", { name: "playgrounds" })).toBeChecked()
    expect(settings.getByRole("combobox", { name: "Browser" })).toHaveTextContent("Firefox")

    await user.click(settingsNavigation.getByRole("button", { name: "Notifications" }))
    expect(settings.getByRole("switch", { name: "Enable notifications" })).not.toBeChecked()
  })
})
