#!/usr/bin/env bash
#
# Daily auto-update for the BDPL battery-research dashboard.
# (The file keeps its old name so the existing scheduled task keeps pointing at it.)
# Rolls the 7-day window, hands daily-prompt.md to Claude Code, and logs everything.
#
# Scheduled for EVERY DAY 06:00 KST (= 21:00 UTC the day before), via the Windows Task
# Scheduler task BDPL-WeeklyDashboard — setup-daily-task.ps1 switches its trigger from
# weekly to daily. Run it by hand any time to test:
#   ./run-weekly.sh
#
#   ./run-weekly.sh --no-push   collect, verify, commit locally — but do not push.
#                               Use it to exercise the whole path without publishing.
#                               (--dry-run is accepted as a synonym.)
#   ./run-weekly.sh --mode daily|weekly
#                               Force a mode. Default: weekly on Mondays (KST), daily
#                               otherwise. Both add the day's new items to the rolling
#                               7-day window; weekly mode ALSO refreshes the student
#                               sections (weekly-prompt.md section 8) and the KPI tiles
#                               and themes, and gets the larger turn and time budget.
#   ./run-weekly.sh --phase pre|post
#                               Split the run around the AI step, for when the AI is NOT
#                               the `claude` CLI but a Claude Code Desktop scheduled task
#                               (desktop-task-prompt.md). `pre` does everything up to and
#                               including the window roll, saves its state to .run-state
#                               and prints the run parameters; the session then does the
#                               daily-prompt.md work; `post` runs every gate, snapshots,
#                               commits and pushes. Default is `all`, the CLI path.
#
# EDITING THIS FILE: commit the change before you run it. The dirty-tree guard below
# does `git reset --hard`, which reverts an uncommitted edit to this very script while
# bash is still reading it -- bash tracks its position by byte offset, so it then
# resumes at that offset in a different file. The 2026-09-10 rehearsal did exactly
# that and had to be killed.
set -uo pipefail

NO_PUSH=0
MODE=auto
PHASE=all
while [ $# -gt 0 ]; do
  case "$1" in
    --no-push|--dry-run) NO_PUSH=1 ;;
    --mode) shift; MODE="${1:-}" ;;
    --mode=*) MODE="${1#--mode=}" ;;
    --phase) shift; PHASE="${1:-}" ;;
    --phase=*) PHASE="${1#--phase=}" ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
case "$MODE" in auto|daily|weekly) ;; *) echo "bad --mode: $MODE (auto|daily|weekly)" >&2; exit 2 ;; esac
case "$PHASE" in all|pre|post) ;; *) echo "bad --phase: $PHASE (all|pre|post)" >&2; exit 2 ;; esac

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$REPO_DIR/.weekly-update.log"
PROMPT_FILE="$REPO_DIR/daily-prompt.md"
RULEBOOK_FILE="$REPO_DIR/weekly-prompt.md"   # daily-prompt.md cites its sections

# Prefix every line of output with a timestamp, and append to the log.
stamp() {
  while IFS= read -r line; do
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$line"
  done >> "$LOG_FILE"
}

# Everything from here on — stdout and stderr — goes to the log, timestamped.
# fd 3 keeps the caller's terminal: everything else goes only to the log, but the run
# parameters and the final verdict are also echoed there, so a desktop session that ran
# this script through its shell tool can read them without opening the log.
exec 3>&1
exec > >(stamp) 2>&1
STAMP_PID=$!

