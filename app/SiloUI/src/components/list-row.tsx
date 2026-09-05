import type { ComponentProps, ReactNode } from "react"

import { cn } from "@/lib/utils"

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
        <div className="flex min-w-0 items-center gap-1.5">{title}</div>
        <div className={cn("truncate text-[10px] text-muted-foreground", detailClassName)}>{detail}</div>
      </div>
      {actions}
    </div>
  )
}

export function ListRowIcon({ className, ...props }: ComponentProps<"span">) {
  return <span className={cn("grid size-7 shrink-0 place-items-center rounded-md bg-muted text-muted-foreground", className)} {...props} />
}
