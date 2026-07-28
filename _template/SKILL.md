---
name: skill-name
description: What it does, in a verb phrase, leading with the words a user would actually type. Then when to use it, as 4-6 trigger nouns. Then inputs and outputs in one clause. Then what it refuses to do. Target 200-350 characters.
metadata:
  source: bwkw/dotagents
---

# /skill-name — one-line role

**Important**: this skill never modifies source code. *(Investigation and review skills only. Delete
this line for skills that do write code, and say plainly what they are allowed to touch.)*

## Preconditions

Stop immediately if any row fails. Report which condition failed. Do not continue.

| Condition | If unmet |
|---|---|
| … | Stop, report the unmet condition, do not proceed |

## Position in the workflow

| Upstream | This skill | Downstream |
|---|---|---|
| … | `/skill-name` | … |

## Files to read

### Always read

| File | Why |
|---|---|
| … | … |

### Read only if

| File | Trigger condition |
|---|---|
| … | … |

> Reading everything "just in case" is forbidden. Load the conditional table only when its trigger
> actually applies.

## Steps

### Step 1. …

## Evidence discipline

- Report only what you verified directly.
- Cite locations as `path/to/file.ts:L42`.
- When you have no basis for a claim, write "could not confirm" — do not guess.
- Separate fact from inference explicitly.
- Attach a URL to any external claim.

## Output

Where it goes and what shape it takes. If the template runs long, move it to
`${CLAUDE_SKILL_DIR}/reference/output-template.md` and point at it here.

## Done when

- [ ] …

## Next

What to run next, and whether to `/clear` first.
