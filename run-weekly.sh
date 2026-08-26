#!/usr/bin/env bash
#
# Weekly auto-update for the BDPL battery-research dashboard.
# Pulls the repo, hands weekly-prompt.md to Claude Code, and logs everything.
#
# Scheduled for Mondays 06:00 KST (= Sundays 21:00 UTC), via the Windows Task
# Scheduler task BDPL-WeeklyDashboard. Run it by hand any time to test:
#   ./run-weekly.sh
#
set -uo pipefail

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
claude -p "$(cat "$PROMPT_FILE")" \
  --permission-mode dontAsk \
  --allowedTools "Read,Edit,Write,Glob,Grep,WebSearch,WebFetch,Bash(git *),Bash(node *)" \
  --max-turns 60
CLAUDE_STATUS=$?

# Post-flight: the sweep must not have touched the three student tabs or their data
# files. If it did, say so loudly -- the run may already have pushed the damage, so
# this is an alarm, not a rollback.
echo "--- student-section guard (after) ---"
if ./check-student-sections.sh; then
  GUARD_STATUS=0
else
  GUARD_STATUS=1
  if [ "$PRE_OK" -eq 1 ]; then
    echo "ERROR: this run DESTROYED part of the jobs/postdoc/grants sections."
    echo "       they were intact before claude ran and are broken now."
    echo "       if the run already pushed, revert that commit:"
    echo "           git revert HEAD && git push"
    echo "       then re-read weekly-prompt.md section 4b before the next run."
  fi
fi

echo "--- done ---"
echo "claude exit status: $CLAUDE_STATUS"
echo "student-section guard: $([ $GUARD_STATUS -eq 0 ] && echo intact || echo DAMAGED)"
if [ $CLAUDE_STATUS -ne 0 ]; then
  echo "WARNING: claude exited non-zero — check the transcript above."
  echo "         the dashboard may not have been updated or pushed."
fi
echo "weekly dashboard update finished"
echo

# Fail the task if either the run or the guard failed, so the scheduler surfaces it.
if [ $CLAUDE_STATUS -ne 0 ]; then exit $CLAUDE_STATUS; fi
exit $GUARD_STATUS
