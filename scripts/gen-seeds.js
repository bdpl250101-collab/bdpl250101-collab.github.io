#!/usr/bin/env node
/*
 * gen-seeds.js — regenerate index.html's inline student seeds from data/*.json,
 * and guard the data layer on the way.
 *
 * Section 4b of weekly-prompt.md says each student section exists twice on purpose:
 * the inline seed arrays (`jobs`, `postdoc`, `grants`, `SECMETA`) that paint on first
 * render and survive a blocked fetch, and `data/*.json`, the pipeline-facing copy.
 * It then asks whoever edited the JSON to "regenerate the inline seeds" — by hand.
 * Two copies kept in step by hand is a drift waiting to happen, and drift here is
 * invisible: the page renders the stale seed, the fetch quietly replaces it, and
 * nobody sees the mismatch until the fetch is the thing that fails.
 *
 * So: data/*.json is the source of truth, and this script writes the seeds from it.
 * ./check-student-sections.sh still compares the two afterwards — this script makes
 * that comparison pass by construction rather than by care.
 *
 * The seed blocks it writes are machine-generated. Do not hand-edit them; edit
 * data/*.json and re-run this.
 *
 * Before writing anything it validates the data layer, because a seed generated from
 * a broken JSON file is a broken seed:
 *   - a section is never emptied, and never loses an official portal link
 *   - every item carries desc and desc_en
 *   - `updated` (lastChecked) is a real date and never moves backwards
 *   - pi_archive counts never fall, and `flag` agrees with count against threshold
 * Fail-closed throughout: an unreadable HEAD aborts rather than passing, for the same
 * reason section 6's archive gate does.
 *
 * Usage:
 *   node scripts/gen-seeds.js            validate, then regenerate the seeds
 *   node scripts/gen-seeds.js --check    validate only; fail if the seeds are stale
 *   node scripts/gen-seeds.js --base REF compare against REF instead of HEAD
 */
"use strict";
const fs = require("fs");
const path = require("path");
const cp = require("child_process");

const ROOT = path.resolve(__dirname, "..");
const INDEX = path.join(ROOT, "index.html");
const SECTIONS = ["jobs", "postdoc", "grants"];

const argv = process.argv.slice(2);
const CHECK_ONLY = argv.includes("--check");
const baseIdx = argv.indexOf("--base");
const BASE = baseIdx >= 0 ? argv[baseIdx + 1] : "HEAD";

const failures = [];
const warnings = [];
const fail = (m) => failures.push(m);
const warn = (m) => warnings.push(m);

/* Portals that must never disappear, whatever a week's search turns up. These are the
   fixed official sources the dashboard promises to always link; a run that finds
   nothing must still leave the reader a door to knock on. Matched on substring so a
   tracking parameter or an http/https swap does not trip the check. */
const REQUIRED_PORTALS = {
  jobs: ["careers.lg.com", "samsungcareers.com", "sk-on.com/recruit"],
  postdoc: [
    "jobs.electrochem.org", "faraday.ac.uk", "jobs.ac.uk",
    "ch.cam.ac.uk", "uni-muenster.de/MEET", "hiu-batteries.de",
  ],
  grants: ["iris.go.kr", "nrf.re.kr", "keit.re.kr", "ketep.re.kr"],
};

/* ---------- git access, fail-closed ---------- */

const git = (args) => cp.execSync("git " + args, { cwd: ROOT, encoding: "utf8", maxBuffer: 1e8 });

try {
  git("rev-parse " + BASE);
} catch (e) {
  console.error("gen-seeds FAILED TO READ " + BASE + ": " + e.message + " — refusing to proceed");
  process.exit(1);
}

// null = the path genuinely does not exist at BASE (a new file), which is not an error.
function readAtBase(rel) {
  try {
    git("cat-file -e " + BASE + ":" + rel);
  } catch (e) {
    return null;
  }
  try {
    return JSON.parse(git("show " + BASE + ":" + rel));
  } catch (e) {
    console.error("gen-seeds FAILED TO READ " + BASE + ":" + rel + ": " + e.message + " — refusing to proceed");
    process.exit(1);
  }
}

const readJson = (rel) => JSON.parse(fs.readFileSync(path.join(ROOT, rel), "utf8"));
const isDate = (s) => /^\d{4}-\d{2}-\d{2}$/.test(String(s || ""));
const today = () => new Date().toISOString().slice(0, 10);
const nonEmpty = (v) => typeof v === "string" && v.trim().length > 0;

