# Daily Battery Dashboard Update

You are updating the BDPL (DGIST Battery Design & Processing Lab) battery-research
dashboard, `index.html` in this repo root, served by GitHub Pages at
https://bdpl250101-collab.github.io/

The dashboard used to be rebuilt once a week. **It is now updated every day at 06:00 KST**
and shows a **rolling 7-day window**: every research / industry / science item that was
*added* in the last seven days. Each run adds that day's new items; a script takes items
off again once they are a week old. Nothing is rebuilt from scratch.

The run parameters are in the header at the very top of this input — or, when this runs
as a Claude Code Desktop scheduled task (`desktop-task-prompt.md`), in the block that
`./run-weekly.sh --phase pre` printed:

| Parameter | Meaning |
|---|---|
| `RUN_MODE` | `daily` (Tue–Sun) or `weekly` (Monday). Weekly does everything daily does, plus section D7. |
| `TODAY` | the run date, KST. Every item you add gets `added:"TODAY"`. |
| `PREV_RUN_DATE` | the previous run's date. |
| `SEARCH_WINDOW` | `START .. TODAY` — the period to search for new material. |

Work through this document top to bottom. Do not skip section D9.

---

## D0. `weekly-prompt.md` is the rulebook — read it first

Everything about *what* a good item is, and *how the data is shaped*, still lives in
`weekly-prompt.md`. **Read it before you start.** This file only changes *when* and *how
much*. Concretely:

| `weekly-prompt.md` section | In a daily run |
|---|---|
| §1 Scope — the five research buckets, *How to gather research items* (Crossref, ISSNs, `rows=1000` and the `total-results` truncation check, filtering, preprints, OpenAlex affiliations, descriptions, per-journal cap), Industry, Science | **Applies**, except the window paragraph at the top of §1 and the per-run numbers — section D2 replaces those. |
| §2 Data schema, the lookup maps | **Applies in full**, plus the new `added` field (D3). |
| §3 What to change | **Replaced** by section D5. In particular `research`, `industry` and `science` are **no longer replaced wholesale.** |
| §4 Archive | **Applies**, with the window from D2 and the insertion rule in D4. |
| §4b Student sections — what must never change | **Applies in full.** |
| §5 Quality rules | **Applies in full**, with one clarification in D3 about `ver`. |
| §6 Verification | **Applies** — section D9 lists exactly which checks to run. |
| §7 Finish | **Replaced** by section D10. |
| §8 Student sections refresh | **Weekly mode only** (Monday). Daily mode does not touch `data/`. |
| §9 Briefing tab | **Applies**: leave it alone unless the run explicitly asks for a briefing. |

Where this file and `weekly-prompt.md` disagree, this file wins for a daily run.

---

## D1. What has already happened before you started

`run-weekly.sh` ran `scripts/daily-roll.js` just before your session. It has:

- set `const RUN_DATE = "TODAY";` in index.html — **script-owned, never edit it**;
- removed every research / industry / science item whose `added` date is older than
  `TODAY − 6 days`. Items from before the daily cadence have no `added`; their `date`
  stood in for it. If an array would have been emptied it kept the newest three and
  printed a WARNING — those carried items will be rolled off by the next run that adds
  enough new ones.

So the arrays you see are the **current 7-day window minus today**. Your job is today.

---

## D2. The search window — what "new today" means

Search **`SEARCH_WINDOW`** only. It starts at the previous run date, so there is one day
of overlap; deduplication (D3) absorbs it. If the pipeline missed days, the window is
already widened to cover them (capped at 14 days).

**Research — use the Crossref *registration* date, not the publication date.** In the
query pattern from §1, replace the `from-pub-date` / `until-pub-date` filter with:

```
filter=from-created-date:{START},until-created-date:{TODAY}
```

`created` is when the DOI was registered, which is close to when the paper first became
public. The publication date (`published`) is often a batch-stamped *issue* date weeks
later — that is the caveat `calloutR` has carried for months. For a daily feed the
registration date is the honest measure of "appeared since yesterday". Everything else
in §1 stands: `rows=1000`, the `total-results` truncation check, the ISSN sanity check,
the battery filter, the type filter. Additionally **drop any record whose `published`
date is more than 90 days before `TODAY`** — those are back-catalogue re-deposits, not
new work.

- The item's `date` field is still the Crossref `published` date, as §2 says.
- ChemRxiv: `from-created-date:{START}` on the `10.26434` prefix, same checks.
- arXiv: keep the §1 query; take only entries whose `published` (submitted) date falls
  in `SEARCH_WINDOW`.

**Industry and science** — news published in `SEARCH_WINDOW`, from the same sources and
watch lists as §1.

