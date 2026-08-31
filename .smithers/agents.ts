// smithers-source: generated
import { type AgentLike } from "smthrs";
import { ClaudeCodeAgent as SmithersClaudeCodeAgent } from "smthrs";
import { CodexAgent as SmithersCodexAgent } from "smthrs";
import { PiAgent as SmithersPiAgent } from "smthrs";
import { OmpAgent as SmithersOmpAgent } from "smthrs";
// import { CursorAgent as SmithersCursorAgent } from "smthrs";
// import { OpenAIAgent as SmithersOpenAIAgent } from "smthrs";
// import { OpenCodeAgent as SmithersOpenCodeAgent } from "smthrs";
// import { AntigravityAgent as SmithersAntigravityAgent } from "smthrs";
// import { KimiAgent as SmithersKimiAgent } from "smthrs";
// import { AmpAgent as SmithersAmpAgent } from "smthrs";
// import { VibeAgent as SmithersVibeAgent } from "smthrs";
// import { HermesCliAgent as SmithersHermesCliAgent } from "smthrs";
// import { OpenClawAgent as SmithersOpenClawAgent } from "smthrs";
// import { PoolAgent as SmithersPoolAgent } from "smthrs";

export { ClaudeCodeAgent } from "./agents/claude-code";
export { CodexAgent } from "./agents/codex";
// export { CursorAgent } from "./agents/cursor";
// export { OpenCodeAgent } from "./agents/opencode";
// export { AntigravityAgent } from "./agents/antigravity";

// class SmithersOpenRouterAgent extends SmithersOpenAIAgent {
//   generate(args = {}) {
//     if (!process.env.OPENROUTER_API_KEY) {
//       throw new Error("Smithers generated an OpenRouter default agent, but OPENROUTER_API_KEY is not set. Set OPENROUTER_API_KEY, or run `smithers agent add` to configure another agent, then rerun this workflow.");
//     }
//     return super.generate(args);
//   }
// }
//
// function createOpenRouterAgent() {
//   return new SmithersOpenRouterAgent({
//     model: "openai/gpt-5.4-mini",
//     baseURL: "https://openrouter.ai/api/v1",
//     apiKey: process.env.OPENROUTER_API_KEY,
//   });
// }

export const providers = {
  claude: new SmithersClaudeCodeAgent({ model: "claude-fable-5" }),
  codex: new SmithersCodexAgent({ model: "gpt-5.6-luna", config: { model_reasoning_effort: "medium" }, skipGitRepoCheck: true }),
//   cursor: new SmithersCursorAgent({ cwd: process.cwd() }),
//   openrouter: createOpenRouterAgent(),
//   opencode: new SmithersOpenCodeAgent({ model: "anthropic/claude-fable-5" }),
//   antigravity: new SmithersAntigravityAgent(),
  pi: new SmithersPiAgent({ provider: "openai", model: "gpt-5.6-luna" }),
  omp: new SmithersOmpAgent({ model: "gpt-5.6-luna" }),
//   kimi: new SmithersKimiAgent({ model: "kimi-k2.7-code" }),
//   amp: new SmithersAmpAgent(),
//   vibe: new SmithersVibeAgent({ agent: "auto-approve" }),
//   hermes: new SmithersHermesCliAgent(),
//   openclaw: new SmithersOpenClawAgent(),
//   pool: new SmithersPoolAgent(),
  codexSol: new SmithersCodexAgent({ model: "gpt-5.6-sol", config: { model_reasoning_effort: "xhigh" }, skipGitRepoCheck: true }),
  codexTerra: new SmithersCodexAgent({ model: "gpt-5.6-terra", config: { model_reasoning_effort: "medium" }, skipGitRepoCheck: true }),
  codexLuna: new SmithersCodexAgent({ model: "gpt-5.6-luna", config: { model_reasoning_effort: "medium" }, skipGitRepoCheck: true }),
  claudeOpus: new SmithersClaudeCodeAgent({ model: "claude-opus-5" }),
  claudeSonnet: new SmithersClaudeCodeAgent({ model: "claude-sonnet-5" }),
} as const;

