# Weekly Battery Dashboard Update

You are updating the BDPL (DGIST Battery Design & Processing Lab) weekly battery-research
dashboard. The entire dashboard is a single self-contained file: `index.html` in this repo
root. There are no other assets — the logo is embedded base64, there is no build step, and
GitHub Pages serves the file directly at https://bdpl250101-collab.github.io/

Work through this document top to bottom. Do not skip the verification section.

---

## 1. Scope

**Cover everything since the previous run.** Determine the last run's date with
`git log -1 --format=%cd --date=short -- index.html`, and use the window
`[last run date, today]`. If that span is under 7 days, widen it to 7 days so a
quick-succession run still has material. State the actual window in `calloutR` and in the
`sub` date-range strings.

This removes carry-forward ambiguity entirely: nothing is inherited from the old file,
every item is re-fetched and re-verified each run, and no publication can slip through a
gap between runs.

Search the web — do not rely on memory or on what is already in the file. Anything you
cannot reach and read is not evidence.

### Research — five buckets

The `cat` field must be **exactly one of these five Korean strings**. The category filter
chips, the badge colors (`CATCLR`) and Chart 1 all key off these literals — any other value
renders a broken, uncolored badge and is invisible to the filters.

| `cat` | Scope |
|---|---|
| `소재` | Cathode, anode, electrolyte, solid electrolyte, separator; interfacial reactions; new characterization methods |
| `전극` | Dry electrodes; electrode architecture; thick / high-energy electrodes; binders and conductive additives |
| `셀` | Cell design; all-solid-state cells; pouch and cylindrical formats; safety; lifetime; fast charging |
| `공정` | Manufacturing; scale-up; coating / calendering / drying; recycling |
| `저널` | Special issues; reviews; perspectives; otherwise-notable papers |

### How to gather research items

Do **not** try to open journal websites directly — they block automated access. Nature
redirects site-wide to `idp.nature.com/authorize`, Wiley returns 402, RSC and ChemRxiv
return 403, and ACS and Cell are closed too. Use the Crossref API, which returns verified
publication dates, DOIs, titles, authors and often abstracts for every publisher on the
list.

**Query pattern** — one call per journal:

```
https://api.crossref.org/journals/{ISSN}/works
  ?filter=from-pub-date:{START},until-pub-date:{END}
  &rows=1000
  &select=DOI,title,published,container-title,author,abstract,type
  &mailto=bdpl250101@gmail.com
```

`{START}`/`{END}` are the window bounds in `YYYY-MM-DD`. Always include `mailto` — it puts
you in Crossref's polite pool and avoids the rate limiting that hits anonymous callers.

> ⚠️ **Never let `rows` truncate silently.** `rows=60` looks sufficient and is not: in the
> 2026-08-05 run it silently cut Energy Storage Materials from 144 in-window records to 60,
> Small from 197, and Electrochimica Acta from 133 — a third of the candidate pool vanished
> with no error. `rows=1000` is Crossref's maximum.
>
> **Required check:** for every journal, read `message.total-results` from the response and
> compare it with the number of items you actually received. If `total-results >= 1000`, the
> cap has been hit and results *are* truncated — log a WARNING naming the journal and its
> total, and narrow the window (or paginate with `offset`/cursor) before continuing. Report
> any such warning in `calloutR`; never present a truncated sweep as complete.

**Journal ISSNs.** Before the first use each run, sanity-check each ISSN with
`https://api.crossref.org/journals/{ISSN}` and confirm the returned `title` matches the
journal you expect. Drop any that don't match and report which ones failed — do not
silently skip a journal.