**Daily volume** — there is no target. Roughly what to expect on a normal day:

| Array | Typical new items per day | Per-run cap |
|---|---|---|
| `research` | 0–8 | **2 per journal** (the §1 cap of 4 was per week) |
| `industry` | 0–5 | — |
| `science` | 1–2 | keep the rolling total around 6–12 |

A day with nothing new is a correct outcome. You still do D5 items 2–4 so the page shows
it was checked today. Never pad, and never re-add anything to fill a quiet day.

---

## D3. Adding items

1. **Deduplicate before writing anything.** Skip a candidate when its DOI or link — or,
   for news, the same event from another outlet — already appears in:
   - the current `research` / `industry` / `science` arrays;
   - any `data/archive/daily/*.json` from the last 14 days, and the newest
     `data/archive/20??-W??.json`. These hold items that were on the page recently and
     have since rolled off; showing them again as "new today" would be false.
2. **Every new item gets `added:"TODAY"`**, placed right after `ver`. That field drives the
   amber *오늘 신규 / New today* badge, sorts the item to the top of its tab, and is what
   the roll script uses to retire it seven days later. Missing it is the one mistake that
   silently breaks the cadence: the item would be treated as old and dropped tomorrow by
   its publication date.
3. **Insert new items at the top of their array.** The page already puts today's items
   first, so the order inside the array only matters for the git diff — top keeps it
   readable.
4. **Do not touch existing items.** Their text, `ver`, `date` and `added` stay exactly as
   they are. They were verified on the day they were added; re-verifying the whole window
   every day is the cost the daily cadence exists to avoid. *This narrows §5's
   carry-forward rule:* that rule was about copying items from one edition into the next,
   and an item that stays inside its own 7-day window is not being carried forward. The
   one exception — you notice an existing item is factually wrong (bad link, wrong date,
   retracted) — fix or remove it and say so in your final summary.
5. All of §2 and §5 applies to the new item: both `desc` and `desc_en`, a real resolving
   `link`, a correct `ver`, the exact `cat` / `region` / `type` / `field` literals, and new
   entries in `COMPANY_EN` / `SUBLBL` when you introduce a name or tag.

```js
{cat:"셀",sub:"전고체",title:"…",org:"Kim 외 (KAIST)",org_en:"Kim et al. (KAIST)",
 journal:"Joule",date:"2026-10-02",ver:true,added:"2026-10-06",link:"https://doi.org/…",
 desc:"한국어 설명.",
 desc_en:"English description."},
```

---

## D4. The annual archive — daily, append-only

Do §4 every day, with two differences:

- query the 11 archive journals over `SEARCH_WINDOW` using `from-created-date` /
  `until-created-date`, the same as D2;
- **insert each new entry at its date-sorted position**, not simply at the top. With a
  registration-date window a paper can arrive today carrying a publication date older than
  the current first entry, and §6 check 4 fails the run if the archive is not sorted
  newest-first by `date`. Inserting does not reorder existing entries relative to each
  other, so the never-reorder rule still holds.

Archive entries do **not** get `added`; they never roll off. The DOI dedup in §4 step 6 is
what makes the one-day overlap harmless here.

The `nature.com/subjects/batteries` curation fetch (§4 step 2) is weekly-mode only — it
has failed every time it has been tried, and once a week is enough to notice if that
changes.

---

## D5. What to change — and nothing else

Every run, both languages (`I18N.ko` and `I18N.en`) wherever a string exists in both:

1. **New items** in `research`, `industry`, `science` (D3), and new `archive` entries (D4).
2. **`sub`** — the date line under the title. Format:
   - ko: `기준일 {TODAY} (최근 7일: {M/D}~{M/D}) · 매일 06:00 KST 갱신 · 연구 동향 & 업계 동향`
   - en: `As of {D Mon YYYY} (last 7 days: {D Mon}–{D Mon}) · updated daily 06:00 KST · Research & industry trends`
   The range is `TODAY − 6` to `TODAY`.
3. **`footNote`** — one or two sentences: today's date, the 7-day totals, how many of them
   are new today, and how many entries the archive gained today. Short. The old weekly
   footnotes ran to a paragraph; a daily one that long becomes noise.
4. **`calloutR` / `calloutI` / `calloutS` / `calloutA`** — keep them honest about the
   *current window*, and keep them short (aim for under ~600 characters each). Each must
   still state what §1 and §5 require: that research items are found by Crossref
   registration date within the 7-day window while the card shows the publication date;
   that Elsevier titles have title-derived descriptions; any truncation warning or failed
   ISSN; which sources were unreachable today; for the archive, whether the ★ marks were
   inferred from Crossref alone. Rewrite them rather than appending to them — they
   describe the window, not a log of every day.
