import { describe, expect, it } from "vitest"

import { surfaceFromSearch } from "@/fixtures/surfaces"

describe("surface fixtures", () => {
  it("defaults to onboarding and accepts only the app surface", () => {
    expect(surfaceFromSearch("")).toBe("onboarding")
    expect(surfaceFromSearch("?view=unknown")).toBe("onboarding")
    expect(surfaceFromSearch("?view=onboarding")).toBe("onboarding")
    expect(surfaceFromSearch("?view=app")).toBe("app")
  })
})
