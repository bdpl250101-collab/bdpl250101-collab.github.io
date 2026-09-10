#!/usr/bin/env bash
#
# Publish the update that the most recent `./run-weekly.sh --no-push` rehearsal
# already built and committed locally — WITHOUT paying for a second 25-40 min
# claude sweep.
#
# `--no-push` runs the entire pipeline (claude collection, every gate, pi-aggregate,
# gen-seeds, the student guard, the week snapshot) and commits the result locally.
# The ONLY thing it skips is the final `git push`. So once a rehearsal prints
#   RUN-VERDICT: COMPLETE
# this week's update is fully built and verified — publishing it is just a push.
#
# This script refuses to push unless all of these hold, so it can never ship a
# half-finished, failed, or empty run:
#   1. the last run on this machine ended RUN-VERDICT: COMPLETE
#   2. the working tree is clean (no run in progress, no partial edit)
#   3. there are local commits ahead of the remote to publish
#   4. index.html actually differs from what is already live (no no-op push)
#
# Usage:
#   ./publish-now.sh          # verify, show what will ship, ask, then push
#   ./publish-now.sh -y       # same, but skip the confirmation prompt
#   ./publish-now.sh --dry-run # verify and show, but never push
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

STATUS_FILE=".weekly-last-status"
ASSUME_YES=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes)      ASSUME_YES=1 ;;
    -n|--dry-run)  DRY_RUN=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

fail(){ echo "REFUSING TO PUBLISH: $*" >&2; exit 1; }

# 1. The last run must have completed cleanly. The status file is written by
#    run-weekly.sh's EXIT trap as: "<timestamp>\t<VERDICT>\texit=N\thead=...".
#    Match the VERDICT field exactly — "INCOMPLETE" contains "COMPLETE", so a
#    substring test would wave the bad case through.
[ -f "$STATUS_FILE" ] || fail "no $STATUS_FILE yet — has a run finished on this machine? Run ./run-weekly.sh --no-push first."
verdict="$(awk -F'\t' 'END{print $2}' "$STATUS_FILE")"
[ "$verdict" = "COMPLETE" ] || fail "last run verdict is '${verdict:-<empty>}', not COMPLETE:
    $(cat "$STATUS_FILE")
  A run may still be in progress, or the last one failed. Wait for COMPLETE, then retry."

# 2. Clean tree — a dirty tree means a run is mid-flight or a previous one died
#    without committing. Publishing from it would ship a partial state.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "working tree is not clean:"; git status --short
  fail "uncommitted changes present — a run may be in progress. Let it finish, then retry."
fi

# 3. There must be something to publish, measured against the real remote.
git fetch -q origin || fail "git fetch failed — no network, or the repo is not authorized to push from here."
if ! git rev-parse '@{upstream}' >/dev/null 2>&1; then
  fail "no upstream is set for the current branch; cannot compare with the remote."
fi
ahead="$(git rev-list --count '@{upstream}..HEAD')"
[ "${ahead:-0}" -gt 0 ] || fail "nothing to publish — HEAD already matches the remote. This week may already be live."

# 4. Sanity: the thing we are about to ship must actually change the dashboard.
if git diff --quiet '@{upstream}' -- index.html; then
  fail "index.html is identical to what is already live — refusing to publish a no-op."
fi

echo "=============================================================="
echo "Ready to publish. Last run: $(cat "$STATUS_FILE")"
echo
echo "Commits that will be pushed ($ahead):"
git --no-pager log --oneline '@{upstream}..HEAD'
echo
echo "File changes vs the live site:"
git --no-pager diff --stat '@{upstream}..HEAD'
echo "=============================================================="

if [ "$DRY_RUN" -eq 1 ]; then
  echo "--dry-run: not pushing. Publish for real with: ./publish-now.sh"
  exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  printf 'Push these to the live dashboard now? [y/N] '
  read -r reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "aborted — nothing pushed."; exit 0 ;;
  esac
fi

if git push; then
  echo "PUBLISHED: $(git rev-parse --short HEAD)"
  echo "https://bdpl250101-collab.github.io/ will refresh within a minute or two."
else
  fail "git push failed — the work is still committed locally; resolve and re-run."
fi
