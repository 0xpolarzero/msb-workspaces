import { z } from "zod"

export const preflightStatusSchema = z.enum(["pass", "needsAction", "unavailable"])

export const siloPreflightCheckSchema = z.object({
  id: z.string().min(1),
  title: z.string().min(1),
  status: preflightStatusSchema,
  detail: z.string(),
  remediation: z.string().nullable(),
}).strict()

export const siloBootstrapWorkspaceSchema = z.object({
  name: z.string().regex(/^[a-z][a-z0-9-]{0,31}$/),
  cpu: z.union([z.literal(4), z.literal(6), z.literal(8), z.literal(12)]),
  cpuCeiling: z.union([z.literal(4), z.literal(6), z.literal(8), z.literal(12)]),
  memoryGiB: z.union([z.literal(16), z.literal(32), z.literal(48)]),
  memoryCeilingGiB: z.union([z.literal(16), z.literal(32), z.literal(48)]),
  workspaceStorageGiB: z.union([z.literal(60), z.literal(80), z.literal(100), z.literal(120)]),
  runtimeStorageGiB: z.union([z.literal(60), z.literal(80), z.literal(100), z.literal(120)]),
}).strict().refine((workspace) => workspace.cpu <= workspace.cpuCeiling, {
  message: "cpu must not exceed cpuCeiling",
}).refine((workspace) => workspace.memoryGiB <= workspace.memoryCeilingGiB, {
  message: "memoryGiB must not exceed memoryCeilingGiB",
})

export const siloBootstrapConfigurationSchema = z.object({
  schemaVersion: z.literal(1),
  workspaces: z.array(siloBootstrapWorkspaceSchema).min(1).max(64),
}).strict().refine((configuration) => {
  const names = configuration.workspaces.map(({ name }) => name)
  return new Set(names).size === names.length
}, { message: "workspace names must be unique" })

export const setupWorkspaceConfigurationSchema = z.object({
  id: z.uuid(),
  name: z.string().regex(/^[a-z][a-z0-9-]{0,31}$/),
  cpus: z.union([z.literal(4), z.literal(6), z.literal(8), z.literal(12)]),
  maxCPUs: z.union([z.literal(4), z.literal(6), z.literal(8), z.literal(12)]),
  memoryGiB: z.union([z.literal(16), z.literal(32), z.literal(48)]),
  maxMemoryGiB: z.union([z.literal(16), z.literal(32), z.literal(48)]),
  workspaceStorageGiB: z.union([z.literal(60), z.literal(80), z.literal(100), z.literal(120)]),
  runtimeStorageGiB: z.union([z.literal(60), z.literal(80), z.literal(100), z.literal(120)]),
}).strict().refine((workspace) => workspace.cpus <= workspace.maxCPUs, {
  message: "cpus must not exceed maxCPUs",
}).refine((workspace) => workspace.memoryGiB <= workspace.maxMemoryGiB, {
  message: "memoryGiB must not exceed maxMemoryGiB",
})

export const setupVirtualMachineConfigurationSchema = setupWorkspaceConfigurationSchema.extend({
  kind: z.literal("vm"),
}).strict()

export const setupSSHMachineConfigurationSchema = z.object({
  id: z.uuid(),
  kind: z.literal("ssh"),
  name: z.string().regex(/^[a-z][a-z0-9-]{0,31}$/),
  host: z.string().trim().min(1).max(253).regex(/^\S+$/),
  user: z.string().trim().min(1).max(64).regex(/^[a-zA-Z_][a-zA-Z0-9._-]*$/),
  port: z.number().int().min(1).max(65_535),
}).strict()

export const setupMachineConfigurationSchema = z.discriminatedUnion("kind", [
  setupVirtualMachineConfigurationSchema,
  setupSSHMachineConfigurationSchema,
])

export const setupMachineConfigurationRequestSchema = z.object({
  schemaVersion: z.literal(1),
  machines: z.array(setupMachineConfigurationSchema).min(1).max(64),
}).strict().refine((configuration) => {
  const names = configuration.machines.map(({ name }) => name.toLowerCase())
  return new Set(names).size === names.length
}, { message: "machine names must be unique" }).refine((configuration) => {
  const ids = configuration.machines.map(({ id }) => id)
  return new Set(ids).size === ids.length
}, { message: "machine IDs must be unique" })

