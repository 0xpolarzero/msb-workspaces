import { fireEvent, render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { useState } from "react"
import { describe, expect, it, vi } from "vitest"

import { InlineConfirmation } from "@/components/inline-confirmation"

function ConfirmationHarness({ onDismiss }: { onDismiss: () => void }) {
  const [active, setActive] = useState(false)

  return (
    <div>
      <button type="button" onClick={() => setActive(true)}>Arm</button>
      <InlineConfirmation active={active} onDismiss={() => {
        onDismiss()
        setActive(false)
      }}>
        {active && <button type="button">Confirm</button>}
      </InlineConfirmation>
      <button type="button">Outside</button>
    </div>
  )
}

describe("InlineConfirmation", () => {
  it("keeps inside presses and dismisses on Escape or an outside press", async () => {
    const user = userEvent.setup()
    const onDismiss = vi.fn()
    render(<ConfirmationHarness onDismiss={onDismiss} />)

    await user.click(screen.getByRole("button", { name: "Arm" }))
    fireEvent.pointerDown(screen.getByRole("button", { name: "Confirm" }))
    expect(screen.getByRole("button", { name: "Confirm" })).toBeVisible()
    expect(onDismiss).not.toHaveBeenCalled()

    await user.keyboard("{Escape}")
    expect(screen.queryByRole("button", { name: "Confirm" })).not.toBeInTheDocument()
    expect(onDismiss).toHaveBeenCalledOnce()

    await user.click(screen.getByRole("button", { name: "Arm" }))
    fireEvent.pointerDown(screen.getByRole("button", { name: "Outside" }))
    expect(screen.queryByRole("button", { name: "Confirm" })).not.toBeInTheDocument()
    expect(onDismiss).toHaveBeenCalledTimes(2)
  })
})
