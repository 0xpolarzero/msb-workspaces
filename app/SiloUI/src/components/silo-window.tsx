import type { ReactNode } from "react"

import { cn } from "@/lib/utils"

interface SiloWindowProps {
  title: string
  label: string
  children: ReactNode
  className?: string
  titleBar?: ReactNode
}

export function SiloWindow({ title, label, children, className, titleBar }: SiloWindowProps) {
  return (
    <main className="grid min-h-dvh place-items-center bg-muted/50 p-0 sm:p-4">
      <section
        className={cn(
          "flex h-dvh w-full max-w-[68rem] flex-col overflow-hidden border-border bg-background shadow-2xl sm:h-[min(46rem,calc(100dvh-2rem))] sm:rounded-xl sm:border",
          className,
        )}
        aria-label={label}
      >
        {titleBar ?? <header className="grid h-10 shrink-0 grid-cols-[1fr_auto_1fr] items-center border-b border-border bg-muted/30 px-3">
          <div className="flex gap-1.5" aria-hidden="true">
            <span className="size-2.5 rounded-full bg-red-400" />
            <span className="size-2.5 rounded-full bg-amber-400" />
            <span className="size-2.5 rounded-full bg-emerald-400" />
          </div>
          <h1 className="text-xs font-medium">{title}</h1>
          <div />
        </header>}
        {children}
      </section>
    </main>
  )
}
