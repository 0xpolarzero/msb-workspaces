import type { ApplicationActivity, ApplicationActivityCategory } from "@/features/application/model/application-source"

export const activityFixtureModes = [
  "catalog",
  "sandbox-live",
  "git-live",
  "backup-live",
  "secrets-live",
  "github-live",
  "system-live",
] as const

export type ActivityFixtureMode = (typeof activityFixtureModes)[number]

type CompletedActivity = Omit<ApplicationActivity, "occurredAt" | "time" | "status">

const fixtureNow = Date.parse("2026-09-04T16:00:00Z")

function completed(index: number, activity: CompletedActivity): ApplicationActivity {
  return {
    ...activity,
    occurredAt: new Date(fixtureNow - index * 60_000).toISOString(),
    time: index === 0 ? "Now" : `${index}m ago`,
    status: "completed",
  }
}

function live(
  id: string,
  category: ApplicationActivityCategory,
  title: string,
  detail: string,
  workspace?: string,
  progress?: number,
  progressLabel?: string,
  tone: ApplicationActivity["tone"] = "neutral",
  status: ApplicationActivity["status"] = "running",
): ApplicationActivity {
  return {
    id,
    category,
    title,
    detail,
    workspace,
    progress,
    progressLabel,
    tone,
    status,
    occurredAt: "2026-09-04T16:00:00.000Z",
    time: status === "running" ? "Now" : "Just now",
  }
}

export const defaultApplicationActivities: ApplicationActivity[] = [
  completed(1, { id: "dev-start", category: "sandbox", title: "Start verified", detail: "A fresh observation confirmed that the sandbox is running.", workspace: "dev", tone: "success" }),
  completed(2, { id: "playgrounds-stop", category: "sandbox", title: "Stop verified", detail: "A fresh observation confirmed that the sandbox is stopped.", workspace: "playgrounds", tone: "success" }),
  completed(3, { id: "dev-push", category: "git", title: "Push completed", detail: "Pushed 3 commits from acme/silo on main.", workspace: "dev", tone: "success" }),
  completed(4, { id: "personal-backup", category: "backup", title: "Backup completed", detail: "Archive verification passed.", tone: "success" }),
]

