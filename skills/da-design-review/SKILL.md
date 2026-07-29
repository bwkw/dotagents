---
name: da-design-review
description: Review a plan or spec before any code exists. Use when a design doc is ready, before implementation starts, or when asked whether an approach is sound. Catches one-way doors, migration order, and rollback. Read-only.
argument-hint: "[path to plan/spec] (default: the most recent plan under docs/)"
allowed-tools: Task, Read, Grep, Glob, Bash(git:*), Bash(gh:*), WebFetch
metadata:
  source: bwkw/dotagents
---

# /da-design-review — catch it while it is still cheap

Code review finds defects in an implementation. It cannot find that the implementation should never
have been built this way. By the time a diff exists, the expensive decisions — the migration
strategy, the contract shape, the deploy order — are already made, and the review that follows is
scoped to whether they were executed correctly.

This skill reviews the decisions themselves.

**This skill never writes code and never edits the plan.** It reports findings. Revising the plan is
a separate act, done deliberately.

## Preconditions

| Condition | If unmet |
|---|---|
| A plan, spec, or design document is identified | **Stop.** Ask which document to review. Never review an imagined plan. |
| The document describes changes to a codebase you can read | Continue, but say in 🔎 that you could not ground the claims in code |

## Position in the workflow

| Upstream | This skill | Downstream |
|---|---|---|
| `/research`, `/grill-me`, `/writing-plans` or an ADR | `/da-design-review` | revise, then `/executing-plans` |

## Files to read

### Always read

| File | Why |
|---|---|
| the plan or spec under review | the subject |
| `${CLAUDE_SKILL_DIR}/reference/finding-discipline.md` | posture and reporting rules; passed to every subagent |
| `${CLAUDE_SKILL_DIR}/reference/design-checklist.md` | the review dimensions |

### Read only if

| File | Trigger condition |
|---|---|
| `${CLAUDE_SKILL_DIR}/reference/verification.md` | entering the refutation pass (Step 5) |
| `${CLAUDE_SKILL_DIR}/reference/silent-failure-patterns.md` | when the plan introduces a fallback, a shared default, or an irreversible action — `verification.md` sends you here, and it is listed at this level so it is not reached only through another reference |
| `${CLAUDE_SKILL_DIR}/reference/report-format.md` | when writing the report, for bucketing and presentation |
| `CLAUDE.md`, `AGENTS.md`, `.claude/rules/*` | if the repository has them — the project's own conventions are the standard |
| the code the plan names | always for the high-risk claims; see Step 2 |

> Reading everything "just in case" is forbidden.

---

## Step 1. Restate the plan in your own words

Before critiquing anything, write what you understand the plan to do, in three to five sentences:
what changes, why, and in what order.

**Show this to the user.** A misread plan produces confident, irrelevant findings, and this is the
cheapest possible place to catch that. If the plan is too vague to restate, that is itself the first
finding — stop and report it.

## Step 2. Ground the plan in the actual code

A plan review that only reads the plan is a proofread. The value is in the gap between what the plan
assumes and what the code actually does.

For each of the plan's load-bearing claims — "this table is append-only", "no other caller depends on
this", "the frontend already handles a missing field" — **open the code and check**, citing
`file:line`. When you cannot confirm one, that is a finding, not a footnote.

Budget: **25 files**. On reaching it, stop and record what you did not verify. An unbounded
"investigate the codebase" burns the context you need for the actual review.

## Step 3. Review across the dimensions

Read `${CLAUDE_SKILL_DIR}/reference/design-checklist.md` and work through it.

For a substantial plan, dispatch the dimensions to **parallel subagents**, one per dimension group,
launched in a single message. Pass each the plan, the Step 2 findings, and the contents of
`finding-discipline.md`. **Run this in subagents rather than inline in the main context** — the
checklist and the code excerpts are bulky, and inline they would crowd out the synthesis.

For a small plan (a handful of files, nothing irreversible), work through it directly.

## Step 4. The question one level up

Separately from the checklist, always ask:

- **Should this be built at all?** Is there a simpler approach that gets most of the value?
- **Is the plan solving the stated problem**, or a nearby, more interesting one?
- **What does the plan assume will stay true?** Name the assumptions and mark which are load-bearing.
- **What is missing entirely** — a rollback path, a migration for existing data, a story for
  in-flight requests during deploy, the operational signal that says it worked?

Absence is the hardest thing to review and the most common source of production surprise. A checklist
finds what is wrong with what is written; only this step finds what was never written.

### The pre-mortem — write it in the past tense, and the tense is the point

Before moving on, write this out properly rather than thinking about it:

> **It is six months from now. This shipped, and it failed.** Write the incident review. What broke,
> what the first symptom was, how long it took anyone to notice, and what the retrospective concluded
> should have been obvious.

The grammatical shift is not stylistic. Imagining an outcome as **already having happened** —
prospective hindsight — raises the number of correctly identified causes by roughly **30%** against
asking what *could* go wrong (Mitchell, Russo & Pennington 1989; the technique is Gary Klein's, HBR
2007). Forward-looking risk questions produce the list everyone already has. Past-tense questions
surface what people privately suspect and would not otherwise put in writing.

Write it as narrative, and be concrete about the first symptom: *"the queue backed up and nobody
noticed for a day"* is a finding; *"there may be performance issues"* is not.

