import { useEffect, useMemo, useRef, useState, type DragEvent, type KeyboardEvent, type ReactNode } from "react"
import { Check, Copy, GripVertical, Monitor, Pencil, Plus, Server, Trash2 } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"
import { ScrollArea } from "@/components/ui/scroll-area"
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip"
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
import type { WorkspaceProgressView } from "@/features/onboarding/model/onboarding-state"

interface MachineEditorState {
  draft: SetupMachineConfiguration
  originalID?: string
  insertAt: number
}

interface MachineListProps {
  machines: readonly SetupMachineConfiguration[]
  progress: WorkspaceProgressView
  onMachinesChange: (machines: SetupMachineConfiguration[]) => void
}

function IconAction({ label, destructive = false, children, ...props }: {
  label: string
  destructive?: boolean
  children: ReactNode
} & Omit<React.ComponentProps<typeof Button>, "children" | "aria-label">) {
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Button
          type="button"
          variant={destructive ? "destructive" : "ghost"}
          size="icon-xs"
          aria-label={label}
          {...props}
        >
          {children}
        </Button>
      </TooltipTrigger>
      <TooltipContent>{label}</TooltipContent>
    </Tooltip>
  )
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
      nextErrors.form = `Configure no more than ${maximumMachineCount} machines.`
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

function machineSummary(machine: SetupMachineConfiguration): string {
  if (machine.kind === "ssh") return `${machine.user}@${machine.host}:${machine.port}`
  return `${machine.cpus} CPU · ${machine.memoryGiB} GB RAM · ${machine.workspaceStorageGiB} GB workspace`
}

