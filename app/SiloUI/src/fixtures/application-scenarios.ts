import type { ApplicationSource, ApplicationWorkspace } from "@/features/application/model/application-source"
import type { GitHubFixtureState, ScenarioName } from "@/fixtures/scenarios"

const baseWorkspaces: ApplicationWorkspace[] = [
  {
    id: "dev",
    purpose: "Primary software development workspace",
    state: "running",
    stateDetail: "Running for 2h 18m",
    freshness: "fresh",
    host: "dev.silo.test",
    cpus: 8,
    memoryGiB: 32,
    storageGiB: 120,
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
    id: "playgrounds",
    purpose: "Experiments and disposable prototypes",
    state: "stopped",
    stateDetail: "Stopped yesterday",
    freshness: "fresh",
    host: "playgrounds.silo.test",
    cpus: 4,
    memoryGiB: 16,
    storageGiB: 60,
    repositories: [{ path: "acme/platform-tools", branch: "main", ahead: 0, behind: 0, dirty: false }],
    ports: [],
    logs: ["17:02:11  silo  Workspace stopped cleanly"],
    activities: [{ id: "playgrounds-stop", title: "Stop succeeded", detail: "Workspace state was preserved.", time: "Yesterday", tone: "neutral" }],
    githubRepositories: ["acme/platform-tools"],
    secretNames: ["PACKAGE_TOKEN"],
  },
  {
    id: "personal",
    purpose: "Personal projects and services",
    state: "stopped",
    stateDetail: "Stopped 4 days ago",
    freshness: "fresh",
    host: "personal.silo.test",
    cpus: 6,
    memoryGiB: 16,
    storageGiB: 100,
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
    return baseWorkspaces.map((workspace) => workspace.id === "dev" ? {
      ...workspace,
      state: "failed",
      stateDetail: "Start failed 3m ago",
      freshness: "stale",
      activities: [{ id: "dev-failure", title: "Start failed", detail: "Candidate networking did not become ready.", time: "3m ago", tone: "danger" }, ...workspace.activities],
    } : workspace)
  }
  return baseWorkspaces
}

export function applicationSourceForScenario(scenario: ScenarioName, githubState?: GitHubFixtureState): ApplicationSource {
  return {
    updatedLabel: scenario === "bootstrap-failure" ? "Last known state · 3m ago" : "Updated just now",
    runtimeRepairRequired: scenario === "dependency-failure",
    workspaces: workspacesForScenario(scenario),
    healthChecks: [
      { id: "runtime", label: "Silo runtime", detail: "Bundled runtime 1.8.0", status: scenario === "dependency-failure" ? "fail" : "pass" },
      { id: "host", label: "Host integration", detail: "Loopback and SSH routing ready", status: "pass" },
      { id: "disk", label: "Available disk space", detail: "128 GiB available", status: "pass" },
      { id: "network", label: "Workspace network", detail: scenario === "bootstrap-failure" ? "dev needs attention" : "Routes verified", status: scenario === "bootstrap-failure" ? "warning" : "pass" },
    ],
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
