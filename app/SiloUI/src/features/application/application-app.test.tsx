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
  return screen.getByRole("tabpanel", { name })
}

describe("application", () => {
  it("opens on Overview with the complete app navigation", () => {
    renderApplication()

    const navigationTabs = within(appNavigation()).getAllByRole("tab")
    expect(navigationTabs.map(({ textContent }) => textContent)).toEqual([
      "Overview",
      "Sandboxes",
      "GitHub",
      "Secrets",
      "Backup",
      "Settings",
    ])
    for (const tab of navigationTabs) expect(tab).toHaveClass("flex-none")
    expect(within(appNavigation()).getByRole("tab", { name: "Overview" })).toHaveAttribute("aria-selected", "true")
    expect(screen.getByRole("heading", { name: "Overview", level: 2 })).toBeVisible()
    expect(screen.getByText("3 sandboxes · Updated just now")).toBeVisible()
  })

  it("keeps the selected sandbox and section while navigating", async () => {
    const { user } = renderApplication()

    await user.click(within(appNavigation()).getByRole("tab", { name: "Sandboxes" }))
    await user.click(screen.getByRole("button", { name: /^playgrounds/i }))
    await user.click(screen.getByRole("tab", { name: "Files" }))
    expect(within(appPanel("Sandboxes")).getByText("acme/platform-tools")).toBeVisible()

    await user.click(within(appNavigation()).getByRole("tab", { name: "Overview" }))
    await user.click(within(appNavigation()).getByRole("tab", { name: "Sandboxes" }))

    const sandboxes = within(appPanel("Sandboxes"))
    expect(sandboxes.getByRole("tab", { name: "Files" })).toHaveAttribute("aria-selected", "true")
    expect(sandboxes.getByText("acme/platform-tools")).toBeVisible()
  })

  it("routes workspace and repair actions with the exact sandbox", async () => {
    const running = renderApplication()

    await running.user.click(screen.getAllByRole("button", { name: "Start" })[0])
    expect(running.actions.startWorkspace).toHaveBeenCalledWith("playgrounds")
    await running.user.click(screen.getByRole("button", { name: "Refresh" }))
    expect(running.actions.refresh).toHaveBeenCalledOnce()
    running.unmount()

    const failed = renderApplication("dependency-failure")
    const overview = within(appPanel("Overview"))
    expect(overview.getByRole("alert")).toHaveTextContent("Silo installation needs repair")
    await failed.user.click(overview.getByRole("button", { name: "Repair…" }))
    expect(failed.actions.repairRuntime).toHaveBeenCalledOnce()
  })

  it("renders the native app domains in the polished Silo shell", async () => {
    const { user } = renderApplication()
    const navigation = within(appNavigation())

    await user.click(navigation.getByRole("tab", { name: "GitHub" }))
    const github = within(appPanel("GitHub"))
    expect(github.getByText("Connected as @taylor")).toBeVisible()
    await user.click(github.getByRole("button", { name: "Edit access" }))
    expect(github.getAllByRole("checkbox")).toHaveLength(4)
    await user.click(github.getByRole("button", { name: "Save changes" }))

    await user.click(navigation.getByRole("tab", { name: "Secrets" }))
    const secrets = within(appPanel("Secrets"))
    expect(secrets.getByText("DATABASE_URL")).toBeVisible()
    expect(secrets.getByRole("alert")).toHaveTextContent("1 secret change requires a restart")

    await user.click(navigation.getByRole("tab", { name: "Backup" }))
    expect(within(appPanel("Backup")).getByText("silo-2026-09-02.silo-backup")).toBeVisible()
  })

  it("preserves notification and general preferences across app sections", async () => {
    const { user } = renderApplication()
    const navigation = within(appNavigation())

    const settingsTab = navigation.getByRole("tab", { name: "Settings" })
    expect(settingsTab).toHaveAttribute("aria-expanded", "false")
    expect(navigation.queryByRole("button", { name: "Notifications" })).not.toBeInTheDocument()

    await user.click(settingsTab)
    expect(settingsTab).toHaveAttribute("aria-expanded", "true")
    const settingsNavigation = within(navigation.getByRole("group", { name: "Settings sections" }))
    expect(settingsNavigation.getByRole("button", { name: "General" })).toHaveAttribute("aria-current", "page")
    const settings = within(appPanel("Settings"))

    await user.click(settingsNavigation.getByRole("button", { name: "Notifications" }))
    await user.click(settings.getByRole("switch", { name: "Enable notifications" }))
    expect(settings.getByRole("switch", { name: "Sandbox health" })).toBeDisabled()

    await user.click(settingsNavigation.getByRole("button", { name: "General" }))
    const general = within(appPanel("Settings"))
    await user.click(general.getByRole("switch", { name: "Start sandboxes at launch" }))
    const playgrounds = general.getByRole("checkbox", { name: "playgrounds" })
    await user.click(playgrounds)
    expect(playgrounds).toBeChecked()

    await user.click(navigation.getByRole("tab", { name: "Overview" }))
    expect(navigation.queryByRole("group", { name: "Settings sections" })).not.toBeInTheDocument()
    await user.click(settingsTab)
    expect(general.getByRole("checkbox", { name: "playgrounds" })).toBeChecked()

    await user.click(within(navigation.getByRole("group", { name: "Settings sections" })).getByRole("button", { name: "Notifications" }))
    expect(settings.getByRole("switch", { name: "Enable notifications" })).not.toBeChecked()
  })
})
