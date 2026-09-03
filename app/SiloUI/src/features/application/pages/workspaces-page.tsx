import { Activity, Check, Code2, Copy, ExternalLink, File, Folder, GitBranch, Play, RotateCw, Search, Square, Terminal, TriangleAlert } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
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

function Files({ workspace }: { workspace: ApplicationWorkspace }) {
  return (
    <div className="grid gap-3 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
      <DetailCard title="Repositories" description={`${workspace.repositories.length} checked out`}>
        <div className="divide-y divide-border">
          {workspace.repositories.map((repository) => (
            <div key={repository.path} className="grid grid-cols-[1rem_minmax(0,1fr)_auto] items-center gap-2 py-2.5 first:pt-0 last:pb-0">
              <GitBranch className="size-4 text-muted-foreground" />
              <div className="min-w-0">
                <div className="truncate text-sm font-medium">{repository.path}</div>
                <div className="mt-0.5 text-xs text-muted-foreground">{repository.branch} · {repository.ahead} ahead, {repository.behind} behind{repository.dirty ? " · local changes" : ""}</div>
              </div>
              {repository.ahead > 0 && <Button variant="outline" size="xs">Push {repository.ahead}</Button>}
            </div>
          ))}
        </div>
      </DetailCard>
      <DetailCard title="Files" description="Workspace root">
        <div className="grid gap-1 font-mono text-xs">
          {[{ icon: Folder, name: "projects" }, { icon: Folder, name: ".config" }, { icon: File, name: ".gitconfig" }, { icon: File, name: "README.md" }].map(({ icon: Icon, name }) => (
            <button key={name} type="button" className="flex items-center gap-2 rounded-md px-2 py-1.5 text-left hover:bg-muted focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring">
              <Icon className="size-4 text-muted-foreground" />{name}
            </button>
          ))}
        </div>
      </DetailCard>
    </div>
  )
}

function Logs({ workspace, query, onQueryChange }: { workspace: ApplicationWorkspace; query: string; onQueryChange: (query: string) => void }) {
  const filteredLogs = workspace.logs.filter((line) => line.toLowerCase().includes(query.toLowerCase()))
  return (
    <DetailCard title="Logs" description="Latest workspace output">
      <div className="mb-3 flex items-center gap-2">
        <div className="relative min-w-0 flex-1">
          <Search className="pointer-events-none absolute top-2 left-2.5 size-4 text-muted-foreground" />
          <Input aria-label="Search logs" placeholder="Search logs" value={query} onChange={(event) => onQueryChange(event.target.value)} className="pl-8" />
        </div>
        <Button variant="outline" size="sm"><Copy data-icon="inline-start" />Copy all</Button>
      </div>
      <div className="min-h-40 overflow-x-auto rounded-lg bg-muted/55 p-3 font-mono text-xs leading-6">
        {filteredLogs.length > 0 ? filteredLogs.map((line) => <div key={line} className="whitespace-pre text-foreground/85">{line}</div>) : <div className="text-muted-foreground">No logs match “{query}”.</div>}
      </div>
    </DetailCard>
  )
}

function Network({ workspace }: { workspace: ApplicationWorkspace }) {
  return (
    <DetailCard title="Network" description={`Routes for ${workspace.host}`}>
      {workspace.ports.length > 0 ? (
        <div className="divide-y divide-border">
          {workspace.ports.map((port) => (
            <div key={port.port} className="grid grid-cols-[1rem_4rem_minmax(0,1fr)_auto] items-center gap-2 py-2.5 first:pt-0 last:pb-0">
              <span className={cn("size-2 rounded-full", port.active ? "bg-emerald-500" : "bg-muted-foreground/45")} aria-hidden="true" />
              <span className="font-mono text-xs">:{port.port}</span>
              <div className="min-w-0">
                <div className="text-sm font-medium">{port.process}</div>
                <div className="truncate text-xs text-muted-foreground">{port.url ?? "Configured, not active"}</div>
              </div>
              {port.url && <Button variant="ghost" size="icon-sm" aria-label={`Open port ${port.port}`}><ExternalLink /></Button>}
            </div>
          ))}
        </div>
      ) : <p className="text-sm text-muted-foreground">No configured ports for this sandbox.</p>}
    </DetailCard>
  )
}

function ActivityLog({ workspace }: { workspace: ApplicationWorkspace }) {
  return (
    <DetailCard title="Activity" description="Latest 50 workspace operations">
      <div className="divide-y divide-border">
        {workspace.activities.map((item) => (
          <div key={item.id} className="grid grid-cols-[1rem_minmax(0,1fr)_auto] items-start gap-2 py-2.5 first:pt-0 last:pb-0">
            {item.tone === "danger" ? <TriangleAlert className="mt-0.5 size-4 text-destructive" /> : item.tone === "success" ? <Check className="mt-0.5 size-4 text-emerald-600 dark:text-emerald-400" /> : <Activity className="mt-0.5 size-4 text-muted-foreground" />}
            <div className="min-w-0">
              <div className="text-sm font-medium">{item.title}</div>
              <div className="mt-0.5 text-xs text-muted-foreground">{item.detail}</div>
            </div>
            <span className="text-xs text-muted-foreground">{item.time}</span>
          </div>
        ))}
      </div>
    </DetailCard>
  )
}

export function WorkspacesPage({
  workspaces,
  selectedWorkspace,
  section,
  logQuery,
  actions,
  onWorkspaceChange,
  onSectionChange,
  onLogQueryChange,
}: {
  workspaces: ApplicationWorkspace[]
  selectedWorkspace: string
  section: WorkspaceSection
  logQuery: string
  actions: ApplicationActions
  onWorkspaceChange: (workspace: string) => void
  onSectionChange: (section: WorkspaceSection) => void
  onLogQueryChange: (query: string) => void
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
          {section === "summary" && <Summary workspace={workspace} actions={actions} />}
          {section === "files" && <Files workspace={workspace} />}
          {section === "logs" && <Logs workspace={workspace} query={logQuery} onQueryChange={onLogQueryChange} />}
          {section === "network" && <Network workspace={workspace} />}
          {section === "activity" && <ActivityLog workspace={workspace} />}
        </Tabs>
      </div>
    </div>
  )
}