export const siloBootstrapPhaseSchema = z.enum([
  "welcome",
  "preflight",
  "toolchain",
  "hostIntegration",
  "workspaces",
  "github",
  "identity",
  "complete",
])

export const siloBootstrapStateSchema = z.object({
  phase: siloBootstrapPhaseSchema,
  startedAt: z.number().optional(),
  updatedAt: z.number(),
  lastError: z.string().optional(),
  completedPhases: z.array(siloBootstrapPhaseSchema),
  workspaceConfigurations: z.array(setupWorkspaceConfigurationSchema).optional(),
  reconnectWorkspace: z.string().optional(),
  phaseDurations: z.record(z.string(), z.number().nonnegative()),
}).strict()

export const siloProgressEventSchema = z.object({
  schemaVersion: z.literal(1),
  type: z.literal("progress"),
  requestId: z.string().trim().min(1),
  phase: z.string().trim().min(1),
  step: z.string().optional(),
  workspace: z.string().optional(),
  revision: z.string().regex(/^[0-9a-f]{64}$/).optional(),
  fraction: z.number().min(0).max(1).optional(),
  message: z.string(),
  safeForDisplay: z.boolean(),
}).strict()

export const siloBootstrapResultSchema = z.object({
  resumed: z.boolean(),
  phase: z.string(),
  requiresApproval: z.boolean(),
  vmsStarted: z.boolean(),
  message: z.string(),
}).strict()

export const siloProtocolErrorSchema = z.object({
  code: z.string().min(1),
  message: z.string().min(1),
  recovery: z.string().nullable(),
  workspace: z.string().nullable(),
  retryable: z.boolean(),
}).strict()

export const githubRepositoryPolicySchema = z.object({
  workspace: z.string().min(1),
  repositoryID: z.number().int(),
  fullName: z.string().min(1),
  installationID: z.number().int(),
  ownerID: z.number().int(),
  ownerLogin: z.string().min(1),
  ownerType: z.string().nullable(),
  mode: z.enum(["read-only", "read-write"]),
}).strict()

export const githubWorkspacePolicySchema = z.object({
  workspace: z.string().min(1),
  repositories: z.array(githubRepositoryPolicySchema),
}).strict().refine((policy) => (
  policy.repositories.every((repository) => repository.workspace === policy.workspace)
), { message: "repository workspaces must match the policy workspace" })

export const setupQueueItemIdSchema = z.enum([
  "workspaceRun",
  "workspaceVerify",
  "githubRun",
  "githubVerify",
  "identityRun",
  "identityVerify",
  "completion",
])

export const setupQueueItemStatusSchema = z.enum(["queued", "running", "succeeded", "failed"])

export type SiloPreflightCheck = z.infer<typeof siloPreflightCheckSchema>
export type SiloBootstrapConfiguration = z.infer<typeof siloBootstrapConfigurationSchema>
export type SiloBootstrapState = z.infer<typeof siloBootstrapStateSchema>
export type SetupMachineConfiguration = z.infer<typeof setupMachineConfigurationSchema>
export type SetupMachineConfigurationRequest = z.infer<typeof setupMachineConfigurationRequestSchema>
export type SetupSSHMachineConfiguration = z.infer<typeof setupSSHMachineConfigurationSchema>
export type SetupVirtualMachineConfiguration = z.infer<typeof setupVirtualMachineConfigurationSchema>
export type SiloProgressEvent = z.infer<typeof siloProgressEventSchema>
export type SiloBootstrapResult = z.infer<typeof siloBootstrapResultSchema>
export type SiloProtocolError = z.infer<typeof siloProtocolErrorSchema>
export type GitHubWorkspacePolicy = z.infer<typeof githubWorkspacePolicySchema>
export type SetupQueueItemID = z.infer<typeof setupQueueItemIdSchema>
export type SetupQueueItemStatus = z.infer<typeof setupQueueItemStatusSchema>
