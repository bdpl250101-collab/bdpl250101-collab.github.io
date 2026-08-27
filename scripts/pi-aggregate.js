#!/usr/bin/env node
/*
 * pi-aggregate.js — accumulate corresponding-author / PI counts into data/pi_archive.json.
 *
 * Runs OUTSIDE the weekly Claude session, from run-weekly.sh, because counting is
 * arithmetic and must not vary with model judgement. The only judgement left here is
 * "which author is the PI", and that is one fixed rule, recorded on every entry so a
 * later reader can tell how the name was obtained.
 *
 * Guarantees, in order of importance:
 *   1. Monotonic. A count never decreases and an entry is never removed. This script
 *      only ever appends papers and increments, and asserts that before writing.
 *   2. Idempotent. A DOI already recorded — under any entry, or in `unresolved` — is
 *      skipped. Re-running the same week changes nothing but `updated`.
 *   3. Fail-soft on the network, fail-loud on the data. Crossref being unreachable
 *      leaves the paper in `unresolved` and still exits 0; a malformed pi_archive.json
 *      aborts before anything is written.
 *
 * Usage: node scripts/pi-aggregate.js [--dry-run] [--offline]
 */
"use strict";
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const INDEX = path.join(ROOT, "index.html");
const ARCHIVE = path.join(ROOT, "data", "pi_archive.json");
const MAILTO = "bdpl250101@gmail.com";

const argv = process.argv.slice(2);
const DRY = argv.includes("--dry-run");
const OFFLINE = argv.includes("--offline");

/* ---------- helpers ---------- */

// Read one of index.html's inline arrays — the same extraction the section 6 gate uses.
function grabArray(html, name) {
  const s = html.indexOf("const " + name + " = [");
  if (s < 0) throw new Error("index.html has no `const " + name + " = [`");
  const e = html.indexOf("\n];", s);
  if (e < 0) throw new Error("unterminated `" + name + "` array in index.html");
  return eval(html.slice(s + ("const " + name + " = ").length, e + 2));
}

/* A DOI is the only stable key we have for a paper. Most links are doi.org or a
   publisher /doi/ path, both of which carry it literally. Nature article URLs do not,
   but their trailing article id is the DOI suffix under the 10.1038 prefix. */
