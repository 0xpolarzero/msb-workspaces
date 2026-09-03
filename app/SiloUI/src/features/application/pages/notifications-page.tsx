import { useState } from "react"
import { Bell, CircleAlert, HardDrive, HeartPulse } from "lucide-react"

import { Card, CardContent } from "@/components/ui/card"
import { Switch } from "@/components/ui/switch"
import { PageHeader, SectionHeader } from "@/features/application/components/application-ui"

const categories = [
  { id: "health", label: "Sandbox health", detail: "State changes and failed health checks.", icon: HeartPulse },
  { id: "actions", label: "Action failures", detail: "Start, stop, restart, push, and maintenance failures.", icon: CircleAlert },
  { id: "backup", label: "Backup failures", detail: "Backup and restore operations that need attention.", icon: HardDrive },
] as const

export function NotificationsPage() {
  const [enabled, setEnabled] = useState(true)
  const [selectedCategories, setSelectedCategories] = useState<Set<string>>(() => new Set(categories.map((category) => category.id)))

  function setCategory(id: string, checked: boolean) {
    setSelectedCategories((current) => {
      const next = new Set(current)
      if (checked) next.add(id)
      else next.delete(id)
      return next
    })
  }

  return (
    <div className="mx-auto grid w-full max-w-3xl gap-6 px-4 py-5 sm:px-6 sm:py-6">
      <PageHeader title="Notifications" description="Choose which Silo events can notify you outside the app." />
      <Card size="sm">
        <CardContent className="flex items-center gap-3">
          <span className="grid size-8 place-items-center rounded-lg bg-muted text-muted-foreground"><Bell className="size-4" /></span>
          <div className="min-w-0 flex-1"><div className="text-sm font-medium">Enable notifications</div><div className="mt-0.5 text-xs text-muted-foreground">Silo can send alerts while its window is closed.</div></div>
          <Switch checked={enabled} onCheckedChange={setEnabled} aria-label="Enable notifications" />
        </CardContent>
      </Card>
      <section className="grid gap-3">
        <SectionHeader title="Alert categories" />
        <Card size="sm">
          <CardContent className="divide-y divide-border">
            {categories.map(({ id, label, detail, icon: Icon }) => (
              <div key={id} className="flex items-center gap-3 py-3 first:pt-0 last:pb-0">
                <Icon className="size-4 text-muted-foreground" />
                <div className="min-w-0 flex-1"><div className="text-sm font-medium">{label}</div><div className="mt-0.5 text-xs text-muted-foreground">{detail}</div></div>
                <Switch checked={selectedCategories.has(id)} onCheckedChange={(checked) => setCategory(id, checked)} disabled={!enabled} aria-label={label} />
              </div>
            ))}
          </CardContent>
        </Card>
      </section>
    </div>
  )
}