/* ---------- 1. validate the three student sections ---------- */

const data = {};
for (const name of SECTIONS) {
  const rel = "data/" + name + ".json";
  try {
    data[name] = readJson(rel);
  } catch (e) {
    fail(rel + ": unreadable or invalid JSON — " + e.message);
    continue;
  }
  const d = data[name];
  const old = readAtBase(rel);

  if (!isDate(d.updated)) fail(rel + ": `updated` is missing or not YYYY-MM-DD (" + d.updated + ")");
  else {
    if (d.updated > today()) fail(rel + ": `updated` is in the future (" + d.updated + ")");
    if (old && isDate(old.updated) && d.updated < old.updated)
      fail(rel + ": `updated` moved backwards, " + old.updated + " -> " + d.updated);
    if (old && d.updated === old.updated)
      warn(rel + ": `updated` unchanged at " + d.updated + " — a run that checked this section should advance it");
  }

  for (const k of ["notice", "context", "portals_title"])
    if (!d[k] || !nonEmpty(d[k].ko) || !nonEmpty(d[k].en))
      fail(rel + ": `" + k + "` needs non-empty ko and en");

  if (!Array.isArray(d.items)) fail(rel + ": `items` is not an array");
  else if (!d.items.length)
    fail(rel + ": `items` is EMPTY — a failed search must keep the previous items, not clear them");
  else if (old && Array.isArray(old.items) && d.items.length < old.items.length)
    warn(rel + ": items shrank " + old.items.length + " -> " + d.items.length +
         " (fine if postings expired; check that a failed search did not silently drop them)");

  (d.items || []).forEach((x, i) => {
    const at = rel + " items[" + i + "]";
    for (const f of ["group", "tag", "title", "meta", "deadline", "desc", "desc_en"])
      if (!nonEmpty(x[f])) fail(at + ": `" + f + "` is missing or empty");
    if (typeof x.ok !== "boolean") fail(at + ": `ok` must be a boolean");
    /* link_type is what the card promises the reader. "deep" claims the URL opens the
       posting itself; the other two admit it does not, and lean on `query` to say what
       to search for — so a non-deep card with no query renders an empty pair of quotes. */
    if (!["deep", "search", "portal"].includes(x.link_type))
      fail(at + ": `link_type` must be deep, search or portal (got " + JSON.stringify(x.link_type) + ")");
    if (x.link_type !== "deep" && !nonEmpty(x.query))
      fail(at + ": `query` is required when link_type is " + JSON.stringify(x.link_type) +
           " — the card has to name what the reader should search for");
    if (x.link_type === "deep" && !nonEmpty(x.link))
      fail(at + ": link_type is deep but the item has no link");
    // No link is allowed and renders link-free; a broken-looking one is not.
    if (x.link != null && !/^https?:\/\/\S+$/.test(String(x.link)))
      fail(at + ": `link` is present but not an http(s) URL: " + x.link);
  });

  const urls = (d.portals || []).map((p) => String(p.url || ""));
  if (!urls.length) fail(rel + ": `portals` is empty — the official source links must always be present");
  for (const must of REQUIRED_PORTALS[name])
    if (!urls.some((u) => u.includes(must))) fail(rel + ": required portal link missing: " + must);
  for (const p of d.portals || [])
    if (!nonEmpty(p.name) || !/^https?:\/\/\S+$/.test(String(p.url || "")))
      fail(rel + ": every portal needs a name and an http(s) url (" + JSON.stringify(p) + ")");
  if (old && Array.isArray(old.portals))
    for (const p of old.portals)
      if (!urls.includes(String(p.url))) fail(rel + ": a portal link was removed: " + p.url);
}

/* ---------- 2. validate pi_archive ---------- */