function doiFromLink(link) {
  if (!link) return null;
  const direct = String(link).match(/10\.\d{4,9}\/[^\s"'<>?#]+/);
  if (direct) return direct[0].replace(/[.,;)]+$/, "").toLowerCase();
  const nature = String(link).match(/nature\.com\/articles\/([a-z0-9-]+)/i);
  if (nature) return ("10.1038/" + nature[1]).toLowerCase();
  return null;
}

// key = lowercased name and organisation joined by a hyphen, per pi_archive.counting_rule.
function norm(s) {
  return String(s == null ? "" : s)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}
const keyFor = (pi, org) => norm(pi) + "|" + norm(org);

function readJson(file) {
  const raw = fs.readFileSync(file, "utf8");
  try {
    return JSON.parse(raw);
  } catch (e) {
    throw new Error(file + " is not valid JSON: " + e.message);
  }
}

// The data files are 2-space, CRLF, newline-terminated. Keep them that way so a
// rewrite shows only the lines that actually changed.
function writeJson(file, obj) {
  fs.writeFileSync(file, JSON.stringify(obj, null, 2).replace(/\r?\n/g, "\r\n") + "\r\n");
}

const today = () => new Date().toISOString().slice(0, 10);

async function crossref(doi) {
  const url = "https://api.crossref.org/works/" + encodeURIComponent(doi) + "?mailto=" + MAILTO;
  const res = await fetch(url, {
    signal: AbortSignal.timeout(20000),
    headers: { "User-Agent": "bdpl-dashboard/1.0 (mailto:" + MAILTO + ")" },
  });
  if (!res.ok) throw new Error("Crossref HTTP " + res.status);
  return (await res.json()).message;
}

/* PI selection: the last listed author carrying an affiliation, which is the group
   leader by convention in this field. Crossref almost never marks the corresponding
   author, so this stays a convention rather than a fact — every entry it produces
   carries corresponding_confirmed:false and the rule that produced it. */
function pickPI(work) {
  const authors = (work && work.author) || [];
  if (!authors.length) return { error: "Crossref record has no author list" };
  const named = authors.filter((a) => a.family);
  if (!named.length) return { error: "Crossref authors have no family name" };
  const withAff = named.filter((a) => (a.affiliation || []).some((x) => x.name));
  const chosen = withAff.length ? withAff[withAff.length - 1] : named[named.length - 1];
  const name = [chosen.given, chosen.family].filter(Boolean).join(" ").trim();
  const aff = (chosen.affiliation || []).find((x) => x.name);
  if (!aff) return { error: "no affiliation on the last author in Crossref", name: name };
  return { name: name, org: String(aff.name).trim() };
}

/* ---------- main ---------- */

(async () => {
  const research = grabArray(fs.readFileSync(INDEX, "utf8"), "research");
  const db = readJson(ARCHIVE);

  if (!Array.isArray(db.entries)) throw new Error("pi_archive.json: `entries` is not an array");
  if (!Array.isArray(db.unresolved)) db.unresolved = [];
  const threshold = Number(db.threshold);
  if (!Number.isFinite(threshold) || threshold < 1)
    throw new Error("pi_archive.json: `threshold` must be a positive number");

  // Snapshot for the monotonicity assertion at the end.
  const before = new Map(db.entries.map((e) => [e.key, e.count]));

  /* Every paper this ledger has already seen, resolved or not — the idempotency guard.
     A DOI is the identity when we have one. When we do not, the paper still has to be
     recognisable next week, or an item whose link yields no DOI gets appended to
     `unresolved` again on every single run and the file grows without bound. */
  const seen = new Set();
  const mark = (rec) => {
    const d = rec.doi || doiFromLink(rec.link);
    if (d) {
      if (!rec.doi) rec.doi = d; // backfill so later runs need not re-derive it
      seen.add(d);
      return d;
    }
    const fallback = rec.link ? "link:" + rec.link : "title:" + norm(rec.title);
    seen.add(fallback);
    return fallback;
  };
  for (const e of db.entries) for (const p of e.papers || []) mark(p);
  for (const u of db.unresolved) mark(u);

  const byKey = new Map(db.entries.map((e) => [e.key, e]));
  let created = 0, counted = 0, skipped = 0, unresolvedNew = 0, netFail = 0;

  for (const item of research) {
    const doi = doiFromLink(item.link);
    const id = doi || (item.link ? "link:" + item.link : "title:" + norm(item.title));
    if (seen.has(id)) { skipped++; continue; }
    seen.add(id);
    if (!doi) {
      db.unresolved.push({
        doi: null, date: item.date, journal: item.journal, title: item.title,
        link: item.link || null, orgs: [],
        reason: "no DOI could be derived from the item link",
      });
      unresolvedNew++;
      continue;
    }

    let pi;
    if (OFFLINE) {
      pi = { error: "--offline: Crossref was not queried this run" };
    } else {
      try {
        pi = pickPI(await crossref(doi));
      } catch (e) {
        pi = { error: "Crossref lookup failed: " + e.message };
        netFail++;
      }
      await new Promise((r) => setTimeout(r, 120)); // stay in Crossref's polite pool
    }

    const paper = { doi: doi, date: item.date, journal: item.journal, title: item.title, link: item.link };

    if (pi.error) {
      db.unresolved.push(Object.assign({}, paper, { orgs: [], pi_guess: pi.name || null, reason: pi.error }));
      unresolvedNew++;
      continue;
    }

    const key = keyFor(pi.name, pi.org);
    let entry = byKey.get(key);
    if (!entry) {
      entry = {
        key: key, pi: pi.name, org: pi.org, count: 0,
        corresponding_confirmed: false, resolved_by: "crossref-last-author", papers: [],
      };
      db.entries.push(entry);
      byKey.set(key, entry);
      created++;
    }
    entry.papers.push(paper);
    entry.count = entry.papers.length; // the count IS the paper tally — it cannot drift
    counted++;
  }

  /* The "2 or more" rule. Flagging is derived, never hand-set, and once an entry is at
     or above threshold it stays flagged, because count cannot fall. */
  let flagged = 0;
  for (const e of db.entries) {
    e.flag = e.count >= threshold;
    if (e.flag) {
      flagged++;
      if (!e.flagged_since) e.flagged_since = today();
    }
  }

  // Monotonicity — assert it rather than trust the code above.
  for (const [k, n] of before) {
    const now = byKey.get(k);
    if (!now) throw new Error("REFUSING TO WRITE: entry disappeared: " + k);
    if (now.count < n)
      throw new Error("REFUSING TO WRITE: count went backwards for " + k + ": " + n + " -> " + now.count);
  }

  db.entries.sort((a, b) => b.count - a.count || a.key.localeCompare(b.key));
  db.updated = today();

  if (!DRY) writeJson(ARCHIVE, db);

  console.log(
    "pi_archive " + (DRY ? "(dry-run) " : "") + "OK: " + before.size + " -> " + db.entries.length +
    " entries (+" + created + " new, " + counted + " papers counted, " + skipped +
    " already seen, " + unresolvedNew + " unresolved" + (netFail ? ", " + netFail + " Crossref failures" : "") + ")"
  );
  console.log("  threshold " + threshold + " — flagged PIs: " + flagged);
  const list = db.entries.filter((e) => e.flag);
  if (list.length) list.forEach((e) => console.log("    * " + e.pi + " · " + e.org + " (count " + e.count + ")"));
  else console.log("    (none yet — no PI has reached " + threshold + ")");
})().catch((e) => {
  console.error("pi-aggregate FAILED: " + e.message);
  process.exit(1);
});
