#!/usr/bin/env node
/*
 * week-archive.js — snapshot this week's dashboard into data/archive/{ISOyear}-W{week}.json.
 *
 * The dashboard itself only ever shows the current week for research and industry: both
 * arrays are replaced wholesale every run (weekly-prompt.md section 3), so once a run
 * finishes, the previous week's research list exists nowhere except in git history. The
 * annual `archive` array keeps the papers, but not the industry items, not the student
 * sections, and not the shape of any given week.
 *
 * This writes that week down. One file per ISO week, added rather than rewritten, so the
 * series accumulates the way data/pi_archive.json does.
 *
 * Re-running inside the same week rewrites only that week's own file — which is what
 * makes a second run of the day idempotent. It never touches another week's file, and it
 * asserts that no existing file disappeared before it writes.
 *
 * Usage: node scripts/week-archive.js [--dry-run] [--date YYYY-MM-DD]
 */
"use strict";
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const INDEX = path.join(ROOT, "index.html");
const DIR = path.join(ROOT, "data", "archive");

const argv = process.argv.slice(2);
const DRY = argv.includes("--dry-run");
const dIdx = argv.indexOf("--date");
const DATE = dIdx >= 0 ? argv[dIdx + 1] : new Date().toISOString().slice(0, 10);

/* ISO-8601 week: weeks start Monday and week 1 is the one holding the first Thursday,
   so the year label can differ from the calendar year at a year boundary. Getting this
   wrong only shows up once a year, in the week that silently overwrites another. */
function isoWeek(yyyymmdd) {
  const d = new Date(yyyymmdd + "T00:00:00Z");
  const t = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
  const day = t.getUTCDay() || 7;          // Sunday = 7, not 0
  t.setUTCDate(t.getUTCDate() + 4 - day);  // move to this week's Thursday
  const year = t.getUTCFullYear();
  const jan1 = new Date(Date.UTC(year, 0, 1));
  const week = Math.ceil(((t - jan1) / 86400000 + 1) / 7);
  return { year: year, week: week, id: year + "-W" + String(week).padStart(2, "0") };
}

function grabArray(html, name) {
  const s = html.indexOf("const " + name + " = [");
  if (s < 0) throw new Error("index.html has no `const " + name + " = [`");
  const e = html.indexOf("\n];", s);
  if (e < 0) throw new Error("unterminated `" + name + "` array in index.html");
  return eval(html.slice(s + ("const " + name + " = ").length, e + 2));
}

const readJson = (p) => JSON.parse(fs.readFileSync(p, "utf8"));

const html = fs.readFileSync(INDEX, "utf8");
const research = grabArray(html, "research");
const industry = grabArray(html, "industry");

const student = {};
for (const s of ["jobs", "postdoc", "grants"]) {
  const d = readJson(path.join(ROOT, "data", s + ".json"));
  student[s] = {
    updated: d.updated,
    items: d.items.map((x) => ({
      group: x.group, tag: x.tag, title: x.title, meta: x.meta,
      deadline: x.deadline, ok: x.ok, link: x.link || null,
      link_type: x.link_type || null, query: x.query || null,
    })),
  };
}

const { id, year, week } = isoWeek(DATE);
fs.mkdirSync(DIR, { recursive: true });

// Nothing may vanish. A run that would leave fewer files than it found is a bug.
const existing = fs.readdirSync(DIR).filter((f) => /^\d{4}-W\d{2}\.json$/.test(f));
const target = path.join(DIR, id + ".json");
const isNew = !fs.existsSync(target);

/* The `sub`/`cat` literals are what the dashboard groups research by; carrying them here
   keeps a snapshot readable without index.html of the same date. */
const snapshot = {
  week: id,
  iso_year: year,
  iso_week: week,
  generated: DATE,
  note: {
    ko: "주차별 스냅샷입니다. research/industry 는 매 실행 전체 교체되므로 이 파일이 해당 주의 유일한 기록입니다.",
    en: "A per-week snapshot. research and industry are replaced wholesale each run, so this file is the only record of that week.",
  },
  counts: {
    research: research.length,
    industry: industry.length,
    jobs: student.jobs.items.length,
    postdoc: student.postdoc.items.length,
    grants: student.grants.items.length,
  },
  research: research.map((x) => ({
    cat: x.cat, sub: x.sub, title: x.title, org: x.org_en || x.org,
    journal: x.journal, date: x.date, link: x.link,
  })),
  industry: industry.map((x) => ({
    region: x.region, type: x.type, company: x.company, date: x.date, link: x.link,
  })),
  student: student,
};

if (!DRY) {
  fs.writeFileSync(target, JSON.stringify(snapshot, null, 2).replace(/\r?\n/g, "\r\n") + "\r\n");
  const after = fs.readdirSync(DIR).filter((f) => /^\d{4}-W\d{2}\.json$/.test(f));
  for (const f of existing)
    if (!after.includes(f)) throw new Error("REFUSING: an existing week file disappeared: " + f);
}

console.log(
  "week-archive " + (DRY ? "(dry-run) " : "") + (isNew ? "wrote new " : "refreshed ") +
  "data/archive/" + id + ".json — research " + snapshot.counts.research +
  ", industry " + snapshot.counts.industry + ", jobs " + snapshot.counts.jobs +
  ", postdoc " + snapshot.counts.postdoc + ", grants " + snapshot.counts.grants
);
console.log("  weeks on file: " + (existing.length + (isNew && !DRY ? 1 : 0)));
