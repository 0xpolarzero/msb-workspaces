import { describe, expect, it } from "vitest"

import { applicationPreviewAfterSetup } from "./onboarding-handoff"
import { productionMachineDefaults } from "@/features/onboarding/model/machine-configuration"
import type { OnboardingCompletionRequest } from "@/features/onboarding/model/onboarding-source"

const request: OnboardingCompletionRequest = {
  machineConfiguration: { schemaVersion: 1, machines: [
    { ...productionMachineDefaults[0], name: "build" },
    { id: "remote-test", kind: "ssh", name: "remote", host: "example.test", user: "dev", port: 2222 },
  ] },
  applications: { terminal: "Warp", editor: "Zed", browser: "Firefox" },
  github: { connectionState: "connected", workspaces: [
    { workspace: "build", identity: { name: "Example", email: "example@example.test", apply: true }, repositories: [{ repository: "acme/design-system", allowPushes: true }] },
    { workspace: "remote", identity: { name: "", email: "", apply: false }, repositories: [] },
  ] },
}

describe("setup preview handoff", () => {
  it("opens the configured machines, application choices and exact repository policy", () => {
    const app = applicationPreviewAfterSetup(request)
    expect(app.workspaces.map(({ machine }) => machine)).toEqual(request.machineConfiguration.machines)
    expect(app.preferences).toMatchObject(request.applications)
    expect(app.github.workspaces).toEqual(request.github.workspaces)
    expect(app.workspaces[0].githubRepositories).toEqual(["acme/design-system"])
    expect(app.workspaces[1].host).toBe("example.test")
    expect(app.secrets).toEqual([])
    expect(app.backup.lastArchive).toBe("")
    expect(app.backup.destination).toBe("")
    expect(app.runtimeRepair).toBeNull()
    expect(app.sandboxConfigurationOperation).toBeNull()
    expect(app.repositoryPushOperations).toEqual([])
  })

  it("retains a disconnected choice without importing the sample account or policies", () => {
    const app = applicationPreviewAfterSetup({ ...request, github: { ...request.github, connectionState: "disconnected" } })
    expect(app.github.state).toBe("disconnected")
    expect(app.github.account).toBeUndefined()
    expect(app.github.accessEnabled).toBe(false)
    expect(app.github.workspaces).toEqual(request.github.workspaces)
  })
})
