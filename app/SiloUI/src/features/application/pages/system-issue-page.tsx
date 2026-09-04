import { CircleAlert, RefreshCw } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { PageHeader } from "@/features/application/components/application-ui"
import type { ApplicationActions } from "@/features/application/model/application-source"

export function SystemIssuePage({ actions }: { actions: ApplicationActions }) {
  return (
    <div className="mx-auto grid w-full max-w-3xl gap-6 px-4 py-5 sm:px-6 sm:py-6">
      <PageHeader
        title="System issue"
        description="A Silo component needs attention before normal operation can resume."
      />

      <Card size="sm" className="ring-destructive/25">
        <CardHeader className="grid-cols-[auto_minmax(0,1fr)] items-start gap-x-3">
          <span className="row-span-2 grid size-8 place-items-center rounded-lg bg-destructive/10 text-destructive">
            <CircleAlert className="size-4" aria-hidden="true" />
          </span>
          <CardTitle><h3>Silo installation needs repair</h3></CardTitle>
          <CardDescription>Reinstall the bundled Silo runtime and verify its exact command identity.</CardDescription>
        </CardHeader>
        <CardContent className="grid gap-4 border-t border-border pt-3">
          <div className="grid gap-1.5 text-xs text-muted-foreground">
            <p>The repair reinstalls Silo's app-managed runtime, then verifies the activated executable.</p>
            <p>Sandbox configuration, host integration, and GitHub setup are not changed.</p>
          </div>
          <div>
            <Button variant="destructive" onClick={actions.repairRuntime}>
              <RefreshCw aria-hidden="true" />
              Repair Installation
            </Button>
          </div>
        </CardContent>
      </Card>
    </div>
  )
}
