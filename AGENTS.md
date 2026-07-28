# dotagents

Personal AI development toolkit. Skills, hooks, and repository profiles that work in **both Claude
Code and Cursor**, installed once globally. `CLAUDE.md` symlinks here, because Claude Code does not
read `AGENTS.md`.

Layout, installation, and the upstream skill list are in `README.md`. Why the toolkit has this shape
is in `docs/design.md`. This file holds only what you cannot get by looking.

## Invariants

Each of these fails **silently** when broken — nothing errors, nothing logs, and the tool appears to
work. That is why they are here rather than in a document you would read once.

1. **A skill must work with `name` and `description` alone.**
   Cursor understands `name`, `description`, `paths`, `disable-model-invocation`. Everything else —
   `allowed-tools`, `context: fork`, `model`, `argument-hint` — is silently dropped. State the
   constraint in the body ("this runs in a subagent", "never modify source code") and treat
   Claude-only frontmatter as optimization on top, never the mechanism. Cursor also runs a different
   model family, so the prose is what carries. `verify-skills.sh` checks this.

2. **Never set `disable-model-invocation`.**
   It blocks programmatic `Skill` calls and subagent preloading too, not just model auto-invocation.
   `review-all` dispatches to `review-backend`, `review-frontend`, and `review-infra` **by skill
   name**, so setting it on any of them turns that layer into a silent no-op — the dispatcher reports
   the layer as covered and reviews nothing. `verify-skills.sh` checks this.

3. **Frontmatter that a real YAML parser rejects still loads.**
   An unquoted `": "` in a description parses as a nested mapping. The skill appears in the menu with
   its description shown, and is broken. Quote the value or use an em dash.

4. **Hooks are copied, not symlinked.**
   A dangling symlink makes the hook exit 127, which Claude Code treats as non-blocking — the
   guardrail *opens* instead of closing. Copies cannot dangle. This also means editing a hook here
   has no effect until `setup.sh install` runs again.

5. **Reference files are addressed via `${CLAUDE_SKILL_DIR}`.**
   It expands to an absolute path, so a subagent resolves it whatever its cwd. A relative path
   silently fails there.

6. **The gate is inert until a skill arms it**, and `gate.sh arm` is the only thing that does.
   An armed gate with no matching profile passes every turn while reporting itself active; arming
   warns about that. `~/.claude/.dotagents-gate/trace.log` records every invocation and why it
   passed — read it before believing the gate did nothing.

7. **Every skill carries `metadata.source: bwkw/dotagents`.**
   Ours sit among two dozen third-party skills, and the difference decides what may be done: ours can
   be rewritten, an upstream one can only be installed or removed, because editing it in place is
   lost on the next `npx skills update`. Hooks prefix output with `[dotagents]` for the same reason.

8. **No secrets here.** `setup.sh` merges only the keys its templates declare and never reads or
   rewrites a value it did not write — the agent settings it edits contain other people's
   credentials.

## Sizes that bite

`SKILL.md` at or under 12 KB. A skill's body stays in context until the session ends and is never
re-read; after auto-compaction only the first ~5,000 tokens of each are restored, so anything past
that is silently lost. Detail belongs in `reference/`, loaded on demand.

Descriptions are resident permanently, all of them, always. Every skill added costs the selection
accuracy of every existing one. `/skills-audit` measures it.

## Adding upstream skills

**Always with `-s`.** `npx skills add <repo>` without it takes the whole repository and blows the
description budget in one command. The curated lists are in `README.md`.

## Writing a skill

Start from `_template/`, then `./scripts/verify-skills.sh`. Required sections, in order:

- **Preconditions** — a table of what must hold, each row saying what to do when it does not: stop,
  report which condition failed, do not continue. The linter checks this section exists.
- **Files to read** — split into "always" and "read only if". A skill that reads everything up front
  has spent the context its own work needs.
- **Read-only declaration** for anything that investigates or reviews.
- **Evidence discipline** — either in the body or delegated to a `reference/` file. Only what was
  verified directly; cite `path/file.ts:L42`; say "could not confirm" rather than guessing; keep fact
  and inference apart; attach URLs to external claims.
