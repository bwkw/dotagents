# Review procedure

The seven-step shape every layer review follows. The layer file supplies what is layer-specific:
what to trace during impact mapping, and the perspective clusters. Everything else is here.

**Read `finding-discipline.md` before starting.** It carries the posture and the reporting rules,
and it is mandatory for every subagent you launch.

---

## Step 1. Establish scope

**First: whose change is this?** It decides what you may assume, and getting it wrong is the most common
way a review lands badly.

| | Your own work | **Someone else's** |
|---|---|---|
| The intent | Known — the spec, the plan, the conversation | **Unknown. Reconstruct it before judging anything.** |
| A different approach than you would take | A design doubt worth raising | **Not a finding.** See below. |
| "This is missing" | Probably missing | **Possibly elsewhere, or deliberate.** Look before saying it. |

When it is someone else's, spend the first pass on **intent, not defects**:

1. Read the PR description, the linked issue, the commit messages, and any spec or ADR the branch
   references. State back what you believe the change is for **before** producing a single finding.
2. If the intent is genuinely unavailable — no description, no issue, no spec — say so in the report and
   review against the **repository's own conventions** instead. Do not invent a goal and then measure the
   change against it; a review built on a guessed intent produces confident, wrong findings.
3. **A difference in approach is not a defect.** "I would have done this with a value object" is a 🧭 at
   most, and only when you can name a concrete cost. The author had context you do not; the review's job
   is to find what is *wrong*, not what is *unfamiliar*.
4. Separate **pre-existing** problems from **introduced** ones, and label them. A defect the diff merely
   moved past is worth mentioning once, marked as pre-existing, and it does not block the change.

Then the mechanics:

1. `$ARGUMENTS`: empty means the working diff; a branch means the diff against it; a path means an
   audit of that path; `all` means the whole repository.

2. Resolve the base branch (diff mode) — take the first that exists:

   ```bash
   BASE=""
   for b in "$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')" \
            origin/develop origin/main develop main; do
     [ -n "$b" ] && git rev-parse --verify --quiet "$b" >/dev/null 2>&1 && BASE="$b" && break
   done
   ```

   Then `git diff --stat "${BASE}"...HEAD` and `git diff "${BASE}"...HEAD`.

3. **When explicit paths are given** — `$ARGUMENTS` is a path or file, or the dispatcher handed you a
   per-layer file list — do **not** re-derive the full diff. Scope strictly to those paths.

4. Edge cases:
   - Empty diff → report "no changes", suggest a `path/` or `all` audit, and stop.
   - `BASE` empty (detached HEAD, no upstream, first commit, missing ref) → diff against the empty
     tree and say so: `git diff 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD`.
   - If the default branch that `symbolic-ref` returned looks like it is not the real PR base, ask.
   - If the change also touches other layers, say so and suggest `/da-review-all` across all of them.

## Step 1b. 差分の大きさを測る —— 大きければ「レビュー」と呼ばない

**Before reading anything, count the diff**: changed lines and changed files. This is the one measurement
that decides whether the output is a review or a sample, and **it has to be taken before the reading
starts**, because afterwards it is indistinguishable from an excuse.

```bash
git diff --shortstat "$BASE"...HEAD && git diff --name-only "$BASE"...HEAD | wc -l
```

| Size | What the report is, and what it must say |
|---|---|
| **≲ 400 changed lines** | A review. Read every changed file in full. |
| **400 – 1,000 lines** | Still a review, but **name which files were read in full and which were skimmed.** A reader cannot calibrate a clean result without knowing which half it came from. |
| **> 1,000 lines, or > 40 files** | **Not a review — a sample.** Say so **at the top, next to the map**, not buried in 🔎. State how the sample was chosen (highest-risk paths from the Step 2 trace, the irreversible surfaces, the files the change centres on) and **what was not opened at all**. |

**Why the threshold is here and not higher.** A large diff does not degrade the review gently; the model
loses coherence and **falls back to pattern-matching on style**, which is exactly the output that looks
like a thorough review and contains none of the findings that matter. Producing plausible style comments
on a 2,000-line diff and calling it reviewed is worse than saying it was sampled — the first hides the
gap, the second hands it to the human.

**The right move above the threshold is usually to send it back.** Say plainly that the change is too
large to review as one unit and name the split you would make. `da-design-review` decides that split at
design time; a change that arrives unsplit missed that step, and reviewing it anyway rewards skipping it.

## Step 2. Impact mapping — mandatory, before reading for defects

Do not stop at the changed lines. **Map the blast radius first**, then decide what to read.
The layer file lists what to trace. In every layer:

