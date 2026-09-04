import type { ComponentProps } from "react"
import { useEffect, useRef, useState } from "react"
import { AlertCircle, Check, Copy } from "lucide-react"

import { Button } from "@/components/ui/button"

type CopyStatus = "idle" | "copied" | "failed"

type CopyLabels = Record<CopyStatus, string>

interface CopyButtonProps extends Omit<ComponentProps<typeof Button>, "aria-label" | "children" | "onClick"> {
  value: string
  labels: CopyLabels
  text?: CopyLabels
}

export function CopyButton({ value, labels, text, type = "button", ...props }: CopyButtonProps) {
  const [status, setStatus] = useState<CopyStatus>("idle")
  const resetTimer = useRef<number | undefined>(undefined)

  useEffect(() => () => window.clearTimeout(resetTimer.current), [])

  async function copy() {
    window.clearTimeout(resetTimer.current)
    try {
      await navigator.clipboard.writeText(value)
      setStatus("copied")
    } catch {
      setStatus("failed")
    }
    resetTimer.current = window.setTimeout(() => setStatus("idle"), 1_200)
  }

  const Icon = status === "copied" ? Check : status === "failed" ? AlertCircle : Copy

  return (
    <Button
      {...props}
      type={type}
      onClick={() => void copy()}
      aria-label={labels[status]}
      aria-live="polite"
      aria-atomic="true"
      data-copy-status={status}
    >
      <Icon data-icon={text ? "inline-start" : undefined} aria-hidden="true" />
      {text?.[status]}
    </Button>
  )
}
