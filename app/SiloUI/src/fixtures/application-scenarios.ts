import type { SetupVirtualMachineConfiguration, SiloProgressEvent } from "@/contracts/silo"
import type {
  ApplicationGitHubWorkspacePolicy,
  ApplicationSource,
  ApplicationWorkspace,
  GitHubWorkspaceOperation,
  RepositoryPushOperation,
  RuntimeRepairPresentation,
  SandboxConfigurationOperation,
  WorkspaceState,
} from "@/features/application/model/application-source"
import { productionMachineDefaults } from "@/features/onboarding/model/machine-configuration"
import { repositoryFixtures, type GitHubFixtureState, type ScenarioName } from "@/fixtures/scenarios"
import {
  applicationActivitiesForFixture,
  defaultApplicationActivities,
  type ActivityFixtureMode,
} from "@/fixtures/application-activity"

const [devMachine, playgroundsMachine, personalMachine] = productionMachineDefaults

export const workspaceFixtureModes = ["running", "starting", "stopped", "warning", "error"] as const
export type WorkspaceFixtureMode = (typeof workspaceFixtureModes)[number]

export const sandboxConfigurationFixtureModes = [
  "add-configuring",
  "add-networking",
  "add-verifying",
  "remove-pending",
  "workspace-error",
] as const
export type SandboxConfigurationFixtureMode = (typeof sandboxConfigurationFixtureModes)[number]

export const systemIssueFixtureModes = [
  "needed",
  "installing",
  "configuring",
  "verifying",
  "failed",
  "succeeded",
  "runtime-missing",
] as const
export type SystemIssueFixtureMode = (typeof systemIssueFixtureModes)[number]

export const repositoryPushFixtureModes = ["pushing", "succeeded", "failed"] as const
export type RepositoryPushFixtureMode = (typeof repositoryPushFixtureModes)[number]

export const githubManagementFixtureModes = [
  "idle",
  "applying",
  "succeeded",
  "failed",
  "applies-on-next-start",
  "restart-required",
  "disabled",
  "connected-empty",
  "missing-host-identity",
  "catalog-unavailable",
] as const
export type GitHubManagementFixtureMode = (typeof githubManagementFixtureModes)[number]

export function workspaceFixtureModeFromSearch(search: string): WorkspaceFixtureMode | undefined {
  const requested = new URLSearchParams(search).get("sandbox-state")
  return workspaceFixtureModes.find((mode) => mode === requested)
}

export function sandboxConfigurationFixtureModeFromSearch(search: string): SandboxConfigurationFixtureMode | undefined {
  const requested = new URLSearchParams(search).get("sandbox-change")
  return sandboxConfigurationFixtureModes.find((mode) => mode === requested)
}

export function systemIssueFixtureModeFromSearch(search: string): SystemIssueFixtureMode | undefined {
  const requested = new URLSearchParams(search).get("system-issue")
  return systemIssueFixtureModes.find((mode) => mode === requested)
}

export function repositoryPushFixtureModeFromSearch(search: string): RepositoryPushFixtureMode | undefined {
  const requested = new URLSearchParams(search).get("repository-push")
  return repositoryPushFixtureModes.find((mode) => mode === requested)
}

export function githubManagementFixtureModeFromSearch(search: string): GitHubManagementFixtureMode | undefined {
  const requested = new URLSearchParams(search).get("github-operation")
  return githubManagementFixtureModes.find((mode) => mode === requested)
}

