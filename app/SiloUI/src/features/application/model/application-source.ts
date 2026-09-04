import type {
  SetupMachineConfiguration,
  SetupMachineConfigurationRequest,
  SiloBootstrapResult,
  SiloProgressEvent,
  SiloProtocolError,
} from "@/contracts/silo"

export type ApplicationTab = "workspaces" | "github" | "secrets" | "backup" | "system" | "settings"
export type SettingsSection = "general" | "notifications"
export type WorkspaceSection = "overview" | "files" | "logs" | "network" | "activity"
export type WorkspaceDetailSection = Exclude<WorkspaceSection, "overview">
export type WorkspaceState = "running" | "starting" | "stopped" | "failed"

export type SandboxConfigurationOperation =
  | {
      id: string
      status: "applying"
      candidate: SetupMachineConfigurationRequest
      progressEvents: readonly SiloProgressEvent[]
      result: null
      error: null
    }
  | {
      id: string
      status: "awaiting-approval"
      candidate: SetupMachineConfigurationRequest
      progressEvents: readonly SiloProgressEvent[]
      result: SiloBootstrapResult
      error: null
    }
  | {
      id: string
      status: "failed"
      candidate: SetupMachineConfigurationRequest
      progressEvents: readonly SiloProgressEvent[]
      result: null
      error: SiloProtocolError
    }

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
  machine: SetupMachineConfiguration
  purpose: string
  state: WorkspaceState
  stateDetail: string
  attention?: {
    level: "warning" | "error"
    message: string
  }
  freshness: "fresh" | "stale"
  host: string
  repositories: ApplicationRepository[]
  ports: ApplicationPort[]
  logs: string[]
  activities: ApplicationActivity[]
  githubRepositories: string[]
  secretNames: string[]
}

export interface ApplicationSecret {
  id: string
  name: string
  workspaces: string[]
  allowedDomains: string[]
  state: "active" | "restart-required"
}

export interface ApplicationSource {
  runtimeRepairRequired: boolean
  workspaces: ApplicationWorkspace[]
  sandboxConfigurationOperation: SandboxConfigurationOperation | null
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
  repairRuntime: () => void
  saveMachineConfiguration: (request: SetupMachineConfigurationRequest) => void
  retryMachineConfiguration: (workspace: string) => void
  startWorkspace: (workspace: string) => void
  pauseWorkspace: (workspace: string) => void
  stopWorkspace: (workspace: string) => void
  restartWorkspace: (workspace: string) => void
  openTerminal: (workspace: string) => void
  openEditor: (workspace: string) => void
}
