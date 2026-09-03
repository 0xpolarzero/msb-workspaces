import { useState } from "react"
import { TabsContent } from "@/components/ui/tabs"

import { ApplicationShell } from "@/features/application/components/application-shell"
import type { ApplicationActions, ApplicationSource, ApplicationTab, WorkspaceSection } from "@/features/application/model/application-source"
import { OverviewPage } from "@/features/application/pages/overview-page"
import { WorkspacesPage } from "@/features/application/pages/workspaces-page"

const placeholderCopy: Record<Exclude<ApplicationTab, "overview" | "workspaces">, string> = {
  github: "Account and repository access",
  secrets: "Host-held credentials",
  backup: "Backup and restore",
  notifications: "Workspace and operation alerts",
  general: "Startup and application preferences",
}

export function ApplicationApp({ source, actions }: { source: ApplicationSource; actions: ApplicationActions }) {
  const [activeTab, setActiveTab] = useState<ApplicationTab>("overview")
  const [selectedWorkspace, setSelectedWorkspace] = useState(source.workspaces[0]?.id ?? "")
  const [workspaceSection, setWorkspaceSection] = useState<WorkspaceSection>("summary")

  function openWorkspace(workspace: string) {
    setSelectedWorkspace(workspace)
    setWorkspaceSection("summary")
    setActiveTab("workspaces")
  }

  return (
    <ApplicationShell activeTab={activeTab} onTabChange={setActiveTab}>
      <TabsContent value="overview" className="m-0">
        <OverviewPage source={source} actions={actions} onOpenWorkspace={openWorkspace} />
      </TabsContent>
      <TabsContent value="workspaces" className="m-0">
        <WorkspacesPage
          workspaces={source.workspaces}
          selectedWorkspace={selectedWorkspace}
          section={workspaceSection}
          actions={actions}
          onWorkspaceChange={setSelectedWorkspace}
          onSectionChange={setWorkspaceSection}
        />
      </TabsContent>
      {(Object.keys(placeholderCopy) as Array<keyof typeof placeholderCopy>).map((tab) => (
        <TabsContent key={tab} value={tab} className="m-0">
          <div className="mx-auto grid min-h-80 w-full max-w-4xl place-items-center px-6 text-center">
            <div>
              <h2 className="text-xl font-semibold tracking-tight capitalize">{tab}</h2>
              <p className="mt-2 text-sm text-muted-foreground">{placeholderCopy[tab]}</p>
            </div>
          </div>
        </TabsContent>
      ))}
    </ApplicationShell>
  )
}
