import { Check, GitFork } from "lucide-react"

import { ListCard, ListRow, ListRowIcon } from "@/components/list-row"
import type { SetupMachineConfiguration } from "@/contracts/silo"

export function SetupComplete({ machines, githubSummary }: {
  machines: readonly SetupMachineConfiguration[]
  githubSummary: string
}) {
  return (
    <section aria-labelledby="setup-complete-title" className="mx-auto grid w-full max-w-3xl gap-3">
      <ListCard>
        <ListRow
          role="status"
          icon={<ListRowIcon className="bg-emerald-500/10 text-emerald-700 dark:text-emerald-400" aria-hidden="true"><Check className="size-3.5" /></ListRowIcon>}
          title={<h2 id="setup-complete-title">Setup complete</h2>}
          detail={`${machines.length} ${machines.length === 1 ? "sandbox is" : "sandboxes are"} ready. Open Silo to get started.`}
          detailClassName="whitespace-normal"
        />
        <ListRow
          icon={<ListRowIcon aria-hidden="true"><GitFork className="size-3.5" /></ListRowIcon>}
          title="GitHub access"
          detail={githubSummary}
          detailClassName="whitespace-normal"
        />
      </ListCard>
    </section>
  )
}
