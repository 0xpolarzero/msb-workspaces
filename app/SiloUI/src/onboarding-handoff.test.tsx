import { render, screen, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { afterEach, describe, expect, it } from "vitest"

import App from "./App"

const originalURL = window.location.href
afterEach(() => window.history.replaceState(null, "", originalURL))

describe("onboarding to application", () => {
  it("opens Silo with the saved sandbox name and application preference", async () => {
    window.history.replaceState(null, "", "?view=onboarding&scenario=complete")
    const user = userEvent.setup()
    render(<App />)
    await user.click(screen.getByRole("combobox", { name: "Browser" }))
    await user.click(screen.getByRole("option", { name: "Firefox" }))
    await user.click(screen.getByRole("tab", { name: /Sandboxes/ }))
    await user.click(screen.getByRole("button", { name: "Edit dev" }))
    await user.clear(screen.getByRole("textbox", { name: "Machine name" }))
    await user.type(screen.getByRole("textbox", { name: "Machine name" }), "build")
    await user.click(screen.getByRole("button", { name: "Save" }))
    await user.click(screen.getByRole("tab", { name: /Review/ }))
    await user.click(screen.getByRole("button", { name: "Finish" }))
    await user.click(screen.getByRole("button", { name: "Open Silo" }))
    expect(screen.queryByRole("navigation", { name: "Setup steps" })).not.toBeInTheDocument()
    const navigation = within(screen.getByRole("navigation", { name: "Silo navigation" }))
    const list = within(screen.getByRole("list", { name: "Configured sandboxes" }))
    expect(list.getByText("build", { exact: true })).toBeVisible()
    expect(list.queryByText("dev", { exact: true })).not.toBeInTheDocument()
    await user.click(navigation.getByRole("button", { name: "Settings" }))
    expect(screen.getByRole("combobox", { name: "Browser" })).toHaveTextContent("Firefox")
    await user.click(navigation.getByRole("button", { name: "Backup" }))
    expect(screen.getByText("No backups yet")).toBeVisible()
    expect(screen.getByRole("button", { name: "Back up" })).toBeDisabled()
    expect(new URL(window.location.href).searchParams.get("view")).toBe("app")
  })
})
