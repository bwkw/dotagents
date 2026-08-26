---
name: da-design-review
description: Review a plan or spec before any code exists. Use when a design doc is ready, before implementation starts, or when asked whether an approach is sound. Catches one-way doors, migration order, and rollback. Read-only.
argument-hint: "[change-id | path to the spec or plan] (default: resolve from the repository's spec_system, then ask)"
allowed-tools: Task, Read, Grep, Glob, Bash, WebFetch
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
| The repository's `spec_system` resolved, or its absence was reported | Step 0. Never guess the subject from the tree |
| The document describes changes to a codebase you can read | Continue, but say in 🔎 that you could not ground the claims in code |

## Position in the workflow

| Upstream | This skill | Downstream |
|---|---|---|
| `/da-spec` (or `/writing-plans`, `/research`, an ADR) | `/da-design-review` | revise, then `/executing-plans` |

## Files to read

### Always read

| File | Why |
|---|---|
| the plan or spec under review | the subject |
| `${CLAUDE_SKILL_DIR}/reference/finding-discipline.md` | posture and reporting rules; passed to every subagent |
| `${CLAUDE_SKILL_DIR}/reference/design-checklist.md` | the review dimensions |
| `${CLAUDE_SKILL_DIR}/reference/spec-system.md` | which artifact is the subject, the repository's own rules, the validator, and how 🧱 relates to its task list |

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

## Step 0. Find the subject, and run what checks it

Follow `${CLAUDE_SKILL_DIR}/reference/spec-system.md`. In an `openspec` repository the subject is the
whole change directory — proposal, design, tasks **and the spec deltas** — not one file of it, and the
standard includes the rules file the profile names.

**Then run `spec_system.validate` and paste the output, before any judgement.** A malformed delta is
not a design finding and must not be reported as one; and a review that reads a spec whose validity was
mechanically checkable, without checking it, is asserting where it could have measured.

> **`Bash` is unrestricted here for exactly one reason and carries exactly one extra permission.**
> `spec_system.validate` is defined per repository — `pnpm`, `make`, `bundle`, `./bin/…` — so an
> allowlist of interpreters would silently fail on the repositories it did not guess. **Run the
> profile's `validate` string verbatim and nothing else**, and check it against the profile's
> `forbidden` list first, exactly as `da-verify` does. Everything else in this skill stays read-only:
> `git`, `gh`, and reading. **This skill still never writes.**

## Step 1. Restate the plan in your own words

Before critiquing anything, write what you understand the plan to do, in three to five sentences:
what changes, why, and in what order.

**Show this to the user.** A misread plan produces confident, irrelevant findings, and this is the
cheapest place to catch it. Too vague to restate is itself the first finding — stop and report it.

## Step 2. Ground the plan in the actual code

A plan review that only reads the plan is a proofread. The value is in the gap between what the plan
assumes and what the code actually does.

For each of the plan's load-bearing claims — "this table is append-only", "no other caller depends on
this", "the frontend already handles a missing field" — **open the code and check**, citing
`file:line`. When you cannot confirm one, that is a finding, not a footnote.

Budget: **25 files.** On reaching it, stop and record what you did not verify — an unbounded
"investigate the codebase" burns the context the review itself needs.

## Step 3. Review across the dimensions

Read `${CLAUDE_SKILL_DIR}/reference/design-checklist.md` and work through it.

For a substantial plan, dispatch the dimensions to **parallel subagents** in a single message, one per
dimension group, each given the plan, the Step 2 findings and `finding-discipline.md`. The checklist and
code excerpts are bulky; inline they crowd out the synthesis. **Small plan — a handful of files, nothing
irreversible — work through it directly.**

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

**The tense is not stylistic** — the measurement and the citations are in `design-checklist.md` under
*Pre-mortem*. Forward-looking risk questions produce the list everyone already has.

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

**The four required parts still apply, read for a plan rather than a diff** — `report-format.md` carries
them under *Design review substitutions*, together with the ⛔ → 🚪 mapping and how 📍 points at a plan
section. **Architecture, aggregate and transaction boundaries, and security are weighted highest here**,
more than in code review: at plan stage they are cheap to move and afterwards they are a rewrite. A plan
silent on any of the three is a ❓, not a pass.

**The full skeleton is in `design-checklist.md` under *Report skeleton*.** Follow it exactly — the
order puts the irreversible decisions above everything somebody can still fix. Two sections are
reproduced here because they must not go missing:

```markdown
### 🚪 One-way doors
| Decision | Irreversible from | Why it cannot be undone | What must be true to proceed |

### 🧱 Landing plan
| # | What lands | What gates it | One-way? | Before the next one starts |
```

### The landing plan is the same judgement, written down

You have already decided what is irreversible and what must deploy in order. **Where the landings
divide is the conclusion of that**, and nothing else here decides it: `da-fix-plan` orders fixes into
commits inside one change, `da-review-all` asks whether two layers ship together only as a finding. So
plans reach implementation with the split unmade.

**N rows means N changes** — N openspec `changes/<id>/` directories, N plan files otherwise. Not one
change with the landings as task groups: a landing ships on its own and a task does not.
`spec-system.md` carries that mapping, because `da-spec` has to create what this table decided.

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