- **Enumerate the changed units.**
- **Trace dependencies in both directions.** A change to anything shared — a utility, a base class,
  a common module, a shared construct — requires naming **every** module, screen, stack, or pipeline
  that uses it. Behaviour changes propagate to all consumers.
- **Enumerate every related domain, screen, or environment** the change reaches. Everything named
  here becomes required reading for the subagents in Step 5.
- **List adjacent assets**: migrations, schemas, contracts, seeds, config, tests.

## Step 3. Explain the change — goes at the top of the report

Written so someone who has never seen this change understands it:

- **What this PR changes** (1–3 lines) / **why** (background, the problem) / **how it works** (the
  main flow and data movement; before-and-after if it helps).
- **Blast radius** — the list from Step 2.
- Pull the intent from the PR or ticket when available (best effort; continue without it):
  ```bash
  gh pr view --json title,body 2>/dev/null   # ignore failure
  ```

## Step 4. Absorb project context

Read `CLAUDE.md`, `AGENTS.md`, `.claude/rules/*.md`, and any relevant skills, and adopt the
project's own conventions as the standard. Identify the framework and stack from the diff. Run the
generic checks even when there is no project context to be found.

## Step 5. Fan out by perspective — the find phase

Launch one subagent per perspective cluster, **all in a single message so they run in parallel**.

Use **`x-codebase-explorer`** for clusters that are mostly tracing — who calls this, where does the data
go, what else touches this pattern. Use `general-purpose` for clusters that need judgement about the
design. Pass every subagent its cluster's checklist from the layer file, and **never skip a cluster**
because the ideal agent for it is unavailable.

> `x-codebase-explorer` and `x-review-verifier` are installed globally by this toolkit, so they exist in
> every repository. Do not wait for a repository to define an agent — by design this toolkit never
> adds a file to a product repository, so a repository-local agent will never appear.

> **Above the inline tier, never run perspective review in the main context.** Dispatch to subagents and
> wait for all of them before synthesising. The reason is not speed: a perspective read in the main
> context stays in the main context, and crowds out the synthesis that follows.
>
> **That reason is proportional to the reading, which is why the inline tier exists.** A 60-line diff
> does not produce enough context to crowd anything out, and isolating it costs a full cold subagent —
> one that re-reads 9 KB of discipline plus the diff plus the impact map to look at sixty lines. Below
> the threshold the isolation is pure overhead, so the budget spends zero there.

Hand every subagent:

- the base and the scope
- the Step 2 impact map, including the full list of related domains
- its cluster's checklist, from the layer file
- "irreversibility is the highest priority"
- "in high-risk areas, do not settle for 'same as existing' — read the actual guard and cite
  `file:line`, or state explicitly that it is unverified"
- **three absolute paths, with an instruction to read them first — not their contents:**
  `${CLAUDE_SKILL_DIR}/reference/finding-discipline.md`,
  `${CLAUDE_SKILL_DIR}/reference/silent-failure-patterns.md`,
  `${CLAUDE_SKILL_DIR}/reference/llm-authored-code.md`.

  Paths, because pasting a file in makes you hold a copy you never apply on top of the copy each subagent
  pays for anyway, and a pasted copy is the one that gets silently abridged when the prompt grows. The
  last two you do **not** read at all — see "Hand down, do not read" in the layer file. **If a brief omits
  them, that subagent reviews without the silent-failure patterns**, which is the miss they exist to
  prevent, so it is worth checking the briefs rather than assuming.

### The fan-out budget — how many subagents, decided by the number from Step 1b

**This is a budget, not a suggestion.** "Scale the fan-out to the change" was the instruction here for a
while, and it produced maximum fan-out every time, because nothing in it could be checked. The layer
files list 9 to 11 clusters; one subagent per cluster on a three-layer change is 29 find subagents before
verification has spent anything.

Take the changed-line count from Step 1b — it is already measured by then — and spend accordingly:

| Diff, from Step 1b | Find subagents **per layer** |
|---|---|
| ≤ 80 lines, ≤ 5 files | **0 — run the five always-covered clusters inline, in this context** |
| ≤ 400 lines | **3** |
| > 400 lines, or > 15 files | **5** |

**The bottom tier spends no find subagents at all.** Read the diff yourself and work the five clusters
below in order. You already have the diff, the impact map and the discipline loaded; a subagent would
start cold and buy all three again to look at sixty lines. **Subagents are not the unit of rigour** —
the clusters are. Running them inline is the same review with the courier removed, and the report says
so plainly: "inline, no find subagents" in 🔎, never a claim that five agents ran.

