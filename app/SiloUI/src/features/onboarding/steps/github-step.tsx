import { useId, useMemo, useState } from "react"
import { Check, GitBranch, Info, LoaderCircle, Search, X } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { Checkbox } from "@/components/ui/checkbox"
import { Input } from "@/components/ui/input"
import { Popover, PopoverAnchor, PopoverContent } from "@/components/ui/popover"
import { ScrollArea } from "@/components/ui/scroll-area"
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip"
import { WorkspaceProgressStrip } from "@/features/onboarding/components/workspace-progress-strip"
import type { WorkspaceProgressView } from "@/features/onboarding/model/onboarding-state"

export type GitHubConnectionState = "disconnected" | "connecting" | "connected"

export interface WorkspaceRepositorySelection {
  repository: string
  allowPushes: boolean
}

export interface WorkspaceGitIdentity {
  name: string
  email: string
  apply: boolean
}

interface RepositoryComboboxProps {
  workspace: string
  repositoryOptions: readonly string[]
  selectedRepositories: readonly WorkspaceRepositorySelection[]
  onAdd: (repository: string) => void
}

function RepositoryCombobox({ workspace, repositoryOptions, selectedRepositories, onAdd }: RepositoryComboboxProps) {
  const listboxId = useId()
  const [open, setOpen] = useState(false)
  const [query, setQuery] = useState("")
  const [activeIndex, setActiveIndex] = useState(0)
  const selectedNames = useMemo(
    () => new Set(selectedRepositories.map(({ repository }) => repository.toLowerCase())),
    [selectedRepositories],
  )
  const results = repositoryOptions.filter((repository) => (
    !selectedNames.has(repository.toLowerCase()) && repository.toLowerCase().includes(query.trim().toLowerCase())
  ))

  function add(repository: string) {
    if (selectedNames.has(repository.toLowerCase())) return
    onAdd(repository)
    setQuery("")
    setActiveIndex(0)
    setOpen(false)
  }

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverAnchor asChild>
        <div className="relative">
          <Search aria-hidden="true" className="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-muted-foreground" />
          <Input
            role="combobox"
            aria-label={`Add repository to ${workspace}`}
            aria-autocomplete="list"
            aria-expanded={open}
            aria-controls={listboxId}
            aria-activedescendant={open && results[activeIndex] ? `${listboxId}-${activeIndex}` : undefined}
            className="pl-8 text-xs"
            placeholder="Search repositories…"
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
                add(results[activeIndex])
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
        aria-label={`Repository results for ${workspace}`}
        className="max-h-[min(15rem,var(--radix-popover-content-available-height))] w-[var(--radix-popover-trigger-width)] overflow-y-auto overscroll-contain p-1"
        onOpenAutoFocus={(event) => event.preventDefault()}
      >
        {results.length > 0 ? results.map((repository, index) => (
          <button
            key={repository}
            id={`${listboxId}-${index}`}
            type="button"
            role="option"
            aria-selected={index === activeIndex}
            className="flex w-full items-center rounded-sm px-2 py-1.5 text-left text-xs outline-none hover:bg-accent focus:bg-accent aria-selected:bg-accent"
            onMouseDown={(event) => event.preventDefault()}
            onMouseEnter={() => setActiveIndex(index)}
            onClick={() => add(repository)}
          >
            <span className="min-w-0 break-all">{repository}</span>
          </button>
        )) : (
          <p className="px-2 py-1.5 text-xs text-muted-foreground">No repositories found.</p>
        )}
      </PopoverContent>
    </Popover>
  )
}

interface GitHubStepProps {
  progress: WorkspaceProgressView
  connectionState: GitHubConnectionState
  repositoryOptions: readonly string[]
  workspaceSelections: Record<string, WorkspaceRepositorySelection[]>
  workspaceIdentities: Record<string, WorkspaceGitIdentity>
  currentHostGitIdentity: { name: string; email: string } | null
  onConnect: () => void
  onWorkspaceSelectionsChange: (workspace: string, selections: WorkspaceRepositorySelection[]) => void
  onWorkspaceIdentityChange: (workspace: string, identity: WorkspaceGitIdentity) => void
  onResetWorkspaceIdentity: (workspace: string) => void
  onViewProgress: () => void
}

