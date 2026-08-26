---
name: da-pr-describe
description: Write or update the current branch's PR title and description. Use when preparing a PR for review, or when the description is stale. Produces something a reviewer can read before opening the diff. Touches only the PR, never repository files.
argument-hint: "[PR number] (default: the PR for the current branch)"
allowed-tools: Bash(gh:*), Bash(git:*), Bash(mktemp:*), Read, Grep, Glob, Write
disable-model-invocation: true
metadata:
  source: bwkw/dotagents
---

# /da-pr-describe — make the PR readable before the diff

**Invoked by you only — type `/da-pr-describe`.** It writes to GitHub, so the timing is yours to choose,
not something to infer from the code looking finished. `disable-model-invocation` also keeps its
description out of context entirely, which costs nothing and frees budget for the skills that do need
to fire on their own. Nothing dispatches to this skill by name.

Generate a title and description that let a reviewer grasp **what changes** and **why that shape
was chosen** without opening the diff. Optimise for being understood, not for being exhaustive.

**This skill never modifies files in the repository.** It edits the PR on GitHub, and writes its
draft body to a temporary file outside the repo.

## Preconditions

| Condition | If unmet |
|---|---|
| `gh` is authenticated and a PR exists for this branch | Stop and report it. Do not create a PR unasked. |
| The working directory is the repository that owns the target PR | Stop. See the cross-repository hazard below. |

## Position in the workflow

| Upstream | This skill | Downstream |
|---|---|---|
| implementation done, PR opened | `/da-pr-describe` | request review |

## Files to read

### Always read

| File | Why |
|---|---|
| `${CLAUDE_SKILL_DIR}/reference/pr-template.md` | The body template and the writing rules. |

### Read only if

| File | Trigger condition |
|---|---|
| the `artifact-design` skill | Only when the visual is an Artifact rather than the default Mermaid block — which is the exception, not the norm |

---

## Steps

### Step 1. Identify the PR — and confirm it is the right one

```bash
gh pr view --json number,title,baseRefName,headRefName,url
```

**`gh` runs against the repository in the current working directory.** `gh pr edit <number>` from
the wrong directory edits *that* repository's PR with the same number — an unrelated PR. Before
editing anything, state the repository, number, title, and URL you are about to modify, and get the
user's confirmation. Do not trust a bare number.

### Step 2. Gather the change

```bash
BASE="$(gh pr view --json baseRefName -q .baseRefName)"
git diff "$BASE"...HEAD
git log --oneline "$BASE"..HEAD
```

### Step 3. Extract what actually changed for someone else

From the diff, pull out **what changes for a user, an operator, or a caller** — see the selection
rules in the reference.

For each retained change, extract **the problem it solves** — the incident, the request, the goal.
Without it the change reads as a solution to an unstated problem.

**Then ask whether an obvious alternative was rejected.** If one was, name it and the evidence that
ruled it out (a slower flag, a narrower exclude that would hide real errors, a deploy-time failure CI
never saw) — otherwise the reviewer opens the diff to ask 「なぜこの形？」. It goes in **検討した代案**,
a section, so it can carry a number and a link. If no real alternative existed, **delete that section**;
do not restate the problem in different words to fill it.

Also pin down, for each change:

- the **領域** — the area in the reader's vocabulary: a screen, an API, a CSV export, an operational
  procedure. **Never a class, function, or flag.**
- the **変更前 / 変更後 pair** — the current value or behaviour and what it becomes, both short. `—` for
  a pure addition. **If a change cannot be written as a before/after pair, that is the signal it is
  internal churn** and does not belong in the table.

**Those three are the table's columns, and all three are short values.** The problem and the rejected
alternative are prose, not a fourth column: a cell can hold only inline formatting, so a column of
sentences sets the row width and squeezes the three that were doing the scanning. Collect the ticket,
issue, design-doc and benchmark links here too — they belong in 概要.

Separately, collect candidates for **manual verification**: things automated tests cannot cover and
that must be checked by hand or in a real environment before merge. Real external API behaviour,
real data, end-to-end against a real tenant, a typecheck the agent is not permitted to run,
environment-specific configuration or permissions.

