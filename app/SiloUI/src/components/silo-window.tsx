import type { ReactNode } from "react"

import { WindowControls } from "@/components/window-toolbar"
import { cn } from "@/lib/utils"
import "./sidebar-shell.css"

interface SiloWindowProps {
  title: string
  label: string
  children: ReactNode
  className?: string
  titleBar?: ReactNode
  reduceMotion?: boolean
}

export function SiloWindow({ title, label, children, className, titleBar, reduceMotion }: SiloWindowProps) {
  return (
    <main className="grid min-h-dvh place-items-center bg-muted/50 p-0 sm:p-4">
      <section
        className={cn(
          "silo-window flex h-dvh w-full max-w-[68rem] flex-col overflow-hidden border-border bg-background shadow-2xl sm:h-[min(46rem,calc(100dvh-2rem))] sm:rounded-xl sm:border",
          className,
        )}
        aria-label={label}
        data-reduce-motion={reduceMotion || undefined}
      >
        {titleBar ?? <header aria-label="Window toolbar" className="grid h-11 shrink-0 grid-cols-[1fr_auto_1fr] items-center border-b border-border bg-background px-3">
          <WindowControls />
          <h1 className="text-[13px] font-medium">{title}</h1>
          <div />
        </header>}
        {children}
      </section>
    </main>
  )
}
