#!/usr/bin/env bash
#
# drain-stuck-runs.sh — approve workflow runs held at `action_required`.
#
# Runs from outside contributors wait for a manual "Approve and run" click. A
# run that is never approved reports no checks at all, which makes the PR
# permanently unmergeable once required status checks are enforced. This drains
# the backlog that accumulated before the fork-approval policy was relaxed.
#
# Two economies, because approving blindly wastes a lot of CI:
#
#   1. Only the NEWEST stuck run per branch is approved. Older ones are for
#      superseded commits -- nanocoder had 126 stuck runs on a single branch
#      (changeset-release/main, re-created on every merge to main).
#   2. Only branches with an OPEN pull request are approved. The rest cannot
#      benefit from a check result.
#
# Usage:
#   ./drain-stuck-runs.sh --dry-run
#   ./drain-stuck-runs.sh
#
set -euo pipefail

ORG="Nano-Collective"
REPOS="${REPOS:-nanocoder prompt-scrubber nanotune sentinel}"
DRY="${1:-}"

approved=0; skipped_super=0; skipped_closed=0

for repo in $REPOS; do
  echo "=== $repo ==="

  # Head branches of currently-open PRs.
  open_refs=$(gh api "repos/$ORG/$repo/pulls?state=open&per_page=100" --paginate \
    --jq '.[].head.ref' 2>/dev/null | sort -u)
  if [ -z "$open_refs" ]; then
    echo "  no open PRs — skipping"
    continue
  fi

  # All stuck runs, newest first.
  runs=$(gh api "repos/$ORG/$repo/actions/runs?status=action_required&per_page=100" --paginate \
    --jq '.workflow_runs[]|"\(.head_branch)\t\(.id)\t\(.created_at)"' 2>/dev/null \
    | sort -t"$(printf '\t')" -k1,1 -k3,3r)

  [ -z "$runs" ] && { echo "  nothing stuck"; continue; }

  last_branch=""
  while IFS=$'\t' read -r branch id created; do
    [ -z "$branch" ] && continue

    if [ "$branch" = "$last_branch" ]; then
      skipped_super=$((skipped_super + 1))
      continue
    fi
    last_branch="$branch"

    if ! printf '%s\n' "$open_refs" | grep -qxF "$branch"; then
      skipped_closed=$((skipped_closed + 1))
      continue
    fi

    if [ "$DRY" = "--dry-run" ]; then
      echo "  [dry-run] would approve $id  ($branch, $created)"
    else
      if gh api -X POST "repos/$ORG/$repo/actions/runs/$id/approve" >/dev/null 2>&1; then
        echo "  approved $id  ($branch)"
      else
        echo "  FAILED   $id  ($branch)" >&2
        continue
      fi
    fi
    approved=$((approved + 1))
  done <<< "$runs"
done

echo
echo "summary:"
echo "  approved (or would):     $approved"
echo "  skipped, superseded:     $skipped_super"
echo "  skipped, no open PR:     $skipped_closed"