let pi = null;
try {
  pi = readJson("data/pi_archive.json");
} catch (e) {
  fail("data/pi_archive.json: unreadable or invalid JSON — " + e.message);
}
if (pi) {
  const oldPi = readAtBase("data/pi_archive.json");
  const threshold = Number(pi.threshold);
  if (!Number.isFinite(threshold) || threshold < 1) fail("pi_archive.json: `threshold` must be a positive number");
  if (oldPi && Number(oldPi.threshold) !== threshold)
    fail("pi_archive.json: `threshold` changed " + oldPi.threshold + " -> " + threshold +
         " — that silently re-flags or un-flags every PI; change it deliberately or not at all");
  if (!isDate(pi.updated)) fail("pi_archive.json: `updated` is missing or not YYYY-MM-DD");

  const byKey = new Map((pi.entries || []).map((e) => [e.key, e]));
  if (oldPi && Array.isArray(oldPi.entries))
    for (const o of oldPi.entries) {
      const now = byKey.get(o.key);
      if (!now) fail("pi_archive.json: entry disappeared: " + o.key);
      else if (Number(now.count) < Number(o.count))
        fail("pi_archive.json: count went backwards for " + o.key + ": " + o.count + " -> " + now.count);
    }

  const seenDoi = new Map();
  for (const e of pi.entries || []) {
    if (!nonEmpty(e.key) || !nonEmpty(e.pi) || !nonEmpty(e.org))
      fail("pi_archive.json: an entry is missing key/pi/org: " + JSON.stringify(e.key || e.pi || e));
    if (!Array.isArray(e.papers)) { fail("pi_archive.json: " + e.key + " has no papers array"); continue; }
    if (Number(e.count) !== e.papers.length)
      fail("pi_archive.json: " + e.key + " count " + e.count + " does not match " + e.papers.length + " papers");
    const want = e.papers.length >= threshold;
    if (e.flag !== want)
      fail("pi_archive.json: " + e.key + " flag is " + e.flag + " but count " + e.count +
           " against threshold " + threshold + " requires " + want);
    if (e.flag && !isDate(e.flagged_since))
      fail("pi_archive.json: " + e.key + " is flagged but has no valid `flagged_since`");
    for (const p of e.papers) {
      if (!p.doi) { warn("pi_archive.json: " + e.key + " has a paper with no doi: " + p.title); continue; }
      const prev = seenDoi.get(p.doi);
      if (prev === e.key) fail("pi_archive.json: " + e.key + " counts DOI " + p.doi + " twice");
      else if (prev) warn("pi_archive.json: DOI " + p.doi + " is counted under both " + prev + " and " + e.key);
      seenDoi.set(p.doi, e.key);
    }
  }
}

try {
  const w = readJson("data/postdoc_watchlist.json");
  if (!Array.isArray(w.regions) || !w.regions.length) fail("postdoc_watchlist.json: `regions` is empty");
  for (const r of w.regions || [])
    for (const e of r.entries || [])
      if (!nonEmpty(e.name) || !nonEmpty(e.org))
        fail("postdoc_watchlist.json: an entry in " + r.region + " is missing name/org: " + JSON.stringify(e));
} catch (e) {
  fail("data/postdoc_watchlist.json: unreadable or invalid JSON — " + e.message);
}

/* Nothing is written if the data is bad — a seed generated from a broken JSON file is
   a broken seed, and it would overwrite the last good one. */
let warned = 0; // report() runs at each stage; a warning is printed once, not once per stage
function report() {
  for (; warned < warnings.length; warned++) console.log("WARN  " + warnings[warned]);
  if (failures.length) {
    console.error("");
    for (const f of failures) console.error("FAIL  " + f);
    console.error("\ngen-seeds: " + failures.length + " check(s) failed — nothing was written, do not commit this state");
    process.exit(1);
  }
}
report();

/* ---------- 3. regenerate the inline seeds ---------- */

let html = fs.readFileSync(INDEX, "utf8");
const NL = html.includes("\r\n") ? "\r\n" : "\n";
const GENERATED = "/* generated by scripts/gen-seeds.js from data/*.json — do not hand-edit */";

// Replace `const <name> = [ ... \n];`, keeping everything around it byte-identical.
function replaceBlock(name, open, close, body) {
  const head = "const " + name + " = " + open;
  const start = html.indexOf(head);
  if (start < 0) { fail("index.html has no `" + head + "` to regenerate"); return false; }
  const end = html.indexOf(NL + close + ";", start);
  if (end < 0) { fail("index.html: `" + name + "` block is not terminated by `" + close + ";`"); return false; }
  const generated = GENERATED + NL + head + NL + body + NL + close + ";";
  // Absorb a previous generation banner so it does not accumulate.
  let from = start;
  const banner = html.lastIndexOf(GENERATED, start);
  if (banner >= 0 && html.slice(banner + GENERATED.length, start).trim() === "") from = banner;
  html = html.slice(0, from) + generated + html.slice(end + NL.length + close.length + 1);
  return true;
}

// JSON with 2-space indent is valid JS and byte-stable, which is what a generated
// block needs. The hand-written style of the surrounding arrays is not reproducible
// deterministically, and a block that reformats itself every week is a useless diff.
const indent = (s) => s.split("\n").map((l) => "  " + l).join(NL);
const jsonBlock = (v) => indent(JSON.stringify(v, null, 2)).slice(2); // drop the first indent

