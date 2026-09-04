import { useEffect, useState } from "react"

import type { SetupMachineConfiguration } from "@/contracts/silo"
import { ApplicationShell } from "@/features/application/components/application-shell"
import type { ApplicationActions, ApplicationSource, ApplicationTab, SandboxConfigurationOperation, SettingsSection, WorkspaceSection } from "@/features/application/model/application-source"
import { BackupPage } from "@/features/application/pages/backup-page"
import { GeneralPage } from "@/features/application/pages/general-page"
import { GitHubPage } from "@/features/application/pages/github-page"
import { NotificationsPage } from "@/features/application/pages/notifications-page"
import { OverviewPage } from "@/features/application/pages/overview-page"
import { SecretsPage } from "@/features/application/pages/secrets-page"
import { SystemIssuePage } from "@/features/application/pages/system-issue-page"
import { WorkspacesPage } from "@/features/application/pages/workspaces-page"

export function ApplicationApp({ source, actions }: { source: ApplicationSource; actions: ApplicationActions }) {
  const [activeTab, setActiveTab] = useState<ApplicationTab>("workspaces")
  const [workspaces, setWorkspaces] = useState(() => source.workspaces.map((workspace) => ({ ...workspace, machine: { ...workspace.machine } })))
  const [selectedWorkspace, setSelectedWorkspace] = useState(source.workspaces[0]?.machine.id ?? "")
  const [workspaceSection, setWorkspaceSection] = useState<WorkspaceSection>("overview")
  const [settingsSection, setSettingsSection] = useState<SettingsSection>("general")
  const [logQuery, setLogQuery] = useState("")
  const [sandboxConfigurationOperation, setSandboxConfigurationOperation] = useState<SandboxConfigurationOperation | null>(source.sandboxConfigurationOperation)
  const applicationSource = { ...source, workspaces, sandboxConfigurationOperation }

  useEffect(() => {
    // The source is the authoritative snapshot when the native bridge publishes a replacement.
    // oxlint-disable-next-line react/set-state-in-effect
    setWorkspaces(source.workspaces.map((workspace) => ({ ...workspace, machine: { ...workspace.machine } })))
    // oxlint-disable-next-line react/set-state-in-effect
    setSelectedWorkspace((current) => source.workspaces.some(({ machine }) => machine.id === current) ? current : source.workspaces[0]?.machine.id ?? "")
    // The native bridge clears or replaces the pending operation alongside its authoritative snapshot.
    // oxlint-disable-next-line react/set-state-in-effect
    setSandboxConfigurationOperation(source.sandboxConfigurationOperation)
    // The destination only exists while the global issue remains active.
    // oxlint-disable-next-line react/set-state-in-effect
    setActiveTab((current) => current === "system" && !source.runtimeRepairRequired ? "workspaces" : current)
  }, [source.workspaces, source.sandboxConfigurationOperation, source.runtimeRepairRequired])

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

  return (
    <ApplicationShell
      activeTab={activeTab}
      workspaceSection={workspaceSection}
      settingsSection={settingsSection}
      showSystemIssue={source.runtimeRepairRequired}
      onTabChange={setActiveTab}
      onWorkspaceSectionChange={setWorkspaceSection}
      onSettingsSectionChange={setSettingsSection}
    >
      <section id="application-panel-workspaces" role="region" aria-labelledby="application-nav-workspaces" hidden={activeTab !== "workspaces"}>
        {workspaceSection === "overview" ? (
          <OverviewPage source={applicationSource} actions={actions} onMachinesChange={updateMachines} />
        ) : (
          <WorkspacesPage
            workspaces={workspaces}
            selectedWorkspace={selectedWorkspace}
            section={workspaceSection}
            logQuery={logQuery}
            onWorkspaceChange={setSelectedWorkspace}
            onLogQueryChange={setLogQuery}
          />
        )}
      </section>
      <section id="application-panel-github" role="region" aria-labelledby="application-nav-github" hidden={activeTab !== "github"}><GitHubPage source={applicationSource} /></section>
      <section id="application-panel-secrets" role="region" aria-labelledby="application-nav-secrets" hidden={activeTab !== "secrets"}><SecretsPage source={applicationSource} /></section>
      <section id="application-panel-backup" role="region" aria-labelledby="application-nav-backup" hidden={activeTab !== "backup"}><BackupPage source={applicationSource} /></section>
      {source.runtimeRepairRequired && (
        <section id="application-panel-system" role="region" aria-labelledby="application-nav-system" hidden={activeTab !== "system"}>
          <SystemIssuePage actions={actions} />
        </section>
      )}
      <section id="application-panel-settings" role="region" aria-labelledby="application-nav-settings" hidden={activeTab !== "settings"}>
        <div hidden={settingsSection !== "general"}><GeneralPage source={applicationSource} /></div>
        <div hidden={settingsSection !== "notifications"}><NotificationsPage /></div>
      </section>
    </ApplicationShell>
  )
}
