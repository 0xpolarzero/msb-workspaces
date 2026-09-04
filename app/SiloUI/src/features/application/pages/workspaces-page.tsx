import { useEffect, useId, useMemo, useState } from "react"
import { Activity, Check, ChevronRight, CircleAlert, CircleCheck, Copy, ExternalLink, File, Folder, GitBranch, Loader2, RotateCw, Search, TriangleAlert, X } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible"
import { Input } from "@/components/ui/input"
import { Popover, PopoverAnchor, PopoverContent } from "@/components/ui/popover"
import { DetailCard, WorkspaceStateDot, WorkspaceStatus } from "@/features/application/components/application-ui"
import type { ApplicationFileEntry, ApplicationWorkspace, RepositoryPushOperation, WorkspaceDetailSection, WorkspaceState } from "@/features/application/model/application-source"
import { cn } from "@/lib/utils"

function WorkspaceFilterBar({
  workspaces,
  excludedWorkspaceIds,
  onChange,
}: {
  workspaces: ApplicationWorkspace[]
  excludedWorkspaceIds: ReadonlySet<string>
  onChange: (excludedWorkspaceIds: Set<string>) => void
}) {
  const listboxId = useId()
  const [open, setOpen] = useState(false)
  const [query, setQuery] = useState("")
  const [activeIndex, setActiveIndex] = useState(0)
  const selectedWorkspaces = workspaces.filter(({ machine }) => !excludedWorkspaceIds.has(machine.id))
  const results = workspaces.filter(({ machine }) => (
    excludedWorkspaceIds.has(machine.id)
    && machine.name.toLowerCase().includes(query.trim().toLowerCase())
  ))

  function includeWorkspace(id: string) {
    const next = new Set(excludedWorkspaceIds)
    next.delete(id)
    onChange(next)
    setQuery("")
    setActiveIndex(0)
    setOpen(false)
  }

  function excludeWorkspace(id: string) {
    const next = new Set(excludedWorkspaceIds)
    next.add(id)
    onChange(next)
  }

  return (
    <div className="flex min-w-0 flex-wrap items-center gap-2 border-b border-border pb-4" role="group" aria-label="Sandbox filters">
      <Popover open={open} onOpenChange={setOpen}>
        <PopoverAnchor asChild>
          <div className="relative w-48 shrink-0">
            <Search aria-hidden="true" className="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-muted-foreground" />
            <Input
              role="combobox"
              aria-label="Add sandbox filter"
              aria-autocomplete="list"
              aria-expanded={open}
              aria-controls={listboxId}
              aria-activedescendant={open && results[activeIndex] ? `${listboxId}-${activeIndex}` : undefined}
              className="h-8 pl-8 text-xs"
              placeholder="Add sandbox…"
              value={query}
              onFocus={() => setOpen(true)}
              onClick={() => setOpen(true)}
              onChange={(event) => {
                setQuery(event.target.value)
                setActiveIndex(0)
                setOpen(true)
              }}
              onKeyDown={(event) => {
                if (event.key === "ArrowDown") {
                  event.preventDefault()
                  setOpen(true)
                  setActiveIndex((current) => Math.min(current + 1, Math.max(0, results.length - 1)))
                } else if (event.key === "ArrowUp") {
                  event.preventDefault()
                  setActiveIndex((current) => Math.max(0, current - 1))
                } else if (event.key === "Enter" && open && results[activeIndex]) {
                  event.preventDefault()
                  includeWorkspace(results[activeIndex].machine.id)
                } else if (event.key === "Escape") {
                  setOpen(false)
                }
              }}
            />
          </div>
        </PopoverAnchor>
        <PopoverContent
          id={listboxId}
          role="listbox"
          aria-label="Available sandbox filters"
          className="max-h-[min(15rem,var(--radix-popover-content-available-height))] w-[var(--radix-popover-trigger-width)] overflow-y-auto overscroll-contain p-1"
          onOpenAutoFocus={(event) => event.preventDefault()}
        >
          {results.length > 0 ? results.map((workspace, index) => (
            <button
              key={workspace.machine.id}
              id={`${listboxId}-${index}`}
              type="button"
              role="option"
              aria-selected={index === activeIndex}
              className="flex w-full items-center rounded-sm px-2 py-1.5 text-left text-xs outline-none hover:bg-accent focus:bg-accent aria-selected:bg-accent"
              onMouseDown={(event) => event.preventDefault()}
              onMouseEnter={() => setActiveIndex(index)}
              onClick={() => includeWorkspace(workspace.machine.id)}
            >
              {workspace.machine.name}
            </button>
          )) : (
            <p className="px-2 py-1.5 text-xs text-muted-foreground">No sandboxes available.</p>
          )}
        </PopoverContent>
      </Popover>

      <div className="flex min-w-0 flex-1 flex-wrap gap-1.5" aria-label="Selected sandboxes">
        {selectedWorkspaces.map((workspace) => (
          <span key={workspace.machine.id} className="inline-flex h-8 items-center gap-1 rounded-full border border-border bg-muted/55 pl-2.5 pr-1 text-xs font-medium">
            {workspace.machine.name}
            <button
              type="button"
              aria-label={`Remove ${workspace.machine.name}`}
              onClick={() => excludeWorkspace(workspace.machine.id)}
              className="grid size-6 place-items-center rounded-full text-muted-foreground hover:bg-background hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
            >
              <X className="size-3.5" aria-hidden="true" />
            </button>
          </span>
        ))}
      </div>

      <div className="ml-auto flex items-center gap-1">
        <Button variant="ghost" size="xs" disabled={selectedWorkspaces.length === 0} onClick={() => onChange(new Set(workspaces.map(({ machine }) => machine.id)))}>Clear</Button>
        <Button variant="ghost" size="xs" disabled={excludedWorkspaceIds.size === 0} onClick={() => onChange(new Set())}>All</Button>
      </div>
    </div>
  )
}

