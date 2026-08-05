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

- Any CSS, or anything in the `<style>` block.
- The page layout or HTML structure (beyond the two KPI value texts named above).
- The embedded base64 logo.
- The script logic — the render functions, event handlers, filters, `CATCLR`, `REGCLR`,
  `CATLBL`, `REGLBL`, `TYPELBL`.
- The brand colors: amber `#ffc000` on black `#0e0e0e`.

---

## 4. Quality rules

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

## 5. Verify before committing

Run all four checks. If any fails, fix it and re-run — do not commit a failing file.

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

4. **Read the diff** — `git diff --stat` then `git diff`. Confirm the only changed regions
   are the ones section 3 permits. If CSS, the base64 logo, or a render function shows up
   in the diff, you changed something you should not have. Revert it.

---

## 6. Finish

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
