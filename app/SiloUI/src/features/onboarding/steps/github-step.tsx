import { Check } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { Checkbox } from "@/components/ui/checkbox"
import { WorkspaceProgressStrip } from "@/features/onboarding/components/workspace-progress-strip"
import type { WorkspaceProgressView } from "@/features/onboarding/model/onboarding-state"

export type GitHubChoice = "connect" | "skip"

interface GitHubStepProps {
  progress: WorkspaceProgressView
  choice: GitHubChoice
  repositorySelected: boolean
  repository: { fullName: string; workspace: string; mode: "read-only" | "read-write" }
  onChoiceChange: (choice: GitHubChoice) => void
  onRepositoryChange: (selected: boolean) => void
  onViewProgress: () => void
}

export function GitHubStep({ progress, choice, repositorySelected, repository, onChoiceChange, onRepositoryChange, onViewProgress }: GitHubStepProps) {
  return (
    <section aria-labelledby="github-title" className="mx-auto max-w-3xl">
      <WorkspaceProgressStrip progress={progress} onView={onViewProgress} />
      <div className="mb-5">
        <h2 id="github-title" className="text-xl font-semibold tracking-tight">GitHub access</h2>
        <p className="mt-1 text-sm text-muted-foreground">Choose how these workspaces access repositories. Silo applies the choice after workspace creation.</p>
      </div>
      <div className="grid gap-3 sm:grid-cols-2" role="radiogroup" aria-label="GitHub setup choice">
        <Button
          type="button"
          variant="outline"
          role="radio"
          aria-checked={choice === "connect"}
          onClick={() => onChoiceChange("connect")}
          className="h-auto items-start justify-start gap-3 p-4 text-left whitespace-normal data-[selected=true]:border-primary/50 data-[selected=true]:bg-primary/5"
          data-selected={choice === "connect"}
        >
          <span className="mt-0.5 grid size-4 shrink-0 place-items-center rounded-full border border-border">{choice === "connect" && <Check className="size-3" />}</span>
          <span><strong className="block">Connect GitHub</strong><span className="mt-1 block text-xs font-normal text-muted-foreground">Select repository access for each workspace.</span></span>
        </Button>
        <Button
          type="button"
          variant="outline"
          role="radio"
          aria-checked={choice === "skip"}
          onClick={() => onChoiceChange("skip")}
          className="h-auto items-start justify-start gap-3 p-4 text-left whitespace-normal data-[selected=true]:border-primary/50 data-[selected=true]:bg-primary/5"
          data-selected={choice === "skip"}
        >
          <span className="mt-0.5 grid size-4 shrink-0 place-items-center rounded-full border border-border">{choice === "skip" && <Check className="size-3" />}</span>
          <span><strong className="block">Skip for now</strong><span className="mt-1 block text-xs font-normal text-muted-foreground">Public repositories remain available without a grant.</span></span>
        </Button>
      </div>

      {choice === "connect" && (
        <Card className="mt-3 py-0">
          <CardContent className="p-4">
            <h3 className="text-sm font-medium">Repository access</h3>
            <label className="mt-3 flex items-start gap-2.5 rounded-md border border-border p-3 text-xs">
              <Checkbox checked={repositorySelected} onCheckedChange={(checked) => onRepositoryChange(checked === true)} aria-label={`Grant access to ${repository.fullName}`} />
              <span><strong className="block">{repository.fullName}</strong><span className="mt-0.5 block text-muted-foreground">{repository.mode === "read-only" ? "Read-only" : "Read and write"} access for the {repository.workspace} workspace</span></span>
            </label>
          </CardContent>
        </Card>
      )}
    </section>
  )
}
