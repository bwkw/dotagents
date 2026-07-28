# 0001 — Install globally through `~/.agents/skills/`

## Status

Accepted.

## Context

The toolkit has to be usable from every repository, in both Claude Code and Cursor, without adding
files to product repositories.

The two agents look in different places:

- Claude Code reads `~/.claude/skills/` and `.claude/skills/`. It does **not** read `.agents/skills/`.
- Cursor reads `~/.cursor/skills/`, `.cursor/skills/`, and — since 2.4 — `~/.agents/skills/` and
  `.agents/skills/` natively.

Claude Code documents that a skill entry may be a symlink to a directory elsewhere on disk, that it
follows the link, and that a target reachable from more than one location is loaded once.

## Decision

Keep one physical copy in `~/.agents/skills/<name>` (itself a symlink into this repository) and point
both `~/.claude/skills/<name>` and `~/.cursor/skills/<name>` at it.

Install globally only. Do not install per-project.

## Consequences

- Editing a file in this repository takes effect in both agents immediately, with no sync step.
- No product repository is touched, so nothing to reconcile, no drift, no migration.
- `~/.agents/skills/` already works this way for `find-skills`, so the mechanism is proven on this
  machine rather than assumed.
- Project-scoped skills are out of reach by construction. That is intended: a personal toolkit that
  needs per-repo installation is a per-repo change, which this design rules out.

## Open question: the `~/.cursor/skills/` link

The `skills` CLI installs to `~/.agents/skills/`, symlinks `~/.claude/skills/` for Claude Code, and
labels Cursor **"universal"** — creating no `~/.cursor/skills/` link at all, on the basis that Cursor
reads `~/.agents/skills/` natively. (An older install of `find-skills` from January does have a
`~/.cursor/skills/` link, so this looks like a deliberate upstream change once Cursor gained native
support.)

`setup.sh` still creates the `~/.cursor/skills/` link. The two failure modes are not symmetric:

- If Cursor reads both locations, our skills appear **twice** in its menu. Cosmetic.
- If Cursor does not read `~/.agents/skills/` and we skipped the link, our skills are **silently
  absent** in Cursor. Functional, and silent.

Belt-and-braces wins when one branch is cosmetic and the other is a silent absence. Revisit after
confirming in Cursor which way it actually behaves: if entries appear twice, drop the
`~/.cursor/skills/` link from `link_skill` and match the CLI.

## Alternatives rejected

**Claude Code plugin marketplace.** The official answer for sharing skills across repositories, and
genuinely better on versioning. Rejected for two reasons: Cursor does not support plugins at all, and
plugins namespace skills as `plugin:skill`, which breaks `review-all`'s by-name dispatch to its layer
references.

**Copying into each product repo.** A pattern seen in the wild: the same skills duplicated under
`.claude/` and `.cursor/`, drifting apart with no sync script and nothing reporting the drift.
Copies drift; links cannot.
