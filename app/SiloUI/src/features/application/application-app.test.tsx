import { render, screen, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it, vi } from "vitest"

import { ApplicationApp } from "@/features/application/application-app"
import type { ApplicationActions } from "@/features/application/model/application-source"
import { applicationSourceForScenario } from "@/fixtures/application-scenarios"

function renderApplication(scenario: Parameters<typeof applicationSourceForScenario>[0] = "running") {
  const actions: ApplicationActions = {
    refresh: vi.fn(),
    runChecks: vi.fn(),
    repairRuntime: vi.fn(),
    startWorkspace: vi.fn(),
    stopWorkspace: vi.fn(),
    restartWorkspace: vi.fn(),
    openTerminal: vi.fn(),
    openEditor: vi.fn(),
  }

  return {
    actions,
    user: userEvent.setup(),
    ...render(<ApplicationApp source={applicationSourceForScenario(scenario)} actions={actions} />),
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
    for (const item of primaryItems) expect(item).toHaveClass("flex-none")

    expect(within(navigation).getByRole("button", { name: "Sandboxes" })).toHaveAttribute("aria-current", "page")
    const sandboxSections = within(navigation).getByRole("group", { name: "Sandbox sections" })
    expect(within(sandboxSections).getAllByRole("button").map(({ textContent }) => textContent)).toEqual(["Overview", "Files", "Logs", "Network", "Activity"])
    expect(within(sandboxSections).getByRole("button", { name: "Overview" })).toHaveAttribute("aria-current", "page")
    expect(sandboxSections).toHaveClass("md:pl-3")
    expect(sandboxSections).not.toHaveClass("md:border-l")

    expect(within(appPanel("Sandboxes")).getByRole("heading", { name: "Overview", level: 2 })).toBeVisible()
    expect(screen.queryByRole("group", { name: "Settings sections" })).not.toBeInTheDocument()
  })

  it("lets each caret expand or collapse without navigating", async () => {
    const { user } = renderApplication()
    const navigation = within(appNavigation())
    const sandboxes = navigation.getByRole("button", { name: "Sandboxes" })

    await user.click(navigation.getByRole("button", { name: "Collapse Sandboxes menu" }))
    expect(navigation.queryByRole("group", { name: "Sandbox sections" })).not.toBeInTheDocument()
    expect(sandboxes).toHaveAttribute("aria-current", "page")
    expect(within(appPanel("Sandboxes")).getByRole("heading", { name: "Overview", level: 2 })).toBeVisible()

    await user.click(navigation.getByRole("button", { name: "Expand Settings menu" }))
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

  it("routes workspace and repair actions with the exact sandbox", async () => {
    const running = renderApplication()
    const overview = within(appPanel("Sandboxes"))

    await running.user.click(overview.getAllByRole("button", { name: "Start" })[0])
    expect(running.actions.startWorkspace).toHaveBeenCalledWith("playgrounds")
    await running.user.click(overview.getByRole("button", { name: "Refresh" }))
    expect(running.actions.refresh).toHaveBeenCalledOnce()
    running.unmount()

    const failed = renderApplication("dependency-failure")
    const failedOverview = within(appPanel("Sandboxes"))
    expect(failedOverview.getByRole("alert")).toHaveTextContent("Silo installation needs repair")
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
