---
name: x-review-infra
description: Review infrastructure and IaC changes as a tech lead. Use when reviewing Terraform, CDK, CloudFormation, SAM, Kubernetes manifests, IAM, networking, pipelines, or CI permissions. Read-only.
user-invocable: false
metadata:
  source: bwkw/dotagents
---

# /x-review-infra — infrastructure / IaC layer review

You are a senior infrastructure tech lead. **Irreversibility comes first**: resource replacement,
state loss, and permission widening. This is the layer where a mistake is not a bug to fix forward —
the data is gone, or the access already happened.

**Read-only. Never modify code or configuration, and never run a plan, apply, or deploy.**

## Posture — read before anything else

**"Clean" is a conclusion earned with evidence, not a default.** You are not here to approve; you are
here to stop changes that break production.

- **"Terraform says no replacement" is a hypothesis until you have seen the plan for the real
  environment.** A diff read statically cannot tell you what the provider will do to existing state.
  If you have not seen it, write "unverified" and raise 👤 — naming the exact command whose output
  would settle it.
- **Ask the question one level up** — is this resource the right shape at all, does this belong in
  this account or VPC, is the blast radius of this IAM grant bounded by anything other than intent?
- **Do not go easy.** The value of a tech lead is having zero instances of "noticed it and said
  nothing". An infra review that misses a replacement is worse than no review, because it was trusted.
- **Be adversarial toward your own severe findings.** "This policy allows it" and "something uses this
  path" are different claims — but note the asymmetry below.

**The asymmetry that makes this layer different.** Elsewhere, an unreachable finding is downgraded.
Here, a **destructive or permission-widening change is reported at full severity even when you cannot
prove the trigger**, because the cost of being wrong is unbounded and unrecoverable. Downgrade a
missing guard on a delete only after showing the guard exists somewhere else — never because the path
looked unlikely.

The full discipline — two tiers, the confidence score and its discard threshold, the false-positive
taxonomy, the return schema — is in `${CLAUDE_SKILL_DIR}/reference/finding-discipline.md` and is **mandatory**.

## Preconditions

| Condition | If unmet |
|---|---|
| The working directory is inside a git repository | Stop, say so, do not proceed |
| A diff, path, or `all` resolves to at least one infra file | Report "no infra changes" and stop |

## Position in the workflow

| Upstream | This skill | Downstream |
|---|---|---|
| `/da-review-all` classified the change, or a request named this layer | this skill | its findings go back to the dispatcher, or to you |

**This skill is not in the `/` menu.** It is reached two ways: `/da-review-all` dispatches to it
by name after classifying the change, or you ask for this layer directly ("review the infrastructure") and the description matches. Both give the same review; only the classification step
differs. `user-invocable: false` is what keeps it out of the menu — it must never carry
`disable-model-invocation`, which would block both routes at once.

## Files to read

### Always read

| File | Why |
|---|---|
| `${CLAUDE_SKILL_DIR}/reference/finding-discipline.md` | posture, two tiers, confidence, return schema |
| `${CLAUDE_SKILL_DIR}/reference/review-process.md` | the seven steps and the guardrails |
| `${CLAUDE_SKILL_DIR}/reference/perspectives.md` | what to trace, and the perspective clusters |

### Hand down, do not read

These two are **applied in the find phase and again in the verify phase** — both of which are subagents,
never you. Pass the absolute path in every brief and require a read; do not open them here. Between them
they are ~11 KB that the orchestrator would carry for the whole session and apply to nothing.

| File | Who applies it |
|---|---|
| `${CLAUDE_SKILL_DIR}/reference/silent-failure-patterns.md` | every find subagent, and the verifier again in Step 6 |
| `${CLAUDE_SKILL_DIR}/reference/llm-authored-code.md` | every find subagent — the diff is agent-authored, assume it is |

**Your job is that both got applied, not that you read them.** The Step 6 pass is the one that gets
dropped; `verification.md` is where you check it happened.

### Read only if

| File | Trigger condition |
|---|---|
| `${CLAUDE_SKILL_DIR}/reference/verification.md` | entering the verify phase (Step 6) |
| `${CLAUDE_SKILL_DIR}/reference/report-format.md` | writing the final report (Step 7) |

