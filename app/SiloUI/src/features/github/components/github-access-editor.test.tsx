import { render, screen, within } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"

import { GitHubAccessEditor } from "@/features/github/components/github-access-editor"

describe("GitHubAccessEditor", () => {
  it("supports app extensions and makes a disabled editor readable but immutable", () => {
    render(
      <GitHubAccessEditor
        workspaces={[{ name: "dev" }]}
        connectionState="connected"
        repositoryOptions={["acme/silo", "acme/design-system"]}
        workspaceSelections={{ dev: [{ repository: "acme/silo", allowPushes: true }] }}
        workspaceIdentities={{ dev: { name: "Taylor Example", email: "taylor@example.com", apply: true } }}
        currentHostGitIdentity={{ name: "Taylor Example", email: "taylor@example.com" }}
        onConnect={vi.fn()}
        onWorkspaceSelectionsChange={vi.fn()}
        onWorkspaceIdentityChange={vi.fn()}
        onResetWorkspaceIdentity={vi.fn()}
        connectedTitle="Connected as @taylor"
        connectedDetail="Private repositories are available."
        connectedActions={<button type="button">Disconnect</button>}
        notice={<p>GitHub access is paused.</p>}
        renderWorkspaceActions={({ name }) => <button type="button">Disable {name} access</button>}
        footer={<div role="status">Unsaved changes</div>}
        disabled
      />,
    )

    expect(screen.getByRole("heading", { name: "Connected as @taylor" })).toBeVisible()
    expect(screen.getByText("Private repositories are available.")).toBeVisible()
    expect(screen.getByText("GitHub access is paused.")).toBeVisible()
    expect(screen.getByRole("button", { name: "Disconnect" })).toBeEnabled()
    expect(screen.getByRole("button", { name: "Disable dev access" })).toBeEnabled()
    expect(screen.getByRole("status")).toHaveTextContent("Unsaved changes")

    const editor = screen.getByRole("region", { name: "Sandbox Git identity and repository access" })
    expect(within(editor).getByLabelText("Git name for dev")).toBeDisabled()
    expect(within(editor).getByLabelText("Git email for dev")).toBeDisabled()
    expect(within(editor).getByRole("checkbox", { name: "Apply Git identity to dev" })).toBeDisabled()
    expect(within(editor).getByRole("button", { name: "Reset Git identity for dev" })).toBeDisabled()
    expect(within(editor).getByRole("combobox", { name: "Add repository to dev" })).toBeDisabled()
    expect(within(editor).getByRole("checkbox", { name: "Allow pushes for acme/silo" })).toBeDisabled()
    expect(within(editor).getByRole("button", { name: "Remove acme/silo from dev" })).toBeDisabled()
  })
})
