import { useId, useMemo, useState, type ReactNode } from "react"
import { Check, GitBranch, Info, LoaderCircle, RotateCcw, Search, X } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { Checkbox } from "@/components/ui/checkbox"
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible"
import { Input } from "@/components/ui/input"
import { Popover, PopoverAnchor, PopoverContent } from "@/components/ui/popover"
import { ScrollArea } from "@/components/ui/scroll-area"
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip"
import { DisclosureIndicator, disclosureTriggerStateClass } from "@/components/disclosure-indicator"

export type GitHubConnectionState = "disconnected" | "connecting" | "connected"

export interface GitHubRepositorySelection {
  repository: string
  allowPushes: boolean
}

export interface GitHubIdentity {
  name: string
  email: string
  apply: boolean
}

export interface GitHubWorkspace {
  name: string
}

interface RepositoryComboboxProps {
  workspace: string
  repositoryOptions: readonly string[]
  selectedRepositories: readonly GitHubRepositorySelection[]
  disabled?: boolean
  onAdd: (repository: string) => void
}

function WorkspaceDisclosure({ name, actions, children }: { name: string; actions?: ReactNode; children: ReactNode }) {
  const [open, setOpen] = useState(true)

  return (
    <Collapsible open={open} onOpenChange={setOpen} className="collapsible-motion">
      <div className="flex h-10 min-w-0 items-center gap-2 px-3">
        <span className="min-w-0 flex-1 truncate text-xs font-semibold" title={name}>{name}</span>
        {actions && <div className="flex shrink-0 items-center gap-1.5">{actions}</div>}
        <CollapsibleTrigger
          aria-label={`${open ? "Collapse" : "Expand"} ${name}`}
          className={`${disclosureTriggerStateClass} grid size-6 shrink-0 place-items-center rounded-md text-muted-foreground transition-colors hover:bg-muted hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/60`}
        >
          <DisclosureIndicator />
        </CollapsibleTrigger>
      </div>
      <CollapsibleContent className="collapsible-content-motion">
        {children}
      </CollapsibleContent>
    </Collapsible>
  )
}

const repositoryGridColumns = "grid-cols-[minmax(0,1fr)_6.75rem_1.5rem]"

