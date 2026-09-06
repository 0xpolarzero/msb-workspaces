import { useEffect, useRef, type RefObject } from "react"
import { ArrowLeft, ArrowRight, Search } from "lucide-react"

import { ToolbarButton, WindowToolbar } from "@/components/window-toolbar"

export function ApplicationTitleBar({
  collapsed,
  previewing,
  toggleRef,
  onToggleSidebar,
  onPreviewEnter,
  onPreviewLeave,
  canGoBack,
  canGoForward,
  onGoBack,
  onGoForward,
}: {
  collapsed: boolean
  previewing: boolean
  toggleRef: RefObject<HTMLButtonElement | null>
  onToggleSidebar: () => void
  onPreviewEnter: () => void
  onPreviewLeave: () => void
  canGoBack: boolean
  canGoForward: boolean
  onGoBack: () => void
  onGoForward: () => void
}) {
  const commandInput = useRef<HTMLInputElement>(null)

  useEffect(() => {
    function focusCommandInput(event: KeyboardEvent) {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k" && !event.altKey && !event.isComposing) {
        event.preventDefault()
        commandInput.current?.focus()
        commandInput.current?.select()
      }
    }
    window.addEventListener("keydown", focusCommandInput)
    return () => window.removeEventListener("keydown", focusCommandInput)
  }, [])

  return (
    <WindowToolbar
      title="Silo"
      sidebarId="application-sidebar"
      collapsed={collapsed}
      previewing={previewing}
      toggleRef={toggleRef}
      onToggleSidebar={onToggleSidebar}
      onPreviewEnter={onPreviewEnter}
      onPreviewLeave={onPreviewLeave}
      navigation={<>
        <ToolbarButton label="Go back" disabled={!canGoBack} onClick={onGoBack}><ArrowLeft /></ToolbarButton>
        <ToolbarButton label="Go forward" disabled={!canGoForward} onClick={onGoForward}><ArrowRight /></ToolbarButton>
      </>}
    >
      <div className="relative w-full max-w-md">
        <Search aria-hidden="true" className="pointer-events-none absolute top-1/2 left-2 size-3.5 -translate-y-1/2 text-muted-foreground" />
        <input
          ref={commandInput}
          aria-label="Search or jump to"
          aria-keyshortcuts="Meta+K Control+K"
          placeholder="Search or jump to…"
          autoComplete="off"
          spellCheck={false}
          className="h-7 w-full min-w-0 rounded-md border border-border bg-muted/30 pr-11 pl-7 text-xs outline-none placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-2 focus-visible:ring-ring/30"
        />
        <kbd aria-hidden="true" className="pointer-events-none absolute top-1/2 right-2 -translate-y-1/2 font-sans text-[11px] text-muted-foreground">⌘ K</kbd>
      </div>
    </WindowToolbar>
  )
}
