---
name: review-all
description: Review a change as a tech lead. Use for code review, PR review, or checking work before shipping. Detects which layers a change touches (infra, backend, frontend), reviews each in parallel subagents, and surfaces the cross-layer irreversible risks no single-layer review sees. Read-only.
argument-hint: "[base-branch | path/ | file | 'all'] (default: the working diff and its blast radius)"
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

### Always read

| File | Why |
|---|---|
| `${CLAUDE_SKILL_DIR}/reference/finding-discipline.md` | The posture and reporting rules. Passed to every subagent. |
| `${CLAUDE_SKILL_DIR}/reference/report-format.md` | Bucketing, merging, and the presentation format for the cross-layer summary. |

### Read only if

| File | Trigger condition |
|---|---|
| `${CLAUDE_SKILL_DIR}/reference/backend.md` | Only inside the backend subagent |
| `${CLAUDE_SKILL_DIR}/reference/frontend.md` | Only inside the frontend subagent |
| `${CLAUDE_SKILL_DIR}/reference/infra.md` | Only inside the infra subagent |
| `${CLAUDE_SKILL_DIR}/reference/review-process.md` | Read by each layer subagent, not by this dispatcher |
| `${CLAUDE_SKILL_DIR}/reference/verification.md` | Read by each layer subagent during its verify phase |

> Reading everything "just in case" is forbidden. The layer bodies are large; loading one here costs
> the whole session, because a skill's content stays in context until the session ends. The
> dispatcher stays thin on purpose — the layer bodies belong in the disposable context of a subagent.

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

**The cross-layer lens for silent, irreversible failures** — apply one pass, always:

- **Global default × another layer's compensation.** One layer adds behaviour to a *shared default*
  (a common module, base class, DB default, seed, catalog, shared config) whose correctness depends
  on *compensating work in another layer* (a context value, a flag, pre-processing, a value the
  frontend sends). Check that **every entry path** satisfies it — other controllers, use cases, batch
  jobs, events, screens — and whether a guard or architecture test enforces the invariant. The one
  path the PR touched being correct is not enough.
- **Fail-open or fail-closed.** Does the fallback on a default, an evaluation error, or a missing
  context or key make an irreversible, statutory, externally-submitted, or billable operation
  **silently skip, auto-complete, or no-op**? **Failing silently is worse than failing loudly or
  visibly over-executing.**
- **Deploy order for LIVE-read seed and config.** Config read fresh at startup rather than from a
  snapshot opens a rollout window where the new data meets the old code. Determine whether a hard
  gate is needed and when it runs. → 👤 if undeterminable.
- **Observability of silent success.** If an irreversible operation can be silently skipped, is there
  an *active* signal (log, metric), not just a row afterwards? Without one it is undetectable → 🟡.
  **Do not casually recommend a new sweep or cron**; prefer one passive monitor plus manual recovery.

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
- **Calibrate cross-layer findings by reachability too.** Before raising a 🔗 as 🔴 or ⛔, establish
  which real path, deploy order, or input reaches the breakage. **"Possible given the code" is not
  grounds for severe.** Where reachability is not backed by real code, do not inflate: place it in 👤
  with what to confirm (which path is used, the seed and config rollout order, backend/frontend
  release synchronisation). Keep permanent defects — an invariant not enforced by a guard or
  architecture test, a fail-open that should be fail-closed — separate from probabilistic triggers.
- Always present the layer classification before acting on it.
- Do not run reviews for layers the change does not touch.
- If only one layer is touched, the result is the same as running that layer alone; say explicitly
  that there is no cross-layer impact.
- Even for a clean cross-layer summary, state the limits under 🔎. Never present it as unconditional
  proof of safety.