export const activityCatalog: ApplicationActivity[] = [
  completed(1, { id: "catalog-state-changed", category: "sandbox", title: "State changed", detail: "Silo returned updated state for 3 sandboxes.", tone: "neutral" }),
  completed(2, { id: "catalog-start-verified", category: "sandbox", title: "Start verified", detail: "A fresh observation confirmed that the sandbox is running.", workspace: "dev", tone: "success" }),
  completed(3, { id: "catalog-stop-verified", category: "sandbox", title: "Stop verified", detail: "A fresh observation confirmed that the sandbox is stopped.", workspace: "playgrounds", tone: "success" }),
  completed(4, { id: "catalog-restart-verified", category: "sandbox", title: "Restart verified", detail: "The sandbox returned to a fresh running state.", workspace: "dev", tone: "success" }),
  completed(5, { id: "catalog-start-failed", category: "sandbox", title: "Start failed", detail: "The sandbox could not mount its workspace storage.", workspace: "dev", tone: "danger" }),
  completed(6, { id: "catalog-stop-failed", category: "sandbox", title: "Stop failed", detail: "The sandbox did not stop before the operation timed out.", workspace: "playgrounds", tone: "danger" }),
  completed(7, { id: "catalog-restart-failed", category: "sandbox", title: "Restart failed", detail: "The sandbox did not return to a running state.", workspace: "dev", tone: "danger" }),
  completed(8, { id: "catalog-restart-unknown", category: "sandbox", title: "Restart outcome unknown", detail: "The command completed, but a fresh observation was unavailable.", workspace: "dev", tone: "warning" }),
  completed(9, { id: "catalog-lifecycle-loss", category: "sandbox", title: "Sandbox stopped unexpectedly", detail: "A fresh observation shows that the sandbox is no longer running.", workspace: "personal", tone: "warning" }),
  completed(10, { id: "catalog-quarantined", category: "sandbox", title: "Sandbox quarantined", detail: "Credential safety could not be verified. Actions remain blocked.", workspace: "playgrounds", tone: "danger" }),
  completed(11, { id: "catalog-unavailable", category: "sandbox", title: "Sandbox unavailable", detail: "The latest state observation failed. The previous snapshot is shown.", workspace: "dev", tone: "warning" }),
  completed(12, { id: "catalog-recovered", category: "sandbox", title: "Sandbox recovered", detail: "Fresh state is available again.", workspace: "dev", tone: "success" }),
  completed(13, { id: "catalog-added", category: "sandbox", title: "Sandbox added", detail: "The new sandbox passed configuration and verification.", workspace: "personal", tone: "success" }),
  completed(14, { id: "catalog-config-updated", category: "sandbox", title: "Sandbox configuration updated", detail: "CPU, memory, and storage settings were applied.", workspace: "dev", tone: "success" }),
  completed(15, { id: "catalog-removed", category: "sandbox", title: "Sandbox removed", detail: "The VM root was removed and persistent volumes were retained.", workspace: "playgrounds", tone: "neutral" }),
  completed(16, { id: "catalog-network-ready", category: "sandbox", title: "Networking ready", detail: "Candidate networking passed readiness checks.", workspace: "dev", tone: "success" }),
  completed(17, { id: "catalog-network-failed", category: "sandbox", title: "Networking failed", detail: "Candidate forwarding did not become ready.", workspace: "playgrounds", tone: "danger" }),
  completed(18, { id: "catalog-verification-passed", category: "sandbox", title: "Verification passed", detail: "The sandbox passed deep verification.", workspace: "dev", tone: "success" }),
  completed(19, { id: "catalog-verification-failed", category: "sandbox", title: "Verification failed", detail: "The sandbox failed its storage check.", workspace: "playgrounds", tone: "danger" }),
  completed(20, { id: "catalog-host-approval", category: "sandbox", title: "Host approval required", detail: "Approve the Silo host helper before setup can continue.", tone: "warning" }),
  completed(21, { id: "catalog-setup-complete", category: "sandbox", title: "Setup completed", detail: "Configuration was committed after deep verification.", tone: "success" }),
  completed(22, { id: "catalog-setup-failed", category: "sandbox", title: "Setup failed", detail: "The staged configuration was discarded safely.", tone: "danger" }),

  completed(23, { id: "catalog-push-complete", category: "git", title: "Push completed", detail: "Pushed 2 commits from acme/silo on main.", workspace: "dev", tone: "success" }),
  completed(24, { id: "catalog-push-failed", category: "git", title: "Push failed", detail: "The remote branch changed after review.", workspace: "dev", tone: "danger" }),
  completed(25, { id: "catalog-push-blocked", category: "git", title: "Push blocked", detail: "Repository policy does not allow this push.", workspace: "dev", tone: "warning" }),
  completed(26, { id: "catalog-push-unknown", category: "git", title: "Push outcome unknown", detail: "The push returned without authoritative reconciliation.", workspace: "dev", tone: "warning" }),
  completed(27, { id: "catalog-clone-complete", category: "git", title: "Clone completed", detail: "Cloned acme/design-system into the workspace.", workspace: "dev", tone: "success" }),
  completed(28, { id: "catalog-clone-failed", category: "git", title: "Clone failed", detail: "Repository access could not be verified.", workspace: "dev", tone: "danger" }),
  completed(29, { id: "catalog-pull-complete", category: "git", title: "Pull completed", detail: "Updated acme/platform-tools on main.", workspace: "playgrounds", tone: "success" }),
  completed(30, { id: "catalog-pull-failed", category: "git", title: "Pull failed", detail: "Local changes prevented a safe update.", workspace: "dev", tone: "danger" }),

  completed(31, { id: "catalog-backup-complete", category: "backup", title: "Backup completed", detail: "The archive and checksum were written successfully.", tone: "success" }),
  completed(32, { id: "catalog-backup-restart", category: "backup", title: "Backup completed · restart required", detail: "The archive is valid. Restart dev to restore its previous running state.", tone: "warning" }),
  completed(33, { id: "catalog-backup-failed", category: "backup", title: "Backup failed", detail: "The destination became unavailable while writing the archive.", tone: "danger" }),
  completed(34, { id: "catalog-restore-complete", category: "backup", title: "Restore completed", detail: "Every sandbox was observed fresh and stopped.", tone: "success" }),
  completed(35, { id: "catalog-restore-unknown", category: "backup", title: "Restore outcome unknown", detail: "The archive was applied, but restored state could not be verified.", tone: "warning" }),
  completed(36, { id: "catalog-restore-failed", category: "backup", title: "Restore failed", detail: "The archive checksum did not match.", tone: "danger" }),

  completed(37, { id: "catalog-secret-added", category: "secrets", title: "Secret added", detail: "PACKAGE_TOKEN was assigned to 2 sandboxes.", tone: "success" }),
  completed(38, { id: "catalog-secret-edited", category: "secrets", title: "Secret updated", detail: "DATABASE_URL metadata and value were replaced.", workspace: "dev", tone: "success" }),
  completed(39, { id: "catalog-secret-removed", category: "secrets", title: "Secret removed", detail: "The binding was verified absent before its value was deleted.", workspace: "playgrounds", tone: "success" }),
  completed(40, { id: "catalog-secret-failed", category: "secrets", title: "Secret change failed", detail: "The reviewed change could not be applied.", workspace: "dev", tone: "danger" }),
  completed(41, { id: "catalog-secret-restart", category: "secrets", title: "Secret restart required", detail: "Restart dev to apply the pending secret generation.", workspace: "dev", tone: "warning" }),
  completed(42, { id: "catalog-secret-next-start", category: "secrets", title: "Secret applies on next start", detail: "The stopped sandbox will receive the change when it starts.", workspace: "personal", tone: "neutral" }),
  completed(43, { id: "catalog-secret-removal-pending", category: "secrets", title: "Secret removal pending restart", detail: "Restart playgrounds to verify that the old binding is absent.", workspace: "playgrounds", tone: "warning" }),
  completed(44, { id: "catalog-secret-restart-complete", category: "secrets", title: "Secret restart completed", detail: "Every affected sandbox now reports the active generation.", tone: "success" }),
  completed(45, { id: "catalog-secret-verification-failed", category: "secrets", title: "Secret verification failed", detail: "The sandbox restarted, but the secret state remained pending.", workspace: "dev", tone: "danger" }),

  completed(46, { id: "catalog-github-connected", category: "github", title: "GitHub connected", detail: "Connected account taylor.", tone: "success" }),
  completed(47, { id: "catalog-github-disconnected", category: "github", title: "GitHub disconnected", detail: "Workspace grants were removed before the account was disconnected.", tone: "neutral" }),
  completed(48, { id: "catalog-auth-denied", category: "github", title: "Authorization denied", detail: "GitHub denied the device authorization request.", tone: "danger" }),
  completed(49, { id: "catalog-auth-expired", category: "github", title: "Authorization expired", detail: "Start a new authorization session to continue.", tone: "warning" }),
  completed(50, { id: "catalog-auth-cancelled", category: "github", title: "Authorization cancelled", detail: "Existing access stayed unchanged.", tone: "neutral" }),
  completed(51, { id: "catalog-auth-failed", category: "github", title: "Authorization failed", detail: "GitHub could not be reached.", tone: "danger" }),
  completed(52, { id: "catalog-access-applied", category: "github", title: "GitHub access applied", detail: "The verified repository scope is active.", workspace: "dev", tone: "success" }),
  completed(53, { id: "catalog-access-delayed", category: "github", title: "GitHub access delayed", detail: "The policy is saved locally and Silo will keep trying.", workspace: "dev", tone: "warning" }),
  completed(54, { id: "catalog-access-failed", category: "github", title: "GitHub access failed", detail: "The saved policy could not be applied.", workspace: "dev", tone: "danger" }),
  completed(55, { id: "catalog-sync-cancelled", category: "github", title: "GitHub sync cancelled", detail: "The saved choices remain available for retry.", workspace: "dev", tone: "neutral" }),
  completed(56, { id: "catalog-grant-stored", category: "github", title: "Grant stored", detail: "A verified scoped installation grant was stored.", workspace: "dev", tone: "success" }),
  completed(57, { id: "catalog-grant-renewed", category: "github", title: "Grant renewed", detail: "The short-lived workspace grant was replaced.", workspace: "dev", tone: "success" }),
  completed(58, { id: "catalog-grant-revoked", category: "github", title: "Grant revoked", detail: "The local workspace credential was removed.", workspace: "dev", tone: "neutral" }),
  completed(59, { id: "catalog-grant-quarantined", category: "github", title: "Grant quarantined", detail: "Credential removal could not be proven.", workspace: "dev", tone: "danger" }),
  completed(60, { id: "catalog-recovery-changed", category: "github", title: "Credential recovery changed", detail: "The workspace now needs authorization.", workspace: "dev", tone: "warning" }),
  completed(61, { id: "catalog-identity-updated", category: "github", title: "Git identity updated", detail: "The configured name and email were applied.", tone: "success" }),

  completed(62, { id: "catalog-runtime-installed", category: "system", title: "Runtime installed", detail: "The bundled Silo toolchain was activated.", tone: "success" }),
  completed(63, { id: "catalog-configuration-installed", category: "system", title: "Default configuration installed", detail: "The bundled default configuration is active.", tone: "success" }),
  completed(64, { id: "catalog-runtime-verified", category: "system", title: "Runtime verification passed", detail: "The activated command identity and handshake were verified.", tone: "success" }),
  completed(65, { id: "catalog-runtime-verification-failed", category: "system", title: "Runtime verification failed", detail: "The activated command did not pass its handshake.", tone: "danger" }),
  completed(66, { id: "catalog-repair-complete", category: "system", title: "Runtime repair completed", detail: "The runtime and default configuration are ready.", tone: "success" }),
  completed(67, { id: "catalog-repair-failed", category: "system", title: "Runtime repair failed", detail: "The bundled runtime could not be verified after installation.", tone: "danger" }),
  completed(68, { id: "catalog-health-passed", category: "system", title: "Health checks passed", detail: "Every required preflight check passed.", tone: "success" }),
  completed(69, { id: "catalog-health-failed", category: "system", title: "Health check failed", detail: "Workspace storage needs repair.", tone: "danger" }),
  completed(70, { id: "catalog-health-unavailable", category: "system", title: "Health check unavailable", detail: "The runtime could not answer this check.", tone: "warning" }),
  completed(71, { id: "catalog-port-conflict", category: "system", title: "Published port conflict", detail: "Port 5173 is already in use and was skipped.", workspace: "dev", tone: "warning" }),
  completed(72, { id: "catalog-port-cleared", category: "system", title: "Published port conflict cleared", detail: "Port 5173 is available again.", workspace: "dev", tone: "success" }),
  completed(73, { id: "catalog-clean-complete", category: "system", title: "Clean completed", detail: "Managed temporary state was removed.", workspace: "dev", tone: "success" }),
  completed(74, { id: "catalog-clean-failed", category: "system", title: "Clean failed", detail: "Managed state could not be removed safely.", workspace: "dev", tone: "danger" }),
  completed(75, { id: "catalog-resize-complete", category: "system", title: "Sandbox resized", detail: "The new memory and CPU limits are effective.", workspace: "dev", tone: "success" }),
  completed(76, { id: "catalog-resize-failed", category: "system", title: "Resize failed", detail: "The requested resource limits were not applied.", workspace: "dev", tone: "danger" }),
  completed(77, { id: "catalog-upgrade-complete", category: "system", title: "Upgrade completed", detail: "Managed sandboxes are using the new runtime version.", tone: "success" }),
  completed(78, { id: "catalog-upgrade-failed", category: "system", title: "Upgrade failed", detail: "The previous runtime remains active.", tone: "danger" }),
  completed(79, { id: "catalog-update-complete", category: "system", title: "Silo update completed", detail: "The requested update completed successfully.", tone: "success" }),
  completed(80, { id: "catalog-update-failed", category: "system", title: "Silo update failed", detail: "The current installation remains active.", tone: "danger" }),
  completed(81, { id: "catalog-deep-check-complete", category: "system", title: "Deep check completed", detail: "Every destructive verification check passed.", tone: "success" }),
  completed(82, { id: "catalog-deep-check-failed", category: "system", title: "Deep check failed", detail: "One or more required checks need repair.", tone: "danger" }),
]

