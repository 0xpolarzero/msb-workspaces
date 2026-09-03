import { useState } from "react"
import { TabsContent } from "@/components/ui/tabs"

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
  const [activeTab, setActiveTab] = useState<ApplicationTab>("overview")
  const [selectedWorkspace, setSelectedWorkspace] = useState(source.workspaces[0]?.id ?? "")
  const [workspaceSection, setWorkspaceSection] = useState<WorkspaceSection>("summary")
  const [settingsSection, setSettingsSection] = useState<SettingsSection>("general")
  const [logQuery, setLogQuery] = useState("")

  function openWorkspace(workspace: string) {
    setSelectedWorkspace(workspace)
    setWorkspaceSection("summary")
    setActiveTab("workspaces")
  }

  return (
    <ApplicationShell activeTab={activeTab} settingsSection={settingsSection} onTabChange={setActiveTab} onSettingsSectionChange={setSettingsSection}>
      <TabsContent value="overview" forceMount className="m-0 data-[state=inactive]:hidden">
        <OverviewPage source={source} actions={actions} onOpenWorkspace={openWorkspace} />
      </TabsContent>
      <TabsContent value="workspaces" forceMount className="m-0 data-[state=inactive]:hidden">
        <WorkspacesPage
          workspaces={source.workspaces}
          selectedWorkspace={selectedWorkspace}
          section={workspaceSection}
          logQuery={logQuery}
          actions={actions}
          onWorkspaceChange={setSelectedWorkspace}
          onSectionChange={setWorkspaceSection}
          onLogQueryChange={setLogQuery}
        />
      </TabsContent>
      <TabsContent value="github" forceMount className="m-0 data-[state=inactive]:hidden"><GitHubPage source={source} /></TabsContent>
      <TabsContent value="secrets" forceMount className="m-0 data-[state=inactive]:hidden"><SecretsPage source={source} /></TabsContent>
      <TabsContent value="backup" forceMount className="m-0 data-[state=inactive]:hidden"><BackupPage source={source} /></TabsContent>
      <TabsContent value="settings" forceMount className="m-0 data-[state=inactive]:hidden">
        <div hidden={settingsSection !== "general"}><GeneralPage source={source} /></div>
        <div hidden={settingsSection !== "notifications"}><NotificationsPage /></div>
      </TabsContent>
    </ApplicationShell>
  )
}
