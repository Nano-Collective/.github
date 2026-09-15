# Org deployment scripts

The organisation is on the GitHub **Free** plan, which has no org-level
rulesets. These scripts are the replacement: they apply the same configuration
to every repository, and are what you re-run when a repository drifts or a new
one is created.

All of them are read-only by default or support `--dry-run`. None of them
require anything beyond `gh auth login` with `repo` scope, except where noted.

## `sync-rulesets.sh`

Applies the two rulesets in [`../rulesets/`](../rulesets) to each package repo.

```bash
./sync-rulesets.sh preflight               # readiness report, read-only
./sync-rulesets.sh apply quality --dry-run
./sync-rulesets.sh apply quality           # goes out in `evaluate` mode
./sync-rulesets.sh enforce quality         # evaluate -> active
./sync-rulesets.sh verify
./sync-rulesets.sh delete-legacy           # remove the superseded "Primary Rules"
```

**Run `preflight` before enforcing anything.** It reports how many of the six
required checks actually report on each repo, and how many workflow runs are
stuck awaiting approval. Enforcing a ruleset whose checks never report makes
every pull request in that repo permanently unmergeable.

### The two rulesets

| | `quality.json` | `review.json` |
|---|---|---|
| Rules | six required status checks, non-fast-forward, no deletion | 1 approval, code-owner review, thread resolution, Copilot review |
| Bypass | organisation admin **only** | organisation admin **+ `maintain`** |
| Effect | the test gate is absolute for maintainers | maintainers merge without waiting for an approval |

They are deliberately separate. Bypass is all-or-nothing per ruleset, so a
single ruleset carrying both concerns would either route every maintainer's work
through a second person, or let them merge failing tests. Splitting gives both
properties at once.

## `drain-stuck-runs.sh`

Approves workflow runs held at `action_required`. Runs from outside
contributors wait for a manual approval, and a run that is never approved
reports no checks at all.

Approves only the **newest** stuck run per branch, and only for branches with an
open pull request — older runs are for superseded commits.

## `retrigger-checks.sh`

Fires checks on open pull requests that have never reported. Pull requests that
predate a workflow change do not re-run when the base branch moves, so nothing
ever triggers them. Closes and immediately reopens each one, which fires
`pull_request: reopened` without touching the contributor's branch.

Skips conflicting pull requests: GitHub cannot compute a merge ref for them, so
`pull_request` workflows do not fire at all and reopening achieves nothing.

## `probe-role-ids.sh`

Resolves `RepositoryRole` bypass `actor_id` values to role names. Kept because
GitHub does not document these ids, the REST API returns bare integers, and
**they are not ordered by privilege**:

| actor_id | role |
|---|---|
| 2 | maintain |
| 4 | write |
| 5 | admin |

Every other id is rejected with *"Actor base role does not have write
permissions"* — only write-and-above can be a bypass actor. Role names are
exposed via **GraphQL** (`repositoryRoleName`), not REST.

Re-run it if a bypass appears not to apply to the role you expected.

## `extract-changelog.mjs`

Prints one version's section of `CHANGELOG.md`, for the GitHub Release body.
Invoked by the shared `release.yml`, which checks this repository out into
`.nc-shared/` on the repo being released — so the script resolves paths from
`process.cwd()`, not from its own location.

```bash
node scripts/extract-changelog.mjs            # version from package.json
node scripts/extract-changelog.mjs 1.2.3      # explicit
CHANGELOG_ROOT=../some-repo node scripts/extract-changelog.mjs
```

It lives here rather than in each package repo because it used to live in each
package repo. Six of them carried the same two bugs, and the copies were only
ever noticed when a seventh received one — CodeQL flags a copied file as new in
the repo that receives it and as nothing at all in the ones that already had it.

Both bugs are worth knowing about, because both were silent:

- **Section boundaries were found with `(?=\n##+ )`**, which also matches
  `###`. A changesets changelog opens every version with `### Patch Changes`, so
  the capture terminated on the first line of the body, came back empty, and the
  script exited `0` having printed nothing.

  **This hit any repo whose CHANGELOG.md is raw changesets output.** In practice
  that was `sentinel`, whose release bodies were blank under "What's Changed"
  until 2026-09-08. The others were spared by accident rather than design:
  `nanocoder` post-processes its changelog into plain bullets, `get-md` and
  `prompt-scrubber` hand-write theirs without a sub-heading directly under the
  version, and `nanotune` links out to the file instead. Any of them adopting
  the changesets default would have started producing empty release notes with
  nothing to say so.

  Boundaries are now found by walking lines and comparing heading depth.
- **The version was interpolated into a pattern with only `.` escaped**, so
  `1.0.0(` threw `Invalid regular expression: Unterminated group` — failing a
  release *after* the package was already on npm. The version is no longer put
  into a pattern at all.

## `generate-contributors.mjs`

Prints the `### Contributors` section of a GitHub Release body. Invoked by the
shared `release.yml` from `.nc-shared/`, same as the extractor above.

```bash
GITHUB_TOKEN=$(gh auth token) GITHUB_REPOSITORY=Nano-Collective/prompt-scrubber \
  node scripts/generate-contributors.mjs --tag v1.4.0 --previous-tag v1.3.0
```

```
### Contributors

This release shipped thanks to @akramcodez.

First-time contributors: @akramcodez. Welcome, and thank you!
```

It exists because the release body comes from `CHANGELOG.md`, which credits
someone only when whoever wrote the changeset remembered to type *"Thanks to
@someone"*. That makes the credit depend on a human remembering, and the people
who most need crediting are first-time contributors, who are the least likely to
write their own thanks into their own changeset. `prompt-scrub` v1.4.0 shipped
one contributor's entire feature under a release body that named nobody.

Rather than parse the git log, it asks GitHub's own release-notes generator
(`POST /releases/generate-notes`) who authored the pull requests in the range,
which is also where the first-time-contributor determination comes from.

Two things worth knowing:

- **It never fails a release.** Every failure path prints to stderr and exits
  `0` with nothing on stdout; the workflow omits the section when the output is
  empty. By the time the body is composed the package may already be on npm, and
  a release must not be held up because the credits could not be built.
- **The tag does not exist yet when it runs.** It is created by the step that
  publishes the release, so `--target <sha>` supplies the commitish to resolve
  the range against. `--previous-tag` is dropped when that tag is missing — a
  first release, or a version published to npm without a matching tag — and the
  generator picks the range itself.

Bots are excluded two ways: a `[bot]` suffix falls outside the login character
class so `@github-actions[bot]` never matches at all, and `BOT_LOGINS` covers
the accounts that appear without the suffix.

This was lifted from `nanocoder`, which had it as a repo-local script while the
six repos on the shared workflow had nothing. `nanocoder` does not call the
shared `release.yml` (it has its own, which publishes a VS Code extension and
updates a Homebrew formula), so its copy stays where it is — but it is the same
logic, and a fix to one should go to the other.

## Things the REST API cannot do

Two organisation settings are **UI-only**. Both silently appear to succeed or
return 404 rather than erroring usefully:

- **Fork pull request workflow approval** — `/orgs/{org}/actions/permissions/fork-pr-workflows`
  returns 404. Set it at Settings → Actions → General.
- **2FA enforcement** — `two_factor_requirement_enabled` is read-only. `PATCH`ing
  it returns `200` and silently ignores the field. Set it at
  Settings → Authentication security.

Enabling 2FA enforcement **removes** any member who does not have 2FA, so check
`/orgs/{org}/members?filter=2fa_disabled` is empty first.
