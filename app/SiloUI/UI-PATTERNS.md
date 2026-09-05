# Compact app rows

Use `ListCard`, `ListRow`, and `ListRowIcon` from `src/components/list-row.tsx`
for records and settings with a left icon, title, caption, and right action or
metadata. Use `ListRowDetails` for expanded review, progress, or result content.

Let titles and captions inherit their type size from `ListRow`: 13px medium
titles and 11px captions, both with 16px line height. The icon tile is 28px;
text buttons use `size="xs"`. Keep semantic headings, list roles, status
announcements, and useful truncation or wrapping at the call site. Badges,
timestamps, and progress percentages can use smaller metadata text.

When changing this pattern, inspect every consumer and its running, failure,
and expanded states. Avoid adding page-specific title or caption sizes.

## App surface audit

| Surface | Shared rows |
| --- | --- |
| Overview | VM and SSH records through `SandboxListRow`; configuration status uses the same icon tile. |
| Files | Repository records; push controls and feedback remain below the header. |
| Activity | Every event, including progress, success, warning, and failure. |
| GitHub | Connected, connecting, and disconnected account cards. |
| Secrets | Secret records, sandbox badges, and restart notices. |
| Backup | Create backup, restore archive, and recent archives; inline review and results use `ListRowDetails`. |
| General | Startup, polling, application preferences, and accessibility settings. |
| Notifications | Main toggle and alert categories. |
| System issue | Repair header and expanded details; ordered repair steps share the icon tile. |

## Specialized layouts reviewed

Logs, Network, and GitHub repository permissions need aligned table columns.
The file tree needs hierarchy and indentation. Navigation and disclosure
headings are single-line controls. Configuration editors are forms. Empty
states are centered explanations. Inline operation feedback and temporary
repair notices remain compact status messages within their owning surface.
These do not need a two-line record card.

Onboarding keeps its existing larger account and application preference
presentation through the shared components' `compact` options.
