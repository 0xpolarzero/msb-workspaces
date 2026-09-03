import type { ReactNode } from "react"
import { Bell, Boxes, GitFork, HardDrive, KeyRound, LayoutDashboard, Settings2 } from "lucide-react"

import { SiloMark } from "@/components/silo-mark"
import { SiloWindow } from "@/components/silo-window"
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs"
import type { ApplicationTab } from "@/features/application/model/application-source"
import { useMediaQuery } from "@/hooks/use-media-query"

const primaryItems = [
  { id: "overview", label: "Overview", icon: LayoutDashboard },
  { id: "workspaces", label: "Sandboxes", icon: Boxes },
  { id: "github", label: "GitHub", icon: GitFork },
  { id: "secrets", label: "Secrets", icon: KeyRound },
  { id: "backup", label: "Backup", icon: HardDrive },
] as const

const preferenceItems = [
  { id: "notifications", label: "Notifications", icon: Bell },
  { id: "general", label: "General", icon: Settings2 },
] as const

function NavigationItems({ items }: { items: ReadonlyArray<{ id: ApplicationTab; label: string; icon: typeof LayoutDashboard }> }) {
  return items.map(({ id, label, icon: Icon }) => (
    <TabsTrigger
      key={id}
      value={id}
      data-appearance="borderless"
      className="h-10 min-w-fit justify-center gap-2 rounded-md border-0 bg-transparent px-3 py-2 text-xs text-muted-foreground shadow-none focus-visible:ring-2 focus-visible:ring-sidebar-ring/70 md:min-w-0 md:w-full md:justify-start md:text-[13px]"
    >
      <Icon className="size-4" />
      {label}
    </TabsTrigger>
  ))
}

export function ApplicationShell({ activeTab, onTabChange, children }: { activeTab: ApplicationTab; onTabChange: (tab: ApplicationTab) => void; children: ReactNode }) {
  const usesSidebar = useMediaQuery("(min-width: 48rem)")

  return (
    <SiloWindow title="Silo" label="Silo">
      <Tabs
        orientation={usesSidebar ? "vertical" : "horizontal"}
        value={activeTab}
        onValueChange={(value) => onTabChange(value as ApplicationTab)}
        className="grid min-h-0 flex-1 grid-rows-[auto_1fr] md:grid-cols-[13.5rem_minmax(0,1fr)] md:grid-rows-1"
      >
        <nav aria-label="Silo navigation" className="min-w-0 overflow-x-auto border-b border-border bg-sidebar px-3 py-2 md:border-r md:border-b-0 md:py-5">
          <div className="mb-5 hidden items-center gap-3 border-b border-border px-3 pb-5 md:flex">
            <SiloMark className="size-8" />
            <span className="text-base font-semibold tracking-tight">Silo</span>
          </div>
          <TabsList className="flex h-auto w-max min-w-full items-stretch gap-1 bg-transparent p-0 md:w-full md:flex-col" aria-label="App sections">
            <NavigationItems items={primaryItems} />
            <div className="mx-3 my-2 hidden border-t border-border md:block" aria-hidden="true" />
            <NavigationItems items={preferenceItems} />
          </TabsList>
        </nav>
        <div className="min-h-0 min-w-0 overflow-y-auto">{children}</div>
      </Tabs>
    </SiloWindow>
  )
}
