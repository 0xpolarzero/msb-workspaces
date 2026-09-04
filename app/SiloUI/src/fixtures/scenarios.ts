import {
  type SiloBootstrapConfiguration,
  type SiloPreflightCheck,
  type SiloProgressEvent,
} from "@/contracts/silo"
import { parseOnboardingSource, type OnboardingSource } from "@/features/onboarding/model/onboarding-source"
import { productionMachineDefaults } from "@/features/onboarding/model/machine-configuration"

export const scenarioNames = ["running", "complete", "dependency-failure", "bootstrap-failure"] as const
export type ScenarioName = (typeof scenarioNames)[number]

export const githubFixtureStates = ["disconnected", "connecting", "connected"] as const
export type GitHubFixtureState = (typeof githubFixtureStates)[number]

export const repositoryFixtures = [
  "acme/silo",
  "acme/design-system",
  "acme/platform-tools",
  "taylor/docs-site",
] as const

const revision = "9f3b7f095c93fced946f31c2847ad6f147e9d35ca91949845f959819f547440d"
const requestId = "setup-bootstrap-20260903"

const bootstrapConfiguration = {
  schemaVersion: 1,
  workspaces: [
    { name: "dev", cpu: 8, cpuCeiling: 12, memoryGiB: 32, memoryCeilingGiB: 48, workspaceStorageGiB: 120, runtimeStorageGiB: 100 },
    { name: "playgrounds", cpu: 4, cpuCeiling: 12, memoryGiB: 32, memoryCeilingGiB: 48, workspaceStorageGiB: 60, runtimeStorageGiB: 60 },
    { name: "personal", cpu: 6, cpuCeiling: 12, memoryGiB: 16, memoryCeilingGiB: 32, workspaceStorageGiB: 100, runtimeStorageGiB: 80 },
    { name: "docs-build", cpu: 4, cpuCeiling: 8, memoryGiB: 16, memoryCeilingGiB: 32, workspaceStorageGiB: 60, runtimeStorageGiB: 60 },
    { name: "client-alpha-integration", cpu: 8, cpuCeiling: 12, memoryGiB: 32, memoryCeilingGiB: 48, workspaceStorageGiB: 100, runtimeStorageGiB: 80 },
    { name: "qa-macos", cpu: 4, cpuCeiling: 8, memoryGiB: 16, memoryCeilingGiB: 32, workspaceStorageGiB: 60, runtimeStorageGiB: 60 },
    { name: "qa-linux", cpu: 4, cpuCeiling: 8, memoryGiB: 16, memoryCeilingGiB: 32, workspaceStorageGiB: 60, runtimeStorageGiB: 60 },
    { name: "release", cpu: 8, cpuCeiling: 12, memoryGiB: 32, memoryCeilingGiB: 48, workspaceStorageGiB: 100, runtimeStorageGiB: 80 },
    { name: "data-lab", cpu: 12, cpuCeiling: 12, memoryGiB: 48, memoryCeilingGiB: 48, workspaceStorageGiB: 120, runtimeStorageGiB: 120 },
    { name: "api-benchmarks", cpu: 12, cpuCeiling: 12, memoryGiB: 32, memoryCeilingGiB: 48, workspaceStorageGiB: 100, runtimeStorageGiB: 80 },
    { name: "customer-demo", cpu: 6, cpuCeiling: 8, memoryGiB: 16, memoryCeilingGiB: 32, workspaceStorageGiB: 80, runtimeStorageGiB: 60 },
    { name: "security-review", cpu: 8, cpuCeiling: 12, memoryGiB: 32, memoryCeilingGiB: 48, workspaceStorageGiB: 100, runtimeStorageGiB: 80 },
  ],
} satisfies SiloBootstrapConfiguration

