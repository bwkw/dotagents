# Which mechanism, and why

Claude Code and Cursor both offer several ways to change how the agent behaves. They are not
interchangeable, and picking the wrong one is how a rule ends up written down somewhere it is never
enforced.

This document records the official guidance, with sources, and the two places this toolkit deviates
from it. It exists because "should this be a skill or a hook" came up often enough to be worth
answering once.

Sources, all read 2026-07-28:

- [Extend Claude Code — features overview](https://code.claude.com/docs/en/features-overview)
- [Extend Claude with skills](https://code.claude.com/docs/en/skills)
- [Skill authoring best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices)
- [Steering Claude Code: when to use CLAUDE.md, skills, hooks, and subagents](https://claude.com/blog/steering-claude-code-skills-hooks-rules-subagents-and-more)
- [Agent Skills — Cursor](https://cursor.com/docs/skills) · [Subagents](https://cursor.com/docs/subagents) · [Hooks](https://cursor.com/docs/hooks)

---

## The decision, in one table

The official framing is a set of **triggers** rather than a taxonomy — you pick by what just happened,
not by what category the thing feels like it belongs to.

| What happened | What to add |
|---|---|
| The agent gets a convention wrong twice | Put it in `AGENTS.md` |
| You keep typing the same prompt to start a task | A skill you invoke by name |
| You have pasted the same playbook a third time | A skill |
| You keep copying data from something the agent cannot see | An MCP server for the connection, and a skill for how to use it well |
| A side task floods the conversation with output you will not reread | A subagent |
| You want something to happen **every time, without asking** | A hook |
| A second repository needs the same setup | A plugin, then a marketplace |

The single most useful line in the official docs is the one that decides hook-versus-anything-else:

> Put guardrails in hooks. An instruction like "never edit `.env`" in CLAUDE.md or a skill is a
> request, not a guarantee.

A skill is read and interpreted. A hook runs. If a rule has to hold on a bad day, it is a hook.

## What each one costs

| Mechanism | Loads | Cost |
|---|---|---|
| `AGENTS.md` | every session | every request, always |
| Skill **description** | every session | every request, for every installed skill |
| Skill **body** | when invoked | stays in context for the rest of the session; never re-read |
| Subagent | when spawned | isolated — the reading stays in its context |
| Hook | on its event | zero, unless it returns output |
| MCP server | session start | tool names only; schemas on demand |

Two consequences that drive most of this repository's decisions:

**Every installed skill taxes every other one.** Descriptions share a listing budget of **1% of the
model's context window**. On overflow, Claude Code "drops descriptions starting with the skills you
invoke least" — so an unused skill does not merely sit there, it degrades the auto-invocation of the
ones you do use, silently. `verify-skills.sh` targets 8,000 characters, which is roughly 1% of a 200K
window; the real budget scales with the model, and `/doctor` reports the actual figure.

**A skill body is a recurring cost, not a one-off.** Once invoked it stays for the session and is
never re-read, so guidance meant to apply throughout must be written as standing instruction rather
than as a step. After auto-compaction only the first ~5,000 tokens of each are restored. Hence
`reference/`: detail loads on demand, and costs nothing until read.

---

## Commands are skills now

There is no commands-versus-skills decision to make. Official, verbatim:

> **Custom commands have been merged into skills.** A file at `.claude/commands/deploy.md` and a skill
> at `.claude/skills/deploy/SKILL.md` both create `/deploy` and work the same way. Your existing
> `.claude/commands/` files keep working. Skills add optional features: a directory for supporting
> files, frontmatter to control whether you or Claude invokes them, and the ability for Claude to load
> them automatically when relevant.

Commands are not deprecated — the language is "merged", "keep working", "Skills are recommended" — but
there is **no documented case where a bare `commands/*.md` is preferable**. It is a skill with fewer
options, kept for compatibility. Cursor's commands documentation page is now a 404.

So this repository has no `commands/` directory, and adding one would be a step backwards.

### The two kinds of skill

What used to be the command-versus-skill question is now one frontmatter field.

| | Model-invoked (default) | You-invoked (`disable-model-invocation: true`) |
|---|---|---|
| You type `/name` | yes | yes |
| The model picks it | yes | **no** |
| Another skill calls it by name | yes | **no** |
| Description in context | yes | **no — zero budget cost** |

Official guidance on when to set it:

> Use `disable-model-invocation: true` for skills with side effects. This saves context and ensures
> only you trigger them. … You don't want Claude deciding to deploy because your code looks ready.

So: **side effects, or you always type it anyway.** Not for reference knowledge, where automatic
invocation is the entire value.

The trap is the third row. It blocks programmatic `Skill` calls and subagent preloading, not just
automatic invocation — so setting it on something another skill dispatches to breaks that dispatch
**with no error**. Two skills here can never have it, and both the lint hook and `verify-skills.sh`
enforce it (see ADR 0005):

- **`da-verify`** — the only thing that runs `gate.sh arm`. Without automatic invocation the Stop gate
  never arms and passes every turn: the guardrail opens.
- **`da-review-backend` / `da-review-frontend` / `da-review-infra`** — `da-review-all` dispatches to them by name.

`user-invocable: false` (in context, hidden from the menu) is **not used here**: no skill on this
machine is background knowledge rather than a workflow, and Cursor ignores the field, which would make
it a Claude-only behaviour difference — the class of thing ADR 0003 exists to prevent.

---

## Cursor reads a subset of all of it

Both agents are first class here, so the binding constraint is whatever Cursor understands.

| | Claude Code | Cursor |
|---|---|---|
| Skills | `~/.claude/skills/`, follows symlinks | `~/.agents/skills/` natively, plus `.cursor/`, `.claude/`, `.codex/` |
| Skill frontmatter | many fields | **`name`, `description`, `paths`, `disable-model-invocation`, `metadata` only** |
| `name` must match the directory | no | **yes** |
| Subagents | `~/.claude/agents/` | reads `.claude/agents/` too; fields are `name`, `description`, `model`, `readonly`, `is_background` |
| Hooks | `settings.json`, PascalCase events | `hooks.json`, camelCase events, **incompatible** |
| Always-loaded context | `CLAUDE.md` | `AGENTS.md` or `.cursor/rules` |
| Commands | legacy | documentation page removed |

Everything else in a Claude Code `SKILL.md` — `allowed-tools`, `argument-hint`, `context: fork`,
`model`, `when_to_use` — is simply absent in Cursor, with nothing reporting it. Hence the rule in
`AGENTS.md`: **strip every Claude-only field and the skill must still behave the same.** Constraints
go in the body as prose; frontmatter is optimisation on top. The same applies to subagents, which is
why both agent definitions here state their read-only constraint in the body as well as in `tools:`.

`${CLAUDE_SKILL_DIR}`, `$ARGUMENTS` and `!`command`` interpolation are Claude Code extensions. Where a
skill depends on one, that dependence needs to be survivable in Cursor.

---

## Where this repository deviates

Two places, both deliberate.

**`verify-skills.sh` hardcodes an 8,000-character budget** where the real one scales with the model.
The number is a reverse-engineered approximation of 1% of a 200K window, and there is a known upstream
issue about the budget being computed against a fixed baseline rather than the actual context window.
A fixed target that is occasionally too strict is more useful than no target; `/doctor` is the source
of truth.

**`skillOverrides` is not used**, though it is the official non-destructive way to suppress a skill
(`on` / `name-only` / `user-invocable-only` / `off`). It lives in Claude Code's `settings.json`, which
Cursor does not read, so every entry would make the two agents disagree about which skills are active —
and `/da-skills-audit` reads files rather than settings, so it could not see the divergence it created.
Suppression here means uninstalling, which is symmetric and visible from both agents.
