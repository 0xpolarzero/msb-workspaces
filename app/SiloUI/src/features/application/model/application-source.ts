export type ApplicationTab = "overview" | "workspaces" | "github" | "secrets" | "backup" | "settings"
export type SettingsSection = "general" | "notifications"
export type WorkspaceSection = "summary" | "files" | "logs" | "network" | "activity"
export type WorkspaceState = "running" | "starting" | "stopped" | "failed"

export interface ApplicationRepository {
  path: string
  branch: string
  ahead: number
  behind: number
  dirty: boolean
}

export interface ApplicationPort {
  port: number
  process: string
  url?: string
  active: boolean
}

export interface ApplicationActivity {
  id: string
  title: string
  detail: string
  time: string
  tone: "success" | "neutral" | "danger"
}

export interface ApplicationWorkspace {
  id: string
  purpose: string
  state: WorkspaceState
  stateDetail: string
  freshness: "fresh" | "stale"
  host: string
  cpus: number
  memoryGiB: number
  storageGiB: number
  repositories: ApplicationRepository[]
  ports: ApplicationPort[]
  logs: string[]
  activities: ApplicationActivity[]
  githubRepositories: string[]
  secretNames: string[]
}

export interface ApplicationHealthCheck {
  id: string
  label: string
  detail: string
  status: "pass" | "warning" | "fail"
}

export interface ApplicationSecret {
  id: string
  name: string
  workspaces: string[]
  allowedDomains: string[]
  state: "active" | "restart-required"
}

export interface ApplicationSource {
  updatedLabel: string
  runtimeRepairRequired: boolean
  workspaces: ApplicationWorkspace[]
  healthChecks: ApplicationHealthCheck[]
  github: {
    state: "disconnected" | "connecting" | "connected"
    account?: string
  }
  secrets: ApplicationSecret[]
  backup: {
    lastArchive: string
    completedLabel: string
    compressedSize: string
    destination: string
  }
  preferences: {
    launchAtLogin: boolean
    startWorkspacesAtLaunch: boolean
    pollingCadence: "15" | "30" | "60"
    terminal: string
    editor: string
    reduceMotion: boolean
  }
}

export interface ApplicationActions {
  refresh: () => void
  runChecks: () => void
  repairRuntime: () => void
  startWorkspace: (workspace: string) => void
  stopWorkspace: (workspace: string) => void
  restartWorkspace: (workspace: string) => void
  openTerminal: (workspace: string) => void
  openEditor: (workspace: string) => void
}