const baseWorkspaces: ApplicationWorkspace[] = [
  {
    machine: { ...devMachine },
    purpose: "Primary software development workspace",
    state: "running",
    stateDetail: "Running for 2h 18m",
    freshness: "fresh",
    host: "dev.silo.test",
    repositories: [
      { path: "acme/silo", branch: "main", ahead: 2, behind: 0, dirty: true },
      { path: "acme/design-system", branch: "next", ahead: 0, behind: 1, dirty: false },
    ],
    files: [
      {
        name: "projects",
        kind: "folder",
        children: [
          { name: "silo", kind: "folder", children: [{ name: "src", kind: "folder" }, { name: "README.md", kind: "file" }] },
          { name: "design-system", kind: "folder" },
        ],
      },
      { name: ".config", kind: "folder", children: [{ name: "git", kind: "folder" }] },
      { name: ".gitconfig", kind: "file" },
    ],
    ports: [
      { port: 3000, listening: true },
      { port: 5173, listening: false },
      { port: 8080, listening: false },
    ],
    logs: [
      { line: "19:18:42  web       Ready on http://0.0.0.0:3000", occurredAt: "2026-09-04T19:18:42Z" },
      { line: "19:18:40  postgres  Database system is ready", occurredAt: "2026-09-04T19:18:40Z" },
      { line: "19:18:37  worker    Connected to queue", occurredAt: "2026-09-04T19:18:37Z" },
    ],
    githubRepositories: ["acme/silo", "acme/design-system"],
    secretNames: ["PACKAGE_TOKEN", "DATABASE_URL"],
  },
  {
    machine: { ...playgroundsMachine },
    purpose: "Experiments and disposable prototypes",
    state: "stopped",
    stateDetail: "Stopped yesterday",
    freshness: "fresh",
    host: "playgrounds.silo.test",
    repositories: [{ path: "acme/platform-tools", branch: "main", ahead: 0, behind: 0, dirty: false }],
    files: [
      { name: "experiments", kind: "folder", children: [{ name: "typescript", kind: "folder" }, { name: "rust", kind: "folder" }] },
      { name: "scratch", kind: "folder", children: [{ name: "notes.md", kind: "file" }] },
      { name: "README.md", kind: "file" },
    ],
    ports: [],
    logs: [{ line: "17:02:11  silo  Workspace stopped cleanly", occurredAt: "2026-09-03T17:02:11Z" }],
    githubRepositories: ["acme/platform-tools"],
    secretNames: ["PACKAGE_TOKEN"],
  },
  {
    machine: { ...personalMachine },
    purpose: "Personal projects and services",
    state: "stopped",
    stateDetail: "Stopped 4 days ago",
    freshness: "fresh",
    host: "personal.silo.test",
    repositories: [{ path: "taylor/docs-site", branch: "main", ahead: 0, behind: 0, dirty: false }],
    files: [
      { name: "docs-site", kind: "folder", children: [{ name: "content", kind: "folder" }, { name: "public", kind: "folder" }] },
      { name: ".config", kind: "folder", children: [{ name: "silo", kind: "folder" }] },
      { name: "notes.md", kind: "file" },
    ],
    ports: [],
    logs: [{ line: "09:41:02  silo  Workspace stopped cleanly", occurredAt: "2026-08-31T09:41:02Z" }],
    githubRepositories: ["taylor/docs-site"],
    secretNames: [],
  },
]

function workspacesForScenario(scenario: ScenarioName): ApplicationWorkspace[] {
  if (scenario === "complete") {
    return baseWorkspaces.map((workspace) => ({
      ...workspace,
      state: "running",
      stateDetail: "Running and verified",
      ports: workspace.ports.length > 0 ? workspace.ports : [{ port: 3000, listening: true }],
    }))
  }
  if (scenario === "bootstrap-failure") {
    return baseWorkspaces.map((workspace) => workspace.machine.name === "dev" ? {
      ...workspace,
      state: "failed",
      stateDetail: "Start failed 3m ago",
      attention: { level: "error", message: "Candidate networking did not become ready." },
      freshness: "stale",
    } : workspace)
  }
  return baseWorkspaces
}

const fixtureStateDetails: Record<WorkspaceState, string> = {
  running: "Running and verified",
  starting: "Starting services",
  stopped: "Stopped",
  failed: "Start failed",
}

