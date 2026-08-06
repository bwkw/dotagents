---
name: da-review-all
description: Review a change across every layer it touches, as a tech lead. Use for code review, PR review, or checking work before shipping — especially when a change spans backend, frontend, and infrastructure. Reviews each layer in its own subagent, then finds the irreversible risks that fall between them, like a contract and its consumer shipping out of order. Read-only.
argument-hint: "[base-branch | path/ | file | 'all'] (default: the working diff and its blast radius)"
allowed-tools: Task, Read, Grep, Glob, Write, Bash(git:*), Bash(gh:*)
metadata:
  source: bwkw/dotagents
---

# /da-review-all — cross-layer review dispatcher

Works out which layers a change touches and runs **only the layer reviews that apply**. When one
change spans several layers — a schema change, the code that reads it, the infrastructure that hosts
it — this removes both the work of invoking each layer by hand and, more importantly, the
**cross-layer irreversibility risks that are invisible from inside any single layer**.

**Important: this skill never modifies code or configuration. It reports findings only.** The
one-page Canvas described in Step 5 is a review artifact, not a source or configuration change.

## Preconditions

| Condition | If unmet |
|---|---|
| The working directory is inside a git repository | Stop, say so, do not proceed |
| A diff, path, or `all` resolves to at least one file | Report "no changes", suggest `path/` or `all`, and stop |

## Position in the workflow

| Upstream | This skill | Downstream |
|---|---|---|
| implementation complete, or a PR open | `/da-review-all` | `/da-fix-plan` to triage into an ordered plan, then fix |

## What this skill delegates to

The three layer reviews are full skills with their own posture, process and perspective clusters. They
are not typed — this dispatcher reaches them, and so does a request that names a layer. This skill
classifies the change, runs the layers that apply, then does the part none of them can.

| Layer skill | Owns |
|---|---|
| `x-review-backend` | server-side source, migrations and schema, contracts and DTOs, queues and jobs, dependencies |
| `x-review-frontend` | components, routes, hooks, stores, styling, frontend i18n |
| `x-review-infra` | Terraform, CDK, CloudFormation, k8s, IAM, networking, pipelines, CI permissions |

**The dispatcher reads no reference files** until Step 4. Each layer skill tells its own subagents what
to load, and opening a reference here would park it in the main context for the whole session.

Step 4 reads **one or three**, depending on how many layers ran. All three are listed here so each is one
level from this file — a reference reached only through another reference gets partially read:

| File | When |
|---|---|
| `${CLAUDE_SKILL_DIR}/reference/cross-layer.md` | **Always** — all ten cross-layer checks, and the report skeleton |
| `${CLAUDE_SKILL_DIR}/reference/silent-failure-patterns.md` | **Two or more layers only** — the single-layer form, to re-read across the boundary |
| `${CLAUDE_SKILL_DIR}/reference/llm-authored-code.md` | **Two or more layers only**, and the change looks agent-authored — for when a model wrote **both** sides of a boundary and made them agree with each other and wrong about the world |

**One layer means read only the first**, then say **no cross-layer impact** and pass the report through.

---

## Step 1. Establish scope

`$ARGUMENTS`: empty means the working diff; a branch means the diff against it; a path means an audit
of that path; `all` means the whole repository.

Resolve the base the same way every layer does — take the first that exists:

```bash
BASE=""
for b in "$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')" \
         origin/develop origin/main develop main; do
  [ -n "$b" ] && git rev-parse --verify --quiet "$b" >/dev/null 2>&1 && BASE="$b" && break
done
```

Get the changed files: with a `BASE`, `git diff --name-only "${BASE}"...HEAD`. With `BASE` empty
(detached HEAD, no upstream, first commit) use the empty tree and **say so**:
`git diff --name-only 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD`.

**No PR is required.** Review before pushing is when it is worth the most; a PR URL is accepted but
never demanded.

If the diff is genuinely empty, report "no changes", suggest `path/` or `all`, and stop.

## Step 2. Classify each file into layers

One file may belong to several layers.

| Layer | Signals |
|---|---|
| **infra** | `*.tf`, `cdk.json`, constructs under `lib/**`, `template.ya?ml` (CFn/SAM), `serverless.yml`, k8s manifests, platform or runner `Dockerfile`, `*.snap` (IaC snapshots), IAM / networking / pipeline definitions |
| **backend** | server-side source (NestJS, Express, …), `*.prisma` and migrations, API contracts and DTOs, domain / use case / repository code, Lambda handlers |
| **frontend** | `*.tsx`, `*.jsx`, `*.vue`, `*.svelte`, route definitions, components, hooks, stores, CSS and styling, frontend i18n resources |
| **build / deps / CI** | `package.json`, `*-lock.*`, Renovate and dependency config, `.github/workflows/**`, application `Dockerfile`. Route **dependencies and supply chain to backend**, and **CI permission or secret changes to infra** |

For a monorepo or several repositories, classify per repository and per directory.

Files you cannot place: read them and classify by content. If still unclear, list them as
**unclassified** — never drop them silently.

**Print the classification, then keep going — do not wait for confirmation.** It must be *visible* (a
misclassification loses a whole layer, and the printed table stays in the report), not *approved*:
blocking bought no accuracy and cost a human round trip every run.

**Stop for one case only — an unclassified file.** Ask which layer it belongs to. That is the sole branch
where continuing means guessing.

