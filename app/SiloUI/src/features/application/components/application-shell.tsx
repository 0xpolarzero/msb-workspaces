import type { ReactNode } from "react"
import { Bell, Boxes, ChevronRight, GitFork, HardDrive, KeyRound, LayoutDashboard, Settings2, SlidersHorizontal } from "lucide-react"

import { SiloMark } from "@/components/silo-mark"
import { SiloWindow } from "@/components/silo-window"
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs"
import type { ApplicationTab, SettingsSection } from "@/features/application/model/application-source"
import { useMediaQuery } from "@/hooks/use-media-query"
import { cn } from "@/lib/utils"

const primaryItems = [
  { id: "overview", label: "Overview", icon: LayoutDashboard },
  { id: "workspaces", label: "Sandboxes", icon: Boxes },
  { id: "github", label: "GitHub", icon: GitFork },
  { id: "secrets", label: "Secrets", icon: KeyRound },
  { id: "backup", label: "Backup", icon: HardDrive },
] as const

const settingsItems = [
  { id: "general", label: "General", icon: SlidersHorizontal },
  { id: "notifications", label: "Notifications", icon: Bell },
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

function SettingsNavigation({ section, onSectionChange }: { section: SettingsSection; onSectionChange: (section: SettingsSection) => void }) {
  return (
    <div id="settings-sections" role="group" aria-label="Settings sections" className="mt-1 flex gap-1 border-t border-border pt-2 md:ml-6 md:grid md:border-t-0 md:border-l md:pt-0 md:pl-2">
      {settingsItems.map(({ id, label, icon: Icon }) => (
        <button
          key={id}
          type="button"
          aria-current={section === id ? "page" : undefined}
          onClick={() => onSectionChange(id)}
          className={cn(
            "flex h-8 min-w-fit items-center justify-center gap-2 rounded-md px-3 text-xs text-muted-foreground transition-colors hover:bg-muted hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sidebar-ring/70 md:w-full md:justify-start",
            section === id && "bg-muted font-medium text-foreground",
          )}
        >
          <Icon className="size-3.5" />
          {label}
        </button>
      ))}
    </div>
  )
}

export function ApplicationShell({
  activeTab,
  settingsSection,
  onTabChange,
  onSettingsSectionChange,
  children,
}: {
  activeTab: ApplicationTab
  settingsSection: SettingsSection
  onTabChange: (tab: ApplicationTab) => void
  onSettingsSectionChange: (section: SettingsSection) => void
  children: ReactNode
}) {
  const usesSidebar = useMediaQuery("(min-width: 48rem)")
  const settingsOpen = activeTab === "settings"

  return (
    <SiloWindow title="Silo" label="Silo">
      <Tabs
        orientation={usesSidebar ? "vertical" : "horizontal"}
        value={activeTab}
        onValueChange={(value) => onTabChange(value as ApplicationTab)}
        className="grid min-h-0 flex-1 grid-rows-[auto_1fr] md:grid-cols-[13.5rem_minmax(0,1fr)] md:grid-rows-1"
      >
        <nav aria-label="Silo navigation" className="min-w-0 overflow-x-auto border-b border-border bg-sidebar px-3 py-2 md:flex md:flex-col md:border-r md:border-b-0 md:py-5">
          <div className="mb-5 hidden items-center gap-3 border-b border-border px-3 pb-5 md:flex">
            <SiloMark className="size-8" />
            <span className="text-base font-semibold tracking-tight">Silo</span>
          </div>
          <TabsList className="flex h-auto w-max min-w-full items-stretch gap-1 bg-transparent p-0 md:w-full md:flex-1 md:flex-col" aria-label="App sections">
            <NavigationItems items={primaryItems} />
            <div className="mx-3 my-2 hidden border-t border-border md:mt-auto md:block" aria-hidden="true" />
            <TabsTrigger
              value="settings"
              data-appearance="borderless"
              aria-expanded={settingsOpen}
              aria-controls={settingsOpen ? "settings-sections" : undefined}
              className="h-10 min-w-fit justify-center gap-2 rounded-md border-0 bg-transparent px-3 py-2 text-xs text-muted-foreground shadow-none focus-visible:ring-2 focus-visible:ring-sidebar-ring/70 md:min-w-0 md:w-full md:justify-start md:text-[13px]"
            >
              <Settings2 className="size-4" />
              <span className="md:flex-1 md:text-left">Settings</span>
              <ChevronRight className={cn("size-3.5 transition-transform", settingsOpen && "rotate-90")} />
            </TabsTrigger>
          </TabsList>
          {settingsOpen && <SettingsNavigation section={settingsSection} onSectionChange={onSettingsSectionChange} />}
        </nav>
        <div className="min-h-0 min-w-0 overflow-y-auto">{children}</div>
      </Tabs>
    </SiloWindow>
  )
}