let wrote = 0;
if (!CHECK_ONLY) {
  for (const name of SECTIONS) {
    const items = data[name].items.map((x) => {
      const o = {};
      for (const k of ["group", "group_en", "tag", "tag_en", "title", "title_en", "meta", "meta_en",
                       "deadline", "deadline_en", "ok", "link", "link_type", "query", "query_en",
                       "desc", "desc_en"])
        if (x[k] !== undefined) o[k] = x[k];
      return o;
    });
    const body = items.map((x) => "  " + JSON.stringify(x)).join("," + NL);
    if (replaceBlock(name, "[", "]", body)) wrote++;
  }
  const meta = {};
  for (const name of SECTIONS) {
    const d = data[name];
    meta[name] = {
      updated: d.updated, notice: d.notice, context: d.context,
      portals_title: d.portals_title, portals: d.portals,
    };
  }
  if (replaceBlock("SECMETA", "{", "}", jsonBlock(meta).replace(/^\{\r?\n?/, "").replace(/\r?\n?\}$/, "")))
    wrote++;
  report();
  fs.writeFileSync(INDEX, html);
}

/* ---------- 4. the contract with index.html ---------- */

html = fs.readFileSync(INDEX, "utf8");
for (const name of SECTIONS)
  if (!html.includes("data/" + name + ".json"))
    fail("index.html no longer references data/" + name + ".json — the panel and the data file have come apart");

// Parse the seeds back out the way check-student-sections.sh does, and confirm they
// now match the JSON. In --check mode this is the drift test; after a write it is
// proof that what we emitted is what the page will read.
function grabSeed(name) {
  const s = html.indexOf("const " + name + " = [");
  if (s < 0) return null;
  const e = html.indexOf("\n];", s);
  if (e < 0) return null;
  try { return eval(html.slice(s + ("const " + name + " = ").length, e + 2)); } catch (err) { return null; }
}
for (const name of SECTIONS) {
  const seed = grabSeed(name);
  if (!seed) { fail("index.html: the `" + name + "` seed array could not be parsed back out"); continue; }
  const want = data[name].items;
  if (seed.length !== want.length) {
    fail("index.html: `" + name + "` seed has " + seed.length + " items, data/" + name + ".json has " + want.length +
         (CHECK_ONLY ? " — run `node scripts/gen-seeds.js` to regenerate" : ""));
    continue;
  }
  for (let i = 0; i < want.length; i++)
    for (const f of ["group", "tag", "title", "meta", "deadline", "ok", "link", "link_type",
                     "query", "desc", "desc_en"])
      if (JSON.stringify(seed[i][f]) !== JSON.stringify(want[i][f] === undefined ? undefined : want[i][f]))
        fail("index.html: `" + name + "` seed item " + i + " field `" + f + "` differs from data/" + name + ".json" +
             (CHECK_ONLY ? " — run `node scripts/gen-seeds.js` to regenerate" : ""));
}

// Every `group` literal needs a badge colour, or the chip renders in the fallback grey.
const grpBlock = html.match(/const GRPCLR=\{[\s\S]*?\};/);
if (!grpBlock) warn("index.html: could not find `const GRPCLR={...}` to check group colours");
else {
  const known = new Set([...grpBlock[0].matchAll(/"([^"]+)":/g)].map((m) => m[1]));
  for (const name of SECTIONS)
    for (const g of new Set((data[name].items || []).map((x) => x.group)))
      if (!known.has(g))
        warn("data/" + name + '.json: group "' + g + '" has no GRPCLR colour in index.html — its badge falls back to grey');
}

report();

console.log(
  CHECK_ONLY
    ? "ALL SEED CHECKS PASSED — seeds in sync with data/*.json" + (warnings.length ? " (" + warnings.length + " warning(s) above)" : "")
    : "SEEDS REGENERATED from data/*.json (" + wrote + " blocks) and all checks passed" +
      (warnings.length ? " (" + warnings.length + " warning(s) above)" : "")
);
for (const name of SECTIONS)
  console.log("  " + (name + ".json").padEnd(14) + String(data[name].items.length).padStart(3) +
    " items   lastChecked " + data[name].updated);
if (pi)
  console.log("  pi_archive     " + String((pi.entries || []).length).padStart(3) + " entries  lastChecked " +
    pi.updated + "   flagged(>=" + pi.threshold + "): " + (pi.entries || []).filter((e) => e.flag).length);
