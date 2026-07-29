# 0006 — One review entry, and designing against the real command surface

- **Status**: accepted, 2026-07-29
- **Partially reverses**: ADR 0004 (the three layer reviews as typed entry points)
- **Narrows**: ADR 0005 Decision 4 (no `skillOverrides`)


> **日本語の要約** — レビューの入口を `da-review-all` の**1つに統合**（層別3本は `user-invocable: false` でメニューから消し、モデルからは呼べるまま）。そして**面の実数が 24 ではなく 75** だったことを記録: 40本は CLI バイナリにコンパイル済みでファイルとして存在せず、11本はサーバ管理プラグイン。過去の主張を3つ訂正している —— ① 使用実績データは存在した（読み取り失敗だった） ② `skillOverrides` 却下はバンドルスキルには当てはまらない（Cursor に存在しないので乖離しない） ③ 自己選好バイアスの根拠は過剰だった。

## Context

Two rounds of pruning took the skill set from 35 to 24 and the resident description budget from 6,905 to
3,559 characters. The complaint that started it — *there are too many and I cannot tell what to use* —
did not go away, and this ADR records why: **the number being pruned was wrong.**

The real surface is **75 invocable names**:

| Source | Count | Where |
|---|---|---|
| On disk (9 ours, 15 upstream) | 24 | `~/.agents/skills/` |
| `anthropic-skills@inline` plugin | 11 | `~/Library/Application Support/Claude/local-agent-mode-sessions/skills-plugin/…` |
| **Compiled into the Claude Code binary** | 40 | no files exist — registered as string constants inside the CLI |
| **Total** | **75** | 46 of them listed to the model in a typical session |

Two earlier inventories missed 51 of these because they read the filesystem, and 40 of them are not on
the filesystem. Compounding it: **two Claude Code installations exist on this machine**, and the one
serving the session is not the one on `$PATH` — mise shims `claude` to **2.1.148** while Claude Desktop
runs its own downloaded **2.1.219**. The bundled skills and two of the control settings exist only in the
newer one.

## Three corrections to earlier decisions

Recorded first, because the decisions below depend on them.

### 1. "Usage data proves nothing" was wrong

ADR 0005 said the pruning had no usage evidence because 34 of 35 skills were installed the same day.
The first half was a reporting error: `~/.claude.json` → `skillUsage` is a map of
`{usageCount, lastUsedAt}` per name, and a script that failed to read it was mistaken for absent data.

| Name | Invocations | Note |
|---|---|---|
| `workflow-code-review` | 199 | a project skill in another repository — the actual primary review tool |
| `update-pr-description` | 77 | the retired command now shipped as `da-pr-describe` |
| **`code-review`** | **42** | **bundled, and in real use** |
| `review-backend` | 40 | retired → `da-review-backend` |
| **`review`** | **24** | **bundled, and in real use** |
| `review-frontend` / `review-all` / `review-infra` | 7 / **6** / 4 | |
| `security-review` | 1 | barely used; its earlier removal was right |

Two things this changes. **The bundled reviewers are not dead weight** — 66 invocations between them.
And **the layer reviews were the real entry point**, 51 invocations against 6 for the dispatcher, which
contradicted the README's claim that `da-review-all` was "the default".

The caveats still hold and are now written into `da-skills-audit`: keys carry no provenance, absence
means "never invoked by name" rather than "useless", and a count means nothing without the install date.

### 2. Rejecting `skillOverrides` was right for the wrong scope

ADR 0005 Decision 4 rejected it because it lives in Claude Code's `settings.json`, which Cursor does not
read, so every entry would make the two agents disagree — one of the seams `design.md` names as a source
of silent failure.

That reasoning is sound **for our own skills**, which exist in both agents. It does not apply to bundled
and plugin skills, which **do not exist in Cursor at all**. There is nothing to diverge from. The second
objection — that these would be hand-edited and untracked — is answered by going through
`templates/claude.settings.snippet.json`, since `setup.sh` merges key-scoped and reverts precisely.

### 3. The self-preference argument was overstated

ADR 0005's successor commit justified `refuted`-by-default with self-preference measured at 10–25%. That
finding is contested: sanity-check work pushes back, and one analysis attributes most of the effect to a
**flat per-reviewer disposition** rather than self-favouring, with ~2.8 points between strictest and most
lenient reviewer.

The rule stays; its justification changes, and so does a design consequence. If the lean is
per-reviewer rather than self-directed, then **a different framing buys more than a different instance** —
which is the argument for keeping a second, differently-built reviewer rather than treating our own as
sufficient. `_shared/finding-discipline.md` now says this.

## Decision 1 — `da-review-all` is the only review entry in the menu

`da-review-backend`, `da-review-frontend` and `da-review-infra` get `user-invocable: false`: out of the
`/` menu, still model-invocable so by-name delegation works.

