import { useCallback, useEffect, useRef, useState } from "react"

import type { SetupMachineConfiguration } from "@/contracts/silo"
import { ApplicationShell } from "@/features/application/components/application-shell"
import type { ApplicationActions, ApplicationSource, ApplicationTab, RepositoryPushOperation, RuntimeRepairPresentation, SandboxConfigurationOperation, SettingsSection, WorkspaceSection } from "@/features/application/model/application-source"
import { BackupPage } from "@/features/application/pages/backup-page"
import { GeneralPage } from "@/features/application/pages/general-page"
import { GitHubPage } from "@/features/application/pages/github-page"
import { NotificationsPage } from "@/features/application/pages/notifications-page"
import { OverviewPage } from "@/features/application/pages/overview-page"
import { SecretsPage } from "@/features/application/pages/secrets-page"
import { SystemIssuePage } from "@/features/application/pages/system-issue-page"
import { WorkspacesPage } from "@/features/application/pages/workspaces-page"

export function ApplicationApp({ source, actions }: { source: ApplicationSource; actions: ApplicationActions }) {
  const activeRuntimeRepair = source.runtimeRepair?.status === "succeeded" ? null : source.runtimeRepair
  const [activeTab, setActiveTab] = useState<ApplicationTab>("workspaces")
  const [workspaces, setWorkspaces] = useState(() => source.workspaces.map((workspace) => ({ ...workspace, machine: { ...workspace.machine } })))
  const [excludedWorkspaceIds, setExcludedWorkspaceIds] = useState<Set<string>>(() => new Set())
  const [workspaceSection, setWorkspaceSection] = useState<WorkspaceSection>("overview")
  const [settingsSection, setSettingsSection] = useState<SettingsSection>("general")
  const [logQuery, setLogQuery] = useState("")
  const [sandboxConfigurationOperation, setSandboxConfigurationOperation] = useState<SandboxConfigurationOperation | null>(source.sandboxConfigurationOperation)
  const [repositoryPushOperations, setRepositoryPushOperations] = useState<RepositoryPushOperation[]>(source.repositoryPushOperations)
  const [repairConfirmationVisible, setRepairConfirmationVisible] = useState(source.runtimeRepair?.status === "succeeded")
  const previousRuntimeRepairStatus = useRef<RuntimeRepairPresentation["status"] | undefined>(undefined)
  const repairConfirmationTimer = useRef<number | null>(null)
  const resolvedSystemSelection = activeTab === "system" && !activeRuntimeRepair
  const visibleTab = resolvedSystemSelection ? "workspaces" : activeTab
  const visibleWorkspaceSection = resolvedSystemSelection && source.runtimeRepair?.status === "succeeded" ? "overview" : workspaceSection
  const applicationSource = { ...source, workspaces, sandboxConfigurationOperation, repositoryPushOperations }

  useEffect(() => {
    // The source is the authoritative snapshot when the native bridge publishes a replacement.
    // oxlint-disable-next-line react/set-state-in-effect
    setWorkspaces(source.workspaces.map((workspace) => ({ ...workspace, machine: { ...workspace.machine } })))
    // oxlint-disable-next-line react/set-state-in-effect
    setExcludedWorkspaceIds((current) => {
      const availableIds = new Set(source.workspaces.map(({ machine }) => machine.id))
      const next = new Set([...current].filter((id) => availableIds.has(id)))
      return next.size === current.size ? current : next
    })
    // The native bridge clears or replaces the pending operation alongside its authoritative snapshot.
    // oxlint-disable-next-line react/set-state-in-effect
    setSandboxConfigurationOperation(source.sandboxConfigurationOperation)
    // The native bridge replaces local push progress with its authoritative operation result.
    // oxlint-disable-next-line react/set-state-in-effect
    setRepositoryPushOperations(source.repositoryPushOperations)
    // The destination only exists while the global issue remains active.
    // oxlint-disable-next-line react/set-state-in-effect
    setActiveTab((current) => current === "system" && !activeRuntimeRepair ? "workspaces" : current)
  }, [source.workspaces, source.sandboxConfigurationOperation, source.repositoryPushOperations, activeRuntimeRepair])

  useEffect(() => {
    const status = source.runtimeRepair?.status
    const previousStatus = previousRuntimeRepairStatus.current
    previousRuntimeRepairStatus.current = status

    if (status && status !== "succeeded") {
      if (repairConfirmationTimer.current !== null) {
        window.clearTimeout(repairConfirmationTimer.current)
        repairConfirmationTimer.current = null
      }
      // oxlint-disable-next-line react/set-state-in-effect
      setRepairConfirmationVisible(false)
      return
    }
    if (status !== "succeeded" || previousStatus === "succeeded") return

    // A successful repair is a transient result, not a navigation destination.
    if (activeTab === "system") {
      // oxlint-disable-next-line react/set-state-in-effect
      setWorkspaceSection("overview")
    }
    // oxlint-disable-next-line react/set-state-in-effect
    setRepairConfirmationVisible(true)
    if (repairConfirmationTimer.current !== null) window.clearTimeout(repairConfirmationTimer.current)
    repairConfirmationTimer.current = window.setTimeout(() => {
      setRepairConfirmationVisible(false)
      repairConfirmationTimer.current = null
    }, 4_000)
  }, [source.runtimeRepair?.status, activeTab])

  useEffect(() => () => {
    if (repairConfirmationTimer.current !== null) window.clearTimeout(repairConfirmationTimer.current)
  }, [])

  function updateMachines(machines: SetupMachineConfiguration[]) {
    const candidate = { schemaVersion: 1 as const, machines }
    setSandboxConfigurationOperation({
      id: "local-sandbox-configuration",
      status: "applying",
      candidate,
      progressEvents: [],
      result: null,
      error: null,
    })
    actions.saveMachineConfiguration(candidate)
  }

  function pushRepository(workspace: string, repositoryPath: string, commitCount: number) {
    setRepositoryPushOperations((current) => [
      ...current.filter((operation) => operation.workspace !== workspace || operation.repositoryPath !== repositoryPath),
      { workspace, repositoryPath, commitCount, status: "pushing" },
    ])
    actions.pushRepository(workspace, repositoryPath)
  }

  const dismissRepositoryPush = useCallback((workspace: string, repositoryPath: string) => {
    setRepositoryPushOperations((current) => current.filter((operation) => operation.workspace !== workspace || operation.repositoryPath !== repositoryPath))
  }, [])

  return (
    <ApplicationShell
      activeTab={visibleTab}
      workspaceSection={visibleWorkspaceSection}
      settingsSection={settingsSection}
      systemIssueStatus={activeRuntimeRepair?.status ?? null}
      onTabChange={setActiveTab}
      onWorkspaceSectionChange={setWorkspaceSection}
      onSettingsSectionChange={setSettingsSection}
    >
      <section id="application-panel-workspaces" role="region" aria-labelledby="application-nav-workspaces" hidden={visibleTab !== "workspaces"}>
        {visibleWorkspaceSection === "overview" ? (
          <OverviewPage source={applicationSource} actions={actions} onMachinesChange={updateMachines} repairCompleted={repairConfirmationVisible} />
        ) : (
          <WorkspacesPage
            workspaces={workspaces}
            excludedWorkspaceIds={excludedWorkspaceIds}
            section={visibleWorkspaceSection}
            logQuery={logQuery}
            repositoryPushOperations={repositoryPushOperations}
            onWorkspaceFilterChange={setExcludedWorkspaceIds}
            onLogQueryChange={setLogQuery}
            onPushRepository={pushRepository}
            onDismissRepositoryPush={dismissRepositoryPush}
          />
        )}
      </section>
      <section id="application-panel-github" role="region" aria-labelledby="application-nav-github" hidden={visibleTab !== "github"}><GitHubPage source={applicationSource} /></section>
      <section id="application-panel-secrets" role="region" aria-labelledby="application-nav-secrets" hidden={visibleTab !== "secrets"}><SecretsPage source={applicationSource} /></section>
      <section id="application-panel-backup" role="region" aria-labelledby="application-nav-backup" hidden={visibleTab !== "backup"}><BackupPage source={applicationSource} /></section>
      {activeRuntimeRepair && (
        <section id="application-panel-system" role="region" aria-labelledby="application-nav-system" hidden={visibleTab !== "system"}>
          <SystemIssuePage issue={activeRuntimeRepair} actions={actions} />
        </section>
      )}
      <section id="application-panel-settings" role="region" aria-labelledby="application-nav-settings" hidden={visibleTab !== "settings"}>
        <div hidden={settingsSection !== "general"}><GeneralPage source={applicationSource} /></div>
        <div hidden={settingsSection !== "notifications"}><NotificationsPage /></div>
      </section>
    </ApplicationShell>
  )
}