export const agents = {
  // Codex runs first. Later entries are runtime fallbacks and are invoked only if every Codex attempt fails.
  cheapFast: [
    providers.codexLuna,
    providers.claudeSonnet,
    providers.pi,
    // providers.kimi,
    // providers.vibe,
    // providers.antigravity,
    // providers.openclaw,
    // providers.cursor,
  ],
  // Codex runs first. Later entries are runtime fallbacks and are invoked only if every Codex attempt fails.
  research: [
    providers.codexLuna,
    providers.claudeSonnet,
    // providers.kimi,
    // providers.antigravity,
    // providers.opencode,
    // providers.openclaw,
    // providers.cursor,
    // providers.openrouter,
  ],
  // Claude leads this seat (Codex 5.6 does not orchestrate or gate). Later entries, including Codex, are runtime fallbacks.
  implement: [
    providers.claudeOpus,
    providers.codexTerra,
    providers.claudeSonnet,
    providers.claude,
    // providers.kimi,
    // providers.antigravity,
    // providers.opencode,
    // providers.openclaw,
    // providers.openrouter,
    // providers.cursor,
  ],
  // Codex runs first. Later entries are runtime fallbacks and are invoked only if every Codex attempt fails.
  midTier: [
    providers.codexTerra,
    providers.claudeSonnet,
    providers.claude,
    // providers.kimi,
    // providers.antigravity,
    // providers.opencode,
    // providers.openclaw,
    // providers.cursor,
    // providers.openrouter,
  ],
  // Codex runs first. Later entries are runtime fallbacks and are invoked only if every Codex attempt fails.
  smartTool: [
    providers.codexTerra,
    providers.claudeSonnet,
    providers.claude,
    // providers.kimi,
    // providers.antigravity,
    // providers.opencode,
    // providers.openclaw,
    // providers.cursor,
    // providers.openrouter,
  ],
  // Codex runs first. Later entries are runtime fallbacks and are invoked only if every Codex attempt fails.
  validate: [
    providers.codexTerra,
    providers.claudeSonnet,
    providers.claude,
    // providers.kimi,
    // providers.antigravity,
    // providers.opencode,
    // providers.openclaw,
    // providers.cursor,
    // providers.openrouter,
  ],
  // Claude leads this seat (Codex 5.6 does not orchestrate or gate). Later entries, including Codex, are runtime fallbacks.
  smart: [
    providers.claudeOpus,
    providers.claude,
    providers.codexSol,
    // providers.opencode,
    // providers.openclaw,
    // providers.openrouter,
    // providers.antigravity,
    // providers.amp,
    // providers.kimi,
    // providers.cursor,
  ],
  // Codex runs first. Later entries are runtime fallbacks and are invoked only if every Codex attempt fails.
  review: [
    providers.codexSol,
    providers.claude,
    providers.claudeOpus,
    providers.claudeSonnet,
    // providers.kimi,
    // providers.amp,
    // providers.opencode,
    // providers.openclaw,
    // providers.openrouter,
    // providers.cursor,
  ],
  // Claude leads this seat (Codex 5.6 does not orchestrate or gate). Later entries, including Codex, are runtime fallbacks.
  planning: [
    providers.claude,
    providers.claudeOpus,
    providers.codexSol,
    providers.claudeSonnet,
    // providers.kimi,
    // providers.opencode,
    // providers.openclaw,
    // providers.cursor,
    // providers.openrouter,
  ],
  // Claude leads this seat (Codex 5.6 does not orchestrate or gate). Later entries, including Codex, are runtime fallbacks.
  orchestrator: [
    providers.claudeOpus,
    providers.claude,
    providers.codexSol,
    // providers.kimi,
    // providers.opencode,
    // providers.openclaw,
    // providers.cursor,
    // providers.openrouter,
  ],
} as const satisfies Record<string, AgentLike[]>;