| Journal | ISSN | Journal | ISSN |
|---|---|---|---|
| Nature | 1476-4687 | Journal of Power Sources | 0378-7753 |
| Science | 1095-9203 | J. Electrochemical Society | 1945-7111 |
| Nature Energy | 2058-7546 | Electrochimica Acta | 0013-4686 |
| Nature Materials | 1476-4660 | Journal of Energy Chemistry | 2095-4956 |
| Nature Nanotechnology | 1748-3395 | Energy Storage Materials | 2405-8297 |
| Joule | 2542-4351 | Batteries & Supercaps | 2566-6223 |
| Advanced Materials | 1521-4095 | Chemistry of Materials | 1520-5002 |
| Advanced Energy Materials | 1614-6840 | Small | 1613-6829 |
| Energy & Environmental Science | 1754-5706 | Nano Energy | 2211-2855 |
| JACS | 1520-5126 | ACS Energy Letters | 2380-8195 |
| Angewandte Chemie Int. Ed. | 1521-3773 | ACS Nano | 1936-086X |

**Filtering what comes back.** Crossref returns everything the journal published, most of
which is not battery work. Keep an item only if its title or abstract is clearly about
secondary batteries — Li-ion, Li-metal, solid-state, Na-ion, electrodes, electrolytes,
separators, cells, battery manufacturing or recycling. Discard solar, fuel cell, catalysis,
supercapacitor and unrelated electrochemistry. Also discard by `type`: drop
`journal-issue`, `component`, and anything whose title begins with "Correction to",
"Erratum", "Retraction" or "Editorial Expression of Concern".

**Preprints.** Keep the arXiv API sweep — it works and is the fastest source:

```
http://export.arxiv.org/api/query?search_query=all:battery+OR+all:lithium-ion
  &sortBy=submittedDate&sortOrder=descending&max_results=60
```

Check ChemRxiv via Crossref instead of its blocked website: ISSN-less, so query
`https://api.crossref.org/prefixes/10.26434/works?filter=from-posted-date:{START}&rows=1000`
— the same `total-results` truncation check applies.

**Affiliations via OpenAlex.** Crossref's single-work endpoint does not return authors when
`select` is used, so take affiliations from OpenAlex instead. For each *selected* DOI:

```
https://api.openalex.org/works/doi:{DOI}
  ?select=authorships,publication_date
  &mailto=bdpl250101@gmail.com
```

Put the first author's institution into `org` / `org_en` — e.g. `org:"Yoo 외 (한양대)"`,
`org_en:"Yoo et al. (Hanyang Univ.)"`. Verified: `10.1016/j.ensm.2026.105331` returns
Hyundong Yoo, Hanyang University. If OpenAlex has no record or no institution, fall back to
`"Surname 외"` / `"Surname et al."` without a parenthetical — never guess an affiliation.
OpenAlex has no abstracts for Elsevier either, so this does not remove the title-derived
caveat below.

**Writing descriptions.** Crossref abstracts (when present) carry enough to write both
`desc` and `desc_en` accurately. When an abstract is missing, try one WebFetch of the DOI
resolver `https://doi.org/{DOI}`; if that is blocked too, write the description from the
title and author affiliations only, and set `ver:true` anyway — the Crossref publication
date is authoritative regardless of whether you could read the page.

Elsevier titles (Energy Storage Materials, Joule, Nano Energy, J. Power Sources, J. Energy
Chemistry) deposit **no** abstracts to Crossref and are blocked at `linkinghub.elsevier.com`,
so their descriptions will routinely be title-derived. State that **once** in `calloutR` —
do not repeat a provenance parenthetical on each card, which is visual noise when it lands
on two-thirds of them.

**Aim for coverage, not volume.** Target roughly 3–8 items per `cat` bucket. If a bucket
truly has nothing after querying every journal, say so in `calloutR` and leave it empty —
but an empty bucket should now be rare, and three empty buckets means something went wrong
with the queries, not with the field.

**Cap each journal at 4 items per run.** No single journal may supply more than four
research items. This is not cosmetic: journals batch-stamp an entire issue to one date, so
raw counts measure publishing cadence, not research activity. In the 2026-08-05 run Energy
Storage Materials stamped 144 records to 2026-08-01 and would have supplied 17 of 30 items.
When a journal exceeds the cap, keep its strongest items and backfill from the next-best
candidates **in the affected buckets**, preferring journals not yet represented. Aim for at
least 10 distinct journals across the set.