# --- completion accounting -------------------------------------------------
# The 2026-09-08 run exposed the worst failure this script can have: it died in
# or after `claude`, wrote nothing past "--- claude ---", yet the Windows
# scheduler recorded LastTaskResult 0. A gate that is never reached cannot
# block, and an exit code that is never wrong cannot alarm.
#
# Two independent backstops close that hole:
#   1. RUN_COMPLETED is set to 1 only on the last line of the happy path. The
#      EXIT trap reports the run INCOMPLETE whenever it is still 0 and — the
#      part that matters — forces a NON-zero exit so the scheduler stops lying.
#   2. Every verdict line is written with a plain >> to the log and to
#      $STATUS_FILE, NOT through the `stamp` process substitution. If `stamp`
#      was severed (which loses buffered output and is the prime suspect for the
#      truncated 09-08 log), the direct write still lands.
RUN_COMPLETED=0
STATUS_FILE="$REPO_DIR/.weekly-last-status"
STATE_FILE="$REPO_DIR/.run-state"
# The verdict a successful run records. `pre` records PRE-COMPLETE, never COMPLETE, so
# publish-now.sh cannot mistake half a run for a finished one.
OK_VERDICT=COMPLETE
[ "$PHASE" = "pre" ] && OK_VERDICT=PRE-COMPLETE

on_exit() {
  local ec=$?
  # Stop feeding the log pipe and let `stamp` drain whatever it still holds, so the
  # verdict appended below is genuinely the last line. These writes open the file
  # directly, so they still land even when `stamp` is already dead.
  exec >/dev/null 2>&1
  wait "${STAMP_PID:-}" 2>/dev/null
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S %z')"
  local head; head="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  local verdict; [ "${RUN_COMPLETED:-0}" -eq 1 ] && verdict="$OK_VERDICT" || verdict=INCOMPLETE
  printf '%s RUN-VERDICT: %s (exit=%s, head=%s)\n' "$ts" "$verdict" "$ec" "$head" >> "$LOG_FILE"
  printf '%s\t%s\texit=%s\thead=%s\n' "$ts" "$verdict" "$ec" "$head" > "$STATUS_FILE"
  printf 'RUN-VERDICT: %s (exit=%s, phase=%s) -- details: tail -40 .weekly-update.log\n' "$verdict" "$ec" "${PHASE:-all}" >&3 2>/dev/null
  # Report failure to the scheduler when a run that claimed success never reached the end.
  if [ "${RUN_COMPLETED:-0}" -ne 1 ] && [ "$ec" -eq 0 ]; then
    exit 90   # incomplete run that would otherwise have exited 0
  fi
}
trap on_exit EXIT

echo "=============================================================="
echo "dashboard update starting"
echo "repo: $REPO_DIR"

cd "$REPO_DIR" || { echo "FATAL: cannot cd to $REPO_DIR"; exit 1; }

for f in "$PROMPT_FILE" "$RULEBOOK_FILE"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: $f not found"
    exit 1
  fi
done

# The run date is the KST calendar day. Computed in node, not `date`: Git Bash on Windows
# does not reliably honour TZ=Asia/Seoul, and at 06:00 KST the UTC date is still yesterday.
# BDPL_TODAY=YYYY-MM-DD overrides it for rehearsals (with --no-push); never set it in the
# scheduled task.
TODAY="${BDPL_TODAY:-$(node -e 'console.log(new Date(Date.now()+9*36e5).toISOString().slice(0,10))')}"
if ! printf '%s' "$TODAY" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
  echo "FATAL: could not determine the run date (node missing, or bad BDPL_TODAY='$TODAY')"; exit 1
fi
DOW="$(node -e 'console.log(new Date(process.argv[1]+"T00:00:00Z").getUTCDay())' "$TODAY")"   # 1 = Monday
if [ "$MODE" = "auto" ]; then
  if [ "$DOW" = "1" ]; then MODE=weekly; else MODE=daily; fi
fi

if [ "$PHASE" = "post" ]; then
  # Resume the run that `pre` started: same date, mode, baseline and rolled file.
  if [ ! -f "$STATE_FILE" ]; then
    echo "FATAL: --phase post but $STATE_FILE is missing -- run --phase pre first"; exit 1
  fi
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  for v in TODAY MODE PREV_RUN_DATE DELTA_START BASE_REF ROLLED_SHA PRE_OK; do
    if [ -z "${!v:-}" ]; then echo "FATAL: $STATE_FILE has no $v"; exit 1; fi
  done
