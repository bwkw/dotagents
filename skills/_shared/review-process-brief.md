# Review procedure — the brief form

**Read this instead of `review-process.md` + `finding-discipline.md` + `verification.md` +
`report-format.md` when, and only when, the diff is at the inline tier: ≤ 80 changed lines and ≤ 5
files.** It is self-contained on all four.

**`perspectives.md` is still read.** It carries the layer's own clusters, which is the entire reason the
layer skill exists rather than a generic one — dropping it would be cutting questions, and this file cuts
only prose.

The full form is ~76 KB of process text and it is a fixed cost — it does not shrink with the diff. On a
measured 11-line, one-file landing the review spent $5.64 and 50 turns against $1.30 for the
implementation it was reviewing, with the fan-out already at zero. There was no fan-out left to cut. The
cost was the reading and the report shape, so that is what this file cuts.

**What is cut is the prose, never the questions.** The five clusters below are the same five the full
form refuses to collapse, the confidence threshold is the same, and the verify pass is the same. If you
find yourself wanting a rule that is not here, read the full form — do not invent one.

---

## 0. Confirm the tier before anything else

```bash
BASE=""
for b in "$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')" \
         origin/develop origin/main develop main; do
  [ -n "$b" ] && git rev-parse --verify --quiet "$b" >/dev/null 2>&1 && BASE="$b" && break
done
git diff --shortstat "$BASE"...HEAD && git diff --name-only "$BASE"...HEAD | wc -l
```

**Over 80 lines or over 5 files: stop reading this file and use the full form.** The tier is a fact about
the diff, not a preference. `BASE` empty (detached HEAD, first commit) → diff against
`4b825dc642cb6eb9a060e54bf8d69288fbee4904` and say so. Empty diff → report "no changes" and stop.

## 1. Whose change is this, and what is it for

Your own work: the intent is known. **Someone else's: reconstruct the intent before judging anything** —
PR description, linked issue, commit messages. If none exist, say so and review against the repository's
own conventions rather than a guessed goal. **A different approach is not a defect.** Label pre-existing
problems as pre-existing; they do not block.

## 2. Map the blast radius, then read

Name every consumer of anything shared the change touches, and the adjacent assets — migrations,
schemas, contracts, config, tests. At this tier the map is a few lines, but it is not optional: it is
what decides whether 80 lines are 80 lines of risk or 80 lines of nothing.

## 3. The five clusters — inline, in this context, in this order

**No subagents — at this tier or any other.** You already hold the diff, the map and this file; a
subagent would start cold and buy all three again, and it would be the same model returning your own
blind spot. **Subagents were never the unit of rigour — the clusters are.**

| Cluster | The question it exists to ask |
|---|---|
| **0. Design soundness** | Should this be built this way at all? The only cluster that can conclude no. |
| **1. Intent and semantic correctness** | Is the code internally consistent and answering a *different question* than the one asked? Measured as 51.3% of bugs that survive review — the largest single category. |
| **2. Architecture and boundaries** | Layer direction, module boundaries, where responsibility sits. |
| **3. Aggregates and transaction boundaries** | What one transaction may span; cross-aggregate invariants. |
| **4. Security, authorization, tenancy** | Cross-tenant leakage, a missing guard, a widened permission. The one category where being wrong once is already the incident. |

Then the layer's own clusters, as far as the diff reaches them. At this size most will not apply — say
which did not, rather than implying all were worked.

## 4. Finding discipline — the whole of it that applies here

- **"Same as existing" is a hypothesis, not a conclusion.** Write "safe" only after opening the guard and
  citing `file:line`. Otherwise write "unverified" and file it as 👤. Never disguise not-knowing as verified.
- **Score each finding 0–100** on one question: would a competent engineer who knows this codebase agree
  this is a real problem worth acting on? **Discard `defect` below 80** — remove it, report only the count.
  `design-doubt` (🧭) and `unverified-clear` (👤) are exempt: their value does not depend on being right.
- **`irreversible=true` only when you can name the data or state destroyed** and no redirect, migration,
  backfill, restore or config revert recovers it.
- **Reachability before severity.** "This branch exists" and "this branch runs in production" are
  different claims. Cannot show which caller, which permission, which timing? It goes to 👤, not to 🔴.
- **Zero findings is a valid result.** Never invent findings to fill a quota. Do not report what CI
  catches mechanically, and do not report a style preference the project has not written down.
