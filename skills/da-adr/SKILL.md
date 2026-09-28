---
name: da-adr
description: アーキテクチャ上の判断を、このリポジトリが実際に ADR を置いている場所へ「判断の記録」として書く。判断が難しく、新規参加者が驚き、トレードオフがある時に使う（grilling・設計レビュー・調査で何かが決まった後）。置き場所はツリーではなくプロファイルから解決する。書くのは ADR だけで、ソースは触らない。
argument-hint: "[判断の内容 | 記録する変更のパス]（省略時は質問する）"
allowed-tools: Read, Grep, Glob, Write, Edit, Bash(git:*), Bash(rg:*)
metadata:
  source: bwkw/dotagents
---

# /da-adr — write the decision down where it will be found

**This skill writes one ADR and nothing else.** It never touches source, schema, migrations or
config. It does not start the implementation and it does not edit the spec or plan the decision came
from.

It exists because the upstream ADR skills **infer the location from the tree** and fall back to
`docs/adr/` or `docs/decisions/`. That produces a well-formed file in a directory nobody in this
repository reads. Where ADRs live is a per-repository fact, so it lives in the profile — the same
place `spec_system` lives, for the same reason.

## Preconditions

Stop immediately if any row fails. Report which condition failed. Do not continue.

| Condition | If unmet |
|---|---|
| The working directory is inside a git repository with an `origin` remote | Stop, say so, do not guess a location |
| **The decision is stated** — what was chosen, and what it was chosen over | **Stop and ask.** An ADR written from an inferred decision reads as authoritative and is wrong in the one place it matters |
| A profile matches this repository and carries `adr_system` | Stop. Report what you observed in the tree, propose the block, and wait. **Observing a directory of ADRs is not being told to write into it** |
| `adr_system.kind` is `none` | Stop. Say the repository does not keep ADRs, and ask — do not create a directory |
| The decision clears all three bars below | Stop and say which bar it misses. Record it in the spec or the commit instead |

**The three bars.** An ADR is for a decision that is **hard** (a reasonable engineer could pick the
other side), **surprising without context** (a newcomer reading the code would ask "why is it like
this?"), and **carries a trade-off** (something was actually given up). A decision that misses any
one of them belongs in the change's design document or the commit message. Most decisions miss one.

## Position in the workflow

| Upstream | This skill | Downstream |
|---|---|---|
| `/grilling`, `/da-design-review`, `/da-investigate`, `/da-spec` | `/da-adr` | `/executing-plans` |

## Files to read

### Always read

| File | Why |
|---|---|
| the matching `profiles/*.json` → `adr_system` | where the ADR goes, and which subtrees it may go in |
| the file named by `adr_system.rules` | the repository's own authoring rules. Writing to a generic template when the repository has written its standard down produces an artifact that fails its own review |
| one existing ADR under `adr_system.roots` | the shape actually in use — headings, language, how alternatives are recorded. Match it |
| `${CLAUDE_SKILL_DIR}/reference/final-design.md` | who the ADR is written for, and the shapes that only parse for someone who was in the conversation |
| `${CLAUDE_SKILL_DIR}/reference/adr-shape.md` | the shape of the ADR itself: title as conclusion, questions ↔ summary ↔ sections numbered one-to-one, premises with sources, what is lost, when to revisit. The newest existing ADR wins where they differ |

### Read only if

| File | Trigger condition |
|---|---|
| the change or spec the decision came from | the decision was settled in a `/da-spec` change — the ADR must not contradict it |
| the code the decision governs | the ADR names identifiers; every backticked name must be confirmed to exist |
| `CLAUDE.md`, `AGENTS.md`, `.claude/rules/*` | the repository has them and `adr_system.rules` delegates to them |

> Reading everything "just in case" is forbidden.

## Steps

### Step 1. Resolve the location — do not choose one

Read `adr_system` from the profile. **Never pick a directory because ADRs appear to be there.** A
tree can carry a half-finished migration, and the failure is quiet in the worst way: the file lands
somewhere real, well-formed, where nobody looks.

For `kind: colocated`, the ADR goes next to the code it governs, inside one of `roots`. Name the
subtree you chose and why. For `kind: directory`, it goes under the single root.

### Step 2. Look for the ADR that already exists

Search by **subject, not by title** — an ADR for the same decision under a different name splits the
record, and neither half is wrong on its own.

```bash
rg -l "<the entity, table, endpoint or rule>" --glob 'ADR.*' --glob 'docs/**'
git log --oneline -20 -- '**/ADR.*'
```

Found one covering this decision: **update it, and say what was already there.** A decision that
reverses an earlier one supersedes it explicitly — do not leave two ADRs disagreeing in silence.

### Step 3. Write it as the final design

Follow `${CLAUDE_SKILL_DIR}/reference/final-design.md`. It carries the reader, the shapes to cut, and
the test to apply before calling the draft done — shared with `da-spec` so the two cannot drift into
disagreeing about what a finished document reads like.

Then lay it out per `${CLAUDE_SKILL_DIR}/reference/adr-shape.md`: the sections, the sub-headings a
decision section carries, and the writing rules (constraints stated as what cannot be answered,
future changes stated as the number of places to touch, no unmeasured "small").

One rule is this skill's own: **every alternative that was seriously considered gets its rejection
reason.** An ADR with no rejected alternative is describing, not deciding.

### Step 4. Ground every name

Each backticked identifier — a file, table, column, class, flag — is confirmed to exist before it is
written. A renamed symbol makes the ADR read as authoritative and wrong. Cite as `path/file.ts:L42`
where the reader would otherwise have to search.

### Step 5. Check the rendering, if the ADR is in Japanese

CommonMark will not close a `**` that sits directly after a Japanese full stop or comma — the
right-flanking rule fails and the asterisks render literally. Keep the punctuation outside the bold.

## Evidence discipline

- Report only what you verified directly.
- Cite locations as `path/to/file.ts:L42`.
- When you have no basis for a claim, write "could not confirm" — do not guess.
- Separate fact from inference explicitly.
- Attach a URL to any external claim.

## Output

One file, at the resolved location, in the shape the existing ADRs use.

Then report, in this order:

1. **置き場所** —— どのプロファイルから解決したか。解決できなければ欠けているものと質問
2. **新規か更新か** —— パス。更新なら既にあった内容
3. **3 つの条件をどう満たしたか** —— 各 1 行
4. **未決のこと** —— 確かめられなかった前提を、ADR の本文ではなく質問として

## Done when

- [ ] The location came from the **profile**, not from what the tree looked like
- [ ] `adr_system.rules` was read **before** writing
- [ ] An existing ADR on the same subject was searched for, and the choice to update or create is
      stated with its reason
- [ ] Every rejected alternative carries its reason
- [ ] The `adr-shape.md` checklist passes: the title states the conclusion, and questions, summary and
      sections share one `§` numbering
- [ ] Every backticked identifier was confirmed to exist
- [ ] Nothing outside the resolved location was written, and no implementation was started

## Next

`/executing-plans` on the change the decision belongs to. The ADR is the standing record; the change
is the work.
