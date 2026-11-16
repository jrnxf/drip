// Writes the question pages into web/public from the content files in this folder, so the chrome,
// head tags and JSON-LD exist once. The pages are committed: build.sh only copies web/public.
//
//   node web/pages/build.mjs           writes the pages
//   node web/pages/build.mjs --check   fails when a page in web/public differs from what it writes
//
// Each page is a module in pages/ (see codex-notifications.mjs). A snippet is read from its recipe
// in recipes/, so it is the recipe's text and a changed recipe makes the page stale. The FAQ's
// JSON-LD is made from the visible FAQ, so the two cannot differ.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { esc, plain, links } from "./lib.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..");
const SITE = "https://drip.jrnxf.co";
const REPO = "https://github.com/jrnxf/drip";
const header = readFileSync(join(here, "header.html"), "utf8").trimEnd();

const slugs = [
  "codex-notifications",
  "gemini-cli-notifications",
  "claude-code-permission-prompt-notification",
  "opencode-notifications",
  "aider-notifications",
  "terminal-notifier-alternative",
];

const attr = (s) => s.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/'/g, "&#x27;").replace(/</g, "&lt;");

function render(slug, p) {
  const url = `${SITE}/${slug}`;
  const title = `${p.title} - drip`;
  const desc = p.description;
  const related = Object.entries(links).filter(([s]) => s !== slug);
  const jsonld = {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "TechArticle",
        headline: plain(p.h1),
        description: desc,
        url,
        about: {
          "@type": "SoftwareApplication",
          name: "drip",
          url: `${SITE}/`,
          applicationCategory: "DeveloperApplication",
          operatingSystem: "macOS 13 or later",
        },
        author: { "@type": "Person", name: "jrnxf", url: "https://github.com/jrnxf" },
      },
      {
        "@type": "FAQPage",
        mainEntity: p.faq.map(([q, a]) => ({
          "@type": "Question",
          name: plain(q),
          acceptedAnswer: { "@type": "Answer", text: plain(a) },
        })),
      },
    ],
  };
  const ld = JSON.stringify(jsonld, null, 2).replace(/</g, "\\u003c");
  return `<!doctype html>
<html lang="en" data-theme="dark">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${esc(title)}</title>
<meta name="description" content="${attr(desc)}">
<link rel="canonical" href="${url}">
<meta property="og:type" content="article">
<meta property="og:site_name" content="drip">
<meta property="og:url" content="${url}">
<meta property="og:title" content="${attr(title)}">
<meta property="og:description" content="${attr(desc)}">
<meta property="og:image" content="${SITE}/og.png">
<meta property="og:image:width" content="2560">
<meta property="og:image:height" content="1280">
<meta name="twitter:card" content="summary_large_image">
<meta name="theme-color" content="#111111" media="(prefers-color-scheme: dark)">
<meta name="theme-color" content="#d9d9d5" media="(prefers-color-scheme: light)">
<link rel="icon" href="/favicon.ico" sizes="16x16 32x32 48x48">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="preload" href="/archivo.woff2" as="font" type="font/woff2" crossorigin>
<link rel="preload" href="/martian-mono.woff2" as="font" type="font/woff2" crossorigin>
<!-- guide.css: build.sh puts the compiled styles here. -->
<script>
  // The home page's theme: ?theme=, then the visitor's last choice there, then the system's.
  (() => {
    const ok = (v) => (v === "dark" || v === "light" ? v : null);
    let saved = null;
    try { saved = localStorage.getItem("drip-theme"); } catch {}
    document.documentElement.dataset.theme = ok(new URLSearchParams(location.search).get("theme")) ?? ok(saved)
      ?? (matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark");
  })();
</script>
<script type="application/ld+json">
${ld}
</script>
</head>
<body class="leading-[1.6]">
<div class="mx-auto max-w-[860px] px-24 narrow:px-16">
  <header class="flex h-58 items-center gap-22 narrow:gap-16">
${header}
  </header>
  <main class="pt-48 pb-64 narrow:pt-28">
    <article class="guide">
      <div class="lbl">${p.label}</div>
      <h1>${p.h1}</h1>
      <p class="answer">${p.answer}</p>
      <pre><code>brew install jrnxf/tap/drip</code></pre>
${p.body.trim()}
      <h2>How it works</h2>
      <ol>
${p.steps.map((s) => `        <li>${s}</li>`).join("\n")}
      </ol>
      <h2>FAQ</h2>
${p.faq.map(([q, a]) => `      <h3>${q}</h3>\n      <p>${a}</p>`).join("\n")}
      <h2>Related</h2>
      <ul>
${related.map(([s, t]) => `        <li><a href="/${s}">${esc(t)}</a></li>`).join("\n")}
        <li><a href="${REPO}">drip on GitHub</a></li>
      </ul>
    </article>
  </main>
  <footer class="flex flex-wrap justify-between gap-x-24 gap-y-10 border-t border-t-rule pt-22 pb-50">
    <span class="lbl">drip shows a native card from your Mac's notch when a command or coding agent finishes or needs you · MIT</span>
    <nav class="lbl flex flex-wrap gap-x-18 gap-y-10" aria-label="Guides"><a class="text-ink" href="/">home</a><a class="text-ink" href="/claude-code-notifications">Claude Code notifications</a><a class="text-ink" href="/notify-when-command-finishes">Alert when a command finishes</a><a class="text-ink" href="/vs">drip vs terminal-notifier</a></nav>
  </footer>
</div>
</body>
</html>
`;
}

const check = process.argv.includes("--check");
let stale = 0;
for (const slug of slugs) {
  const page = (await import(`./${slug}.mjs`)).default;
  const out = join(root, "web", "public", `${slug}.html`);
  const html = render(slug, page);
  if (check) {
    if (!existsSync(out) || readFileSync(out, "utf8") !== html) {
      console.error(`web/public/${slug}.html is stale: run node web/pages/build.mjs`);
      stale++;
    }
  } else {
    writeFileSync(out, html);
  }
}
process.exit(stale ? 1 : 0);
