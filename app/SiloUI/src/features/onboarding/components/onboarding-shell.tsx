import type { ReactNode } from "react"

import { SiloWindow } from "@/components/silo-window"
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
  children: ReactNode
}

export function OnboardingShell({ activeStep, viewModel, onStepChange, onBack, onContinue, children }: OnboardingShellProps) {
  const usesSidebar = useMediaQuery("(min-width: 48rem)")

  return (
    <SiloWindow title="Silo Setup" label="Silo Setup">
      <Tabs orientation={usesSidebar ? "vertical" : "horizontal"} value={activeStep} onValueChange={(value) => onStepChange(value as OnboardingStep)} className="grid min-h-0 flex-1 grid-rows-[auto_1fr] md:grid-cols-[13.5rem_minmax(0,1fr)] md:grid-rows-1">
        <StepNavigation status={viewModel.stepStatus} />
        <div className="flex min-h-0 min-w-0 flex-col">
          <div className="min-h-0 flex-1 overflow-y-auto px-4 py-5 sm:px-6 sm:py-6">{children}</div>
          <OnboardingFooter activeStep={activeStep} viewModel={viewModel} onBack={onBack} onContinue={onContinue} />
        </div>
      </Tabs>
    </SiloWindow>
  )
}
