import { useState, type ReactNode } from "react"
import { Activity, Bell, Boxes, ChevronRight, File, GitFork, HardDrive, KeyRound, LayoutDashboard, Network, Settings2, SlidersHorizontal, Terminal } from "lucide-react"

import { SiloMark } from "@/components/silo-mark"
import { SiloWindow } from "@/components/silo-window"
import type { ApplicationTab, SettingsSection, WorkspaceSection } from "@/features/application/model/application-source"
import { cn } from "@/lib/utils"

const primaryItems = [
  { id: "github", label: "GitHub", icon: GitFork },
  { id: "secrets", label: "Secrets", icon: KeyRound },
  { id: "backup", label: "Backup", icon: HardDrive },
] as const

const workspaceItems = [
  { id: "overview", label: "Overview", icon: LayoutDashboard },
  { id: "files", label: "Files", icon: File },
  { id: "logs", label: "Logs", icon: Terminal },
  { id: "network", label: "Network", icon: Network },
  { id: "activity", label: "Activity", icon: Activity },
] as const

const settingsItems = [
  { id: "general", label: "General", icon: SlidersHorizontal },
  { id: "notifications", label: "Notifications", icon: Bell },
] as const

function NavigationButton({
  id,
  label,
  icon: Icon,
  active,
  reserveDisclosure = false,
  onClick,
}: {
  id: ApplicationTab
  label: string
  icon: typeof Boxes
  active: boolean
  reserveDisclosure?: boolean
  onClick: () => void
}) {
  return (
    <button
      id={`application-nav-${id}`}
      type="button"
      data-navigation-level="primary"
      aria-current={active ? "page" : undefined}
      aria-controls={`application-panel-${id}`}
      onClick={onClick}
      className={cn(
        "flex h-10 min-w-fit flex-none items-center justify-center gap-2 rounded-md px-3 py-2 text-xs text-muted-foreground transition-colors hover:bg-sidebar-accent hover:text-sidebar-accent-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sidebar-ring/70 md:min-w-0 md:w-full md:justify-start md:text-[13px]",
        active && "bg-sidebar-accent font-medium text-sidebar-accent-foreground",
        reserveDisclosure && "pr-10",
      )}
    >
      <Icon className="size-4" />
      <span className="md:flex-1 md:text-left">{label}</span>
    </button>
  )
}

function DisclosureNavigationItem({
  id,
  label,
  icon,
  active,
  expanded,
  onSelect,
  onToggle,
  children,
}: {
  id: "workspaces" | "settings"
  label: string
  icon: typeof Boxes
  active: boolean
  expanded: boolean
  onSelect: () => void
  onToggle: () => void
  children: ReactNode
}) {
  const menuID = `${id}-sections`

  return (
    <div className="flex gap-1 md:grid md:w-full">
      <div className="relative md:w-full">
        <NavigationButton id={id} label={label} icon={icon} active={active} reserveDisclosure onClick={onSelect} />
        <button
          type="button"
          aria-label={`${expanded ? "Collapse" : "Expand"} ${label} menu`}
          aria-expanded={expanded}
          aria-controls={menuID}
          onClick={onToggle}
          className="absolute top-1 right-1 z-10 grid size-8 place-items-center rounded-md text-foreground/65 hover:bg-sidebar-accent hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sidebar-ring/70"
        >
          <ChevronRight className={cn("size-4 transition-transform", expanded && "rotate-90")} />
        </button>
      </div>
      {expanded && <div id={menuID}>{children}</div>}
    </div>
  )
}

function SubNavigation<Section extends string>({
  label,
  items,
  section,
  active,
  onSelect,
}: {
  label: string
  items: ReadonlyArray<{ id: Section; label: string; icon: typeof Boxes }>
  section: Section
  active: boolean
  onSelect: (section: Section) => void
}) {
  return (
    <div role="group" aria-label={label} className="flex gap-1 md:ml-3 md:grid md:w-[calc(100%-0.75rem)] md:border-l md:border-border md:pl-2">
      {items.map(({ id, label: itemLabel, icon: Icon }) => (
        <button
          key={id}
          type="button"
          aria-current={active && section === id ? "page" : undefined}
          onClick={() => onSelect(id)}
          className={cn(
            "flex h-8 min-w-fit items-center justify-center gap-2 rounded-md px-2.5 text-xs text-muted-foreground transition-colors hover:bg-muted hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sidebar-ring/70 md:w-full md:justify-start",
            active && section === id && "bg-muted font-medium text-foreground",
          )}
        >
          <Icon className="size-3.5" />
          {itemLabel}
        </button>
      ))}
    </div>
  )
}

