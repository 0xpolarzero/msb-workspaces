import { AlertCircle, Check, Clock3, LoaderCircle } from "lucide-react"

import { Button } from "@/components/ui/button"
import type { OnboardingStep, OnboardingViewModel } from "@/features/onboarding/model/onboarding-state"

interface OnboardingFooterProps {
  activeStep: OnboardingStep
  viewModel: OnboardingViewModel
  onBack: () => void
  onContinue: () => void
}

export function OnboardingFooter({ activeStep, viewModel, onBack, onContinue }: OnboardingFooterProps) {
  const { workspaceProgress } = viewModel
  const isReview = activeStep === "review"
  const dependenciesBlocked = activeStep === "dependencies" && viewModel.dependencyStatus === "failed"
  const statusText = dependenciesBlocked
    ? "Resolve dependency checks to continue"
    : workspaceProgress.status === "failed"
    ? workspaceProgress.currentMessage
    : workspaceProgress.status === "succeeded"
      ? "All required setup work is complete"
      : workspaceProgress.currentMessage

  return (
    <footer className="flex items-center justify-between gap-3 border-t border-border bg-muted/20 px-4 py-3">
      <div className="flex min-w-0 items-center gap-2 text-xs text-muted-foreground" aria-live="polite">
        {dependenciesBlocked || workspaceProgress.status === "failed" ? <AlertCircle className="size-3.5 shrink-0 text-destructive" />
          : workspaceProgress.status === "succeeded" ? <Check className="size-3.5 shrink-0 text-emerald-600 dark:text-emerald-400" />
            : workspaceProgress.status === "running" ? <LoaderCircle className="size-3.5 shrink-0 animate-spin" />
              : <Clock3 className="size-3.5 shrink-0" />}
        <span className="truncate">{statusText}</span>
      </div>
      <div className="flex shrink-0 gap-2">
        <Button variant="outline" onClick={onBack} disabled={activeStep === "dependencies"}>Back</Button>
        <Button onClick={onContinue} disabled={isReview ? !viewModel.finishEnabled : dependenciesBlocked}>
          {isReview ? "Finish" : "Continue"}
        </Button>
      </div>
    </footer>
  )
}
