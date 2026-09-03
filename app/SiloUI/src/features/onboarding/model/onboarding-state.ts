import type {
  SetupQueueItemID,
  SiloPreflightCheck,
  SiloProgressEvent,
} from "@/contracts/silo"
import type { OnboardingSource } from "@/features/onboarding/model/onboarding-source"

export const onboardingSteps = ["dependencies", "workspaces", "github", "identity", "review"] as const
export type OnboardingStep = (typeof onboardingSteps)[number]

export type PresentationStatus = "waiting" | "running" | "succeeded" | "failed"

export interface DependencyItemView {
  name: string
  role: string
  check?: SiloPreflightCheck
}

export interface DependencyGroupView {
  id: string
  title: string
  status: "succeeded" | "failed"
  items: DependencyItemView[]
}

export interface WorkspaceView {
  name: string
  status: "waiting" | "working" | "ready" | "failed"
  detail: string
}

export interface WorkspaceProgressView {
  status: PresentationStatus
  elapsedSeconds: number
  currentWorkspace?: string
  currentMessage: string
  completedOperations: number
  totalOperations: number
  fraction?: number
  workspaces: WorkspaceView[]
  visibleEvents: SiloProgressEvent[]
  readyCount: number
  workingCount: number
  waitingCount: number
  failedCount: number
  recovery?: string
  retryable: boolean
}

export interface ReviewQueueItemView {
  id: SetupQueueItemID
  label: string
  status: "queued" | "running" | "succeeded" | "failed"
  failure?: string
}

export interface OnboardingViewModel {
  dependencies: DependencyGroupView[]
  dependencyStatus: PresentationStatus
  workspaceProgress: WorkspaceProgressView
  queueItems: ReviewQueueItemView[]
  finishEnabled: boolean
  error: OnboardingSource["error"]
  stepStatus: Record<OnboardingStep, PresentationStatus>
}

const inventory = [
  {
    id: "silo-tools",
    title: "Silo tools",
    items: [
      ["silo", "Manage and verify workspaces", "silo-runtime"],
      ["silo-ssh-proxy", "Route workspace SSH"],
      ["silo-github-proxy", "Scope GitHub HTTPS and LFS"],
      ["silo-git-askpass", "Authenticate host Git"],
      ["silo-keychain-bridge", "Read host-held credentials"],
      ["silo-github-host-token", "Supply the GitHub proxy"],
    ],
  },
  {
    id: "required-software",
    title: "Required software",
    items: [
      ["msb", "Run MicroSandbox VMs", "tool-msb"],
      ["git", "Source control", "tool-git"],
      ["git-lfs", "Large repository files", "tool-git-lfs"],
      ["tar / gtar", "Backup and restore", "tool-tar"],
      ["zstd", "Archive compression", "tool-zstd"],
    ],
  },
  {
    id: "mac-runtime",
    title: "Mac and runtime",
    items: [
      ["macOS 26+", "Supported system", "macos-version"],
      ["Apple Silicon", "arm64 architecture", "architecture"],
      ["20 GiB free", "Minimum disk space", "disk-space"],
      ["16 GiB memory", "Workspace recommendation", "memory"],
      ["Silo protocol 1", "Current app handshake"],
      ["MicroSandbox runtime", "VM runtime available"],
    ],
  },
  {
    id: "host-integration",
    title: "Host integration",
    items: [
      ["Host helper", "Signed, registered, reachable", "host-integration"],
      ["Loopback aliases", "Fixed workspace addresses"],
      ["Host records", "Managed workspace names"],
    ],
  },
] as const

const queueByStep: Record<Exclude<OnboardingStep, "dependencies">, SetupQueueItemID[]> = {
  workspaces: ["workspaceRun", "workspaceVerify"],
  github: ["githubRun", "githubVerify"],
  identity: ["identityRun", "identityVerify"],
  review: ["completion"],
}

const workspaceOperationSteps = new Set([
  "workspace-configuration",
  "workspace-networking",
  "workspace-verification",
])

function combineQueueStatus(items: ReviewQueueItemView[]): PresentationStatus {
  if (items.some(({ status }) => status === "failed")) return "failed"
  if (items.some(({ status }) => status === "running")) return "running"
  if (items.length > 0 && items.every(({ status }) => status === "succeeded")) return "succeeded"
  return "waiting"
}

function workspaceDetail(event: SiloProgressEvent): string {
  if (event.fraction === 1 && event.step === "workspace-verification") return "Ready"
  return event.message
}

const queueLabels: Record<SetupQueueItemID, string> = {
  workspaceRun: "Create workspaces",
  workspaceVerify: "Verify workspaces",
  githubRun: "Save GitHub",
  githubVerify: "Verify GitHub",
  identityRun: "Save Git",
  identityVerify: "Verify Git",
  completion: "Finish setup",
}