export function ApplicationShell({
  activeTab,
  workspaceSection,
  settingsSection,
  onTabChange,
  onWorkspaceSectionChange,
  onSettingsSectionChange,
  children,
}: {
  activeTab: ApplicationTab
  workspaceSection: WorkspaceSection
  settingsSection: SettingsSection
  onTabChange: (tab: ApplicationTab) => void
  onWorkspaceSectionChange: (section: WorkspaceSection) => void
  onSettingsSectionChange: (section: SettingsSection) => void
  children: ReactNode
}) {
  const [workspaceMenuOpen, setWorkspaceMenuOpen] = useState(activeTab === "workspaces")
  const [settingsMenuOpen, setSettingsMenuOpen] = useState(activeTab === "settings")

  function selectTab(tab: ApplicationTab) {
    if (tab === "workspaces") setWorkspaceMenuOpen(true)
    if (tab === "settings") setSettingsMenuOpen(true)
    onTabChange(tab)
  }

  return (
    <SiloWindow title="Silo" label="Silo">
      <div className="grid min-h-0 flex-1 grid-rows-[auto_1fr] md:grid-cols-[13.5rem_minmax(0,1fr)] md:grid-rows-1">
        <nav aria-label="Silo navigation" className="min-w-0 overflow-x-auto border-b border-border bg-sidebar px-3 py-2 md:flex md:flex-col md:border-r md:border-b-0 md:py-5">
          <div className="mb-5 hidden items-center gap-3 border-b border-border px-3 pb-5 md:flex">
            <SiloMark className="size-8" />
            <span className="text-base font-semibold tracking-tight">Silo</span>
          </div>
          <div className="flex w-max min-w-full items-start gap-1 md:min-h-0 md:w-full md:flex-1 md:flex-col">
            <div className="flex gap-1 md:grid md:w-full">
              <DisclosureNavigationItem
                id="workspaces"
                label="Sandboxes"
                icon={Boxes}
                active={activeTab === "workspaces"}
                expanded={workspaceMenuOpen}
                onSelect={() => selectTab("workspaces")}
                onToggle={() => setWorkspaceMenuOpen((open) => !open)}
              >
                <SubNavigation
                  label="Sandbox sections"
                  items={workspaceItems}
                  section={workspaceSection}
                  active={activeTab === "workspaces"}
                  onSelect={(section) => {
                    onWorkspaceSectionChange(section)
                    selectTab("workspaces")
                  }}
                />
              </DisclosureNavigationItem>
              {primaryItems.map(({ id, label, icon }) => (
                <NavigationButton key={id} id={id} label={label} icon={icon} active={activeTab === id} onClick={() => selectTab(id)} />
              ))}
            </div>
            <div className="flex gap-1 md:mt-auto md:grid md:w-full">
              <div className="mx-3 my-2 hidden border-t border-border md:block" aria-hidden="true" />
              <DisclosureNavigationItem
                id="settings"
                label="Settings"
                icon={Settings2}
                active={activeTab === "settings"}
                expanded={settingsMenuOpen}
                onSelect={() => selectTab("settings")}
                onToggle={() => setSettingsMenuOpen((open) => !open)}
              >
                <SubNavigation
                  label="Settings sections"
                  items={settingsItems}
                  section={settingsSection}
                  active={activeTab === "settings"}
                  onSelect={(section) => {
                    onSettingsSectionChange(section)
                    selectTab("settings")
                  }}
                />
              </DisclosureNavigationItem>
            </div>
          </div>
        </nav>
        <div className="min-h-0 min-w-0 overflow-y-auto">{children}</div>
      </div>
    </SiloWindow>
  )
}
