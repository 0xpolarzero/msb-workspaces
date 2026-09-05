import { act, fireEvent, render, screen, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { afterEach, describe, expect, it, vi } from "vitest"

import { BackupPage } from "@/features/application/pages/backup-page"
import { applicationSourceForScenario } from "@/fixtures/application-scenarios"

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

function selectArchive(name = "silo-2026-09-02.silo-backup") {
  fireEvent.change(screen.getByLabelText("Backup archive file"), { target: { files: [new File(["fixture archive"], name)] } })
}

async function finishOperation() {
  for (let step = 0; step < 4; step += 1) {
    await act(async () => { await vi.advanceTimersByTimeAsync(1_600) })
  }
}

describe("BackupPage", () => {
  it("opens the native folder picker, preserves cancelled choices, and uses the selected folder", async () => {
    const user = userEvent.setup()
    const picker = vi.fn()
      .mockRejectedValueOnce(new DOMException("Cancelled", "AbortError"))
      .mockResolvedValueOnce({ name: "My backups" })
    vi.stubGlobal("showDirectoryPicker", picker)
    render(<BackupPage source={applicationSourceForScenario("running")} />)
    await user.click(screen.getByRole("button", { name: "Select destination" }))
    expect(picker).toHaveBeenCalledWith({ id: "silo-backup-destination", mode: "read" })
    expect(screen.getByText("External SSD / Silo Backups")).toBeVisible()
    expect(screen.queryByRole("alert")).not.toBeInTheDocument()
    expect(screen.queryByRole("group", { name: "Backup destination" })).not.toBeInTheDocument()
    await user.click(screen.getByRole("button", { name: "Select destination" }))
    expect(screen.getByText("My backups")).toBeVisible()
    await user.click(screen.getByRole("button", { name: "Back up" }))
    expect(screen.getByRole("group", { name: "Review backup" })).toHaveTextContent("My backups")
    expect(screen.getByRole("group", { name: "Review backup" })).not.toHaveTextContent("GB available")
  })

  it("uses the native directory input when the directory handle API is unavailable", () => {
    vi.stubGlobal("showDirectoryPicker", undefined)
    render(<BackupPage source={applicationSourceForScenario("running")} />)
    const input = screen.getByLabelText("Backup destination folder") as HTMLInputElement
    const click = vi.spyOn(input, "click").mockImplementation(() => undefined)
    fireEvent.click(screen.getByRole("button", { name: "Select destination" }))
    expect(click).toHaveBeenCalledOnce()
    expect(input.webkitdirectory).toBe(true)
    const file = new File(["fixture"], "archive.silo-backup")
    Object.defineProperty(file, "webkitRelativePath", { value: "Local backups/archive.silo-backup" })
    fireEvent.change(input, { target: { files: [file] } })
    expect(screen.getByText("Local backups")).toBeVisible()
    fireEvent.change(input, { target: { files: [] } })
    expect(screen.getByText("Local backups")).toBeVisible()
  })

  it("opens the native archive picker and reviews the selected file directly", () => {
    render(<BackupPage source={applicationSourceForScenario("running")} />)
    const input = screen.getByLabelText("Backup archive file") as HTMLInputElement
    const click = vi.spyOn(input, "click").mockImplementation(() => undefined)
    fireEvent.click(screen.getByRole("button", { name: "Choose archive…" }))
    expect(click).toHaveBeenCalledOnce()
    expect(input).toHaveAttribute("accept", ".silo-backup")
    fireEvent.change(input, { target: { files: [] } })
    expect(screen.queryByRole("group", { name: "Review restore" })).not.toBeInTheDocument()
    selectArchive("my-backup.silo-backup")
    expect(screen.getByRole("group", { name: "Review restore" })).toHaveTextContent("my-backup.silo-backup")
    expect(screen.queryByRole("button", { name: "Use archive" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Restore backup" })).toBeDisabled()
  })

  it("requires review, locks other actions while running, and adds only a completed backup to history", async () => {
    vi.useFakeTimers()
    const onBusyChange = vi.fn()
    render(<BackupPage source={applicationSourceForScenario("running")} onBusyChange={onBusyChange} />)
    const history = within(screen.getByRole("list", { name: "Recent backups" }))
    fireEvent.click(screen.getByRole("button", { name: "Back up" }))
    expect(screen.queryByRole("progressbar")).not.toBeInTheDocument()
    expect(screen.getByRole("group", { name: "Review backup" })).toHaveTextContent("dev will stop briefly")
    fireEvent.click(screen.getByRole("button", { name: "Start backup" }))
    expect(screen.getByRole("progressbar", { name: "Backup progress" })).toBeVisible()
    expect(screen.getByRole("button", { name: "Choose archive…" })).toBeDisabled()
    expect(screen.getByRole("button", { name: "Select destination" })).toBeDisabled()
    expect(onBusyChange).toHaveBeenLastCalledWith(true)
    expect(history.getAllByRole("listitem")).toHaveLength(1)

    await finishOperation()
    expect(screen.getByRole("status")).toHaveTextContent("Backup completed")
    expect(history.getAllByRole("listitem")).toHaveLength(2)
    expect(onBusyChange).toHaveBeenLastCalledWith(false)
    fireEvent.click(screen.getByRole("button", { name: "Done" }))
    expect(screen.queryByRole("status")).not.toBeInTheDocument()
    expect(history.getAllByRole("listitem")).toHaveLength(2)
  })

  it("keeps failed backups out of history and lets the destination be changed before retrying", async () => {
    vi.useFakeTimers()
    render(<BackupPage source={applicationSourceForScenario("running")} previewMode="backup-failed" />)
    fireEvent.click(screen.getByRole("button", { name: "Back up" }))
    fireEvent.click(screen.getByRole("button", { name: "Start backup" }))
    await finishOperation()
    expect(screen.getByRole("alert")).toHaveTextContent("Backup failed")
    expect(within(screen.getByRole("list", { name: "Recent backups" })).getAllByRole("listitem")).toHaveLength(1)
    fireEvent.click(screen.getByRole("button", { name: "Review and retry" }))
    expect(screen.getByRole("group", { name: "Review backup" })).toBeVisible()
    expect(screen.getByRole("button", { name: "Select destination" })).toBeEnabled()
  })

  it("shows a valid archive with a separate restart warning when a sandbox cannot restart", async () => {
    vi.useFakeTimers()
    render(<BackupPage source={applicationSourceForScenario("running")} previewMode="restart-required" />)
    fireEvent.click(screen.getByRole("button", { name: "Back up" }))
    fireEvent.click(screen.getByRole("button", { name: "Start backup" }))
    await finishOperation()
    expect(screen.getByRole("status")).toHaveTextContent("Backup completed")
    expect(screen.getByRole("status")).toHaveTextContent("Restart dev")
    expect(within(screen.getByRole("list", { name: "Recent backups" })).getAllByRole("listitem")).toHaveLength(2)
  })

  it("validates an archive and requires typing RESTORE before replacing sandbox state", async () => {
    vi.useFakeTimers()
    const onRestoreComplete = vi.fn()
    render(<BackupPage source={applicationSourceForScenario("running")} onRestoreComplete={onRestoreComplete} />)
    fireEvent.click(screen.getByRole("button", { name: "Choose archive…" }))
    selectArchive()
    const review = screen.getByRole("group", { name: "Review restore" })
    expect(review).toHaveTextContent("Checksum verified")
    expect(review).toHaveTextContent("All restored sandboxes will stay stopped")
    const restore = screen.getByRole("button", { name: "Restore backup" })
    expect(restore).toBeDisabled()
    fireEvent.change(screen.getByRole("textbox", { name: "Type RESTORE to confirm" }), { target: { value: "restore" } })
    expect(restore).toBeDisabled()
    fireEvent.change(screen.getByRole("textbox", { name: "Type RESTORE to confirm" }), { target: { value: "RESTORE" } })
    fireEvent.click(restore)
    expect(screen.getByRole("button", { name: "Back up" })).toBeDisabled()
    expect(onRestoreComplete).not.toHaveBeenCalled()
    await finishOperation()
    expect(screen.getByRole("status")).toHaveTextContent("Restore completed")
    expect(onRestoreComplete).toHaveBeenCalledOnce()
    expect(within(screen.getByRole("list", { name: "Recent backups" })).getAllByRole("listitem")).toHaveLength(1)
  })

  it("blocks damaged archives and clears confirmation when a restore is cancelled", () => {
    const source = applicationSourceForScenario("running")
    const { rerender } = render(<BackupPage source={source} previewMode="invalid-archive" />)
    fireEvent.click(screen.getByRole("button", { name: "Choose archive…" }))
    selectArchive()
    expect(screen.getByRole("alert")).toHaveTextContent("Checksum mismatch")
    expect(screen.queryByRole("button", { name: "Restore backup" })).not.toBeInTheDocument()

    rerender(<BackupPage source={source} />)
    fireEvent.click(screen.getByRole("button", { name: "Choose archive…" }))
    selectArchive()
    fireEvent.change(screen.getByRole("textbox", { name: "Type RESTORE to confirm" }), { target: { value: "RESTORE" } })
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }))
    fireEvent.click(screen.getByRole("button", { name: "Choose archive…" }))
    selectArchive()
    expect(screen.getByRole("button", { name: "Restore backup" })).toBeDisabled()
  })

  it("opens history details and preserves the selected archive when reviewing a restore", async () => {
    vi.useFakeTimers()
    render(<BackupPage source={applicationSourceForScenario("running")} />)
    fireEvent.click(screen.getByRole("button", { name: "Back up" }))
    fireEvent.click(screen.getByRole("button", { name: "Start backup" }))
    await finishOperation()
    fireEvent.click(screen.getByRole("button", { name: "Details for silo-2026-09-02.silo-backup" }))
    const details = within(screen.getByRole("group", { name: "Archive details for silo-2026-09-02.silo-backup" }))
    expect(details.getByText("External SSD / Silo Backups")).toBeVisible()
    fireEvent.click(details.getByRole("button", { name: "Restore…" }))
    expect(screen.getByRole("group", { name: "Review restore" })).toHaveTextContent("silo-2026-09-02.silo-backup")
    fireEvent.keyDown(screen.getByRole("textbox", { name: "Type RESTORE to confirm" }), { key: "Escape" })
    expect(screen.queryByRole("group", { name: "Review restore" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Choose archive…" })).toHaveFocus()
  })

  it("discards a running preview when an authoritative backup snapshot replaces it", async () => {
    vi.useFakeTimers()
    const source = applicationSourceForScenario("running")
    const onBusyChange = vi.fn()
    const { rerender } = render(<BackupPage source={source} onBusyChange={onBusyChange} />)
    fireEvent.click(screen.getByRole("button", { name: "Back up" }))
    fireEvent.click(screen.getByRole("button", { name: "Start backup" }))
    rerender(<BackupPage source={{ ...source, backup: { ...source.backup, lastArchive: "replacement.silo-backup" } }} onBusyChange={onBusyChange} />)
    await finishOperation()
    expect(screen.queryByRole("progressbar")).not.toBeInTheDocument()
    expect(screen.queryByRole("status")).not.toBeInTheDocument()
    expect(onBusyChange).toHaveBeenLastCalledWith(false)
    const history = within(screen.getByRole("list", { name: "Recent backups" }))
    expect(history.getAllByRole("listitem")).toHaveLength(1)
    expect(history.getByText("replacement.silo-backup")).toBeVisible()
  })

  it("does not report a failed restore as completed and cancels timers on unmount", async () => {
    vi.useFakeTimers()
    const onRestoreComplete = vi.fn()
    const onBusyChange = vi.fn()
    const { unmount } = render(<BackupPage source={applicationSourceForScenario("running")} previewMode="restore-failed" onRestoreComplete={onRestoreComplete} onBusyChange={onBusyChange} />)
    fireEvent.click(screen.getByRole("button", { name: "Choose archive…" }))
    selectArchive()
    fireEvent.change(screen.getByRole("textbox", { name: "Type RESTORE to confirm" }), { target: { value: "RESTORE" } })
    fireEvent.click(screen.getByRole("button", { name: "Restore backup" }))
    await finishOperation()
    expect(screen.getByRole("alert")).toHaveTextContent("Restore failed")
    expect(onRestoreComplete).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole("button", { name: "Choose another archive" }))
    selectArchive()
    fireEvent.change(screen.getByRole("textbox", { name: "Type RESTORE to confirm" }), { target: { value: "RESTORE" } })
    fireEvent.click(screen.getByRole("button", { name: "Restore backup" }))
    unmount()
    await finishOperation()
    expect(onRestoreComplete).not.toHaveBeenCalled()
    expect(onBusyChange).toHaveBeenLastCalledWith(false)
  })
})
