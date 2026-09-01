#!/usr/bin/env bash
#
# Weekly auto-update for the BDPL battery-research dashboard.
# Pulls the repo, hands weekly-prompt.md to Claude Code, and logs everything.
#
# Scheduled for Mondays 06:00 KST (= Sundays 21:00 UTC), via the Windows Task
# Scheduler task BDPL-WeeklyDashboard. Run it by hand any time to test:
#   ./run-weekly.sh
#
#   ./run-weekly.sh --no-push   collect, verify, commit locally — but do not push.
#                               Use it to exercise the whole path without publishing.
#                               (--dry-run is accepted as a synonym.)
set -uo pipefail

NO_PUSH=0
for arg in "$@"; do
  case "$arg" in
    --no-push|--dry-run) NO_PUSH=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$REPO_DIR/.weekly-update.log"
PROMPT_FILE="$REPO_DIR/weekly-prompt.md"

# Prefix every line of output with a timestamp, and append to the log.
stamp() {
  while IFS= read -r line; do
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$line"
  done >> "$LOG_FILE"
}

# Everything from here on — stdout and stderr — goes to the log, timestamped.
exec > >(stamp) 2>&1

echo "=============================================================="
echo "weekly dashboard update starting"
echo "repo: $REPO_DIR"

cd "$REPO_DIR" || { echo "FATAL: cannot cd to $REPO_DIR"; exit 1; }

if [ ! -f "$PROMPT_FILE" ]; then
  echo "FATAL: $PROMPT_FILE not found"
  exit 1
fi

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
echo "--- dirty-tree check ---"
if ! git diff --quiet HEAD 2>/dev/null; then
  echo "WARNING: dirty working tree — a previous run likely died mid-edit."
  echo "         discarding partial changes and starting clean:"
  git status --short
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
timeout 3h claude -p \
  --permission-mode dontAsk \
  --allowedTools "Read,Edit,Write,Glob,Grep,WebSearch,WebFetch,Bash(git *),Bash(node *),Bash(./check-student-sections.sh)" \
  --max-turns 90 \
  < "$PROMPT_FILE"
CLAUDE_STATUS=$?
if [ $CLAUDE_STATUS -eq 124 ]; then
  echo "FATAL: claude hit the 3h timeout"
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

echo "--- pi ledger (scripts/pi-aggregate.js) ---"
if ! node scripts/pi-aggregate.js; then
  echo "FATAL: PI aggregation failed; not committing, not pushing"
  echo "weekly dashboard update finished"
  exit 1
fi

echo "--- regenerate seeds + data-layer gate (scripts/gen-seeds.js) ---"
if ! node scripts/gen-seeds.js --base "$BASE_REF"; then
  echo "FATAL: the data-layer gate failed; nothing was written, not committing, not pushing"
  echo "       fix data/*.json by hand, re-run the gate, then push"
  echo "weekly dashboard update finished"
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
  echo "weekly dashboard update finished"
  exit 1
fi

# research and industry are replaced wholesale every run, so the moment this finishes
# the previous week exists nowhere but git history. Snapshot the finished state per ISO
# week -- after the guards, so what gets recorded is what gets published, and before the
# commit, so the file is actually staged rather than left untracked for the next run's
# dirty-tree check to trip over.
echo "--- week snapshot (scripts/week-archive.js) ---"
if ! node scripts/week-archive.js; then
  echo "FATAL: week snapshot failed; not committing, not pushing"
  echo "weekly dashboard update finished"
  exit 1
fi

# gen-seeds rewrites index.html's seed blocks, pi-aggregate rewrites the ledger and
# week-archive adds a file, so this is usually dirty even when claude committed its own
# work. --porcelain rather than "git diff --quiet": the week snapshot is a NEW file on
# the first run of each week, and git diff does not see untracked files at all.
if [ -n "$(git status --porcelain -- data/ index.html)" ]; then
  echo "--- committing the generated layer ---"
  git add data/ index.html
  git commit -m "chore: PI ledger and regenerated seeds ($(date '+%Y-%m-%d'))" || {
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
    echo "weekly dashboard update finished"
    exit 1
  fi
  echo "pushed: $(git rev-parse --short HEAD)"
fi

echo "--- done ---"
echo "weekly dashboard update finished"
echo

exit $CLAUDE_STATUS
