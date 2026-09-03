import type { SetupMachineConfiguration } from "@/contracts/silo"

export function machineSummary(machine: SetupMachineConfiguration): string {
  if (machine.kind === "ssh") return `${machine.user}@${machine.host}:${machine.port}`
  return `${machine.cpus} CPU · ${machine.memoryGiB} GB RAM · ${machine.workspaceStorageGiB} GB workspace`
}
