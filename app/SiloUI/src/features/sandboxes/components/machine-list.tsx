import { useEffect, useMemo, useRef, useState, type DragEvent, type KeyboardEvent, type ReactNode } from "react"
import { Check, Copy, GripVertical, Monitor, Pencil, Plus, Server, Trash2 } from "lucide-react"

import { InlineConfirmation } from "@/components/inline-confirmation"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"
import type { SetupMachineConfiguration, SetupVirtualMachineConfiguration } from "@/contracts/silo"
import {
  configurationRequest,
  duplicateMachine,
  maximumMachineCount,
  newSSHMachine,
  newVirtualMachine,
  supportedCPUs,
  supportedMemoryGiB,
  supportedStorageGiB,
  validateMachine,
  type MachineValidationErrors,
} from "@/features/onboarding/model/machine-configuration"
import { SandboxAction, SandboxList, SandboxListItem, SandboxListRow, type SandboxIconState, type SandboxRowTone } from "@/features/sandboxes/components/sandbox-list"
import { machineSummary } from "@/features/sandboxes/model/machine-summary"

interface MachineEditorState {
  draft: SetupMachineConfiguration
  originalID?: string
  insertAt: number
  displayAfterID?: string
}

export interface MachineRowPresentation {
  detail?: ReactNode
  detailClassName?: string
  icon?: ReactNode
  iconState?: SandboxIconState
  actions?: ReactNode
  actionsClassName?: string
  tone?: SandboxRowTone
  busy?: boolean
  suppressInteractions?: boolean
}

interface MachineListProps {
  machines: readonly SetupMachineConfiguration[]
  onMachinesChange: (machines: SetupMachineConfiguration[]) => void
  getRowPresentation?: (machine: SetupMachineConfiguration) => MachineRowPresentation
  sortPriority?: (machine: SetupMachineConfiguration) => number
  interactionDisabled?: boolean
  summary?: ReactNode
  footer?: ReactNode
}

function SelectField({ label, value, values, suffix, error, onChange }: {
  label: string
  value: number
  values: readonly number[]
  suffix: string
  error?: string
  onChange: (value: number) => void
}) {
  return (
    <label className="grid min-w-0 gap-1 text-[11px] font-medium text-muted-foreground">
      {label}
      <select
        aria-label={label}
        aria-invalid={Boolean(error)}
        className="h-8 min-w-0 rounded-lg border border-input bg-background px-2 text-xs text-foreground outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50 aria-invalid:border-destructive"
        value={value}
        onChange={(event) => onChange(Number(event.target.value))}
      >
        {values.map((option) => <option key={option} value={option}>{option} {suffix}</option>)}
      </select>
      {error && <span className="text-destructive">{error}</span>}
    </label>
  )
}

function TextField({ label, value, error, firstField = false, inputRef, ...props }: {
  label: string
  value: string
  error?: string
  firstField?: boolean
  inputRef?: React.RefObject<HTMLInputElement | null>
} & Omit<React.ComponentProps<typeof Input>, "value" | "aria-label">) {
  return (
    <label className="grid min-w-0 gap-1 text-[11px] font-medium text-muted-foreground">
      {label}
      <Input ref={firstField ? inputRef : undefined} aria-label={label} aria-invalid={Boolean(error)} value={value} {...props} />
      {error && <span className="text-destructive">{error}</span>}
    </label>
  )
}

