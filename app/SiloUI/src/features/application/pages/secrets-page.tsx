import { useEffect, useState } from "react"
import { Box, Check, Globe, KeyRound, Pencil, Plus, RotateCw, Trash2 } from "lucide-react"

import { InlineConfirmation } from "@/components/inline-confirmation"
import { StatusBadge } from "@/components/status-badge"
import { Button } from "@/components/ui/button"
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip"
import { WorkspaceBadge } from "@/features/application/components/application-ui"
import type { ApplicationSource } from "@/features/application/model/application-source"

export function SecretsPage({ source }: { source: ApplicationSource }) {
  const [secrets, setSecrets] = useState(source.secrets)
  const [pendingRemoval, setPendingRemoval] = useState<string | null>(null)

  useEffect(() => {
    // Fixture-only removals reset when a replacement source arrives.
    // oxlint-disable-next-line react/set-state-in-effect
    setSecrets(source.secrets)
    // oxlint-disable-next-line react/set-state-in-effect
    setPendingRemoval(null)
  }, [source.secrets])

  function removeSecret(id: string) {
    if (pendingRemoval !== id) {
      setPendingRemoval(id)
      return
    }
    setSecrets((current) => current.filter((secret) => secret.id !== id))
    setPendingRemoval(null)
  }

  return (
    <div className="mx-auto grid w-full max-w-4xl gap-2 px-4 py-5 sm:px-6 sm:py-6">
      <header className="flex min-w-0 flex-wrap items-center justify-between gap-2">
        <div className="min-w-0">
          <h2 className="text-xs font-medium">Secrets</h2>
          <p className="text-[11px] text-muted-foreground">{secrets.length} configured</p>
        </div>
        <Button type="button" variant="outline" size="xs" aria-label="Add secret">
          <Plus aria-hidden="true" data-icon="inline-start" /> Add
        </Button>
      </header>
      {secrets.length > 0 ? (
        <TooltipProvider delayDuration={150}>
          <ul className="divide-y divide-border overflow-hidden rounded-md border border-border" aria-label="Configured secrets">
            {secrets.map((secret) => {
              const confirmingRemoval = pendingRemoval === secret.id
              const removalLabel = confirmingRemoval ? `Confirm removal of ${secret.name}` : `Remove ${secret.name}`

              return (
                <li key={secret.id} className="flex min-w-0 items-center gap-2 px-3 py-2.5 transition-colors hover:bg-muted/35 focus-within:bg-muted/35">
                  <KeyRound className="size-3.5 shrink-0 text-muted-foreground" aria-hidden="true" />
                  <div className="min-w-0 flex-1">
                    <div className="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1">
                      <h3 className="break-all font-mono text-xs font-medium">{secret.name}</h3>
                      {secret.state === "restart-required" && (
                        <span className="inline-flex items-center gap-1 text-[10px] text-amber-600 dark:text-amber-400">
                          <RotateCw className="size-3" aria-hidden="true" />Restart required
                        </span>
                      )}
                    </div>
                    <div className="mt-1 flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1.5">
                      <div className="flex min-w-0 flex-wrap gap-1" role="group" aria-label={`Sandboxes for ${secret.name}`}>
                        {secret.workspaces.map((name) => {
                          const workspace = source.workspaces.find(({ machine }) => machine.name === name)
                          return workspace
                            ? <WorkspaceBadge key={name} name={name} state={workspace.state} />
                            : <StatusBadge key={name} indicator={<Box className="size-2" />}>{name}</StatusBadge>
                        })}
                      </div>
                      <p className="flex min-w-0 items-start gap-1 text-[11px] text-muted-foreground" aria-label={`Allowed domains for ${secret.name}`}>
                        <Globe className="mt-0.5 size-3 shrink-0" aria-hidden="true" />
                        <span className="break-all">{secret.allowedDomains.join(", ") || "No allowed domains"}</span>
                      </p>
                    </div>
                  </div>
                  <div className="flex shrink-0 items-center gap-0.5 text-muted-foreground" role="group" aria-label={`Manage ${secret.name}`}>
                    <Tooltip>
                      <TooltipTrigger asChild>
                        <Button type="button" variant="ghost" size="icon-xs" aria-label={`Edit ${secret.name}`}>
                          <Pencil aria-hidden="true" />
                        </Button>
                      </TooltipTrigger>
                      <TooltipContent>Edit {secret.name}</TooltipContent>
                    </Tooltip>
                    <InlineConfirmation active={confirmingRemoval} onDismiss={() => setPendingRemoval(null)}>
                      <Tooltip>
                        <TooltipTrigger asChild>
                          <Button type="button" variant={confirmingRemoval ? "destructive" : "ghost"} size="icon-xs" aria-label={removalLabel} onClick={() => removeSecret(secret.id)}>
                            {confirmingRemoval ? <Check aria-hidden="true" /> : <Trash2 aria-hidden="true" />}
                          </Button>
                        </TooltipTrigger>
                        <TooltipContent>{removalLabel}</TooltipContent>
                      </Tooltip>
                    </InlineConfirmation>
                  </div>
                </li>
              )
            })}
          </ul>
        </TooltipProvider>
      ) : <p className="rounded-md border border-border px-3 py-6 text-center text-xs text-muted-foreground">No secrets configured.</p>}
    </div>
  )
}
