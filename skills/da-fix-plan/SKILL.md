---
name: da-fix-plan
description: レビュー報告を、順序のついた修正計画のファイルにする。コードレビューや PR の指摘を受けた後、対応しきれないほど所見がある時に使う。直さないものとその理由を決め、残りを不可逆性と依存関係の順に並べ、計画をファイルに書く。計画に合意するまでは読み取り専用。
argument-hint: "[レビュー報告のパス | '上のレビュー']（省略時はこの会話の報告）"
allowed-tools: Read, Grep, Glob, Bash(git:*), Bash(gh:*), Write
metadata:
  source: bwkw/dotagents
---

# /da-fix-plan — decide what not to fix, then order the rest

A review produces findings. This turns them into a plan, and **its primary job is subtraction.**

> A reviewer prompted to find gaps **will report some even when the work is sound**, because that is
> what it was asked to do. Chasing every finding leads to over-engineering: extra abstraction layers,
> defensive code, and tests for cases that cannot happen.

So the failure this skill exists to prevent is not "a finding got missed". It is **acting on all of
them**. A plan that accepts every finding has not triaged; it has transcribed.

**Read-only until the plan is agreed.** Produce the plan, show it, and stop. Fixing happens after.

## Preconditions

| Condition | If unmet |
|---|---|
| A review report exists — in this conversation, at a path, or on a PR | **Stop.** Ask which review. Never plan against remembered findings. |
| You can tell what the change was *supposed* to do — a spec, a plan, a PR description, or the user saying so | **Ask.** Without it you cannot separate "the code is wrong" from "the reviewer wanted something else", and that distinction is most of the work here. |
| The findings carry locations | Continue, but mark any finding you cannot locate as **unactionable** rather than guessing at one |

## Position in the workflow

| Upstream | This skill | Downstream |
|---|---|---|
| `/da-review-all`, `/code-review`, `/find-bugs`, or a human review | `/da-fix-plan` | `/executing-plans` on the accepted set, then `/da-verify` |

Not the same as `/receiving-code-review`, which is about how to respond to *one* piece of feedback in a
conversation. This one takes a **whole report** and produces an ordered artifact on disk.

**When a bucket's outcome gets written back to the reviewer** — a Decline that needs explaining, a
correction to a finding that was partly wrong — the register for that is the responding half of
`profiles/review-voice.md`, and it is a different one from the reviewing half: lead with agreement or
with the correction, cite the commit, and **volunteer what is unfavourable to you**. `receiving-code-review`
is upstream and cannot be taught this durably, so the pointer lives here.

**This is the stopping condition for the review loop.** Reviewing until nothing is found does not
terminate — a reviewer asked for findings produces findings. What ends the loop is not a count of
rounds but **the Decline bucket**: deciding, on the record, which findings will not be fixed and why.
The gate has the same shape for checks (three attempts, then a `VERDICT` that says it gave up); this is
the shape for review. A loop with no Decline is a loop with no exit.

## Files to read

### Always read

| File | Why |
|---|---|
| the review report | the subject |
| the spec, plan, or PR description the change was written against | the line between a defect and a preference |
| `${CLAUDE_SKILL_DIR}/reference/finding-discipline.md` | the severity vocabulary the reports use, so triage matches how they were graded |

### Read only if

| File | Trigger condition |
|---|---|
| the code a finding names | before **accepting** anything above 🟡, and before declining anything at 🔴 or above |
| `CLAUDE.md`, `AGENTS.md`, `.claude/rules/*` | when a finding rests on a convention — the project's own rules decide it |

> Do not re-read the whole diff. The review already did that; this is a decision pass, not a second
> review. If you find yourself reviewing, stop — you are duplicating the upstream skill and will
> introduce findings the report did not make.

---

**Write the report in the language the user is writing in** (Japanese when that is unclear), keeping
paths, identifiers, commands, code excerpts and log output in their original form. These instructions are English because the model reads them; the report is read by
a person.

## Step 1. Restate what the change was for

One or two sentences, from the spec or PR description. Confirm it before triaging.

This is not ceremony. **Half of triage is comparing a finding against the intended scope**, and if the
intent is only in your head the comparison is unfalsifiable.

## Step 2. Sort every finding into exactly one bucket

Every finding lands in one of five. Nothing is left uncategorised, and **nothing is silently dropped** —
declining is a visible outcome with a reason attached.

| Bucket | Meaning |
|---|---|
| **Fix now** | Blocks the merge. Irreversible, a correctness defect on a reachable path, a security or tenancy hole, or a broken contract. |
| **Fix now, smaller** | The finding is real but the proposed remedy is bigger than the problem. Record the *minimal* change that closes it. |
| **Follow-up** | Real, not blocking. Needs an issue with enough context to act on later — otherwise it is not a follow-up, it is a decline in disguise. |
| **Decline** | Not acting, **with a reason**: outside the spec, speculative, a style preference, over-engineering, or the reviewer misread the intent. |
| **Needs a decision** | Not yours to call — a product question, an ordering constraint with another team, a trade-off the author should own. Name **who** decides and **what** they need. |

Three rules that make the buckets mean something:

- **A finding outside the spec goes to Follow-up or Decline, never Fix now** — unless it is a defect
  that ships regardless of scope. Scope creep enters through exactly this door.