const liveSequences: Record<Exclude<ActivityFixtureMode, "catalog">, readonly ApplicationActivity[]> = {
  "sandbox-live": [
    live("live-sandbox", "sandbox", "Configuring sandbox", "Creating the sandbox and reconciling its storage.", "personal", 0.2, "Sandbox configuration 20% complete"),
    live("live-sandbox", "sandbox", "Preparing networking", "Starting candidate forwarding and readiness checks.", "personal", 0.5, "Sandbox configuration 50% complete"),
    live("live-sandbox", "sandbox", "Verifying sandbox", "Running the complete deep verification.", "personal", 0.8, "Sandbox configuration 80% complete"),
    live("live-sandbox", "sandbox", "Sandbox added", "Configuration was committed after verification.", "personal", 1, "Sandbox configuration complete", "success", "completed"),
  ],
  "git-live": [
    live("live-git", "git", "Pushing commits", "Pushing 2 commits from acme/silo on main.", "dev"),
    live("live-git", "git", "Push completed", "Pushed 2 commits from acme/silo on main.", "dev", 1, "Push complete", "success", "completed"),
  ],
  "backup-live": [
    live("live-backup", "backup", "Preparing backup", "Flushing and stopping the previously running sandboxes.", undefined, 0.1, "Backup 10% complete"),
    live("live-backup", "backup", "Writing archive", "Scanning, compressing, and writing the destination.", undefined, 0.45, "Backup 45% complete"),
    live("live-backup", "backup", "Checksumming archive", "Verifying the completed archive.", undefined, 0.75, "Backup 75% complete"),
    live("live-backup", "backup", "Finalizing backup", "Saving the durable result and restoring sandbox state.", undefined, 0.92, "Backup 92% complete"),
    live("live-backup", "backup", "Backup completed", "The archive and checksum were written successfully.", undefined, 1, "Backup complete", "success", "completed"),
  ],
  "secrets-live": [
    live("live-secrets", "secrets", "Applying secret change", "Updating DATABASE_URL for dev.", "dev"),
    live("live-secrets", "secrets", "Secret restart required", "Restart dev to apply the pending generation.", "dev", undefined, undefined, "warning", "completed"),
    live("live-secrets", "secrets", "Restarting for secrets", "Restarting dev and verifying its secret state.", "dev"),
    live("live-secrets", "secrets", "Secret change active", "The updated generation is active in dev.", "dev", 1, "Secret change complete", "success", "completed"),
  ],
  "github-live": [
    live("live-github", "github", "GitHub access saved", "Waiting to apply the reviewed repository policy.", "dev", 0.15, "GitHub access 15% complete"),
    live("live-github", "github", "Applying GitHub access", "Binding and verifying the scoped workspace grant.", "dev", 0.55, "GitHub access 55% complete"),
    live("live-github", "github", "GitHub access delayed", "The policy is saved locally and Silo will keep trying.", "dev", 0.7, "GitHub access delayed", "warning"),
    live("live-github", "github", "GitHub access applied", "The verified repository scope is active.", "dev", 1, "GitHub access complete", "success", "completed"),
  ],
  "system-live": [
    live("live-system", "system", "Installing runtime", "Activating the bundled Silo toolchain.", undefined, 0.2, "Runtime repair 20% complete"),
    live("live-system", "system", "Installing default configuration", "Applying the bundled default configuration.", undefined, 0.5, "Runtime repair 50% complete"),
    live("live-system", "system", "Verifying runtime", "Checking the activated command identity and handshake.", undefined, 0.8, "Runtime repair 80% complete"),
    live("live-system", "system", "Runtime repair completed", "The runtime and default configuration are ready.", undefined, 1, "Runtime repair complete", "success", "completed"),
  ],
}

export function activityFixtureModeFromSearch(search: string): ActivityFixtureMode | undefined {
  const requested = new URLSearchParams(search).get("activity")
  return activityFixtureModes.find((mode) => mode === requested)
}

export function activityFixtureStepCount(mode?: ActivityFixtureMode): number {
  return mode && mode !== "catalog" ? liveSequences[mode].length : 1
}

export function applicationActivitiesForFixture(
  mode: ActivityFixtureMode | undefined,
  step: number,
  fallback: readonly ApplicationActivity[],
): ApplicationActivity[] {
  if (!mode) return fallback.map((activity) => ({ ...activity }))
  if (mode === "catalog") return activityCatalog.map((activity) => ({ ...activity }))
  const sequence = liveSequences[mode]
  const current = sequence[Math.min(Math.max(step, 0), sequence.length - 1)]
  return [
    { ...current },
    ...activityCatalog
      .filter((activity) => (
        activity.category === current.category
        && (activity.title !== current.title || activity.detail !== current.detail)
      ))
      .map((activity) => ({ ...activity })),
  ]
}
