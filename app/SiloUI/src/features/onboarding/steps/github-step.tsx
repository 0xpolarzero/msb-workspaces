import { Check, GitBranch, LoaderCircle } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { ScrollArea } from "@/components/ui/scroll-area"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { WorkspaceProgressStrip } from "@/features/onboarding/components/workspace-progress-strip"
import type { WorkspaceProgressView } from "@/features/onboarding/model/onboarding-state"

export type GitHubConnectionState = "disconnected" | "connecting" | "connected"
export type RepositoryPermission = "read-only" | "read-write"

export interface WorkspaceRepositoryAccess {
  repository: string | null
  permission: RepositoryPermission
}

interface GitHubStepProps {
  progress: WorkspaceProgressView
  connectionState: GitHubConnectionState
  repositoryOptions: readonly string[]
  workspaceAccess: Record<string, WorkspaceRepositoryAccess>
  onConnect: () => void
  onWorkspaceAccessChange: (workspace: string, access: WorkspaceRepositoryAccess) => void
  onViewProgress: () => void
}

export function GitHubStep({
  progress,
  connectionState,
  repositoryOptions,
  workspaceAccess,
  onConnect,
  onWorkspaceAccessChange,
  onViewProgress,
}: GitHubStepProps) {
  return (
    <section aria-labelledby="github-title" className="mx-auto max-w-3xl">
      <WorkspaceProgressStrip progress={progress} onView={onViewProgress} />
      <div className="mb-5">
        <h2 id="github-title" className="text-xl font-semibold tracking-tight">GitHub access</h2>
      </div>

      {connectionState === "disconnected" && (
        <Card className="py-0">
          <CardContent className="flex items-center gap-3 p-4">
            <span className="grid size-9 shrink-0 place-items-center rounded-full bg-muted"><GitBranch className="size-4" /></span>
            <div className="min-w-0 flex-1">
              <h3 className="text-sm font-medium">Not connected</h3>
              <p className="mt-0.5 text-xs text-muted-foreground">Connect to select private repositories and push permissions.</p>
            </div>
            <Button type="button" onClick={onConnect}>Connect GitHub</Button>
          </CardContent>
        </Card>
      )}

      {connectionState === "connecting" && (
        <Card className="py-0" role="status" aria-live="polite">
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
        <Card className="py-0">
          <CardContent className="p-4">
            <div className="flex items-center gap-3">
              <span className="grid size-9 shrink-0 place-items-center rounded-full bg-emerald-500/10 text-emerald-700 dark:text-emerald-400"><Check className="size-4" /></span>
              <div>
                <h3 className="text-sm font-medium">Connected to GitHub</h3>
                <p className="mt-0.5 text-xs text-muted-foreground">Repository credentials remain scoped to each workspace.</p>
              </div>
            </div>

            <div className="mt-4 border-t border-border pt-4">
              <div className="mb-2 grid gap-1 sm:grid-cols-[minmax(7rem,1fr)_minmax(11rem,1.4fr)_minmax(8rem,0.8fr)] sm:px-3">
                <span className="text-xs font-medium">Workspace repository access</span>
                <span className="hidden text-[11px] font-medium text-muted-foreground sm:block">Repository</span>
                <span className="hidden text-[11px] font-medium text-muted-foreground sm:block">Permission</span>
              </div>
              <ScrollArea className="h-72 rounded-md border border-border" role="region" aria-label="Workspace repository access">
                <div className="divide-y divide-border">
                  {progress.workspaces.map(({ name }) => {
                    const access = workspaceAccess[name] ?? { repository: null, permission: "read-only" as const }
                    return (
                      <div key={name} className="grid gap-2 p-3 sm:grid-cols-[minmax(7rem,1fr)_minmax(11rem,1.4fr)_minmax(8rem,0.8fr)] sm:items-center">
                        <span className="truncate text-xs font-medium" title={name}>{name}</span>
                        <Select
                          value={access.repository ?? "none"}
                          onValueChange={(repository) => onWorkspaceAccessChange(name, { ...access, repository: repository === "none" ? null : repository })}
                        >
                          <SelectTrigger aria-label={`Repository for ${name}`}><SelectValue /></SelectTrigger>
                          <SelectContent>
                            <SelectItem value="none">No access</SelectItem>
                            {repositoryOptions.map((repository) => <SelectItem key={repository} value={repository}>{repository}</SelectItem>)}
                          </SelectContent>
                        </Select>
                        <Select
                          value={access.permission}
                          disabled={access.repository === null}
                          onValueChange={(permission) => onWorkspaceAccessChange(name, { ...access, permission: permission as RepositoryPermission })}
                        >
                          <SelectTrigger aria-label={`Permission for ${name}`}><SelectValue /></SelectTrigger>
                          <SelectContent>
                            <SelectItem value="read-only">Read only</SelectItem>
                            <SelectItem value="read-write">Allow pushes</SelectItem>
                          </SelectContent>
                        </Select>
                      </div>
                    )
                  })}
                </div>
              </ScrollArea>
            </div>
          </CardContent>
        </Card>
      )}
    </section>
  )
}
