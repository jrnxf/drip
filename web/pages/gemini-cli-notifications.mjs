import { ABOUT, pre, snippet } from "./lib.mjs";

export default {
  title: "Gemini CLI notifications on Mac, from the notch",
  description:
    "Add a hook snippet to ~/.gemini/settings.json and Gemini CLI shows a card from your Mac's notch when a tool needs permission. Free and open source.",
  label: "guide / coding agents",
  h1: "Gemini CLI notifications on Mac, <b>from the notch.</b>",
  answer:
    "Add a hook snippet to <code>~/.gemini/settings.json</code> and Gemini CLI shows a card from your Mac's notch whenever a tool needs your permission. Install drip with <code>brew install jrnxf/tap/drip</code>, then merge the snippet into the file.",
  body: `
<p>Add this to <code>~/.gemini/settings.json</code>. If the file has a <code>hooks</code> entry already, merge the events and keep your own hooks. This is the permission-cards recipe: a card when Gemini needs you, and nothing else.</p>
${pre(snippet("permission-cards", "Gemini CLI"))}
<p>${ABOUT}</p>
<h2>A card when a turn is done</h2>
<p>The everything recipe adds an <code>AfterAgent</code> hook. The done card shows Gemini's last response and replaces the waiting card of that session in place. Use this file instead of the one above.</p>
${pre(snippet("everything", "Gemini CLI"))}
`,
  steps: [
    "<b>Hooks, not polling.</b> The snippet hooks Gemini CLI's <code>Notification</code> event, which is a tool permission. <code>AfterTool</code> and <code>BeforeAgent</code> are in it only to take the card away.",
    "<b>One card per request.</b> Each hook runs <code>drip hook gemini</code>, which reads the hook's JSON and shows <code>my-app needs you</code> with Gemini's message.",
    "<b>Gone once you answer.</b> Once the tool has run, or you send Gemini a prompt, the card that said it needs you goes. Otherwise it stays until you click it, the session's next card replaces it, or 10 minutes pass.",
    "<b>Named by project.</b> The title is the project, from the session's working directory, so several sessions at once stay apart.",
    "<b>Gemini's mark.</b> The card shows the Gemini mark that drip bundles. A click brings forward the terminal Gemini runs in.",
  ],
  faq: [
    [
      "Can I allow or deny from the card?",
      "No. Gemini CLI has no hook that takes an answer, so its card only tells you and you answer in the terminal. The <code>--approve</code> flag is for Claude Code and Codex.",
    ],
    [
      "Why do I get no card when Gemini finishes?",
      "The permission-cards recipe has no hook on the end of a turn. Add an <code>AfterAgent</code> hook that runs <code>drip hook gemini</code>, as the everything recipe above does.",
    ],
    [
      "Can a failing hook make Gemini CLI run a turn again?",
      "drip is built so it cannot. Gemini CLI reads any exit code but 0 and 1 as a block, which after a turn makes it run the turn again. <code>drip hook</code> exits 0, or 1 for any failure, never 2 or more.",
    ],
    [
      "What happens over ssh, or when nobody is logged in to the screen?",
      "There is nothing to show, so drip prints nothing and exits 0. Gemini CLI then shows no hook error after every turn.",
    ],
  ],
};
