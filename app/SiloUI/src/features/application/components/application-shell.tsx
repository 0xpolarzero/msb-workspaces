import { useState, type ReactNode } from "react"
import { Activity, Bell, Boxes, ChevronRight, CircleAlert, File, GitFork, HardDrive, KeyRound, LayoutDashboard, Loader2, Network, Settings2, SlidersHorizontal, Terminal } from "lucide-react"

import { SiloMark } from "@/components/silo-mark"
import { SiloWindow } from "@/components/silo-window"
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip"
import { ApplicationTitleBar } from "@/features/application/components/application-title-bar"
import type { ActiveRuntimeRepairPresentation, ApplicationTab, SettingsSection, WorkspaceSection } from "@/features/application/model/application-source"
import { cn } from "@/lib/utils"

export interface ApplicationNavigationLoading {
  tabs?: Partial<Record<ApplicationTab, boolean>>
  workspaceSections?: Partial<Record<WorkspaceSection, boolean>>
  settingsSections?: Partial<Record<SettingsSection, boolean>>
}

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

function NavigationLoadingIndicator({ loading }: { loading: boolean }) {
  if (!loading) return null
  return <Loader2 data-navigation-loading-indicator aria-hidden="true" className="size-3.5 shrink-0 animate-spin" />
}

function NavigationTooltip({ label, collapsed, children }: { label: string; collapsed: boolean; children: ReactNode }) {
  if (!collapsed) return children
  return <Tooltip>
    <TooltipTrigger asChild>{children}</TooltipTrigger>
    <TooltipContent side="right">{label}</TooltipContent>
  </Tooltip>
}

function NavigationButton({
  id,
  label,
  icon: Icon,
  active,
  tone = "default",
  loading = false,
  reserveDisclosure = false,
  collapsed,
  onClick,
}: {
  id: ApplicationTab
  label: string
  icon: typeof Boxes
  active: boolean
  tone?: "default" | "danger" | "warning"
  loading?: boolean
  reserveDisclosure?: boolean
  collapsed: boolean
  onClick: () => void
}) {
  return (
    <NavigationTooltip label={label} collapsed={collapsed}>
    <button
      id={`application-nav-${id}`}
      type="button"
      data-navigation-level="primary"
      data-navigation-tone={tone}
      aria-current={active ? "page" : undefined}
      aria-controls={`application-panel-${id}`}
      aria-busy={loading || undefined}
      onClick={onClick}
      className={cn(
        "relative flex h-10 w-full min-w-0 flex-none items-center gap-2 rounded-md py-2 text-[13px] transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sidebar-ring/70",
        collapsed ? "justify-center px-0" : "justify-start px-3",
        tone === "danger"
          ? "text-destructive hover:bg-destructive/[0.07] hover:text-destructive"
          : tone === "warning"
            ? "text-amber-700 hover:bg-amber-500/[0.08] hover:text-amber-700 dark:text-amber-400 dark:hover:text-amber-400"
          : "text-muted-foreground hover:bg-sidebar-accent hover:text-sidebar-accent-foreground",
        active && (tone === "danger"
          ? "bg-destructive/10 font-medium text-destructive"
          : tone === "warning"
            ? "bg-amber-500/10 font-medium text-amber-800 dark:text-amber-300"
          : "bg-sidebar-accent font-medium text-sidebar-accent-foreground"),
        reserveDisclosure && !collapsed && "pr-10",
      )}
    >
      {!(collapsed && loading) && <Icon aria-hidden="true" className="size-4 shrink-0" />}
      <span className={collapsed ? "sr-only" : "flex-1 text-left"}>{label}</span>
      <NavigationLoadingIndicator loading={loading} />
    </button>
    </NavigationTooltip>
  )
}

function DisclosureNavigationItem({
  id,
  label,
  icon,
  active,
  expanded,
  collapsed,
  onSelect,
  onToggle,
  children,
}: {
  id: "workspaces" | "settings"
  label: string
  icon: typeof Boxes
  active: boolean
  expanded: boolean
  collapsed: boolean
  onSelect: () => void
  onToggle: () => void
  children: ReactNode
}) {
  const menuID = `${id}-sections`

  return (
    <div className="grid w-full gap-1">
      <div className="relative w-full">
        <NavigationButton id={id} label={label} icon={icon} active={active} collapsed={collapsed} reserveDisclosure onClick={onSelect} />
        {!collapsed && <button
          type="button"
          aria-label={`${expanded ? "Collapse" : "Expand"} ${label} menu`}
          aria-expanded={expanded}
          aria-controls={menuID}
          onClick={onToggle}
          className="absolute top-1 right-1 z-10 grid size-8 place-items-center rounded-md text-foreground/65 hover:bg-sidebar-accent hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sidebar-ring/70"
        >
          <ChevronRight className={cn("size-4 transition-transform", expanded && "rotate-90")} />
        </button>}
      </div>
      {(expanded || collapsed) && <div id={menuID}>{children}</div>}
    </div>
  )
}

