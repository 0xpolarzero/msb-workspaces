import { Checkbox } from "@/components/ui/checkbox"
import { Input } from "@/components/ui/input"
import { WorkspaceProgressStrip } from "@/features/onboarding/components/workspace-progress-strip"
import type { WorkspaceProgressView } from "@/features/onboarding/model/onboarding-state"

export interface IdentityChoice {
  name: string
  email: string
  target: string | null
}

interface IdentityStepProps {
  progress: WorkspaceProgressView
  identity: IdentityChoice
  defaultTarget: string | null
  onIdentityChange: (identity: IdentityChoice) => void
  onViewProgress: () => void
}

export function IdentityStep({ progress, identity, defaultTarget, onIdentityChange, onViewProgress }: IdentityStepProps) {
  return (
    <section aria-labelledby="identity-title" className="mx-auto max-w-3xl">
      <WorkspaceProgressStrip progress={progress} onView={onViewProgress} />
      <div className="mb-5">
        <h2 id="identity-title" className="text-xl font-semibold tracking-tight">Git identity</h2>
        <p className="mt-1 text-sm text-muted-foreground">Set the author name and email used for commits inside your workspaces.</p>
      </div>
      <div className="space-y-4 rounded-lg border border-border bg-card p-4">
        <div className="grid gap-4 sm:grid-cols-2">
          <label className="grid gap-1.5 text-xs font-medium" htmlFor="identity-name">
            Name
            <Input id="identity-name" value={identity.name} onChange={(event) => onIdentityChange({ ...identity, name: event.target.value })} autoComplete="name" />
          </label>
          <label className="grid gap-1.5 text-xs font-medium" htmlFor="identity-email">
            Email
            <Input id="identity-email" type="email" value={identity.email} onChange={(event) => onIdentityChange({ ...identity, email: event.target.value })} autoComplete="email" />
          </label>
        </div>
        <label className="flex items-start gap-2.5 rounded-md border border-border p-3 text-xs">
          <Checkbox
            checked={identity.target === null}
            disabled={defaultTarget === null}
            onCheckedChange={(checked) => onIdentityChange({ ...identity, target: checked === true ? null : defaultTarget })}
            aria-label="Apply identity to all workspaces"
          />
          <span>
            Apply to all {progress.workspaces.length} workspaces when they are ready
            {identity.target !== null && <span className="mt-0.5 block text-muted-foreground">Currently limited to {identity.target}.</span>}
          </span>
        </label>
      </div>
    </section>
  )
}
