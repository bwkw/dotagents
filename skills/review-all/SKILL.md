---
name: review-all
description: Review a change as a tech lead. Use for code review, PR review, or checking work before shipping. Detects which layers a change touches (infra, backend, frontend), reviews each in parallel subagents, and surfaces the cross-layer irreversible risks no single-layer review sees. Read-only.
argument-hint: "[base-branch | path/ | file | 'all'] (default: the working diff and its blast radius)"
metadata:
  source: bwkw/dotagents
---

# /review-all — cross-layer review dispatcher

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
| implementation complete, or a PR open | `/review-all` | triage the findings, then fix |

## Files to read

**The dispatcher reads none of them.** Each layer file tells its own subagent what to load, and the
cross-layer report skeleton is inline in Step 4. Opening a reference here would put it in the main
context for the rest of the session, which is the cost this split exists to avoid.

| File | Read by |
|---|---|
| `reference/backend.md` | the backend subagent, on instruction |
| `reference/frontend.md` | the frontend subagent |
| `reference/infra.md` | the infra subagent |
| `reference/review-process.md` | each layer file, as its first instruction |
| `reference/finding-discipline.md` | every reviewing and verifying subagent |
| `reference/verification.md` | each layer subagent, during its verify phase |
| `reference/report-format.md` | whichever subagent writes a layer report |

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

For each layer with files, launch a subagent and give it the file list you classified into that
layer. Prefer a purpose-built agent when the repository defines one (`senior-architect`,
`ddd-expert`, `database-specialist`, a domain expert); otherwise `general-purpose`.

The task for each subagent:

> Read `${CLAUDE_SKILL_DIR}/reference/<layer>.md` and follow it exactly. Your scope is strictly these
> files: `<the list>`. Do not re-derive the full diff.

**Use the `${CLAUDE_SKILL_DIR}` form, not a relative path.** It expands to an absolute path, so it
resolves inside the subagent, whose working directory is not yours.

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

**The cross-layer lens for silent, irreversible failures** — apply the four patterns in
`verification.md` one more time, but only for the case they cannot cover: where the *compensating
work* sits in a **different layer** from the shared default that needs it. A global default whose
correctness depends on the frontend sending a particular value, or on a batch job setting a flag, is
correct in each layer read alone and broken between them.

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

```markdown
## Cross-Layer Review Summary

### Layers touched
- infra: N files / backend: M files / frontend: K files (unclassified: L)

### Layer reports
- 🏗️ Infra / ⚙️ Backend / 🖥️ Frontend — see each report for detail
- Counts are consolidated in 📊 below; not repeated here
- Each report carries 📍 location, plain explanation, and 💬 suggested comment per finding

### 🔗 Cross-layer irreversibility and consistency risks (highest priority)
| Risk | Layers | What breaks | Ship order / must confirm |
|---|---|---|---|
| e.g. contract field made required, backend deployed first | backend→frontend | old frontend fails validation | ship frontend first, or accept both during a staged migration |

Follow each 🔗 row with one 📍 location and one 💬 suggested comment.

### 🧭 Design and system-wide doubts / unverified clears (pulled up from every layer)
- Which layer, and what would settle it.

### 🔎 Confidence of this review
- What each layer actually read versus assumed, in one or two lines. State plainly that a clean
  result means "not detected at this depth", not a design sign-off.

### 📊 Summary
| Layer | ⛔ | 🔴 | 🟡 | 💡 | 🧭 | 👤 |
|---|---|---|---|---|---|---|
| infra | | | | | | |
| backend | | | | | | |
| frontend | | | | | | |
| 🔗 cross-layer | | | | | | |
```

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
