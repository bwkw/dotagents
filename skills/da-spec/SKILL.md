---
name: da-spec
description: Write the change onto disk in the form this repository actually uses, or update the existing one. Use when a spec, proposal, design or plan needs recording before implementation — openspec changes, spec deltas, plan files. Resolves the repository's own convention and its authoring rules rather than picking a location. Writes only spec artifacts, never source.
argument-hint: "[what the change is | change-id | path] (default: ask)"
allowed-tools: Read, Grep, Glob, Write, Edit, Bash(git:*), Bash(gh:*), Bash(pnpm:*), Bash(npm:*), Bash(npx:*), Bash(yarn:*), Bash(make:*), Bash(bundle:*)
metadata:
  source: bwkw/dotagents
---

# /da-spec — record intent where this repository keeps it

**This skill writes only intent artifacts** — spec, proposal, design, tasks, plan. It never touches
source, migrations, schema or config, and it never starts the implementation.

It exists because **the routing used to live in `README.md`**, in a parenthetical saying that a
repository using openspec should get openspec instead of a plan file. `README.md` is not loaded at
runtime, so nothing ever read it, and the answer was always a plan file in the upstream skill's
default location. **A rule written where it cannot bind is not a rule** — this file is the place it
binds, and `spec_system` in the profile is the place the fact lives.

## Preconditions

Stop immediately if any row fails. Report which condition failed. Do not continue.

| Condition | If unmet |
|---|---|
| The working directory is inside a git repository with an `origin` remote | Stop, say so, do not guess a location |
| **What the change is, is stated** | **Stop and ask.** A spec written from an inferred goal is a spec for the wrong change, and it reads as authoritative. |
| A profile matches this repository | Continue **only** as far as Step 1, which reports the gap and asks. Never invent a convention |
| `spec_system.kind` is `none` | Stop. Say the repository records intent nowhere, and ask where it should go — do not create a directory |

## Position in the workflow

| Upstream | This skill | Downstream |
|---|---|---|
| `/research`, `/grilling`, `/da-investigate` | `/da-spec` | **`/da-design-review`**, then `/executing-plans` |

## Files to read

### Always read

| File | Why |
|---|---|
| `${CLAUDE_SKILL_DIR}/reference/spec-system.md` | how to resolve the convention, why not from the tree, and the validator rule. Shared with `da-design-review`, so the two cannot disagree about where the artifact lives |
| the matching `profiles/*.json` → `spec_system` | which convention this repository uses, and where |
| the file named by `spec_system.rules` | **the repository's own authoring rules.** Not optional: writing to a generic template when the repository has written its rules down produces an artifact that fails its own validator |

### Read only if

| File | Trigger condition |
|---|---|
| the existing change or plan being updated | Step 2 found one — and it usually should |
| `${CLAUDE_SKILL_DIR}/reference/openspec.md` | `kind` is `openspec` — the directory shape, the delta headings, and what `validate --strict` actually checks |
| `CLAUDE.md`, `AGENTS.md`, `.cursor/rules/*` | the repository has them, and the rules file delegates to them |

> Reading everything "just in case" is forbidden.

---

## Step 1. Resolve the convention — do not choose one

Follow `${CLAUDE_SKILL_DIR}/reference/spec-system.md`: resolve `spec_system` from the profile, read the
rules file it names, and stop and ask when there is no profile or no `spec_system`. **Observing a
directory is not being told to write into it.**

## Step 2. Look for the change that already exists — before creating one

**This is the step whose absence is the whole complaint.** Creating a second change for a capability
that already has one splits the record in two, and neither half is wrong on its own, so nothing
reports it.

Search by **capability and by subject, not by title**:

```bash
ls "$ROOT"/changes 2>/dev/null                       # openspec: change ids are slugs, read them all
rg -l "<the entity, table, endpoint, or capability>" "$ROOT" 
git log --oneline -20 -- "$ROOT"                     # what was last touched here, and by which branch
```