function workspacesForFixtureMode(workspaces: ApplicationWorkspace[], mode?: WorkspaceFixtureMode): ApplicationWorkspace[] {
  if (!mode) return workspaces
  const state: WorkspaceState = mode === "error" ? "failed" : mode === "warning" ? "stopped" : mode
  return workspaces.map((workspace) => ({
    ...workspace,
    state,
    stateDetail: fixtureStateDetails[state],
    attention: mode === "warning"
      ? { level: "warning", message: "Storage is almost full." }
      : mode === "error"
        ? { level: "error", message: "Candidate networking did not become ready." }
        : undefined,
    freshness: mode === "error" ? "stale" : "fresh",
  }))
}

const scratchMachine: SetupVirtualMachineConfiguration = {
  ...devMachine,
  id: "00000000-0000-4000-8000-000000000004",
  name: "scratch",
  cpus: 4,
  memoryGiB: 16,
  workspaceStorageGiB: 60,
  runtimeStorageGiB: 60,
}

const fixtureRevision = "a".repeat(64)

function progressEvent(step: string, workspace: string, fraction: 0 | 1, message: string): SiloProgressEvent {
  return {
    schemaVersion: 1,
    type: "progress",
    requestId: "fixture-sandbox-configuration",
    phase: step === "workspace-verification" ? "verification" : "workspaces",
    step,
    workspace,
    revision: fixtureRevision,
    fraction,
    message,
    safeForDisplay: true,
  }
}

function configurationOperationForFixture(
  workspaces: ApplicationWorkspace[],
  mode?: SandboxConfigurationFixtureMode,
): SandboxConfigurationOperation | null {
  if (!mode) return null
  const machines = workspaces.map(({ machine }) => machine)
  const candidate = {
    schemaVersion: 1 as const,
    machines: mode === "remove-pending"
      ? machines.filter(({ name }) => name !== "playgrounds")
      : [...machines, scratchMachine],
  }
  const configured = progressEvent("workspace-configuration", "scratch", 1, "Workspace 'scratch' is configured.")
  const networkReady = progressEvent("workspace-networking", "scratch", 1, "Candidate networking is ready for 'scratch'.")

  if (mode === "workspace-error") {
    return {
      id: "fixture-sandbox-configuration",
      status: "failed",
      candidate,
      progressEvents: [configured, progressEvent("workspace-networking", "scratch", 0, "Candidate networking failed for 'scratch'.")],
      result: null,
      error: {
        code: "SILO_CANDIDATE_NETWORKING_FAILED",
        message: "Networking failed for 'scratch'.",
        recovery: "Repair workspace startup or SSH forwarding, then retry.",
        workspace: "scratch",
        retryable: true,
      },
    }
  }

  const progressEvents = mode === "add-configuring"
    ? [progressEvent("workspace-configuration", "scratch", 0, "Configuring workspace 'scratch'.")]
    : mode === "add-networking"
      ? [configured, progressEvent("workspace-networking", "scratch", 0, "Starting candidate networking for 'scratch'.")]
      : mode === "add-verifying"
        ? [configured, networkReady, progressEvent("workspace-verification", "scratch", 0, "Verifying 'scratch'.")]
        : []

  return {
    id: "fixture-sandbox-configuration",
    status: "applying",
    candidate,
    progressEvents,
    result: null,
    error: null,
  }
}

const neededRuntimeRepair: RuntimeRepairPresentation = {
  status: "needed",
  reason: "Silo could not verify the bundled runtime used to manage sandboxes.",
}

