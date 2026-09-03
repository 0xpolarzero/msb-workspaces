import { cn } from "@/lib/utils"

/**
 * The Silo mark, adapted from app/Silo/Scripts/generate-app-icons.swift
 * (the production app icon generator): the middle ivory level and the orange
 * core, each with its characteristic gap; the generator's outer level is
 * omitted. The levels use currentColor (dark in light mode, ivory in dark
 * mode) while the orange core stays fixed. The viewBox is tightened to the
 * remaining arcs' bounds, and CoreGraphics' y-up arcs are mirrored to SVG's
 * y-down coordinates.
 */
export function SiloMark({ className }: { className?: string }) {
  return (
    <svg viewBox="34.5 34.5 59 59" aria-hidden="true" className={cn("shrink-0 text-foreground", className)}>
      <g fill="none" strokeWidth="7" strokeLinecap="round">
        <path d="M 88.625 72.344 A 26 26 0 1 1 75.804 40.834" stroke="currentColor" />
        <path d="M 72.591 54.243 A 13 13 0 1 1 52.316 58.301" stroke="#FF9F0A" />
      </g>
    </svg>
  )
}
