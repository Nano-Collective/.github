# Maintaining a Nano Collective project

This is for people with merge rights. It is not the contributor guide — each
repository has its own `CONTRIBUTING.md` for that.

It exists because the merge bar used to live in one person's head. Since 1 June,
`will-lamerton` merged 331 of 399 pull requests while authoring 6. That was not
a policy, it was a consequence of how the repositories were configured, and it
is what the current setup was built to end. The gates are now automated and
merge rights are broad — which only works if the judgement behind them is
written down.

So this document is mostly *reasoning*. Where it gives a rule, it tries to say
why.

---

## What is already decided for you

Six checks must be green before anything merges to `main`. You cannot merge past
them and neither can anyone else at `maintain`:

```
pr-checks / Linting
pr-checks / Type Checks
pr-checks / Format Checks
pr-checks / Unused Dependencies
pr-checks / Unit Tests & Coverage Analysis
pr-checks / Verify Build
```

Three more run and report but never block: **Package Audit**, **Semgrep**,
**CodeQL**. They depend on upstream advisory feeds, so a disclosure landing
overnight must not stop an unrelated bug fix. They tell you something is wrong;
they do not hold the queue hostage while you fix it. Read them, act on them
separately.

Review requirements are a *second* ruleset: one approval plus code-owner review,
which anyone at `maintain` bypasses. That split is deliberate. GitHub does not
let an author approve their own pull request, so any approval requirement routes
a prolific author's work through someone else — which is precisely the
bottleneck this replaced. Bypass is all-or-nothing per ruleset, so the two
concerns had to be separated to make the test gate absolute while letting
maintainers merge their own work.

**The practical consequence: your judgement is not needed on formatting, types,
lint, unused dependencies, or whether the suite passes.** Do not spend attention
there. Spend it on what follows.

---

## What is actually yours to judge

### Do the tests prove anything?

The coverage gate proves lines were executed. It cannot tell you whether a test
would fail if the behaviour regressed, and that is the only property that
matters.

Real example from this repository: a test named *"Discovery file failure does not
abort server start"* captured `rename`, never substituted it, and left
`realRename; // referenced only to silence unused-locals` behind. The publish
path was never made to fail. The suite went green, coverage counted the lines,
and the test proved nothing about the case in its own name.

Ask: what would have to break for this test to go red? If the answer is
"nothing", the test is decoration. That is worth blocking on, and it is the
single most common real defect that survives all six checks.

`Unit Tests & Coverage Analysis` is currently ~19 of the ~29 check failures
across the open queue, so this is also where contributors need the most help.

The floor is 80% with fail-on-drop. `nanotune` is pinned at 71 **temporarily**,
with an issue tracking the gap, and is held out of the quality ruleset until it
reaches 80. Treat a pinned floor as debt, not as the standard: fail-on-drop
means it can only ratchet upward from there.

### Does it do what the issue asked — all of it?

If a pull request says "Closes #N", merging it closes #N. Anything the issue
asked for that the diff does not do is then silently lost, because nobody
returns to a closed issue.

A partial fix is not automatically wrong — it is wrong to *close the issue* with
it. Either get the rest, or ask the author to drop the closing keyword so the
remainder survives.

### Is the scope the scope?

A bug fix that also renames twenty variables is harder to review, harder to
revert, and conflicts with everything else in flight. Ask for the refactor
separately. This is not pedantry: with a queue this size, a conflicting
drive-by refactor can cost more time than the fix saved.

### Does it duplicate work already in flight?

With 60+ open pull requests, two people solving the same problem is common and
nearly invisible. This is the thing a human reviewer is least likely to catch and
the thing that wastes the most contributor goodwill when missed. Check before
merging anything non-trivial.

### Should this change exist?

Maintainer attention is the scarcest resource here. A pull request that should
not have been opened costs it whether or not the code is correct.

Be careful and fair with this one. Small changes from first-time contributors
are how people start, and "this is small" is not a reason to reject anything.
The question is whether the change is *justified* — a real problem, not already
solved elsewhere in the codebase, not churn against working code. Where it is
justified but simply undiscussed, that is a conversation, not a rejection.

### Is there a changeset, if users would notice?

User-facing changes need one. Internal refactors, CI changes, test-only changes
and documentation do not. Getting this wrong means a released version with no
changelog entry explaining it.

---

## `nc-review`

An automated reviewer runs on pull-request open and applies one label:

| Label | Meaning |
|---|---|
| `agent:clean` | nothing raised |
| `agent:comments` | findings, none blocking |
| `agent:needs-work` | at least one blocking finding |

It covers the same ground as the sections above — correctness, security, tests,
issue resolution, duplicates, scope. **It is advisory and it is not always
right.** Read its findings; do not treat the label as a verdict. Maintainers can
re-run it with a `/re-review` comment.

