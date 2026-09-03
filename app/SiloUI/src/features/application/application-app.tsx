import { useState } from "react"

import { ApplicationShell } from "@/features/application/components/application-shell"
import type { ApplicationActions, ApplicationSource, ApplicationTab, SettingsSection, WorkspaceSection } from "@/features/application/model/application-source"
import { BackupPage } from "@/features/application/pages/backup-page"
import { GeneralPage } from "@/features/application/pages/general-page"
import { GitHubPage } from "@/features/application/pages/github-page"
import { NotificationsPage } from "@/features/application/pages/notifications-page"
import { OverviewPage } from "@/features/application/pages/overview-page"
import { SecretsPage } from "@/features/application/pages/secrets-page"
import { WorkspacesPage } from "@/features/application/pages/workspaces-page"

export function ApplicationApp({ source, actions }: { source: ApplicationSource; actions: ApplicationActions }) {
  const [activeTab, setActiveTab] = useState<ApplicationTab>("workspaces")
  const [selectedWorkspace, setSelectedWorkspace] = useState(source.workspaces[0]?.id ?? "")
  const [workspaceSection, setWorkspaceSection] = useState<WorkspaceSection>("overview")
  const [settingsSection, setSettingsSection] = useState<SettingsSection>("general")
  const [logQuery, setLogQuery] = useState("")

  return (
    <ApplicationShell
      activeTab={activeTab}
      workspaceSection={workspaceSection}
      settingsSection={settingsSection}
      onTabChange={setActiveTab}
      onWorkspaceSectionChange={setWorkspaceSection}
      onSettingsSectionChange={setSettingsSection}
    >
      <section id="application-panel-workspaces" role="region" aria-labelledby="application-nav-workspaces" hidden={activeTab !== "workspaces"}>
        {workspaceSection === "overview" ? (
          <OverviewPage source={source} actions={actions} />
        ) : (
          <WorkspacesPage
            workspaces={source.workspaces}
            selectedWorkspace={selectedWorkspace}
            section={workspaceSection}
            logQuery={logQuery}
            onWorkspaceChange={setSelectedWorkspace}
            onLogQueryChange={setLogQuery}
          />
        )}
      </section>
      <section id="application-panel-github" role="region" aria-labelledby="application-nav-github" hidden={activeTab !== "github"}><GitHubPage source={source} /></section>
      <section id="application-panel-secrets" role="region" aria-labelledby="application-nav-secrets" hidden={activeTab !== "secrets"}><SecretsPage source={source} /></section>
      <section id="application-panel-backup" role="region" aria-labelledby="application-nav-backup" hidden={activeTab !== "backup"}><BackupPage source={source} /></section>
      <section id="application-panel-settings" role="region" aria-labelledby="application-nav-settings" hidden={activeTab !== "settings"}>
        <div hidden={settingsSection !== "general"}><GeneralPage source={source} /></div>
        <div hidden={settingsSection !== "notifications"}><NotificationsPage /></div>
      </section>
    </ApplicationShell>
  )
}
