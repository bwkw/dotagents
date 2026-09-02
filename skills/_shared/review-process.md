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

**Measure what you were asked to review, not what the branch contains.** Step 1.3 already forbids
re-deriving the full diff when paths were given; this measurement is bound by the same rule, and it is
the easier one to break because an unscoped number still comes out looking plausible.

```bash
SCOPE=""   # the per-layer file list the dispatcher handed you, or the path in $ARGUMENTS. Empty = the whole diff.
git diff --shortstat "$BASE"...HEAD -- $SCOPE && git diff --name-only "$BASE"...HEAD -- $SCOPE | wc -l
```

| Size | What the report is, and what it must say |
|---|---|
| **≲ 400 changed lines** | A review. Read every changed file in full. |
| **400 – 1,000 lines** | Still a review, but **name which files were read in full and which were skimmed.** A reader cannot calibrate a clean result without knowing which half it came from. |
| **> 1,000 lines** | **Not a review — a sample.** Say so **at the top, next to the map**, not buried in 🔎. State how the sample was chosen (highest-risk paths from the Step 2 trace, the irreversible surfaces, the files the change centres on) and **what was not opened at all**. |

**Sampling applies to reading for semantic correctness, and to nothing else.** Whether the business
logic is right cannot be established for 10,000 lines, and pretending otherwise is the failure this
table exists to stop. But **Step 2b is a whole-diff pass at every size** — architecture conformance,
dependency direction, irreversible surfaces, the tenant boundary, and new write or async entry points
are settled with `grep` and placement checks rather than by reading files, so the diff being large
does not make them unaffordable. **"It was a sample" is never an answer for anything in Step 2b.**

Observed: a 10,729-line review declared itself a sample, worked the perspective clusters over the
files it opened, and reached architecture conformance only when the user asked afterwards — which then
took four tool calls. The cost was never the reason it was skipped; the ordering was.

**Why the threshold is here and not higher.** A large diff does not degrade the review gently; the model
loses coherence and **falls back to pattern-matching on style**, which is exactly the output that looks
like a thorough review and contains none of the findings that matter. Producing plausible style comments
on a 2,000-line diff and calling it reviewed is worse than saying it was sampled — the first hides the
gap, the second hands it to the human.

**Why the threshold counts lines and not files.** `> 40 files` used to share that last row. It had no
mechanism behind it — only the line count did — and the only case it caught that the line count does not
is the wide-and-shallow one: a rename, an import path sweep, one field added to every DTO. **That is
precisely where sampling is worth least.** The risk is spread evenly across the sites and completeness
*is* the review: open 20 of 60 call sites and you have reviewed nothing, because the finding is at one of
the 40 you skipped. The remedy below did not apply there either — a codemod usually cannot be split into
halves that both ship. **Breadth is not what breaks a review; the volume that has to be held together at
once is, and lines measure that.** If you want a breadth signal, count the **independent subsystems** the
change reaches — that is Step 2's job, not this one's.

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

## Step 2b. Conformance sweep — every changed file, every time

**This is the pass that no diff size excuses.** It is mechanical: `grep`, `ls`, and comparing a path
against a rule, over **100% of the changed files**. It costs a handful of tool calls on a 10,000-line
diff, so the size table above never reaches it.

**Load the repository's own rules first.** `CLAUDE.md`, `AGENTS.md`, `.claude/rules/*.md`,
`.cursor/rules/*` — specifically whichever of them states the layer and directory conventions. That
file is the standard; your own sense of good architecture is not. **If no such file exists, say so** —
then the sweep runs on the generic rows below and the architecture verdict is explicitly weaker.

| Swept | The question, asked of every changed file |
|---|---|
| **Placement** | Does each new or moved file sit where the repository's own rules put that kind of thing? Name the rule and the line. |
| **Dependency direction** | Does any import run against the declared direction — domain reaching into infrastructure or api, a module reaching into another module's internals instead of through its declared boundary? One `grep` over the diff's imports answers it. |
| **Irreversible surfaces** | Every migration, schema change, contract change, permission or IAM change, logical-ID or resource-name change. **Enumerate them all**; a missed one cannot be taken back. |
| **Tenant / authorization boundary** | Every new read or write path: is the tenant filter present, and is it applied where the repository says to apply it? |
| **New entry points** | Every new write entry point, async consumer, job handler, or scheduled path — does it carry the guards its siblings carry? Compare against one existing sibling by `file:line`. |