### Industry — two regions

The `region` field must be **exactly** `국내` or `해외` — the region filter and `REGCLR`
key off these literals.

| `region` | Watch list |
|---|---|
| `국내` | LG에너지솔루션, 삼성SDI, SK온, 에코프로비엠, 포스코퓨처엠, 엘앤에프, 롯데에너지머티리얼즈 — plus Korean policy, subsidy and capacity news |
| `해외` | CATL, BYD, Panasonic, Northvolt, QuantumScape, Tesla, StoreDot, Toyota, Umicore, BASF — plus US IRA / tariffs and EU battery regulation |

The `type` field must be **exactly one of**:

`실적` · `신기술` · `전망` · `판매` · `공장/공정` · `소재사` · `정책`

> ⚠️ Note the **forward slash** in `공장/공정`. `TYPELBL` (index.html:338) maps that exact
> string; `공장·공정` with a middle dot will render untranslated in English mode.

---

## 2. The data schema — write against this exactly

### `const research = [ … ]` (index.html, ~line 343)

```js
{cat:"소재",sub:"고체전해질",title:"…",title_en:"…",org:"Kim 외",org_en:"Kim et al.",
 journal:"Nature Energy",date:"2026-07-31",ver:true,link:"https://…",
 desc:"한국어 설명.",
 desc_en:"English description."},
```

| Field | Required | Rules |
|---|---|---|
| `cat` | **yes** | one of the five Korean literals above |
| `sub` | **yes** | short free-text sub-tag, e.g. `"건식 전극"`, `"Li금속 SEI"`. See the `SUBLBL` rule below. |
| `title` | **yes** | the paper title, normally left in English |
| `title_en` | optional | only when `title` is Korean; falls back to `title` |
| `org` | **yes** | authors or institution; use `"—"` if genuinely unknown |
| `org_en` | optional | English form, e.g. `"Kim et al."`; falls back to `org` |
| `journal` | **yes** | never translated |
| `date` | **yes** | `"2026-07-31"` when confirmed, `"2026-07"` or `"2026"` when only partly known |
| `ver` | **yes** | boolean — see the `ver` rule below |
| `link` | **yes** | real, resolving URL to the paper |
| `desc` | **yes** | Korean, 1–2 sentences |
| `desc_en` | **yes** | English, 1–2 sentences |

### `const industry = [ … ]` (index.html, ~line 418)

```js
{region:"국내",type:"실적",company:"LG에너지솔루션",date:"2026-07-30",ver:true,
 link:"https://…",
 desc:"한국어 설명.",
 desc_en:"English description."},
```

| Field | Required | Rules |
|---|---|---|
| `region` | **yes** | `국내` or `해외` |
| `type` | **yes** | one of the seven type literals above |
| `company` | **yes** | Korean name for domestic firms; Latin name for foreign ones. **There is no `company_en` field** — English names come from the `COMPANY_EN` map. |
| `date` | **yes** | same format rules as research |
| `ver` | **yes** | boolean |
| `link` | **yes** | real, resolving URL to the article |
| `desc` | **yes** | Korean, 1–2 sentences |
| `desc_en` | **yes** | English, 1–2 sentences |

### The two lookup maps — keep them in sync

Both maps fall back to the raw Korean string on a miss, so a forgotten entry **fails
silently**: the English view simply shows Korean text. Nothing errors, nothing warns.

- **`COMPANY_EN`** (index.html:340) — adding a new Korean company name to `industry`
  means adding `"한국어사명":"English Name"` here. It feeds the card headline, the Chart 2
  bar labels, *and* the industry search index — an unmapped company cannot be found by
  typing its English name.
- **`SUBLBL`** (index.html:339) — adding a new research `sub` tag means adding
  `"새태그":"English tag"` here, unless the tag is already English.

---

## 3. What to change — and nothing else

