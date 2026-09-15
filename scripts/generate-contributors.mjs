#!/usr/bin/env node

/**
 * Print the "Contributors" section of a GitHub Release body.
 *
 *   node generate-contributors.mjs --tag v1.4.0 [--previous-tag v1.3.0] [--target <sha>]
 *
 * Requires `GITHUB_TOKEN` and `GITHUB_REPOSITORY` in the environment.
 *
 * The release body itself comes from CHANGELOG.md via `extract-changelog.mjs`,
 * which only credits someone when whoever wrote the changeset remembered to
 * type "Thanks to @someone" — so the credit depends on a human remembering, and
 * the people who most need crediting are first-time contributors, who are the
 * least likely to write their own thanks into their own changeset. prompt-scrub
 * v1.4.0 shipped one contributor's work under a release body that named nobody.
 *
 * This asks GitHub's own release-notes generator who authored the pull requests
 * in the tag range instead, so the credit does not depend on anyone remembering.
 *
 * **Never fails the release.** A release that has already published to npm must
 * not be held up because the credits could not be built, so every failure path
 * prints to stderr and exits 0 with nothing on stdout. The caller checks for
 * empty output and omits the section.
 *
 * **The tag usually does not exist yet.** It is created by the step that
 * publishes the release, which runs after this one, so `--target` supplies the
 * commitish the generator should resolve the range against. Without it the API
 * rejects the request for an unknown tag.
 */

const API = "https://api.github.com";

/** Accounts that author pull requests but are not people. */
const BOT_LOGINS = new Set([
  "changeset-bot",
  "copilot-swe-agent",
  "dependabot",
  "dependabot-preview",
  "github-actions",
  "renovate",
]);

function isBot(login) {
  return login.endsWith("[bot]") || BOT_LOGINS.has(login.toLowerCase());
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i]?.replace(/^--/, "");
    if (key) args[key] = argv[i + 1];
  }
  return args;
}

async function api(path, token, init = {}) {
  const response = await fetch(`${API}${path}`, {
    ...init,
    headers: {
      accept: "application/vnd.github+json",
      authorization: `Bearer ${token}`,
      "x-github-api-version": "2022-11-28",
      ...(init.body ? { "content-type": "application/json" } : {}),
    },
  });
  if (!response.ok) {
    throw new Error(
      `${init.method ?? "GET"} ${path} failed: ${response.status} ${response.statusText}`,
    );
  }
  return response.json();
}

async function tagExists(repo, tag, token) {
  try {
    await api(`/repos/${repo}/git/ref/tags/${encodeURIComponent(tag)}`, token);
    return true;
  } catch {
    return false;
  }
}

/**
 * Pull the authors and first-time contributors out of GitHub's generated notes,
 * whose lines are shaped like:
 *
 *   * Some change by @octocat in https://github.com/owner/repo/pull/1
 *   * @octocat made their first contribution in https://github.com/owner/repo/pull/1
 *
 * A `[bot]` suffix falls outside the login character class, so `@github-actions[bot]`
 * never matches in the first place. `BOT_LOGINS` is for the accounts that appear
 * without the suffix.
 */
function parseContributors(notes) {
  const authors = new Set();
  const firstTimers = new Set();

  for (const [, login] of notes.matchAll(/ by @([A-Za-z0-9-]+) in https/g)) {
    if (!isBot(login)) authors.add(login);
  }
  for (const [, login] of notes.matchAll(
    /@([A-Za-z0-9-]+) made their first contribution/g,
  )) {
    if (!isBot(login)) {
      authors.add(login);
      firstTimers.add(login);
    }
  }

  const byName = (a, b) => a.toLowerCase().localeCompare(b.toLowerCase());
  return {
    authors: [...authors].sort(byName),
    firstTimers: [...firstTimers].sort(byName),
  };
}

/** "a", "a and b", "a, b and c" */
function joinMentions(logins) {
  const mentions = logins.map((login) => `@${login}`);
  if (mentions.length <= 1) return mentions.join("");
  return `${mentions.slice(0, -1).join(", ")} and ${mentions.at(-1)}`;
}

function formatSection({ authors, firstTimers }) {
  if (authors.length === 0) return "";

  const lines = [
    "### Contributors",
    "",
    `This release shipped thanks to ${joinMentions(authors)}.`,
  ];
  if (firstTimers.length > 0) {
    lines.push(
      "",
      `First-time contributors: ${joinMentions(firstTimers)}. Welcome, and thank you!`,
    );
  }
  return lines.join("\n");
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const token = process.env.GITHUB_TOKEN;
  const repo = process.env.GITHUB_REPOSITORY;

  if (!args.tag) throw new Error("--tag is required");
  if (!token) throw new Error("GITHUB_TOKEN is not set");
  if (!repo) throw new Error("GITHUB_REPOSITORY is not set");

  const body = { tag_name: args.tag };
  if (args.target) body.target_commitish = args.target;
  // Left unset when the previous tag is missing — a first release, or a version
  // published to npm without a matching tag — so the generator picks the range
  // itself rather than the request failing outright.
  if (
    args["previous-tag"] &&
    (await tagExists(repo, args["previous-tag"], token))
  ) {
    body.previous_tag_name = args["previous-tag"];
  }

  const notes = await api(`/repos/${repo}/releases/generate-notes`, token, {
    method: "POST",
    body: JSON.stringify(body),
  });

  const section = formatSection(parseContributors(notes.body ?? ""));
  if (section) console.log(section);
  else console.error("No contributors found for this range; skipping section.");
}

main().catch((error) => {
  console.error(`Could not build contributors section: ${error.message}`);
  process.exit(0);
});
