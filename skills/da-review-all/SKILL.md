---
name: da-review-all
description: The entry point for every code review — one layer or many. Use for PR review, reviewing a diff, or checking work before shipping, including when only the backend, only the frontend, or only infrastructure changed. Classifies the change, reviews each layer against its own checklist, then finds the irreversible risks that fall between them, like a contract and its consumer shipping out of order. Read-only.
argument-hint: "[base-branch | path/ | file | 'all'] (default: the working diff and its blast radius)"
allowed-tools: Read, Grep, Glob, Write, Skill, Artifact, Bash(git:*), Bash(gh:*)
metadata:
  source: bwkw/dotagents
---

# /da-review-all — cross-layer review dispatcher

Works out which layers a change touches and runs **only the layer reviews that apply**. When one
change spans several layers — a schema change, the code that reads it, the infrastructure that hosts
it — this removes both the work of invoking each layer by hand and, more importantly, the
**cross-layer irreversibility risks that are invisible from inside any single layer**.

**Read-only. This skill never modifies code or configuration.** The Step 5 overview is a review
artifact, not a source change.

**What it hands back depends on whose change it is** (Step 1). Someone else's PR → an **overview page
plus comment drafts in the user's voice**, with the layer reports as working material that never
reaches the terminal. Your own work, or a diff with no PR → the layer reports, as before.

## Preconditions

| Condition | If unmet |
|---|---|
| The working directory is inside a git repository | Stop, say so, do not proceed |
| A diff, path, or `all` resolves to at least one file | Report "no changes", suggest `path/` or `all`, and stop |

Upstream: implementation complete, or a PR open. Downstream: `/da-fix-plan` triages the findings into
an ordered plan, then `/da-verify`.

## What this skill delegates to

| Layer skill | Owns |
|---|---|
| `x-review-backend` | server-side source, migrations and schema, contracts and DTOs, queues and jobs, dependencies |
| `x-review-frontend` | components, routes, hooks, stores, styling, frontend i18n |
| `x-review-infra` | Terraform, CDK, CloudFormation, k8s, IAM, networking, pipelines, CI permissions |

Each is a full skill with its own posture, process and perspectives. This one classifies the change,
runs the layers that apply, then does the part none can.

## Files to read, and when

**Nothing up front.** Each opens at the step that applies it; read early it just sits in context.

| File (under `${CLAUDE_SKILL_DIR}/reference/` unless noted) | When |
|---|---|
| `profiles/review-voice.md` — **toolkit root**, not `reference/` | **Step 1**, the moment ownership resolves to someone else. Read late, the register gets rebuilt from scratch. |
| `cross-layer.md` | **Step 4, always** — the ten checks and the skeleton |
| `silent-failure-patterns.md` | **Step 4, ≥2 layers** — the single-layer form, re-read across the boundary |
| `llm-authored-code.md` | **Step 4, ≥2 layers**, agent-authored — both sides of a boundary agreeing with each other and wrong about the world |
| `decisions-sweep.md` | **Step 4b**, someone else's PR |
| `overview-artifact.md` | **Step 5** — the six sections and this host's container |
| `../_shared/pr-comments.md` | **Step 6**, and its PR-mapping part at Step 1 |

**One layer: of the Step 4 rows read only `cross-layer.md`**, say **no cross-layer impact**, pass
through. Steps 1 / 4b / 5 / 6 are unaffected — a single-layer PR still gets the page and drafts.

---

## Step 1. Establish scope, then ownership

`$ARGUMENTS`: empty means the working diff; a branch means the diff against it; a path means an audit
of that path; `all` means the whole repository.

Resolve the base and the file list exactly as `../_shared/review-process.md` Step 1 does — same
fallback order, same empty-tree case, and **say so** when the base could not be resolved. Every layer
uses that resolution, so it is not restated here.

**No PR is required.** Review before pushing is when it is worth the most; a PR URL is accepted but
never demanded. If the diff is genuinely empty, report "no changes", suggest `path/` or `all`, stop.

**Several PRs or several repositories are one review, not N.** Resolve them all here, and **record
which PR's diff each file belongs to** — a line comment can only land on the PR whose diff contains
that line, and a stacked PR's base is the branch below it, not the trunk. The mapping procedure is in
`pr-comments.md`; run it now, while the branches are fetched.

### Whose change is this

```bash
gh pr view <n> --json author -q .author.login    # or: git log -1 --format=%ae
git config user.email
```

`review-process.md` Step 1 says ownership decides what you may assume. It also decides what you hand
back:

| | Your own work / no PR | **Someone else's PR** |
|---|---|---|
| Deliverable | The layer reports | **Overview page + comment drafts in the user's voice** |
| Layer reports | Printed | **Working material, never printed.** Their 🔎 and 🔬 move onto the page; the rest is consumed by the page and the drafts |
| Read at Step 1 | — | `profiles/review-voice.md` (toolkit root) |
| Extra step | — | Step 4b, the decisions sweep |

**Ambiguous — a shared branch, a pair-written change — ask.** Guessing wrong costs a whole deliverable
in the wrong shape.

## Step 2. Classify each file into layers

One file may belong to several layers.