function EmptyState({ title, description }: { title: string; description: string }) {
  return (
    <div className="grid min-h-48 place-items-center rounded-lg border border-dashed border-border px-6 text-center">
      <div>
        <p className="text-sm font-medium">{title}</p>
        <p className="mt-1 text-xs text-muted-foreground">{description}</p>
      </div>
    </div>
  )
}

function WorkspaceBadge({ name, state }: { name: string; state: WorkspaceState }) {
  const stateLabel = state.charAt(0).toUpperCase() + state.slice(1)
  return (
    <span className="inline-flex h-5 shrink-0 items-center gap-1 rounded-full border border-border bg-muted/45 px-1.5 text-[10px] font-medium text-muted-foreground" aria-label={`${name}, ${stateLabel}`}>
      <WorkspaceStateDot state={state} className="size-1.5" />
      {name}
    </span>
  )
}

function FileTreeEntries({ entries, label }: { entries: ApplicationFileEntry[]; label: string }) {
  return (
    <ul className="grid gap-0.5 border-l border-border pl-3" aria-label={label}>
      {entries.map((entry) => {
        const hasChildren = entry.kind === "folder" && entry.children && entry.children.length > 0
        if (!hasChildren) {
          const Icon = entry.kind === "folder" ? Folder : File
          return (
            <li key={entry.name}>
              <button type="button" className="flex h-8 w-full items-center gap-2 rounded-md px-2 text-left font-mono text-xs hover:bg-muted focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring">
                <span className="size-3.5 shrink-0" aria-hidden="true" />
                <Icon className="size-4 shrink-0 text-muted-foreground" aria-hidden="true" />
                <span className="truncate">{entry.name}</span>
              </button>
            </li>
          )
        }

        return (
          <li key={entry.name}>
            <Collapsible>
              <CollapsibleTrigger className="flex h-8 w-full items-center gap-2 rounded-md px-2 text-left font-mono text-xs hover:bg-muted focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring [&[data-state=open]_.tree-caret]:rotate-90">
                <ChevronRight className="tree-caret size-3.5 shrink-0 text-muted-foreground transition-transform" aria-hidden="true" />
                <Folder className="size-4 shrink-0 text-muted-foreground" aria-hidden="true" />
                <span className="truncate">{entry.name}</span>
              </CollapsibleTrigger>
              <CollapsibleContent className="ml-4">
                <FileTreeEntries entries={entry.children ?? []} label={`${entry.name} contents`} />
              </CollapsibleContent>
            </Collapsible>
          </li>
        )
      })}
    </ul>
  )
}

