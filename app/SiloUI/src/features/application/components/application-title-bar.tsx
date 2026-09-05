import { useEffect, useRef, type ComponentProps } from "react"
import { ArrowLeft, ArrowRight, PanelLeft, Search } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip"
import { cn } from "@/lib/utils"

function ToolbarButton({ label, ...props }: ComponentProps<typeof Button> & { label: string }) {
  return <Tooltip>
    <TooltipTrigger asChild>
      <Button variant="ghost" size="icon-sm" className="size-7 text-muted-foreground hover:text-foreground disabled:opacity-35 [&_svg]:size-4" aria-label={label} {...props} />
    </TooltipTrigger>
    <TooltipContent side="bottom">{label}</TooltipContent>
  </Tooltip>
}

export function ApplicationTitleBar({
  collapsed,
  onToggleSidebar,
  canGoBack,
  canGoForward,
  onGoBack,
  onGoForward,
}: {
  collapsed: boolean
  onToggleSidebar: () => void
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
    <header aria-label="Window toolbar" className="flex h-11 shrink-0 items-center border-b border-border bg-background">
      <h1 className="sr-only">Silo</h1>
      <div className={cn(
        "flex h-full shrink-0 items-center gap-3 pl-3",
        collapsed ? "pr-2" : "w-[max(var(--sidebar-width),12.5rem)] border-r border-border bg-sidebar pr-3",
      )}>
        <div className="flex shrink-0 items-center gap-2" aria-hidden="true" data-window-controls>
          <span className="size-3.5 rounded-full border border-[#e0443e] bg-[#ff5f57]" />
          <span className="size-3.5 rounded-full border border-[#dea123] bg-[#febc2e]" />
          <span className="size-3.5 rounded-full border border-[#1aab29] bg-[#28c840]" />
        </div>
        <div className="flex items-center gap-1">
          <ToolbarButton label={collapsed ? "Expand sidebar" : "Collapse sidebar"} aria-expanded={!collapsed} aria-controls="application-sidebar" onClick={onToggleSidebar}><PanelLeft /></ToolbarButton>
          <ToolbarButton label="Go back" disabled={!canGoBack} onClick={onGoBack}><ArrowLeft /></ToolbarButton>
          <ToolbarButton label="Go forward" disabled={!canGoForward} onClick={onGoForward}><ArrowRight /></ToolbarButton>
        </div>
      </div>
      {collapsed && <span aria-hidden="true" className="h-5 w-px shrink-0 bg-border" />}
      <div className="flex min-w-0 flex-1 items-center px-3">
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
      </div>
    </header>
  )
}
