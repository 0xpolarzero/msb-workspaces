import { z } from "zod"

export const applicationPreferenceSelectionSchema = z.object({
  terminal: z.string().min(1),
  editor: z.string().min(1),
  browser: z.string().min(1),
}).strict()

export type ApplicationPreferenceSelection = z.infer<typeof applicationPreferenceSelectionSchema>

