import { AlertCircle, Check, Clock3, LoaderCircle } from "lucide-react"

import { Button } from "@/components/ui/button"
import type { OnboardingStep, OnboardingViewModel } from "@/features/onboarding/model/onboarding-state"

interface OnboardingFooterProps {
  activeStep: OnboardingStep
  viewModel: OnboardingViewModel
  onBack: () => void
  onContinue: () => void
  completed?: boolean
  onOpenApp?: () => void
}

export function OnboardingFooter({ activeStep, viewModel, onBack, onContinue, completed = false, onOpenApp }: OnboardingFooterProps) {
  const isReview = activeStep === "review"
  const dependenciesBlocked = activeStep === "dependencies" && viewModel.dependencyStatus === "failed"
  const failedItem = viewModel.queueItems.find(({ status }) => status === "failed")
  const runningItem = viewModel.queueItems.find(({ status }) => status === "running")
  const failed = viewModel.dependencyStatus === "failed" || !!failedItem || !!viewModel.error
  const complete = completed || (viewModel.dependencyStatus === "succeeded" && viewModel.queueItems.length > 0 && viewModel.queueItems.every(({ status }) => status === "succeeded"))
  const statusText = completed
    ? "Complete · Silo is ready"
    : viewModel.dependencyStatus === "failed"
      ? "Failed · Resolve dependency checks to continue"
      : failed
        ? `Failed · ${failedItem?.failure ?? viewModel.error?.message ?? "Setup needs your attention"}`
        : complete
          ? "Complete · Ready to finish setup"
          : runningItem
            ? `In progress · ${runningItem.label}`
            : "Waiting · Setup tasks are queued"

  return (
    <footer className="flex shrink-0 flex-wrap items-center justify-between gap-x-4 gap-y-3 border-t border-border bg-muted/20 px-4 py-3 sm:px-6" aria-label="Onboarding actions">
      <div className="flex min-w-0 flex-[1_1_12rem] items-start gap-2 text-xs leading-5 text-muted-foreground" aria-live="polite">
        {failed && !completed ? <AlertCircle className="mt-0.5 size-3.5 shrink-0 text-destructive" />
          : complete ? <Check className="mt-0.5 size-3.5 shrink-0 text-emerald-600 dark:text-emerald-400" />
            : runningItem ? <LoaderCircle className="mt-0.5 size-3.5 shrink-0 animate-spin" />
              : <Clock3 className="mt-0.5 size-3.5 shrink-0" />}
        <span className="break-words">{statusText}</span>
      </div>
      <div className="ml-auto flex shrink-0 gap-2">
        {completed ? <Button onClick={onOpenApp} disabled={!onOpenApp}>Open Silo</Button> : <>
          <Button variant="outline" onClick={onBack} disabled={activeStep === "dependencies"}>Back</Button>
          <Button onClick={onContinue} disabled={isReview ? !viewModel.finishEnabled : dependenciesBlocked}>
            {isReview ? "Finish" : "Continue"}
          </Button>
        </>}
      </div>
    </footer>
  )
}