fi
echo "run date (KST): $TODAY   mode: $MODE   phase: $PHASE"

if [ "$PHASE" != "post" ]; then

# Dirty-tree guard. If a previous run died mid-edit (session limit, the task's
# ExecutionTimeLimit, a crash), index.html is left half-written and uncommitted.
# git pull --rebase then refuses outright, and without this guard every later run
# would fail identically while the dashboard quietly went stale.
#
# Safe here: the sweep only ever rewrites the `research` and `industry` arrays in
# place -- it does NOT regenerate index.html, and must never do so, because the
# jobs/postdoc/grants tabs and the archive live in the same file and are not part
# of the sweep (weekly-prompt.md section 4b). .weekly-update.log is
# gitignored, and reset --hard does not touch untracked files. Local commits that
# were made but not pushed are also preserved — reset --hard only rewinds the
# working tree and index to HEAD.
#
# NOT safe for an uncommitted edit to this script -- see the note at the top.
echo "--- dirty-tree check ---"
if ! git diff --quiet HEAD 2>/dev/null; then
  echo "WARNING: dirty working tree — a previous run likely died mid-edit."
  echo "         discarding partial changes and starting clean:"
  git status --short
  if ! git diff --quiet HEAD -- run-weekly.sh 2>/dev/null; then
    echo "FATAL: the dirty file is run-weekly.sh itself, which is the script now running."
    echo "       Resetting it would swap this file out from under bash mid-execution."
    echo "       Commit or stash the change, then re-run."
    exit 1
  fi
  git reset --hard HEAD
  echo "WARNING: partial changes discarded. If this repeats week after week,"
  echo "         the run is dying before it can commit — investigate rather than ignore."
else
  echo "working tree clean"
fi

echo "--- git pull --rebase ---"
if ! git pull --rebase; then
  echo "FATAL: git pull --rebase failed (rebase conflict or no network); aborting"
  echo "       resolve by hand, then re-run this script"
  exit 1
fi

# The commit the run starts from. gen-seeds compares against this, NOT against HEAD:
# claude commits its own work before the deterministic pass runs, so by then HEAD is
# already the new state and every comparative check -- portal removed, count fell,
# lastChecked moved backwards, section shrank -- would be comparing it with itself and
# passing trivially. Capturing the ref here is what keeps those checks meaningful.
BASE_REF="$(git rev-parse HEAD)"
echo "baseline for the data-layer gate: $BASE_REF"

# Pre-flight: record that the student sections were intact going in, so that if the
# post-run check fails we know this run broke them rather than inheriting the damage.
echo "--- student-section guard (before) ---"
if ./check-student-sections.sh; then
  PRE_OK=1
else
  PRE_OK=0
  echo "WARNING: student sections were ALREADY damaged before this run started."
  echo "         fix them by hand -- this run will not repair them."
fi

# Roll the window BEFORE claude: drop items added more than 7 days ago and move RUN_DATE
# to today. The previous RUN_DATE is the start of today's search window -- read it first.
PREV_RUN_DATE="$(grep -o 'const RUN_DATE = "[0-9-]*"' index.html | grep -o '[0-9]\{4\}-[0-9-]*')"
if [ -z "$PREV_RUN_DATE" ]; then
  echo "FATAL: index.html has no const RUN_DATE line"
  exit 1
fi
# Search window start: the previous run date (one day of overlap, deduplicated by DOI and
# link), but never more than 14 days back -- a long outage should not turn one run into a
# month-long sweep the turn budget cannot finish.
DELTA_START="$(node -e '
  const t=new Date(process.argv[1]+"T00:00:00Z"), p=new Date(process.argv[2]+"T00:00:00Z");
  const floor=new Date(t); floor.setUTCDate(floor.getUTCDate()-14);
  console.log((p<floor?floor:p).toISOString().slice(0,10));' "$TODAY" "$PREV_RUN_DATE")"
