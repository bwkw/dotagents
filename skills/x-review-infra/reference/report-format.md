# Report format

## Merging duplicates

Findings on the same `file` within roughly ±5 lines, or sharing a root cause, **merge into one**:
list both perspectives, take the **highest severity**, and combine `why` and `recommendation`. The
same problem must not appear once per perspective that noticed it.

## Bucketing

Each finding is counted in **exactly one** bucket.

| Bucket | Contents |
|---|---|
| ⛔ | `irreversible=true`. Never also counted under 🔴. |
| 🔴 | `critical` that is not irreversible. |
| 🟡 | warning |
| 💡 | info |
| 🧭 | Design soundness, system-wide and propagation risk, upgraded unverified clears. Things a senior would ask about but cannot call defects. **Exempt from noise caps.** When the harm is legible, it belongs in 🔴/⛔ instead. |
| 👤 | Needs a human: unverified clears, unresolved reachability. |

Summary-table totals must equal the post-merge finding count.

**Output budget** (final report only — separate from the ~3-per-cluster cap during the find phase):
🟡 at most ~7, 💡 at most ~5; fold the overflow into a single aggregate note. Never truncate ⛔, 🔴,
or 🧭.

## How each finding is presented

⛔, 🔴, and 🟡 findings are written as a three-part set, optimised for "comprehensible with no prior
context, and pasteable straight into the PR". 💡 may collapse to a one-line summary.

- **📍 Location** — `path/to/file.ts:123`, the **exact line** the inline comment attaches to. Ranges
  as `:120-135`.
- **Plain explanation** — two to four sentences, avoiding jargon and abbreviations (gloss them if
  unavoidable): what the situation is now, what is wrong with it, and whose problem it becomes if
  left alone. This is context for the person reading the report.
- **💬 Suggested comment**, as a block quote, ready to paste on that line:
  > **[🔴/🟡] One-line summary.** What the problem is (concrete input and state → result) → why it
  > matters → the recommended fix (the relevant API, the direction of the smallest diff,
  > pseudocode if useful). When confidence is low, say "needs confirming: X".

The comment must **stand on its own when displayed as a single line**, since the review UI shows it
attached to a line with nothing around it. **When the plain explanation and the comment would say
the same thing, keep only the comment** — do not pad.

Each ⛔ row gets one 💬 suggested comment with its line. Each 👤 item must state, in the comment,
**what to look at or whom to ask** to settle it.

**This is a proposal, not a post.** The skill is read-only. Actually posting with
`gh pr review --comment` or `gh api` happens only when the user explicitly asks, and then the
bodies above are used verbatim.

---

## Report skeleton

Replace `<Layer>` with Backend, Frontend, or Infra.

```markdown
## <Layer> Review Report

### Change summary
- What / why / how it works
- Blast radius (the related domains, modules, screens, or stacks)

### ⛔ Irreversibility hotspots (highest priority, verified)
| Location | Kind | Why it cannot be undone | Must confirm before release |
|---|---|---|---|
| `file:line` | dropped column / API break / deletion / shared-function fan-out / resource replacement | … | … |

(each row followed by one 💬 suggested comment with its line)

### 🔴 Critical / 🟡 Warning / 💡 Info / 👤 Needs human
Each finding in the three-part set above. 💡 may be one line.

### 🧭 Design and system-wide doubts
Each item: the doubt — why it is concerning — how to settle it. May fall outside the diff.

### 🔎 Confidence of this review — required reading before trusting a clean result
- **What was read versus what was assumed.** Especially: did you actually open the shared or base
  code that the high-risk parts lean on? Cite `file:line`.
- Areas covered only shallowly, and what could not be confirmed. Honestly.
- The caveat: this result means "no defect was detected locally in the diff at this depth". It does
  not mean "a senior signed off on the design".

### 🔬 Filtered out (reference, counts only)
- N refuted during verification
- N scored below the confidence threshold
(one-line summaries only if useful — do not restate them)

### 📊 Summary
| Bucket | Count |
|---|---|
| ⛔ Irreversibility hotspots | |
| 🔴 Critical | |
| 🟡 Warning | |
| 💡 Info | |
| 🧭 Design / system-wide | |
| 👤 Needs human | |
| 🔬 Filtered out | |
```

**A report where nothing was filtered out has not been calibrated.** Reviewers instructed to find
gaps will always find something; acting on all of it produces over-engineering — extra abstraction
layers, defensive code, tests for cases that cannot occur. If the filtered count is zero, say so and
explain why, rather than letting it pass as a thorough review.
