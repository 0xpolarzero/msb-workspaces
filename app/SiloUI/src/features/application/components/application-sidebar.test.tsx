import { act, cleanup, fireEvent, render, screen } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { ApplicationShell } from "./application-shell"

function renderSidebar() {
  render(<ApplicationShell
    activeTab="workspaces"
    workspaceSection="overview"
    settingsSection="general"
    systemIssueStatus={null}
    workspaceAttention={{ errors: 0, warnings: 0 }}
    onTabChange={vi.fn()}
    onWorkspaceSectionChange={vi.fn()}
    onSettingsSectionChange={vi.fn()}
    canGoBack={false}
    canGoForward={false}
    onGoBack={vi.fn()}
    onGoForward={vi.fn()}
  ><button>Page content</button></ApplicationShell>)
  fireEvent.click(screen.getByRole("button", { name: "Collapse sidebar" }))
  return {
    toggle: screen.getByRole("button", { name: "Expand sidebar" }),
    sidebar: screen.getByRole("navigation", { name: "Silo navigation" }),
  }
}

function wait(milliseconds: number) {
  act(() => vi.advanceTimersByTime(milliseconds))
}

describe("sidebar hover preview", () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => {
    cleanup()
    vi.useRealTimers()
  })

  it("previews on deliberate hover without moving the page, then closes after leaving", () => {
    const { toggle, sidebar } = renderSidebar()
    fireEvent.pointerEnter(toggle)
    wait(100)
    expect(sidebar).toHaveAttribute("data-collapsed", "true")
    wait(100)
    expect(sidebar).toHaveAttribute("data-previewing", "true")
    expect(sidebar).toHaveAttribute("data-collapsed", "false")
    expect(sidebar.parentElement).toHaveAttribute("data-sidebar-layout", "collapsed")
    expect(toggle).toHaveAccessibleName("Keep sidebar open")

    fireEvent.pointerLeave(toggle)
    wait(80)
    fireEvent.pointerEnter(sidebar)
    wait(250)
    expect(sidebar).toHaveAttribute("data-previewing", "true")
    fireEvent.pointerLeave(sidebar)
    wait(80)
    expect(sidebar).toHaveAttribute("data-previewing", "true")
    wait(120)
    expect(sidebar).toHaveAttribute("data-collapsed", "true")
    expect(toggle).toHaveAttribute("aria-expanded", "false")
  })

  it("ignores a passing hover and does not reopen immediately after a collapse click", () => {
    const { toggle, sidebar } = renderSidebar()
    fireEvent.pointerEnter(toggle)
    wait(60)
    fireEvent.pointerLeave(toggle)
    wait(250)
    expect(sidebar).toHaveAttribute("data-previewing", "false")

    fireEvent.click(toggle)
    fireEvent.pointerEnter(toggle)
    fireEvent.click(toggle)
    wait(300)
    expect(sidebar).toHaveAttribute("data-collapsed", "true")
  })

  it("pins a preview on click and stays open after the pointer leaves", () => {
    const { toggle, sidebar } = renderSidebar()
    fireEvent.pointerEnter(toggle)
    wait(200)
    fireEvent.click(toggle)
    fireEvent.pointerLeave(toggle)
    wait(300)
    expect(sidebar).toHaveAttribute("data-previewing", "false")
    expect(sidebar).toHaveAttribute("data-collapsed", "false")
    expect(sidebar.parentElement).toHaveAttribute("data-sidebar-layout", "expanded")
    expect(toggle).toHaveAccessibleName("Collapse sidebar")
  })

  it("cancels dismissal when the pointer returns to the preview", () => {
    const { toggle, sidebar } = renderSidebar()
    fireEvent.pointerEnter(toggle)
    wait(200)
    fireEvent.pointerLeave(toggle)
    fireEvent.pointerEnter(sidebar)
    fireEvent.pointerLeave(sidebar)
    wait(100)
    fireEvent.pointerEnter(sidebar)
    wait(200)
    expect(sidebar).toHaveAttribute("data-previewing", "true")
  })

  it("dismisses with Escape and restores focus without reopening under the pointer", () => {
    const { toggle, sidebar } = renderSidebar()
    fireEvent.pointerEnter(toggle)
    wait(200)
    screen.getByRole("button", { name: "Files" }).focus()
    fireEvent.keyDown(window, { key: "Escape" })
    expect(sidebar).toHaveAttribute("data-collapsed", "true")
    expect(toggle).toHaveFocus()
    wait(300)
    expect(sidebar).toHaveAttribute("data-previewing", "false")
  })

  it("retains a preview during keyboard navigation and closes when focus leaves", () => {
    const { toggle, sidebar } = renderSidebar()
    fireEvent.pointerEnter(toggle)
    wait(200)
    fireEvent.keyDown(sidebar, { key: "Tab" })
    screen.getByRole("button", { name: "Files" }).focus()
    fireEvent.pointerLeave(toggle)
    wait(250)
    expect(sidebar).toHaveAttribute("data-previewing", "true")
    screen.getByRole("button", { name: "Page content" }).focus()
    wait(200)
    expect(sidebar).toHaveAttribute("data-collapsed", "true")
  })
})
