import { AlertTriangle, Check, Play, RotateCw, Terminal } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { HealthSummary, InlineNotice, PageHeader, SectionHeader, WorkspaceStatus } from "@/features/application/components/application-ui"
import type { ApplicationActions, ApplicationSource, ApplicationWorkspace } from "@/features/application/model/application-source"

function WorkspaceActions({ workspace, actions, onView }: { workspace: ApplicationWorkspace; actions: ApplicationActions; onView: () => void }) {
  if (workspace.state === "running") {
    return (
      <div className="flex shrink-0 items-center gap-2">
        <Button variant="outline" size="sm" onClick={() => actions.openTerminal(workspace.id)}>
          <Terminal data-icon="inline-start" />
          Terminal
        </Button>
        <Button variant="ghost" size="sm" onClick={onView}>Details</Button>
      </div>
    )
  }
  if (workspace.state === "failed") {
    return <Button variant="outline" size="sm" onClick={() => actions.restartWorkspace(workspace.id)}><RotateCw data-icon="inline-start" />Retry</Button>
  }
  return <Button variant="outline" size="sm" onClick={() => actions.startWorkspace(workspace.id)}><Play data-icon="inline-start" />Start</Button>
}

export function OverviewPage({ source, actions, onOpenWorkspace }: { source: ApplicationSource; actions: ApplicationActions; onOpenWorkspace: (workspace: string) => void }) {
  const issueCount = source.healthChecks.filter((check) => check.status !== "pass").length

  return (
    <div className="mx-auto grid w-full max-w-4xl gap-6 px-4 py-5 sm:px-6 sm:py-6">
      <PageHeader title="Overview" description={`${source.workspaces.length} sandboxes · ${source.updatedLabel}`} />

      {source.runtimeRepairRequired && (
        <InlineNotice
          title="Silo installation needs repair"
          action={<Button variant="outline" size="sm" onClick={actions.repairRuntime}>Repair…</Button>}
        >
          The bundled runtime could not be verified. Existing workspace information remains visible.
        </InlineNotice>
      )}

      <HealthSummary issueCount={issueCount} onRefresh={actions.refresh} />

      <section className="grid gap-3" aria-labelledby="overview-workspaces">
        <SectionHeader title="Sandboxes" />
        <div className="grid gap-2">
          {source.workspaces.map((workspace) => (
            <Card key={workspace.id} size="sm" className={workspace.state === "failed" ? "ring-destructive/30" : undefined}>
              <CardContent className="grid min-w-0 gap-3 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center">
                <div className="min-w-0">
                  <div className="flex min-w-0 items-center gap-3">
                    <h3 className="truncate text-sm font-semibold">{workspace.id}</h3>
                    <WorkspaceStatus state={workspace.state} detail={workspace.stateDetail} />
                  </div>
                  <p className="mt-1 text-xs text-muted-foreground">{workspace.purpose}</p>
                  {workspace.state === "failed" && (
                    <p className="mt-2 flex items-center gap-2 text-xs text-destructive">
                      <AlertTriangle className="size-3.5" />Candidate networking did not become ready.
                    </p>
                  )}
                </div>
                <WorkspaceActions workspace={workspace} actions={actions} onView={() => onOpenWorkspace(workspace.id)} />
              </CardContent>
            </Card>
          ))}
        </div>
      </section>

      <section className="grid gap-3" aria-labelledby="system-health">
        <SectionHeader title="System health" action={<Button variant="outline" size="sm" onClick={actions.runChecks}>Run checks</Button>} />
        <Card size="sm">
          <CardContent className="divide-y divide-border">
            {source.healthChecks.map((check) => (
              <div key={check.id} className="grid grid-cols-[1rem_minmax(0,1fr)_auto] items-center gap-2 py-2.5 first:pt-0 last:pb-0">
                {check.status === "pass" ? <Check className="size-4 text-emerald-600 dark:text-emerald-400" /> : <AlertTriangle className="size-4 text-amber-600 dark:text-amber-400" />}
                <span className="text-sm font-medium">{check.label}</span>
                <span className="text-xs text-muted-foreground">{check.detail}</span>
              </div>
            ))}
          </CardContent>
        </Card>
      </section>
    </div>
  )
}