**Report the sweep as a table with a verdict per row**, even when every row passes — a clean
architecture result that is *stated* is worth something, and one that is silently omitted is
indistinguishable from one that never ran. Where a row passes because the change matches an existing
sibling, **cite the sibling**: "matches `year-end-adjustment-csv-export-partition.chunk-handler.ts:52`"
is a verdict; "follows the existing pattern" is not.

The layer's `perspectives.md` carries the concrete shape each row takes in that stack.

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

## Step 5. Work the perspective clusters — the find phase, inline

**This review spawns no subagents. None — not per cluster, not per layer, not for verification.** You
read the diff and work the clusters yourself, in this context, in the order below.

That is a deliberate reversal. The previous version budgeted 0/3/5 find subagents per layer plus a
verifier that "never goes to zero", and it was wrong in three ways at once:

**It bought the wrong thing.** The case for a subagent is *independence* — a reader who did not watch the
finding get made. But every one of these is **the same model, on the same diff, under the same
discipline**, so what comes back is a copy of your own blind spot with a cold-start bill attached. The
toolkit's own measurement says where independence actually comes from: across 146 pull requests reviewed
by four **differently built** tools, **93.4% of findings were caught by exactly one of the four, and none
by all four.** Coverage came from a different *kind* of reviewer, never from another instance of the same
one. `/find-bugs` is that different reviewer here; a subagent is not.

**It cost what it claimed to save.** A subagent starts cold and does not inherit the parent's cached
prefix, so it re-buys the discipline, the diff and the impact map at full uncached price. Measured
fan-out multipliers: **2.6–5.9× the sequential token cost, and not faster in wall-clock** (five
subagents at 4:45 against 4:15 sequential). Width is bought with tokens and does not come back as speed.

**It could not hold in both agents.** Subagent orchestration is the least portable thing this toolkit
does — the `Task` tool is Claude Code's, Cursor's subagents are a different mechanism with different
frontmatter, and a review whose rigour lives in *how many agents were dispatched* is a review that means
something different in the two. Inline, the prose carries the whole method, and **the same file produces
the same review in Claude Code and in Cursor.** That is the property this toolkit is built on.

**What does not change is the questions.** The clusters below are the unit of rigour — they always were;
the subagents were only couriers. Work all five, then the layer's remaining clusters. **Say so in 🔎:
"inline, no subagents"** — never a claim that agents ran.

**When the diff is too big to hold, the answer is not more agents.** It is the one Step 1b already gives:
say it is a sample, name what was not opened, and send the change back to be split. Fanning out over a
3,000-line diff produced plausible style comments and called it reviewed; that is the failure this
paragraph replaces, not a capability being given up.

**Five clusters survive every collapse.** They are the ones where a miss is expensive and a late catch is
a rewrite, so they are never merged away, never sampled, and never dropped for a "small" diff:

| Always covered | Why it cannot wait |
|---|---|
| **0. Design soundness / the question one level up** | The only cluster that can conclude "this should not be built this way". No amount of per-file scrutiny reaches it. |
| **1. Intent and semantic correctness** | **The measured largest category of bugs that survive review — 51.3% of 187 missed bugs across 28 projects, with exception handling alone 36.5% of those.** Code that is internally consistent and answers a different question than the one asked. Reachable only with the stated intent in hand, which is why it cannot be inferred later from the diff. |
| **Architecture and boundaries** | Layer direction, module and context boundaries, where responsibility sits. Wrong here and every later change pays for it. |
| **Aggregates and transaction boundaries (DDD)** | Aggregate granularity, cross-aggregate invariants, what a single transaction is allowed to span. These are decided once and inherited by everything after. |
| **Security, authorization and tenancy** | Cross-tenant leakage, a missing guard, a widened permission. The only category where being wrong once is already the incident. |

