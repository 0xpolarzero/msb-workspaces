import type { ApplicationSource } from "@/features/application/model/application-source"

export const backupFixtureModes = ["success", "backup-failed", "restart-required", "invalid-archive", "restore-failed"] as const
export type BackupFixtureMode = (typeof backupFixtureModes)[number]

export function backupFixtureModeFromSearch(search: string): BackupFixtureMode | undefined {
  const requested = new URLSearchParams(search).get("backup-operation")
  return backupFixtureModes.find((mode) => mode === requested)
}

export interface BackupArchive {
  name: string
  completedLabel: string
  size: string
  destination: string
  sandboxes: string[]
}

export function initialBackupArchive(source: ApplicationSource): BackupArchive {
  return {
    name: source.backup.lastArchive,
    completedLabel: source.backup.completedLabel,
    size: source.backup.compressedSize,
    destination: source.backup.destination,
    sandboxes: ["dev", "playgrounds", "personal"],
  }
}

export function backupDestinationChoices(destination: string) {
  return [
    { path: destination, name: "External SSD", availableGB: 412 },
    { path: "~/Backups/silo", name: "Macintosh HD", availableGB: 186 },
    { path: "USB Drive / Silo Backups", name: "USB Drive", availableGB: 12 },
  ].filter((choice, index, choices) => choices.findIndex(({ path }) => path === choice.path) === index)
}

export const backupRequiredGB = 48

export const backupProgressSteps = [
  { title: "Preparing backup", detail: "Flushing data and stopping running sandboxes.", progress: 10 },
  { title: "Writing archive", detail: "Compressing sandbox disks and persistent data.", progress: 45 },
  { title: "Verifying archive", detail: "Checking the archive and writing its checksum.", progress: 78 },
  { title: "Finishing backup", detail: "Restoring the previous sandbox running state.", progress: 95 },
]

export const restoreProgressSteps = [
  { title: "Preparing restore", detail: "Stopping sandboxes and preserving the current state.", progress: 10 },
  { title: "Extracting archive", detail: "Unpacking sandbox disks and persistent data.", progress: 45 },
  { title: "Restoring sandboxes", detail: "Applying the archived configuration and data.", progress: 78 },
  { title: "Verifying restore", detail: "Checking restored sandboxes before finishing.", progress: 95 },
]
