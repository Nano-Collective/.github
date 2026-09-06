#!/usr/bin/env node

/**
 * Validate that every changeset names a real workspace package.
 *
 * `.changeset/*.md` files declare their target in YAML frontmatter:
 *
 *   ---
 *   "@nanocollective/nanocoder": patch
 *   ---
 *
 * A name that does not resolve to a workspace package passes the pull request
 * checks and then breaks `release-prepare` on every subsequent push to main
 * with "Found changeset <slug> for package <name> which is not in the
 * workspace". The Version Packages pull request stops updating and no release
 * can be cut until somebody notices. nanocoder#1065 did exactly that; #1077
 * added the first version of this check.
 *
 * Deliberately narrower than `changeset status`, which also exits non-zero when
 * packages changed and no changeset was added. That is a policy the collective
 * does not want enforced — `changeset-check` is a non-blocking nudge on purpose
 * — and `changeset status` additionally needs a local `main` ref, which CI's
 * detached checkout does not have.
 *
 * Empty changesets (`changeset add --empty`, the chore convention) declare no
 * packages and are valid.
 *
 * Usage: node validate-changesets.mjs [repo-root]
 *   repo-root defaults to the current working directory, so this can be run
 *   from a checkout of Nano-Collective/.github against any repository.
 */

import {readdirSync, readFileSync, existsSync} from 'node:fs';
import {join, resolve} from 'node:path';

const root = resolve(process.argv[2] ?? process.cwd());

/**
 * Workspace globs from pnpm-workspace.yaml.
 *
 * Parsed with a regex rather than a YAML library so this script has no
 * dependencies and can run before `pnpm install`. Only the shapes actually used
 * across the collective are supported: a `packages:` block of `- entry` lines,
 * where an entry is either a literal path or a single trailing `*`.
 */
function workspaceGlobs() {
	const file = join(root, 'pnpm-workspace.yaml');
	if (!existsSync(file)) return ['.'];

	const text = readFileSync(file, 'utf8');
	const block = text.match(/^packages:\s*\r?\n((?:\s*-\s.*\r?\n?)+)/m);
	if (!block) return ['.'];

	const globs = block[1]
		.split(/\r?\n/)
		.map(line => line.trim())
		.filter(line => line.startsWith('- '))
		.map(line => line.slice(2).trim().replace(/^["']|["']$/g, ''))
		.filter(Boolean);

	return globs.length > 0 ? globs : ['.'];
}

/** Directories a glob expands to, relative to the repo root. */
function expand(glob) {
	if (!glob.includes('*')) return [glob];

	const prefix = glob.replace(/\/?\*+$/, '');
	const dir = join(root, prefix);
	try {
		return readdirSync(dir, {withFileTypes: true})
			.filter(entry => entry.isDirectory())
			.map(entry => join(prefix, entry.name));
	} catch {
		// A declared workspace directory that does not exist is not our concern.
		return [];
	}
}

/** Every package name declared anywhere in the workspace. */
function workspacePackageNames() {
	const names = new Set();
	for (const glob of workspaceGlobs()) {
		for (const dir of expand(glob)) {
			try {
				const {name} = JSON.parse(
					readFileSync(join(root, dir, 'package.json'), 'utf8'),
				);
				if (name) names.add(name);
			} catch {
				// A workspace entry without a readable manifest is not our concern.
			}
		}
	}
	return names;
}

/**
 * Package names declared in one changeset's frontmatter.
 *
 * The frontmatter is the block between the first two `---` fences. Entries are
 * `"name": bump`; the name may be double-quoted, single-quoted, or bare.
 */
function declaredPackages(contents) {
	const match = contents.match(/^---\r?\n([\s\S]*?)\r?\n?---/);
	if (!match) return [];

	return match[1]
		.split(/\r?\n/)
		.map(line => line.trim())
		.filter(line => line && !line.startsWith('#'))
		.map(line => line.match(/^(?:"([^"]+)"|'([^']+)'|([^:]+?))\s*:/))
		.filter(Boolean)
		.map(parts => (parts[1] ?? parts[2] ?? parts[3]).trim());
}

const changesetDir = join(root, '.changeset');
if (!existsSync(changesetDir)) {
	console.log('No .changeset directory; nothing to validate.');
	process.exit(0);
}

const known = workspacePackageNames();
if (known.size === 0) {
	console.error(
		'Could not resolve any workspace package names. Check pnpm-workspace.yaml ' +
			'and that package.json files are readable.',
	);
	process.exit(1);
}

const files = readdirSync(changesetDir)
	.filter(file => file.endsWith('.md') && file !== 'README.md')
	.sort();

const problems = [];
for (const file of files) {
	const contents = readFileSync(join(changesetDir, file), 'utf8');
	for (const name of declaredPackages(contents)) {
		if (!known.has(name)) problems.push({file, name});
	}
}

if (problems.length > 0) {
	console.error('Changesets naming packages that are not in the workspace:\n');
	for (const {file, name} of problems) {
		console.error(`  .changeset/${file} declares "${name}"`);
	}
	console.error(
		`\nWorkspace packages: ${[...known].sort().join(', ')}` +
			'\n\nThis would break `changeset version` on main. Fix the package name.',
	);
	process.exit(1);
}

console.log(
	`Checked ${files.length} changeset${files.length === 1 ? '' : 's'} against ` +
		`${known.size} workspace package${known.size === 1 ? '' : 's'}; ` +
		'every declared package resolves.',
);
