#!/usr/bin/env bash
#
# probe-role-ids.sh — resolve RepositoryRole bypass actor_id -> role name.
#
# The REST API returns bypass actors as bare integers and GitHub does not
# document the base-role ids. GraphQL *does* expose repositoryRoleName, so this
# creates a deliberately inert ruleset per candidate id, reads the name back,
# and deletes it again.
#
# Inert by construction: evaluate mode, scoped to a branch pattern that matches
# nothing, carrying a single rule. It cannot gate anything while it exists.
#
# Ids below `write` are rejected by the API with "Actor base role does not have
# write permissions", so each candidate is tried in its own request -- one bad
# id in a batch would fail the whole batch.
#
# Usage:
#   ./probe-role-ids.sh              # sweep the default candidates
#   ./probe-role-ids.sh 6 7 8        # specific ids
#
set -euo pipefail

ORG="Nano-Collective"
REPO=".github"
CANDIDATES=("$@")
[ ${#CANDIDATES[@]} -eq 0 ] && CANDIDATES=(1 2 3 4 5 6 7 8 9 10 11 12)

probe_one() {
  local id="$1" rid name payload
  payload=$(jq -nc --argjson id "$id" '{
    name: "ROLE ID PROBE - delete me",
    target: "branch",
    enforcement: "evaluate",
    conditions: { ref_name: { include: ["refs/heads/__no_such_branch__"], exclude: [] } },
    bypass_actors: [ { actor_id: $id, actor_type: "RepositoryRole", bypass_mode: "always" } ],
    rules: [ { type: "non_fast_forward" } ]
  }')

  rid=$(printf '%s' "$payload" \
    | gh api -X POST "repos/$ORG/$REPO/rulesets" --input - --jq '.id' 2>/dev/null) || {
    printf '  %-4s rejected\n' "$id"
    return 0
  }
  case "$rid" in ''|*[!0-9]*) printf '  %-4s rejected\n' "$id"; return 0 ;; esac

  name=$(gh api graphql -f query="
    {
      repository(owner: \"$ORG\", name: \"$REPO\") {
        rulesets(first: 50) {
          nodes {
            databaseId
            bypassActors(first: 10) { nodes { repositoryRoleName } }
          }
        }
      }
    }" --jq "
      .data.repository.rulesets.nodes[]
      | select(.databaseId == $rid)
      | .bypassActors.nodes[0].repositoryRoleName // \"?\"
    " 2>/dev/null)

  gh api -X DELETE "repos/$ORG/$REPO/rulesets/$rid" >/dev/null 2>&1 \
    || echo "  WARNING: probe ruleset $rid left behind — delete manually" >&2

  printf '  %-4s = %s\n' "$id" "${name:-?}"
}

echo "probing RepositoryRole ids on $ORG/$REPO..."
for id in "${CANDIDATES[@]}"; do probe_one "$id"; done
echo
echo "leftover probe rulesets (should be none):"
gh api "repos/$ORG/$REPO/rulesets" \
  --jq 'if length==0 then "  (none)" else .[]|"  \(.id) \(.name)" end'
