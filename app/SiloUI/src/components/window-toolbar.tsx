import type { ComponentProps, ReactNode, RefObject } from "react"
import { PanelLeft } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip"

export function WindowControls() {
  return <div className="flex shrink-0 items-center gap-2" aria-hidden="true" data-window-controls>
    <span className="size-3.5 rounded-full border border-[#e0443e] bg-[#ff5f57]" />
    <span className="size-3.5 rounded-full border border-[#dea123] bg-[#febc2e]" />
    <span className="size-3.5 rounded-full border border-[#1aab29] bg-[#28c840]" />
  </div>
}

export function ToolbarButton({ label, showTooltip = true, ...props }: ComponentProps<typeof Button> & { label: string; showTooltip?: boolean }) {
  return <Tooltip>
    <TooltipTrigger asChild>
      <Button variant="ghost" size="icon-sm" className="size-7 text-muted-foreground hover:text-foreground disabled:opacity-35 [&_svg]:size-4" aria-label={label} {...props} />
    </TooltipTrigger>
    <TooltipContent side="bottom" hidden={!showTooltip}>{label}</TooltipContent>
  </Tooltip>
}

interface WindowToolbarProps {
  title: string
  sidebarId: string
  collapsed: boolean
  previewing: boolean
  toggleRef: RefObject<HTMLButtonElement | null>
  onToggleSidebar: () => void
  onPreviewEnter: () => void
  onPreviewLeave: () => void
  navigation?: ReactNode
  children?: ReactNode
}

export function WindowToolbar({ title, sidebarId, collapsed, previewing, toggleRef, onToggleSidebar, onPreviewEnter, onPreviewLeave, navigation, children }: WindowToolbarProps) {
  return <header aria-label="Window toolbar" className="flex h-11 shrink-0 items-center border-b border-border bg-background">
    {children && <h1 className="sr-only">{title}</h1>}
    <div className="silo-titlebar-controls flex h-full shrink-0 items-center gap-3 pr-2 pl-3">
      <WindowControls />
      <div className="flex items-center gap-1">
        <ToolbarButton
          ref={toggleRef}
          label={collapsed ? previewing ? "Keep sidebar open" : "Expand sidebar" : "Collapse sidebar"}
          showTooltip={!previewing}
          aria-expanded={!collapsed || previewing}
          aria-controls={sidebarId}
          onPointerEnter={(event) => { if (event.pointerType !== "touch") onPreviewEnter() }}
          onPointerLeave={onPreviewLeave}
          onClick={onToggleSidebar}
        ><PanelLeft /></ToolbarButton>
        {navigation}
      </div>
      <span aria-hidden="true" className="silo-toolbar-divider" />
    </div>
    <div className="flex min-w-0 flex-1 items-center px-4 sm:px-6">
      {children ?? <h1 className="text-[13px] font-medium">{title}</h1>}
    </div>
  </header>
}
