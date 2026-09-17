# Reusable workflow callers

Each file here is a thin caller for a shared workflow that lives in
[`.github/workflows/`](../workflows/). The shared workflows carry the
implementation; the callers carry only the trigger wiring and any
project-specific overrides. Adopting a shared workflow in a new repository
is a copy-and-edit of the matching caller.

## Files

| Caller | Shared workflow | Trigger |
|---|---|---|
| [`nc-review.caller.yml`](nc-review.caller.yml) | `nc-review.yml` | `pull_request_target: opened`, `issue_comment`, `workflow_dispatch` |
| [`release.caller.yml`](release.caller.yml) | `release.yml` | `push: main` |
| [`update-badges.caller.yml`](update-badges.caller.yml) | `update-badges.yml` | `schedule`, `release: published`, `workflow_dispatch` |
| [`duplicate-issue.caller.yml`](duplicate-issue.caller.yml) | `duplicate-issue.yml` | `issues: opened, edited`, `workflow_dispatch` |
| [`first-time-contributor.caller.yml`](first-time-contributor.caller.yml) | `first-time-contributor.yml` | `pull_request_target: closed`, `workflow_dispatch` |

## Adopting `first-time-contributor` in a new package repo

1. **Set the secret.** The shared workflow pushes to a different repository
   than the one it runs in, and the default `GITHUB_TOKEN` only reaches the
   calling repo. A PAT with `contents: write` and `pull-requests: write` on
   `Nano-Collective/.github` is required.

   Set it once as an ORGANISATION secret named `PAT_TOKEN` with visibility
   "all". The same secret already covers `update-badges.yml`; no new
   credential needs to be created.

2. **Drop the caller.** Copy
   `templates/first-time-contributor.caller.yml` into the new repo at
   `.github/workflows/first-time-contributor.yml`. The defaults assume the
   target is `Nano-Collective/.github` and the file is `contributors.json`,
   which is what every current package repo wants.

3. **Create the registry file** in `Nano-Collective/.github` at
   `contributors.json` with an empty JSON array (`[]`). The workflow will
   create it on first run if it is absent, but committing it explicitly
   avoids the first-contributor PR also being a "create file" PR — easier
   to review.

## What the workflow writes

Each onboarding PR adds one entry to `contributors.json`, sorted by login
(case-insensitive):

```json
[
  {
    "github": "octocat",
    "profile": {
      "login": "octocat",
      "name": "The Octocat",
      "bio": "GitHub mascot. Likes commits.",
      "avatar_url": "https://avatars.githubusercontent.com/u/583231?v=4",
      "html_url": "https://github.com/octocat",
      "blog": "https://octocat.dev",
      "company": "@github",
      "twitter_username": "octocat"
    },
    "first_pr": {
      "repo": "Nano-Collective/nanocoder",
      "number": 123,
      "url": "https://github.com/Nano-Collective/nanocoder/pull/123",
      "merged_at": "2026-09-17T10:30:00Z"
    }
  }
]
```

`profile` is fetched from `GET /users/{login}` at workflow time and matches
the field names the website's [`Contributor`](https://github.com/Nano-Collective/website/blob/main/lib/contributors.ts)
type already exposes (`name`, `bio`, `photo`, `github`, `website`). The JSON
is a source-of-truth for either a manual update to `lib/contributors.ts` or
a future refactor that has the contributors page read the JSON directly.

JSON because every other shared script here parses JSON. Markdown would be
nicer for humans and easier to render on a profile page, but it cannot be
updated atomically without a parser. Repos that want a markdown registry
can override `target-file-path` and add a follow-up workflow to render the
JSON into markdown — but the source of truth stays JSON.

If the GitHub profile fetch fails (rate limit, account suspended, etc.),
the workflow still records the contributor — `profile.name`, `profile.bio`,
etc. come back as `null`, and `profile.login` falls back to the event
payload's login. A contributor with no profile snapshot is still worth
recording.

## Idempotency

The workflow exits cleanly (no PR opened) when any of these are true:

- the PR author is a bot (`type == "Bot"`)
- the author already has a merged PR in `Nano-Collective/*`
- the author is already present in `contributors.json`
- an open onboarding PR for the same author already exists in the target
  repo

Re-running a `pull_request_target: closed` workflow on the same PR is safe:
each check above reads fresh data and the plan-then-write pattern means a
second successful run produces an identical result.