echo "previous run: $PREV_RUN_DATE   search window: $DELTA_START .. $TODAY"

echo "--- roll the 7-day window (scripts/daily-roll.js) ---"
if ! node scripts/daily-roll.js --date "$TODAY"; then
  echo "FATAL: the window roll failed; nothing was written by it, not running claude"
  exit 1
fi
# The roll itself changes index.html, so the stall guard below compares against the
# rolled file rather than BASE_REF -- otherwise the roll alone would satisfy it.
ROLLED_SHA="$(git hash-object index.html)"

if [ "$MODE" = "weekly" ]; then
  MAX_TURNS=90; TIME_LIMIT=3h
else
  MAX_TURNS=60; TIME_LIMIT=100m
fi

fi   # end of: PHASE != post

if [ "$PHASE" = "pre" ]; then
  {
    printf 'TODAY=%q\nMODE=%q\nPREV_RUN_DATE=%q\nDELTA_START=%q\n' "$TODAY" "$MODE" "$PREV_RUN_DATE" "$DELTA_START"
    printf 'BASE_REF=%q\nROLLED_SHA=%q\nPRE_OK=%q\n' "$BASE_REF" "$ROLLED_SHA" "$PRE_OK"
  } > "$STATE_FILE"
  # Printed to the terminal as well as the log: the desktop session reads it from here.
  HDR="<!-- RUN PARAMETERS (written by run-weekly.sh --phase pre) -->
RUN_MODE: $MODE
TODAY: $TODAY
PREV_RUN_DATE: $PREV_RUN_DATE
SEARCH_WINDOW: $DELTA_START .. $TODAY
<!-- end of run parameters -->"
  printf '%s\n' "$HDR"
  printf '%s\n' "$HDR" >&3
  echo "pre phase done: now do daily-prompt.md, commit, then run ./run-weekly.sh --phase post"
  RUN_COMPLETED=1
  exit 0
fi

if [ "$PHASE" = "all" ]; then
echo "--- claude ---"
# --max-turns 90: the 2026-08-26 run died on "Reached max turns (60)" having written
# only the two sweep arrays. Section 8 adds three more sections to the run; the
# deterministic half of that work moved to scripts/ to buy the turns back, but the
# searching itself still costs some.
#
# timeout 3h: that same run went on writing to this log for 24 hours. The scheduler's
# ExecutionTimeLimit (PT4H) kills only the action process and orphans its children, so
# the deadline has to be here, where the script is still alive to log it. 124 is
# timeout's exit code for "deadline hit".
# The prompt goes in on STDIN, not as an argument. Windows caps a command line at
# 32767 characters, and "$(cat "$PROMPT_FILE")" puts the whole prompt on it: once
# weekly-prompt.md passed that size the exec failed outright and claude exited 126
# without running, which reads in the log exactly like a crash. Measured on this
# machine: a 31KB prompt runs, a 36KB prompt exits 126. The file is past that now and
# only grows, so the argument form is not usable at any prompt size worth keeping.
#
# Daily cadence: the run parameters go in as a short header ahead of daily-prompt.md, so
# the prompt itself stays a static file and the values are visible in one place.
# Daily runs get 60 turns / 100 min -- they only add one day of items. Weekly (Monday)
# runs keep the old 90 turns / 3h because they also do section 8.
{
  printf '%s\n' "<!-- RUN PARAMETERS (written by run-weekly.sh) -->"
  printf 'RUN_MODE: %s\n' "$MODE"
  printf 'TODAY: %s\n' "$TODAY"
  printf 'PREV_RUN_DATE: %s\n' "$PREV_RUN_DATE"
  printf 'SEARCH_WINDOW: %s .. %s\n' "$DELTA_START" "$TODAY"
  printf '%s\n\n' "<!-- end of run parameters -->"
  cat "$PROMPT_FILE"
} | timeout "$TIME_LIMIT" claude -p \
  --permission-mode dontAsk \
  --allowedTools "Read,Edit,Write,Glob,Grep,WebSearch,WebFetch,Bash(git *),Bash(node *),Bash(./check-student-sections.sh)" \
  --max-turns "$MAX_TURNS"
