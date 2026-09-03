import { AlertCircle, Check, LoaderCircle } from "lucide-react"

import { TabsList, TabsTrigger } from "@/components/ui/tabs"
import { SiloMark } from "@/features/onboarding/components/silo-mark"
import { cn } from "@/lib/utils"
import type { OnboardingStep, PresentationStatus } from "@/features/onboarding/model/onboarding-state"

const steps: { id: OnboardingStep; label: string }[] = [
  { id: "dependencies", label: "Dependencies" },
  { id: "workspaces", label: "Sandboxes" },
  { id: "github", label: "GitHub" },
  { id: "review", label: "Review" },
]

function StepMark({ index, status }: { index: number; status: PresentationStatus }) {
  if (status === "succeeded") return <Check className="size-3.5" aria-label="Complete" />
  if (status === "failed") return <AlertCircle className="size-3.5" aria-label="Needs action" />
  if (status === "running") return <LoaderCircle className="size-3.5 animate-spin" aria-label="In progress" />
  return <span aria-hidden="true">{index + 1}</span>
}

export function StepNavigation({ status }: { status: Record<OnboardingStep, PresentationStatus> }) {
  return (
    <nav aria-label="Setup steps" className="min-w-0 overflow-x-auto border-b border-border bg-sidebar px-3 py-2 md:border-r md:border-b-0 md:px-3 md:py-5">
      <div className="mb-5 hidden items-center gap-2 px-3 text-sm font-semibold md:flex">
        <SiloMark className="size-6" />
        Silo
      </div>
      <TabsList className="grid h-auto w-full min-w-0 grid-cols-4 gap-1 bg-transparent p-0 md:flex md:flex-col md:items-stretch" aria-label="Setup steps">
        {steps.map((step, index) => (
          <TabsTrigger
            key={step.id}
            value={step.id}
            data-appearance="borderless"
            className="h-10 min-w-0 justify-center gap-1 rounded-md border-0 bg-transparent px-2 py-2 text-[10px] text-muted-foreground shadow-none focus-visible:ring-2 focus-visible:ring-sidebar-ring/70 md:w-full md:justify-start md:gap-2 md:px-3.5 md:py-2.5 md:text-[13px]"
          >
            <span className={cn(
              "grid size-5 place-items-center rounded-full border border-border text-[10px]",
              status[step.id] === "failed" && "border-destructive text-destructive",
              status[step.id] === "running" && "border-primary/30 text-primary",
              status[step.id] === "succeeded" && "border-emerald-600/30 text-emerald-600 dark:text-emerald-400",
            )}>
              <StepMark index={index} status={status[step.id]} />
            </span>
            {step.label}
          </TabsTrigger>
        ))}
      </TabsList>
    </nav>
  )
}