Then decide, and **say which you chose and why**:

| What you found | Do this |
|---|---|
| A change covering this capability, not yet archived | **Update it.** Add requirements to the existing delta rather than starting a sibling |
| A change that is adjacent but genuinely separate | New change. **State the boundary** — what makes them separate deliveries |
| A **deployed** spec (`specs/<capability>/spec.md`) but no open change | New change, and its delta is `## MODIFIED Requirements` against that spec — not `ADDED` |
| Nothing | New change |

**When it is ambiguous, ask.** Two people's judgement of "same capability" differs, and the cost of
asking is one message against a split record nobody notices for a month.

## Step 3. Write it, against the repository's rules

`kind: openspec` → read `${CLAUDE_SKILL_DIR}/reference/openspec.md`, then write the change directory.

`kind: plans` → **use the `writing-plans` skill and follow it exactly**, then place the file where
`spec_system.root` says rather than at that skill's default. **Do not restate its guidance here.**
Task decomposition, right-sizing and the plan header are its subject and it is maintained upstream;
duplicating it here would produce two versions that drift, and the copy in this repository would be
the stale one.

Either way, two rules that are this skill's own:

- **The rules file wins over any template.** If `spec_system.rules` requires headings, a normative
  vocabulary, or that a modified requirement is restated whole, that is the standard. A generic
  template that reads well and fails the validator is worse than no artifact.
- **Write what you verified, and mark what you did not.** A spec is read later as settled fact. An
  assumption you did not check goes in as an explicit open question, not as a requirement.

## Step 4. Run the validator, and show its output

Per `${CLAUDE_SKILL_DIR}/reference/spec-system.md`. **Red means not finished** — fix and re-run rather
than reporting the artifact as written. Green means well-formed and nothing more; say that in those
words, and leave the design judgement to `/da-design-review`.

> **The frontmatter allowlist is the enforcement, and the prose below is not.** An earlier version of
> this file opened `Bash` and put the constraint in a sentence, reasoning that an allowlist would fail
> silently on an interpreter it did not guess. **That had the failure direction backwards**: a denied
> tool call is refused loudly, in front of the user, while a sentence is a request. The gate hook says
> it in one line — *a rule written in a skill is a request, not a guarantee*.
>
> So: **if the repository's validator is not one the allowlist covers, say so and stop.** Do not route
> it through a covered interpreter to get it to run. Report "the validator could not be run here" and
> let the profile or the allowlist be changed deliberately.
>
> Within what is allowed: **run the profile's `validate` argv and nothing else.** Refuse an argv whose
> first element is a shell (`sh`, `bash`, `zsh`) or that contains `-c` — that is a command string
> wearing an array's clothes. Check every element against the profile's `forbidden` list first.
> `pnpm run <anything>` is not in scope just because the validator happens to start with `pnpm`.

## Evidence discipline

- Report only what you verified directly. Cite locations as `path/to/file.md:L42`.
- When you have no basis for a claim, write "could not confirm" — do not guess.
- Separate fact from inference explicitly.
- Attach a URL to any external claim.

## Output

Report, in this order:

1. **Which convention resolved**, and from which profile — or the gap, and the question
2. **Created or updated**, with the path, and **for an update, what was already there**
3. **The validator output**, pasted, or the fact that there is none
4. **What is still open** — the assumptions you could not check, as questions rather than as spec text

## Done when

- [ ] The convention came from the **profile**, not from what the tree looked like
- [ ] `spec_system.rules` was read **before** writing, and the artifact follows it
- [ ] Step 2 ran: an existing change was **searched for by capability** and the choice to update or
      create is stated with its reason
- [ ] The validator ran and its output is **pasted**, or its absence is stated
- [ ] Nothing outside the spec root was written, and no implementation was started

## Next

`/da-design-review` on what was just written. It reads the same `spec_system` and reviews the change
directory rather than guessing at a plan path.