function runtimeRepairForFixture(
  scenario: ScenarioName,
  mode?: SystemIssueFixtureMode,
): RuntimeRepairPresentation | null {
  if (!mode) return scenario === "dependency-failure" ? neededRuntimeRepair : null
  if (mode === "needed") return neededRuntimeRepair
  if (mode === "installing") {
    return { status: "repairing", phase: "installing-runtime", completedSteps: 0, totalSteps: 3 }
  }
  if (mode === "configuring") {
    return { status: "repairing", phase: "installing-configuration", completedSteps: 1, totalSteps: 3 }
  }
  if (mode === "verifying") {
    return { status: "repairing", phase: "verifying", completedSteps: 2, totalSteps: 3 }
  }
  if (mode === "failed") {
    return {
      status: "failed",
      phase: "verifying",
      summary: "The activated runtime did not pass verification.",
      recovery: "Retry the repair. If it fails again, open a GitHub issue and paste the technical details below.",
      diagnosticDetails: [
        "Installing bundled Silo tools",
        "Installing default configuration",
        "Verifying activated command identity",
        "Final error: bundled Silo command failed its version handshake.",
      ].join("\n"),
    }
  }
  if (mode === "succeeded") return { status: "succeeded" }
  return {
    status: "unavailable",
    reason: "This app build is missing its bundled Silo runtime.",
    recovery: "Reinstall Silo from a complete app bundle.",
  }
}

function repositoryPushOperationsForFixture(mode?: RepositoryPushFixtureMode): RepositoryPushOperation[] {
  if (!mode) return []
  const operation = {
    workspace: "dev",
    repositoryPath: "acme/silo",
    commitCount: 2,
  }
  if (mode === "pushing") return [{ ...operation, status: "pushing" }]
  if (mode === "succeeded") return [{ ...operation, status: "succeeded" }]
  return [{
    ...operation,
    status: "failed",
    message: "Push failed because the remote branch changed.",
    diagnosticDetails: [
      "Repository: acme/silo",
      "Branch: main",
      "The remote branch no longer matches the reviewed commit.",
    ].join("\n"),
  }]
}

const githubWorkspacePolicies: readonly ApplicationGitHubWorkspacePolicy[] = [
  {
    workspace: "dev",
    identity: { name: "Taylor Example", email: "taylor@example.com", apply: true },
    repositories: [
      { repository: "acme/silo", allowPushes: true },
      { repository: "acme/design-system", allowPushes: false },
    ],
  },
  {
    workspace: "playgrounds",
    identity: { name: "Taylor Example", email: "taylor@example.com", apply: false },
    repositories: [{ repository: "acme/platform-tools", allowPushes: false }],
  },
  {
    workspace: "personal",
    identity: { name: "Taylor Example", email: "taylor@personal.dev", apply: true },
    repositories: [{ repository: "taylor/docs-site", allowPushes: true }],
  },
]

function githubWorkspaceOperationsForFixture(mode?: GitHubManagementFixtureMode): readonly GitHubWorkspaceOperation[] {
  if (!mode || mode === "idle" || mode === "disabled" || mode === "connected-empty" || mode === "missing-host-identity" || mode === "catalog-unavailable") return []
  if (mode === "applying") {
    return [{ workspace: "dev", status: "applying", message: "Applying repository access…" }]
  }
  if (mode === "succeeded") {
    return [{ workspace: "dev", status: "succeeded", message: "Repository access applied." }]
  }
  if (mode === "failed") {
    return [{
      workspace: "dev",
      status: "failed",
      message: "Repository access could not be applied.",
      canRetry: true,
      diagnosticDetails: [
        "Sandbox: dev",
        "Repository: acme/silo",
        "The scoped repository grant could not be verified.",
      ].join("\n"),
    }]
  }
  if (mode === "applies-on-next-start") {
    return [{ workspace: "playgrounds", status: "applies-on-next-start", message: "Saved. Applies when this sandbox next starts." }]
  }
  return [{ workspace: "dev", status: "restart-required", message: "Changes are ready. Restart this sandbox to finish applying them." }]
}

function githubWorkspacePoliciesForFixture(mode?: GitHubManagementFixtureMode): readonly ApplicationGitHubWorkspacePolicy[] {
  if (mode === "connected-empty") {
    return githubWorkspacePolicies.map((policy) => ({ ...policy, repositories: [] }))
  }
  if (mode === "missing-host-identity") {
    return githubWorkspacePolicies.map((policy) => ({
      ...policy,
      identity: { name: "", email: "", apply: false },
    }))
  }
  return githubWorkspacePolicies
}

