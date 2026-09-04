import type { ComponentProps, ReactNode } from "react"
import { CircleAlert, Monitor, Server, TriangleAlert } from "lucide-react"

import { Button } from "@/components/ui/button"
import { ScrollArea } from "@/components/ui/scroll-area"
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip"
import { cn } from "@/lib/utils"

export type SandboxIconState = "normal" | "warning" | "error"
export type SandboxRowTone = "running" | "starting" | "stopped" | "warning" | "error"

export function SandboxList({ label, className, children, ...props }: {
  label: string
  children: ReactNode
} & Omit<ComponentProps<typeof ScrollArea>, "children">) {
  return (
    <TooltipProvider delayDuration={150}>
      <ScrollArea className={cn("rounded-md border border-border", className)} {...props}>
        <ol className="divide-y divide-border p-0" aria-label={label}>{children}</ol>
      </ScrollArea>
    </TooltipProvider>
  )
}

export function SandboxListItem({ className, ...props }: ComponentProps<"li">) {
  return <li className={cn("min-w-0 bg-background", className)} {...props} />
}

function SandboxIcon({ kind, state }: { kind: "vm" | "ssh"; state: SandboxIconState }) {
  return (
    <span
      className={cn(
        "grid size-7 shrink-0 place-items-center rounded-md",
        state === "normal" && "bg-muted text-muted-foreground",
        state === "warning" && "bg-amber-500/10 text-amber-600 dark:text-amber-400",
        state === "error" && "bg-destructive/10 text-destructive",
      )}
      data-sandbox-icon-state={state}
      role={state === "normal" ? undefined : "img"}
      aria-label={state === "normal" ? undefined : `${state} status`}
      aria-hidden={state === "normal" ? "true" : undefined}
    >
      {state === "error" ? (
        <CircleAlert className="size-3.5" aria-hidden="true" />
      ) : state === "warning" ? (
        <TriangleAlert className="size-3.5" aria-hidden="true" />
      ) : kind === "vm" ? (
        <Monitor className="size-3.5" aria-hidden="true" />
      ) : (
        <Server className="size-3.5" aria-hidden="true" />
      )}
    </span>
  )
}

export function SandboxListRow({
  name,
  kind,
  iconState = "normal",
  detail,
  detailClassName,
  leading,
  icon,
  actions,
  actionsClassName,
  hoverActions,
  tone,
}: {
  name: string
  kind: "vm" | "ssh"
  iconState?: SandboxIconState
  detail: ReactNode
  detailClassName?: string
  leading?: ReactNode
  icon?: ReactNode
  actions?: ReactNode
  actionsClassName?: string
  hoverActions?: ReactNode
  tone?: SandboxRowTone
}) {
  return (
    <div
      className={cn(
        "sandbox-row flex min-w-0 items-center gap-1.5 px-2 py-2 transition-colors",
        !tone && "hover:bg-muted/35 focus-within:bg-muted/35",
        tone === "running" && "bg-emerald-500/[0.035] hover:bg-emerald-500/[0.07] focus-within:bg-emerald-500/[0.07]",
        tone === "starting" && "bg-amber-500/[0.035] hover:bg-amber-500/[0.07] focus-within:bg-amber-500/[0.07]",
        tone === "stopped" && "bg-muted/15 hover:bg-muted/35 focus-within:bg-muted/35",
        tone === "warning" && "bg-amber-500/[0.04] hover:bg-amber-500/[0.08] focus-within:bg-amber-500/[0.08]",
        tone === "error" && "bg-destructive/[0.035] hover:bg-destructive/[0.07] focus-within:bg-destructive/[0.07]",
      )}
      data-sandbox-row-tone={tone}
    >
      {leading}
      {icon ?? <SandboxIcon kind={kind} state={iconState} />}
      <div className="min-w-0 flex-1">
        <div className="flex min-w-0 items-center gap-1.5">
          <span className="truncate text-xs font-medium" title={name}>{name}</span>
          <span className="shrink-0 rounded-full bg-muted px-1.5 py-0.5 text-[9px] font-medium uppercase text-muted-foreground">{kind}</span>
        </div>
        <div className={cn(
          "truncate text-[10px] text-muted-foreground",
          iconState === "warning" && "text-amber-700 dark:text-amber-400",
          iconState === "error" && "text-destructive",
          detailClassName,
        )}>{detail}</div>
      </div>
      {hoverActions && (
        <div
          className="sandbox-hover-actions flex shrink-0 items-center gap-0.5 transition-opacity"
          aria-label={`Manage ${name}`}
          data-sandbox-hover-actions=""
        >
          {hoverActions}
        </div>
      )}
      {actions && <div className={cn("flex shrink-0 items-center gap-0.5", actionsClassName)} aria-label={`Controls for ${name}`}>{actions}</div>}
    </div>
  )
}

export function SandboxAction({ label, destructive = false, children, ...props }: {
  label: string
  destructive?: boolean
  children: ReactNode
} & Omit<ComponentProps<typeof Button>, "children" | "aria-label">) {
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Button
          type="button"
          variant={destructive ? "destructive" : "ghost"}
          size="icon-xs"
          aria-label={label}
          {...props}
        >
          {children}
        </Button>
      </TooltipTrigger>
      <TooltipContent>{label}</TooltipContent>
    </Tooltip>
  )
}
