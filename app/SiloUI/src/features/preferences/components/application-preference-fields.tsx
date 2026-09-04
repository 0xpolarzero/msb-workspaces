import { Code2, Compass, SquareTerminal } from "lucide-react"

import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import type { ApplicationPreferenceSelection } from "@/features/preferences/model/application-preferences"

function ApplicationPreferenceRow({
  icon: Icon,
  title,
  description,
  control,
}: {
  icon: typeof Compass
  title: string
  description: string
  control: React.ReactNode
}) {
  return (
    <div className="flex items-center gap-3 py-3 first:pt-0 last:pb-0">
      <Icon className="size-4 shrink-0 text-muted-foreground" aria-hidden="true" />
      <div className="min-w-0 flex-1">
        <div className="text-sm font-medium">{title}</div>
        <div className="mt-0.5 text-xs text-muted-foreground">{description}</div>
      </div>
      <div className="w-48 shrink-0">{control}</div>
    </div>
  )
}

export function ApplicationPreferenceFields({
  value,
  onChange,
}: {
  value: ApplicationPreferenceSelection
  onChange: (value: ApplicationPreferenceSelection) => void
}) {
  function update<Key extends keyof ApplicationPreferenceSelection>(key: Key, selection: ApplicationPreferenceSelection[Key]) {
    onChange({ ...value, [key]: selection })
  }

  return (
    <>
      <ApplicationPreferenceRow
        icon={SquareTerminal}
        title="Terminal"
        description="Used by sandbox terminal shortcuts."
        control={(
          <Select value={value.terminal} onValueChange={(selection) => update("terminal", selection)}>
            <SelectTrigger aria-label="Terminal"><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value="Terminal">Terminal</SelectItem>
              <SelectItem value="iTerm">iTerm</SelectItem>
              <SelectItem value="Warp">Warp</SelectItem>
            </SelectContent>
          </Select>
        )}
      />
      <ApplicationPreferenceRow
        icon={Code2}
        title="Code editor"
        description="Used when opening sandbox files."
        control={(
          <Select value={value.editor} onValueChange={(selection) => update("editor", selection)}>
            <SelectTrigger aria-label="Code editor"><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value="Visual Studio Code">Visual Studio Code</SelectItem>
              <SelectItem value="Cursor">Cursor</SelectItem>
              <SelectItem value="Zed">Zed</SelectItem>
            </SelectContent>
          </Select>
        )}
      />
      <ApplicationPreferenceRow
        icon={Compass}
        title="Browser"
        description="Used when opening sandbox URLs."
        control={(
          <Select value={value.browser} onValueChange={(selection) => update("browser", selection)}>
            <SelectTrigger aria-label="Browser"><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value="Safari">Safari</SelectItem>
              <SelectItem value="Google Chrome">Google Chrome</SelectItem>
              <SelectItem value="Firefox">Firefox</SelectItem>
            </SelectContent>
          </Select>
        )}
      />
    </>
  )
}

