// Helpers the page modules share.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

export const ABOUT =
  "drip is a free, open-source macOS CLI that shows scriptable notification cards from the MacBook notch, for builds, deploys and coding agents like Claude Code, Codex and Gemini CLI.";

// Every page the Related block can name, in the order it lists them.
export const links = {
  "claude-code-notifications": "Claude Code notifications on Mac",
  "notify-when-command-finishes": "Alert when a terminal command finishes",
  "codex-notifications": "Codex notifications on Mac",
  "gemini-cli-notifications": "Gemini CLI notifications on Mac",
  "claude-code-permission-prompt-notification": "Claude Code permission prompt notification",
  "opencode-notifications": "opencode notifications on Mac",
  "aider-notifications": "Aider notifications on Mac",
  "terminal-notifier-alternative": "A terminal-notifier alternative for scripts",
  vs: "drip vs terminal-notifier, osascript and alerter",
};

export const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

// A code block from text.
export const pre = (s) => `<pre><code>${esc(s.replace(/\n+$/, ""))}</code></pre>`;

// The first fenced block under "### <heading>" in a recipe's README, or the first one in the file.
export function snippet(recipe, heading = null) {
  const text = readFileSync(join(root, "recipes", recipe, "README.md"), "utf8");
  let from = 0;
  if (heading) {
    from = text.indexOf(`\n### ${heading}\n`);
    if (from < 0) throw new Error(`${recipe}: no "### ${heading}"`);
  }
  const m = /```\w*\n([\s\S]*?)\n```/.exec(text.slice(from));
  if (!m) throw new Error(`${recipe}: no code block after ${heading}`);
  return m[1];
}

// The visible text of a piece of HTML, for the JSON-LD.
export function plain(html) {
  return html
    .replace(/<[^>]+>/g, "")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#x27;/g, "'")
    .replace(/&amp;/g, "&");
}
