---
name: design-review
description: Review a plan or spec before any code exists. Use when a design doc is ready, before implementation starts, or when asked whether an approach is sound. Catches what code review cannot fix later — one-way doors, migration order, rollback, and what the plan omitted. Read-only.
argument-hint: "[path to plan/spec] (default: the most recent plan under docs/)"
allowed-tools: Task, Read, Grep, Glob, Bash(git:*), Bash(gh:*), WebFetch
metadata:
  source: bwkw/dotagents
---

# /design-review — catch it while it is still cheap

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
| `/grill-me`, `/writing-plans`, `/brainstorming` | `/design-review` | revise the plan, then `/executing-plans` |

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

## Step 5. Report

Follow `${CLAUDE_SKILL_DIR}/reference/report-format.md` for bucketing and presentation, with these
substitutions:

- **⛔ becomes "one-way doors"** — decisions that are expensive or impossible to reverse once
  shipped. These lead the report. For each: what becomes irreversible, at what moment it becomes
  irreversible, and what would have to be true to proceed safely.
- **🧭 carries more weight here than in code review.** At plan stage, "this seems like the wrong
  shape" is still actionable; after implementation it is a rewrite.
- 📍 Location points at a **section of the plan**, plus the `file:line` in the code it conflicts with
  when there is one.

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

### 🔎 Confidence
- Which claims I grounded in code, with `file:line`; which I took on trust; where I hit the 25-file
  budget. A clean review means "no problem found at this depth", not a design sign-off.
```

## Done when

- [ ] The plan was restated and confirmed before critique
- [ ] Every load-bearing claim is either grounded with `file:line` or listed as unverified
- [ ] One-way doors are separated from ordinary findings
- [ ] Step 4 ran — absences, not just errors
- [ ] **Some findings were rejected**, and the count is reported. See `report-format.md` — the
      reasoning is there, and a review that filtered nothing has not been calibrated.

## Next

Revise the plan against the 🔴 items, then `/design-review` again if the shape changed materially.
Otherwise proceed to implementation.
