import { useEffect, useRef, useState, type ReactNode } from "react"
import { Archive, Check, ChevronDown, Info, LoaderCircle, RotateCcw, TriangleAlert } from "lucide-react"

import { ListRow, ListRowIcon } from "@/components/list-row"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Progress } from "@/components/ui/progress"
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip"
import type { ApplicationSource } from "@/features/application/model/application-source"
import {
  backupDestinationChoices, backupProgressSteps, backupRequiredGB, initialBackupArchive, restoreProgressSteps,
  type BackupArchive, type BackupFixtureMode,
} from "@/fixtures/application-backup"

type Operation = "backup" | "restore"
type Flow =
  | { kind: "idle" }
  | { kind: "destination"; draft: string }
  | { kind: "backup-review" }
  | { kind: "archive-picker"; archive: BackupArchive }
  | { kind: "restore-review"; archive: BackupArchive; confirmation: string }
  | { kind: "invalid-archive"; archive: BackupArchive }
  | { kind: "running"; operation: Operation; archive: BackupArchive; runningNames: string[]; step: number }
  | { kind: "result"; operation: Operation; archive: BackupArchive; runningNames: string[]; outcome: "success" | "failed" | "restart-required" }

interface BackupPageProps {
  source: ApplicationSource
  previewMode?: BackupFixtureMode
  onBusyChange?: (busy: boolean) => void
  onRestoreComplete?: () => void
  onRestartRequired?: (sandboxes: string[]) => void
}

export function BackupPage(props: BackupPageProps) {
  // A replacement backup snapshot clears local previews and their pending timers.
  return <BackupPageContent key={`${JSON.stringify(props.source.backup)}:${props.previewMode ?? "success"}`} {...props} />
}

function InlinePanel({ label, children }: { label: string; children: ReactNode }) {
  return <div role="group" aria-label={label} className="mx-2 grid gap-3 border-t border-border py-3 pr-1 pl-8 text-xs">{children}</div>
}

