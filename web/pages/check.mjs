// Checks every page in web/public: its JSON-LD parses, the FAQ in the JSON-LD says what the page
// says, the title and description are the right length, the about sentence stands once, and every
// internal link and sitemap entry names a page that exists, and each homepage story row has
// its feature.
//
//   node web/pages/check.mjs
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { ABOUT, plain } from "./lib.mjs";

const pub = join(dirname(fileURLToPath(import.meta.url)), "..", "public");
const questionPages = new Set(readdirSync(join(pub, ".")).filter((f) => f.endsWith(".html")));
const generated = [
  "codex-notifications",
  "gemini-cli-notifications",
  "claude-code-permission-prompt-notification",
  "opencode-notifications",
  "aider-notifications",
  "terminal-notifier-alternative",
];
const errors = [];
const fail = (page, msg) => errors.push(`${page}: ${msg}`);

const exists = (path) => {
  if (path === "/" || path === "") return true;
  const clean = path.replace(/^\//, "");
  return existsSync(join(pub, clean)) || questionPages.has(`${clean}.html`);
};

for (const file of [...questionPages].sort()) {
  const html = readFileSync(join(pub, file), "utf8");
  const slug = file.replace(/\.html$/, "");
  const blocks = [...html.matchAll(/<script type="application\/ld\+json">\s*([\s\S]*?)\s*<\/script>/g)];
  if (!blocks.length) fail(file, "no JSON-LD");
  for (const b of blocks) {
    let data;
    try {
      data = JSON.parse(b[1]);
    } catch (e) {
      fail(file, `JSON-LD does not parse: ${e.message}`);
      continue;
    }
    for (const node of data["@graph"] ?? [data]) {
      if (node["@type"] !== "FAQPage") continue;
      for (const q of node.mainEntity) {
        if (!html.includes(`<h3>${q.name}</h3>`) && !html.includes(`<h3>${q.name.replace(/&/g, "&amp;")}</h3>`) && generated.includes(slug))
          fail(file, `question not on the page: ${q.name}`);
      }
      const n = (html.slice(html.indexOf("<h2>FAQ</h2>")).match(/<h3>/g) ?? []).length;
      if (generated.includes(slug) && node.mainEntity.length !== n)
        fail(file, `${node.mainEntity.length} questions in JSON-LD, ${n} on the page`);
    }
  }
  for (const m of html.matchAll(/href="(\/[^"#?]*)(?:[#?][^"]*)?"/g)) {
    if (!exists(m[1])) fail(file, `link to a missing page: ${m[1]}`);
  }
  if (!generated.includes(slug)) continue;
  const title = /<title>(.*)<\/title>/.exec(html)[1];
  const desc = plain(/name="description" content="(.*?)">/.exec(html)[1]);
  if (title.length >= 60) fail(file, `title is ${title.length} characters`);
  if (!title.endsWith(" - drip")) fail(file, "title does not end with - drip");
  if (desc.length < 140 || desc.length > 160) fail(file, `description is ${desc.length} characters`);
  const words = plain(/<p class="answer">(.*?)<\/p>/.exec(html)[1]).split(/\s+/).length;
  if (words > 50) fail(file, `answer is ${words} words`);
  if (!/<p class="answer">.*brew install jrnxf\/tap\/drip/.test(html)) fail(file, "answer lacks the install command");
  const about = html.split(ABOUT).length - 1;
  if (about !== 1) fail(file, `the about sentence stands ${about} times`);
  if (html.includes("—")) fail(file, "has an em dash");
  // A hooks snippet or a plugin is the recipe's text, character for character.
  const recipes = readdirSync(join(pub, "..", "..", "recipes"), { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => readFileSync(join(pub, "..", "..", "recipes", d.name, "README.md"), "utf8"));
  for (const m of html.matchAll(/<pre><code>([\s\S]*?)<\/code><\/pre>/g)) {
    const code = plain(m[1]);
    if (/^(\{|export const Drip)/.test(code) && !recipes.some((r) => r.includes(code)))
      fail(file, "a snippet is not in any recipe");
  }
  if (!/\/\/github\.com\/jrnxf\/drip"/.test(html)) fail(file, "no link to the repo");
}

const sitemap = readFileSync(join(pub, "sitemap.xml"), "utf8");
for (const m of sitemap.matchAll(/<loc>https:\/\/drip\.jrnxf\.co(\/[^<]*)<\/loc>/g)) {
  if (!exists(m[1])) fail("sitemap.xml", `names a missing page: ${m[1]}`);
}
for (const file of questionPages) {
  const slug = file.replace(/\.html$/, "");
  const loc = slug === "index" ? "https://drip.jrnxf.co/" : `https://drip.jrnxf.co/${slug}`;
  if (!sitemap.includes(`<loc>${loc}</loc>`)) fail("sitemap.xml", `lacks ${loc}`);
}

// The homepage's story: each row has a feature for the engine to play.
{
  const home = readFileSync(join(pub, "index.html"), "utf8");
  const rows = [...home.matchAll(/<div class="row" tabindex="0" data-key="([a-z]+)"><h2>([^<]+)<\/h2>/g)];
  const keys = new Set([...home.matchAll(/^  \{ key: "([a-z]+)"/gm)].map((m) => m[1]));
  if (!rows.length) fail("index.html", "has no story rows");
  for (const [, key] of rows) if (!keys.has(key)) fail("index.html", `no feature plays the row ${key}`);
}

if (errors.length) {
  console.error(errors.join("\n"));
  process.exit(1);
}
console.log(`checked ${questionPages.size} pages: ok`);