export function MachineList({ machines, progress, onMachinesChange }: MachineListProps) {
  const [addOpen, setAddOpen] = useState(false)
  const [editor, setEditor] = useState<MachineEditorState | null>(null)
  const [pendingDelete, setPendingDelete] = useState<string | null>(null)
  const [draggedID, setDraggedID] = useState<string | null>(null)
  const [announcement, setAnnouncement] = useState("")
  const [operationError, setOperationError] = useState("")

  const displayMachines = useMemo(() => {
    if (!editor || editor.originalID) return machines
    const next = [...machines]
    next.splice(editor.insertAt, 0, editor.draft)
    return next
  }, [editor, machines])

  useEffect(() => {
    function dismiss(event: PointerEvent) {
      if (!pendingDelete) return
      const target = event.target
      if (target instanceof Element && target.closest(`[data-pending-delete-row="${pendingDelete}"]`)) return
      setPendingDelete(null)
    }
    function escape(event: globalThis.KeyboardEvent) {
      if (event.key === "Escape") setPendingDelete(null)
    }
    document.addEventListener("pointerdown", dismiss, true)
    document.addEventListener("keydown", escape)
    return () => {
      document.removeEventListener("pointerdown", dismiss, true)
      document.removeEventListener("keydown", escape)
    }
  }, [pendingDelete])

  function beginOperation() {
    setPendingDelete(null)
    setOperationError("")
    setEditor(null)
  }

  function startEdit(machine: SetupMachineConfiguration) {
    beginOperation()
    setEditor({
      draft: structuredClone(machine),
      originalID: machine.id,
      insertAt: machines.findIndex(({ id }) => id === machine.id),
    })
  }

  function startAdd(kind: SetupMachineConfiguration["kind"]) {
    beginOperation()
    setAddOpen(false)
    setEditor({
      draft: kind === "vm" ? newVirtualMachine(machines) : newSSHMachine(machines),
      insertAt: machines.length,
    })
  }

  function startDuplicate(machine: SetupMachineConfiguration) {
    beginOperation()
    const sourceIndex = machines.findIndex(({ id }) => id === machine.id)
    setEditor({ draft: duplicateMachine(machine, machines), insertAt: sourceIndex + 1 })
  }

  function save(machine: SetupMachineConfiguration) {
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
    if (pendingDelete !== machine.id) {
      beginOperation()
      setPendingDelete(machine.id)
      return
    }
    if (machines.length === 1) {
      setPendingDelete(null)
      setOperationError("Setup requires at least one machine.")
      return
    }
    onMachinesChange(configurationRequest(machines.filter(({ id }) => id !== machine.id)).machines)
    setPendingDelete(null)
  }

  function reorder(id: string, targetIndex: number) {
    const from = machines.findIndex((machine) => machine.id === id)
    const boundedTarget = Math.max(0, Math.min(targetIndex, machines.length - 1))
    if (from < 0 || from === boundedTarget) return
    beginOperation()
    const updated = [...machines]
    const [moved] = updated.splice(from, 1)
    updated.splice(boundedTarget, 0, moved)
    onMachinesChange(configurationRequest(updated).machines)
    setAnnouncement(`${moved.name} moved to position ${boundedTarget + 1} of ${updated.length}.`)
  }

  function handleReorderKey(event: KeyboardEvent<HTMLElement>, machine: SetupMachineConfiguration, index: number) {
    if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return
    event.preventDefault()
    reorder(machine.id, index + (event.key === "ArrowUp" ? -1 : 1))
  }

  function drop(event: DragEvent, targetIndex: number) {
    event.preventDefault()
    const id = draggedID || event.dataTransfer.getData("text/plain")
    if (id) reorder(id, targetIndex)
    setDraggedID(null)
  }

  return (
    <TooltipProvider delayDuration={150}>
      <section aria-labelledby="machine-list-heading" className="flex h-full min-h-0 flex-col">
        <div className="mb-2 flex min-w-0 flex-wrap items-center justify-between gap-2 text-xs">
          <div className="min-w-0">
            <h3 id="machine-list-heading" className="font-medium">Machines</h3>
            <p className="text-[11px] text-muted-foreground">{machines.length} configured · {machines.filter(({ kind }) => kind === "vm").length} VM · {machines.filter(({ kind }) => kind === "ssh").length} SSH</p>
          </div>
          <Popover open={addOpen} onOpenChange={setAddOpen}>
            <PopoverTrigger asChild>
              <Button type="button" variant="outline" size="sm" aria-haspopup="menu" onClick={beginOperation}>
                <Plus aria-hidden="true" data-icon="inline-start" /> Add
              </Button>
            </PopoverTrigger>
            <PopoverContent role="menu" aria-label="Add machine" align="end" className="grid w-48 gap-1 p-1">
              <button type="button" role="menuitem" className="rounded-sm px-2 py-1.5 text-left text-xs hover:bg-accent focus:bg-accent focus:outline-none" onClick={() => startAdd("vm")}>New virtual machine</button>
              <button type="button" role="menuitem" className="rounded-sm px-2 py-1.5 text-left text-xs hover:bg-accent focus:bg-accent focus:outline-none" onClick={() => startAdd("ssh")}>Add via SSH</button>
            </PopoverContent>
          </Popover>
        </div>

        <ScrollArea className="min-h-0 flex-1 rounded-md border border-border" data-testid="machine-list">
          <ol className="divide-y divide-border p-0" aria-label="Configured machines">
            {displayMachines.map((machine, index) => {
              const isEditing = editor?.draft.id === machine.id
              const status = progress.workspaces.find(({ name }) => name === machine.name)
              const deleteArmed = pendingDelete === machine.id
              return (
                <li
                  key={machine.id}
                  data-machine-id={machine.id}
                  data-pending-delete-row={deleteArmed ? machine.id : undefined}
                  className="min-w-0 bg-background"
                  onDragOver={(event) => event.preventDefault()}
                  onDrop={(event) => drop(event, index)}
                >
                  {isEditing && editor ? (
                    <MachineEditor editor={editor} machines={machines} onCancel={() => setEditor(null)} onSave={save} />
                  ) : (
                    <div className="flex min-w-0 items-center gap-1.5 px-2 py-2">
                      <Tooltip>
                        <TooltipTrigger asChild>
                          <span
                            role="button"
                            tabIndex={0}
                            draggable={!editor}
                            aria-label={`Reorder ${machine.name}`}
                            className="grid size-7 shrink-0 cursor-grab place-items-center rounded-md text-muted-foreground outline-none hover:bg-muted focus-visible:ring-3 focus-visible:ring-ring/50 active:cursor-grabbing"
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
                          </span>
                        </TooltipTrigger>
                        <TooltipContent>Drag to reorder; use Up and Down arrow keys.</TooltipContent>
                      </Tooltip>
                      <span className="grid size-7 shrink-0 place-items-center rounded-md bg-muted text-muted-foreground">
                        {machine.kind === "vm" ? <Monitor className="size-3.5" aria-hidden="true" /> : <Server className="size-3.5" aria-hidden="true" />}
                      </span>
                      <div className="min-w-0 flex-1">
                        <div className="flex min-w-0 items-center gap-1.5">
                          <span className="truncate text-xs font-medium" title={machine.name}>{machine.name}</span>
                          <span className="shrink-0 rounded-full bg-muted px-1.5 py-0.5 text-[9px] font-medium uppercase text-muted-foreground">{machine.kind}</span>
                        </div>
                        <div className="truncate text-[10px] text-muted-foreground" title={machineSummary(machine)}>{machineSummary(machine)}{status ? ` · ${status.detail}` : ""}</div>
                      </div>
                      <div className="flex shrink-0 items-center gap-0.5" aria-label={`Actions for ${machine.name}`}>
                        <IconAction label={`Edit ${machine.name}`} onClick={() => startEdit(machine)}><Pencil /></IconAction>
                        <IconAction label={`Duplicate ${machine.name}`} onClick={() => startDuplicate(machine)}><Copy /></IconAction>
                        <IconAction
                          label={deleteArmed ? `Confirm deletion of ${machine.name}` : `Delete ${machine.name}`}
                          destructive={deleteArmed}
                          onClick={() => remove(machine)}
                        >
                          {deleteArmed ? <Check /> : <Trash2 />}
                        </IconAction>
                      </div>
                    </div>
                  )}
                </li>
              )
            })}
          </ol>
        </ScrollArea>
        {operationError && <p className="mt-2 text-xs text-destructive" role="alert">{operationError}</p>}
        <p className="sr-only" aria-live="polite">{announcement}</p>
      </section>
    </TooltipProvider>
  )
}
