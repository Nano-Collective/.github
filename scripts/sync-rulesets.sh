#!/usr/bin/env bash
#
# sync-rulesets.sh — apply the collective's rulesets to each package repo.
#
# The org is on GitHub Free, so org-level rulesets are unavailable. This script
# is the replacement: it PUTs the same definition to every repo, and is what you
# re-run when a repo drifts or a new repo is created.
#
# Usage:
#   ./sync-rulesets.sh preflight              # read-only readiness report
#   ./sync-rulesets.sh apply quality --dry-run
#   ./sync-rulesets.sh apply quality
#   ./sync-rulesets.sh apply review
#   ./sync-rulesets.sh verify
#   ./sync-rulesets.sh enforce quality        # flip evaluate -> active
#
# Env:
#   REPOS="a b c"   override the default repo list
#
set -euo pipefail

ORG="Nano-Collective"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULESET_DIR="$HERE/../rulesets"

# nanotune is deliberately excluded until its coverage reaches 80 (decision
# Q18); it sits at 71.6% with a 71 floor pinned in its caller workflow. Add it
# here when nanotune#123 closes, and delete the pin in the same change.
#
# nanoterm was excluded on the same grounds and is no longer: it reached 90.56%
# against the standard 80, so it joined the list on 2026-09-07.
DEFAULT_REPOS="nanocoder sentinel prompt-scrubber get-md json-up nanoterm"
REPOS="${REPOS:-$DEFAULT_REPOS}"

# RepositoryRole bypass actor ids, resolved empirically on 2026-09-04 via
# scripts/probe-role-ids.sh. GitHub does not document these and they are NOT
# ordered by privilege -- do not infer one from another:
#
#   2 = maintain     4 = write     5 = admin
#
# Every other id in 1..12 is rejected with "Actor base role does not have write
# permissions". review.json uses 2.

# The six blocking checks, as they are actually reported by the reusable
# workflow. Verified against live check runs on 2026-09-04.
REQUIRED_CHECKS=(
  "pr-checks / Linting"
  "pr-checks / Type Checks"
  "pr-checks / Format Checks"
  "pr-checks / Unused Dependencies"
  "pr-checks / Unit Tests & Coverage Analysis"
  "pr-checks / Verify Build"
)

die() { echo "error: $*" >&2; exit 1; }

need_scope() {
  local scopes
  scopes=$(gh auth status 2>&1 | sed -n 's/.*Token scopes: //p')
  echo "token scopes: $scopes"
  case "$scopes" in
    *admin:org*) ;;
    *) echo "note: no admin:org scope — repo rulesets work, org/team operations do not." ;;
  esac
}

# ---------------------------------------------------------------- preflight --

# Enforcing a ruleset whose checks are not reporting makes every PR in the repo
# permanently unmergeable. This refuses to let that happen silently.
preflight() {
  need_scope
  echo
  printf '%-18s %-8s %-8s %-10s %s\n' REPO STUCK OPEN_PRS RULESETS CHECKS_ON_LATEST_PR
  for repo in $REPOS; do
    local stuck open pr sha found rs
    stuck=$(gh api "repos/$ORG/$repo/actions/runs?status=action_required&per_page=1" \
      --jq '.total_count' 2>/dev/null || echo "?")
    open=$(gh api "search/issues?q=repo:$ORG/$repo+is:pr+is:open&per_page=1" \
      --jq '.total_count' 2>/dev/null || echo "?")
    rs=$(gh api "repos/$ORG/$repo/rulesets" --jq '[.[].name]|join(",")' 2>/dev/null || echo "?")
    [ -z "$rs" ] && rs="none"

    pr=$(gh api "repos/$ORG/$repo/pulls?state=all&per_page=1" --jq '.[0].number' 2>/dev/null)
    found=0
    if [ -n "$pr" ] && [ "$pr" != "null" ]; then
      sha=$(gh api "repos/$ORG/$repo/pulls/$pr" --jq '.head.sha' 2>/dev/null)
      for c in "${REQUIRED_CHECKS[@]}"; do
        if gh api "repos/$ORG/$repo/commits/$sha/check-runs?per_page=100" \
             --jq '.check_runs[].name' 2>/dev/null | grep -qxF "$c"; then
          found=$((found + 1))
        fi
      done
    fi
    printf '%-18s %-8s %-8s %-10s %s\n' "$repo" "$stuck" "$open" "$rs" "$found/6"
  done
  echo
  echo "STUCK = workflow runs awaiting manual approval. Any non-zero value means"
  echo "those PRs will never report checks, so enforcing 'quality' blocks them."
}

# ------------------------------------------------------------------- apply --

ruleset_id_by_name() {
  gh api "repos/$ORG/$1/rulesets" 2>/dev/null \
    | jq -r --arg n "$2" '.[]|select(.name==$n)|.id' \
    | head -1 || true
}

