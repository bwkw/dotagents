# 0005 — Mechanism taxonomy, global subagents, and pruning to 24 skills

- **Status**: accepted, 2026-07-28
- **Amends**: ADR 0003 (the `disable-model-invocation` blanket ban)


> **日本語の要約** — 仕組みの分類（skill / command / subagent / hook / MCP）を公式ガイダンスに基づいて明文化し、**コマンドはスキルに統合済み**であることを記録。`disable-model-invocation` の全面禁止を**「名指し委譲の対象のみ禁止」**に絞る（`da-verify` はゲートを arm する唯一のものなので絶対禁止）。グローバル subagent 2本を定義し、**5ファイルにあった到達不能な分岐**（「リポジトリが専用エージェントを定義していれば」＝プロダクトリポに触らない制約下では永遠に成立しない）を解消。スキル11本を削除。

## Context

Thirty-five skills were installed, using 7,167 characters of description. The complaint that started
this was not about budget: *there are too many and I cannot tell how to use them.* Alongside that, the
repository had no written basis for choosing between a skill, a command, a subagent, a hook, and an
MCP server, so every addition was an ad-hoc judgement.

Reading the official guidance turned up three places where this repository was wrong, and looking for
usage data turned up a fourth problem with the obvious plan.

## What the guidance actually says

Recorded in full, with sources, in [`../mechanisms.md`](../mechanisms.md). The parts that changed a
decision here:

**Commands are skills.** "Custom commands have been merged into skills… Skills are recommended." There
is no documented case where a bare `commands/*.md` is preferable. A prompt template you type is spelled
as a skill with `disable-model-invocation: true`. So the absence of a `commands/` directory here is
correct, and the README now says why rather than leaving it to be discovered.

**`disable-model-invocation` is recommended, not forbidden.** For side-effectful workflows and for
anything you always invoke by name. It also removes the description from context entirely, making it
the only zero-budget option.

**The budget is 1% of the model's context window**, and on overflow Claude Code drops descriptions
starting with the skills invoked least. An unused skill therefore degrades the auto-invocation of the
used ones, silently. This is the real cost of keeping things installed — not disk, not clutter.

## Decision 1 — the `disable-model-invocation` ban is scoped, not blanket

ADR 0003 banned the field outright. That was over-general, and it is the second time this invariant's
justification has been wrong: ADR 0004 already found the stated reason false once. The correct rule is
**never on something reached by name**, because the field blocks programmatic `Skill` calls and
subagent preloading too, with no error.

Two skills can never have it:

| Skill | What breaks |
|---|---|
| `da-verify` | It is the only thing that runs `gate.sh arm`. Without auto-invocation the Stop gate never arms and passes every turn — the guardrail **opens**. |
| `x-review-backend` / `-frontend` / `-infra` | `da-review-all` dispatches to them by name; the dispatcher would report a layer as covered while reviewing nothing. |

Everything else may set it. Applied to `da-pr-describe` only: it writes to GitHub, it is always typed, and
nothing dispatches to it. That is the official textbook case, and it frees 241 characters.

Enforced in two places that must agree — the lint hook and `verify-skills.sh`. **The first version of
the linter check matched on `$id`, which is `skills/<name>`, so the bare `case` pattern never matched
and the check silently never fired.** It was installed and enforcing nothing, which is exactly the
failure this repository is about. `scripts/test-lint-hook.sh` now asserts the scope at both enforcement
points, in both hook dialects — 28 assertions, in CI.

## Decision 2 — two subagents, defined globally

Five files said "prefer a purpose-built agent when the repository defines one" and named
`senior-architect`, `ddd-expert`, `database-specialist`. But `design.md`'s hardest constraint is that
product repositories stay untouched — "a hard constraint, not a preference" — so **a repository will
never define an agent.** The preferred branch was unreachable. Every review, on every repository, has
silently taken the `general-purpose` fallback while the skills advertised a specialisation tier the
architecture forbids from existing.

Two agents, not eight — agent descriptions consume context in their own right, and adding a fleet to
fix a budget problem defeats itself. The bar is *`general-purpose` cannot satisfy the instruction*, not
*a specialist would be nicer*:

| Agent | Why a definition rather than a prompt |
|---|---|
| **`x-review-verifier`** | `verification.md` requires a verifier that did not take part in finding, and that returns `refuted` rather than `uncertain` when it cannot substantiate a claim. That posture has to hold *before* it reads anything. Passed in a prompt, it is a request. |
| **`x-codebase-explorer`** | Read-only tracing with `file:line` evidence, an explicit budget, and confirmed / inferred / not-confirmed kept apart. Used by `da-investigate`'s fan-out and every review's Step 2. |

Linked into `~/.claude/agents/`, which Cursor also reads, so one link covers both agents. Managed by
`setup.sh` with prune, uninstall, status and manifest support on the same footing as skills and hooks —
an unmanaged `~/.claude/agents/` would be invariant 4's problem in a new costume.

**Unverified:** that Cursor picks up `~/.claude/agents/`. The documentation says it reads
`.claude/agents/` and the home-directory equivalents, but this has not been observed here the way ADR
0001's skill path was. If an agent fails to resolve in Cursor, the fix is a second link into
`~/.cursor/agents/`; the symptom would be a visible fallback to `general-purpose`, not a silent
failure, which is why shipping on documentation alone is acceptable here.

## Decision 3 — eleven skills uninstalled, two of them wrongly

Kept: the basic development loop, the official-best-practice sets, and what was already in use.
Removed: specialist advisory skills, duplicates of what the harness now provides natively, and one
skill in direct behavioural conflict with our own.