export function applicationSourceForScenario(
  scenario: ScenarioName,
  githubState?: GitHubFixtureState,
  workspaceMode?: WorkspaceFixtureMode,
  sandboxConfigurationMode?: SandboxConfigurationFixtureMode,
  systemIssueMode?: SystemIssueFixtureMode,
  repositoryPushMode?: RepositoryPushFixtureMode,
  activityMode?: ActivityFixtureMode,
  activityStep = 0,
  githubManagementMode?: GitHubManagementFixtureMode,
): ApplicationSource {
  const githubConnectionState = githubState ?? "connected"
  const workspaces: ApplicationWorkspace[] = workspacesForFixtureMode(workspacesForScenario(scenario), workspaceMode).map((workspace) => (
    repositoryPushMode === "succeeded" && workspace.machine.name === "dev"
      ? { ...workspace, repositories: workspace.repositories.map((repository) => repository.path === "acme/silo" ? { ...repository, ahead: 0 } : repository) }
      : githubManagementMode === "restart-required" && workspace.machine.name === "dev"
        ? { ...workspace, attention: { level: "warning", message: "GitHub changes need a restart." } }
      : githubManagementMode === "failed" && workspace.machine.name === "dev"
        ? { ...workspace, attention: { level: "error", message: "GitHub access could not be applied." } }
      : workspace
  ))
  return {
    runtimeRepair: runtimeRepairForFixture(scenario, systemIssueMode),
    workspaces,
    activities: applicationActivitiesForFixture(
      activityMode,
      activityStep,
      scenario === "bootstrap-failure"
        ? [
            {
              id: "dev-failure",
              category: "sandbox",
              title: "Start failed",
              detail: "Candidate networking did not become ready.",
              occurredAt: "2026-09-04T15:59:00.000Z",
              time: "3m ago",
              tone: "danger",
              status: "completed",
              workspace: "dev",
            },
            ...defaultApplicationActivities,
          ]
        : defaultApplicationActivities,
    ),
    sandboxConfigurationOperation: configurationOperationForFixture(workspaces, sandboxConfigurationMode),
    repositoryPushOperations: repositoryPushOperationsForFixture(repositoryPushMode),
    github: {
      state: githubConnectionState,
      account: githubConnectionState === "connected" ? "taylor" : undefined,
      accessEnabled: githubManagementMode !== "disabled",
      repositoryCatalog: githubManagementMode === "catalog-unavailable" ? [] : repositoryFixtures,
      repositoryCatalogStatus: githubManagementMode === "catalog-unavailable"
        ? { status: "unavailable", message: "GitHub repositories could not be loaded.", canRetry: true }
        : { status: "available" },
      hostIdentity: githubManagementMode === "missing-host-identity"
        ? null
        : { name: "Taylor Example", email: "taylor@example.com" },
      workspaces: githubWorkspacePoliciesForFixture(githubManagementMode),
      workspaceOperations: githubWorkspaceOperationsForFixture(githubManagementMode),
    },
    secrets: [
      { id: "package-token", name: "PACKAGE_TOKEN", workspaces: ["dev", "playgrounds"], allowedDomains: ["registry.npmjs.org"], state: "active" },
      { id: "database-url", name: "DATABASE_URL", workspaces: ["dev"], allowedDomains: ["db.example.test"], state: "restart-required" },
    ],
    backup: {
      lastArchive: "silo-2026-09-02.silo-backup",
      completedLabel: "Yesterday at 22:14",
      compressedSize: "38.4 GB",
      destination: "External SSD / Silo Backups",
    },
    preferences: {
      launchAtLogin: true,
      startWorkspacesAtLaunch: false,
      pollingCadence: "30",
      terminal: "Terminal",
      editor: "Visual Studio Code",
      browser: "Safari",
      reduceMotion: false,
    },
  }
}
