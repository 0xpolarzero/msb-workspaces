import { useState } from "react"
import { Accessibility, AppWindow, Eye, Power } from "lucide-react"

import { Checkbox } from "@/components/ui/checkbox"
import { Card, CardContent } from "@/components/ui/card"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { Switch } from "@/components/ui/switch"
import { PageHeader, SectionHeader } from "@/features/application/components/application-ui"
import type { ApplicationSource } from "@/features/application/model/application-source"

function SettingRow({ icon: Icon, title, description, control }: { icon: typeof Power; title: string; description: string; control: React.ReactNode }) {
  return (
    <div className="flex items-center gap-3 py-3 first:pt-0 last:pb-0">
      <Icon className="size-4 text-muted-foreground" />
      <div className="min-w-0 flex-1"><div className="text-sm font-medium">{title}</div><div className="mt-0.5 text-xs text-muted-foreground">{description}</div></div>
      <div className="w-48 shrink-0">{control}</div>
    </div>
  )
}

export function GeneralPage({ source }: { source: ApplicationSource }) {
  const [launchAtLogin, setLaunchAtLogin] = useState(source.preferences.launchAtLogin)
  const [startAtLaunch, setStartAtLaunch] = useState(source.preferences.startWorkspacesAtLaunch)
  const [startupWorkspaces, setStartupWorkspaces] = useState<Set<string>>(() => {
    const initial = source.workspaces.find(({ machine }) => machine.name === "dev") ?? source.workspaces[0]
    return new Set(initial ? [initial.machine.id] : [])
  })
  const [pollingCadence, setPollingCadence] = useState(source.preferences.pollingCadence)
  const [terminal, setTerminal] = useState(source.preferences.terminal)
  const [editor, setEditor] = useState(source.preferences.editor)
  const [reduceMotion, setReduceMotion] = useState(source.preferences.reduceMotion)

  function toggleStartupWorkspace(workspaceID: string, checked: boolean) {
    setStartupWorkspaces((current) => {
      const next = new Set(current)
      if (checked) next.add(workspaceID)
      else next.delete(workspaceID)
      return next
    })
  }

  return (
    <div className="mx-auto grid w-full max-w-3xl gap-6 px-4 py-5 sm:px-6 sm:py-6">
      <PageHeader title="General" description="Control startup, observation, and application preferences." />
      <section className="grid gap-3">
        <SectionHeader title="Startup" />
        <Card size="sm">
          <CardContent className="divide-y divide-border">
            <SettingRow icon={Power} title="Launch Silo at login" description="Keep workspace status and notifications available." control={<div className="flex justify-end"><Switch checked={launchAtLogin} onCheckedChange={setLaunchAtLogin} aria-label="Launch Silo at login" /></div>} />
            <SettingRow icon={Power} title="Start sandboxes at launch" description="Start selected sandboxes when Silo opens." control={<div className="flex justify-end"><Switch checked={startAtLaunch} onCheckedChange={setStartAtLaunch} aria-label="Start sandboxes at launch" /></div>} />
            {startAtLaunch && (
              <div className="grid gap-2 py-3 pl-7">
                {source.workspaces.map((workspace) => (
                  <label key={workspace.machine.id} className="flex items-center gap-2 text-sm"><Checkbox checked={startupWorkspaces.has(workspace.machine.id)} onCheckedChange={(checked) => toggleStartupWorkspace(workspace.machine.id, checked === true)} />{workspace.machine.name}</label>
                ))}
              </div>
            )}
          </CardContent>
        </Card>
      </section>
      <section className="grid gap-3">
        <SectionHeader title="Observation" />
        <Card size="sm"><CardContent><SettingRow icon={Eye} title="Polling cadence" description="How often Silo refreshes hidden app state." control={<Select value={pollingCadence} onValueChange={(value) => setPollingCadence(value as "15" | "30" | "60")}><SelectTrigger aria-label="Polling cadence"><SelectValue /></SelectTrigger><SelectContent><SelectItem value="15">15 seconds</SelectItem><SelectItem value="30">30 seconds</SelectItem><SelectItem value="60">60 seconds</SelectItem></SelectContent></Select>} /></CardContent></Card>
      </section>
      <section className="grid gap-3">
        <SectionHeader title="Applications" />
        <Card size="sm">
          <CardContent className="divide-y divide-border">
            <SettingRow icon={AppWindow} title="Terminal" description="Used by sandbox terminal shortcuts." control={<Select value={terminal} onValueChange={setTerminal}><SelectTrigger aria-label="Terminal"><SelectValue /></SelectTrigger><SelectContent><SelectItem value="Terminal">Terminal</SelectItem><SelectItem value="iTerm">iTerm</SelectItem><SelectItem value="Warp">Warp</SelectItem></SelectContent></Select>} />
            <SettingRow icon={AppWindow} title="Code editor" description="Used when opening workspace files." control={<Select value={editor} onValueChange={setEditor}><SelectTrigger aria-label="Code editor"><SelectValue /></SelectTrigger><SelectContent><SelectItem value="Visual Studio Code">Visual Studio Code</SelectItem><SelectItem value="Cursor">Cursor</SelectItem><SelectItem value="Zed">Zed</SelectItem></SelectContent></Select>} />
          </CardContent>
        </Card>
      </section>
      <section className="grid gap-3">
        <SectionHeader title="Accessibility" />
        <Card size="sm"><CardContent><SettingRow icon={Accessibility} title="Reduce motion" description="Disable nonessential interface animation." control={<div className="flex justify-end"><Switch checked={reduceMotion} onCheckedChange={setReduceMotion} aria-label="Reduce motion" /></div>} /></CardContent></Card>
      </section>
    </div>
  )
}