1. The `research` array — **full replacement**.
2. The `industry` array — **full replacement**.
   > ⚠️ The `archive` array is **not** in this list and is **never** replaced. It is
   > append-only — see section 4. Rewriting it destroys a year of accumulated history.
3. New entries in `COMPANY_EN` and `SUBLBL` for any new Korean company name or `sub` tag.
4. The date range: `I18N.ko.sub` and `I18N.en.sub`.
5. The three KPI tiles, both languages:
   - KPI 1 — `k1l`, `k1v`, `k1n` in both `ko` and `en` (all in I18N).
   - KPI 2 — `k2l`, `k2n` in both languages, **plus** its value, which is hardcoded in
     the body markup at **index.html:197**: `<div class="val">+42<small>%</small></div>`
   - KPI 3 — `k3l`, `k3n` in both languages, **plus** its value at **index.html:203**:
     `<div class="val">22.6<small> mAh/cm²</small></div>`
   - For KPI 2 and 3, change **only the number and the unit text inside those two lines**.
     Never alter the tags, the `class` attributes, or the surrounding structure.
   - **KPI 4 is computed** from `research.length + industry.length` — leave it alone.
6. The five key themes: `I18N.ko.themes` and `I18N.en.themes`. Keep exactly five
   `[title, subtitle]` pairs — the layout is built for five.
7. The footer generation date: `I18N.ko.footNote` and `I18N.en.footNote`.
8. The honesty callouts `calloutR` / `calloutI` and the source list `footSrc`, both
   languages — these describe *this week's* data, so they must match what you actually found.
9. Chart 2's earnings figures at **index.html:562-564**, but **only when Korean makers have
   reported new quarterly results**. Edit only the company keys and the numeric `v:` values
   inside that `hbar('chartEarnings', …)` call, and update the `cc2c` caption in both
   languages to name the right quarter. Do not restructure the call. In a normal week
   there are no new results and this stays untouched.

### Do NOT touch

- **Any existing entry in the `archive` array.** You may only prepend new ones. See section 4.
- Any CSS, or anything in the `<style>` block.
- The page layout or HTML structure (beyond the two KPI value texts named above).
- The embedded base64 logo.
- The script logic — the render functions, event handlers, filters, `CATCLR`, `REGCLR`,
  `CATLBL`, `REGLBL`, `TYPELBL`.
- The brand colors: amber `#ffc000` on black `#0e0e0e`.

---

## 4. The archive array is append-only — never replace it

`research` and `industry` are replaced wholesale every run. **`archive` is not.** It holds the
year's accumulated top-tier papers, and a run that rewrites it destroys months of history that
cannot be recovered from the current window.

### Scope — 11 journals only

Narrower than the weekly sweep on purpose: a paper being here should mean something.

| Journal | ISSN | Journal | ISSN |
|---|---|---|---|
| Nature | 1476-4687 | Nature Catalysis | 2520-1158 |
| Science | 1095-9203 | Nature Sustainability | 2398-9629 |
| Nature Energy | 2058-7546 | Nature Reviews Materials | 2058-8437 |
| Nature Materials | 1476-4660 | Science Advances | 2375-2548 |
| Nature Nanotechnology | 1748-3395 | Joule | 2542-4351 |
| Nature Chemistry | 1755-4349 | | |

All eleven were verified against `api.crossref.org/journals/{ISSN}` on 2026-08-06 and all
returned the expected title. Re-check them anyway, as section 1 requires.

**Nature Communications (2041-1723) is deliberately excluded** — its battery output alone would
outnumber every other journal here combined. If you ever want it, add it as a visually separate
tier rather than mixing it in.

### The schema — `const archive = [ … ]` (index.html, just after `industry`)

```js
{doi:"10.1038/s41586-026-10862-4",
 title:"Avalanche-like intercalation and intraparticle correlations in graphite",
 journal:"Nature", date:"2026-07-29", cat:"셀",
 org:"Han 외", org_en:"Han et al.", nv:false,
 link:"https://doi.org/10.1038/s41586-026-10862-4",
 desc:"한국어 한 문장.",
 desc_en:"One English sentence."},
```