| Layer | Signals |
|---|---|
| **infra** | `*.tf`, `cdk.json`, constructs under `lib/**`, `template.ya?ml` (CFn/SAM), `serverless.yml`, k8s manifests, platform or runner `Dockerfile`, `*.snap` (IaC snapshots), IAM / networking / pipeline definitions |
| **backend** | server-side source (NestJS, Express, …), `*.prisma` and migrations, API contracts and DTOs, domain / use case / repository code, Lambda handlers |
| **frontend** | `*.tsx`, `*.jsx`, `*.vue`, `*.svelte`, route definitions, components, hooks, stores, CSS and styling, frontend i18n resources |
| **build / deps / CI** | `package.json`, `*-lock.*`, Renovate and dependency config, `.github/workflows/**`, application `Dockerfile`. Route **dependencies and supply chain to backend**, and **CI permission or secret changes to infra** |

For a monorepo or several repositories, classify per repository and per directory. Files you cannot
place: read them and classify by content; if still unclear, list them as **unclassified** — never drop
one silently.

**Print the classification, then keep going — do not wait for confirmation.** It must be *visible* (a
misclassification loses a whole layer), not *approved*: blocking bought no accuracy and cost a round
trip every run. **Stop for one case only — an unclassified file.** That is the sole branch where
continuing means guessing.

## Step 3. Run the layer reviews — inline, one after another

**Spawn nothing.** For each layer with files, invoke that layer's skill **by name, in this context**,
scoped strictly to that layer's file list:

> Use the `x-review-<layer>` skill and follow it exactly. Scope: `<the list>`. Do not re-derive the
> full diff.

Finish one layer before starting the next. The layer skill handles posture, process, perspectives and
the silent-failure patterns. **Do not restate its instructions here** — guidance a layer needs belongs
in that layer's own skill.

> **Never set `disable-model-invocation` on a layer skill.** It blocks programmatic `Skill` calls too,
> so this step becomes a silent no-op. The linter and the lint hook both check for it.

**Why no subagents** — measured account in `review-process.md` Step 5 and `docs/decisions.md`. Short
form: same model, same diff, same discipline returns this context's blind spot at 2.6–5.9× the tokens
and no less wall-clock; independence comes from a **differently built** reviewer, `/find-bugs`.
**Say "inline, no subagents"** — never imply agents ran.

**Check each layer reported its Step 2b conformance sweep** — architecture, dependency direction,
irreversible surfaces, tenancy, new entry points, over its **whole** file list with a verdict per row,
at any diff size. **A layer calling architecture a token pass has skipped Step 2b**; send it back.

**Unclassified files**: fold each into the nearest layer by content. Anything you genuinely cannot
place, review openly at Step 4 and mark **"not reviewed / needs confirmation"**.

## Step 4. Cross-layer synthesis — what only this skill can do

**Wait until every layer report is in**, then read `cross-layer.md` and apply **all ten** checks — the
four structural forms, the five patterns in their cross-layer shape, and the sixth that exists only
across a boundary. Each appears only when cause and consequence sit in **different layers**, which is
why no layer review reaches them: every half is locally correct.

**Pull every layer's 🧭 and 👤 to the top**, and **merge duplicates** — the same root cause in two
layers becomes one finding naming both, counted **once**. Never add per-layer totals.

## Step 4b. The decisions sweep — someone else's PR only

Read `decisions-sweep.md`. Two sources: a mechanical marker sweep over the whole diff, and — where the
surprises are — the decisions the review itself surfaced that carry no marker at all.

**Say what changes depending on the answer**, not that the item is open. The TODO restated is worth
nothing; the author wrote it.

## Step 5. The one-page overview

Read `overview-artifact.md` for the six sections and the container: **Artifact in Claude Code, Canvas
in Cursor, a written HTML file where neither exists.** Sections identical in all three.

**The page is about the change, not about the review** — what it enables, how it relates to what
exists, how it flows, where the code sits, what ships in what order, what is undecided. Findings live
in the drafts; the page carries the 🔎 / 🔬 honesty rows and the decisions.

On the own-work path, offer it in one line rather than building it unasked.

## Step 6. Comment drafts and the terminal index — someone else's PR only

Follow `pr-comments.md` end to end: select by rule, draft in the voice loaded at Step 1, **verify every
anchor against the PR head**, show the drafts, wait for the literal `Go`.

**The terminal gets an index, not a report.** Per draft: target, severity, one line. Then the link to
the page. **Nothing on the page or in a draft is restated here** — that duplication is what made an
earlier run write one finding four times.

## Done when

- [ ] **Ownership resolved before anything was produced**, and the deliverable matches it
- [ ] Classification shown **before** any review ran; every file in a layer, an unclassified one having
      stopped the run
- [ ] **Every layer reported its Step 2b sweep with a verdict per row.** A layer that sampled
      architecture, tenancy or the irreversible surfaces skipped the step no size excuses
- [ ] Every layer with files invoked **by skill name** — a layer reported as covered with nothing
      behind it is the failure this dispatcher exists to avoid
- [ ] 🔎 says **"inline, no subagents"**, names what it did not reach and any token-pass cluster, and
      states that a clean result is not a sign-off
- [ ] **All ten `cross-layer.md` checks applied**; every 🔗 names **both** layers with a 📍 on each
      side; merged duplicates counted once; a single-layer change says **no cross-layer impact**
- [ ] **One overview page in this host's container**, linked, with **no finding on it restated** in the
      terminal or a draft
- [ ] Someone-else's-PR path: drafts written **after** the voice profile loaded, **every anchor verified
      against the PR head** before posting, decisions sweep ran

## Guardrails

- Never modify code or configuration. Read-only.
- Posting happens on the literal `Go`, and never as `--approve` or `--request-changes` — a PR's review
  state is the human's, always.
- Do not run reviews for layers the change does not touch.
- Cross-layer findings need the same traced path as anything else (`finding-discipline.md`): which
  path is actually used, the config rollout order, whether the two sides release together.
