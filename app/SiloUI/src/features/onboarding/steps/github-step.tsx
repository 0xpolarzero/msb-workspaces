import {
  GitHubAccessEditor,
  type GitHubAccessEditorProps,
} from "@/features/github/components/github-access-editor"

export function GitHubStep(props: GitHubAccessEditorProps) {
  return (
    <section aria-labelledby="github-title" className="mx-auto flex h-full min-h-0 max-w-3xl flex-col">
      <h2 id="github-title" className="sr-only" data-visual-heading="hidden">GitHub</h2>
      <GitHubAccessEditor compactConnection confirmRepositoryClear {...props} />
    </section>
  )
}