Every by-name reference was checked before removing anything. Nine had no inbound references. The two
that did are kept **for that reason**: `brainstorming` (referenced by our own `da-design-review`, and by
`writing-plans`) and `using-git-worktrees` (by `writing-plans` and `executing-plans`).

| Removed | Reason |
|---|---|
| `find-skills` | 303 chars teaching `npx skills add` **without `-s`**, which AGENTS.md has an invariant against |
| `using-superpowers` | Mandates skill invocation "before ANY response including clarifying questions", which contradicts `da-investigate` and `da-design-review` — both of which refuse an unstated goal. It also hard-wires brainstorming → writing-plans, a funnel that structurally cannot reach `/grill-me` or `/da-design-review` |
| `observability-and-instrumentation`, `performance-optimization`, `deprecation-and-migration` | Specialist advisory, off the development loop |
| ~~`documentation-and-adrs`~~ | **Reinstated.** Cut as "specialist advisory" — writing an ADR is the *first step* of the design flow here, and this directory holds seven of them |
| `codebase-design`, `domain-modeling`, `improve-codebase-architecture` | A mutually-referencing set, removed together so no reference dangles |
| `dispatching-parallel-agents` | The harness provides parallel agents natively |
| ~~`research`~~ | **Reinstated.** Cut because "the harness has WebFetch", which confuses *having the tool* with *having the practice* |

**Two of these were wrong, in the same way, twice.** Both `documentation-and-adrs` and `research` were
cut against a guess at the development flow rather than the flow itself. Once the actual phases were
stated — external survey first, then ADR, then implementation — both turned out to sit on it. The
correction that matters is not the two reinstatements but the rule they produce:

> **Do not remove a skill against an assumed workflow.** Removal needs the flow stated by the person who
> uses it. Structural evidence — a dangling reference, a behavioural conflict, a duplicate of a native
> capability — is a reason to remove. "It looks off the loop to me" is not, and cost two reversals.

**One accepted dangling reference.** `executing-plans` names `using-superpowers`. It is upstream, so
editing it in place is lost on the next `npx skills update` (invariant 7). A stale name in one upstream
skill costs less than a behaviour conflict on every session. Its value moves to `AGENTS.md`, where the
official taxonomy puts a fact needed every session: check for an applicable skill, user instructions
outrank skills, and a skill's preconditions may require a question first.

Five descriptions shortened by dropping the posture clause — near identical across the three layer
reviews, so it carried no signal distinguishing them, and per ADR 0004 the posture is already inline in
each body. **The file vocabulary stays**: it is what routes `*.tf` to infra and `*.tsx` to frontend.

**Result: 35 skills → 24. Resident descriptions 6,905 → 3,559 characters.**

## Decision 4 — no `skillOverrides`

> **Narrowed by ADR 0006 (2026-07-29).** The reasoning below holds for *our own* skills, which exist in
> Cursor too. It does not hold for bundled and plugin skills, which do not exist in Cursor at all — there
> is nothing for them to diverge from. Six of those are now suppressed through
> `templates/claude.settings.snippet.json`, which also answers the "unmanaged and untracked" objection,
> since `setup.sh` merges key-scoped and reverts precisely. The standing rule is **never on a skill that
> also exists in Cursor.**

It is the official non-destructive suppression mechanism, and it was the obvious way to avoid deciding.
Rejected: it lives in Claude Code's `settings.json`, which Cursor does not read, so every entry makes
the two agents disagree about which skills are active — one of the two seams `design.md` names as a
source of silent failure. Worse, `/da-skills-audit` reads files rather than settings, so the tool that
exists to detect skill-state confusion could not see the confusion this created. Suppression here means
uninstalling, which is symmetric, visible from both agents, and reversible in one command.

## What this decision is not based on

> **Corrected by ADR 0006 (2026-07-29).** The claim below is half wrong. `skillUsage` *does* carry
> `usageCount` and `lastUsedAt` per name; a script that failed to read it was mistaken for missing data.
> The real figures show the bundled reviewers in active use (`code-review` 42, `review` 24) and the layer
> reviews as the actual entry point (51 invocations against 6 for the dispatcher). The install-date
> caveat below is the part that stands.

**There is no usage evidence.** `~/.claude.json` records skill usage, and 29 of the 35 had none — but
34 of the 35 were installed the same day this was written, so "never used" means "installed hours ago".
The one exception, `find-skills` (installed 2026-01-30), had been used, and was removed anyway on
structural grounds.

So every removal above rests on **structure** — a dangling reference, a behavioural conflict, a
duplicate of a native capability — or on the judgement that a skill is off the development loop. None
rests on measurement. That is a weaker basis than this repository asks for elsewhere, and it is stated
here rather than dressed up.

`OTEL_LOG_TOOL_DETAILS=1` is already set, so `skill_activated` events accumulate. Revisit in two weeks
with `skill.name` × `invocation_trigger`, remembering that Cursor emits none of it, so the sample is
Claude-only and the final call is a human's.

## Consequences

- The `commands`-versus-skills question has a written answer with a source, and the README says why
  there is no `commands/` directory.
- The `disable-model-invocation` invariant is now true as scoped, and asserted by tests rather than
  documented and hoped for.
- Every review now reaches a real verifier and a real explorer instead of falling through a dead branch
  to `general-purpose`.
- One upstream dangling reference exists on purpose, recorded above.
- `verify-skills.sh` checks agents as well as skills, and fails when a skill dispatches to an agent that
  does not exist.
- The gate's arming path is documented correctly in three places; `design.md` previously claimed the
  gate armed itself, and that error is what produced an earlier proposal to disable `da-verify`'s
  auto-invocation — which would have failed the gate open.