function MachineEditor({ editor, machines, onCancel, onSave }: {
  editor: MachineEditorState
  machines: readonly SetupMachineConfiguration[]
  onCancel: () => void
  onSave: (machine: SetupMachineConfiguration) => void
}) {
  const [draft, setDraft] = useState(editor.draft)
  const [errors, setErrors] = useState<MachineValidationErrors>({})
  const firstField = useRef<HTMLInputElement>(null)

  useEffect(() => {
    firstField.current?.focus()
    firstField.current?.scrollIntoView?.({ block: "nearest" })
  }, [])

  function update(changes: Partial<SetupMachineConfiguration>) {
    setDraft((current) => ({ ...current, ...changes } as SetupMachineConfiguration))
    setErrors({})
  }

  function save() {
    const nextErrors = validateMachine(draft, machines, editor.originalID)
    if (!editor.originalID && machines.length >= maximumMachineCount) {
      nextErrors.form = `Configure no more than ${maximumMachineCount} sandboxes.`
    }
    setErrors(nextErrors)
    if (Object.keys(nextErrors).length === 0) onSave(draft)
  }

  return (
    <div className="grid min-w-0 gap-3 p-3" data-testid={`machine-editor-${draft.id}`}>
      <div className="flex min-w-0 items-center gap-2">
        {draft.kind === "vm" ? <Monitor className="size-4 shrink-0" aria-hidden="true" /> : <Server className="size-4 shrink-0" aria-hidden="true" />}
        <span className="min-w-0 flex-1 text-xs font-semibold">{draft.kind === "vm" ? "Virtual machine details" : "SSH machine details"}</span>
        <span className="rounded-full bg-muted px-2 py-0.5 text-[10px] uppercase text-muted-foreground">{draft.kind}</span>
      </div>

      <TextField
        firstField
        inputRef={firstField}
        label="Machine name"
        value={draft.name}
        error={errors.name}
        autoComplete="off"
        maxLength={32}
        onChange={(event) => update({ name: event.target.value })}
      />

      {draft.kind === "vm" ? (
        <div className="grid min-w-0 grid-cols-1 gap-2 sm:grid-cols-2">
          <SelectField label="CPU limit" value={draft.cpus} values={supportedCPUs} suffix="CPU" error={errors.cpus} onChange={(cpus) => update({ cpus } as Partial<SetupVirtualMachineConfiguration>)} />
          <SelectField label="CPU ceiling" value={draft.maxCPUs} values={supportedCPUs} suffix="CPU" error={errors.maxCPUs} onChange={(maxCPUs) => update({ maxCPUs } as Partial<SetupVirtualMachineConfiguration>)} />
          <SelectField label="Memory limit" value={draft.memoryGiB} values={supportedMemoryGiB} suffix="GB" error={errors.memoryGiB} onChange={(memoryGiB) => update({ memoryGiB } as Partial<SetupVirtualMachineConfiguration>)} />
          <SelectField label="Memory ceiling" value={draft.maxMemoryGiB} values={supportedMemoryGiB} suffix="GB" error={errors.maxMemoryGiB} onChange={(maxMemoryGiB) => update({ maxMemoryGiB } as Partial<SetupVirtualMachineConfiguration>)} />
          <SelectField label="Workspace storage" value={draft.workspaceStorageGiB} values={supportedStorageGiB} suffix="GB" error={errors.workspaceStorageGiB} onChange={(workspaceStorageGiB) => update({ workspaceStorageGiB } as Partial<SetupVirtualMachineConfiguration>)} />
          <SelectField label="Runtime storage" value={draft.runtimeStorageGiB} values={supportedStorageGiB} suffix="GB" error={errors.runtimeStorageGiB} onChange={(runtimeStorageGiB) => update({ runtimeStorageGiB } as Partial<SetupVirtualMachineConfiguration>)} />
        </div>
      ) : (
        <div className="grid min-w-0 grid-cols-1 gap-2 sm:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)_7rem]">
          <TextField label="SSH host" value={draft.host} error={errors.host} autoComplete="off" placeholder="server.example.com" onChange={(event) => update({ host: event.target.value })} />
          <TextField label="SSH user" value={draft.user} error={errors.user} autoComplete="username" placeholder="developer" onChange={(event) => update({ user: event.target.value })} />
          <label className="grid min-w-0 gap-1 text-[11px] font-medium text-muted-foreground">
            SSH port
            <Input
              aria-label="SSH port"
              aria-invalid={Boolean(errors.port)}
              type="number"
              inputMode="numeric"
              min={1}
              max={65_535}
              value={draft.port}
              onChange={(event) => update({ port: Number(event.target.value) })}
            />
            {errors.port && <span className="text-destructive">{errors.port}</span>}
          </label>
        </div>
      )}

      <div className="flex justify-end gap-2">
        <Button type="button" variant="outline" size="sm" onClick={onCancel}>Cancel</Button>
        <Button type="button" size="sm" onClick={save}>Save</Button>
      </div>
      {errors.form && <p className="text-xs text-destructive" role="alert">{errors.form}</p>}
    </div>
  )
}

