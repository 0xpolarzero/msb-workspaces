import { fireEvent, render, screen, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it, vi } from "vitest"

import { DependencyDisclosure } from "@/features/onboarding/components/dependency-disclosure"
import { projectOnboarding } from "@/features/onboarding/model/onboarding-state"
import { GitHubStep } from "@/features/onboarding/steps/github-step"
import { onboardingScenarios } from "@/fixtures/scenarios"

describe("onboarding preparation interactions", () => {
  it("summarizes closed dependency groups and supports keyboard disclosure", async () => {
    const user = userEvent.setup()
    const group = projectOnboarding(onboardingScenarios.running, "connected").dependencies[0]
    render(<DependencyDisclosure group={group} onRepairRuntime={vi.fn()} />)

    expect(screen.getByText("6 components ready")).toBeVisible()
    expect(screen.queryByText("silo-ssh-proxy")).not.toBeInTheDocument()
    const trigger = screen.getByRole("button", { name: "Silo tools" })
    trigger.focus()
    await user.keyboard(" ")
    expect(trigger).toHaveAttribute("aria-expanded", "true")
    expect(screen.getByText("silo-ssh-proxy")).toBeVisible()
    await user.keyboard(" ")
    expect(trigger).toHaveAttribute("aria-expanded", "false")
    expect(screen.queryByText("silo-ssh-proxy")).not.toBeInTheDocument()
  })

  it("opens failed checks with their recovery action and keeps repair separate from disclosure", async () => {
    const user = userEvent.setup()
    const repair = vi.fn()
    const group = projectOnboarding(onboardingScenarios["dependency-failure"], "connected").dependencies[0]
    render(<DependencyDisclosure group={group} onRepairRuntime={repair} />)

    expect(screen.getByText("1 check needs attention")).toBeVisible()
    const trigger = screen.getByRole("button", { name: "Silo tools" })
    expect(trigger).toHaveAttribute("aria-expanded", "true")
    const notice = screen.getByRole("alert")
    expect(within(notice).getByText("Silo runtime needs repair")).toBeVisible()
    expect(within(notice).getByText("Use Repair… to reinstall the bundled Silo runtime.")).toBeVisible()
    await user.click(within(notice).getByRole("button", { name: "Repair…" }))
    expect(repair).toHaveBeenCalledOnce()
    expect(trigger).toHaveAttribute("aria-expanded", "true")
  })

  it("requires inline confirmation before clearing onboarding repository access", () => {
    const changeSelections = vi.fn()
    render(<GitHubStep
      workspaces={[{ name: "dev" }]}
      connectionState="connected"
      repositoryOptions={["acme/silo"]}
      workspaceSelections={{ dev: [{ repository: "acme/silo", allowPushes: false }] }}
      workspaceIdentities={{ dev: { name: "Taylor", email: "taylor@example.com", apply: true } }}
      currentHostGitIdentity={{ name: "Taylor", email: "taylor@example.com" }}
      onConnect={vi.fn()}
      onWorkspaceSelectionsChange={changeSelections}
      onWorkspaceIdentityChange={vi.fn()}
      onResetWorkspaceIdentity={vi.fn()}
    />)

    fireEvent.click(screen.getByRole("button", { name: "Clear repositories from dev" }))
    expect(changeSelections).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole("button", { name: "Confirm clearing repositories from dev" }))
    expect(changeSelections).toHaveBeenCalledExactlyOnceWith("dev", [])
  })
})
