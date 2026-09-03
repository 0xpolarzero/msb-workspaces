import { Check, Loader, Minus, TriangleAlert } from "lucide-react"

import { SiloMark } from "@/features/onboarding/components/silo-mark"
import { TabsList, TabsTrigger } from "@/components/ui/tabs"
import { cn } from "@/lib/utils"
import type { OnboardingStep, PresentationStatus } from "@/features/onboarding/model/onboarding-state"

const steps: { id: OnboardingStep; label: string }[] = [
  { id: "dependencies", label: "Dependencies" },
  { id: "workspaces", label: "Sandboxes" },
  { id: "github", label: "GitHub" },
  { id: "review", label: "Review" },
]

function StepMark({ status }: { status: PresentationStatus }) {
  if (status === "succeeded") return <Check className="size-4" aria-label="Complete" />
  if (status === "failed") return <TriangleAlert className="size-4" aria-label="Needs action" />
  if (status === "running") return <Loader className="size-4 animate-spin" aria-label="In progress" />
  return <Minus className="size-4" aria-hidden="true" />
}

export function StepNavigation({ status }: { status: Record<OnboardingStep, PresentationStatus> }) {
  return (
    <nav aria-label="Setup steps" className="min-w-0 overflow-x-auto border-b border-border bg-sidebar px-3 py-2 md:border-r md:border-b-0 md:px-3 md:py-5">
      <div className="mb-5 hidden items-center gap-3 border-b border-border px-3 pb-5 md:flex">
        <SiloMark className="size-8 text-foreground" />
        <span className="text-base font-semibold tracking-tight text-foreground">Silo</span>
      </div>
      <TabsList className="grid h-auto w-full min-w-0 grid-cols-4 gap-1 bg-transparent p-0 md:flex md:flex-col md:items-stretch" aria-label="Setup steps">
        {steps.map((step) => (
          <TabsTrigger
            key={step.id}
            value={step.id}
            data-appearance="borderless"
            className="h-10 min-w-0 justify-center gap-1 rounded-md border-0 bg-transparent px-2 py-2 text-[10px] text-muted-foreground shadow-none focus-visible:ring-2 focus-visible:ring-sidebar-ring/70 md:w-full md:justify-start md:gap-2 md:px-3.5 md:py-2.5 md:text-[13px]"
          >
            <span className={cn(
              "grid size-5 shrink-0 place-items-center",
              status[step.id] === "failed" && "text-destructive",
              status[step.id] === "running" && "text-primary",
              status[step.id] === "succeeded" && "text-emerald-600 dark:text-emerald-400",
            )}>
              <StepMark status={status[step.id]} />
            </span>
            {step.label}
          </TabsTrigger>
        ))}
      </TabsList>
    </nav>
  )
}
