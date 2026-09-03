import { Archive, Check, FolderOpen, HardDrive, History, RotateCcw } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { PageHeader, SectionHeader } from "@/features/application/components/application-ui"
import type { ApplicationSource } from "@/features/application/model/application-source"

export function BackupPage({ source }: { source: ApplicationSource }) {
  return (
    <div className="mx-auto grid w-full max-w-4xl gap-6 px-4 py-5 sm:px-6 sm:py-6">
      <PageHeader title="Backup" description="Create and restore complete Silo archives with a review step before any workspace changes." />
      <div className="grid gap-3 lg:grid-cols-2">
        <Card size="sm">
          <CardHeader>
            <span className="mb-2 grid size-8 place-items-center rounded-lg bg-muted text-muted-foreground"><Archive className="size-4" /></span>
            <CardTitle>Create backup</CardTitle>
            <CardDescription>Includes workspace code, VM state, databases, Docker data, and guest-side credentials.</CardDescription>
          </CardHeader>
          <CardContent>
            <div className="mb-3 flex items-center gap-2 text-xs text-muted-foreground"><FolderOpen className="size-4" />{source.backup.destination}</div>
            <Button size="sm">Choose destination…</Button>
          </CardContent>
        </Card>
        <Card size="sm">
          <CardHeader>
            <span className="mb-2 grid size-8 place-items-center rounded-lg bg-muted text-muted-foreground"><RotateCcw className="size-4" /></span>
            <CardTitle>Restore archive</CardTitle>
            <CardDescription>Restoring replaces managed state for every configured sandbox and leaves them stopped.</CardDescription>
          </CardHeader>
          <CardContent><Button variant="outline" size="sm">Choose archive…</Button></CardContent>
        </Card>
      </div>
      <section className="grid gap-3">
        <SectionHeader title="Recent backups" />
        <Card size="sm">
          <CardContent className="grid grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-3">
            <span className="grid size-8 place-items-center rounded-full bg-emerald-500/10 text-emerald-600 dark:text-emerald-400"><Check className="size-4" /></span>
            <div className="min-w-0">
              <div className="truncate text-sm font-medium">{source.backup.lastArchive}</div>
              <div className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted-foreground"><span>{source.backup.completedLabel}</span><span>{source.backup.compressedSize}</span><span>3 sandboxes</span></div>
            </div>
            <Button variant="ghost" size="icon-sm" aria-label="Show backup in Finder"><HardDrive /></Button>
          </CardContent>
        </Card>
        <div className="flex items-center gap-2 text-xs text-muted-foreground"><History className="size-4" />Backup history is stored with verified archive metadata.</div>
      </section>
    </div>
  )
}