function WorkspaceFileTree({ workspace }: { workspace: ApplicationWorkspace }) {
  return (
    <li>
      <Collapsible defaultOpen>
        <CollapsibleTrigger className="flex h-9 w-full items-center gap-2 rounded-md px-2 text-left text-sm font-medium hover:bg-muted focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring [&[data-state=open]_.tree-caret]:rotate-90">
          <ChevronRight className="tree-caret size-3.5 shrink-0 text-muted-foreground transition-transform" aria-hidden="true" />
          <Folder className="size-4 shrink-0 text-muted-foreground" aria-hidden="true" />
          <span className="truncate">{workspace.machine.name}</span>
        </CollapsibleTrigger>
        <CollapsibleContent className="ml-4">
          {workspace.files.length > 0
            ? <FileTreeEntries entries={workspace.files} label={`Files in ${workspace.machine.name}`} />
            : <p className="border-l border-border py-1 pl-5 text-xs text-muted-foreground">File browsing is unavailable.</p>}
        </CollapsibleContent>
      </Collapsible>
    </li>
  )
}

function commitLabel(count: number) {
  return `${count} ${count === 1 ? "commit" : "commits"}`
}

function RepositoryPushFeedback({
  operation,
  workspace,
  repositoryPath,
  onRetry,
  onDismiss,
}: {
  operation: RepositoryPushOperation
  workspace: string
  repositoryPath: string
  onRetry: () => void
  onDismiss: (workspace: string, repositoryPath: string) => void
}) {
  useEffect(() => {
    if (operation.status !== "succeeded") return
    const timer = window.setTimeout(() => onDismiss(workspace, repositoryPath), 4_000)
    return () => window.clearTimeout(timer)
  }, [operation.status, onDismiss, repositoryPath, workspace])

  if (operation.status === "pushing") {
    return (
      <div className="flex h-6 items-center gap-1.5 text-xs text-muted-foreground" role="status" aria-live="polite" aria-atomic="true">
        <Loader2 className="size-3.5 animate-spin" aria-hidden="true" />
        Pushing {commitLabel(operation.commitCount)}…
      </div>
    )
  }
  if (operation.status === "succeeded") {
    return (
      <div className="flex h-6 items-center gap-1.5 text-xs text-emerald-700 dark:text-emerald-400" role="status" aria-live="polite" aria-atomic="true">
        <CircleCheck className="size-3.5" aria-hidden="true" />
        Pushed {commitLabel(operation.commitCount)}.
      </div>
    )
  }
  return (
    <Collapsible className="grid w-full gap-1.5">
      <div className="flex min-h-6 min-w-0 flex-wrap items-center gap-1.5" role="alert" aria-live="assertive" aria-atomic="true">
        <CircleAlert className="size-3.5 shrink-0 text-destructive" aria-hidden="true" />
        <span className="min-w-40 flex-1 text-xs text-destructive">{operation.message}</span>
        {operation.diagnosticDetails && (
          <CollapsibleTrigger asChild>
            <Button variant="ghost" size="xs" aria-label={`Toggle push error details for ${repositoryPath}`}>
              Details
            </Button>
          </CollapsibleTrigger>
        )}
        <Button variant="outline" size="xs" onClick={onRetry} aria-label={`Retry push for ${repositoryPath}`}>
          <RotateCw aria-hidden="true" />
          Retry
        </Button>
      </div>
      {operation.diagnosticDetails && (
        <CollapsibleContent>
          <pre className="overflow-auto rounded-md bg-muted px-2.5 py-2 font-mono text-[10px] leading-4 whitespace-pre-wrap text-muted-foreground">{operation.diagnosticDetails}</pre>
        </CollapsibleContent>
      )}
    </Collapsible>
  )
}

