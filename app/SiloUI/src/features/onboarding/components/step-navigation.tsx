import { AlertCircle, Check, LoaderCircle } from "lucide-react"

import { TabsList, TabsTrigger } from "@/components/ui/tabs"
import { cn } from "@/lib/utils"
import type { OnboardingStep, PresentationStatus } from "@/features/onboarding/model/onboarding-state"

const steps: { id: OnboardingStep; label: string }[] = [
  { id: "dependencies", label: "Dependencies" },
  { id: "workspaces", label: "Workspaces" },
  { id: "github", label: "GitHub" },
  { id: "identity", label: "Git" },
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
    <nav aria-label="Setup steps" className="min-w-0 overflow-x-auto border-b border-border bg-sidebar px-3 py-2 md:border-r md:border-b-0 md:px-2 md:py-4">
      <div className="mb-5 hidden items-center gap-2 px-2 text-sm font-semibold md:flex">
        <span className="grid size-6 place-items-center rounded-md bg-primary text-xs text-primary-foreground">S</span>
        Silo
      </div>
      <TabsList className="h-auto min-w-[33rem] justify-start gap-1 bg-transparent p-0 md:min-w-0 md:flex-col md:items-stretch" aria-label="Setup steps">
        {steps.map((step, index) => (
          <TabsTrigger
            key={step.id}
            value={step.id}
            className="h-9 flex-none justify-start gap-2 rounded-md border border-transparent px-2.5 text-xs text-muted-foreground shadow-none data-[state=active]:border-border data-[state=active]:bg-background data-[state=active]:text-foreground data-[state=active]:shadow-xs md:w-full"
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
