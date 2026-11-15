import { ABOUT, pre, snippet } from "./lib.mjs";

export default {
  title: "opencode notifications on Mac, from the notch",
  description:
    "Save a plugin in ~/.config/opencode/plugins and opencode shows a card from your Mac's notch when it asks for permission, and when a session is done.",
  label: "guide / coding agents",
  h1: "opencode notifications on Mac, <b>from the notch.</b>",
  answer:
    "Save a small plugin as <code>~/.config/opencode/plugins/drip.js</code> and opencode shows a card from your Mac's notch when it asks for a permission, and another when a session is done. Install drip first with <code>brew install jrnxf/tap/drip</code>.",
  body: `
<p>opencode has plugins instead of hooks, so this recipe is a plugin and installs nothing in drip. Save this as <code>~/.config/opencode/plugins/drip.js</code>:</p>
${pre(snippet("opencode"))}
<p>${ABOUT}</p>
<p>For permission cards only, drop the <code>session.idle</code> branch.</p>
`,
  steps: [
    "<b>Plugins, not hooks.</b> opencode loads plugins from <code>~/.config/opencode/plugins/</code>. This one listens to opencode's events and calls drip itself.",
    "<b>A permission shows a waiting card.</b> On <code>permission.asked</code> the plugin runs <code>drip info --stay</code>: <code>my-app needs you</code>, with <code>opencode wants to use</code> and the permission as the detail.",
    "<b>An idle session shows a done card.</b> On <code>session.idle</code> the plugin runs <code>drip ok</code>: <code>my-app is done</code>.",
    "<b>The done card replaces the waiting one.</b> Both use the id <code>opencode:&lt;session&gt;</code>, so a session has one card that changes in place.",
    "<b>Named by project.</b> The title is the last folder of the directory opencode runs in.",
  ],
  faq: [
    [
      "Do I need drip hook for opencode?",
      "No. opencode has plugins instead of hooks, so the plugin calls <code>drip info</code> and <code>drip ok</code> directly. <code>drip hook</code> is for Claude Code, Codex and Gemini CLI.",
    ],
    [
      "How do I get cards for permissions only?",
      "Drop the <code>session.idle</code> branch from the plugin. Then only the waiting card shows, and no done card follows it.",
    ],
    [
      "How does the waiting card go away?",
      "It stays until you click it, the done card of the same session replaces it, or 10 minutes pass. The plugin has no event that takes the card away when you answer in the terminal.",
    ],
    [
      "Can I allow or deny from the card?",
      "No. The cards only tell you. The <code>--approve</code> flag is for <code>drip hook</code> with Claude Code and Codex.",
    ],
    [
      "Does a failing drip break opencode?",
      "No. The plugin runs drip with <code>.quiet().nothrow()</code>, so a drip that fails does not throw in the plugin.",
    ],
  ],
};
