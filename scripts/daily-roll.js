#!/usr/bin/env node
/*
 * daily-roll.js — keep research / industry / science a rolling 7-day window.
 *
 * Since the switch to a daily cadence the page no longer shows "one week's sweep,
 * replaced wholesale". It shows every item ADDED in the last 7 days (KST), and each run
 * only adds the day's new items (daily-prompt.md). Something has to take items off the
 * page again once they are a week old, and that is arithmetic, not judgement — so it is
 * a script, in the same spirit as pi-aggregate.js and gen-seeds.js.
 *
 * Two modes:
 *
 *   node scripts/daily-roll.js [--date YYYY-MM-DD] [--days 7] [--dry-run]
 *       Runs BEFORE the Claude session. Sets `const RUN_DATE` to the run date and drops
 *       every item whose `added` date is older than the window. Items that predate the
 *       daily cadence have no `added`; their `date` stands in for it (or the previous
 *       RUN_DATE when the date is month-only). Never empties an array below MIN_KEEP —
 *       a page with an empty tab reads as "nothing happened", which is a claim nobody
 *       verified; it keeps the newest few and says so loudly instead.
 *
 *   node scripts/daily-roll.js --check [--date YYYY-MM-DD]
 *       Runs AFTER the Claude session, as a publish gate. Fails (exit 1) when an item has
 *       a malformed or future `added`, when one array carries the same link twice, or when
 *       an item added today is missing desc / desc_en / link. Prints today's additions.
 *
 * Item text is never rewritten: kept items are copied byte-for-byte from the source, so
 * the git diff of a roll shows only removed items and the RUN_DATE line.
 */
"use strict";
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const INDEX = path.join(ROOT, "index.html");
const ARRAYS = ["research", "industry", "science"];
const MIN_KEEP = 3;

const argv = process.argv.slice(2);
const arg = (k, d) => { const i = argv.indexOf(k); return i >= 0 ? argv[i + 1] : d; };
const CHECK = argv.includes("--check");
const DRY = argv.includes("--dry-run");
const kstToday = () => new Date(Date.now() + 9 * 3600e3).toISOString().slice(0, 10);
const TODAY = arg("--date", kstToday());
const DAYS = Number(arg("--days", "7"));
const ISO = /^\d{4}-\d{2}-\d{2}$/;
if (!ISO.test(TODAY)) { console.error("daily-roll: bad --date " + TODAY); process.exit(2); }
if (!(DAYS >= 1)) { console.error("daily-roll: bad --days"); process.exit(2); }

const addDays = (d, n) => {
  const t = new Date(d + "T00:00:00Z"); t.setUTCDate(t.getUTCDate() + n);
  return t.toISOString().slice(0, 10);
};
const CUTOFF = addDays(TODAY, -(DAYS - 1)); // inclusive: TODAY and the DAYS-1 days before it

/* Split `const name = [ ... ];` into the exact source text of each top-level object.
   A small scanner rather than a regex: descriptions contain braces, brackets and quotes. */
