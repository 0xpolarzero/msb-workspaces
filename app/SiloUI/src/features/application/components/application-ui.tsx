import type { ReactNode } from "react"
import { AlertTriangle } from "lucide-react"

import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { cn } from "@/lib/utils"
import type { WorkspaceState } from "@/features/application/model/application-source"

export function PageHeader({ title, description, action }: { title: string; description?: string; action?: ReactNode }) {
  return (
    <header className="flex min-w-0 items-start justify-between gap-4">
      <div className="min-w-0">
        <h2 className="text-xl font-semibold tracking-tight">{title}</h2>
        {description && <p className="mt-1 text-sm text-muted-foreground">{description}</p>}
      </div>
      {action && <div className="shrink-0">{action}</div>}
    </header>
  )
}

export function SectionHeader({ id, title, action }: { id?: string; title: string; action?: ReactNode }) {
  return (
    <div className="flex items-center justify-between gap-3">
      <h3 id={id} className="text-sm font-semibold">{title}</h3>
      {action}
    </div>
  )
}

const workspaceStateStyles: Record<WorkspaceState, string> = {
  running: "bg-emerald-500",
  starting: "bg-amber-500",
  stopped: "bg-muted-foreground/55",
  failed: "bg-destructive",
}

const workspaceStateLabelStyles: Record<WorkspaceState, string> = {
  running: "text-emerald-700 dark:text-emerald-400",
  starting: "text-amber-700 dark:text-amber-400",
  stopped: "text-muted-foreground",
  failed: "text-destructive",
}

export function WorkspaceStateLabel({ state }: { state: WorkspaceState }) {
  return (
    <span className={cn("font-medium", workspaceStateLabelStyles[state])} data-workspace-state={state}>
      {state.charAt(0).toUpperCase() + state.slice(1)}
    </span>
  )
}

export function WorkspaceStatus({ state, detail }: { state: WorkspaceState; detail?: string }) {
  return (
    <span className="inline-flex items-center gap-2 text-xs text-muted-foreground" aria-label={detail ?? state}>
      <span className={cn("size-2 rounded-full", workspaceStateStyles[state])} aria-hidden="true" />
      <WorkspaceStateLabel state={state} />
    </span>
  )
}

export function InlineNotice({
  title,
  children,
  tone = "warning",
  action,
}: {
  title: string
  children: ReactNode
  tone?: "warning" | "danger"
  action?: ReactNode
}) {
  return (
    <div className={cn(
      "flex items-start gap-3 rounded-lg border p-3 text-sm",
      tone === "danger" ? "border-destructive/25 bg-destructive/8 text-destructive" : "border-amber-500/25 bg-amber-500/8 text-foreground",
    )} role="alert">
      <AlertTriangle className={cn("mt-0.5 size-4 shrink-0", tone === "warning" && "text-amber-600 dark:text-amber-400")} />
      <div className="min-w-0 flex-1">
        <div className="font-medium">{title}</div>
        <div className={cn("mt-0.5 text-xs", tone === "danger" ? "text-destructive/85" : "text-muted-foreground")}>{children}</div>
      </div>
      {action && <div className="shrink-0">{action}</div>}
    </div>
  )
}

export function DetailCard({ title, description, children, action }: { title: string; description?: string; children: ReactNode; action?: ReactNode }) {
  return (
    <Card size="sm">
      <CardHeader>
        <CardTitle>{title}</CardTitle>
        {description && <CardDescription>{description}</CardDescription>}
        {action && <div data-slot="card-action" className="col-start-2 row-span-2 row-start-1 self-start justify-self-end">{action}</div>}
      </CardHeader>
      <CardContent>{children}</CardContent>
    </Card>
  )
}