### Step 4. 全体像 — a section, present only when there is one

**First ask whether the change has a shape at all**: a flow that changed, a sequence, which layers are
touched, a state machine. A flag value changing has no shape, and the table already says everything —
**delete the whole section rather than draw something to fill it.** Never fabricate a URL.

It is a heading (`## 全体像`), above 概要, and it behaves like 検討した代案: **there when there is
something, gone when there is not.** Those two are the only optional sections, and they are optional the
same way — one fewer rule than the unheaded block it replaced.

When it does have a shape, take the route the environment supports:

**Mermaid is the default, in every environment** — a ` ```mermaid ` fence, which GitHub renders inline
for every reader with no account and no sharing step.

**Reach for an Artifact only when the shape exceeds a diagram** (grouped before/after tables, several
views on one page). It is **private by default**, so a link in a PR body is dead for every reviewer until
you share it: share it before posting, or do not link it. Read `artifact-design` first.

**The route used to be picked by which tool the author had.** That optimises for the author's capability
and against the reader, which is the one trade a PR description must never make.

Either way, **do not restate the 変わること table.** The body already carries the scannable view; a page
or diagram that repeats it is one more thing to open and dismiss.

### Step 5. Compose the title and body

**Language: match the repository, do not assume.** Unlike every other skill here, this output has an
audience that is not you, so this is the one place where the language is not simply Japanese.

```bash
gh pr list --state merged --limit 5 --json title,body
```

Read those, or recent commit subjects, and write in whatever language they use. **The template's
headings are Japanese because that is the common case here; the reference lists the English equivalent
for each.** The table's structure and its four columns do not change with the language.

State which language you chose and what it was based on. If the merged PRs are mixed, or there is
nothing to go on, **ask** — guessing wrong is visible to everyone on the PR. Paths, identifiers,
commands and code excerpts stay verbatim inside a sentence of either language.


Follow `${CLAUDE_SKILL_DIR}/reference/pr-template.md`. If Step 4 produced a URL or a Mermaid block, it
goes under `## 全体像`, the first section of the body. If it produced neither, that heading is absent. **Markdown tables and Mermaid fences go
inline; raw HTML never does** — GitHub strips much of it and what survives renders badly.

### Step 6. Show it, then update

Show the user the final title and body. On approval:

```bash
gh pr edit --title "..." --body-file "$TMPFILE"
```

Write `$TMPFILE` under a temporary directory, never inside the repository.

## Done when

- [ ] The reviewer can tell what changes from the description alone
- [ ] **概要 carries the problem**, not a benefit and not a restatement of the change — and the ticket,
      issue, design doc or benchmark numbers are linked there rather than left out
- [ ] **検討した代案 exists only if one was actually rejected**, with the evidence that ruled it out —
      otherwise the section is deleted, not filled
- [ ] No 領域 cell names a class, function, or flag
- [ ] **No table cell contains a sentence** — every cell is a value or a short phrase
- [ ] Nothing in the table failed the before/after test — a row that cannot be written as a pair is
      internal churn and was dropped
- [ ] `## 全体像` carries a visual, **or the section is absent** because the change has no shape — never
      a heading with nothing under it, and never a diagram drawn to fill one
- [ ] The title is a standalone sentence written as an order, in the repository's language
- [ ] The language was chosen from the repository's merged PRs, and which was chosen was stated
- [ ] No internal-only churn made it into the body
- [ ] Everything requiring manual verification is listed, unchecked, with a reason
- [ ] Cross-repository references use full URLs or `owner/repo#number`, never a bare `#number`

## Cross-repository hazards

Both of these have bitten before and neither fails loudly.

**`#number` resolves within the PR's own repository.** A `#80` written in a backend PR body points
at backend's #80, not the frontend PR you meant. Across repositories, always use the full URL
(`https://github.com/owner/repo/pull/80`) or `owner/repo#80`. For a set of PRs spanning backend and
frontend, every cross-link and shared-artifact note must use that form.

**`gh` acts on the current working directory's repository.** When handling PRs across repositories,
`cd` to the target repository before each command and verify with `gh pr view <number> --json title`
that it is the PR you think it is.
