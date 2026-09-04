import type { ApplicationSource, ApplicationWorkspace, WorkspaceState } from "@/features/application/model/application-source"
import { productionMachineDefaults } from "@/features/onboarding/model/machine-configuration"
import type { GitHubFixtureState, ScenarioName } from "@/fixtures/scenarios"

const [devMachine, playgroundsMachine, personalMachine] = productionMachineDefaults

export const workspaceFixtureModes = ["running", "starting", "stopped", "warning", "error"] as const
export type WorkspaceFixtureMode = (typeof workspaceFixtureModes)[number]

export function workspaceFixtureModeFromSearch(search: string): WorkspaceFixtureMode | undefined {
  const requested = new URLSearchParams(search).get("sandbox-state")
  return workspaceFixtureModes.find((mode) => mode === requested)
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
    ports: [
      { port: 3000, process: "web", url: "https://dev.silo.test", active: true },
      { port: 5173, process: "vite", active: false },
      { port: 8080, process: "api", active: false },
    ],
    logs: [
      "19:18:42  web       Ready on http://0.0.0.0:3000",
      "19:18:40  postgres  Database system is ready",
      "19:18:37  worker    Connected to queue",
    ],
    activities: [
      { id: "dev-start", title: "Start succeeded", detail: "Workspace services passed verification.", time: "2h ago", tone: "success" },
      { id: "dev-push", title: "Push completed", detail: "Pushed 3 commits from acme/silo.", time: "Yesterday", tone: "neutral" },
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
    ports: [],
    logs: ["17:02:11  silo  Workspace stopped cleanly"],
    activities: [{ id: "playgrounds-stop", title: "Stop succeeded", detail: "Workspace state was preserved.", time: "Yesterday", tone: "neutral" }],
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
    ports: [],
    logs: ["09:41:02  silo  Workspace stopped cleanly"],
    activities: [{ id: "personal-backup", title: "Backup completed", detail: "Archive verification passed.", time: "4 days ago", tone: "success" }],
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
      ports: workspace.ports.length > 0 ? workspace.ports : [{ port: 3000, process: "web", active: true }],
    }))
  }
  if (scenario === "bootstrap-failure") {
    return baseWorkspaces.map((workspace) => workspace.machine.name === "dev" ? {
      ...workspace,
      state: "failed",
      stateDetail: "Start failed 3m ago",
      attention: { level: "error", message: "Candidate networking did not become ready." },
      freshness: "stale",
      activities: [{ id: "dev-failure", title: "Start failed", detail: "Candidate networking did not become ready.", time: "3m ago", tone: "danger" }, ...workspace.activities],
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

export function applicationSourceForScenario(scenario: ScenarioName, githubState?: GitHubFixtureState, workspaceMode?: WorkspaceFixtureMode): ApplicationSource {
  return {
    runtimeRepairRequired: scenario === "dependency-failure",
    workspaces: workspacesForFixtureMode(workspacesForScenario(scenario), workspaceMode),
    github: {
      state: githubState ?? "connected",
      account: githubState === "disconnected" ? undefined : "taylor",
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
      reduceMotion: false,
    },
  }
}
