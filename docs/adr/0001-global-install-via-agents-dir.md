# 0001 — Install globally through `~/.agents/skills/`

## Status

Accepted.


> **日本語の要約** — スキルはグローバルに1箇所（`~/.agents/skills/`）だけ置き、Claude Code へは symlink を張る。**Cursor は `~/.agents/skills/` をネイティブに読む**ことが実機で確認できたので、`~/.cursor/skills/` へのリンクは作らない（作っても二重登録されないが、買うものが何も無い）。プロダクトリポジトリには1ファイルも置かないという絶対制約から、配布はグローバル一本になる。

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

## Resolved, 2026-07-28: no `~/.cursor/skills/` link

This was an open question. It is now settled by observation in Cursor, which was the only way to
settle it.

Two things were visible in Cursor's skill menu:

- **`/codebase-design` appeared**, and it has no `~/.cursor/skills/` entry — it exists only under
  `~/.agents/skills/` and `~/.claude/skills/`. So **Cursor reads `~/.agents/skills/` natively**, which
  had been an assumption taken from the upstream CLI's behaviour rather than something checked.
- **`/da-review-all` appeared once**, despite being reachable from both `~/.agents/skills/` and
  `~/.cursor/skills/`. So Cursor does not double-list a skill reachable by two paths.

That inverts the reasoning that kept the link. It was retained because "a silent absence is worse
than a duplicate menu entry" — but there is no absence to guard against, so the link buys nothing and
writes into a directory we have no reason to touch.

> **Note, 2026-07-28.** `find-skills` and `codebase-design`, cited above as evidence, were uninstalled
> later that day (ADR 0005). The observations stand — they were made while both were installed — but do
> not expect to reproduce them with those two skills. The conclusion has a practical consequence worth
> knowing: because `~/.agents/skills/` is what Cursor reads, `npx skills remove` leaving a directory
> there means a skill can be gone from Claude Code and still live in Cursor.

`setup.sh` no longer creates it, and removes any it created before, matching what the upstream
`skills` CLI does. Only Claude Code gets a link, because Claude Code is the one that needs one.

If a future Cursor stops reading `~/.agents/skills/`, the symptom is skills vanishing from its menu
while `setup.sh status` still reports them installed. The fix is to restore the second link in
`link_skill`.

**A second observation worth recording**, because it strengthens ADR 0003 beyond what that ADR
claims: the Cursor session was running **GPT-5.6**, not a Claude model. So "behaviour lives in the
body, not the frontmatter" is not only about which YAML keys get parsed — the prose in these skills
is read and executed by a different model family entirely. A constraint expressed as an instruction
survives that; a constraint expressed as a Claude-specific frontmatter key was never going to.

## Alternatives rejected

**Claude Code plugin marketplace.** The official answer for sharing skills across repositories, and
genuinely better on versioning. Rejected for two reasons: Cursor does not support plugins at all, and
plugins namespace skills as `plugin:skill`, which breaks `da-review-all`'s by-name dispatch to its layer
references.

**Copying into each product repo.** A pattern seen in the wild: the same skills duplicated under
`.claude/` and `.cursor/`, drifting apart with no sync script and nothing reporting the drift.
Copies drift; links cannot.
