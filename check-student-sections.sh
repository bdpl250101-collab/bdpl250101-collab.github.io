#!/usr/bin/env bash
#
# Structural guard for the three student sections — jobs / postdoc / grants.
#
# These sections are NOT part of the weekly Crossref sweep. The sweep replaces the
# `research` and `industry` arrays wholesale, and a run that also rewrites the page
# shell would silently delete three tabs the sweep knows nothing about. This script
# is the tripwire: it asserts every piece of the three sections is still present.
#
# Called by run-weekly.sh after the Claude run, and by weekly-prompt.md §6 check 5.
# Exit 0 = intact, exit 1 = something was lost.
#
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

HTML=$(tr -d '\r' < index.html)
fail=0
miss() { echo "  MISSING: $1"; fail=$((fail + 1)); }

echo "--- student-section guard (jobs / postdoc / grants) ---"

# 1. The three tab buttons, their panels, and the render wiring in index.html.
for id in tabJ tabP tabG; do
  grep -q "id=\"$id\"" <<< "$HTML" || miss "tab button #$id"
done
for t in jobs postdoc grants; do
  grep -q "data-tab=\"$t\""   <<< "$HTML" || miss "tab trigger data-tab=\"$t\""
  grep -q "id=\"panel-$t\""   <<< "$HTML" || miss "panel #panel-$t"
done
for el in noticeJ jobsFilters jobsCards portalsJ \
          noticeP postdocFilters postdocCards portalsP \
          noticeG grantsFilters grantsCards portalsG; do
  grep -q "id=\"$el\"" <<< "$HTML" || miss "element #$el"
done
for fn in renderJobs renderPostdoc renderGrants loadStudentData \
          studentNotice studentFilters studentCards studentPortals; do
  grep -q "function $fn(" <<< "$HTML" || miss "render function $fn()"
done
grep -q "const STUDENT=" <<< "$HTML" || miss "const STUDENT state object"
# renderAll must actually call the three renderers, or the tabs stay blank forever.
for fn in renderJobs renderPostdoc renderGrants; do
  grep -q "function renderAll().*$fn()" <<< "$HTML" || miss "renderAll() no longer calls $fn()"
done

# 2. Both language tables must carry the three tab labels. A tab whose label is
#    dropped from one language renders as an empty button in that language only.
for key in tabJ tabP tabG; do
  # One `tabJ:"..."` definition in I18N.ko and one in I18N.en.
  n=$(grep -o "$key:\"" <<< "$HTML" | wc -l)
  [ "$n" -ge 2 ] || miss "I18N label $key defined in only $n of the 2 language tables"
  # And applyStatic() must still push it into the button.
  grep -q "set('$key',t.$key)" <<< "$HTML" || miss "applyStatic() no longer sets $key"
done

# 3. The data files the three sections fetch at runtime.
for f in data/jobs.json data/postdoc.json data/grants.json \
         data/postdoc_watchlist.json data/pi_archive.json; do
  [ -s "$f" ] || { miss "data file $f (absent or empty)"; continue; }
  node -e "JSON.parse(require('fs').readFileSync('$f','utf8'))" 2>/dev/null \
    || miss "data file $f (invalid JSON)"
done

# 4. Every item in the three feeds must be complete in both languages. This is the
#    same rule §6 check 3 applies to research/industry: a missing _en field renders
#    as an empty string in the English view, which reads as a broken card.
node -e '
const fs=require("fs");
let bad=[];
for(const f of ["jobs","postdoc","grants"]){
  let d;
  try{ d=JSON.parse(fs.readFileSync("data/"+f+".json","utf8")); }catch(e){
    bad.push(f+".json unreadable: "+e.message); continue; }
  if(!d.updated) bad.push(f+".json has no `updated` (last-checked) date");
  for(const k of ["notice","context","portals_title"])
    if(!d[k]||!d[k].ko||!d[k].en) bad.push(f+".json "+k+" needs both ko and en");
  (d.portals||[]).forEach((p,i)=>{
    if(!/^https:\/\//.test(p.url||"")) bad.push(f+" portal["+i+"] url is not https: "+p.url);
    if(!p.name||!p.name_en) bad.push(f+" portal["+i+"] needs name and name_en");
  });
  if(!(d.items||[]).length) bad.push(f+".json has no items");
  (d.items||[]).forEach((x,i)=>{
    for(const k of ["group","tag","title","meta","deadline","desc"])
      if(!x[k]||!String(x[k]).trim()) bad.push(f+"["+i+"] missing "+k);
    for(const k of ["group","tag","title","meta","deadline","desc"])
      if(!x[k+"_en"]||!String(x[k+"_en"]).trim()) bad.push(f+"["+i+"] missing "+k+"_en");
    if(typeof x.ok!=="boolean") bad.push(f+"["+i+"] ok is not a boolean");
    // link may be null — an expired posting with no replacement URL. It may not,
    // however, be a non-https string.
    if(x.link!==null&&x.link!==undefined&&!/^https:\/\//.test(x.link))
      bad.push(f+"["+i+"] link is neither null nor https: "+x.link);
  });
}
if(bad.length){ bad.forEach(b=>console.log("  INCOMPLETE: "+b)); process.exit(1); }
' || fail=$((fail + 1))

if [ "$fail" -ne 0 ]; then
  cat <<'MSG'

STUDENT SECTIONS DAMAGED — refusing to call this run clean.
The weekly sweep must never touch the jobs / postdoc / grants tabs or data/*.json.
Recover the lost parts before pushing:
    git diff index.html data/          # see what went
    git checkout HEAD -- index.html    # or restore from the last good commit
See weekly-prompt.md §4b for the preservation rule.
MSG
  exit 1
fi

echo "student sections intact: 3 tabs, 3 panels, 5 data files, all items complete in ko+en"
exit 0