Then convert each cause into a 🔴 (the plan should handle this), a 🧭 (the shape may be wrong), or a ❓
(the plan does not mention it). **Anything that will not convert stays in the report as a named residual
risk** — do not drop a cause because it did not fit a bucket.

## Step 5. Refute your own findings

**Mandatory, and it applies to 🚪 one-way doors and 🔴 findings.** Read
`${CLAUDE_SKILL_DIR}/reference/verification.md` for the general shape — the refute-by-default
asymmetry, the ⛔/🔴 three-lens pass, and the disposition table all apply here unchanged. Dispatch to
**`x-review-verifier`**, which did not take part in Steps 1–4.

Design review has a specific failure mode that code review does not, and it is what this step exists
to catch: **a plan is a document, so anything not written down looks missing.** The find phase is
structurally biased toward over-reporting absence. Three questions turn that bias back:

- **Is this "one-way door" actually irreversible, or just expensive to undo?** Expensive is a 🟡. A
  door is one-way only when reversing it destroys data, breaks a consumer you do not control, or
  cannot be done at all. Name the moment it closes. If you cannot name the moment, it is not a door.
- **Is the omission actually omitted?** Check the rest of the plan, the repository's existing
  conventions, and the framework's defaults. "The plan does not mention rollback" is refuted if the
  deploy pipeline already rolls back, and that is the single most common false positive here.
- **Can you write the path by which the design fails?** "This is the wrong shape" without a concrete
  bad outcome is a 🧭, not a 🔴. Keep it — 🧭 is load-bearing at plan stage — but do not let it wear
  🔴's severity.

Report the refuted count. **A design review where nothing was refuted did not run this step**, or
reported everything it thought of — say which, plainly, in 🔎.

## Step 6. Report

Follow `${CLAUDE_SKILL_DIR}/reference/report-format.md` for bucketing and presentation, with these
substitutions:

- **⛔ becomes "one-way doors"** — decisions that are expensive or impossible to reverse once
  shipped. These lead the report. For each: what becomes irreversible, at what moment it becomes
  irreversible, and what would have to be true to proceed safely.
- **🧭 carries more weight here than in code review.** At plan stage, "this seems like the wrong
  shape" is still actionable; after implementation it is a rewrite.
- 📍 Location points at a **section of the plan**, plus the `file:line` in the code it conflicts with
  when there is one.

**The four required parts still apply, read for a plan rather than a diff.** They are what makes a design
review actionable instead of a list of misgivings:

| Part | Here it means |
|---|---|
| **1. What changed** | *What the plan proposes to do*, restated from Step 1 and confirmed. First, and present even when nothing is found. |
| **2. Why this is wrong, in detail** | The mechanism the plan implies → the concrete failure it produces → **when** it produces it (which deploy step, which migration, which load) → and whether the *shape* of the plan causes it rather than one sentence in it. "This will be slow" is not this part; "the backfill locks the orders table for the duration and the plan runs it before the read path moves off it" is. |
| **3. Plain explanation** | Two to four sentences for whoever has to decide, jargon glossed. |
| **4. 💬 Suggested comment** | Pasteable onto that plan section, or onto the PR that will implement it. |

**Architecture, aggregate and transaction boundaries, and security are weighted highest here too** —
more so than in code review, because at plan stage they are still cheap to move and afterwards they are a
rewrite. If a plan is silent on any of the three, that silence is a ❓, not a pass.

```markdown
## Design Review — <plan name>

### What I understand the plan to do
(Step 1, three to five sentences)

### 🚪 One-way doors
| Decision | Irreversible from | Why it cannot be undone | What must be true to proceed |

### 🔴 Must resolve before implementing
### 🟡 Should resolve
### 🧭 Design doubts (judgement, not defects)
### ❓ Missing from the plan
(Step 4: rollback, data migration, in-flight requests, observability, …)

### 🧱 Landing plan
| # | What lands | What gates it | One-way? | Before the next one starts |
|---|---|---|---|---|

### 🔎 Confidence
- Which claims I grounded in code, with `file:line`; which I took on trust; where I hit the 25-file
  budget. A clean review means "no problem found at this depth", not a design sign-off.
```

### The landing plan is the same judgement, written down

You have already decided what is irreversible and what must deploy in order. **Where the landings
divide is the conclusion of that**, and nothing else here decides it: `da-fix-plan` orders fixes into
commits inside one change, `da-review-all` asks whether two layers ship together only as a finding. So
plans reach implementation with the split unmade.

The rules are in `${CLAUDE_SKILL_DIR}/reference/design-checklist.md` under **Landing boundaries**.
The one that decides most: **every landing needs a gate you can name** — if you cannot say what proves
it, the plan is not finished. One landing is a legitimate answer as one row with a reason; **an absent
table means nobody decided.**

## Done when

- [ ] The plan was restated and confirmed before critique
- [ ] Every load-bearing claim is either grounded with `file:line` or listed as unverified
- [ ] One-way doors are separated from ordinary findings
- [ ] Step 4 ran — absences, not just errors
- [ ] **Step 5 ran in `x-review-verifier`**, and every 🚪 names the moment the door closes
- [ ] **Some findings were rejected**, and the count is reported. A review that refuted nothing either
      skipped Step 5 or reported everything it thought of — say which in 🔎.

## Next

Revise the plan against the 🔴 items, then `/da-design-review` again if the shape changed materially.
Otherwise proceed to implementation.
