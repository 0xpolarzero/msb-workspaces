import { Code2, Compass, SquareTerminal } from "lucide-react"

import { ListRow, ListRowIcon } from "@/components/list-row"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import type { ApplicationPreferenceSelection } from "@/features/preferences/model/application-preferences"

function ApplicationPreferenceRow({
  icon: Icon,
  title,
  description,
  control,
  compact,
}: {
  icon: typeof Compass
  title: string
  description: string
  control: React.ReactNode
  compact: boolean
}) {
  return (
    <ListRow
      className={compact ? "hover:bg-muted/35 focus-within:bg-muted/35" : "gap-3 px-0 py-3 first:pt-0 last:pb-0"}
      icon={compact ? <ListRowIcon aria-hidden="true"><Icon className="size-3.5" /></ListRowIcon> : <Icon className="size-4 shrink-0 text-muted-foreground" aria-hidden="true" />}
      title={<div className={compact ? "text-xs font-medium" : "text-sm font-medium"}>{title}</div>}
      detail={description}
      detailClassName={compact ? "whitespace-normal" : "mt-0.5 whitespace-normal text-xs"}
      actions={<div className={compact ? "w-40 max-w-[45%] shrink-0" : "w-48 shrink-0"}>{control}</div>}
    />
  )
}

export function ApplicationPreferenceFields({
  value,
  onChange,
  compact = false,
}: {
  value: ApplicationPreferenceSelection
  compact?: boolean
  onChange: (value: ApplicationPreferenceSelection) => void
}) {
  function update<Key extends keyof ApplicationPreferenceSelection>(key: Key, selection: ApplicationPreferenceSelection[Key]) {
    onChange({ ...value, [key]: selection })
  }

  return (
    <>
      <ApplicationPreferenceRow
        compact={compact}
        icon={SquareTerminal}
        title="Terminal"
        description="Used by sandbox terminal shortcuts."
        control={(
          <Select value={value.terminal} onValueChange={(selection) => update("terminal", selection)}>
            <SelectTrigger className={compact ? "h-7 text-[11px]" : undefined} aria-label="Terminal"><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value="Terminal">Terminal</SelectItem>
              <SelectItem value="iTerm">iTerm</SelectItem>
              <SelectItem value="Warp">Warp</SelectItem>
            </SelectContent>
          </Select>
        )}
      />
      <ApplicationPreferenceRow
        compact={compact}
        icon={Code2}
        title="Code editor"
        description="Used when opening sandbox files."
        control={(
          <Select value={value.editor} onValueChange={(selection) => update("editor", selection)}>
            <SelectTrigger className={compact ? "h-7 text-[11px]" : undefined} aria-label="Code editor"><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value="Visual Studio Code">Visual Studio Code</SelectItem>
              <SelectItem value="Cursor">Cursor</SelectItem>
              <SelectItem value="Zed">Zed</SelectItem>
            </SelectContent>
          </Select>
        )}
      />
      <ApplicationPreferenceRow
        compact={compact}
        icon={Compass}
        title="Browser"
        description="Used when opening sandbox URLs."
        control={(
          <Select value={value.browser} onValueChange={(selection) => update("browser", selection)}>
            <SelectTrigger className={compact ? "h-7 text-[11px]" : undefined} aria-label="Browser"><SelectValue /></SelectTrigger>
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

