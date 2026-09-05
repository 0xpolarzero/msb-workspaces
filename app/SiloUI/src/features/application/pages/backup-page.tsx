import { Archive, Check, FolderOpen, Info, RotateCcw } from "lucide-react"

import { ListRow, ListRowIcon } from "@/components/list-row"
import { Button } from "@/components/ui/button"
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip"
import type { ApplicationSource } from "@/features/application/model/application-source"

export function BackupPage({ source }: { source: ApplicationSource }) {
  return (
    <TooltipProvider delayDuration={150}>
      <div className="mx-auto grid w-full max-w-4xl gap-4 px-4 py-5 sm:px-6 sm:py-6">
        <section className="grid gap-2">
          <h2 className="text-xs font-medium">Backup</h2>
          <ul className="divide-y divide-border overflow-hidden rounded-md border border-border" aria-label="Backup controls">
            <li>
              <ListRow
                className="hover:bg-muted/35 focus-within:bg-muted/35"
                icon={<ListRowIcon aria-hidden="true"><Archive className="size-3.5" /></ListRowIcon>}
                title={<>
                  <h3 className="truncate text-xs font-medium">Create backup</h3>
                  <Tooltip>
                    <TooltipTrigger asChild>
                      <Button type="button" variant="ghost" size="icon-xs" className="size-4 text-muted-foreground" aria-label="What a backup includes">
                        <Info aria-hidden="true" />
                      </Button>
                    </TooltipTrigger>
                    <TooltipContent>Includes sandbox code, VM state, databases, Docker data, and guest-side credentials.</TooltipContent>
                  </Tooltip>
                </>}
                detail={<span title={source.backup.destination}>{source.backup.destination}</span>}
                actions={<div className="flex shrink-0 items-center gap-1">
                  <Button type="button" variant="ghost" size="xs" aria-label="Change backup destination">Change…</Button>
                  <Button type="button" variant="outline" size="xs">Back up</Button>
                </div>}
              />
            </li>
            <li>
              <ListRow
                className="hover:bg-muted/35 focus-within:bg-muted/35"
                icon={<ListRowIcon aria-hidden="true"><RotateCcw className="size-3.5" /></ListRowIcon>}
                title={<h3 className="truncate text-xs font-medium">Restore archive</h3>}
                detail="Replaces all sandbox state and leaves sandboxes stopped."
                detailClassName="whitespace-normal"
                actions={<Button type="button" variant="outline" size="xs">Choose archive…</Button>}
              />
            </li>
          </ul>
        </section>
        <section className="grid gap-2" aria-labelledby="backup-history-heading">
          <h3 id="backup-history-heading" className="text-xs font-medium">Recent backups</h3>
          <ul className="divide-y divide-border overflow-hidden rounded-md border border-border" aria-label="Recent backups">
            <li>
              <ListRow
                className="hover:bg-muted/35 focus-within:bg-muted/35"
                icon={<ListRowIcon className="bg-emerald-500/10 text-emerald-600 dark:text-emerald-400" role="img" aria-label="Backup completed"><Check className="size-3.5" aria-hidden="true" /></ListRowIcon>}
                title={<span className="truncate text-xs font-medium" title={source.backup.lastArchive}>{source.backup.lastArchive}</span>}
                detail={<>{source.backup.completedLabel} · {source.backup.compressedSize} · 3 sandboxes</>}
                actions={<Tooltip>
                  <TooltipTrigger asChild>
                    <Button type="button" variant="ghost" size="icon-xs" className="text-muted-foreground" aria-label="Show backup in Finder">
                      <FolderOpen aria-hidden="true" />
                    </Button>
                  </TooltipTrigger>
                  <TooltipContent>Show in Finder</TooltipContent>
                </Tooltip>}
              />
            </li>
          </ul>
        </section>
      </div>
    </TooltipProvider>
  )
}
