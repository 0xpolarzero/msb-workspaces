import { Globe, KeyRound, RotateCw } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { InlineNotice, PageHeader, SectionHeader } from "@/features/application/components/application-ui"
import type { ApplicationSource } from "@/features/application/model/application-source"

export function SecretsPage({ source }: { source: ApplicationSource }) {
  const restartCount = source.secrets.filter((secret) => secret.state === "restart-required").length

  return (
    <div className="mx-auto grid w-full max-w-4xl gap-6 px-4 py-5 sm:px-6 sm:py-6">
      <PageHeader title="Secrets" description="Manage host-held credentials without exposing their values to the app." action={<Button size="sm">Add secret</Button>} />
      {restartCount > 0 && (
        <InlineNotice title={`${restartCount} secret ${restartCount === 1 ? "change requires" : "changes require"} a restart`}>
          Restart the affected sandbox when you are ready to make the updated value available.
        </InlineNotice>
      )}
      <section className="grid gap-3">
        <SectionHeader title={`${source.secrets.length} configured secrets`} />
        <div className="grid gap-2">
          {source.secrets.map((secret) => (
            <Card key={secret.id} size="sm">
              <CardContent className="grid min-w-0 gap-3 sm:grid-cols-[auto_minmax(0,1fr)_auto] sm:items-center">
                <span className="grid size-8 place-items-center rounded-lg bg-muted text-muted-foreground"><KeyRound className="size-4" /></span>
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <h3 className="font-mono text-sm font-semibold">{secret.name}</h3>
                    {secret.state === "restart-required" && <span className="inline-flex items-center gap-1 text-xs text-amber-600 dark:text-amber-400"><RotateCw className="size-3" />Restart required</span>}
                  </div>
                  <p className="mt-1 text-xs text-muted-foreground">{secret.workspaces.join(", ")} · <Globe className="mr-1 inline size-3" />{secret.allowedDomains.join(", ")}</p>
                </div>
                <div className="flex items-center gap-2">
                  <Button variant="outline" size="sm">Edit</Button>
                  <Button variant="ghost" size="sm" className="text-destructive hover:text-destructive">Remove</Button>
                </div>
              </CardContent>
            </Card>
          ))}
        </div>
      </section>
    </div>
  )
}
