---
name: da-review-all
description: Review a change across every layer it touches, as a tech lead. Use for code review, PR review, or checking work before shipping — especially when a change spans backend, frontend, and infrastructure. Reviews each layer in its own subagent, then finds the irreversible risks that fall between them, like a contract and its consumer shipping out of order. Read-only.
argument-hint: "[base-branch | path/ | file | 'all'] (default: the working diff and its blast radius)"
metadata:
  source: bwkw/dotagents
---

# /da-review-all — cross-layer review dispatcher

Works out which layers a change touches and runs **only the layer reviews that apply**. When one
change spans several layers — a schema change, the code that reads it, the infrastructure that hosts
it — this removes both the work of invoking each layer by hand and, more importantly, the
**cross-layer irreversibility risks that are invisible from inside any single layer**.

**Important: this skill never modifies code or configuration. It reports findings only.**

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

**This is the only review entry point in the `/` menu.** The three layer reviews are full skills with
their own posture, process and perspective clusters, but they carry `user-invocable: false` — reachable
by this dispatcher and by a request that names a layer, not by typing. One menu entry, three layers of
depth behind it.

This skill classifies the change and runs the layers that apply, then does the part none of them can.

| Layer skill | Owns |
|---|---|
| `x-review-backend` | server-side source, migrations and schema, contracts and DTOs, queues and jobs, dependencies |
| `x-review-frontend` | components, routes, hooks, stores, styling, frontend i18n |
| `x-review-infra` | Terraform, CDK, CloudFormation, k8s, IAM, networking, pipelines, CI permissions |

**The dispatcher reads no reference files** until Step 4. Each layer skill tells its own subagents what
to load, and opening a reference here would park it in the main context for the whole session.

Step 4 reads three, **all listed here so each is one level from this file** — a reference reached only
through another reference gets partially read:

| File | When |
|---|---|
| `${CLAUDE_SKILL_DIR}/reference/silent-failure-patterns.md` | Step 4, first — the five patterns in their single-layer form |
| `${CLAUDE_SKILL_DIR}/reference/cross-layer.md` | Step 4, then — the same five where cause and consequence sit in different layers, plus the one that only exists across a boundary |
| `${CLAUDE_SKILL_DIR}/reference/llm-authored-code.md` | Step 4, when the change looks agent-authored — for the cross-layer case where a model wrote **both** sides of a boundary and made them consistent with each other and wrong about the outside world |

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

**Present the classification to the user before going on to Step 3.** A misclassification loses an
entire layer, and that is not recoverable by anything later in the process.

## Step 3. Run the layer reviews

For each layer with files, launch a subagent and tell it to use that layer's skill **by name**:

> Use the `x-review-<layer>` skill and follow it exactly. Your scope is strictly these files:
> `<the list>`. Do not re-derive the full diff.

The layer skill handles the rest — it reads its own posture, process, perspectives, and the
silent-failure patterns, and fans out to its own perspective subagents. **Do not restate its
instructions here.** If a layer needs different guidance, that belongs in the layer skill, where a
direct `/x-review-backend` invocation also benefits from it.

> **This by-name dispatch is why `disable-model-invocation` must never be set on any of them.** That
> field blocks programmatic `Skill` calls and subagent preloading, not just model auto-invocation —
> setting it on a layer skill turns this step into a silent no-op. The linter checks for it.

Run the layers **sequentially**. Each one fans out to its own subagents internally, so there is no
parallelism to gain here, and attempting it just makes the transcript harder to follow.

The dispatcher **dispatches**. It does not duplicate the layer checks — each layer maps its own
internal blast radius in its Step 2.

**Unclassified files**: fold each into the nearest layer by content and include it in that review.
Anything you genuinely cannot place, review openly here in Step 4 and mark **"not reviewed / needs
confirmation"** in the report. Never let one fall off quietly.

## Step 4. Cross-layer synthesis — what only this skill can do

**Wait until every layer report is in.** Then look specifically for the risks that appear *between*
layers, which no single-layer review can see:

- **Schema ↔ code deploy-order coupling.** Do the database or contract change (backend), the code
  that reads it, and the infrastructure deploy survive being applied in the real order? Is it a
  backward-compatible staged rollout?
- **API contract, backend ↔ frontend.** Does the contract change land in the same PR or release as
  the frontend that consumes it, or does one side shipping first break the other?
- **Infrastructure change versus application assumptions.** Does renaming, replacing, or re-scoping a
  resource break a runtime assumption in backend or frontend code?
- **Release order and rollback.** The safe order to ship a cross-layer change, and what stays
  consistent if only one side is rolled back.

**Then the silent, irreversible failures in their cross-layer form.** Read
`${CLAUDE_SKILL_DIR}/reference/cross-layer.md` and work through all five. Do not settle for
re-applying the patterns as written — each has a shape that appears only when the cause and the
consequence sit in **different layers**, and no layer review can reach any of them because every copy,
every half, every side is locally correct. In short: a shared default whose compensation lives in
another layer; a fallback that treats absent-from-elsewhere as permitted; one source of truth
re-declared under a different name; live-read config racing a two-pipeline rollout; and an action in
one layer whose only signal lands in another.

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

**The report skeleton is in `${CLAUDE_SKILL_DIR}/reference/cross-layer.md`**, which this step
already reads. It lives there rather than here because it is only needed once the layer reports
are in, and a template parked in this context from the first turn is the cost the split avoids.

## Done when

The four requirements in `report-format.md` apply to the layer reports; these are the dispatcher's own,
and it is the only place they can be checked because no layer can see them.

- [ ] The layer classification was shown **before** any review ran, and every file is in a layer or listed
      as unclassified
- [ ] Every layer with files was dispatched to **by skill name**, and the transcript shows it ran — a
      layer reported as covered with no subagent behind it is the failure this dispatcher exists to avoid
- [ ] **The change summary spans layers**: what changed in each, and what the change is *as one thing*
      rather than three unrelated diffs
- [ ] **All six cross-layer forms were applied**, not just the four structural ones — including the
      agent-authored case where both sides of a boundary agree with each other and are wrong about the
      outside world
- [ ] Every 🔗 finding names **both** layers and carries a 📍 on **each** side, plus the detailed
      why-this-is-wrong and a pasteable comment
- [ ] Every layer's 🧭 and 👤 were **pulled up**, not left inside a sub-report
- [ ] Duplicates across layers were merged and the summary counts them **once**
- [ ] 🔎 says which layers were reviewed at what depth, and states plainly that a clean cross-layer result
      is not a sign-off
- [ ] If only one layer was touched, the report says explicitly that there is **no cross-layer impact** —
      rather than implying a synthesis happened

## Guardrails

- Never modify code or configuration. Read-only.
- Suggested comments stay suggestions. Posting via `gh pr review` or similar happens only when the
  user explicitly asks for it.
- Cross-layer findings are calibrated by the same reachability rule as everything else; it lives in
  `finding-discipline.md`. What to confirm here is specific though: which path is actually used, the
  seed and config rollout order, and whether backend and frontend release together.
- Always present the layer classification before acting on it.
- Do not run reviews for layers the change does not touch.
- If only one layer is touched, the result is the same as running that layer alone; say explicitly
  that there is no cross-layer impact.
- Even for a clean cross-layer summary, state the limits under 🔎. Never present it as unconditional
  proof of safety.