**This partially reverses ADR 0004**, and it is safe because ADR 0004 fixed the right thing for a
differently-stated complaint. What had been lost then was the **tech-lead depth**, not the entry points;
the depth stays where it is. The trade being made now is 51 layer invocations' worth of direct typed
access for one menu entry instead of four.

The cost is smaller than the usage numbers suggest, because only the *typed* route closes. "Review the
backend" still matches the layer's description and fires it directly — `user-invocable` and
`disable-model-invocation` are different fields, and only the latter would block that.

Which is the new hazard, so it is enforced rather than documented: `verify-skills.sh` errors when
`user-invocable: false` appears on anything nothing dispatches to (reachable then only by description
match), and errors when it is combined with `disable-model-invocation` (unreachable by every route at
once). Five assertions in `test-lint-hook.sh`.

Cursor ignores `user-invocable`, so the three stay in its menu. That is a presentation difference, not a
behavioural one, which is the line ADR 0003 draws.

## Decision 2 — six suppressions, via managed `skillOverrides`

| Name | Setting | Why |
|---|---|---|
| `verification-before-completion` | `name-only` | Triggers nearly identical to `da-verify` — "before claiming complete", "before committing", "before opening a PR" — and both auto-fire. `name-only` drops only the competing description, so `systematic-debugging`'s by-name reference and the no-profile fallback survive |
| `claude-api` | `name-only` | Fires on any mention of Claude, Anthropic, Opus, Sonnet, `claude-*`, `[1m]`. In this repository that is every session |
| `anthropic-skills:schedule` | `off` | **Two live skills are literally named `schedule`.** Keeping the bundled one, which also covers cron and routines |
| `docx` `pptx` `xlsx` `pdf` | `name-only` | Long resident descriptions, extension-based triggers, no development-loop use. Budget reclaimed, still typable |
| `morning` `setup-cowork` | `off` | A personal brief and a one-time onboarding |

**Not suppressed, deliberately: `code-review`, `review`, `find-bugs`, `simplify`.** The usage data above
shows the first two in real use, and a measurement of four reviewers over the same 146 pull requests found
**93.4% of findings caught by exactly one of the four and none by all four**. Reviewer *diversity* beats
reviewer *quality*, so a second differently-built reviewer is the highest-value thing available;
suppressing it would be removing the part that works. `simplify` is the quality half of Anthropic's
deliberate quality/correctness split and this repository's reviews span both.

**`disableBundledSkills` is not used.** It removes all ~40 at once, including the four above, and it
exists only in 2.1.219+ — so an older `claude` on `$PATH` would ignore it silently. Per-name overrides are
right on both granularity and version portability.

## Decision 3 — the loop is documented in official vocabulary

`docs/workflow.md`, replacing a five-phase shape invented here. Official is three phases mechanically
(*gather → act → verify*) or four as a workflow (*Explore → Plan → Implement → Commit*), with **verify as
a cross-cutting property and review as an escalation, not a phase**. Worth stating because this
repository's largest investment is review machinery, and the guidance says to reach for it when a change
is risky or unwatched rather than after every diff.

The decision rules carried across because they are cheap and load-bearing: *if you could describe the
diff in one sentence, skip the plan*; a spec names its files and interfaces, states what is out of scope,
and ends with an end-to-end verification step; `/clear` and start a fresh session between plan and
implementation; two failed corrections then discard the session and rewrite the prompt.

## Decision 4 — the measurement gap was instrument-shaped, and the instruments exist

`design.md` called "nothing measures whether the skills work" the largest known gap. Wrong, in the same
way and for the same reason as the inventory: **`anthropic-skills:skill-creator` is installed** and runs
paired with-skill / without-skill benchmarks with pass rate, tokens and time, and **`/skill-doctor`** is
bundled and reports which loaded skills are unused and costing context.

So the gap is now smaller and more embarrassing: the instruments have not been run. First targets are the
calls made on judgement rather than evidence — `da-verify` against `verification-before-completion`,
`da-review-backend` against `find-bugs`, `da-review-all` against bundled `code-review`.

## Consequences

- One review entry in the menu; three layers of depth behind it; a linter check that makes the hiding
  mechanism impossible to combine into unreachability.
- Six names suppressed, tracked in the manifest, removed exactly by `uninstall`. Verified against the
  live settings: the plaintext Datadog key and all five hook registrations byte-identical, and a
  pre-existing user override with a different value left alone.
- `skillOverrides` is now used, narrowly. The rule is: **never on a skill that also exists in Cursor.**
- Three earlier claims corrected in place rather than quietly dropped. Two of the three were mine
  reporting badly on my own data, which is worth noticing as a pattern: both the inventory and the usage
  reading failed by trusting a script's silence.
- **Still unverified**: that Cursor picks up `~/.claude/agents/` (ADR 0005), and now also that the three
  layer skills remain reachable in Cursor's menu as expected. Both fail visibly rather than silently.
