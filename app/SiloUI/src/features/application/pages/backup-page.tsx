import { Archive, Check, FolderOpen, Info, RotateCcw } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip"
import type { ApplicationSource } from "@/features/application/model/application-source"

export function BackupPage({ source }: { source: ApplicationSource }) {
  return (
    <TooltipProvider delayDuration={150}>
      <div className="mx-auto grid w-full max-w-4xl gap-4 px-4 py-5 sm:px-6 sm:py-6">
        <section className="grid gap-2">
          <h2 className="text-xs font-medium">Backup</h2>
          <div className="divide-y divide-border overflow-hidden rounded-md border border-border">
            <div className="grid min-w-0 grid-cols-[1rem_minmax(0,1fr)] items-center gap-x-2 gap-y-2 px-3 py-2.5 sm:grid-cols-[1rem_minmax(0,1fr)_auto]">
              <Archive className="size-3.5 text-muted-foreground" aria-hidden="true" />
              <div className="min-w-0">
                <div className="flex items-center gap-1">
                  <h3 className="text-xs font-medium">Create backup</h3>
                  <Tooltip>
                    <TooltipTrigger asChild>
                      <Button type="button" variant="ghost" size="icon-xs" className="size-4 text-muted-foreground" aria-label="What a backup includes">
                        <Info aria-hidden="true" />
                      </Button>
                    </TooltipTrigger>
                    <TooltipContent>Includes sandbox code, VM state, databases, Docker data, and guest-side credentials.</TooltipContent>
                  </Tooltip>
                </div>
                <div className="mt-0.5 flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1">
                  <span className="min-w-0 truncate text-[11px] text-muted-foreground" title={source.backup.destination}>{source.backup.destination}</span>
                  <Button type="button" variant="ghost" size="xs" aria-label="Change backup destination">Change…</Button>
                </div>
              </div>
              <Button type="button" size="xs" className="col-start-2 justify-self-start sm:col-start-3 sm:justify-self-end">Back up</Button>
            </div>
            <div className="grid min-w-0 grid-cols-[1rem_minmax(0,1fr)] items-center gap-x-2 gap-y-2 px-3 py-2.5 sm:grid-cols-[1rem_minmax(0,1fr)_auto]">
              <RotateCcw className="size-3.5 text-muted-foreground" aria-hidden="true" />
              <div className="min-w-0">
                <h3 className="text-xs font-medium">Restore archive</h3>
                <p className="mt-1 text-[11px] text-muted-foreground">Replaces all sandbox state and leaves sandboxes stopped.</p>
              </div>
              <Button type="button" variant="outline" size="xs" className="col-start-2 justify-self-start sm:col-start-3 sm:justify-self-end">Choose archive…</Button>
            </div>
          </div>
        </section>
        <section className="grid gap-2" aria-labelledby="backup-history-heading">
          <h3 id="backup-history-heading" className="text-xs font-medium">Recent backups</h3>
          <ul className="divide-y divide-border overflow-hidden rounded-md border border-border" aria-label="Recent backups">
            <li className="flex min-w-0 items-center gap-2 px-3 py-2.5 transition-colors hover:bg-muted/35 focus-within:bg-muted/35">
              <Check className="size-3.5 shrink-0 text-emerald-600 dark:text-emerald-400" role="img" aria-label="Backup completed" />
              <div className="min-w-0 flex-1">
                <div className="truncate text-xs font-medium" title={source.backup.lastArchive}>{source.backup.lastArchive}</div>
                <div className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-muted-foreground"><span>{source.backup.completedLabel}</span><span>{source.backup.compressedSize}</span><span>3 sandboxes</span></div>
              </div>
              <Tooltip>
                <TooltipTrigger asChild>
                  <Button type="button" variant="ghost" size="icon-xs" className="text-muted-foreground" aria-label="Show backup in Finder">
                    <FolderOpen aria-hidden="true" />
                  </Button>
                </TooltipTrigger>
                <TooltipContent>Show in Finder</TooltipContent>
              </Tooltip>
            </li>
          </ul>
        </section>
      </div>
    </TooltipProvider>
  )
}
