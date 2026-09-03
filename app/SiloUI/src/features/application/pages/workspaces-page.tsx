import { Activity, Check, Copy, ExternalLink, File, Folder, GitBranch, Search, TriangleAlert } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { DetailCard, PageHeader, WorkspaceStatus } from "@/features/application/components/application-ui"
import type { ApplicationWorkspace, WorkspaceDetailSection } from "@/features/application/model/application-source"
import { cn } from "@/lib/utils"

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
  onWorkspaceChange,
  onLogQueryChange,
}: {
  workspaces: ApplicationWorkspace[]
  selectedWorkspace: string
  section: WorkspaceDetailSection
  logQuery: string
  onWorkspaceChange: (workspace: string) => void
  onLogQueryChange: (query: string) => void
}) {
  const workspace = workspaces.find((item) => item.machine.id === selectedWorkspace) ?? workspaces[0]

  return (
    <div className="mx-auto grid w-full max-w-4xl gap-5 px-4 py-5 sm:px-6 sm:py-6">
      <PageHeader title="Sandboxes" description="Inspect state, files, logs, networking, and recent activity." />
      <div className="flex min-w-0 gap-2 overflow-x-auto pb-1" aria-label="Choose sandbox">
        {workspaces.map((item) => (
          <button
            key={item.machine.id}
            type="button"
            onClick={() => onWorkspaceChange(item.machine.id)}
            className={cn(
              "flex min-w-36 items-center justify-between gap-3 rounded-lg border px-3 py-2 text-left text-sm transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
              item.machine.id === workspace.machine.id ? "border-foreground/20 bg-muted font-medium" : "border-border bg-card text-muted-foreground hover:bg-muted/60 hover:text-foreground",
            )}
          >
            {item.machine.name}
            <WorkspaceStatus state={item.state} />
          </button>
        ))}
      </div>
      <div>
        <div className="flex items-end justify-between gap-3">
          <div>
            <h3 className="text-base font-semibold">{workspace.machine.name}</h3>
            <p className="mt-1 text-xs text-muted-foreground">{workspace.purpose}</p>
          </div>
          <WorkspaceStatus state={workspace.state} detail={workspace.stateDetail} />
        </div>
        <div className="mt-4">
          {section === "files" && <Files workspace={workspace} />}
          {section === "logs" && <Logs workspace={workspace} query={logQuery} onQueryChange={onLogQueryChange} />}
          {section === "network" && <Network workspace={workspace} />}
          {section === "activity" && <ActivityLog workspace={workspace} />}
        </div>
      </div>
    </div>
  )
}