5. **`footSrc`** — only if today's sources changed what it says.
6. **KPI tiles and the five themes** — leave them as they are, **unless** an item a tile
   or theme is about has rolled off the page, or `RUN_MODE` is `weekly` (then refresh all
   of them for the current 7-day window, per §3 items 5–6). KPI 2 and KPI 3 have their
   values hard-coded in the body markup (search for `<div class="val">` inside the second
   and third `.kpi` blocks — the line numbers in §3 are out of date); change only the
   number and unit text there. KPI 4 is computed; leave it alone.
7. **Chart 2 earnings** — only when a Korean maker reported new quarterly results, per
   §3 item 9.

### Do NOT touch

Everything in §3's *Do NOT touch* list, plus:

- `const RUN_DATE` — written by `scripts/daily-roll.js`;
- the `added` value of any existing item;
- `data/archive/` and `data/archive/daily/` — written by `scripts/week-archive.js`;
- in **daily** mode: `data/jobs.json`, `data/postdoc.json`, `data/grants.json`,
  `data/postdoc_watchlist.json` — they are refreshed on Mondays.

---

## D6. Budget

A daily run has **60 turns and 100 minutes**. That is plenty for one day of material and
not enough to re-sweep a week. If you are running short: finish and verify the items you
have, update the D5 strings, and commit. A smaller verified update beats an unfinished
one — the next run's window starts at today and will pick up what you did not reach.

---

## D7. Weekly mode only (`RUN_MODE: weekly`, Mondays)

In addition to everything above:

1. **Student sections** — do `weekly-prompt.md` §8 in full: jobs, postdoc, grants, the
   watchlist, link types, `updated` dates.
2. **KPI tiles and themes** — refresh all of them for the current 7-day window (D5 item 6).
3. **Archive curation** — try the nature.com Featured fetch (§4 step 2).

Weekly mode has 90 turns and 3 hours.

---

## D8. Quality rules — the short version

§5 in full applies. The ones a daily cadence makes more likely to go wrong:

- **Never invent anything.** A quiet day is a fine outcome.
- **Never re-add** something that was on the page in the last 14 days (D3.1).
- **`added` is always `TODAY`** on what you add, and never changes on what you did not.
- **String literals.** A stray `"`, backtick or `$` blanks the whole page. Use typographic
  quotes inside descriptions.

---

## D9. Verify before committing

Run these. If any fails, fix it and re-run — do not commit a failing file.

1. `weekly-prompt.md` §6 **check 1** (syntax).
2. `weekly-prompt.md` §6 **check 2** (no empty arrays).
3. `weekly-prompt.md` §6 **check 3** (desc / desc_en / link on every item).
4. **The rolling-window gate:**
   ```bash
   node scripts/daily-roll.js --check --date TODAY
   ```
   It fails on a malformed or future `added`, a duplicate research DOI, a duplicate
   science link added today, or a new item missing a required field, and it prints how
   many items were added today. Check that number against what you meant to add.
5. `weekly-prompt.md` §6 **check 4** (the archive gate — never shrinks, no duplicate DOI,
   sorted newest-first).
6. `weekly-prompt.md` §6 **check 5** (`./check-student-sections.sh`).
7. `weekly-prompt.md` §6 **check 6** (`node scripts/gen-seeds.js`) — weekly mode, or any
   run that touched `data/`.
8. **Read the diff** (`git diff --stat`, then `git diff`). In daily mode the only changed
   regions should be: the removed items from the roll, your new items, the D5 strings,
   any new `COMPANY_EN` / `SUBLBL` entries and archive insertions, and the `RUN_DATE` line.
   `git diff --stat -- data/` must print nothing in daily mode.
   `git diff index.html | grep '^-.*doi:'` must print nothing (archive entries never lose
   a line — the roll does not touch the archive).

---

## D10. Finish

```bash
git add index.html
git add data/        # weekly mode only — section 8 edits data/*.json
git commit -m "chore: daily dashboard update (TODAY)"     # weekly mode: "chore: weekly dashboard update (TODAY)"
```

**Commit, do not push.** `run-weekly.sh` pushes after its own gates pass (§7 explains why
the order matters). Never `git add -A`.

Then print, as the final output:

- `N research / M industry / K science in the 7-day window (today: +a / +b / +c)`
- `archive: +x today (total T)`
- `student sections: intact (3 tabs, 5 data files)` — or a loud warning.
- In weekly mode, one line on what §8 changed.
- A **2-line headline summary** of what was new today — or one line saying it was a quiet
  day and which sources were checked.
