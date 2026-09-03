import type { ReactNode } from "react"
import { AlertTriangle, Check, RefreshCw } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { cn } from "@/lib/utils"
import type { WorkspaceState } from "@/features/application/model/application-source"

export function PageHeader({ title, description, action }: { title: string; description: string; action?: ReactNode }) {
  return (
    <header className="flex min-w-0 items-start justify-between gap-4">
      <div className="min-w-0">
        <h2 className="text-xl font-semibold tracking-tight">{title}</h2>
        <p className="mt-1 text-sm text-muted-foreground">{description}</p>
      </div>
      {action && <div className="shrink-0">{action}</div>}
    </header>
  )
}

export function SectionHeader({ title, action }: { title: string; action?: ReactNode }) {
  return (
    <div className="flex items-center justify-between gap-3">
      <h3 className="text-sm font-semibold">{title}</h3>
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

export function WorkspaceStatus({ state, detail }: { state: WorkspaceState; detail?: string }) {
  return (
    <span className="inline-flex items-center gap-2 text-xs text-muted-foreground" aria-label={detail ?? state}>
      <span className={cn("size-2 rounded-full", workspaceStateStyles[state])} aria-hidden="true" />
      <span className="capitalize">{state}</span>
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

export function HealthSummary({ issueCount, onRefresh }: { issueCount: number; onRefresh: () => void }) {
  const ready = issueCount === 0
  return (
    <Card size="sm" className={cn(!ready && "ring-amber-500/30")}>
      <CardHeader className="grid-cols-[auto_1fr_auto] items-center gap-x-3">
        <span className={cn(
          "grid size-8 place-items-center rounded-full",
          ready ? "bg-emerald-500/10 text-emerald-600 dark:text-emerald-400" : "bg-amber-500/10 text-amber-600 dark:text-amber-400",
        )}>
          {ready ? <Check className="size-4" /> : <AlertTriangle className="size-4" />}
        </span>
        <div>
          <CardTitle>{ready ? "Silo is ready" : `${issueCount} item${issueCount === 1 ? "" : "s"} need attention`}</CardTitle>
          <CardDescription>{ready ? "Workspace state is current and actions are available." : "Review the affected system checks before retrying workspace actions."}</CardDescription>
        </div>
        <Button variant="ghost" size="sm" onClick={onRefresh}>
          <RefreshCw data-icon="inline-start" />
          Refresh
        </Button>
      </CardHeader>
    </Card>
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
