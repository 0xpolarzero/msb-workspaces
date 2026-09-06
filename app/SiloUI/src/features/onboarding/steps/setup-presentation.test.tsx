import { render, screen, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it, vi } from "vitest"

import { Button } from "@/components/ui/button"
import { SetupNotice } from "@/features/onboarding/components/setup-notice"
import { productionMachineDefaults } from "@/features/onboarding/model/machine-configuration"
import type { ReviewQueueItemView, WorkspaceProgressView } from "@/features/onboarding/model/onboarding-state"
import { ReviewStep } from "@/features/onboarding/steps/review-step"
import { WorkspacesStep } from "@/features/onboarding/steps/workspaces-step"

const progress: WorkspaceProgressView = {
  status: "running", elapsedSeconds: 83, currentWorkspace: "playgrounds", currentMessage: "Checking sandbox connectivity",
  completedOperations: 4, totalOperations: 9, fraction: 4 / 9,
  workspaces: [
    { name: "dev", status: "ready", detail: "Ready" },
    { name: "playgrounds", status: "working", detail: "Checking sandbox connectivity" },
    { name: "personal", status: "waiting", detail: "Waiting" },
  ],
  visibleEvents: [], readyCount: 1, workingCount: 1, waitingCount: 1, failedCount: 0, retryable: false,
}

const queueItems: ReviewQueueItemView[] = [
  { id: "workspaceRun", label: "Create sandboxes", status: "succeeded" },
  { id: "workspaceVerify", label: "Verify sandboxes", status: "running" },
  { id: "githubRun", label: "Save GitHub", status: "queued" },
  { id: "githubVerify", label: "Verify GitHub", status: "queued" },
  { id: "identityRun", label: "Save Git identities", status: "queued" },
  { id: "identityVerify", label: "Verify Git identities", status: "queued" },
  { id: "completion", label: "Finish setup", status: "queued" },
]

function renderReview(onEditStep = vi.fn()) {
  render(<ReviewStep machines={productionMachineDefaults} queueItems={queueItems} workspaceRetryable={false} identitySummary="Alex · alex@example.com" githubSummary="2 repositories selected" onRetryWorkspaceSetup={vi.fn()} onEditStep={onEditStep} />)
  return onEditStep
}

describe("setup progress and review presentation", () => {
  it("keeps activity collapsed until requested and preserves the list while opening it", async () => {
    const user = userEvent.setup()
    render(<WorkspacesStep machines={productionMachineDefaults} progress={progress} onMachinesChange={vi.fn()} onRetry={vi.fn()} />)
    const machines = screen.getByRole("list", { name: "Configured sandboxes" })
    expect(screen.queryByLabelText("Sandbox activity")).not.toBeInTheDocument()
    await user.click(screen.getByRole("button", { name: "Expand activity" }))
    expect(screen.getByLabelText("Sandbox activity")).toHaveTextContent("No activity yet.")
    expect(screen.getByRole("list", { name: "Configured sandboxes" })).toBe(machines)
    expect(within(machines).getAllByRole("listitem")).toHaveLength(3)
    await user.click(screen.getByRole("button", { name: "Collapse activity" }))
    expect(screen.queryByLabelText("Sandbox activity")).not.toBeInTheDocument()
  })

  it("distinguishes each sandbox status without replacing the busy machine icon", () => {
    render(<WorkspacesStep machines={productionMachineDefaults} progress={progress} onMachinesChange={vi.fn()} onRetry={vi.fn()} />)
    const rows = within(screen.getByRole("list", { name: "Configured sandboxes" })).getAllByRole("listitem")
    expect(within(rows[0]).getByText("Complete")).toBeVisible()
    expect(within(rows[1]).getByText("In progress")).toBeVisible()
    expect(rows[1]).toHaveAttribute("aria-busy", "true")
    expect(rows[1].querySelector("svg.lucide-monitor")).not.toBeNull()
    expect(rows[1].querySelector("svg.lucide-loader-circle")).not.toBeNull()
    expect(within(rows[2]).getByText("Waiting")).toBeVisible()
    expect(screen.getByLabelText("Elapsed time")).toHaveTextContent("01:23")
  })

  it("keeps recovery and retry beside the failed operation", async () => {
    const user = userEvent.setup()
    const retry = vi.fn()
    render(<WorkspacesStep machines={productionMachineDefaults} progress={{ ...progress, status: "failed", retryable: true, currentMessage: "The sandbox could not be reached.", recovery: "Check the network connection, then retry setup.", workspaces: [{ name: "playgrounds", status: "failed", detail: "The sandbox could not be reached." }] }} onMachinesChange={vi.fn()} onRetry={retry} />)
    const status = screen.getByRole("alert")
    expect(status).toHaveTextContent("The sandbox could not be reached.")
    expect(status.parentElement).toHaveTextContent("Check the network connection, then retry setup.")
    await user.click(within(status).getByRole("button", { name: "Retry" }))
    expect(retry).toHaveBeenCalledOnce()
    expect(within(screen.getByRole("list", { name: "Configured sandboxes" })).getByText("Failed")).toBeVisible()
  })

  it("uses readable operation statuses and preserves sandbox order and resources", () => {
    renderReview()
    const operations = within(screen.getByRole("list", { name: "Setup operations" })).getAllByRole("listitem")
    expect(operations).toHaveLength(7)
    expect(operations[0]).toHaveTextContent("Complete")
    expect(operations[1]).toHaveTextContent("In progress")
    expect(operations[2]).toHaveTextContent("Waiting")
    expect(screen.queryByText("queued")).not.toBeInTheDocument()
    expect(screen.queryByText("succeeded")).not.toBeInTheDocument()
    const sandboxes = within(screen.getByRole("list", { name: "Sandboxes in setup order" })).getAllByRole("listitem")
    expect(sandboxes.map((row) => row.querySelector("[title]")?.getAttribute("title"))).toEqual(["dev", "playgrounds", "personal"])
    expect(sandboxes[0]).toHaveTextContent("8 CPU · 32 GB RAM · 120 GB workspace")
    expect(screen.getByText("2 repositories selected")).toBeVisible()
    expect(screen.getByText("Alex · alex@example.com")).toBeVisible()
  })

  it("routes review edit shortcuts to their corresponding steps", async () => {
    const user = userEvent.setup()
    const edit = renderReview()
    await user.click(screen.getByRole("button", { name: "Edit sandboxes" }))
    expect(edit).toHaveBeenLastCalledWith("workspaces")
    await user.click(screen.getByRole("button", { name: "Edit GitHub access" }))
    expect(edit).toHaveBeenLastCalledWith("github")
    await user.click(screen.getByRole("button", { name: "Edit Git author" }))
    expect(edit).toHaveBeenLastCalledWith("github")
  })

  it("keeps recovery visible while technical evidence stays optional", async () => {
    const user = userEvent.setup()
    const repair = vi.fn()
    render(<SetupNotice title="Setup couldn’t finish" detail="The helper is unavailable." recovery="Repair the installation to continue." technicalDetails="Helper connection timed out after 30 seconds." action={<Button onClick={repair}>Repair</Button>} />)
    expect(screen.getByRole("alert")).toHaveTextContent("Repair the installation to continue.")
    expect(screen.queryByText("Helper connection timed out after 30 seconds.")).not.toBeInTheDocument()
    await user.click(screen.getByRole("button", { name: "Show technical details" }))
    expect(screen.getByText("Helper connection timed out after 30 seconds.")).toBeVisible()
    await user.click(screen.getByRole("button", { name: "Repair" }))
    expect(repair).toHaveBeenCalledOnce()
  })
})