function Files({
  workspaces,
  repositoryPushOperations,
  onPushRepository,
  onDismissRepositoryPush,
}: {
  workspaces: ApplicationWorkspace[]
  repositoryPushOperations: RepositoryPushOperation[]
  onPushRepository: (workspace: string, repositoryPath: string, commitCount: number) => void
  onDismissRepositoryPush: (workspace: string, repositoryPath: string) => void
}) {
  if (workspaces.length === 0) return <EmptyState title="No sandboxes selected" description="Select at least one sandbox to browse its files and repositories." />
  const repositories = workspaces.flatMap((workspace) => workspace.repositories.map((repository) => ({ workspace, repository })))
  const pushOperations = new Map(repositoryPushOperations.map((operation) => [`${operation.workspace}:${operation.repositoryPath}`, operation]))

  return (
    <div className="grid gap-6 lg:grid-cols-2 lg:gap-0">
      <section className="min-w-0 lg:pr-5" aria-labelledby="files-repositories-heading">
        <h3 id="files-repositories-heading" className="mb-3 font-heading text-sm font-medium">Repositories</h3>
        {repositories.length > 0 ? (
          <div className="divide-y divide-border" role="list" aria-label="Repositories">
            {repositories.map(({ workspace, repository }) => {
              const operation = pushOperations.get(`${workspace.machine.name}:${repository.path}`)
              const push = () => onPushRepository(workspace.machine.name, repository.path, operation?.commitCount ?? repository.ahead)
              return (
                <div key={`${workspace.machine.id}:${repository.path}`} role="listitem" aria-busy={operation?.status === "pushing" || undefined} className="grid grid-cols-[1rem_minmax(0,1fr)] items-start gap-2 py-2.5 first:pt-0 last:pb-0">
                  <GitBranch className="mt-0.5 size-4 text-muted-foreground" aria-hidden="true" />
                  <div className="min-w-0">
                    <div className="flex min-w-0 items-start justify-between gap-2" data-repository-header>
                      <div className="truncate text-sm font-medium">{repository.path}</div>
                      <WorkspaceBadge name={workspace.machine.name} state={workspace.state} />
                    </div>
                    <div className="mt-0.5 text-xs text-muted-foreground">{repository.branch} · {repository.ahead} ahead, {repository.behind} behind</div>
                    {(operation || repository.ahead > 0) && (
                      <div className="mt-2 flex min-h-6 items-start" data-repository-actions>
                        {operation
                          ? <RepositoryPushFeedback operation={operation} workspace={workspace.machine.name} repositoryPath={repository.path} onRetry={push} onDismiss={onDismissRepositoryPush} />
                          : <Button variant="outline" size="xs" onClick={push}>Push {commitLabel(repository.ahead)}</Button>}
                      </div>
                    )}
                  </div>
                </div>
              )
            })}
          </div>
        ) : <p className="text-xs text-muted-foreground">No repositories checked out.</p>}
      </section>

      <section className="min-w-0 lg:border-l lg:border-border lg:pl-5" aria-labelledby="files-tree-heading">
        <h3 id="files-tree-heading" className="mb-3 font-heading text-sm font-medium">File tree</h3>
        <ul className="grid gap-0.5" aria-label="File tree">
          {workspaces.map((workspace) => <WorkspaceFileTree key={workspace.machine.id} workspace={workspace} />)}
        </ul>
      </section>
    </div>
  )
}

interface LogRow {
  id: string
  raw: string
  timestamp: string
  workspace: string
  message: string
}

function logRows(workspaces: ApplicationWorkspace[]): LogRow[] {
  return workspaces.flatMap((workspace) => workspace.logs.map((line, index) => {
    const match = /^(\S+)\s{2,}(.*)$/.exec(line)
    return {
      id: `${workspace.machine.id}:${index}`,
      raw: line,
      timestamp: match?.[1] ?? "—",
      workspace: workspace.machine.name,
      message: match?.[2] ?? line,
    }
  }))
}

