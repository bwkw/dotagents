# dotagents

Personal AI development toolkit. Skills, hooks, and repo profiles that work in **both Claude Code and Cursor**, installed once globally and available in every repository.

This file is the always-loaded layer. `CLAUDE.md` is a symlink to it (Claude Code does not read `AGENTS.md`).

## Layout

| Path | Contents |
|---|---|
| `skills/` | Own skills. One directory per skill, `SKILL.md` inside. `_shared/` holds files referenced by several skills. |
| `profiles/` | Per-repository verification config, resolved by git remote. Product repos stay untouched. |
| `hooks/` | Hook scripts. Installed as **real copies**, never symlinks (see below). |
| `templates/` | Settings snippets merged key-by-key into `~/.claude/settings.json` and `~/.cursor/hooks.json`. |
| `scripts/` | `setup.sh` (install/status/uninstall/doctor), `verify-skills.sh` (lint). |
| `_template/` | Skill template. The `_` prefix excludes it from installation. |
| `docs/adr/` | Why decisions were made. Read before changing an invariant. |

## Install

```bash
scripts/setup.sh install          # add --dry-run first
scripts/setup.sh status
scripts/setup.sh doctor
```

Skills land in `~/.agents/skills/<name>` and are reachable from `~/.claude/skills/<name>` and
`~/.cursor/skills/<name>`. Cursor reads `~/.agents/skills/` natively; Claude Code follows the symlink.

Third-party skills are **not** vendored here. They are installed separately:

```bash
npx skills add obra/superpowers -g -a claude-code -a cursor
npx skills add mattpocock/skills -g -a claude-code -a cursor
```

## Invariants

These are load-bearing. Breaking one fails silently rather than loudly.

1. **Every skill must work with `name` and `description` alone.**
   Cursor understands only `name`, `description`, `paths`, `disable-model-invocation`. Everything else
   (`allowed-tools`, `context: fork`, `model`, `argument-hint`) is silently dropped. So state the
   constraint in the body — "this runs in a subagent", "never modify source code" — and treat
   Claude-only frontmatter as optimization, never as the mechanism. `verify-skills.sh` checks this.

2. **Never set `disable-model-invocation`.**
   It blocks far more than model auto-invocation: programmatic `Skill` calls, subagent preloading,
   and scheduled-task triggering. `review` dispatches to its layer references by name, so setting
   this turns the dispatcher into a no-op with no error.

3. **Hooks are copied, not symlinked.**
   A dangling symlink makes the hook exit 127, which Claude Code treats as non-blocking — the
   guardrail *opens* instead of *closing*. Copies cannot dangle.

4. **Reference files are addressed via `${CLAUDE_SKILL_DIR}`.**
   It expands to an absolute path, so subagents resolve it regardless of cwd. Relative paths break.

5. **Product repositories are never modified.**
   Anything repo-specific lives in `profiles/`, keyed by git remote.

6. **No secrets in this repository.**
   `setup.sh` merges only the keys listed in `templates/`, and never reads or rewrites existing
   values it did not write.

## Writing a skill

Start from `_template/`. Required sections, in order:

- **Preconditions** — a table of what must hold. Each row states what to do when it does not:
  stop immediately, report which condition failed, do not continue.
- **Position in the workflow** — upstream / this skill / downstream.
- **Files to read** — two tables, "always read" and "read only if". State plainly that reading
  everything "just in case" is forbidden.
- **Read-only declaration** — investigation and review skills say, in bold, that they never modify
  source code.
- **Evidence discipline** — only what was directly verified; cite `path/to/file.ts:L42`; when there
  is no basis, say so rather than guessing; separate fact from inference; attach URLs for external
  claims.

Keep `SKILL.md` at or under 12 KB. Skill bodies stay in context until the session ends and are not
re-read; after auto-compaction only the first ~5,000 tokens of each skill are restored. Long material
belongs in `reference/`, loaded on demand.
