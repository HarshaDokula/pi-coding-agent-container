/**
 * redact-secrets — strip credentials from tool results before they are
 * persisted to the session transcript.
 *
 * Pi replays the transcript (and this is what session files store), so any
 * secret the agent `cat`s, greps or `read`s is otherwise written to disk in
 * plaintext and fed back into future context. This extension redacts common
 * credential shapes from every tool result (SECURITY.md, A1).
 *
 * Redaction is pattern-based (it does not read your key files), so it also
 * covers keys the agent generates or reads from a source this extension does
 * not know about.
 */

import type { ExtensionAPI, ToolResultEventResult } from "@earendil-works/pi-coding-agent";

interface SecretPattern {
  re: RegExp;
  replace: string | ((match: string, ...groups: string[]) => string);
}

/**
 * Order matters: the private-key block is a multiline pattern and must run
 * before the shorter token patterns so a base64 key body cannot be partially
 * matched first.
 */
const SECRET_PATTERNS: SecretPattern[] = [
  {
    // -----BEGIN ... PRIVATE KEY----- <base64> -----END ... -----
    re: /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----/g,
    replace: () => "[REDACTED PRIVATE KEY]",
  },
  {
    // GitHub fine-grained PAT: github_pat_...
    re: /\bgithub_pat_[A-Za-z0-9_]{20,}/g,
    replace: () => "github_pat_***",
  },
  {
    // GitHub classic/OAuth/user/server tokens: ghp_, gho_, ghu_, ghs_, ghr_
    re: /\bgh[pousr]_[A-Za-z0-9]{20,}/g,
    replace: (m) => m.slice(0, 4) + "***",
  },
  {
    // AWS access key IDs
    re: /\bAKIA[0-9A-Z]{16}\b/g,
    replace: () => "AKIA***",
  },
  {
    // OpenAI/DeepSeek/Anthropic/OpenCode-style keys: sk-..., sk-ant-..., sk-proj-...
    re: /\bsk(?:-ant)?-[A-Za-z0-9_-]{16,}/g,
    replace: () => "sk-***",
  },
  {
    // Authorization header / bearer token values
    re: /\b(Bearer|Basic|token)\s+[A-Za-z0-9._~+/=-]{16,}/g,
    replace: (_m, scheme) => `${scheme} ***`,
  },
];

/** Redact secrets from a single string. Exported for testing. */
export function redactText(text: string): string {
  let out = text;
  for (const { re, replace } of SECRET_PATTERNS) {
    out = out.replace(re, replace as (substring: string, ...args: unknown[]) => string);
  }
  return out;
}

/** Recursively redact secrets from arbitrary JSON. Exported for testing. */
export function redactValue(value: unknown): unknown {
  if (typeof value === "string") return redactText(value);
  if (Array.isArray(value)) return value.map(redactValue);
  if (value !== null && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      out[k] = redactValue(v);
    }
    return out;
  }
  return value;
}

export default function (pi: ExtensionAPI) {
  pi.on("tool_result", (event) => {
    const content = event.content.map((c) =>
      c.type === "text" ? { ...c, text: redactText(c.text) } : c,
    );

    const result: ToolResultEventResult = { content };
    // Replacing content without structuredContent drops the structured result
    // (and vice versa for callers that read it), so redact both together.
    if (event.structuredContent !== undefined) {
      result.structuredContent = redactValue(event.structuredContent) as ToolResultEventResult["structuredContent"];
    }
    return result;
  });
}