**These five come first, then the layer's remaining clusters** in the order the layer file lists them.

**Depth per question still falls as the diff grows, and that is the thing a reader cannot see.** Working
eleven clusters over a 900-line diff in one context gives each less attention than one cluster would get
alone — the same trade the fan-out budget used to make, now made openly instead of being disguised as
five agents. So 🔎 names **any cluster that got only a token pass**, and says which. The honest narrow
review and the dishonest one differ by that sentence, and the uncapped fan-out never wrote it either: it
was equally shallow at 29 subagents and reported nothing about it.

**Three of the five are not eligible for a token pass, because Step 2b already answered them at full
coverage.** Architecture and boundaries, aggregate and transaction boundaries, and security and tenancy
each have a row in the conformance sweep, so what remains for them here is judgement on top of a
complete inventory — not a sampled look. **"Architecture got a token pass" now means Step 2b was
skipped**, which is a different admission, and not one this file permits.

## Step 5b. The five sweeps that apply to every layer

The clusters above are about the code. These five are about **the diff as a whole**, they belong to no
layer, and each one is a category of finding that a cluster-by-cluster read structurally cannot produce.
The first four came out of a real review that landed 14 findings, **half of them in tests, documentation
and naming** — the half a "reviewed the main changes" pass never reaches. The fifth came out of a later
one, where **four of nine findings turned out to be the second copy of another finding.**

**1. Read every file in the diff, one at a time.** Not "the important ones". Tests, fixtures, seed
scripts, scenario files, skill references, specs. A change is not reviewed until every file it touches
has been opened; say which files you opened and which you did not.

**2. Sweep for what the change made stale.** Renames and deletions leave references behind, and nothing
fails. Search the codebase for **every identifier the diff removed or renamed** and judge each surviving
hit as either *a different concept* or *stale*. Specifically:

- references to deleted error classes, functions, types
- prose saying "validated at runtime" where the change moved it into the type
- **counts** — "the 8 axes", "these 3 fields" — which stop being true the moment a shape changes
- cross-references pointing at headings that the diff renamed
- **mirrored documents** (`.claude/` and `.cursor/`, or any doc kept in two places) — both copies
- JSDoc separated from what it documents, by an insertion landing between them

**3. Is the diff proportional to the change?** Abstraction introduced to satisfy a review comment is
still abstraction. A thin wrapper, a utility with one caller, a class that exists to hold two functions:
**ask what deleting it would cost in lines.** If the answer is "nothing", it should not be there. The
same question run the other way: two places assembling the same thing with a few fields different should
be one place.

**4. Was it verified, or was it sent to CI to find out?** "CI will tell us" is not verification when the
repository can reproduce CI locally — find the command and say whether it was run. A completion report
must carry **what was checked and where**: "type errors 0", "unit N passed", "sql against a real
instance N passed", "the production query returns 0 rows". **Anything unchecked is written as unchecked.**
Fixing one annotation at a time and pushing again is a finding about the process, not just the code.

**5. Every finding is a query — run it across the codebase before writing it down.** The four twins in
that review were: the same doc comment left documenting the member below it, on the interface *and* on the
implementation; the same guard expression pasted into a second handler; the same status rule written once
as an entity method and once as a `WHERE` clause. Every one was found by asking **"where else does this
exist?"** — none by reading the file the first copy was in. The places a twin hides:

- **interface ↔ implementation** — the mechanical mistakes get made on both sides, in one sitting
- **sibling handlers, use cases and endpoints** that were copied from each other
- **the read path ↔ the write path** — the same rule as SQL and as a domain method
- **the wire type ↔ the domain type ↔ the editing state** — one shape, narrowed in only one of them
- **mirrored documents**, and a fixture or snapshot holding the shape a second time

Report the set as **one finding carrying every `file:line`**. "And similar elsewhere" is not that: it
leaves the search to the author, who will do it for the sites they remember.

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