## Step 3. Run the layer reviews

For each layer with files, launch a subagent and tell it to use that layer's skill **by name**:

> Use the `x-review-<layer>` skill and follow it exactly. Your scope is strictly these files:
> `<the list>`. Do not re-derive the full diff.

The layer skill handles the rest — it reads its own posture, process, perspectives, and the
silent-failure patterns, and fans out to its own perspective subagents. **Do not restate its
instructions here.** If a layer needs different guidance, that belongs in the layer skill, where a
direct `/x-review-backend` invocation also benefits from it.

> **Never set `disable-model-invocation` on a layer skill.** It blocks programmatic `Skill` calls too,
> so this step becomes a silent no-op. The linter and the lint hook both check for it.

Run the layers **sequentially**, and do not "fix" this into parallel. There *is* parallelism to gain, but
a subagent does not inherit this session's cached prefix, so three layers at once re-buys the same files
cold at the uncached rate: measured **2.6–5.9× the tokens, and not faster** (`docs/decisions.md` §16).

**Tell each layer its budget tier** from the Step 1b table in `review-process.md`, computed on **that
layer's file list, not the whole diff** — a one-file frontend change riding along with a large backend
change is a one-subagent layer, and only the dispatcher sees both halves.

The dispatcher **dispatches**. It does not duplicate the layer checks — each layer maps its own
internal blast radius in its Step 2.

**Unclassified files**: fold each into the nearest layer by content and include it in that review.
Anything you genuinely cannot place, review openly here in Step 4 and mark **"not reviewed / needs
confirmation"** in the report. Never let one fall off quietly.

## Step 4. Cross-layer synthesis — what only this skill can do

**Wait until every layer report is in.** Then read `${CLAUDE_SKILL_DIR}/reference/cross-layer.md`, which
holds all ten checks: the **four structural forms** — deploy order, the backend ↔ frontend contract,
infrastructure versus application assumptions, rollback — then the **five patterns in their cross-layer
shape**, plus the sixth that only exists across a boundary.

Do not settle for re-applying the patterns as written — each has a shape that appears only when cause and
consequence sit in **different layers**, and no layer review can reach any of them, because every copy,
every half, every side is locally correct.

**Always pull each layer's 🧭 and unverified clears (👤) to the top.** Design doubts, system-wide
concerns, and overconfident clears cut across layers, so they must not stay buried inside a
sub-report. The dispatcher does not get to sit on them.

**Merge cross-layer duplicates.** When different layers raise the **same root cause** (the same
contract, schema, or shared file), combine them into one cross-layer finding naming both layers. The
summary table counts the merged finding once — do not double-count by adding the per-layer totals.

**Presentation.** Each layer report already carries 📍 location, plain explanation, and 💬 suggested
comment per finding. **Do not restate them.** Attach the same three-part set only to the new 🔗
cross-layer findings you raise here — and for a backend ↔ frontend contract issue, give the line on
*both* sides.

## Step 5. One-page Canvas review summary

After the layer reports and cross-layer synthesis are complete, use the `canvas` skill and follow it
exactly. In Cursor, you must create exactly one Canvas as the primary review deliverable. Read
`${CLAUDE_SKILL_DIR}/reference/canvas-review-summary.md` for its required change summary and review
findings. The response must link the Canvas.

If Canvas support is unavailable, say so explicitly and provide the same one-page structure in
Markdown; do not silently omit the artifact.

## Done when

The four requirements in `report-format.md` apply to the layer reports; these are the dispatcher's own,
and it is the only place they can be checked because no layer can see them.

- [ ] The layer classification was shown **before** any review ran, and every file is in a layer — an
      unclassified file stopped the run and was asked about, rather than being carried forward
- [ ] 🔎 reports **the budget tier and the subagent count per layer**, and names what it did not reach —
      the toolkit's only cost measurement, so a review that omits it cannot be tuned
- [ ] Every layer with files was dispatched to **by skill name**, and the transcript shows it ran — a
      layer reported as covered with no subagent behind it is the failure this dispatcher exists to avoid
- [ ] **The change summary spans layers**: what changed in each, and what the change is *as one thing*
      rather than three unrelated diffs
- [ ] **All ten checks in `cross-layer.md` were applied** — not just the four structural ones, and
      including the agent-authored case where both sides of a boundary agree and are wrong about the world
- [ ] Every 🔗 finding names **both** layers and carries a 📍 on **each** side, plus the detailed
      why-this-is-wrong and a pasteable comment
- [ ] Every layer's 🧭 and 👤 were **pulled up**, not left inside a sub-report
- [ ] Duplicates across layers were merged and the summary counts them **once**
- [ ] 🔎 says which layers were reviewed at what depth, and states plainly that a clean cross-layer result
      is not a sign-off
- [ ] If only one layer was touched, the report says explicitly that there is **no cross-layer impact** —
      rather than implying a synthesis happened
- [ ] In Cursor, exactly one Canvas summarizes the change content and review outcome, and the final
      response links to it

## Guardrails

- Never modify code or configuration. Read-only.
- Suggested comments stay suggestions. Posting via `gh pr review` or similar happens only when the
  user explicitly asks for it.
- Do not run reviews for layers the change does not touch.
- Cross-layer findings use the same reachability rule as everything else (`finding-discipline.md`).
  What to confirm here is specific: which path is actually used, the seed and config rollout order,
  and whether backend and frontend release together.