export function MachineList({ machines, onMachinesChange, getRowPresentation, sortPriority, interactionDisabled = false, summary, footer }: MachineListProps) {
  const [addOpen, setAddOpen] = useState(false)
  const [editor, setEditor] = useState<MachineEditorState | null>(null)
  const [pendingDelete, setPendingDelete] = useState<string | null>(null)
  const [draggedID, setDraggedID] = useState<string | null>(null)
  const [announcement, setAnnouncement] = useState("")
  const [operationError, setOperationError] = useState("")

  const displayMachines = useMemo(() => {
    if (!sortPriority) {
      const next = [...machines]
      if (editor && !editor.originalID) next.splice(editor.insertAt, 0, editor.draft)
      return next
    }

    const next = [...machines]
      .map((machine, index) => ({ machine, index }))
      .sort((a, b) => sortPriority(a.machine) - sortPriority(b.machine) || a.index - b.index)
      .map(({ machine }) => machine)
    if (editor && !editor.originalID) {
      const sourceIndex = editor.displayAfterID ? next.findIndex(({ id }) => id === editor.displayAfterID) : -1
      next.splice(sourceIndex >= 0 ? sourceIndex + 1 : next.length, 0, editor.draft)
    }
    return next
  }, [editor, machines, sortPriority])

  function beginOperation() {
    setPendingDelete(null)
    setOperationError("")
    setEditor(null)
  }

  function startEdit(machine: SetupMachineConfiguration) {
    if (interactionDisabled) return
    beginOperation()
    setEditor({
      draft: structuredClone(machine),
      originalID: machine.id,
      insertAt: machines.findIndex(({ id }) => id === machine.id),
    })
  }

  function startAdd(kind: SetupMachineConfiguration["kind"]) {
    if (interactionDisabled) return
    beginOperation()
    setAddOpen(false)
    setEditor({
      draft: kind === "vm" ? newVirtualMachine(machines) : newSSHMachine(machines),
      insertAt: machines.length,
    })
  }

  function startDuplicate(machine: SetupMachineConfiguration) {
    if (interactionDisabled) return
    beginOperation()
    const sourceIndex = machines.findIndex(({ id }) => id === machine.id)
    setEditor({ draft: duplicateMachine(machine, machines), insertAt: sourceIndex + 1, displayAfterID: machine.id })
  }

  function save(machine: SetupMachineConfiguration) {
    if (interactionDisabled) return
    const updated = [...machines]
    if (editor?.originalID) {
      const index = updated.findIndex(({ id }) => id === editor.originalID)
      if (index < 0) return
      updated[index] = machine
    } else {
      updated.splice(editor?.insertAt ?? updated.length, 0, machine)
    }
    onMachinesChange(configurationRequest(updated).machines)
    setEditor(null)
  }

  function remove(machine: SetupMachineConfiguration) {
    if (interactionDisabled) return
    if (pendingDelete !== machine.id) {
      beginOperation()
      setPendingDelete(machine.id)
      return
    }
    if (machines.length === 1) {
      setPendingDelete(null)
      setOperationError("At least one sandbox is required.")
      return
    }
    onMachinesChange(configurationRequest(machines.filter(({ id }) => id !== machine.id)).machines)
    setPendingDelete(null)
  }

  function reorder(id: string, targetIndex: number) {
    if (interactionDisabled) return
    const displayed = displayMachines.filter((machine) => machines.some(({ id: configuredID }) => configuredID === machine.id))
    const from = displayed.findIndex((machine) => machine.id === id)
    const boundedTarget = Math.max(0, Math.min(targetIndex, displayed.length - 1))
    if (from < 0 || from === boundedTarget) return
    beginOperation()
    const moved = displayed[from]

    if (sortPriority) {
      const target = displayed[boundedTarget]
      const priority = sortPriority(moved)
      if (sortPriority(target) !== priority) {
        setAnnouncement(`${moved.name} can only be reordered within its status group.`)
        return
      }

      const bucket = machines.filter((machine) => sortPriority(machine) === priority)
      const bucketFrom = bucket.findIndex((machine) => machine.id === moved.id)
      const bucketTarget = bucket.findIndex((machine) => machine.id === target.id)
      const [bucketMoved] = bucket.splice(bucketFrom, 1)
      bucket.splice(bucketTarget, 0, bucketMoved)
      let bucketIndex = 0
      const updated = machines.map((machine) => sortPriority(machine) === priority ? bucket[bucketIndex++] : machine)
      onMachinesChange(configurationRequest(updated).machines)
      setAnnouncement(`${moved.name} moved to position ${boundedTarget + 1} of ${displayed.length}.`)
      return
    }

    const updated = [...machines]
    const configuredFrom = updated.findIndex((machine) => machine.id === id)
    const [configuredMoved] = updated.splice(configuredFrom, 1)
    updated.splice(boundedTarget, 0, configuredMoved)
    onMachinesChange(configurationRequest(updated).machines)
    setAnnouncement(`${moved.name} moved to position ${boundedTarget + 1} of ${displayed.length}.`)
  }

  function handleReorderKey(event: KeyboardEvent<HTMLElement>, machine: SetupMachineConfiguration, index: number) {
    if (interactionDisabled) return
    if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return
    event.preventDefault()
    reorder(machine.id, index + (event.key === "ArrowUp" ? -1 : 1))
  }

  function drop(event: DragEvent, targetIndex: number) {
    event.preventDefault()
    if (interactionDisabled) return
    const id = draggedID || event.dataTransfer.getData("text/plain")
    if (id) reorder(id, targetIndex)
    setDraggedID(null)
  }

  return (
    <>
      <div aria-labelledby="machine-list-heading" className="flex h-full min-h-0 flex-col">
        <div className="mb-2 flex min-w-0 shrink-0 flex-wrap items-center justify-between gap-2 text-xs">
          <div className="min-w-0">
            <h3 id="machine-list-heading" className="font-medium">Sandboxes</h3>
            <p className="text-[11px] text-muted-foreground">{summary ?? <>{machines.length} configured · {machines.filter(({ kind }) => kind === "vm").length} VM · {machines.filter(({ kind }) => kind === "ssh").length} SSH</>}</p>
          </div>
          <Popover open={addOpen} onOpenChange={setAddOpen}>
            <PopoverTrigger asChild>
              <Button type="button" variant="outline" size="xs" aria-haspopup="menu" disabled={interactionDisabled} onClick={beginOperation}>
                <Plus aria-hidden="true" data-icon="inline-start" /> Add
              </Button>
            </PopoverTrigger>
            <PopoverContent role="menu" aria-label="Add sandbox" align="end" className="grid w-48 gap-1 p-1">
              <button type="button" role="menuitem" className="rounded-sm px-2 py-1.5 text-left text-xs hover:bg-accent focus:bg-accent focus:outline-none" onClick={() => startAdd("vm")}>New sandbox</button>
              <button type="button" role="menuitem" className="rounded-sm px-2 py-1.5 text-left text-xs hover:bg-accent focus:bg-accent focus:outline-none" onClick={() => startAdd("ssh")}>Connect a machine via SSH</button>
            </PopoverContent>
          </Popover>
        </div>

        <SandboxList label="Configured sandboxes" className="max-h-full min-h-0" data-testid="machine-list">
            {displayMachines.map((machine, index) => {
              const isEditing = editor?.draft.id === machine.id
              const presentation = getRowPresentation?.(machine)
              const deleteArmed = pendingDelete === machine.id
              return (
                <SandboxListItem
                  key={machine.id}
                  data-machine-id={machine.id}
                  data-sandbox-name={machine.name}
                  aria-busy={presentation?.busy || undefined}
                  className="min-w-0 bg-background"
                  onDragOver={(event) => event.preventDefault()}
                  onDrop={(event) => drop(event, index)}
                >
                  {isEditing && editor ? (
                    <MachineEditor editor={editor} machines={machines} onCancel={() => setEditor(null)} onSave={save} />
                  ) : (
                    <SandboxListRow
                      name={machine.name}
                      kind={machine.kind}
                      iconState={presentation?.iconState}
                      icon={presentation?.icon}
                      tone={presentation?.tone}
                      detail={presentation?.detail ?? machineSummary(machine)}
                      detailClassName={presentation?.detailClassName}
                      leading={presentation?.suppressInteractions ? undefined : <span
                        role="button"
                        tabIndex={interactionDisabled ? -1 : 0}
                        draggable={!editor && !interactionDisabled}
                        aria-label={`Reorder ${machine.name}`}
                        aria-disabled={interactionDisabled || undefined}
                        className="grid size-7 shrink-0 cursor-grab place-items-center rounded-md text-muted-foreground outline-none hover:bg-muted focus-visible:ring-3 focus-visible:ring-ring/50 active:cursor-grabbing aria-disabled:cursor-default aria-disabled:opacity-40"
                        onKeyDown={(event) => handleReorderKey(event, machine, index)}
                        onDragStart={(event) => {
                          beginOperation()
                          setDraggedID(machine.id)
                          event.dataTransfer.effectAllowed = "move"
                          event.dataTransfer.setData("text/plain", machine.id)
                        }}
                        onDragEnd={() => setDraggedID(null)}
                      >
                        <GripVertical className="size-4" aria-hidden="true" />
                      </span>}
                      actions={presentation?.actions}
                      actionsClassName={presentation?.actionsClassName}
                      hoverActions={presentation?.suppressInteractions ? undefined : <>
                        <SandboxAction label={`Edit ${machine.name}`} disabled={interactionDisabled} onClick={() => startEdit(machine)}><Pencil /></SandboxAction>
                        <SandboxAction label={`Duplicate ${machine.name}`} disabled={interactionDisabled} onClick={() => startDuplicate(machine)}><Copy /></SandboxAction>
                        <InlineConfirmation active={deleteArmed} onDismiss={() => setPendingDelete(null)}>
                          <SandboxAction
                            label={deleteArmed ? `Confirm deletion of ${machine.name}` : `Delete ${machine.name}`}
                            destructive={deleteArmed}
                            disabled={interactionDisabled}
                            onClick={() => remove(machine)}
                          >
                            {deleteArmed ? <Check /> : <Trash2 />}
                          </SandboxAction>
                        </InlineConfirmation>
                      </>}
                    />
                  )}
                </SandboxListItem>
              )
            })}
        </SandboxList>
        {footer && <div className="mt-3 shrink-0">{footer}</div>}
        {operationError && <p className="mt-2 text-xs text-destructive" role="alert">{operationError}</p>}
        <p className="sr-only" aria-live="polite">{announcement}</p>
      </div>
    </>
  )
}