- **`Nit:` findings default to Decline.** They were marked optional by the reviewer; treating them as
  work reverses that on purpose.
- **A 🔴 you want to decline must be checked against the code first.** Declining a severe finding on the
  strength of the summary alone is how a real bug gets closed as noise.

## Step 3. Order what remains, and say why the order

Not by severity. By what breaks if done in the wrong order:

1. **Irreversible first** — anything touching data, migrations, or a published contract. A later fix may
   change what the migration should have been, and by then it has run.
2. **Then fixes that change a shared interface**, before the callers that depend on it.
3. **Then the independent ones**, which can be batched into one commit.
4. **Last, anything that touches tests only.**

Then check for interaction, which is the part that gets skipped:

- **Does one fix make another unnecessary?** Merge them and say so. Two findings on the same root cause
  are one fix.
- **Does one fix invalidate another's premise?** Re-check the second *after* the first, and mark it as
  needing re-verification rather than fixing both against a state that will not exist.
- **Do two fixes touch the same lines?** Sequence them explicitly; do not let them be discovered as a
  conflict.

## Step 4. Write the plan to a file

Not to the conversation. It has to survive `/clear`, and it becomes the criterion `/da-verify` and the
next review are measured against.

Default path: `docs/fix-plans/<date>-<branch>.md`, unless the repository has its own convention — check
before inventing one. Follow the three properties of a useful plan: **name the files and interfaces
involved, state what is out of scope, and end with a verification step**.

```markdown
# 修正計画 — <ブランチまたは PR>

**変更の目的:** <1〜2 文>
**出どころ:** <どのレビューか、所見は何件か>

## 今すぐ直す（Fix now）
| # | 所見 | 場所 | 最小の修正 | 順番 |
|---|---|---|---|---|

## 今すぐ直す、ただし提案より小さく（Fix now, but smaller than proposed）
| # | 所見 | 提案された修正 | 実際に要るもの | 小さい方で塞がる理由 |

## 後で対応（Follow-up）
| # | 所見 | 待てる理由 | issue に書くべきこと |

## 直さない（Declined）
| # | 所見 | 理由 |
|---|---|---|
| | | spec の範囲外 / 推測 / 好みの問題 / 過剰設計 / レビュアーが意図を読み違えた |

## 判断が要る（Needs a decision）
| # | 問い | 誰が決めるか | 決めるのに要るもの |

## 順番と相互作用
- 不可逆なものを先に: …
- 統合した（根本原因が同じ）: …
- 先の修正の後に再検証が要る: …
- 同じファイルで衝突するので順番を決める: …

## この計画の範囲外
<この計画があえて触らないもの>

## 検証
<採用した修正が終わったことを示すコマンドやチェック。/da-verify が実行するもの>

## 採択率
<accepted N / total M = XX%>。前回の記録があれば併記する。
```

The bucket headings keep their English names in parentheses: `scripts/loop.sh` and the rest of this
file refer to the buckets by those names.

## Step 5. Report the shape, not the contents

The file has the detail. In the conversation, say only:

- the counts per bucket, with **Declined stated as a number, not hidden**
- anything in **Needs a decision**, because that is the only part blocked on a human
- the first two or three items in order, so the next step is obvious

**If nothing was declined, say so and treat it as a warning sign.** Either the review was unusually
clean, or this pass transcribed instead of triaging. Both are worth knowing before acting on it.

### The decline count is the only measurement of whether the reviewer is trusted

**Report it as a rate, not just a count**: accepted (Fix now + Fix now smaller + Follow-up) over total
findings. Write it into the plan file so it accumulates across reviews — one number from one review says
nothing, and this is the only place the number exists.

It is the industry's trust signal for an automated reviewer, and it reads in both directions:

| Acceptance rate | What it means |
|---|---|
| **below ~50%** | The reviewer is producing noise. **Do not tune the plan — tune the review.** More than half of what it raised was not worth acting on, and a reviewer at that rate gets routed around rather than read. |
| **~50–80%** | Working, worth reading, not worth gating on. |
| **above ~80%** | Trusted enough that a failing review could hold a merge. |
| **100%, repeatedly** | Not a good sign. Either this pass transcribed, or the review is only raising the safe and obvious. |

**A rate this skill never records is a rate nobody can act on.** That is the whole reason for the line —
the refutation pass already suppresses false positives before they reach a report, but nothing has ever
measured whether it worked.

## Done when

- [ ] Every finding is in exactly one bucket, and none was dropped
- [ ] Every Decline carries a reason from the list, not "low priority"
- [ ] Every 🔴-or-above Decline was checked against the code, not just the summary
- [ ] The order is justified by irreversibility and dependency, not by severity
- [ ] Fixes on the same root cause are merged, and conflicting ones are sequenced
- [ ] The plan is on disk, names its files, states what is out of scope, and ends with a verification step
- [ ] The declined count was reported out loud, **as a rate**, and written into the plan file

## Guardrails

- **Read-only until the plan is agreed.** No code changes in this skill, even for a one-line fix that
  looks obvious — a fix made while planning is a fix nobody reviewed.
- Never create issues, comment on the PR, or push. The plan proposes; you decide.
- **Do not add findings.** If the review missed something, say so separately — folding your own findings
  into a triage pass makes it impossible to tell what the reviewer actually said.