function locate(html, name) {
  const head = "const " + name + " = [";
  const s = html.indexOf(head);
  if (s < 0) throw new Error("index.html has no `" + head + "`");
  const e = html.indexOf("\n];", s);
  if (e < 0) throw new Error("unterminated `" + name + "` array");
  const body = html.slice(s + head.length, e);
  const items = [];
  let depth = 0, start = -1, q = null;
  for (let i = 0; i < body.length; i++) {
    const c = body[i];
    if (q) {
      if (c === "\\") { i++; continue; }
      if (c === q) q = null;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") { q = c; continue; }
    if (c === "/" && body[i + 1] === "*") { const k = body.indexOf("*/", i + 2); i = k < 0 ? body.length : k + 1; continue; }
    if (c === "{") { if (depth === 0) start = i; depth++; }
    else if (c === "}") { depth--; if (depth === 0) items.push(body.slice(start, i + 1)); }
  }
  if (depth !== 0 || q) throw new Error("could not parse `" + name + "` (unbalanced)");
  // Cross-check the scanner against the JS engine: same count, same objects.
  const parsed = eval("[" + body + "]");
  if (parsed.length !== items.length) throw new Error("`" + name + "`: scanner found " + items.length + " items, eval found " + parsed.length);
  return { s: s, e: e + 3, head: head, items: items.map((src, i) => ({ src: src, obj: parsed[i] })) };
}

function rebuild(head, kept) {
  return head + "\n" + kept.map((x) => "  " + x.src + ",").join("\n") + "\n];";
}

let html = fs.readFileSync(INDEX, "utf8");
const m = html.match(/const RUN_DATE = "(\d{4}-\d{2}-\d{2})";/);
if (!m) throw new Error("index.html has no `const RUN_DATE = \"YYYY-MM-DD\";` line");
const PREV = m[1];

/* ------------------------------ --check ------------------------------ */
if (CHECK) {
  const bad = [], warn = [];
  const added = {};
  for (const name of ARRAYS) {
    const { items } = locate(html, name);
    if (!items.length) bad.push(name + " is EMPTY");
    const links = new Map();
    added[name] = 0;
    items.forEach(({ obj }, i) => {
      const tag = name + "[" + i + "] " + String(obj.title || obj.company || "").slice(0, 50);
      if (obj.added === undefined) warn.push(tag + " has no `added` (pre-daily item)");
      else if (!ISO.test(obj.added)) bad.push(tag + " bad added: " + obj.added);
      else if (obj.added > TODAY) bad.push(tag + " added is in the future: " + obj.added);
      else if (obj.added < CUTOFF) warn.push(tag + " added " + obj.added + " is outside the window (kept by MIN_KEEP?)");
      if (obj.added === TODAY) {
        added[name]++;
        for (const f of ["desc", "desc_en", "link", "date"])
          if (!obj[f] || !String(obj[f]).trim()) bad.push(tag + " (new today) missing " + f);
        if (typeof obj.ver !== "boolean") bad.push(tag + " (new today) ver is not a boolean");
      }
      /* Duplicate links. A research link is a DOI, so two cards on one DOI is always a
         mistake. Industry items legitimately share one link when a weekly digest is the
         primary source for several events, so there it is only a warning. Science sits in
         between: an old pair is tolerated, but re-adding an article already on the page
         today is the exact failure a daily cadence invites, so that fails. */
      if (obj.link) {
        const k = String(obj.link).trim().replace(/\/+$/, "").toLowerCase();
        if (links.has(k)) {
          const j = links.get(k);
          const msg = name + ": duplicate link at [" + j + "] and [" + i + "]: " + obj.link;
          const today = obj.added === TODAY || items[j].obj.added === TODAY;
          if (name === "research" || (name === "science" && today)) bad.push(msg);
          else warn.push(msg);
        } else links.set(k, i);
      }
    });
  }
  if (PREV !== TODAY) bad.push("RUN_DATE is " + PREV + ", expected " + TODAY + " — was the roll skipped or RUN_DATE hand-edited?");
  warn.forEach((w) => console.log("  WARNING: " + w));
  if (bad.length) {
    console.error("daily-roll --check FAILED:\n  " + bad.join("\n  "));
    process.exit(1);
  }
  console.log("daily-roll --check OK (" + TODAY + "): new today — research +" + added.research +
    ", industry +" + added.industry + ", science +" + added.science);
  process.exit(0);
}

/* ------------------------------ roll ------------------------------ */
const effAdded = (o) => {
  if (o.added && ISO.test(o.added)) return o.added;
  if (o.date && ISO.test(o.date)) return o.date;
  return PREV; // month-only legacy item: it was on the page as of the last run
};

const report = [];
// Work from the last array backwards so earlier offsets stay valid.
const spans = ARRAYS.map((n) => Object.assign({ name: n }, locate(html, n))).sort((a, b) => b.s - a.s);
for (const sp of spans) {
  const fresh = sp.items.filter((x) => effAdded(x.obj) >= CUTOFF);
  let kept = fresh;
  let floor = 0;
  if (fresh.length < Math.min(MIN_KEEP, sp.items.length)) {
    // Keep the newest few instead of emptying the tab. Preserve their original order.
    const ranked = sp.items.map((x, i) => [x, i])
      .sort((a, b) => effAdded(b[0].obj).localeCompare(effAdded(a[0].obj)) || a[1] - b[1])
      .slice(0, Math.min(MIN_KEEP, sp.items.length)).map((p) => p[1]);
    const keepIdx = new Set(ranked);
    kept = sp.items.filter((_, i) => keepIdx.has(i));
    floor = kept.length - fresh.length;
  }
  report.push({ name: sp.name, before: sp.items.length, after: kept.length, floor: floor });
  html = html.slice(0, sp.s) + rebuild(sp.head, kept) + html.slice(sp.e);
}
html = html.replace(/const RUN_DATE = "\d{4}-\d{2}-\d{2}";/, 'const RUN_DATE = "' + TODAY + '";');

// The rebuilt arrays must still parse to exactly the kept objects.
for (const r of report) {
  const n = locate(html, r.name).items.length;
  if (n !== r.after) throw new Error("REFUSING TO WRITE: " + r.name + " rebuilt to " + n + " items, expected " + r.after);
}

if (!DRY) fs.writeFileSync(INDEX, html);

console.log("daily-roll " + (DRY ? "(dry-run) " : "") + "OK: RUN_DATE " + PREV + " -> " + TODAY +
  ", window " + CUTOFF + " .. " + TODAY);
report.reverse().forEach((r) => {
  console.log("  " + r.name.padEnd(9) + r.before + " -> " + r.after + " (-" + (r.before - r.after) + ")" +
    (r.floor ? "   WARNING: kept " + r.floor + " expired item(s) so the tab is not empty" : ""));
});
console.log("PREV_RUN_DATE=" + PREV);
