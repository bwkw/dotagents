---
name: da-fix-plan
description: Turn a review report into an ordered fix plan on disk. Use after a code review or PR feedback, when there are more findings than you want to act on. Decides what NOT to fix and why, orders what remains by irreversibility and dependency, and writes the plan to a file. Read-only until the plan is agreed.
argument-hint: "[path to the review report | 'the review above'] (default: the report in this conversation)"
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
# Fix plan — <branch or PR>

**The change was for:** <one or two sentences>
**Source:** <which review(s), and how many findings>

## Fix now
| # | Finding | Location | The minimal fix | Order |
|---|---|---|---|---|

## Fix now, but smaller than proposed
| # | Finding | What was proposed | What is actually needed | Why the smaller version closes it |

## Follow-up
| # | Finding | Why it can wait | What the issue needs to say |

## Declined
| # | Finding | Reason |
|---|---|---|
| | | outside the spec / speculative / style preference / over-engineering / reviewer misread intent |

## Needs a decision
| # | Question | Who decides | What they need to decide it |

## Ordering and interactions
- Irreversible first: …
- Merged (same root cause): …
- Needs re-verification after an earlier fix: …
- Same-file conflicts to sequence: …

## Out of scope for this plan
<what this plan deliberately does not touch>

## Verification
<the command or check that proves the accepted set is done — this is what /da-verify runs>
```

## Step 5. Report the shape, not the contents

The file has the detail. In the conversation, say only:

- the counts per bucket, with **Declined stated as a number, not hidden**
- anything in **Needs a decision**, because that is the only part blocked on a human
- the first two or three items in order, so the next step is obvious

**If nothing was declined, say so and treat it as a warning sign.** Either the review was unusually
clean, or this pass transcribed instead of triaging. Both are worth knowing before acting on it.

## Done when

- [ ] Every finding is in exactly one bucket, and none was dropped
- [ ] Every Decline carries a reason from the list, not "low priority"
- [ ] Every 🔴-or-above Decline was checked against the code, not just the summary
- [ ] The order is justified by irreversibility and dependency, not by severity
- [ ] Fixes on the same root cause are merged, and conflicting ones are sequenced
- [ ] The plan is on disk, names its files, states what is out of scope, and ends with a verification step
- [ ] The declined count was reported out loud

## Guardrails

- **Read-only until the plan is agreed.** No code changes in this skill, even for a one-line fix that
  looks obvious — a fix made while planning is a fix nobody reviewed.
- Never create issues, comment on the PR, or push. The plan proposes; you decide.
- **Do not add findings.** If the review missed something, say so separately — folding your own findings
  into a triage pass makes it impossible to tell what the reviewer actually said.
