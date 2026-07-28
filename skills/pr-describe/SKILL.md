---
name: pr-describe
description: Write or update the current branch's PR title and description. Use when preparing a PR for review, or when the description is stale. Produces something a reviewer can read before opening the diff. Touches only the PR, never repository files.
argument-hint: "[PR number] (default: the PR for the current branch)"
allowed-tools: Bash(gh:*), Bash(git:*), Read, Grep, Glob
---

# /pr-describe — make the PR readable before the diff

Generate a title and description that let a reviewer grasp **what changes** without opening the
diff. Optimise for being understood, not for being exhaustive.

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
| implementation done, PR opened | `/pr-describe` | request review |

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

Separately, collect candidates for **manual verification**: things automated tests cannot cover and
that must be checked by hand or in a real environment before merge. Real external API behaviour,
real data, end-to-end against a real tenant, a typecheck the agent is not permitted to run,
environment-specific configuration or permissions.

### Step 4. Publish the visual summary — only where the Artifact tool exists

**This step is Claude-specific.** In Cursor, or anywhere the Artifact tool is unavailable, skip it
and go to Step 5 — the description stands on its own without it. Do not fabricate a URL.

Read the `artifact-design` skill, then build one HTML page: an at-a-glance table of changes (area ×
observable change), the detail by area, tests, and notes. Apply the same selection rules as the
body — no internal refactoring, renaming, or seed data. Publish it and keep the URL.

### Step 5. Compose the title and body

Follow `${CLAUDE_SKILL_DIR}/reference/pr-template.md`. If Step 4 produced a URL, link it at the very
top of the body. Never inline an HTML table into the body.

### Step 6. Show it, then update

Show the user the final title and body. On approval:

```bash
gh pr edit --title "..." --body-file "$TMPFILE"
```

Write `$TMPFILE` under a temporary directory, never inside the repository.

## Done when

- [ ] The reviewer can tell what changes from the description alone
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
