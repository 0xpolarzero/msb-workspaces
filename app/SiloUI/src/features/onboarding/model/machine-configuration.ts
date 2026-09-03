import type {
  SetupMachineConfiguration,
  SetupSSHMachineConfiguration,
  SetupVirtualMachineConfiguration,
} from "@/contracts/silo"
import {
  setupMachineConfigurationSchema,
  setupMachineConfigurationRequestSchema,
} from "@/contracts/silo"

export const supportedCPUs = [4, 6, 8, 12] as const
export const supportedMemoryGiB = [16, 32, 48] as const
export const supportedStorageGiB = [60, 80, 100, 120] as const

// Exact values from the production native source of truth:
// app/Silo/Sources/SiloModels.swift, SetupWorkspaceConfiguration.defaults.
export const productionMachineDefaults: readonly SetupVirtualMachineConfiguration[] = [
  {
    id: "00000000-0000-4000-8000-000000000001",
    kind: "vm",
    name: "dev",
    cpus: 8,
    maxCPUs: 12,
    memoryGiB: 32,
    maxMemoryGiB: 48,
    workspaceStorageGiB: 120,
    runtimeStorageGiB: 100,
  },
  {
    id: "00000000-0000-4000-8000-000000000002",
    kind: "vm",
    name: "playgrounds",
    cpus: 4,
    maxCPUs: 12,
    memoryGiB: 32,
    maxMemoryGiB: 48,
    workspaceStorageGiB: 60,
    runtimeStorageGiB: 60,
  },
  {
    id: "00000000-0000-4000-8000-000000000003",
    kind: "vm",
    name: "personal",
    cpus: 6,
    maxCPUs: 12,
    memoryGiB: 16,
    maxMemoryGiB: 32,
    workspaceStorageGiB: 100,
    runtimeStorageGiB: 80,
  },
] as const

export function createMachineID(): string {
  return crypto.randomUUID()
}

export function nextMachineName(base: string, machines: readonly SetupMachineConfiguration[]): string {
  const names = new Set(machines.map(({ name }) => name.toLowerCase()))
  let suffix = "-copy"
  let candidate = `${base.slice(0, 32 - suffix.length).replace(/-+$/, "")}${suffix}`
  let index = 2
  while (names.has(candidate.toLowerCase())) {
    suffix = `-copy-${index}`
    candidate = `${base.slice(0, 32 - suffix.length).replace(/-+$/, "")}${suffix}`
    index += 1
  }
  return candidate
}

export function newVirtualMachine(machines: readonly SetupMachineConfiguration[]): SetupVirtualMachineConfiguration {
  const names = new Set(machines.map(({ name }) => name.toLowerCase()))
  let number = machines.length + 1
  while (names.has(`workspace-${number}`)) number += 1
  const template = productionMachineDefaults[0]
  return { ...template, id: createMachineID(), name: `workspace-${number}` }
}

export function newSSHMachine(machines: readonly SetupMachineConfiguration[]): SetupSSHMachineConfiguration {
  const names = new Set(machines.map(({ name }) => name.toLowerCase()))
  let number = 1
  while (names.has(`remote-${number}`)) number += 1
  return {
    id: createMachineID(),
    kind: "ssh",
    name: `remote-${number}`,
    host: "",
    user: "",
    port: 22,
  }
}

export function duplicateMachine(
  machine: SetupMachineConfiguration,
  machines: readonly SetupMachineConfiguration[],
): SetupMachineConfiguration {
  return {
    ...machine,
    id: createMachineID(),
    name: nextMachineName(machine.name, machines),
  }
}

export type MachineValidationErrors = Partial<Record<"name" | "cpus" | "maxCPUs" | "memoryGiB" | "maxMemoryGiB" | "workspaceStorageGiB" | "runtimeStorageGiB" | "host" | "user" | "port", string>>

export function validateMachine(
  machine: SetupMachineConfiguration,
  machines: readonly SetupMachineConfiguration[],
  originalID?: string,
): MachineValidationErrors {
  const result = setupMachineConfigurationSchema.safeParse(machine)
  const errors: MachineValidationErrors = {}
  if (!result.success) {
    for (const issue of result.error.issues) {
      const field = issue.path[0]
      if (typeof field === "string" && !(field in errors)) errors[field as keyof MachineValidationErrors] = issue.message
    }
  }
  if (machines.some(({ id, name }) => id !== originalID && name.toLowerCase() === machine.name.toLowerCase())) {
    errors.name = "Machine names must be unique."
  }
  if (!/^[a-z][a-z0-9-]{0,31}$/.test(machine.name)) {
    errors.name = "Use a lowercase name that starts with a letter and contains only letters, numbers, or hyphens."
  }
  if (machine.kind === "vm") {
    if (machine.cpus > machine.maxCPUs) errors.cpus = "CPU limit cannot exceed its ceiling."
    if (machine.memoryGiB > machine.maxMemoryGiB) errors.memoryGiB = "Memory limit cannot exceed its ceiling."
  } else {
    if (!machine.host.trim()) errors.host = "Enter an SSH host."
    if (!machine.user.trim()) errors.user = "Enter an SSH user."
    if (!Number.isInteger(machine.port) || machine.port < 1 || machine.port > 65_535) errors.port = "Enter a port from 1 to 65535."
  }
  return errors
}

export function configurationRequest(machines: readonly SetupMachineConfiguration[]) {
  return setupMachineConfigurationRequestSchema.parse({ schemaVersion: 1, machines })
}
