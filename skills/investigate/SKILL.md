---
name: investigate
description: Map what a change would touch, or trace how something actually works. Use when asked where something lives, what depends on it, or what would break. Answers with file:line evidence under a fixed exploration budget, and names what it could not confirm. Read-only.
argument-hint: "the question to answer"
allowed-tools: Read, Grep, Glob, Bash(git:*), Bash(rg:*), Bash(gh:*)
---

# /investigate — answer the question, then stop

Two failure modes bracket codebase investigation. One is stopping too early and answering from a
plausible guess. The other is "look into the codebase" with no boundary, reading three hundred files
and filling the context before any work starts.

This skill fixes both ends: a **declared scope contract** before reading anything, and a **numeric
budget** that ends the search whether or not the answer is complete.

**This skill never modifies anything.** It reads and reports.

## Preconditions

| Condition | If unmet |
|---|---|
| There is a specific question to answer | **Stop.** "Investigate the auth module" is not a question. Ask what decision the answer serves — that determines when to stop. |

## Position in the workflow

| Upstream | This skill | Downstream |
|---|---|---|
| a question, or the start of planning | `/investigate` | `/grill-me`, `/writing-plans`, `/design-review` |

## Files to read

### Always read

| File | Why |
|---|---|
| `${CLAUDE_SKILL_DIR}/reference/evidence-rules.md` | How to report what you found, and what you did not |

### Read only if

| File | Trigger condition |
|---|---|
| `CLAUDE.md`, `AGENTS.md` | When the question concerns project convention rather than mechanism |

---

## Step 1. Declare the scope contract — before reading anything

State, and show the user:

- **The question**, restated precisely.
- **The decision it serves.** This is what tells you when you have enough. "Where is tenant filtering
  applied?" for a security review needs every site; for orientation, one representative site is fine.
- **What you will read** to answer it, and roughly how much.
- **What you are deliberately not reading.**

If the question turns out to be several questions, say so and ask which one matters — do not silently
answer all of them.

## Step 2. Search widest-first, cheapest-first

Escalate. Do not start at the most expensive rung.

| Rung | Tool | Answers |
|---|---|---|
| 1 | `rg` for exact strings, symbols, identifiers | where is this text |
| 2 | `rg` with structural patterns; `ast-grep` if available | where is this *shape* of code |
| 3 | LSP / go-to-definition, if the environment has it | who really calls this, who implements it |
| 4 | reading whole files | how does this actually work |

Most questions are answered at rungs 1–2. **Reading files is the last rung, not the first.** When
you find yourself opening a fifth file to answer a "where is X" question, the search term is wrong,
not the budget.

For a broad question with independent parts, dispatch them to **parallel subagents** — one per part,
in a single message — and synthesise. Each subagent gets its own share of the budget. Investigation
is the single best use of subagents, because the reading stays in their context and only the
conclusion comes back to yours.

## Step 3. Respect the budget

**25 file reads. 3 rounds of search refinement.** Per investigation, including subagents.

On exhausting it: **stop and report**. Do not silently continue. The report names what remains
unverified and what the next 25 reads should target. A partial answer with a known boundary is
usable; an answer that quietly ran out of room is not.

Raise the budget only when the user asks, and say so explicitly.

## Step 4. Report

Follow `${CLAUDE_SKILL_DIR}/reference/evidence-rules.md`. Structure:

```markdown
## <the question>

### Answer
Direct, up front. Two to five sentences. Not a narrative of the search.

### Evidence
| Claim | Where | Confirmed |
|---|---|---|
| tenant filter applied in the repository layer | `src/foo/bar.repository.ts:L42` | read directly |
| batch path goes through the same filter | `src/batch/sync.ts:L88` | read directly |
| the admin path does too | — | **not confirmed** — hit the budget |

### What I did not check
- Named, not implied. "I did not look at X" is information; silence is not.

### Confidence
What is fact, what is inference, and what would settle the rest.
```

## Done when

- [ ] The answer comes first, and answers the question that was asked
- [ ] Every claim has a `file:line` or is explicitly marked unconfirmed
- [ ] Unexamined territory is named
- [ ] Fact and inference are visibly separated

## Anti-patterns

**Reading in order to feel thorough.** If you cannot say which claim a file will support, do not
open it.

**Answering a bigger question than was asked.** Blast-radius mapping for a one-line change is waste.
The scope contract exists to prevent this — write it honestly.

**Hiding a gap in hedged prose.** "It appears that the filter is probably applied" is worse than
"not confirmed: I did not read the admin path". Hedging looks like an answer and is not.