const passingPreflightChecks = [
  { id: "macos-version", title: "macOS 26 or later", status: "pass", detail: "Detected macOS 26.", remediation: null },
  { id: "architecture", title: "Apple Silicon", status: "pass", detail: "Detected arm64.", remediation: null },
  { id: "disk-space", title: "Available disk space", status: "pass", detail: "128 GiB available; setup estimates at least 20 GiB.", remediation: null },
  { id: "memory", title: "Memory budget", status: "pass", detail: "Detected 64 GiB physical memory.", remediation: null },
  { id: "tool-git", title: "git", status: "pass", detail: "/usr/bin/git is executable.", remediation: null },
  { id: "tool-tar", title: "tar", status: "pass", detail: "/usr/bin/tar is executable.", remediation: null },
  { id: "tool-zstd", title: "zstd", status: "pass", detail: "/opt/homebrew/bin/zstd is executable.", remediation: null },
  { id: "tool-git-lfs", title: "git-lfs", status: "pass", detail: "/opt/homebrew/bin/git-lfs is executable.", remediation: null },
  { id: "tool-msb", title: "msb", status: "pass", detail: "/opt/homebrew/bin/msb is executable.", remediation: null },
  { id: "silo-runtime", title: "Silo runtime", status: "pass", detail: "Silo verified its coupled runtime.", remediation: null },
  { id: "host-integration", title: "Host integration", status: "pass", detail: "The fixed loopback aliases and managed host records are installed.", remediation: null },
] satisfies SiloPreflightCheck[]

function progress(
  message: string,
  step: string,
  workspace: string,
  fraction: number,
  safeForDisplay = true,
): SiloProgressEvent {
  return {
    schemaVersion: 1,
    type: "progress",
    requestId,
    phase: step === "workspace-verification" ? "verification" : "workspaces",
    step,
    workspace,
    revision,
    fraction,
    message,
    safeForDisplay,
  }
}

const configuredWorkspaceEvents = bootstrapConfiguration.workspaces.flatMap(({ name }) => [
  progress(`Configuring sandbox '${name}'.`, "workspace-configuration", name, 0),
  progress(`Sandbox '${name}' is configured.`, "workspace-configuration", name, 1),
])

const networkedWorkspaceEvents = bootstrapConfiguration.workspaces.flatMap(({ name }) => [
  progress(`Starting candidate networking for '${name}'.`, "workspace-networking", name, 0),
  progress(`Candidate networking is ready for '${name}'.`, "workspace-networking", name, 1),
])

const completedWorkspaceEvents = ["dev", "playgrounds", "personal"].flatMap((workspace) => [
  progress(`Verifying '${workspace}'.`, "workspace-verification", workspace, 0),
  progress(`Verification passed for '${workspace}'.`, "workspace-verification", workspace, 1),
])

const runningEvents = [
  ...configuredWorkspaceEvents,
  ...networkedWorkspaceEvents,
  ...completedWorkspaceEvents,
  progress("Internal verification path is not safe for display.", "workspace-verification", "docs-build", 0, false),
  progress("Verifying 'docs-build'.", "workspace-verification", "docs-build", 0),
] satisfies SiloProgressEvent[]

const completeEvents = bootstrapConfiguration.workspaces.flatMap(({ name }) => [
  progress(`Sandbox '${name}' is configured.`, "workspace-configuration", name, 1),
  progress(`Candidate networking is ready for '${name}'.`, "workspace-networking", name, 1),
  progress(`Verification passed for '${name}'.`, "workspace-verification", name, 1),
]) satisfies SiloProgressEvent[]

const runningSource = {
  machineConfigurations: productionMachineDefaults.map((machine) => ({ ...machine })),
  bootstrapConfiguration,
  bootstrapState: {
    phase: "workspaces",
    startedAt: 810129582,
    updatedAt: 810129720,
    completedPhases: ["welcome", "preflight", "toolchain", "hostIntegration"],
    phaseDurations: { preflight: 1.4, toolchain: 0.8, hostIntegration: 0.6 },
  },
  preflightChecks: passingPreflightChecks,
  progressEvents: runningEvents,
  githubPolicies: [{
    workspace: "dev",
    repositories: [{
      workspace: "dev",
      repositoryID: 1001,
      fullName: "acme/silo",
      ownerID: 42,
      ownerLogin: "acme",
      ownerType: "Organization",
      mode: "read-only",
    }],
  }],
  currentHostGitIdentity: {
    name: "Taylor Example",
    email: "taylor@example.com",
  },
  applicationPreferences: {
    terminal: "Terminal",
    editor: "Visual Studio Code",
    browser: "Safari",
  },
  bootstrapResult: null,
  error: null,
} satisfies OnboardingSource

