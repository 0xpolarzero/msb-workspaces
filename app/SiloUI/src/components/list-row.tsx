import type { ComponentProps, ReactNode } from "react"

import { cn } from "@/lib/utils"

export function ListCard({ className, ...props }: ComponentProps<"div">) {
  return <div className={cn("divide-y divide-border overflow-hidden rounded-md border border-border", className)} {...props} />
}

export function ListRowDetails({ label, className, ...props }: { label: string } & ComponentProps<"div">) {
  return <div role="group" aria-label={label} className={cn("mx-2 grid gap-3 border-t border-border py-3 pr-1 pl-8 text-xs", className)} {...props} />
}

export function ListRow({
  icon,
  title,
  detail,
  leading,
  actions,
  detailClassName,
  className,
  ...props
}: {
  icon: ReactNode
  title: ReactNode
  detail: ReactNode
  leading?: ReactNode
  actions?: ReactNode
  detailClassName?: string
} & Omit<ComponentProps<"div">, "title" | "children">) {
  return (
    <div className={cn("flex min-w-0 items-center gap-1.5 px-2 py-2 transition-colors", className)} {...props}>
      {leading}
      {icon}
      <div className="min-w-0 flex-1">
        <div className="flex min-w-0 items-center gap-1.5 text-[13px] leading-4 font-medium">{title}</div>
        <div className={cn("truncate text-[11px] leading-4 text-muted-foreground", detailClassName)}>{detail}</div>
      </div>
      {actions}
    </div>
  )
}

export function ListRowIcon({ className, ...props }: ComponentProps<"span">) {
  return <span className={cn("grid size-7 shrink-0 place-items-center rounded-md bg-muted text-muted-foreground", className)} {...props} />
}