| Field | Rules |
|---|---|
| `doi` | **the dedup key** — never add a DOI already present |
| `cat` | the same five Korean literals as `research`; reuses `CATCLR` for the row colour |
| `date` | `YYYY-MM-DD`, or `YYYY-MM` when the publisher deposits no day (all of Joule). The renderer prints a dash in the day column for month-only dates. |
| `org` / `org_en` | first author's surname. `"Kim 외"` / `"Kim et al."` for multi-author work, but a **bare surname with no 외 / et al.** for a single-author piece — most News & Views are single-author, and "Bianchini et al." is simply wrong. `"—"` when Crossref lists no author. |
| `nv` | boolean, never omitted — see the detection rules below |
| `desc` / `desc_en` | **one sentence each**, tighter than the weekly cards — this list runs to hundreds of rows over a year and long summaries make it unscannable |

### Each run

1. Read the existing `const archive = [...]` out of `index.html` and **keep every entry**.
2. Try `https://www.nature.com/subjects/batteries` and read the **Featured** section. Every item
   there is editor-curated — take it, mark `nv:true`, and if the piece names the paper it
   comments on, record that paper too. **If the fetch fails, log the failure explicitly in
   `.weekly-update.log` and continue with step 3** rather than silently skipping curation.
   > As of the 2026-08-06 seed this fetch **does not work**: nature.com returns HTTP 303 to
   > `idp.nature.com/authorize`, confirmed with both WebFetch and curl with a browser
   > User-Agent. Try it anyway each run — but expect to fall back.
3. Query Crossref for the window across the 11 archive journals only, with the same `rows=1000`
   and `total-results` truncation check section 1 requires.
4. Keep the battery-relevant results, applying the same filtering rules as the research array.
   Two extra scope calls the seed settled, worth keeping consistent:
   - **In scope:** recycling and second-life of spent cells; battery system, safety, lifetime
     and diagnostics work; metal-CO2, metal-O2, flow, structural and aqueous batteries.
   - **Out of scope:** upstream mineral extraction and refining (brine, hardrock, primary
     mining separation); fuel cells, electrolysers, CO2 capture, supercapacitors, dielectric
     capacitors, thermal "batteries"; primary (non-rechargeable) cells; "battery-free" devices;
     and — the single biggest source of false positives — **neuroscience papers about neuronal
     dendrites**, which any keyword sweep on "dendrite" will drag in.
