import { ABOUT, pre } from "./lib.mjs";

export default {
  title: "terminal-notifier alternative for Mac scripts",
  description:
    "Use drip in place of terminal-notifier in scripts: a card from the notch, no Notifications permission, and drip run for status and time. See both side by side.",
  label: "guide / compared",
  h1: "A terminal-notifier alternative <b>for scripts.</b>",
  answer:
    "drip does the job terminal-notifier does in a script, from the notch instead of Notification Center. Install it with <code>brew install jrnxf/tap/drip</code> and call <code>drip ok build -d finished</code>. Keep terminal-notifier if you want notifications that follow Focus.",
  body: `
<h2>The same job in both</h2>
<h3>Say a thing</h3>
${pre(`# terminal-notifier
terminal-notifier -title build -message finished

# drip
drip ok build -d finished`)}
<h3>Say how a command went</h3>
${pre(`# terminal-notifier
if make test; then
  terminal-notifier -title make -message passed
else
  terminal-notifier -title make -message failed
fi

# drip
drip run make test`)}
<h3>Ask a question</h3>
<p>terminal-notifier's <code>-action</code> and <code>-reply</code> (version 3) print the answer. drip's <code>--yes</code> and <code>--no</code> are an exit status: 0 on yes, 1 on no and 5 when nobody answers.</p>
${pre(`# drip
drip warn "Deploy to prod?" --yes Deploy --no Cancel && ./deploy.sh`)}
<p>The title stays the title, and terminal-notifier's message becomes drip's detail with <code>-d</code>. The flags are different, so change each call by hand. <code>drip run</code> shows <code>make test finished</code> in green on exit 0, or <code>make test failed (exit 2)</code> in red, with how long it took, and then exits with the command's own status.</p>
<p>${ABOUT}</p>
<h2>What is different</h2>
<div class="wide"><table>
  <thead><tr><th scope="col"></th><th scope="col">drip</th><th scope="col">terminal-notifier</th></tr></thead>
  <tbody>
    <tr><th scope="row">Shows</th><td>its own card, from the notch</td><td>a Notification Center banner</td></tr>
    <tr><th scope="row">Permission</th><td>none for a card</td><td>Notifications, asked once</td></tr>
    <tr><th scope="row">Focus and Do Not Disturb</th><td>shows anyway; <code>drip pause</code> holds cards</td><td>follows Focus</td></tr>
    <tr><th scope="row">Kept afterwards</th><td><code>drip history</code></td><td>Notification Center's list</td></tr>
    <tr><th scope="row">Wraps a command</th><td><code>drip run</code>: status, exit code and time</td><td>no</td></tr>
    <tr><th scope="row">Runs on</th><td>macOS 13+</td><td>macOS 10.14+</td></tr>
  </tbody>
</table></div>
<h2>When terminal-notifier is still the right choice</h2>
<ul>
  <li>You want a Notification Center banner that follows Focus and Do Not Disturb.</li>
  <li>You want the notification to wait in Notification Center's list afterwards.</li>
  <li>The Mac runs macOS older than 13, which drip does not support.</li>
  <li>You need a typed reply from <code>-reply</code> printed to the script.</li>
</ul>
`,
  steps: [
    "<b>drip draws its own card.</b> It grows out of the camera notch, or out of the top edge of a screen without one, so it needs no Notifications permission and does not use Notification Center.",
    "<b>Two words carry over.</b> The title is the bold text and <code>-d</code> is the gray text under it. The first word picks the look: <code>ok</code>, <code>warn</code>, <code>fail</code> or <code>info</code>.",
    "<b>A command can be wrapped.</b> <code>drip run</code> runs it, times it and picks green or red from the exit code. Scripts and <code>&amp;&amp;</code> chains work as before.",
    "<b>A question is an exit status.</b> <code>--yes</code> and <code>--no</code> add buttons, and drip exits 0 on yes, 1 on no and 5 when nobody answers.",
    "<b>Nothing is lost while you are away.</b> <code>drip history</code> keeps the cards, and <code>drip history --missed</code> lists what came up while you were away.",
  ],
  faq: [
    [
      "Is drip a replacement for terminal-notifier?",
      "For alerts about builds, deploys, tests and coding agents, yes. If you want notifications to wait in Notification Center's list and follow Focus, terminal-notifier does that and drip does not.",
    ],
    [
      "Is drip a drop-in with the same flags?",
      "No. The flags differ, so change each call by hand. A title and message become a title and <code>-d</code>, as in <code>drip ok build -d finished</code>.",
    ],
    [
      "Why is drip not in Notification Center?",
      "So it needs no Notifications permission and can show at the notch, where a glance finds it. The cost is that it does not follow Focus. Cards show during Do Not Disturb, and <code>drip pause</code> holds them for a while instead.",
    ],
    [
      "Can I use drip and terminal-notifier together?",
      "Yes. They do not touch each other's settings, so a script can call either.",
    ],
    [
      "Does drip work over ssh or on Linux?",
      "No. drip needs a Mac running macOS 13 or newer with someone logged in to the screen. Over ssh there is no GUI session, so drip exits 3.",
    ],
  ],
};
