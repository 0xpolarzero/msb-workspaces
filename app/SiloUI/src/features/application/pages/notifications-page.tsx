import { useState } from "react"
import { Bell, CircleAlert, HardDrive, HeartPulse } from "lucide-react"

import { ListCard, ListRow, ListRowIcon } from "@/components/list-row"
import { Switch } from "@/components/ui/switch"

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
    <div className="mx-auto grid w-full max-w-4xl gap-4 px-4 py-5 sm:px-6 sm:py-6">
      <h2 className="text-xs font-medium">Notifications</h2>
      <ListCard>
        <ListRow
          className="hover:bg-muted/35 focus-within:bg-muted/35"
          icon={<ListRowIcon aria-hidden="true"><Bell className="size-3.5" /></ListRowIcon>}
          title={<h3>Enable notifications</h3>}
          detail="Silo can send alerts while its window is closed."
          detailClassName="whitespace-normal"
          actions={<Switch checked={enabled} onCheckedChange={setEnabled} aria-label="Enable notifications" />}
        />
      </ListCard>
      <section className="grid gap-2">
        <h3 className="text-xs font-medium">Alert categories</h3>
        <ListCard>
          {categories.map(({ id, label, detail, icon: Icon }) => (
            <ListRow
              key={id}
              className="hover:bg-muted/35 focus-within:bg-muted/35"
              icon={<ListRowIcon aria-hidden="true"><Icon className="size-3.5" /></ListRowIcon>}
              title={<h4>{label}</h4>}
              detail={detail}
              detailClassName="whitespace-normal"
              actions={<Switch checked={selectedCategories.has(id)} onCheckedChange={(checked) => setCategory(id, checked)} disabled={!enabled} aria-label={label} />}
            />
          ))}
        </ListCard>
      </section>
    </div>
  )
}
