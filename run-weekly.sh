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
# Safe here: index.html is fully regenerated each run, .weekly-update.log is
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

echo "--- claude ---"
claude -p "$(cat "$PROMPT_FILE")" \
  --permission-mode dontAsk \
  --allowedTools "Read,Edit,Write,Glob,Grep,WebSearch,WebFetch,Bash(git *),Bash(node *)" \
  --max-turns 60
CLAUDE_STATUS=$?

echo "--- done ---"
echo "claude exit status: $CLAUDE_STATUS"
if [ $CLAUDE_STATUS -ne 0 ]; then
  echo "WARNING: claude exited non-zero — check the transcript above."
  echo "         the dashboard may not have been updated or pushed."
fi
echo "weekly dashboard update finished"
echo

exit $CLAUDE_STATUS
