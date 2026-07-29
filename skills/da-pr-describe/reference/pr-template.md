# PR body template and writing rules

## What goes in, and what stays out

A description exists so the change can be understood by reading it. Write **observable changes**
only; leave internal matters to the diff.

**Include** — anything that changes a reader's experience, a contract, or a result:

- What became possible, and what stopped being possible
- Changes to API responses, error conditions, validation, or output (CSV, ETL, …)
- Changes to default behaviour, classification, or transformation rules

**Leave out** — the diff covers these, and writing them adds noise:

- Internal refactoring, renaming, splitting functions or classes (when behaviour is unchanged)
- Seed data, test fixtures, local-only presets
- Unifying display strings, comments, documentation formatting
- Stating that something is unchanged

> The test: if you deleted this line, would a reviewer misunderstand the change? If not, leave it out.
> When an internal change *is* the crux of the review, give it one line under Notes — not the table.

---

## Template

Use only the sections you need. Never emit an empty section. The visual summary link goes first
when there is one.

```markdown
📋 **Change summary (visual)** → <artifact URL>

> An at-a-glance view of what changes, before opening the diff. May need sharing enabled to open.

## Overview

<!-- 2-3 sentences: what changes and why. The point should land from this alone. -->

## What changes

<!-- Observable changes, one topic per bullet. Each bullet states what changed AND why that shape
     was chosen (the constraint, measurement, or failure mode that ruled out the obvious alternatives).
     In the reader's words; each standing on its own. -->
-
-

## Before → After (optional)

<!-- Only for items where existing behaviour changes and the contrast prevents a misreading.
     Not for new additions (where Before is empty) and not for internal changes.
     Omit the whole section when there is nothing worth contrasting. -->

| Item | Before | After |
|---|---|---|
| | | |

## Tests

<!-- What automated tests and CI already cover, at a granularity that shows what was verified. -->
- [x]

## Manual verification (local / real environment)

<!-- What automated tests cannot cover and must be checked before merge. Keep separate from Tests.
     Unchecked items stay `- [ ]`. One line each: what to check and why it matters. Omit if none. -->
- [ ]

## Notes (optional)

<!-- Deliberate design decisions a reviewer would otherwise stop on, and known gaps deferred to a
     next phase. Minimal. Omit if none. -->
```

---

## Writing rules

**Title.** Concise, around 50 characters. No `feat:`-style prefix (follow the repository's own
ticket-tag convention). Match the language the repository's other PR titles use.

**Overview.** Two or three sentences: what changes, and why.

**What changes.** Observable changes as bullets, in the words of the user, operator, or API caller.
**Do not make a class, function, or flag the subject.** Not "added `LoadOutboundUsecase`" but
"customer-facing CSV can now be exported". One topic per bullet, each meaningful on its own without
the lines around it. Nothing from the "leave out" list.

**Every bullet must carry the why.** State what changed, then why that shape was chosen — the
constraint, measurement, or failure mode that ruled out the obvious alternatives. A reviewer should
not have to open the diff or ask "なぜこの形？" to understand the decision. Prefer one sentence that
pairs change + reason over a bare fact followed by a separate justification paragraph.

Bad: "`pnpm run typecheck` now uses `--singleThreaded`"
Good: "`pnpm run typecheck` is fixed to `--singleThreaded`, because on this codebase `--checkers 2`
was ~2.4× slower and used ~40% more memory"

**Before → After.** Only where **existing behaviour changes** and the contrast prevents a
misunderstanding — for example, "records with an empty unique key were counted as successful rows →
they are now excluded as errors". New additions and internal changes do not belong in a table; the
bullets are enough. Optional; omit the section when nothing qualifies.

**Tests.** What automated tests and CI actually cover, one line each, describing the *behaviour
verified* rather than "added tests". Done is `- [x]`; outstanding is `- [ ]`. CI coverage as
`- [x] CI: typecheck / lint / unit`. **Anything that cannot be verified automatically goes in the
next section, not here.**

**Manual verification.** Checkboxes for what must be confirmed by hand or in a real environment
before merge. Typical: real external API response shapes, real integration behaviour, migrations
against production-like data, a typecheck the agent is not permitted to run, end-to-end against a
real tenant, environment-dependent configuration and permissions. Each line states **what to check
and why it matters — what breaks if it is skipped**. This section is a hold on merging until it is
filled in. Omit it entirely when automated tests genuinely suffice. Where useful, add one line to
Notes about how the item could become an automated test later, so this list shrinks over time.

**Notes.** Only deliberate design decisions and known deferred gaps. No listing of implementation,
nothing self-evident. Omit if empty.

---

## Visual summary

Only when the Artifact tool is available in the current environment.

- Publish the summary as an HTML Artifact and link the URL at the top of the body. **Never inline an
  HTML table into the PR body** — the at-a-glance view belongs in the artifact.
- Read the `artifact-design` skill first. Page structure: at-a-glance table (area × observable
  change), then detail by area, then tests and notes. Same selection rules as the body.
- **Artifacts are private by default.** Add one line telling the reviewer that sharing may need to be
  enabled, so they are not met with a dead link.
- Overlap between the artifact and Overview / What changes is fine: the artifact is for scanning, the
  body for detail.
- For a set of PRs spanning several repositories, publish one artifact per PR and link each to its
  own.