- **Length is not evidence.** A finding is worth what its `file:line` is worth.

Return schema: as in `finding-discipline.md` — `{id, severity, irreversible, file, perspective, finding,
why, recommendation, comment, kind, confidence}`.

## 5. Verify — a second pass, in this context, with the question inverted

**No subagent.** A fresh one is the same model on the same diff under the same discipline: it returns
your own disposition with an empty context, and a report saying "a verifier confirmed it" reads as
stronger than "I checked my own work". **Real independence is `/find-bugs` — a differently built
reviewer** (93.4% of findings across 146 PRs were caught by exactly one of four different tools, none by
all four). Route to a stronger model where one is available (`--advisor`) and say so.

What makes this a real pass rather than a re-read: **invert the question, and judge only the evidence.**

- **6a, refutation** — for every `critical` or `irreversible` finding: read the actual path and try to
  show the claimed failure **cannot** happen. **When you cannot substantiate a finding, return
  `refuted`, not `uncertain`.** Reserve `uncertain` for genuinely data- or runtime-dependent cases.
  `confirmed` → keep; `refuted` → drop, report the count only; `uncertain` → demote to 👤.
  **Take them in reverse severity order**, 💡 first and ⛔ last: whatever you judge first sets the tone,
  and judging your own ⛔ first is the arrangement most likely to launder the list.
- **6b, the skeptic** — a distinct pass, *after* 6a rather than mixed into it, or the refuting frame
  answers the hunting one. Challenge the clears: the high-risk places dismissed as "same as existing",
  read the actual guard and cite `file:line`. Then one fresh pass over the most irreversible surfaces for
  what find missed, and confirm cluster 0's 🧭 candidates were not quietly dropped.

**🔎 says "self-verified inline, not independently".** A reader who thinks an independent agent signed
off will weight the clean parts wrongly, and that misweighting is the whole cost of doing this inline.


**The infrastructure exception overrides reachability**: for a destructive or permission-widening change,
improbability is not a refutation. Refute only by showing the guard exists.

**Escalate to the full form for one case**: a surviving ⛔ or a 🔴 on an irreversible surface gets the
three-lens pass in `verification.md` (reachability / existing guard / severity) and the full four-part
presentation in `report-format.md`. **The tier decides the process, not the seriousness of what it
finds** — a small diff is allowed to contain one large problem, and that is exactly the case this
paragraph exists for.

## 6. Report — short form

Same buckets, less ceremony. Findings still carry `file:line` and a concrete failure scenario; what is
dropped is the four-part expansion for everything below ⛔/🔴.

```markdown
## <層> レビュー報告（brief — inline tier）

### 変更内容
| 領域 | 変更前 | 変更後 | なぜ（読み取れた意図） |
|---|---|---|---|
（読者が認識するもの。ファイルパスとクラス名は禁止。意図が読み取れなければ「不明」と書く —— それ自体が 👤）

仕組みを1〜2文。影響範囲 —— **読まなかったものも名指しする。**

### 所見
各件: `file:line` / 一行の指摘 / 具体的な失敗（入力と状態 → 結果）/ 💬 そのまま貼れるコメント。
⛔ と、不可逆な面の 🔴 だけは `report-format.md` の四部構成に展開する。

### 🧭 設計とシステム全体への疑い / 👤 人間の判断が必要
差分の外でもよい。何を見れば決着するかを書く。

### 🔎 このレビューの確度
読んだもの／仮定したもの／見なかったもの。**"brief 版・inline・サブエージェント無し・検証は自己検証"と明記する。**
綺麗な結果は「この深さで検出されなかった」であって「安全」ではない。

### 🔬 除外 / 📊 集計
除外は件数のみ。除外ゼロなら、なぜかを書く（校正されていないレビューの徴候）。
```

**Write the report in the language the user is writing in**; when unclear, Japanese. Leave paths,
identifiers, commands, code excerpts and severity emoji in their original form.

**🔎 must say this is the brief form.** A reader cannot calibrate a clean result without knowing which
process produced it, and this file's entire justification is that the reader is told.

---

## Guardrails

- **Never modify code or configuration. Report findings only.**
- Every finding carries a `file:line` and a concrete failure scenario. No general advice.
- Design soundness and system-wide risk are raised as 🧭 even outside the diff.
- Do not run `typecheck` or `tsgo`. Leave it to CI and the developer.