function SubNavigation<Section extends string>({
  label,
  items,
  section,
  active,
  attention,
  loading,
  collapsed,
  onSelect,
}: {
  label: string
  items: ReadonlyArray<{ id: Section; label: string; icon: typeof Boxes }>
  section: Section
  active: boolean
  attention?: { section: Section; errors: number; warnings: number } | null
  loading?: Partial<Record<Section, boolean>>
  collapsed: boolean
  onSelect: (section: Section) => void
}) {
  return (
    <div role="group" aria-label={label} className={cn("grid gap-1", collapsed ? "w-full" : "ml-3 w-[calc(100%-0.75rem)] border-l border-border pl-2")}>
      {items.map(({ id, label: itemLabel, icon: Icon }) => (
        <NavigationTooltip key={id} label={itemLabel} collapsed={collapsed}>
        <button
          type="button"
          aria-current={active && section === id ? "page" : undefined}
          aria-busy={loading?.[id] || undefined}
          onClick={() => onSelect(id)}
          className={cn(
            "relative flex h-8 w-full min-w-0 items-center gap-2 rounded-md text-xs text-muted-foreground transition-colors hover:bg-muted hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sidebar-ring/70",
            collapsed ? "justify-center px-0" : "justify-start px-2.5",
            active && section === id && "bg-muted font-medium text-foreground",
          )}
        >
          {!(collapsed && loading?.[id]) && <Icon aria-hidden="true" className="size-3.5 shrink-0" />}
          <span className={collapsed ? "sr-only" : "flex-1 text-left"}>{itemLabel}</span>
          {collapsed && attention?.section === id && <span
            role="status"
            aria-label={`${attention.errors} sandbox errors, ${attention.warnings} sandbox warnings`}
            className={cn("absolute top-1 right-1 size-1.5 rounded-full", attention.errors > 0 ? "bg-destructive" : "bg-amber-500")}
          />}
          {!collapsed && attention?.section === id && (
            <span className="flex shrink-0 items-center gap-1">
              <TooltipProvider delayDuration={150}>
                {attention.errors > 0 && (
                  <Tooltip>
                    <TooltipTrigger asChild>
                      <span
                        role="status"
                        aria-label={`${attention.errors} sandbox ${attention.errors === 1 ? "error" : "errors"}`}
                        className="inline-flex h-5 min-w-5 items-center justify-center rounded-full border border-destructive/20 bg-destructive/10 px-1 text-[10px] leading-none font-semibold tabular-nums text-destructive"
                      >
                        {attention.errors}
                      </span>
                    </TooltipTrigger>
                    <TooltipContent>{attention.errors} sandbox {attention.errors === 1 ? "needs" : "need"} attention</TooltipContent>
                  </Tooltip>
                )}
                {attention.warnings > 0 && (
                  <Tooltip>
                    <TooltipTrigger asChild>
                      <span
                        role="status"
                        aria-label={`${attention.warnings} sandbox ${attention.warnings === 1 ? "warning" : "warnings"}`}
                        className="inline-flex h-5 min-w-5 items-center justify-center rounded-full border border-amber-500/20 bg-amber-500/10 px-1 text-[10px] leading-none font-semibold tabular-nums text-amber-700 dark:text-amber-400"
                      >
                        {attention.warnings}
                      </span>
                    </TooltipTrigger>
                    <TooltipContent>{attention.warnings} sandbox {attention.warnings === 1 ? "has" : "have"} a warning</TooltipContent>
                  </Tooltip>
                )}
              </TooltipProvider>
              </span>
            )}
          <NavigationLoadingIndicator loading={loading?.[id] ?? false} />
        </button>
        </NavigationTooltip>
      ))}
    </div>
  )
}