**Five is the ceiling, and it does not rise.** Not for a 3,000-line diff, not for a wide impact map. Two
independent measurements put the ceiling there: multi-agent code review F1 **plateaus around n=5–10**, and
scaling *homogeneous* agents — which these are, same model and same discipline — shows marginal gain per
agent collapsing toward zero, because copies of one reviewer converge on the same blind spot. Above the
ceiling the honest move is the one Step 1b already names: **say it is a sample, and send the change back
to be split.** Buying a sixth subagent instead is paying for coverage the measurement says you do not get.

**The budget counts subagents, not clusters, and one subagent can carry several.** That is the whole
mechanism: at 5 subagents a layer's 9–11 clusters are *grouped* into 5 briefs, not cut down to 5. At 1
subagent, all five always-covered clusters below go into that one brief. What the budget limits is how
many times you pay the cold-start and the re-read, not how many questions get asked.

**Concurrency:** launch a layer's find subagents in one message, but **do not launch two layers' fan-outs
at once.** Every subagent starts cold — a subagent does not inherit the parent's cached prefix, so it pays
full uncached price for everything it reads — and overlapping cold fan-outs turn one cache miss into a
stampede. Measured fan-out multipliers sit at **2.6–5.9× the sequential token cost**, and in the same
measurements the fan-out was **not faster in wall-clock** (five subagents at 4:45 against 4:15 sequential).
Width is bought with tokens and does not come back as speed.

**Say the shape in 🔎: the budget tier you used, how many find subagents ran, and which clusters were
collapsed into which.** A reader cannot calibrate a clean result without it, and it is the only record of
what a review cost — this toolkit has no other cost instrumentation.

**Five clusters survive every collapse.** They are the ones where a miss is expensive and a late catch is
a rewrite, so they are never merged away, never sampled, and never dropped for a "small" diff:

| Always covered | Why it cannot wait |
|---|---|
| **0. Design soundness / the question one level up** | The only cluster that can conclude "this should not be built this way". No amount of per-file scrutiny reaches it. |
| **1. Intent and semantic correctness** | **The measured largest category of bugs that survive review — 51.3% of 187 missed bugs across 28 projects, with exception handling alone 36.5% of those.** Code that is internally consistent and answers a different question than the one asked. Reachable only with the stated intent in hand, which is why it cannot be inferred later from the diff. |
| **Architecture and boundaries** | Layer direction, module and context boundaries, where responsibility sits. Wrong here and every later change pays for it. |
| **Aggregates and transaction boundaries (DDD)** | Aggregate granularity, cross-aggregate invariants, what a single transaction is allowed to span. These are decided once and inherited by everything after. |
| **Security, authorization and tenancy** | Cross-tenant leakage, a missing guard, a widened permission. The only category where being wrong once is already the incident. |

**These five are placed first, then the layer's remaining clusters are distributed across the same
subagents** in the order the layer file lists them. Grouping is what shrinks — never the list of questions.

But grouping is not free, and this is the part to be honest about in the report: **six clusters in one
brief get less attention each than one cluster in one brief.** Depth per question falls as the budget
falls, which is correct — a 40-line diff does not need the depth a 900-line one does — and it is the thing
a reader cannot see. So 🔎 names the grouping, and any cluster that got only a token pass is said to have
got one. The cap does not make a narrow review wide; it makes a narrow review **honest about being
narrow**, which the uncapped version was not either — it was equally shallow at 29 subagents and reported
nothing about it.

## Step 6. Verify

Follow `verification.md`. Both 6a (refutation) and 6b (challenging the clears, hunting what was
missed) are mandatory.

## Step 7. Synthesise

Follow `report-format.md`.

---

## Guardrails

- **Never modify code or configuration. Report findings only.**
- Every finding carries a `file:line` and a **concrete failure scenario**. No general advice.
- ⛔, 🔴, and 🟡 always use the three-part presentation. Suggested comments stay suggestions;
  posting happens only when the user explicitly asks.
- **Never disguise not-knowing as verified.** Safety you have not read is "unverified" and goes to
  👤 or 🧭. "Same as existing or siblings" is not grounds for a clear without a `file:line`.
- **When you report clean, state its limits under 🔎** — what you read, what you assumed. Never
  present "no findings" as unconditional proof of safety.
- **Design soundness, system-wide risk, and propagation always get raised as 🧭, even outside the
  diff.** Do not hide behind diff scope.
- Behaviour changes to shared utilities and common foundations must be assessed for irreversibility
  across **every consumer** enumerated in Step 2.
- Do not report what CI catches mechanically (formatting, lint minutiae). Concentrate on design,
  irreversibility, and security.
- Requirement conformance is flagged best-effort only; the final call is 👤.
- Do not run `typecheck` or `tsgo`. Leave it to CI and the developer.