CLAUDE_STATUS=$?
if [ $CLAUDE_STATUS -eq 124 ]; then
  echo "FATAL: claude hit the $TIME_LIMIT timeout"
fi
else
  # --phase post: the AI step was a Claude Code Desktop session, not this script's child.
  CLAUDE_STATUS=0
  echo "--- AI step was done outside this script (desktop session); resuming at the gates ---"
fi

# Breadcrumb written straight to the log. On 2026-09-08 nothing past
# "--- claude ---" survived, so we could not even tell whether claude returned.
# This line bypasses `stamp`, so it lands even if the log pipe is already gone —
# next time it will pin down "claude returned 0 then downstream vanished" versus
# "claude never returned at all".
printf '%s claude returned: status=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$CLAUDE_STATUS" >> "$LOG_FILE"

# Silent-stall guard. Every real run moves at least the date-range and
# generation-date strings, so index.html is never byte-identical to the rolled file
# afterward -- even on a day that found nothing new. If it is, claude returned without
# doing the work (the 09-08 signature) and we fail loudly here instead of sailing
# through the gates into a deceptive "nothing to push". Compared against the ROLLED file,
# not BASE_REF: the roll already changed RUN_DATE, which would satisfy a BASE_REF check.
if [ "$(git hash-object index.html)" = "$ROLLED_SHA" ]; then
  echo "FATAL: claude returned (status=$CLAUDE_STATUS) but index.html is unchanged since the"
  echo "       window roll. The run produced nothing; not committing, not pushing."
  exit 1
fi

# Daily runs leave the student data to Monday. Checked here, straight after claude, because
# check-links.js below legitimately rewrites link_type in those same files every run.
if [ "$MODE" = "daily" ] && ! git diff --quiet "$BASE_REF" -- data/jobs.json data/postdoc.json data/grants.json data/postdoc_watchlist.json 2>/dev/null; then
  echo "WARNING: a DAILY claude session changed the student data files. Those are refreshed"
  echo "         on Mondays (weekly mode). The gates below still judge the result; check the diff."
fi

# ---------------------------------------------------------------------------
# Deterministic pass. Everything below is arithmetic and assertions -- no model
# judgement -- so it runs here rather than as an instruction in the prompt.
#
# Order matters, and it is the reason the post-flight guard moved down here:
#   pi-aggregate reads the research array claude just wrote, so it runs after claude.
#   gen-seeds rewrites index.html's inline seeds from data/*.json, so it runs after
#     any edit claude made to those files -- section 8 now has the run update them,
#     which means the seeds are legitimately out of step until this point. Running
#     check-student-sections.sh before this would report that as damage.
#   the guard then judges the finished state, which is the state that gets pushed.
#   nothing is published unless all three pass.
# ---------------------------------------------------------------------------
# Link quality, before the gates. Every student-section URL is fetched and anything
# that 404s, bounces to a home page or hits a login wall is demoted out of "deep" so the
# card stops promising a posting it cannot deliver. Deliberately advisory: it exits 0 even
# when every request fails, because being offline is not evidence a link is dead, and a
# flaky network must not be able to block a good week from publishing.
echo "--- link check (scripts/check-links.js) ---"
node scripts/check-links.js || echo "WARNING: link check errored; continuing with link_type as it was"

echo "--- rolling-window gate (scripts/daily-roll.js --check) ---"
if ! node scripts/daily-roll.js --check --date "$TODAY"; then
  echo "FATAL: the rolling-window gate failed; not committing, not pushing"
  echo "dashboard update finished"
  exit 1
fi

