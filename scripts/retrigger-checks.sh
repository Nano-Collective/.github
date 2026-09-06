#!/usr/bin/env bash
#
# retrigger-checks.sh — fire pr-checks on open PRs that have never reported.
#
# Some PRs predate the shared workflow and have not been pushed since. GitHub
# does not re-run PR checks when the base branch moves, so nothing ever
# triggered them, and they would be blocked the moment required status checks
# are enforced -- through no fault of the author.
#
# The caller workflow triggers on [opened, synchronize, reopened], so closing
# and immediately reopening fires it without touching the contributor's branch.
#
# Skips:
#   - PRs that already report all six required checks
#   - CONFLICTING PRs: GitHub cannot compute a merge ref, so `pull_request`
#     workflows do not fire at all. Reopening achieves nothing; the branch needs
#     a rebase first.
#
# Usage:
#   ./retrigger-checks.sh --dry-run
#   ./retrigger-checks.sh
#   REPOS="nanocoder" ./retrigger-checks.sh
#
set -euo pipefail

ORG="Nano-Collective"
REPOS="${REPOS:-nanocoder prompt-scrubber}"
DRY="${1:-}"

REQ='["pr-checks / Linting","pr-checks / Type Checks","pr-checks / Format Checks","pr-checks / Unused Dependencies","pr-checks / Unit Tests & Coverage Analysis","pr-checks / Verify Build"]'

total=0; skipped_conflict=0

for repo in $REPOS; do
  echo "=== $repo ==="

  targets=$(gh api graphql -f query="
  {
    repository(owner: \"$ORG\", name: \"$repo\") {
      pullRequests(states: OPEN, first: 100) {
        nodes { number mergeable isDraft
          commits(last: 1) { nodes { commit { checkSuites(first: 20) {
            nodes { checkRuns(first: 30) { nodes { name } } } } } } } }
      }
    }
  }" --jq "
    $REQ as \$req
    | .data.repository.pullRequests.nodes
    | map(. + {present: ([.commits.nodes[0].commit.checkSuites.nodes[].checkRuns.nodes[]
                          | select(.name as \$n | \$req | index(\$n)) | .name] | unique | length)})
    | map(select(.present < 6))
    | .[] | \"\(.number)\t\(.mergeable)\"
  ")

  [ -z "$targets" ] && { echo "  nothing to retrigger"; continue; }

  while IFS=$'\t' read -r num mergeable; do
    [ -z "$num" ] && continue
    if [ "$mergeable" = "CONFLICTING" ]; then
      echo "  #$num skipped — CONFLICTING, needs a rebase (workflows cannot run)"
      skipped_conflict=$((skipped_conflict + 1))
      continue
    fi
    if [ "$DRY" = "--dry-run" ]; then
      echo "  [dry-run] would close+reopen #$num"
    else
      gh pr close  "$num" --repo "$ORG/$repo" >/dev/null 2>&1
      gh pr reopen "$num" --repo "$ORG/$repo" >/dev/null 2>&1
      echo "  #$num retriggered"
    fi
    total=$((total + 1))
  done <<< "$targets"
done

echo
echo "summary:"
echo "  retriggered (or would): $total"
echo "  skipped, conflicting:   $skipped_conflict"
