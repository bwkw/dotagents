# Review procedure

The seven-step shape every layer review follows. The layer file supplies what is layer-specific:
what to trace during impact mapping, and the perspective clusters. Everything else is here.

**Read `finding-discipline.md` before starting.** It carries the posture and the reporting rules,
and it is mandatory for every subagent you launch.

---

## Step 1. Establish scope

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
   - If the change also touches other layers, say so and suggest `/review-all` across all of them.

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

Use **`codebase-explorer`** for clusters that are mostly tracing — who calls this, where does the data
go, what else touches this pattern. Use `general-purpose` for clusters that need judgement about the
design. Pass every subagent its cluster's checklist from the layer file, and **never skip a cluster**
because the ideal agent for it is unavailable.

> `codebase-explorer` and `review-verifier` are installed globally by this toolkit, so they exist in
> every repository. Do not wait for a repository to define an agent — by design this toolkit never
> adds a file to a product repository, so a repository-local agent will never appear.

> **Never run perspective review inline in the main context.** Dispatch to subagents and wait for
> all of them before synthesising. The reason is not speed: a perspective read in the main context
> stays in the main context, and crowds out the synthesis that follows.

Hand every subagent:

- the base and the scope
- the Step 2 impact map, including the full list of related domains
- its cluster's checklist, from the layer file
- "irreversibility is the highest priority"
- "in high-risk areas, do not settle for 'same as existing' — read the actual guard and cite
  `file:line`, or state explicitly that it is unverified"
- the contents of `finding-discipline.md`, including the return schema

**Scale the fan-out to the change.** For a small or narrow diff, collapse adjacent clusters into two
or three subagents; expand to every cluster only when the impact map is wide. **Even when collapsed,
cluster 0 — design soundness and the question one level up — must land in one of them.** Keep
concurrency at about eight; queue the rest.

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
