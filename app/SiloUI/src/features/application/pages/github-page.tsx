import { useState } from "react"
import { Check, GitBranch, LoaderCircle, ShieldCheck } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Checkbox } from "@/components/ui/checkbox"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { InlineNotice, PageHeader, SectionHeader } from "@/features/application/components/application-ui"
import type { ApplicationSource } from "@/features/application/model/application-source"

export function GitHubPage({ source }: { source: ApplicationSource }) {
  const [editing, setEditing] = useState(false)
  const [disabled, setDisabled] = useState(false)
  const [selected, setSelected] = useState(() => new Set(source.workspaces.flatMap((workspace) => workspace.githubRepositories.map((repository) => `${workspace.id}:${repository}`))))

  function toggleRepository(key: string, checked: boolean) {
    setSelected((current) => {
      const next = new Set(current)
      if (checked) next.add(key)
      else next.delete(key)
      return next
    })
  }

  return (
    <div className="mx-auto grid w-full max-w-4xl gap-6 px-4 py-5 sm:px-6 sm:py-6">
      <PageHeader title="GitHub" description="Manage the account and repository access available inside each sandbox." />

      {source.github.state === "disconnected" ? (
        <InlineNotice title="GitHub is not connected" action={<Button size="sm">Connect GitHub</Button>}>
          Connect an account on this Mac before assigning repositories to sandboxes.
        </InlineNotice>
      ) : source.github.state === "connecting" ? (
        <Card size="sm"><CardContent className="flex items-center gap-3"><LoaderCircle className="size-4 animate-spin" /><span className="text-sm">Connecting GitHub account…</span></CardContent></Card>
      ) : (
        <Card size="sm">
          <CardHeader className="grid-cols-[auto_1fr_auto] items-center gap-x-3">
            <span className="grid size-8 place-items-center rounded-full bg-emerald-500/10 text-emerald-600 dark:text-emerald-400"><ShieldCheck className="size-4" /></span>
            <div>
              <CardTitle>Connected as @{source.github.account}</CardTitle>
              <CardDescription>{disabled ? "Repository access is temporarily disabled." : "Host credential is available through Silo's scoped proxy."}</CardDescription>
            </div>
            <Button variant="outline" size="sm" disabled={editing} onClick={() => setDisabled((value) => !value)}>{disabled ? "Enable access" : "Disable access"}</Button>
          </CardHeader>
        </Card>
      )}

      <section className="grid gap-3">
        <SectionHeader
          title="Repository access"
          action={source.github.state === "connected" && !disabled ? (
            editing ? (
              <div className="flex items-center gap-2">
                <Button variant="ghost" size="sm" onClick={() => setEditing(false)}>Cancel</Button>
                <Button size="sm" onClick={() => setEditing(false)}>Save changes</Button>
              </div>
            ) : <Button variant="outline" size="sm" onClick={() => setEditing(true)}>Edit access</Button>
          ) : undefined}
        />
        <div className="grid gap-2">
          {source.workspaces.map((workspace) => (
            <Card key={workspace.id} size="sm" className={disabled ? "opacity-60" : undefined}>
              <CardHeader>
                <CardTitle>{workspace.id}</CardTitle>
                <CardDescription>{workspace.githubRepositories.length} repositories configured</CardDescription>
              </CardHeader>
              <CardContent className="grid gap-2">
                {workspace.githubRepositories.map((repository) => {
                  const key = `${workspace.id}:${repository}`
                  return (
                    <label key={repository} className="flex items-center gap-2 text-sm">
                      {editing && <Checkbox checked={selected.has(key)} onCheckedChange={(checked) => toggleRepository(key, checked === true)} />}
                      {editing ? null : selected.has(key) ? <Check className="size-4 text-emerald-600 dark:text-emerald-400" /> : <span className="size-4" />}
                      <GitBranch className="size-4 text-muted-foreground" />
                      <span className="min-w-0 flex-1 truncate">{repository}</span>
                      <span className="text-xs text-muted-foreground">Clone and pull</span>
                    </label>
                  )
                })}
              </CardContent>
            </Card>
          ))}
        </div>
      </section>
    </div>
  )
}