If a comment says nc-review could not produce a verdict, that is the agent
failing, not the contribution. Re-run it or ignore it.

---

## Bypassing the gates

Organisation admins can bypass the quality ruleset. This is break-glass: broken
CI at midnight, a revert that has to land now.

**It should be rare, and right now it is not.** 19 of the last 20 rule-suite
evaluations on `nanocoder` are `bypass` rather than `pass` — a legacy of the old
arrangement where one admin merged everything under bypass. That number is the
baseline. If it stays high, the gate is decorative and we have rebuilt the old
problem with better tooling.

If you find yourself reaching for bypass regularly, the gate is wrong, not the
situation. Fix the gate.

---

## Traps that have cost real time

These are all things that look like a broken workflow and are not.

**A conflicting pull request runs no checks at all.** GitHub cannot compute a
merge ref, so `pull_request` workflows never fire — while `pull_request_target`
ones still do, which makes it look as though CI is broken. The branch needs a
rebase; nothing else will help.

**Checks do not re-run when `main` moves.** A fix that landed after the pull
request was opened is not picked up until `main` is merged into the branch.

**Pull requests targeting a branch other than `main` get no checks whatsoever.**
The workflow is scoped `branches: [main]` and the rulesets target the default
branch. `nanocoder` currently has several open pull requests into
`feature/new-ui` with zero verification. The eventual feature→`main` pull request
*is* checked, so nothing unverified reaches `main` — but do not assume anything
merged into a feature branch was vetted.

**First-time contributors need their workflow run approved** before CI starts. An
unapproved run reports nothing, which looks identical to a passing-but-silent
pull request and blocks the merge indefinitely. Anyone at `maintain` can approve.

**A fix to the shared workflow is not picked up by re-running.** Reusable
workflows resolve at run creation. Push a new commit.

**`semgrep` is not on bare runners.** It needs the `semgrep/semgrep` container;
calling `pnpm test:security` from an ordinary job fails.

**Local clones drift badly.** Always `git fetch` and check
`git rev-list --left-right --count HEAD...origin/main` before branching. One
clone was 393 commits behind, producing a 35-file conflicting pull request from a
one-line change.

---

## Things that have actually broken, and what they teach

**A dependabot bump broke the VS Code extension build for weeks.** Tailwind v4
moved its CLI into `@tailwindcss/cli`. The pull-request checks only verified the
committed `.vsix` still existed, not that it could still be built, so nothing
caught it — and `release.yml` builds the extension, so the next release would
have failed. *Green checks prove what they test, not what you assume they test.*

**A bad package name in a changeset broke `release-prepare` on every push to
main.** `changeset-check` asserts a changeset *file* exists; it never checked the
name inside resolved to a real package. A validator was added afterwards.
*Verify the release path end to end, not just that the ceremony was performed.*

**`json-up`'s `release.yml` was silently broken** by its pnpm migration — `npm
ci` with no lockfile. No check covered it, and it was found only by reading the
file. Its last release was April. *A pipeline nobody runs is a pipeline nobody
knows is broken.*

---

## Repository-specific notes

**`nanocoder`** — much the largest queue. Has a local `vscode-extension` job and
changeset validation on top of the shared checks; that split is intended, shared
checks central and repo-specific work local. Architecture and direction decisions
sit with `will-lamerton`; merge rights do not.

**`nanotune`** — 71.6% coverage against a pinned floor of 71, so it is held out
of the quality ruleset until it reaches 80. It carries the review ruleset only.
Do not treat the pinned floor as the standard.

**`nanoterm`** — was the other repo below the bar; it is now at 90.56% against a
floor of 80 and has met the standard. It carries **no rulesets at all** and
should be brought into both.

**`sentinel`** — becoming the collective's conformance checker. Its
`release.yml` publishes on merge to `main` when `package.json` is ahead of npm,
so it does not need changesets to cut a release.

**`json-up`** — `CODEOWNERS` names `@mrspence` as sole owner of everything.
Sole ownership is a bottleneck of the kind this document exists to remove, and
adding a second owner is an outstanding action.

**Five of seven package repositories have no changesets at all.** Until that is
fixed, releasing them is whatever manual process exists.

---

## When to say no

Closing a pull request is a real cost to the person who wrote it. But leaving one
open for months is worse — it reads as indifference rather than a decision.

Say no when the change is not wanted, and say why in a sentence. Say "not like
this" when the idea is right and the implementation is not, and be specific about
what would change your mind. Both are kinder than silence.

If you are unsure whether something is wanted, that is a question for
`will-lamerton`, not a reason to leave it in the queue.

---

## Related

- Each repository's `CONTRIBUTING.md` — the contributor-facing rules
- [`rulesets/`](rulesets) — the two rulesets, as applied
- [`scripts/README.md`](scripts/README.md) — how the gates are deployed, and the
  organisation settings that cannot be set over the API