const completeSource = {
  ...runningSource,
  bootstrapState: {
    phase: "complete",
    startedAt: 810129300,
    updatedAt: 810129720,
    completedPhases: ["welcome", "preflight", "toolchain", "hostIntegration", "workspaces", "github", "identity", "complete"],
    workspaceConfigurations: bootstrapConfiguration.workspaces.map((workspace, index) => ({
      id: `00000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`,
      name: workspace.name,
      cpus: workspace.cpu,
      maxCPUs: workspace.cpuCeiling,
      memoryGiB: workspace.memoryGiB,
      maxMemoryGiB: workspace.memoryCeilingGiB,
      workspaceStorageGiB: workspace.workspaceStorageGiB,
      runtimeStorageGiB: workspace.runtimeStorageGiB,
    })),
    phaseDurations: { preflight: 1.4, toolchain: 0.8, hostIntegration: 0.6, workspaces: 416 },
  },
  progressEvents: completeEvents,
  bootstrapResult: {
    resumed: true,
    phase: "complete",
    requiresApproval: false,
    vmsStarted: true,
    message: "Sandbox bootstrap and deep verification completed; the previous running set was restored.",
  },
  error: null,
} satisfies OnboardingSource

const dependencyFailureSource = {
  ...runningSource,
  preflightChecks: passingPreflightChecks.map((check) => check.id === "silo-runtime" ? {
    id: "silo-runtime",
    title: "Silo runtime",
    status: "needsAction" as const,
    detail: "The activated bundled Silo runtime needs repair.",
    remediation: "Use Repair… to reinstall the bundled Silo runtime.",
  } : check),
  progressEvents: [],
  bootstrapState: {
    phase: "preflight",
    startedAt: 810129720,
    updatedAt: 810129720,
    lastError: "Setup cannot continue until required preflight checks pass.",
    completedPhases: ["welcome"],
    phaseDurations: { preflight: 1.4 },
  },
} satisfies OnboardingSource

const bootstrapFailureMessage = "Candidate networking could not become ready for 'client-alpha-integration'."
const bootstrapFailureSource = {
  ...runningSource,
  progressEvents: [
    ...configuredWorkspaceEvents,
    ...bootstrapConfiguration.workspaces.slice(0, 4).flatMap(({ name }) => [
      progress(`Starting candidate networking for '${name}'.`, "workspace-networking", name, 0),
      progress(`Candidate networking is ready for '${name}'.`, "workspace-networking", name, 1),
    ]),
    progress("Starting candidate networking for 'client-alpha-integration'.", "workspace-networking", "client-alpha-integration", 0),
    progress("Candidate networking failed for 'client-alpha-integration'.", "workspace-networking", "client-alpha-integration", 0),
  ],
  bootstrapState: {
    ...runningSource.bootstrapState,
    lastError: bootstrapFailureMessage,
  },
  error: {
    code: "SILO_CANDIDATE_NETWORKING_FAILED",
    message: bootstrapFailureMessage,
    recovery: "Repair sandbox startup or SSH forwarding for 'client-alpha-integration', then resume Setup.",
    workspace: "client-alpha-integration",
    retryable: true,
  },
} satisfies OnboardingSource

export const onboardingScenarios: Record<ScenarioName, OnboardingSource> = {
  running: parseOnboardingSource(runningSource),
  complete: parseOnboardingSource(completeSource),
  "dependency-failure": parseOnboardingSource(dependencyFailureSource),
  "bootstrap-failure": parseOnboardingSource(bootstrapFailureSource),
}

export function scenarioFromSearch(search: string): ScenarioName {
  const requested = new URLSearchParams(search).get("scenario")
  return scenarioNames.find((name) => name === requested) ?? "running"
}

export function githubStateFromSearch(search: string): GitHubFixtureState | undefined {
  const requested = new URLSearchParams(search).get("github")
  return githubFixtureStates.find((state) => state === requested)
}