function Logs({ workspaces, query, onQueryChange }: { workspaces: ApplicationWorkspace[]; query: string; onQueryChange: (query: string) => void }) {
  if (workspaces.length === 0) return <EmptyState title="No sandboxes selected" description="Select at least one sandbox to see its logs." />
  const rows = logRows(workspaces)
  const normalizedQuery = query.trim().toLowerCase()
  const filteredRows = rows.filter((row) => !normalizedQuery || `${row.timestamp} ${row.workspace} ${row.message}`.toLowerCase().includes(normalizedQuery))

  return (
    <div>
      <div className="mb-3 flex items-center gap-2">
        <div className="relative min-w-0 flex-1">
          <Search className="pointer-events-none absolute top-2 left-2.5 size-4 text-muted-foreground" aria-hidden="true" />
          <Input aria-label="Search logs" placeholder="Search logs" value={query} onChange={(event) => onQueryChange(event.target.value)} className="pl-8" />
        </div>
        <Button variant="outline" size="sm" disabled={filteredRows.length === 0}><Copy data-icon="inline-start" />Copy all</Button>
      </div>
      {filteredRows.length > 0 ? (
        <div role="table" aria-label="Logs" className="overflow-hidden rounded-lg border border-border text-xs">
          <div role="row" className="grid grid-cols-[5.5rem_7rem_minmax(0,1fr)_1.5rem] gap-3 border-b border-border bg-muted/45 px-3 py-2 font-medium text-muted-foreground">
            <span role="columnheader">Timestamp</span>
            <span role="columnheader">Sandbox</span>
            <span role="columnheader">Message</span>
            <span role="columnheader" className="sr-only">Actions</span>
          </div>
          <div className="max-h-80 divide-y divide-border overflow-y-auto bg-card font-mono">
            {filteredRows.map((row) => (
              <div key={row.id} role="row" className="group/log-row grid grid-cols-[5.5rem_7rem_minmax(0,1fr)_1.5rem] items-center gap-3 px-3 py-2 transition-colors hover:bg-muted/55 focus-within:bg-muted/55">
                <span role="cell" className="text-muted-foreground">{row.timestamp}</span>
                <span role="cell" className="truncate font-medium">{row.workspace}</span>
                <span role="cell" className="min-w-0 break-words text-foreground/85">{row.message}</span>
                <span role="cell">
                  <Button
                    variant="ghost"
                    size="icon-xs"
                    aria-label={`Copy log line from ${row.workspace} at ${row.timestamp}`}
                    className="opacity-0 transition-opacity group-hover/log-row:opacity-100 group-focus-within/log-row:opacity-100 focus-visible:opacity-100"
                    onClick={() => void navigator.clipboard.writeText(row.raw)}
                  >
                    <Copy aria-hidden="true" />
                  </Button>
                </span>
              </div>
            ))}
          </div>
        </div>
      ) : <EmptyState title={normalizedQuery ? "No matching logs" : "No logs yet"} description={normalizedQuery ? `No logs match “${query}”.` : "Logs from the selected sandboxes will appear here."} />}
    </div>
  )
}

function Network({ workspaces }: { workspaces: ApplicationWorkspace[] }) {
  if (workspaces.length === 0) return <EmptyState title="No sandboxes selected" description="Select at least one sandbox to see its network services." />

  return (
    <div className="grid gap-3">
      <p className="text-xs text-muted-foreground">Each sandbox has its own .silo.test address, so the same port can be active in multiple sandboxes.</p>
      {workspaces.map((workspace) => (
        <section key={workspace.machine.id} aria-label={`Network for ${workspace.machine.name}`}>
          <DetailCard title={workspace.machine.name} description={workspace.host} action={<WorkspaceStatus state={workspace.state} />}>
            {workspace.ports.length > 0 ? (
              <div className="divide-y divide-border">
                {workspace.ports.map((port) => (
                  <div key={`${workspace.machine.id}:${port.port}`} className="grid grid-cols-[1rem_4rem_minmax(0,1fr)_auto] items-center gap-2 py-2.5 first:pt-0 last:pb-0">
                    <span className={cn("size-2 rounded-full", port.active ? "bg-emerald-500" : "bg-muted-foreground/45")} aria-hidden="true" />
                    <span className="font-mono text-xs">:{port.port}</span>
                    <div className="min-w-0">
                      <div className="text-sm font-medium">{port.process}</div>
                      <div className="truncate text-xs text-muted-foreground">{port.url ?? "Configured, not active"}</div>
                    </div>
                    {port.url && <Button variant="ghost" size="icon-sm" aria-label={`Open ${workspace.machine.name} port ${port.port}`}><ExternalLink /></Button>}
                  </div>
                ))}
              </div>
            ) : <p className="text-sm text-muted-foreground">No configured ports.</p>}
          </DetailCard>
        </section>
      ))}
    </div>
  )
}