apply() {
  local which="${1:?usage: apply <quality|review> [--dry-run]}"
  local dry="${2:-}"
  local file="$RULESET_DIR/$which.json"
  [ -f "$file" ] || die "no such ruleset file: $file"

  for repo in $REPOS; do
    local id
    id=$(ruleset_id_by_name "$repo" "$(jq -r .name "$file")")
    if [ "$dry" = "--dry-run" ]; then
      if [ -n "$id" ]; then
        echo "[dry-run] $repo: would UPDATE ruleset $id from $which.json"
      else
        echo "[dry-run] $repo: would CREATE ruleset from $which.json"
      fi
      continue
    fi
    if [ -n "$id" ]; then
      gh api -X PUT "repos/$ORG/$repo/rulesets/$id" --input "$file" >/dev/null
      echo "$repo: updated ruleset $id ($which)"
    else
      id=$(gh api -X POST "repos/$ORG/$repo/rulesets" --input "$file" --jq '.id')
      echo "$repo: created ruleset $id ($which)"
    fi
  done
}

# Flip evaluate -> active once the rule suites come back clean.
enforce() {
  local which="${1:?usage: enforce <quality|review>}"
  local file="$RULESET_DIR/$which.json"
  local name; name=$(jq -r .name "$file")
  for repo in $REPOS; do
    local id; id=$(ruleset_id_by_name "$repo" "$name")
    [ -n "$id" ] || { echo "$repo: no '$name' ruleset — skipping"; continue; }
    jq '.enforcement = "active"' "$file" \
      | gh api -X PUT "repos/$ORG/$repo/rulesets/$id" --input - >/dev/null
    echo "$repo: '$name' -> active"
  done
}

# ------------------------------------------------------------------ verify --

# Reads back what GitHub actually stored. Two things worth eyeballing here: the
# check contexts (a mismatch reports as "N of 6 expected" forever) and the
# RepositoryRole bypass id, which decides whether maintainers can actually
# merge without an approval.
verify() {
  for repo in $REPOS; do
    echo "=== $repo ==="
    gh api "repos/$ORG/$repo/rules/branches/main" --jq \
      '[.[]|.type]|unique|"  active rule types: \(join(", "))"' 2>&1
    for name in "Quality gates" "Review gates"; do
      local id; id=$(ruleset_id_by_name "$repo" "$name")
      [ -n "$id" ] || { echo "  $name: absent"; continue; }
      gh api "repos/$ORG/$repo/rulesets/$id" --jq \
        "\"  $name: \(.enforcement) | bypass=\([.bypass_actors[]|\"\(.actor_type):\(.actor_id // \"-\")\"]|join(\",\"))\""
    done
    # Most recent rule-suite evaluation, which is where a context mismatch shows up.
    gh api "repos/$ORG/$repo/rulesets/rule-suites?per_page=1" --jq \
      '.[0] // empty | "  last evaluation: \(.result) by \(.actor_name)"' 2>/dev/null
  done
}

# Removes the legacy "Primary Rules" ruleset. Rulesets STACK, so Ruleset B has
# no effect while this one is live -- it is the stricter of the two and keeps
# routing everything through an org admin.
#
# Refuses to run unless "Review gates" is already in place on the repo, so a
# repo cannot be left with no review gate at all.
delete_legacy() {
  local dry="${1:-}"
  for repo in $REPOS; do
    local legacy review
    legacy=$(ruleset_id_by_name "$repo" "Primary Rules")
    [ -n "$legacy" ] || { echo "$repo: no 'Primary Rules' — nothing to do"; continue; }
    review=$(ruleset_id_by_name "$repo" "Review gates")
    if [ -z "$review" ]; then
      echo "$repo: REFUSING — 'Review gates' absent; apply review first"
      continue
    fi
    if [ "$dry" = "--dry-run" ]; then
      echo "[dry-run] $repo: would DELETE 'Primary Rules' ($legacy); 'Review gates' ($review) present"
      continue
    fi
    gh api "repos/$ORG/$repo/rulesets/$legacy" \
      > "${TMPDIR:-/tmp}/primary-rules-$repo.json"
    gh api -X DELETE "repos/$ORG/$repo/rulesets/$legacy"
    echo "$repo: deleted 'Primary Rules' ($legacy) — backup in ${TMPDIR:-/tmp}/primary-rules-$repo.json"
  done
}

case "${1:-preflight}" in
  preflight)     preflight ;;
  apply)         shift; apply "$@" ;;
  enforce)       shift; enforce "$@" ;;
  verify)        verify ;;
  delete-legacy) shift; delete_legacy "$@" ;;
  *)             die "unknown command: $1" ;;
esac
