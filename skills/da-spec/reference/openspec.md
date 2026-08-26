# openspec — the shape, and what the validator actually checks

Read this only when `spec_system.kind` is `openspec`. **`openspec/config.yaml` outranks this file**:
this describes the format, that describes *this repository's* rules for filling it in.

## The shape

```
openspec/
  config.yaml                        # schema: spec-driven, plus the repository's own rules
  specs/<capability>/spec.md         # deployed truth. Current behaviour, not proposals
  changes/<change-id>/
    proposal.md                      # Why / What Changes / Impact
    design.md                        # how, and where responsibility sits
    tasks.md                         # ordered checklist, with paths and expected results
    specs/<capability>/spec.md       # the DELTA against specs/<capability>/spec.md
    .openspec.yaml
```

**`specs/` is what shipped. `changes/<id>/specs/` is what would change.** Writing a proposal into
`specs/` states as deployed truth something that does not exist yet, and nothing in the tree marks it
as speculative afterwards.

**A change id is a slug of the outcome**, matching its siblings — `add-*`, and the verb the repository
already uses. Read the existing ids before inventing a style.

## The delta headings

A change's spec file uses exactly these:

```markdown
## ADDED Requirements
## MODIFIED Requirements
## REMOVED Requirements
## RENAMED Requirements
```

**`MODIFIED` restates the whole requirement block — heading and every scenario.** A partial update is
rejected, and the reason is worth knowing rather than working around: the archived change has to be
readable on its own years later, and a diff-of-a-diff is not. If you are tempted to write only the
changed line, you are about to make the record unreadable to save four lines.

**`ADDED` against a capability that already has a deployed spec is usually wrong** — it is `MODIFIED`.
Check `specs/<capability>/spec.md` before choosing the heading; this is the most common validator
failure and the one that looks correct while writing it.

## Requirements and scenarios

- Normative vocabulary is **SHALL / MUST / MUST NOT**, matched to the terms already used in the
  capability's spec. Do not mix in "should" for something the system enforces.
- **Every requirement carries at least one `#### Scenario:`** with `GIVEN` / `WHEN` / `THEN` / `AND`
  bullets. A requirement with no scenario is a sentence nobody can test, and the validator says so.
- A scenario names **state and input, then result**. "THEN it works" is not a scenario.

## What `validate --strict` catches, and what it cannot

**It catches shape**: missing headings, a requirement with no scenario, a delta heading that is not
one of the four, `MODIFIED` blocks that are not whole, references to a capability that does not exist.

**It cannot catch**: whether the requirement is the *right* requirement, whether `ADDED` should have
been `MODIFIED` against a spec that exists, whether the scenarios cover the failure paths, or whether
the change contradicts a sibling capability's spec.

So a green validator means **the artifact is well-formed**, and nothing more. Say exactly that when
reporting it — "validate --strict passed" read as "the design is sound" is the same misweighting a
clean code review causes, and it is the reason `/da-design-review` runs after this and not instead
of it.

## Updating an existing change

- **Add to the existing delta**, in the heading it belongs under. Do not append a second
  `## ADDED Requirements` block — merge into the one that is there.
- When the new requirement modifies one this change already added, **edit that block**. Two versions
  of the same requirement inside one change is the state the validator does not catch and a reader
  cannot resolve.
- The `<change-id>/tasks.md` checklist is ordered: a new task goes where its dependencies put it, not at the end.
- Re-run the validator after any edit, not only after creation.
