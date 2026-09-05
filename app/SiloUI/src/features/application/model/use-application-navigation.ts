import { useCallback, useEffect, useState } from "react"

import type { ApplicationTab, SettingsSection, WorkspaceSection } from "./application-source"

interface Location {
  tab: ApplicationTab
  workspaceSection: WorkspaceSection
  settingsSection: SettingsSection
}

interface History {
  entries: Location[]
  index: number
}

function sameDestination(left: Location, right: Location) {
  return left.tab === right.tab
    && (left.tab !== "workspaces" || left.workspaceSection === right.workspaceSection)
    && (left.tab !== "settings" || left.settingsSection === right.settingsSection)
}

function withoutSystemIssue(history: History): History {
  if (!history.entries.some(({ tab }) => tab === "system")) return history
  const entries: Location[] = []
  let index = 0
  history.entries.forEach((entry, position) => {
    if (entry.tab === "system" && position !== history.index) return
    const destination: Location = entry.tab === "system"
      ? { ...entry, tab: "workspaces", workspaceSection: "overview" }
      : entry
    if (!entries.length || !sameDestination(entries.at(-1)!, destination)) entries.push(destination)
    if (position <= history.index) index = entries.length - 1
  })
  return { entries, index }
}

export function useApplicationNavigation(hasSystemIssue: boolean) {
  const [storedHistory, setHistory] = useState<History>({
    entries: [{ tab: "workspaces", workspaceSection: "overview", settingsSection: "general" }],
    index: 0,
  })
  const history = hasSystemIssue ? storedHistory : withoutSystemIssue(storedHistory)

  useEffect(() => {
    // A resolved issue is removed from history as well as the sidebar.
    // oxlint-disable-next-line react/set-state-in-effect
    if (!hasSystemIssue) setHistory(withoutSystemIssue)
  }, [hasSystemIssue])

  const navigate = useCallback((change: Partial<Location>) => {
    setHistory((stored) => {
      const current = hasSystemIssue ? stored : withoutSystemIssue(stored)
      const location = current.entries[current.index]
      const next = { ...location, ...change }
      if (sameDestination(location, next)) return current
      return { entries: [...current.entries.slice(0, current.index + 1), next], index: current.index + 1 }
    })
  }, [hasSystemIssue])

  const move = useCallback((offset: number) => {
    setHistory((stored) => {
      const current = hasSystemIssue ? stored : withoutSystemIssue(stored)
      const index = Math.max(0, Math.min(current.index + offset, current.entries.length - 1))
      return index === current.index ? current : { ...current, index }
    })
  }, [hasSystemIssue])

  return {
    ...history.entries[history.index],
    canGoBack: history.index > 0,
    canGoForward: history.index < history.entries.length - 1,
    goBack: () => move(-1),
    goForward: () => move(1),
    selectTab: (tab: ApplicationTab) => navigate({ tab }),
    selectWorkspaceSection: (workspaceSection: WorkspaceSection) => navigate({ tab: "workspaces", workspaceSection }),
    selectSettingsSection: (settingsSection: SettingsSection) => navigate({ tab: "settings", settingsSection }),
  }
}
