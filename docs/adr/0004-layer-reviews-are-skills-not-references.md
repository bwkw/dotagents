# 0004 — Layer reviews are skills, not reference files

- **Status**: accepted, 2026-07-28
- **Supersedes**: the initial split, where the layer bodies lived as `review-all/reference/{backend,frontend,infra}.md`

## Context

Four review commands existed before this repository: `/review-all`, `/review-backend`,
`/review-frontend`, `/review-infra`. Each was directly invokable, and each was self-contained — roughly
31 KB for backend, with a large overlap between the three because the seven-step process, the finding
discipline, and the report format were duplicated in each one.

The first migration removed the duplication by making `review-all` the only skill and demoting the
three layer bodies to `reference/*.md` that the dispatcher handed to a subagent. The reasoning was
context economy: a skill body, once loaded, stays in context until the session ends, so making
`review-backend` a skill would park its full body there even when reviewing only backend.

## The problem with that

Three regressions, all of which came from the same move and none of which were intended:

1. **Three entry points disappeared.** `reference/backend.md` is not invokable. "Review just the
   backend" had to go through `/review-all` and its classification step, which is exactly the work you
   want to skip when you already know the answer.

2. **The find phase lost the silent-failure patterns.** The original layer bodies carried the
   recurring silent-and-irreversible incident patterns with an explicit instruction to apply them in
   **both** the find and verify phases. De-duplication moved them into `verification.md`, which by its
   own "read only if" rule is read *only when entering the verify phase*. The patterns were still
   written down, still correct, and no longer read by the pass with the best chance of catching them
   early. Nothing reported this.

3. **The posture moved two hops from the point of use.** The original layer file opened with how to
   think — "clean is a conclusion earned with evidence", "do not go easy", "be adversarial toward your
   own severe findings" — and only then listed what to check. After the split, the layer file opened
   with the checklist and delegated the posture to a shared file it merely pointed at.

The third is the one that produced the complaint that the tech-lead perspective had been shaved off.
The checklists survived intact; the stance around them did not.

A fourth, smaller problem: `AGENTS.md` claimed `review-all` "dispatches to its layer references by
name, so setting `disable-model-invocation` turns the dispatcher into a no-op". It dispatched to
*files*, so the stated justification for that invariant was false.

## Decision

The layer reviews are skills: `review-backend`, `review-frontend`, `review-infra`. Each has a lean
`SKILL.md` and keeps its heavy content in its own `reference/perspectives.md`. `review-all` dispatches
to them **by skill name**, via a subagent.

Context economy is preserved by where the weight sits, not by refusing to be a skill:

| | In context after invoking one layer |
|---|---|
| Before (reference) | dispatcher body + layer body in the subagent |
| Now (skill) | layer `SKILL.md` (~6 KB) + `perspectives.md` in the subagent |

The perspective clusters — the part that was ~9 KB and worth avoiding — are still loaded only by the
subagent that needs them. What is now resident is the posture and the dispatch instructions, which is
the part that should be resident: it is what the main context needs in order to judge the subagent
reports it gets back.

Shared material stays shared, by symlink into each layer skill's `reference/`: `finding-discipline.md`,
`review-process.md`, `verification.md`, `report-format.md`, `silent-failure-patterns.md`. One physical
copy, five reachable paths.

The silent-failure patterns move to their own file, listed under **always read** in every layer skill,
so they are read in both phases. `verification.md` keeps a pointer and an explanation of why it does
not hold the only copy.

## Consequences

- Three entry points return. `/review-backend` works standalone and as a dispatch target, from one
  file, so they cannot drift.
- The `disable-model-invocation` invariant is now true as written: setting it on a layer skill makes
  `review-all` report that layer as covered while reviewing nothing. The linter checks for it.
- Description budget grows by ~950 chars (5,963 → 6,914 against a target of 8,000). This is the real
  cost, and it is why the layer descriptions stay tight and each names a distinct file vocabulary
  rather than restating "review changes".
- Each layer skill duplicates a condensed posture inline while the full discipline stays shared. This
  is deliberate partial duplication: the four bullets are the thing that must be read before anything
  else, and a pointer to them is not the same as having them. The risk is drift between the condensed
  and full versions, which is accepted — it is a smaller risk than the posture going unread, which
  already happened once.
- `review-all` no longer symlinks `review-process.md`, `verification.md`, or `report-format.md`; it
  does not run a layer review itself. The linter flagged them as unmentioned, which is how they were
  found.