function projectQueue(source: OnboardingSource): ReviewQueueItemView[] {
  const ids = Object.keys(queueLabels) as SetupQueueItemID[]
  const completedPhases = new Set(source.bootstrapState.completedPhases)
  const workspaceBoundaryComplete = completedPhases.has("workspaces") && source.bootstrapResult?.phase === "complete"
  const allSetupComplete = completedPhases.has("complete") && workspaceBoundaryComplete && !source.error
  const isVerifying = source.progressEvents.some(({ step }) => step === "workspace-verification")
  return ids.map((id) => {
    if (allSetupComplete) return { id, label: queueLabels[id], status: "succeeded" }
    if (workspaceBoundaryComplete && (id === "workspaceRun" || id === "workspaceVerify")) {
      return { id, label: queueLabels[id], status: "succeeded" }
    }
    if (completedPhases.has("github") && (id === "githubRun" || id === "githubVerify")) {
      return { id, label: queueLabels[id], status: "succeeded" }
    }
    if (completedPhases.has("identity") && (id === "identityRun" || id === "identityVerify")) {
      return { id, label: queueLabels[id], status: "succeeded" }
    }
    if (source.error && id === (isVerifying ? "workspaceVerify" : "workspaceRun")) {
      return { id, label: queueLabels[id], status: "failed", failure: source.error.message }
    }
    if (source.progressEvents.length > 0) {
      if (id === "workspaceRun") return { id, label: queueLabels[id], status: isVerifying ? "succeeded" : "running" }
      if (id === "workspaceVerify" && isVerifying && !source.error) return { id, label: queueLabels[id], status: "running" }
    }
    return { id, label: queueLabels[id], status: "queued" }
  })
}

function projectWorkspaceProgress(source: OnboardingSource, queueItems: ReviewQueueItemView[]): WorkspaceProgressView {
  const activeRevision = source.progressEvents.findLast(({ revision }) => revision !== undefined)?.revision
  const activeEvents = source.progressEvents.filter((event) => (
    !activeRevision || !event.revision || event.revision === activeRevision
  ))
  const visibleEvents = activeEvents.filter(({ safeForDisplay }) => safeForDisplay)
  const completionKeys = new Set(
    activeEvents
      .filter((event) => event.workspace && event.step && workspaceOperationSteps.has(event.step) && event.fraction === 1)
      .map((event) => `${event.workspace}:${event.step}`),
  )
  const currentEvent = visibleEvents.at(-1)
  const failedWorkspace = source.error?.workspace ?? undefined
  const latestByWorkspace = new Map<string, SiloProgressEvent>()
  for (const event of activeEvents) {
    if (event.workspace) latestByWorkspace.set(event.workspace, event)
  }

  const workspaces = source.bootstrapConfiguration.workspaces.map(({ name }): WorkspaceView => {
    const latest = latestByWorkspace.get(name)
    if (failedWorkspace === name) {
      return { name, status: "failed", detail: source.error?.message ?? "Setup failed" }
    }
    if (latest?.step === "workspace-verification" && latest.fraction === 1) {
      return { name, status: "ready", detail: "Ready" }
    }
    if (latest && latest === currentEvent && latest.fraction !== 1) {
      return { name, status: "working", detail: workspaceDetail(latest) }
    }
    if (latest?.step === "workspace-networking" && latest.fraction === 1) {
      return { name, status: "waiting", detail: "Waiting for verification" }
    }
    if (latest?.step === "workspace-configuration" && latest.fraction === 1) {
      return { name, status: "waiting", detail: "Waiting for networking" }
    }
    if (latest) return { name, status: "waiting", detail: "Waiting" }
    return { name, status: "waiting", detail: "Waiting" }
  })

  const queueStatus = combineQueueStatus(queueItems.filter(({ id }) => queueByStep.workspaces.includes(id)))
  const totalOperations = workspaces.length * 3
  return {
    status: queueStatus,
    elapsedSeconds: source.bootstrapState.startedAt
      ? Math.max(0, source.bootstrapState.updatedAt - source.bootstrapState.startedAt)
      : 0,
    currentWorkspace: currentEvent?.workspace,
    currentMessage: source.error?.message ?? currentEvent?.message ?? source.bootstrapResult?.message ?? "Waiting to create workspaces",
    completedOperations: completionKeys.size,
    totalOperations,
    fraction: totalOperations > 0 ? completionKeys.size / totalOperations : undefined,
    workspaces,
    visibleEvents,
    readyCount: workspaces.filter(({ status }) => status === "ready").length,
    workingCount: workspaces.filter(({ status }) => status === "working").length,
    waitingCount: workspaces.filter(({ status }) => status === "waiting").length,
    failedCount: workspaces.filter(({ status }) => status === "failed").length,
    recovery: source.error?.recovery ?? undefined,
    retryable: source.error?.retryable ?? false,
  }
}

export function projectOnboarding(source: OnboardingSource): OnboardingViewModel {
  const checksById = new Map(source.preflightChecks.map((check) => [check.id, check]))
  const dependencies = inventory.map((group): DependencyGroupView => {
    const items = group.items.map(([name, role, checkId]) => ({
      name,
      role,
      check: checkId ? checksById.get(checkId) : undefined,
    }))
    return {
      id: group.id,
      title: group.title,
      status: items.some(({ check }) => check && check.status !== "pass") ? "failed" : "succeeded",
      items,
    }
  })
  const dependencyStatus = dependencies.some(({ status }) => status === "failed") ? "failed" : "succeeded"
  const queueItems = projectQueue(source)
  const workspaceProgress = projectWorkspaceProgress(source, queueItems)
  const stepStatus = {
    dependencies: dependencyStatus,
    workspaces: workspaceProgress.status,
    github: combineQueueStatus(queueItems.filter(({ id }) => queueByStep.github.includes(id))),
    identity: combineQueueStatus(queueItems.filter(({ id }) => queueByStep.identity.includes(id))),
    review: combineQueueStatus(queueItems.filter(({ id }) => queueByStep.review.includes(id))),
  } satisfies Record<OnboardingStep, PresentationStatus>

  return {
    dependencies,
    dependencyStatus,
    workspaceProgress,
    queueItems,
    finishEnabled: dependencyStatus === "succeeded" && source.error === null && queueItems.every(({ status }) => status === "succeeded"),
    error: source.error,
    stepStatus,
  }
}
