import { ABOUT, pre, snippet } from "./lib.mjs";

export default {
  title: "Claude Code permission prompt notification on Mac",
  description:
    "Get a card from your Mac's notch when Claude Code asks for permission. It shows the command, and a short shell command gets Allow and Deny. Free, open source.",
  label: "guide / coding agents",
  h1: "Get a notification when Claude Code <b>asks for permission.</b>",
  answer:
    "Add the approve-from-card hooks to <code>~/.claude/settings.json</code> and a card from your Mac's notch shows what Claude Code wants to run. A short shell command gets Allow and Deny. Install drip first with <code>brew install jrnxf/tap/drip</code>.",
  body: `
<p>Add this to <code>~/.claude/settings.json</code> (<code>$CLAUDE_CONFIG_DIR/settings.json</code> if you set it). If the file has a <code>hooks</code> entry already, merge the events and keep your own hooks. This is the approve-from-card recipe.</p>
${pre(snippet("approve-from-card", "Claude Code"))}
<p>For a card that only tells you, with no buttons, use the permission-cards recipe: the same snippet with <code>drip hook claude</code> in place of <code>drip hook claude --approve</code> on <code>PermissionRequest</code>. If each card comes with a second notification from Claude Code itself, set Local notifications to disabled in its <code>/config</code>.</p>
<p>${ABOUT}</p>
<h2>When the card has Allow and Deny</h2>
<p>A permission card always shows what the call would do, read from the tool's own input: the command, else the file or the address, else the tool. It never shows only the agent's description of the call. Allow and Deny appear only for a shell command that is short, on one line, in plain ASCII, with no extra options. The card then shows the command character for character.</p>
<p>Every other request is asked in the terminal. The card only tells, and the hook returns at once. That covers:</p>
<ul>
  <li>other tools, such as Write, Edit, WebFetch or an MCP tool</li>
  <li>a command too long for the card</li>
  <li>a command with a line break, a tab, a run of spaces or a character outside ASCII</li>
  <li>a command with an option that can change what runs, such as <code>dangerouslyDisableSandbox</code></li>
</ul>
`,
  steps: [
    "<b>The hook waits on the card.</b> The <code>PermissionRequest</code> hook runs <code>drip hook claude --approve</code>. A click on Allow or Deny is Claude Code's answer, and the tool runs or does not, without the terminal.",
    "<b>You see the command first.</b> The card is titled <code>my-app needs you</code> and shows the command, such as <code>npm install</code>. Allow shows only when the command fits the rules above.",
    "<b>Claude asks in the terminal too.</b> Claude Code asks there at the same time, and the first answer counts. A deny in the terminal takes the card away at once. An allow does, once the tool ends.",
    "<b>Buttons wait for a still card.</b> The buttons take a click only once the card has been still for 0.4 seconds, so a click meant for the card before never answers this one.",
    "<b>No click, no change.</b> Nothing clicked in 9 minutes prints nothing, and the terminal asks as it would without drip. So does a click on the card itself, which brings the terminal forward, and the ×.",
  ],
  faq: [
    [
      "Can I allow a command from the card without seeing it?",
      "No. The card shows the command, file or tool, never only Claude Code's description of it, and Allow appears only for a short, single-line, plain-ASCII shell command that the card shows character for character.",
    ],
    [
      "What happens when the command does not fit on the card?",
      "There is no Allow button. The card only tells you, the hook returns at once and Claude Code asks in the terminal as it would without drip. The same holds for Write, Edit, WebFetch and MCP tools.",
    ],
    [
      "Can a stray click allow a command?",
      "It can, which is why the buttons are off by default and you add <code>--approve</code> by choice. The buttons also take a click only once the card has been still for 0.4 seconds.",
    ],
    [
      "What if I do nothing about the card?",
      "After 9 minutes the hook prints nothing and the terminal asks as usual. A click on the card itself, or on the ×, does the same.",
    ],
    [
      "Does it work when the screen is locked or from another machine?",
      "The card then only tells. A permission card that comes up while the screen is locked or <code>drip pause</code> holds cards has no buttons, and neither has one from another machine, because <code>--approve</code> is local only.",
    ],
  ],
};
