export const surfaceNames = ["onboarding", "app"] as const
export type SurfaceName = (typeof surfaceNames)[number]

export function surfaceFromSearch(search: string): SurfaceName {
  const requested = new URLSearchParams(search).get("view")
  return surfaceNames.find((surface) => surface === requested) ?? "onboarding"
}
