# 0003 — Behaviour lives in the body, not the frontmatter

## Status

Accepted.


> **日本語の要約** — **Cursor が読む frontmatter は `name` / `description` / `paths` / `disable-model-invocation` / `metadata` だけ**で、それ以外は拒否ではなく**黙って無視**される。だから規則は「Claude 専用フィールドを全部剥がしてもスキルは同じ挙動をしなければならない」。制約は本文に散文で書き、frontmatter はその上の最適化として扱う。`disable-model-invocation` の全面禁止はこの ADR 内で ADR 0005/0006 に修正されている。

## Context

Claude Code supports a large skill frontmatter: `allowed-tools`, `disallowed-tools`, `context: fork`,
`agent`, `model`, `effort`, `hooks`, `argument-hint`, `arguments`, `user-invocable`, `shell`.

Cursor supports four fields: `name`, `description`, `paths`, `disable-model-invocation`. The rest are
ignored — not rejected, ignored. A skill that encodes a constraint in `allowed-tools` is unconstrained
in Cursor, and nothing says so.

Both agents are first-class targets here, so the failure has to be designed out rather than documented.

## Decision

**Strip every Claude-only field, and the skill must still behave the same.**

Constraints are written in the body as instructions:

| Instead of | Write in the body |
|---|---|
| `allowed-tools:` omitting Edit/Write | "**This skill never modifies source code.**" |
| `context: fork` | "Run this in a subagent. Do not execute it inline in the main context." |
| `model:` / `effort:` | Nothing — a preference, not a mechanism. |

Claude-only frontmatter stays, but only as optimization on top of behaviour the body already
guarantees. `verify-skills.sh` flags any skill whose body does not restate its frontmatter constraints.

**`disable-model-invocation` is never set.** It blocks programmatic `Skill` invocation, subagent
preloading, and scheduled-task triggering — not just model auto-invocation. `da-review-all` dispatches to
its layer references by name, so setting it converts the dispatcher into a silent no-op.

> **Amended by ADR 0005 (2026-07-28).** The blanket ban was over-general, and the sentence above is the
> second time this invariant's stated justification has been wrong — ADR 0004 corrected it once already.
> Official guidance *recommends* the field for side-effectful workflows and for anything you always
> invoke by name, and it is the only way to make a skill cost zero description budget.
>
> The rule is now **never on something reached by name**: `da-verify` (the only thing that arms the gate)
> and `x-review-backend` / `x-review-frontend` / `x-review-infra` (dispatch targets). Everything else may set
> it; `da-pr-describe` does. Note that this field is one of the four Cursor *does* understand, so unlike
> the rest of this ADR's subject matter it behaves identically in both agents.

## Consequences

- Skills read as prose rather than configuration. That is a feature: the agent is a reader, and a
  sentence in the body is enforced by both agents while a YAML key is enforced by one.
- Claude loses a little enforcement strength — an instruction is softer than a tool restriction. The
  trade is accepted, because a constraint enforced in one agent and absent in the other is worse than
  a constraint enforced softly in both.

## Correction, 2026-07-28: Cursor's hooks

An earlier version of this ADR said Cursor had no Stop-hook equivalent. That was wrong, and the
correction matters because it changed what is enforceable.

[Cursor's hooks](https://cursor.com/docs/agent/hooks) include `stop`, and `preToolUse` supports a
`matcher`. So both guardrails run on both agents. They are **not equivalent in strength**:

| | Claude Code | Cursor |
|---|---|---|
| Event | `Stop` | `stop` |
| Input | `cwd`, `hook_event_name`, … | `{status, loop_count}` — no `cwd` |
| Can block? | **Yes** — `exit 2` refuses to end the turn | **No** |
| Weaker mechanism | — | `{"followup_message": "…"}` auto-submits a message so the agent keeps going, capped by `loop_limit` (default 5) |
| Reply shape for `preToolUse` | `hookSpecificOutput.permissionDecision` | `permission` / `user_message` / `agent_message` |

Both hooks now detect the caller and answer in the right dialect: `hook_event_name` is present only
on Claude Code, and the `stop` payload is recognised by `loop_count`.

Two consequences worth stating plainly:

- **Cursor's gate can be walked past.** A follow-up message is a strong nudge; it is not a refusal.
  The user can stop the agent with checks red. This is documented in `README.md` and in the `da-verify`
  skill rather than glossed over.
- **We stop injecting at `loop_count >= 3`**, below Cursor's limit of 5. Consuming the whole budget
  would leave the user with an agent that will not settle and no explanation for why.

Cursor 2.5 also [added Plugins](https://cursor.com/changelog/2-5), packaging skills, subagents, MCP
servers, hooks, and rules together. That removes the first of the two reasons ADR 0001 gives for
avoiding plugin packaging. The second — that namespacing breaks by-name dispatch — still stands, and
the manifest format was not documented in what we could read. Revisit when it is.

## Precedent

The command this skill grew out of already worked this way. Before being retired to
`~/.claude/retired-commands-<date>/`, `review-all.md` declared "this command is read-only: it never
modifies code, only reports findings" in its body, and noted that skills run on the main thread so
invocations proceed in order. It had been in daily use in that form, which is why the pattern was
carried over rather than invented here.