function RepositoryCombobox({ workspace, repositoryOptions, selectedRepositories, disabled = false, onAdd }: RepositoryComboboxProps) {
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
    if (disabled || selectedNames.has(repository.toLowerCase())) return
    onAdd(repository)
    setQuery("")
    setActiveIndex(0)
    setOpen(false)
  }

  return (
    <Popover open={!disabled && open} onOpenChange={(nextOpen) => !disabled && setOpen(nextOpen)}>
      <PopoverAnchor asChild>
        <div className="relative">
          <Search aria-hidden="true" className="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-muted-foreground" />
          <Input
            role="combobox"
            aria-label={`Add repository to ${workspace}`}
            aria-autocomplete="list"
            aria-expanded={!disabled && open}
            aria-controls={listboxId}
            aria-activedescendant={open && results[activeIndex] ? `${listboxId}-${activeIndex}` : undefined}
            className="pl-8 text-xs"
            disabled={disabled}
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
            disabled={disabled}
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

export interface GitHubAccessEditorProps {
  workspaces: readonly GitHubWorkspace[]
  connectionState: GitHubConnectionState
  repositoryOptions: readonly string[]
  workspaceSelections: Readonly<Record<string, readonly GitHubRepositorySelection[]>>
  workspaceIdentities: Readonly<Record<string, GitHubIdentity>>
  currentHostGitIdentity: { name: string; email: string } | null
  onConnect: () => void
  onWorkspaceSelectionsChange: (workspace: string, selections: GitHubRepositorySelection[]) => void
  onWorkspaceIdentityChange: (workspace: string, identity: GitHubIdentity) => void
  onResetWorkspaceIdentity: (workspace: string) => void
  connectedTitle?: ReactNode
  connectedDetail?: ReactNode
  connectedActions?: ReactNode
  notice?: ReactNode
  renderWorkspaceActions?: (workspace: GitHubWorkspace) => ReactNode
  footer?: ReactNode
  disabled?: boolean
  repositoryControlsAvailable?: boolean
  busy?: boolean
}

export function GitHubAccessEditor({
  workspaces,
  connectionState,
  repositoryOptions,
  workspaceSelections,
  workspaceIdentities,
  currentHostGitIdentity,
  onConnect,
  onWorkspaceSelectionsChange,
  onWorkspaceIdentityChange,
  onResetWorkspaceIdentity,
  connectedTitle = "Connected to GitHub",
  connectedDetail = "Repository credentials remain scoped to each workspace.",
  connectedActions,
  notice,
  renderWorkspaceActions,
  footer,
  disabled = false,
  repositoryControlsAvailable = true,
  busy = false,
}: GitHubAccessEditorProps) {
  return (
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
        <div className="grid shrink-0 grid-cols-[2.25rem_minmax(0,1fr)] items-center gap-x-3 gap-y-2 sm:grid-cols-[2.25rem_minmax(0,1fr)_auto]">
          <span className="grid size-9 place-items-center rounded-full bg-emerald-500/10 text-emerald-700 dark:text-emerald-400"><Check className="size-4" /></span>
          <div className="min-w-0 flex-1">
            <h3 className="text-sm font-medium">{connectedTitle}</h3>
            <div className="mt-0.5 text-xs text-muted-foreground">{connectedDetail}</div>
          </div>
          {connectedActions && <div className="col-start-2 flex min-w-0 flex-wrap items-center gap-2 sm:col-start-3 sm:row-start-1 sm:flex-nowrap">{connectedActions}</div>}
        </div>
      )}

      {!currentHostGitIdentity && (
        <p id="host-git-identity-unavailable" className="shrink-0 text-xs text-muted-foreground">
          No host Git identity is available. Enter values manually; Reset is unavailable.
        </p>
      )}

      {notice && <div className="shrink-0">{notice}</div>}

      <ScrollArea className="min-h-0 flex-1 rounded-md border border-border" role="region" aria-label="Sandbox Git identity and repository access" aria-busy={busy || undefined}>
        <div className="divide-y divide-border">
          {workspaces.map((workspace) => {
            const { name } = workspace
            const selections = workspaceSelections[name] ?? []
            const identity = workspaceIdentities[name] ?? { name: "", email: "", apply: true }
            const workspaceActions = renderWorkspaceActions?.(workspace)
            return (
              <WorkspaceDisclosure key={name} name={name} actions={workspaceActions}>
                  <div className="grid gap-3 px-3 pb-3">
                    <div
                      role="group"
                      aria-label={`Git identity for ${name}`}
                      data-layout="compact-row"
                      className="flex min-w-0 items-center gap-1.5"
                    >
                      <TooltipProvider delayDuration={150}>
                        <Tooltip>
                          <TooltipTrigger asChild>
                            <span
                              tabIndex={0}
                              aria-label={`About Git identity for ${name}`}
                              className="grid size-4 shrink-0 place-items-center rounded-sm text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/60"
                            >
                              <GitBranch aria-hidden="true" className="size-3.5" />
                            </span>
                          </TooltipTrigger>
                          <TooltipContent>Name and email used for Git commits in this VM.</TooltipContent>
                        </Tooltip>
                      </TooltipProvider>
                      <Input
                        aria-label={`Git name for ${name}`}
                        autoComplete="off"
                        className="h-7 min-w-0 flex-[0.8] rounded-md px-2 text-[11px] md:text-[11px]"
                        placeholder="Name"
                        disabled={disabled}
                        value={identity.name}
                        onChange={(event) => onWorkspaceIdentityChange(name, { ...identity, name: event.target.value })}
                      />
                      <Input
                        aria-label={`Git email for ${name}`}
                        autoComplete="off"
                        className="h-7 min-w-0 flex-[1.2] rounded-md px-2 text-[11px] md:text-[11px]"
                        inputMode="email"
                        placeholder="Email"
                        type="email"
                        disabled={disabled}
                        value={identity.email}
                        onChange={(event) => onWorkspaceIdentityChange(name, { ...identity, email: event.target.value })}
                      />
                      <label className="flex shrink-0 items-center gap-1 text-[11px]">
                        <Checkbox
                          aria-label={`Apply Git identity to ${name}`}
                          checked={identity.apply}
                          disabled={disabled}
                          onCheckedChange={(checked) => onWorkspaceIdentityChange(name, { ...identity, apply: checked === true })}
                        />
                        Apply
                      </label>
                      <TooltipProvider delayDuration={150}>
                        <Tooltip>
                          <TooltipTrigger asChild>
                            <span
                              className="inline-flex shrink-0"
                              tabIndex={currentHostGitIdentity ? undefined : 0}
                              aria-label={currentHostGitIdentity ? undefined : `Reset Git identity for ${name}`}
                            >
                              <Button
                                type="button"
                                variant="ghost"
                                size="icon-xs"
                                aria-label={`Reset Git identity for ${name}`}
                                aria-describedby={currentHostGitIdentity ? undefined : "host-git-identity-unavailable"}
                                disabled={disabled || !currentHostGitIdentity}
                                onClick={() => onResetWorkspaceIdentity(name)}
                              >
                                <RotateCcw aria-hidden="true" className="size-3" />
                              </Button>
                            </span>
                          </TooltipTrigger>
                          <TooltipContent>{`Reset Git identity for ${name}`}</TooltipContent>
                        </Tooltip>
                      </TooltipProvider>
                    </div>
                    {connectionState === "connected" && (
                      <>
                        {repositoryControlsAvailable && (
                          <RepositoryCombobox
                            workspace={name}
                            repositoryOptions={repositoryOptions}
                            selectedRepositories={selections}
                            disabled={disabled}
                            onAdd={(repository) => onWorkspaceSelectionsChange(name, [...selections, { repository, allowPushes: false }])}
                          />
                        )}
                        {selections.length > 0 && (
                          <div role="table" aria-label={`Selected repositories for ${name}`} className="overflow-hidden rounded-md border border-border">
                            <div role="row" className={`grid ${repositoryGridColumns} items-center gap-2 bg-muted/50 px-2 py-1.5 text-left text-[11px] font-medium text-muted-foreground`}>
                              <span role="columnheader">Repository</span>
                              <span role="columnheader" className="flex items-center justify-start gap-0.5 text-left">
                                Allow pushes
                                <TooltipProvider delayDuration={150}>
                                  <Tooltip>
                                    <TooltipTrigger asChild>
                                      <Button type="button" variant="ghost" size="icon-xs" className="size-5" aria-label="About Allow pushes">
                                        <Info aria-hidden="true" className="size-3" />
                                      </Button>
                                    </TooltipTrigger>
                                    <TooltipContent>Allow pushing to this repo from inside this VM.</TooltipContent>
                                  </Tooltip>
                                </TooltipProvider>
                              </span>
                              <span role="columnheader" className="sr-only">Remove</span>
                            </div>
                            {selections.map((selection) => (
                              <div key={selection.repository} role="row" className={`grid ${repositoryGridColumns} items-center gap-2 border-t border-border px-2 py-2 text-left`}>
                                <span role="cell" className="min-w-0 break-all text-xs">{selection.repository}</span>
                                <span role="cell" className="flex justify-start">
                                  <Checkbox
                                    aria-label={`Allow pushes for ${selection.repository}`}
                                    checked={selection.allowPushes}
                                    disabled={disabled || !repositoryControlsAvailable}
                                    onCheckedChange={(checked) => onWorkspaceSelectionsChange(name, selections.map((item) => (
                                      item.repository === selection.repository ? { ...item, allowPushes: checked === true } : item
                                    )))}
                                  />
                                </span>
                                <span role="cell" className="flex justify-start">
                                  <Button
                                    type="button"
                                    variant="ghost"
                                    size="icon-xs"
                                    aria-label={`Remove ${selection.repository} from ${name}`}
                                    disabled={disabled || !repositoryControlsAvailable}
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
              </WorkspaceDisclosure>
            )
          })}
        </div>
      </ScrollArea>

      {footer && <div className="shrink-0">{footer}</div>}
    </div>
  )
}