function ActivityLog({ workspaces }: { workspaces: ApplicationWorkspace[] }) {
  if (workspaces.length === 0) return <EmptyState title="No sandboxes selected" description="Select at least one sandbox to see its activity." />
  const activities = workspaces.flatMap((workspace) => workspace.activities.map((activity) => ({ ...activity, workspace: workspace.machine.name })))

  return (
    <DetailCard title="Activity">
      {activities.length > 0 ? (
        <div className="divide-y divide-border" role="list" aria-label="Recent activity">
          {activities.map((item) => (
            <div key={`${item.workspace}:${item.id}`} role="listitem" className="grid grid-cols-[1rem_minmax(0,1fr)_auto] items-start gap-2 py-2.5 first:pt-0 last:pb-0">
              {item.tone === "danger" ? <TriangleAlert className="mt-0.5 size-4 text-destructive" aria-hidden="true" /> : item.tone === "success" ? <Check className="mt-0.5 size-4 text-emerald-600 dark:text-emerald-400" aria-hidden="true" /> : <Activity className="mt-0.5 size-4 text-muted-foreground" aria-hidden="true" />}
              <div className="min-w-0">
                <div className="text-sm font-medium">{item.title}</div>
                <div className="mt-0.5 text-xs font-medium text-muted-foreground">{item.workspace}</div>
                <div className="mt-0.5 text-xs text-muted-foreground">{item.detail}</div>
              </div>
              <span className="text-xs text-muted-foreground">{item.time}</span>
            </div>
          ))}
        </div>
      ) : <p className="text-sm text-muted-foreground">No recent activity.</p>}
    </DetailCard>
  )
}

export function WorkspacesPage({
  workspaces,
  excludedWorkspaceIds,
  section,
  logQuery,
  repositoryPushOperations,
  onWorkspaceFilterChange,
  onLogQueryChange,
  onPushRepository,
  onDismissRepositoryPush,
}: {
  workspaces: ApplicationWorkspace[]
  excludedWorkspaceIds: ReadonlySet<string>
  section: WorkspaceDetailSection
  logQuery: string
  repositoryPushOperations: RepositoryPushOperation[]
  onWorkspaceFilterChange: (excludedWorkspaceIds: Set<string>) => void
  onLogQueryChange: (query: string) => void
  onPushRepository: (workspace: string, repositoryPath: string, commitCount: number) => void
  onDismissRepositoryPush: (workspace: string, repositoryPath: string) => void
}) {
  const visibleWorkspaces = useMemo(
    () => workspaces.filter(({ machine }) => !excludedWorkspaceIds.has(machine.id)),
    [workspaces, excludedWorkspaceIds],
  )

  return (
    <div className="mx-auto grid w-full max-w-5xl gap-4 px-4 py-5 sm:px-6 sm:py-6">
      <WorkspaceFilterBar workspaces={workspaces} excludedWorkspaceIds={excludedWorkspaceIds} onChange={onWorkspaceFilterChange} />
      {section === "files" && <Files workspaces={visibleWorkspaces} repositoryPushOperations={repositoryPushOperations} onPushRepository={onPushRepository} onDismissRepositoryPush={onDismissRepositoryPush} />}
      {section === "logs" && <Logs workspaces={visibleWorkspaces} query={logQuery} onQueryChange={onLogQueryChange} />}
      {section === "network" && <Network workspaces={visibleWorkspaces} />}
      {section === "activity" && <ActivityLog workspaces={visibleWorkspaces} />}
    </div>
  )
}