export function GitHubStep({
  progress,
  connectionState,
  repositoryOptions,
  workspaceSelections,
  workspaceIdentities,
  currentHostGitIdentity,
  onConnect,
  onWorkspaceSelectionsChange,
  onWorkspaceIdentityChange,
  onResetWorkspaceIdentity,
  onViewProgress,
}: GitHubStepProps) {
  return (
    <section aria-labelledby="github-title" className="mx-auto flex h-full min-h-0 max-w-3xl flex-col">
      <WorkspaceProgressStrip progress={progress} onView={onViewProgress} />
      <div className="mb-5">
        <h2 id="github-title" className="text-xl font-semibold tracking-tight">GitHub</h2>
        <p className="mt-1 text-xs text-muted-foreground">Set a Git identity for each VM. Connect GitHub only to select repository access.</p>
      </div>

      <div className="flex min-h-0 flex-1 flex-col gap-3">
        {connectionState === "disconnected" && (
          <Card className="shrink-0 py-0">
            <CardContent className="flex flex-col items-start gap-3 p-4 sm:flex-row sm:items-center">
              <span className="grid size-9 shrink-0 place-items-center rounded-full bg-muted"><GitBranch className="size-4" /></span>
              <div className="min-w-0 flex-1">
                <h3 className="text-sm font-medium">Not connected</h3>
                <p className="mt-0.5 text-xs text-muted-foreground">Connect to select private repositories and push permissions.</p>
              </div>
              <Button type="button" className="sm:self-center" onClick={onConnect}>Connect GitHub</Button>
            </CardContent>
          </Card>
        )}

        {connectionState === "connecting" && (
          <Card className="shrink-0 py-0" role="status" aria-live="polite">
            <CardContent className="flex items-center gap-3 p-4">
              <span className="grid size-9 shrink-0 place-items-center rounded-full bg-muted"><LoaderCircle className="size-4 animate-spin" /></span>
              <div>
                <h3 className="text-sm font-medium">Connecting to GitHub…</h3>
                <p className="mt-0.5 text-xs text-muted-foreground">Completing the secure browser authorization.</p>
              </div>
            </CardContent>
          </Card>
        )}

        {connectionState === "connected" && (
          <div className="flex shrink-0 items-center gap-3">
            <span className="grid size-9 shrink-0 place-items-center rounded-full bg-emerald-500/10 text-emerald-700 dark:text-emerald-400"><Check className="size-4" /></span>
            <div>
              <h3 className="text-sm font-medium">Connected to GitHub</h3>
              <p className="mt-0.5 text-xs text-muted-foreground">Repository credentials remain scoped to each workspace.</p>
            </div>
          </div>
        )}

        {!currentHostGitIdentity && (
          <p id="host-git-identity-unavailable" className="shrink-0 text-xs text-muted-foreground">
            No host Git identity is available. Enter values manually; Reset is unavailable.
          </p>
        )}

        <ScrollArea className="min-h-0 flex-1 rounded-md border border-border" role="region" aria-label="Workspace Git identity and repository access">
          <div className="divide-y divide-border">
            {progress.workspaces.map(({ name }) => {
              const selections = workspaceSelections[name] ?? []
              const identity = workspaceIdentities[name] ?? { name: "", email: "", apply: true }
              return (
                <div key={name} className="grid gap-3 p-3">
                  <span className="truncate text-xs font-semibold" title={name}>{name}</span>
                  <div className="grid gap-2 rounded-md bg-muted/40 p-2.5">
                    <div className="grid gap-2 sm:grid-cols-2">
                      <label className="grid gap-1 text-[11px] font-medium">
                        Git name
                        <Input
                          aria-label={`Git name for ${name}`}
                          autoComplete="off"
                          value={identity.name}
                          onChange={(event) => onWorkspaceIdentityChange(name, { ...identity, name: event.target.value })}
                        />
                      </label>
                      <label className="grid gap-1 text-[11px] font-medium">
                        Git email
                        <Input
                          aria-label={`Git email for ${name}`}
                          autoComplete="off"
                          inputMode="email"
                          type="email"
                          value={identity.email}
                          onChange={(event) => onWorkspaceIdentityChange(name, { ...identity, email: event.target.value })}
                        />
                      </label>
                    </div>
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <label className="flex items-center gap-2 text-xs">
                        <Checkbox
                          aria-label={`Apply Git identity to ${name}`}
                          checked={identity.apply}
                          onCheckedChange={(checked) => onWorkspaceIdentityChange(name, { ...identity, apply: checked === true })}
                        />
                        Apply identity
                      </label>
                      <Button
                        type="button"
                        variant="outline"
                        size="xs"
                        aria-label={`Reset Git identity for ${name}`}
                        aria-describedby={currentHostGitIdentity ? undefined : "host-git-identity-unavailable"}
                        disabled={!currentHostGitIdentity}
                        onClick={() => onResetWorkspaceIdentity(name)}
                      >
                        Reset
                      </Button>
                    </div>
                  </div>
                  {connectionState === "connected" && (
                    <>
                      <RepositoryCombobox
                        workspace={name}
                        repositoryOptions={repositoryOptions}
                        selectedRepositories={selections}
                        onAdd={(repository) => onWorkspaceSelectionsChange(name, [...selections, { repository, allowPushes: false }])}
                      />
                      {selections.length > 0 && (
                        <div role="table" aria-label={`Selected repositories for ${name}`} className="overflow-hidden rounded-md border border-border">
                          <div role="row" className="grid grid-cols-[minmax(0,1fr)_6.75rem_1.5rem] items-center gap-2 bg-muted/50 px-2 py-1.5 text-[11px] font-medium text-muted-foreground">
                            <span role="columnheader">Repository</span>
                            <span role="columnheader" className="flex items-center justify-center gap-0.5 text-center">
                              Allow pushes
                              <TooltipProvider delayDuration={150}>
                                <Tooltip>
                                  <TooltipTrigger asChild>
                                    <Button type="button" variant="ghost" size="icon-xs" className="size-5" aria-label="About Allow pushes">
                                      <Info aria-hidden="true" className="size-3" />
                                    </Button>
                                  </TooltipTrigger>
                                  <TooltipContent>Checked: the VM can push. Unchecked: it can’t.</TooltipContent>
                                </Tooltip>
                              </TooltipProvider>
                            </span>
                            <span role="columnheader" className="sr-only">Remove</span>
                          </div>
                          {selections.map((selection) => (
                            <div key={selection.repository} role="row" className="grid grid-cols-[minmax(0,1fr)_6.75rem_1.5rem] items-center gap-2 border-t border-border px-2 py-2">
                              <span role="cell" className="min-w-0 break-all text-xs">{selection.repository}</span>
                              <span role="cell" className="flex justify-center">
                                <Checkbox
                                  aria-label={`Allow pushes for ${selection.repository}`}
                                  checked={selection.allowPushes}
                                  onCheckedChange={(checked) => onWorkspaceSelectionsChange(name, selections.map((item) => (
                                    item.repository === selection.repository ? { ...item, allowPushes: checked === true } : item
                                  )))}
                                />
                              </span>
                              <span role="cell">
                                <Button
                                  type="button"
                                  variant="ghost"
                                  size="icon-xs"
                                  aria-label={`Remove ${selection.repository} from ${name}`}
                                  onClick={() => onWorkspaceSelectionsChange(name, selections.filter(({ repository }) => repository !== selection.repository))}
                                >
                                  <X aria-hidden="true" />
                                </Button>
                              </span>
                            </div>
                          ))}
                        </div>
                      )}
                    </>
                  )}
                </div>
              )
            })}
          </div>
        </ScrollArea>
      </div>
    </section>
  )
}