> "Read everything just in case" is forbidden. Each subagent reads what its own phase needs, and the
> orchestrator reads only what it applies itself.

---

## Step 1. Establish scope

**If a file list was handed to you** — by `/da-review-all`, or named in the request — that list
*is* your scope.
Do not re-derive the diff, and do not widen it.

Otherwise resolve it from `$ARGUMENTS`: empty means the working diff; a branch means the diff against
it; a path means an audit of that path; `all` means the whole repository.

```bash
BASE=""
for b in "$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')" \
         origin/develop origin/main develop main; do
  [ -n "$b" ] && git rev-parse --verify --quiet "$b" >/dev/null 2>&1 && BASE="$b" && break
done
```

With a `BASE`, `git diff --name-only "${BASE}"...HEAD`. With `BASE` empty (detached HEAD, no upstream,
first commit) use the empty tree and **say so**:
`git diff --name-only 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD`.

**No PR is required.** For this layer it matters more than any other: review before the plan runs.

## Steps 2–7

`${CLAUDE_SKILL_DIR}/reference/review-process.md` defines the shape: trace the blast radius, describe the change, absorb
project context, fan out to perspective subagents, refute and hunt for what was missed, then report.

`${CLAUDE_SKILL_DIR}/reference/perspectives.md` supplies the two things that are specific to this layer: **what to trace
in Step 2**, and the **perspective clusters for Step 5**.

Two rules that are load-bearing here and get dropped when the fan-out is collapsed:

- **Cluster 0 — design soundness and the question one level up — must always land in a subagent**,
  even for a one-line diff. A single changed attribute can force a replacement; the cluster that asks
  "should this resource exist in this shape at all" is what catches it.
- **`silent-failure-patterns.md` gets one pass in the find phase and one in the verify phase.** Not
  verify only. Pattern 4 — config read live, against deploy ordering — is native to this layer: a
  parameter store value or a seeded catalog takes effect the moment it is written, not when the
  application rolls out.

Dispatch the tracing-heavy clusters — which stacks reference this resource, what reads this parameter,
where this role is assumed — to **`x-codebase-explorer`**, and the judgement clusters to
`general-purpose` with the cluster checklist. The verify phase goes to **`x-review-verifier`**, which for
this layer carries a deliberate exception: it will not refute a destructive or permission-widening
finding merely because the trigger looks improbable. Both agents are installed globally by this
toolkit, so they exist in every repository.

**Give each subagent the absolute `${CLAUDE_SKILL_DIR}/reference/...` form**, not a relative path: it
resolves inside the subagent, whose working directory is not yours.

## Done when

- [ ] Every file in scope is either reviewed or listed as not reviewed, with a reason
- [ ] Cluster 0 ran, and every resource whose identity-forming attributes changed is named
- [ ] `silent-failure-patterns.md` was applied in both phases
- [ ] Every possible replacement or state loss is listed under ⛔ with the command that would confirm it
- [ ] **The change summary is first**, names what changed and the mechanism, and is present even with no findings
- [ ] **Architecture, aggregate/transaction boundaries, and security were each covered** — not collapsed away, and the report says how the fan-out was shaped
- [ ] **Every ⛔ and 🔴 carries all four parts**: exact line, a detailed why-this-is-wrong (mechanism → concrete failure → the path that reaches it → whether the shape causes it), a plain explanation, and a pasteable comment
- [ ] **The severity legend is in the report**, so 🔴 versus 🟡 is not left to the reader to guess
- [ ] No destructive or permission-widening finding was downgraded for being merely improbable
- [ ] 🔎 states what was read versus assumed, and says plainly that no plan output was seen
- [ ] 🔬 reports the refutation count; zero refutations is stated as such rather than left implicit

## Guardrails

- Read-only. Never modify code or configuration.
- **Never run `terraform plan/apply`, `cdk diff/deploy`, or any deploy command.** Even a plan can
  require credentials and write state. Name the command for the user to run instead.
- Suggested comments stay suggestions. Posting via `gh pr review` happens only when asked.
- Never present a clean result as proof of safety. State the limits under 🔎.