echo "--- pi ledger (scripts/pi-aggregate.js) ---"
if ! node scripts/pi-aggregate.js; then
  echo "FATAL: PI aggregation failed; not committing, not pushing"
  echo "dashboard update finished"
  exit 1
fi

echo "--- regenerate seeds + data-layer gate (scripts/gen-seeds.js) ---"
if ! node scripts/gen-seeds.js --base "$BASE_REF"; then
  echo "FATAL: the data-layer gate failed; nothing was written, not committing, not pushing"
  echo "       fix data/*.json by hand, re-run the gate, then push"
  echo "dashboard update finished"
  exit 1
fi

echo "--- student-section guard (after) ---"
if ./check-student-sections.sh; then
  GUARD_STATUS=0
else
  GUARD_STATUS=1
  if [ "$PRE_OK" -eq 1 ]; then
    echo "ERROR: this run DESTROYED part of the jobs/postdoc/grants sections."
    echo "       they were intact before claude ran and are broken now."
    echo "       nothing has been pushed. inspect the working tree, then either fix it"
    echo "       or discard it with: git checkout -- index.html data/"
    echo "       re-read weekly-prompt.md sections 4b and 8 before the next run."
  fi
fi

echo "claude exit status: $CLAUDE_STATUS"
echo "student-section guard: $([ $GUARD_STATUS -eq 0 ] && echo intact || echo DAMAGED)"
if [ $CLAUDE_STATUS -ne 0 ]; then
  echo "WARNING: claude exited non-zero — check the transcript above."
fi

# The guard is a publish gate, not just an alarm: a damaged state is never pushed.
if [ $GUARD_STATUS -ne 0 ]; then
  echo "FATAL: refusing to commit or push with the student sections damaged"
  echo "dashboard update finished"
  exit 1
fi

# research and industry are replaced wholesale every run, so the moment this finishes
# the previous week exists nowhere but git history. Snapshot the finished state per ISO
# week -- after the guards, so what gets recorded is what gets published, and before the
# commit, so the file is actually staged rather than left untracked for the next run's
# dirty-tree check to trip over.
echo "--- week + day snapshot (scripts/week-archive.js) ---"
if ! node scripts/week-archive.js --date "$TODAY"; then
  echo "FATAL: week snapshot failed; not committing, not pushing"
  echo "dashboard update finished"
  exit 1
fi

# gen-seeds rewrites index.html's seed blocks, pi-aggregate rewrites the ledger and
# week-archive adds a file, so this is usually dirty even when claude committed its own
# work. --porcelain rather than "git diff --quiet": the week snapshot is a NEW file on
# the first run of each week, and git diff does not see untracked files at all.
if [ -n "$(git status --porcelain -- data/ index.html)" ]; then
  echo "--- committing the generated layer ---"
  git add data/ index.html
  git commit -m "chore: PI ledger, seeds and snapshots ($TODAY, $MODE)" || {
    echo "FATAL: could not commit the generated layer"; exit 1; }
fi

echo "--- push ---"
if [ "$NO_PUSH" -eq 1 ]; then
  echo "--no-push: skipping git push. Local state, for inspection:"
  git --no-pager log --oneline "@{upstream}..HEAD" 2>/dev/null || git --no-pager log --oneline -3
  git --no-pager diff --stat "@{upstream}..HEAD" 2>/dev/null
  echo "         publish it with: git push"
elif git diff --quiet "@{upstream}..HEAD" 2>/dev/null; then
  echo "nothing to push — HEAD already matches the remote"
else
  if ! git push; then
    echo "FATAL: git push failed; the work is committed locally but not published"
    echo "dashboard update finished"
    exit 1
  fi
  echo "pushed: $(git rev-parse --short HEAD)"
fi

rm -f "$STATE_FILE"
echo "--- done ---"
echo "dashboard update finished"
echo

RUN_COMPLETED=1
exit $CLAUDE_STATUS