export function ApplicationShell({
  activeTab,
  workspaceSection,
  settingsSection,
  systemIssueStatus,
  workspaceAttention,
  navigationLoading,
  onTabChange,
  onWorkspaceSectionChange,
  onSettingsSectionChange,
  canGoBack,
  canGoForward,
  onGoBack,
  onGoForward,
  children,
}: {
  activeTab: ApplicationTab
  workspaceSection: WorkspaceSection
  settingsSection: SettingsSection
  systemIssueStatus: ActiveRuntimeRepairPresentation["status"] | null
  workspaceAttention: { errors: number; warnings: number }
  navigationLoading?: ApplicationNavigationLoading
  onTabChange: (tab: ApplicationTab) => void
  onWorkspaceSectionChange: (section: WorkspaceSection) => void
  onSettingsSectionChange: (section: SettingsSection) => void
  canGoBack: boolean
  canGoForward: boolean
  onGoBack: () => void
  onGoForward: () => void
  children: ReactNode
}) {
  const [workspaceMenuOpen, setWorkspaceMenuOpen] = useState(activeTab === "workspaces")
  const [settingsMenuOpen, setSettingsMenuOpen] = useState(activeTab === "settings")
  const [collapsed, setCollapsed] = useState(() => window.matchMedia?.("(max-width: 767px)").matches ?? false)

  function selectTab(tab: ApplicationTab) {
    if (tab === "workspaces") setWorkspaceMenuOpen(true)
    if (tab === "settings") setSettingsMenuOpen(true)
    onTabChange(tab)
  }

  return (
    <TooltipProvider delayDuration={300}>
    <SiloWindow title="Silo" label="Silo" className={collapsed ? "[--sidebar-width:3.5rem]" : "[--sidebar-width:13.5rem]"} titleBar={
      <ApplicationTitleBar collapsed={collapsed} onToggleSidebar={() => setCollapsed((current) => !current)} canGoBack={canGoBack} canGoForward={canGoForward} onGoBack={onGoBack} onGoForward={onGoForward} />
    }>
      <div className="grid min-h-0 flex-1 grid-cols-[var(--sidebar-width)_minmax(0,1fr)]">
        <nav id="application-sidebar" aria-label="Silo navigation" data-collapsed={collapsed} className={cn("flex min-h-0 min-w-0 flex-col overflow-x-hidden overflow-y-auto border-r border-border bg-sidebar py-4", collapsed ? "px-2" : "px-3")}>
          <div className={cn("mb-4 flex shrink-0 items-center gap-3 border-b border-border pb-4", collapsed ? "justify-center" : "px-3")}>
            <SiloMark className={collapsed ? "size-7" : "size-8"} />
            <span className={collapsed ? "sr-only" : "text-base font-semibold tracking-tight"}>Silo</span>
          </div>
          <div className="flex w-full flex-1 flex-col items-start gap-1">
            <div className="grid w-full gap-1">
              <DisclosureNavigationItem
                id="workspaces"
                label="Sandboxes"
                icon={Boxes}
                active={activeTab === "workspaces"}
                expanded={workspaceMenuOpen}
                collapsed={collapsed}
                onSelect={() => selectTab("workspaces")}
                onToggle={() => setWorkspaceMenuOpen((open) => !open)}
              >
                <SubNavigation
                  label="Sandbox sections"
                  items={workspaceItems}
                  section={workspaceSection}
                  active={activeTab === "workspaces"}
                  collapsed={collapsed}
                  attention={workspaceAttention.errors > 0 || workspaceAttention.warnings > 0
                    ? { section: "overview", ...workspaceAttention }
                    : null}
                  loading={navigationLoading?.workspaceSections}
                  onSelect={(section) => {
                    onWorkspaceSectionChange(section)
                    setWorkspaceMenuOpen(true)
                  }}
                />
              </DisclosureNavigationItem>
              {primaryItems.map(({ id, label, icon }) => (
                <NavigationButton key={id} id={id} label={label} icon={icon} active={activeTab === id} collapsed={collapsed} loading={navigationLoading?.tabs?.[id]} onClick={() => selectTab(id)} />
              ))}
            </div>
            <div className="mt-auto grid w-full gap-1">
              <div className={cn("my-2 border-t border-border", !collapsed && "mx-3")} aria-hidden="true" />
              {systemIssueStatus && (
                <NavigationButton
                  id="system"
                  label="System issue"
                  icon={CircleAlert}
                  loading={navigationLoading?.tabs?.system}
                  active={activeTab === "system"}
                  collapsed={collapsed}
                  tone={systemIssueStatus === "repairing" ? "warning" : "danger"}
                  onClick={() => selectTab("system")}
                />
              )}
              <DisclosureNavigationItem
                id="settings"
                label="Settings"
                icon={Settings2}
                active={activeTab === "settings"}
                expanded={settingsMenuOpen}
                collapsed={collapsed}
                onSelect={() => selectTab("settings")}
                onToggle={() => setSettingsMenuOpen((open) => !open)}
              >
                <SubNavigation
                  label="Settings sections"
                  items={settingsItems}
                  section={settingsSection}
                  active={activeTab === "settings"}
                  collapsed={collapsed}
                  loading={navigationLoading?.settingsSections}
                  onSelect={(section) => {
                    onSettingsSectionChange(section)
                    setSettingsMenuOpen(true)
                  }}
                />
              </DisclosureNavigationItem>
            </div>
          </div>
        </nav>
        <div className={cn("min-h-0 min-w-0", activeTab === "workspaces" ? "overflow-hidden" : "overflow-y-auto")}>{children}</div>
      </div>
    </SiloWindow>
    </TooltipProvider>
  )
}
