import { ABOUT, pre, snippet } from "./lib.mjs";

export default {
  title: "Aider notifications on Mac, from the notch",
  description:
    "Start Aider with --notifications-command set to a drip command and a card from your Mac's notch shows when Aider is done and waits for you. Free, open source.",
  label: "guide / coding agents",
  h1: "Aider notifications on Mac, <b>from the notch.</b>",
  answer:
    "Start Aider with <code>--notifications --notifications-command</code> set to a drip command, and a card from your Mac's notch shows when Aider is done and waits for you. Install drip first with <code>brew install jrnxf/tap/drip</code>.",
  body: `
<p>Aider has no hooks, so this recipe uses its notification command and installs nothing in drip. Start Aider like this:</p>
${pre(snippet("aider"))}
<p>Or, in <code>.aider.conf.yml</code>: <code>notifications: true</code>, and <code>notifications-command:</code> with the same command.</p>
<p>${ABOUT}</p>
`,
  steps: [
    "<b>Aider runs a command when it waits.</b> <code>--notifications-command</code> is that command, and <code>--notifications</code> turns the feature on.",
    "<b>The command is drip.</b> <code>drip ok</code> shows a green card titled with the project's folder name and <code>is done</code>.",
    "<b>One card per project.</b> The id is <code>aider:$PWD</code>, so a new card from the same project replaces its last one instead of queueing behind it.",
    "<b>Change the look.</b> Change the title, the icon or the card options. <code>drip --help</code> lists them.",
  ],
  faq: [
    [
      "Does Aider need hooks for this?",
      "No. Aider has no hooks, so the recipe uses its notification command. Nothing is installed in drip, and you change no file unless you want the command in <code>.aider.conf.yml</code>.",
    ],
    [
      "How do I make it permanent?",
      "Put it in <code>.aider.conf.yml</code>: <code>notifications: true</code>, and <code>notifications-command:</code> with the same command as on the command line.",
    ],
    [
      "What if I run Aider in two projects at once?",
      "Each project gets its own card. The id is <code>aider:$PWD</code>, so only a new card from the same folder replaces the last one.",
    ],
    [
      "Can the card ask for permission like Claude Code's?",
      "No. The recipe shows one card, for when Aider is done and waits for you. For a tool without hooks, you can wrap what it runs in <code>drip run</code>, or call drip from the tool's own commands.",
    ],
  ],
};
