import { Code2, Folder, Play, RotateCw, Square, Terminal } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { DetailCard, PageHeader, WorkspaceStatus } from "@/features/application/components/application-ui"
import type { ApplicationActions, ApplicationWorkspace, WorkspaceSection } from "@/features/application/model/application-source"
import { cn } from "@/lib/utils"

const sections: { id: WorkspaceSection; label: string }[] = [
  { id: "summary", label: "Summary" },
  { id: "files", label: "Files" },
  { id: "logs", label: "Logs" },
  { id: "network", label: "Network" },
  { id: "activity", label: "Activity" },
]

function Summary({ workspace, actions }: { workspace: ApplicationWorkspace; actions: ApplicationActions }) {
  return (
    <div className="grid gap-3 lg:grid-cols-2">
      <DetailCard title="Status" description={workspace.stateDetail}>
        <div className="flex flex-wrap items-center gap-2">
          <WorkspaceStatus state={workspace.state} />
          {workspace.state === "running" ? (
            <>
              <Button variant="outline" size="sm" onClick={() => actions.openTerminal(workspace.id)}><Terminal data-icon="inline-start" />Terminal</Button>
              <Button variant="outline" size="sm" onClick={() => actions.openEditor(workspace.id)}><Code2 data-icon="inline-start" />Editor</Button>
              <Button variant="ghost" size="sm" onClick={() => actions.restartWorkspace(workspace.id)}><RotateCw data-icon="inline-start" />Restart</Button>
              <Button variant="ghost" size="sm" onClick={() => actions.stopWorkspace(workspace.id)}><Square data-icon="inline-start" />Stop</Button>
            </>
          ) : (
            <Button variant="outline" size="sm" onClick={() => actions.startWorkspace(workspace.id)}><Play data-icon="inline-start" />Start</Button>
          )}
        </div>
      </DetailCard>
      <DetailCard title="Resources" description="Current allocation">
        <dl className="grid grid-cols-3 gap-3 text-sm">
          <div><dt className="text-xs text-muted-foreground">CPU</dt><dd className="mt-1 font-medium">{workspace.cpus} cores</dd></div>
          <div><dt className="text-xs text-muted-foreground">Memory</dt><dd className="mt-1 font-medium">{workspace.memoryGiB} GiB</dd></div>
          <div><dt className="text-xs text-muted-foreground">Storage</dt><dd className="mt-1 font-medium">{workspace.storageGiB} GiB</dd></div>
        </dl>
      </DetailCard>
      <DetailCard title="Connections" description="Managed host access">
        <dl className="grid gap-2 text-sm">
          <div className="flex justify-between gap-3"><dt className="text-muted-foreground">Host</dt><dd className="font-mono text-xs">{workspace.host}</dd></div>
          <div className="flex justify-between gap-3"><dt className="text-muted-foreground">GitHub</dt><dd>{workspace.githubRepositories.length} repositories</dd></div>
          <div className="flex justify-between gap-3"><dt className="text-muted-foreground">Secrets</dt><dd>{workspace.secretNames.length} available</dd></div>
        </dl>
      </DetailCard>
      <DetailCard title="Freshness" description={workspace.freshness === "fresh" ? "Current snapshot" : "Showing last known state"}>
        <p className="text-sm text-muted-foreground">Silo last verified this sandbox {workspace.freshness === "fresh" ? "just now" : "3 minutes ago"}.</p>
      </DetailCard>
    </div>
  )
}

function PlaceholderSection({ section, workspace }: { section: Exclude<WorkspaceSection, "summary">; workspace: ApplicationWorkspace }) {
  return (
    <Card size="sm">
      <CardContent className="grid min-h-48 place-items-center text-center">
        <div>
          <Folder className="mx-auto size-5 text-muted-foreground" />
          <h3 className="mt-3 text-sm font-medium">{sections.find((item) => item.id === section)?.label}</h3>
          <p className="mt-1 text-xs text-muted-foreground">{workspace.id} content is ready for the full view.</p>
        </div>
      </CardContent>
    </Card>
  )
}

export function WorkspacesPage({
  workspaces,
  selectedWorkspace,
  section,
  actions,
  onWorkspaceChange,
  onSectionChange,
}: {
  workspaces: ApplicationWorkspace[]
  selectedWorkspace: string
  section: WorkspaceSection
  actions: ApplicationActions
  onWorkspaceChange: (workspace: string) => void
  onSectionChange: (section: WorkspaceSection) => void
}) {
  const workspace = workspaces.find((item) => item.id === selectedWorkspace) ?? workspaces[0]

  return (
    <div className="mx-auto grid w-full max-w-4xl gap-5 px-4 py-5 sm:px-6 sm:py-6">
      <PageHeader title="Sandboxes" description="Inspect state, files, logs, networking, and recent activity." />
      <div className="flex min-w-0 gap-2 overflow-x-auto pb-1" aria-label="Choose sandbox">
        {workspaces.map((item) => (
          <button
            key={item.id}
            type="button"
            onClick={() => onWorkspaceChange(item.id)}
            className={cn(
              "flex min-w-36 items-center justify-between gap-3 rounded-lg border px-3 py-2 text-left text-sm transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
              item.id === workspace.id ? "border-foreground/20 bg-muted font-medium" : "border-border bg-card text-muted-foreground hover:bg-muted/60 hover:text-foreground",
            )}
          >
            {item.id}
            <WorkspaceStatus state={item.state} />
          </button>
        ))}
      </div>
      <div>
        <div className="flex items-end justify-between gap-3">
          <div>
            <h3 className="text-base font-semibold">{workspace.id}</h3>
            <p className="mt-1 text-xs text-muted-foreground">{workspace.purpose}</p>
          </div>
          <WorkspaceStatus state={workspace.state} detail={workspace.stateDetail} />
        </div>
        <Tabs value={section} onValueChange={(value) => onSectionChange(value as WorkspaceSection)} className="mt-4 gap-4">
          <TabsList variant="line" className="w-full justify-start overflow-x-auto" aria-label={`${workspace.id} sections`}>
            {sections.map((item) => <TabsTrigger key={item.id} value={item.id}>{item.label}</TabsTrigger>)}
          </TabsList>
          {section === "summary" ? <Summary workspace={workspace} actions={actions} /> : <PlaceholderSection section={section} workspace={workspace} />}
        </Tabs>
      </div>
    </div>
  )
}
