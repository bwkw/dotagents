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
| the `artifact-design` skill | Only when publishing the visual summary, and only if the Artifact tool exists in this environment |

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

For each retained change, extract **two separate things**, because they answer different questions and
a row with only one of them is incomplete:

- **変更目的 — why this is being done at all.** The problem, the request, the incident, the goal.
  Without it the change reads as a solution to an unstated problem.
- **この形にした理由 — why this shape and not the obvious alternative.** The constraint, measurement,
  or failure mode that ruled the alternative out (a slower flag, a narrower exclude that would hide
  real errors, a deploy-time failure CI never saw). Without it the reviewer opens the diff to ask
  「なぜこの形？」 anyway.

Also name the **領域** for each: the area in the reader's vocabulary — a screen, an API, a CSV export,
an operational procedure. **Never a class, function, or flag.** These three plus the observable change
are the four columns of the table.

Separately, collect candidates for **manual verification**: things automated tests cannot cover and
that must be checked by hand or in a real environment before merge. Real external API behaviour,
real data, end-to-end against a real tenant, a typecheck the agent is not permitted to run,
environment-specific configuration or permissions.

### Step 4. Publish the visual summary — only where the Artifact tool exists

**This step is Claude-specific, and it is now optional in both agents.** The at-a-glance view lives in
the body's 変わること table, which is plain Markdown and renders identically from Claude and from
Cursor. That is deliberate: this step used to be the only at-a-glance view, so a PR written from Cursor
silently got none. **Skip this step and the description is complete** — in Cursor, where the Artifact
tool does not exist, and in Claude whenever the change is small enough that a second view adds nothing.
Never fabricate a URL.

When you do publish one, read the `artifact-design` skill first, then build one HTML page that earns
its place by doing what a Markdown table cannot: grouping by area, showing before/after side by side,
or carrying a diagram. Same selection rules as the body — no internal refactoring, renaming, or seed
data. **Do not just restate the table**; a duplicate of the body is an extra link for the reviewer to
open and dismiss.

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


Follow `${CLAUDE_SKILL_DIR}/reference/pr-template.md`. If Step 4 produced a URL, link it at the very
top of the body. **The 変わること table is a Markdown table in the body; raw HTML never is** — GitHub
strips much of it and what survives renders badly.

### Step 6. Show it, then update

Show the user the final title and body. On approval:

```bash
gh pr edit --title "..." --body-file "$TMPFILE"
```

Write `$TMPFILE` under a temporary directory, never inside the repository.

## Done when

- [ ] The reviewer can tell what changes from the description alone
- [ ] Every 変わること row fills all four columns, and **変更目的 and この形にした理由 say different
      things** — one is why do this, the other is why like this. A row where they restate each other
      has answered only one of the two questions
- [ ] No 領域 cell names a class, function, or flag
- [ ] Every cell is one sentence; anything longer moved its detail to 補足
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
