import type { ReactNode } from "react"

import { Tabs } from "@/components/ui/tabs"
import { OnboardingFooter } from "@/features/onboarding/components/onboarding-footer"
import { StepNavigation } from "@/features/onboarding/components/step-navigation"
import type { OnboardingStep, OnboardingViewModel } from "@/features/onboarding/model/onboarding-state"
import { useMediaQuery } from "@/hooks/use-media-query"

interface OnboardingShellProps {
  activeStep: OnboardingStep
  viewModel: OnboardingViewModel
  onStepChange: (step: OnboardingStep) => void
  onBack: () => void
  onContinue: () => void
  onSkip: () => void
  continueDisabled?: boolean
  children: ReactNode
}

export function OnboardingShell({ activeStep, viewModel, onStepChange, onBack, onContinue, onSkip, continueDisabled, children }: OnboardingShellProps) {
  const usesSidebar = useMediaQuery("(min-width: 48rem)")

  return (
    <main className="grid min-h-dvh place-items-center bg-muted/50 p-0 sm:p-4">
      <section className="flex h-dvh w-full max-w-[68rem] flex-col overflow-hidden border-border bg-background shadow-2xl sm:h-[min(46rem,calc(100dvh-2rem))] sm:rounded-xl sm:border" aria-label="Silo Setup">
        <header className="grid h-10 shrink-0 grid-cols-[1fr_auto_1fr] items-center border-b border-border bg-muted/30 px-3">
          <div className="flex gap-1.5" aria-hidden="true"><span className="size-2.5 rounded-full bg-red-400" /><span className="size-2.5 rounded-full bg-amber-400" /><span className="size-2.5 rounded-full bg-emerald-400" /></div>
          <h1 className="text-xs font-medium">Silo Setup</h1>
          <div />
        </header>
        <Tabs orientation={usesSidebar ? "vertical" : "horizontal"} value={activeStep} onValueChange={(value) => onStepChange(value as OnboardingStep)} className="grid min-h-0 flex-1 grid-rows-[auto_1fr] md:grid-cols-[10.75rem_1fr] md:grid-rows-1">
          <StepNavigation status={viewModel.stepStatus} />
          <div className="flex min-h-0 min-w-0 flex-col">
            <div className="min-h-0 flex-1 overflow-y-auto px-4 py-5 sm:px-6 sm:py-6">{children}</div>
            <OnboardingFooter activeStep={activeStep} viewModel={viewModel} onBack={onBack} onContinue={onContinue} onSkip={onSkip} continueDisabled={continueDisabled} />
          </div>
        </Tabs>
      </section>
    </main>
  )
}