function BackupPageContent({ source, previewMode = "success", onBusyChange, onRestoreComplete, onRestartRequired }: BackupPageProps) {
  const destinations = backupDestinationChoices(source.backup.destination)
  const [destination, setDestination] = useState(destinations[0])
  const [archives, setArchives] = useState<BackupArchive[]>(() => [initialBackupArchive(source)])
  const [flow, setFlow] = useState<Flow>({ kind: "idle" })
  const [expandedArchive, setExpandedArchive] = useState<string | null>(null)
  const backupButton = useRef<HTMLButtonElement>(null)
  const restoreButton = useRef<HTMLButtonElement>(null)
  const busy = flow.kind === "running"
  const localSandboxes = source.workspaces.filter(({ machine }) => machine.kind === "vm")
  const runningNames = localSandboxes.filter(({ state }) => state === "running").map(({ machine }) => machine.name)
  const backupExpanded = flow.kind === "destination" || flow.kind === "backup-review" || ((flow.kind === "running" || flow.kind === "result") && flow.operation === "backup")
  const restoreExpanded = flow.kind !== "idle" && !backupExpanded

  useEffect(() => {
    onBusyChange?.(busy)
    return () => { if (busy) onBusyChange?.(false) }
  }, [busy, onBusyChange])

  useEffect(() => {
    if (flow.kind !== "running") return
    // UI fixture only. No archive or sandbox is changed outside this preview.
    const timer = window.setTimeout(() => {
      if (flow.step < 3) {
        setFlow({ ...flow, step: flow.step + 1 })
        return
      }
      const failed = previewMode === `${flow.operation}-failed`
      const needsRestart = flow.operation === "backup" && previewMode === "restart-required" && flow.runningNames.length > 0
      if (!failed && flow.operation === "backup") setArchives((current) => [flow.archive, ...current])
      if (!failed && flow.operation === "restore") onRestoreComplete?.()
      if (needsRestart) onRestartRequired?.(flow.runningNames)
      setFlow({ ...flow, kind: "result", outcome: failed ? "failed" : needsRestart ? "restart-required" : "success" })
    }, 1_600)
    return () => window.clearTimeout(timer)
  }, [flow, previewMode, onRestoreComplete, onRestartRequired])

  function closeFlow() {
    setFlow({ kind: "idle" })
    if (backupExpanded) backupButton.current?.focus()
    else restoreButton.current?.focus()
  }

  function startBackup() {
    const archive: BackupArchive = {
      name: `silo-${new Date().toISOString().slice(0, 10)}-${String(archives.length).padStart(3, "0")}.silo-backup`,
      completedLabel: "Just now", size: source.backup.compressedSize, destination: destination.path,
      sandboxes: localSandboxes.map(({ machine }) => machine.name),
    }
    setFlow({ kind: "running", operation: "backup", archive, runningNames, step: 0 })
  }

  function pickArchive(archive = archives[0]) {
    setFlow({ kind: "archive-picker", archive })
  }

  function operationPanel(operation: Operation) {
    if ((flow.kind !== "running" && flow.kind !== "result") || flow.operation !== operation) return null
    if (flow.kind === "running") {
      const step = (operation === "backup" ? backupProgressSteps : restoreProgressSteps)[flow.step]
      return <InlinePanel label={operation === "backup" ? "Backup in progress" : "Restore in progress"}>
        <div className="flex items-start gap-2" role="status">
          <LoaderCircle aria-hidden="true" className="mt-0.5 size-3.5 shrink-0 animate-spin motion-reduce:animate-none text-muted-foreground" />
          <div className="min-w-0 flex-1"><p className="font-medium">{step.title}</p><p className="mt-0.5 text-[11px] text-muted-foreground">{step.detail}</p></div>
          <span className="text-[10px] tabular-nums text-muted-foreground">{step.progress}%</span>
        </div>
        <Progress value={step.progress} aria-label={operation === "backup" ? "Backup progress" : "Restore progress"} />
        <p className="text-[10px] text-muted-foreground">Keep Silo open until this finishes.</p>
      </InlinePanel>
    }
    const failed = flow.outcome === "failed"
    return <InlinePanel label={operation === "backup" ? "Backup result" : "Restore result"}>
      <div role={failed ? "alert" : "status"} className="flex items-start gap-2">
        {failed ? <TriangleAlert aria-hidden="true" className="mt-0.5 size-3.5 shrink-0 text-destructive" /> : <Check aria-hidden="true" className="mt-0.5 size-3.5 shrink-0 text-emerald-600 dark:text-emerald-400" />}
        <div className="min-w-0 space-y-1">
          <p className="font-medium">{operation === "backup" ? "Backup" : "Restore"} {failed ? "failed" : "completed"}</p>
          <p className="text-[11px] text-muted-foreground">{failed
            ? operation === "backup" ? "The destination disconnected while writing. No archive was saved; the previous sandbox running state was restored." : "The restored data could not be verified. Your previous sandbox state was recovered."
            : operation === "backup" ? "Archive saved and checksum verified." : "All restored sandboxes are stopped. Start them from Overview when ready."}</p>
          {!failed && <p className="break-all text-[10px] text-muted-foreground">{flow.archive.destination} / {flow.archive.name}</p>}
          {flow.outcome === "restart-required" && <p className="text-[11px] text-amber-700 dark:text-amber-400">Restart {flow.runningNames.join(", ")} to return to the previous running state. Your backup is valid.</p>}
        </div>
      </div>
      <div className="flex justify-end gap-1">
        <Button variant="ghost" size="xs" onClick={closeFlow}>{failed ? "Dismiss" : "Done"}</Button>
        {failed && <Button variant="outline" size="xs" onClick={() => operation === "backup" ? setFlow({ kind: "backup-review" }) : pickArchive()}>{operation === "backup" ? "Review and retry" : "Choose another archive"}</Button>}
      </div>
    </InlinePanel>
  }

  return (
    <TooltipProvider delayDuration={150}>
      <div className="mx-auto grid w-full max-w-4xl gap-4 px-4 py-5 sm:px-6 sm:py-6" onKeyDown={(event) => {
        if (event.key === "Escape" && flow.kind !== "idle" && !busy) { event.preventDefault(); closeFlow() }
      }}>
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
                    <TooltipTrigger asChild><Button type="button" variant="ghost" size="icon-xs" className="size-4 text-muted-foreground" aria-label="What a backup includes"><Info aria-hidden="true" /></Button></TooltipTrigger>
                    <TooltipContent>Includes sandbox code, VM state, databases, Docker data, and guest-side credentials. macOS Keychain credentials are excluded.</TooltipContent>
                  </Tooltip>
                </>}
                detail={<span title={destination.path}>{destination.path}</span>}
                actions={<div className="flex shrink-0 items-center gap-1">
                  <Button type="button" variant="ghost" size="xs" aria-label="Change backup destination" disabled={busy} aria-expanded={flow.kind === "destination"} aria-controls="backup-details" onClick={() => setFlow({ kind: "destination", draft: destination.path })}>Change…</Button>
                  <Button ref={backupButton} type="button" variant="outline" size="xs" disabled={busy || localSandboxes.length === 0} aria-expanded={backupExpanded && flow.kind !== "destination"} aria-controls="backup-details" onClick={() => setFlow({ kind: "backup-review" })}>Back up</Button>
                </div>}
              />
              <div id="backup-details">
                {flow.kind === "destination" && <InlinePanel label="Backup destination">
                  <fieldset className="grid gap-1">
                    <legend className="mb-2 font-medium">Choose a destination</legend>
                    {destinations.map((choice) => <label key={choice.path} className="flex cursor-pointer items-center gap-2 rounded px-1 py-1.5 hover:bg-muted/50 has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-ring">
                      <input autoFocus={choice.path === destination.path} type="radio" name="backup-destination" className="size-3 accent-primary" checked={flow.draft === choice.path} onChange={() => setFlow({ kind: "destination", draft: choice.path })} />
                      <span className="min-w-0 flex-1"><span className="block text-[11px] font-medium">{choice.name}</span><span className="block truncate text-[10px] text-muted-foreground">{choice.path}</span></span>
                      <span className="shrink-0 text-[10px] text-muted-foreground">{choice.availableGB} GB free</span>
                    </label>)}
                  </fieldset>
                  {(destinations.find(({ path }) => path === flow.draft)?.availableGB ?? 0) < backupRequiredGB
                    ? <p role="alert" className="text-[11px] text-destructive">Not enough space. This backup needs approximately {backupRequiredGB} GB.</p>
                    : <p className="text-[11px] text-muted-foreground">Approximately {backupRequiredGB} GB required. Choosing a folder does not start a backup.</p>}
                  <div className="flex justify-end gap-1">
                    <Button variant="ghost" size="xs" onClick={closeFlow}>Cancel</Button>
                    <Button variant="outline" size="xs" disabled={(destinations.find(({ path }) => path === flow.draft)?.availableGB ?? 0) < backupRequiredGB} onClick={() => {
                      const selected = destinations.find(({ path }) => path === flow.draft)
                      if (selected && selected.availableGB >= backupRequiredGB) { setDestination(selected); closeFlow() }
                    }}>Use folder</Button>
                  </div>
                </InlinePanel>}
                {flow.kind === "backup-review" && <InlinePanel label="Review backup">
                  <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1.5 text-[11px]">
                    <dt className="text-muted-foreground">Destination</dt><dd className="break-all">{destination.path}</dd>
                    <dt className="text-muted-foreground">Space</dt><dd>About {backupRequiredGB} GB required · {destination.availableGB} GB available</dd>
                    <dt className="text-muted-foreground">Sandboxes</dt><dd>{localSandboxes.map(({ machine }) => machine.name).join(", ")}</dd>
                  </dl>
                  <p className="text-[11px] text-muted-foreground">{runningNames.length > 0 ? `${runningNames.join(", ")} will stop briefly and restart after the backup. Stopped sandboxes will stay stopped.` : "All sandboxes are stopped and will stay stopped after the backup."}</p>
                  <div className="flex justify-end gap-1"><Button variant="ghost" size="xs" onClick={closeFlow}>Cancel</Button><Button autoFocus variant="outline" size="xs" onClick={startBackup}>Start backup</Button></div>
                </InlinePanel>}
                {operationPanel("backup")}
              </div>
            </li>
            <li>
              <ListRow
                className="hover:bg-muted/35 focus-within:bg-muted/35"
                icon={<ListRowIcon aria-hidden="true"><RotateCcw className="size-3.5" /></ListRowIcon>}
                title={<h3 className="truncate text-xs font-medium">Restore archive</h3>}
                detail="Replaces all sandbox state and leaves sandboxes stopped."
                detailClassName="whitespace-normal"
                actions={<Button ref={restoreButton} type="button" variant="outline" size="xs" disabled={busy} aria-expanded={restoreExpanded} aria-controls="restore-details" onClick={() => pickArchive()}>Choose archive…</Button>}
              />
              <div id="restore-details">
                {flow.kind === "archive-picker" && <InlinePanel label="Choose an archive">
                  <fieldset className="grid gap-1">
                    <legend className="mb-2 font-medium">Available archives</legend>
                    {archives.map((archive) => <label key={archive.name} className="flex min-w-0 cursor-pointer items-center gap-2 rounded px-1 py-1.5 hover:bg-muted/50 has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-ring">
                      <input autoFocus={archive.name === flow.archive.name} type="radio" name="restore-archive" className="size-3 shrink-0 accent-primary" checked={flow.archive.name === archive.name} onChange={() => pickArchive(archive)} />
                      <span className="min-w-0"><span className="block truncate text-[11px] font-medium">{archive.name}</span><span className="block truncate text-[10px] text-muted-foreground">{archive.destination} · {archive.size}</span></span>
                    </label>)}
                  </fieldset>
                  <div className="flex justify-end gap-1"><Button variant="ghost" size="xs" onClick={closeFlow}>Cancel</Button><Button variant="outline" size="xs" onClick={() => setFlow(previewMode === "invalid-archive" ? { kind: "invalid-archive", archive: flow.archive } : { kind: "restore-review", archive: flow.archive, confirmation: "" })}>Use archive</Button></div>
                </InlinePanel>}
                {flow.kind === "invalid-archive" && <InlinePanel label="Archive validation">
                  <div role="alert" className="space-y-1"><p className="font-medium text-destructive">Checksum mismatch</p><p className="text-[11px] text-muted-foreground">This archive is incomplete or damaged. Choose another copy. No sandbox data has changed.</p></div>
                  <div className="flex justify-end gap-1"><Button variant="ghost" size="xs" onClick={closeFlow}>Cancel</Button><Button variant="outline" size="xs" onClick={() => pickArchive()}>Choose another archive</Button></div>
                </InlinePanel>}
                {flow.kind === "restore-review" && <InlinePanel label="Review restore">
                  <div className="space-y-1"><p className="break-all text-[11px] font-medium">{flow.archive.name}</p><p className="text-[10px] text-muted-foreground">{flow.archive.completedLabel} · {flow.archive.size} · {flow.archive.sandboxes.length} sandboxes</p><p className="flex items-center gap-1 text-[10px] text-emerald-600 dark:text-emerald-400"><Check aria-hidden="true" className="size-3" />Checksum verified</p></div>
                  <p className="text-[11px] text-muted-foreground">Replaces current sandbox data with {flow.archive.sandboxes.join(", ")} from this archive. Changes since the backup will be lost. All restored sandboxes will stay stopped.</p>
                  <div className="flex flex-wrap items-end justify-between gap-3">
                    <label className="grid gap-1.5 text-[11px]">Type RESTORE to confirm<Input autoFocus autoComplete="off" spellCheck={false} className="h-7 w-44 rounded-md text-xs md:text-xs" value={flow.confirmation} onChange={(event) => setFlow({ ...flow, confirmation: event.target.value })} /></label>
                    <div className="flex gap-1"><Button variant="ghost" size="xs" onClick={closeFlow}>Cancel</Button><Button variant="destructive" size="xs" disabled={flow.confirmation !== "RESTORE"} onClick={() => {
                      if (flow.confirmation === "RESTORE") setFlow({ kind: "running", operation: "restore", archive: flow.archive, runningNames, step: 0 })
                    }}>Restore backup</Button></div>
                  </div>
                </InlinePanel>}
                {operationPanel("restore")}
              </div>
            </li>
          </ul>
        </section>
        <section className="grid gap-2" aria-labelledby="backup-history-heading">
          <h3 id="backup-history-heading" className="text-xs font-medium">Recent backups</h3>
          <ul className="divide-y divide-border overflow-hidden rounded-md border border-border" aria-label="Recent backups">
            {archives.map((archive) => <li key={archive.name}>
              <ListRow
                className="hover:bg-muted/35 focus-within:bg-muted/35"
                icon={<ListRowIcon className="bg-emerald-500/10 text-emerald-600 dark:text-emerald-400" role="img" aria-label="Backup completed"><Check className="size-3.5" aria-hidden="true" /></ListRowIcon>}
                title={<span className="truncate text-xs font-medium" title={archive.name}>{archive.name}</span>}
                detail={<>{archive.completedLabel} · {archive.size} · {archive.sandboxes.length} sandboxes</>}
                actions={<Button type="button" variant="ghost" size="icon-xs" className="text-muted-foreground" aria-label={`Details for ${archive.name}`} aria-expanded={expandedArchive === archive.name} onClick={() => setExpandedArchive(expandedArchive === archive.name ? null : archive.name)}><ChevronDown aria-hidden="true" className={expandedArchive === archive.name ? "rotate-180" : ""} /></Button>}
              />
              {expandedArchive === archive.name && <InlinePanel label={`Archive details for ${archive.name}`}>
                <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1.5 text-[11px]"><dt className="text-muted-foreground">Location</dt><dd className="break-all">{archive.destination}</dd><dt className="text-muted-foreground">Sandboxes</dt><dd>{archive.sandboxes.join(", ")}</dd></dl>
                <div className="flex justify-end"><Button variant="outline" size="xs" disabled={busy} onClick={() => pickArchive(archive)}>Restore…</Button></div>
              </InlinePanel>}
            </li>)}
          </ul>
        </section>
      </div>
    </TooltipProvider>
  )
}