5. Set `nv:true` on front matter, using every signal available:
   - a `page` field spanning **≤ 3 pages** in a Nature-family journal;
   - the `10.1038/d41586-` DOI prefix (Nature-brand news and comment);
   - Nature-family **and** no `page` **and** no abstract **and** ≤ 2 authors — this catches
     online-first News & Views, which Crossref deposits with no page range at all. In the seed
     this rule recovered exactly the two Nature Nanotechnology News & Views pieces that the
     Featured-section scrape had independently found, which is why it is trusted here.
   - Do **not** reach for OpenAlex to settle this: it reports plain `type: "article"` for known
     News & Views pieces, indistinguishable from research papers. It was tested and is useless
     for this purpose.
   - Note Elsevier article numbers (Joule's `page: "102585"`) are **not** page ranges. Never
     apply the page-span rule to them.
6. **Drop any whose `doi` already appears in the archive** — the DOI is the dedup key. Note it
   will not catch a publisher depositing one paper under two DOIs; the seed found one such pair
   in Joule and kept the earlier.
7. Prepend what remains, newest first.
8. **Never delete, never reorder existing entries, never rewrite their text.**

There is no per-journal cap here and no per-run cap. A quiet week adds nothing; a heavy week
adds a dozen. Both are correct.

Keep `calloutA` honest in both languages: if the nature.com curation fetch failed, the callout
must say the ★ marks were inferred from Crossref alone and are under-inclusive.

---

## 5. Quality rules

**Never invent anything.** Every item must come from a page you actually opened and read
this run. Every `link` must be a real URL that resolves to the item it claims to be. If you
cannot verify something, leave it out — an omission is honest, a fabrication is not.

**Withdrawn and retracted work.** Before including any preprint, check whether a later
version is withdrawn — arXiv marks this in the abstract page comments ("withdrawn by the
author"). For journal articles, skip Crossref items of `type: retraction` and any whose
title starts with "Retraction". A withdrawn paper is never included, even if in-window.

**The `ver` flag is a factual claim, not a formality.** Crossref publication dates are
authoritative, so items sourced through it are `ver:true` when the date falls inside the
window. Reserve `ver:false` for items where the date itself is uncertain — typically an
arXiv preprint with no journal DOI, or a news-sourced item you could only place to a month.
Never carry a `ver:true` forward from a previous run without re-confirming the date this
run; with Crossref that is a single cheap lookup per DOI.

**Say what the dates mean.** A Crossref publication date is the **issue-assignment** date,
which can post-date online-first availability by weeks or months — OpenAlex records
`10.1016/j.ensm.2026.105331` as 2026-06-24 where Crossref gives 2026-08-01. That is why the
window is honest but not equivalent to "first appeared this week". State this explicitly in
`calloutR`, in both languages, every run.

**Both descriptions, every item.** `desc` (Korean) and `desc_en` (English) are both
mandatory on every research and industry entry. A missing one renders as `undefined` in
that language — it breaks the KO/EN toggle. This is the single most common way to break
this dashboard. Check it explicitly before committing.

**A quiet week is a fine outcome.** If the week genuinely produced little, publish fewer
items and say so plainly in `calloutR` / `calloutI`. Do not pad the arrays with stale
material, marginal items, or anything recycled from last week's version to hit a number.

**Watch the string literals.** Descriptions go into single-quoted or double-quoted JS
strings that are then interpolated into template literals. A stray `'`, `"`, backtick or
`$` in a title or description will break the script and blank the entire page. Prefer
typographic quotes (`'` `'` `"` `"`) inside description text, and never paste a raw
backtick.

---

## 6. Verify before committing

Run all five checks. If any fails, fix it and re-run — do not commit a failing file.

```bash
# 1. Syntax — extract the <script> block and parse it with node.
#    (The extracted file references `document`, but node --check only parses; it never runs.)
#    index.html has CRLF line endings, hence the tr.
tr -d '\r' < index.html | sed -n '/^<script>$/,/^<\/script>$/p' | sed '1d;$d' > /tmp/check.js
node --check /tmp/check.js && echo "SYNTAX OK"
```

```bash
# 2. Neither array is empty, and the counts are what you expect.
node -e '
const fs=require("fs"),h=fs.readFileSync("index.html","utf8");
const grab=n=>{const s=h.indexOf("const "+n+" = [");const e=h.indexOf("\n];",s);
  return eval(h.slice(s+("const "+n+" = ").length, e+2));};
const r=grab("research"), i=grab("industry");
if(!r.length) throw new Error("research array is EMPTY");
if(!i.length) throw new Error("industry array is EMPTY");
console.log("research:",r.length,"industry:",i.length);
'
```

```bash
# 3. Every item has desc, desc_en and link.
node -e '
const fs=require("fs"),h=fs.readFileSync("index.html","utf8");
const grab=n=>{const s=h.indexOf("const "+n+" = [");const e=h.indexOf("\n];",s);
  return eval(h.slice(s+("const "+n+" = ").length, e+2));};
let bad=0;
for(const [name,arr] of [["research",grab("research")],["industry",grab("industry")]])
  arr.forEach((x,n)=>{
    for(const f of ["desc","desc_en","link"])
      if(!x[f]||!String(x[f]).trim()){console.error(`${name}[${n}] missing ${f}:`,x.title||x.company);bad++;}
  });
if(bad) throw new Error(bad+" field(s) missing");
console.log("ALL ITEMS COMPLETE");
'
```

이 블록은 절대 fail-open으로 되돌리지 말 것 — 읽기 실패는 통과가 아니라 중단이다.

```bash
# 4. THE ARCHIVE GATE. The archive must never shrink and must never gain a duplicate DOI.
#    This is the check that does the real work — it fails loudly if a run dropped entries.
node -e '
const fs=require("fs"),cp=require("child_process");
const grab=(h,n)=>{const s=h.indexOf("const "+n+" = [");if(s<0)return[];
  const e=h.indexOf("\n];",s);if(e<0)return[];
  return eval(h.slice(s+("const "+n+" = ").length,e+2));};
const now=grab(fs.readFileSync("index.html","utf8"),"archive");
// Read HEAD strictly. A failed or corrupt read must ABORT, never fall through to an
// empty `old`, which would make every check below pass trivially and silently disable
// the gate. Distinguish "HEAD genuinely has no archive" from "could not read HEAD".
let old;
try {
  const head = cp.execSync("git show HEAD:index.html", {encoding:"utf8", maxBuffer:1e8});
  if (!head.startsWith("<!DOCTYPE html>")) throw new Error("git show returned corrupt content");
  old = head.includes("const archive = [") ? grab(head, "archive") : [];
} catch (e) {
  throw new Error("ARCHIVE GATE FAILED TO READ HEAD: " + e.message + " — refusing to proceed");
}
if(now.length < old.length)
  throw new Error("ARCHIVE SHRANK: "+old.length+" -> "+now.length+" — entries were deleted");
const nowDois=new Set(now.map(x=>x.doi));
const lost=old.map(x=>x.doi).filter(d=>!nowDois.has(d));
if(lost.length) throw new Error("ARCHIVE LOST ENTRIES: "+lost.join(", "));
const seen=new Set(),dup=[];
now.forEach(x=>seen.has(x.doi)?dup.push(x.doi):seen.add(x.doi));
if(dup.length) throw new Error("DUPLICATE DOIs: "+dup.join(", "));
const bad=[];
now.forEach((x,i)=>{
  for(const f of ["doi","title","journal","date","cat","org","org_en","link","desc","desc_en"])
    if(!x[f]||!String(x[f]).trim()) bad.push("archive["+i+"] missing "+f);
  if(typeof x.nv!=="boolean") bad.push("archive["+i+"] nv is not a boolean");
  if(!["소재","전극","셀","공정","저널"].includes(x.cat)) bad.push("archive["+i+"] bad cat: "+x.cat);
  if(!/^\d{4}-\d{2}(-\d{2})?$/.test(x.date)) bad.push("archive["+i+"] bad date: "+x.date);
  if(x.link!=="https://doi.org/"+x.doi) bad.push("archive["+i+"] link does not match doi");
});
if(bad.length) throw new Error(bad.join("\n"));
const sorted=now.every((x,i)=>i===0||now[i-1].date>=x.date);
if(!sorted) throw new Error("ARCHIVE NOT SORTED newest-first");
console.log("archive OK: "+old.length+" -> "+now.length+" (+"+(now.length-old.length)+"), no dups, no losses");
'
```

5. **Read the diff** — `git diff --stat` then `git diff`. Confirm the only changed regions
   are the ones section 3 permits. If CSS, the base64 logo, or a render function shows up
   in the diff, you changed something you should not have. Revert it.
   For the archive specifically, `git diff index.html | grep '^-.*doi:'` must print **nothing** —
   any removed `doi:` line means an existing entry was deleted or rewritten.

---

## 7. Finish

```bash
git add index.html weekly-prompt.md
git commit -m "chore: weekly dashboard update (YYYY-MM-DD)"
git push
```

Substitute today's real date for `YYYY-MM-DD`. If `SUBLBL` / `COMPANY_EN` / the KPI values
changed, they are inside `index.html` and are already staged.

Then print, as the final output:

- The item counts, in the form `N research / M industry`.
- A **3-line headline summary** — one line each for the biggest research story, the biggest
  industry story, and the week's overall through-line.
