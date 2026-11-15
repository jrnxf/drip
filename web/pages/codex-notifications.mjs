import { ABOUT, pre, snippet } from "./lib.mjs";

export default {
  title: "Codex notifications on Mac, from the notch",
  description:
    "Add a hook snippet to ~/.codex/hooks.json and Codex shows a card from your Mac's notch when it wants to run something. Trust it with /hooks. Free, open source.",
  label: "guide / coding agents",
  h1: "Codex notifications on Mac, <b>from the notch.</b>",
  answer:
    "Add a hook snippet to <code>~/.codex/hooks.json</code> and Codex shows a card from your Mac's notch whenever it wants to run something. Install drip with <code>brew install jrnxf/tap/drip</code>, add the snippet, then run <code>/hooks</code> in Codex to trust it.",
  body: `
<p>Add this to <code>~/.codex/hooks.json</code> (<code>$CODEX_HOME/hooks.json</code> if you set it). If the file has a <code>hooks</code> entry already, merge the events and keep your own hooks. This is the permission-cards recipe: a card when Codex needs you, and nothing else.</p>
${pre(snippet("permission-cards", "Codex"))}
<p>Codex runs a new hook only after you trust it: run <code>/hooks</code> in Codex. If your <code>config.toml</code> has an older <code>notify = ["drip", "hook", "codex"]</code> line, delete it, or each done card shows twice.</p>
<p>${ABOUT}</p>
<h2>A card when a turn is done</h2>
<p>The everything recipe adds a <code>Stop</code> hook. The done card shows Codex's last message and replaces the waiting card of that session in place. Use this file instead of the one above.</p>
${pre(snippet("everything", "Codex"))}
`,
  steps: [
    "<b>Hooks, not polling.</b> The snippet hooks Codex's <code>PermissionRequest</code> event, which fires when Codex wants to run something. <code>PostToolUse</code> and <code>UserPromptSubmit</code> are in it only to take the card away.",
    "<b>One card per request.</b> Each hook runs <code>drip hook codex</code>, which reads the hook's JSON and shows <code>my-app needs you</code> with what Codex wants, such as <code>Codex wants to run npm install</code>.",
    "<b>Gone once you answer.</b> Approve in the terminal, or send Codex a prompt, and the card that said it needs you goes.",
    "<b>Otherwise it stays</b> until you click it, the session's next card replaces it, or 10 minutes pass. A click brings forward the terminal Codex runs in.",
    "<b>Codex's own icon.</b> The card shows the icon of the Codex app or ChatGPT.app when one is installed, and the Codex mark that drip bundles when not.",
  ],
  faq: [
    [
      "Do I need to change Codex's config.toml?",
      "No, the hooks live in <code>~/.codex/hooks.json</code>. Only if <code>config.toml</code> has an older <code>notify = [\"drip\", \"hook\", \"codex\"]</code> line, delete it, or each done card shows twice.",
    ],
    [
      "Why does Codex show no card after I add the hooks?",
      "Codex runs a new hook only once you trust it. Run <code>/hooks</code> in Codex and trust the drip hooks.",
    ],
    [
      "Can I get a card when Codex finishes?",
      "Yes. Add a <code>Stop</code> hook that runs <code>drip hook codex</code>, as the everything recipe above does. The done card shows Codex's last message. To skip it for short turns, add <code>--min-turn 30</code> to that hook, as the long-turns recipe does.",
    ],
    [
      "Can I allow or deny from the card?",
      "Yes, with the approve-from-card recipe, which runs <code>drip hook codex --approve</code> on <code>PermissionRequest</code>. Codex asks in its terminal only once the hook returns, so the card has Allow and Deny only while you are not watching that terminal. With nothing clicked in 9 minutes, the terminal asks as usual.",
    ],
    [
      "How do I get no cards from one Codex run?",
      "Set <code>DRIP_HOOK=off</code> for that run, as in <code>DRIP_HOOK=off codex exec \"fix the flaky test\"</code>. drip cannot tell a Codex session nobody attends, so the variable is how you say it.",
    ],
  ],
};
