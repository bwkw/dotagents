# Verification pass

> **Where the enforcement lives.** Four mechanisms exist; they are not interchangeable.
>
> | Mechanism | Cost | Enforces? | Use it for |
> |---|---|---|---|
> | Instructions in the prompt | free | no | the default. Everything starts here. |
> | `/goal` | re-evaluated **every turn** | no, but it re-asserts | a condition that must hold across a long session and that no script can express — "the public API shape must not change". Claude Code only. |
> | Stop hook | runs once per turn | **yes**, on Claude Code | anything a command can decide. Cheaper than `/goal` and not subject to persuasion. |
> | Verification subagent | one subagent | no, but it is independent | judgement calls a command cannot make — "does this diff satisfy the acceptance criteria?" |
>
> Prefer the Stop hook whenever the condition is mechanically checkable: it costs one run instead of
> one per turn, and it cannot be talked out of its answer. Reach for `/goal` only when the condition
> needs a model to evaluate it and has to survive many turns. The two are complements, not
> alternatives — the hook checks the build, `/goal` watches the invariant.


Run after the find phase. False positives and false negatives are asymmetric problems, so **both
6a and 6b are mandatory**. Skipping 6b is how a review produces a confident, wrong "clean".

Every verifier is a **fresh subagent that did not take part in the find phase**. It sees the diff
and the findings, not the reasoning that produced them — that is the whole point. A reviewer who
watched the work get done evaluates the reasoning; a reviewer who did not evaluates the result.

---

## 6a. Refutation — against false positives

Applies only to findings with `severity=critical` or `irreversible=true`.

**Batch by perspective cluster.** One verification subagent handles all of one cluster's findings.
Never spawn one agent per finding. Keep concurrency at the same ceiling as the find phase; when
there are more, prioritise by severity and irreversibility and send the remainder to 👤.

Instruction to the verifier, including the tie-breaking rule:

> For each finding, read the actual code path and try to show that **the claimed failure cannot
> happen** — a guard exists, a constraint enforces it, the path is unreachable. If you can show
> that, return `refuted`. When you cannot substantiate the finding, return **`refuted`**, not
> `uncertain`. Reserve `uncertain` for cases that are genuinely data- or runtime-dependent.

```
{ id, verdict: "confirmed" | "refuted" | "uncertain",
  evidence: "file:line and reasoning",
  corrected_severity?, reachability? }
```

**Severity recalibration — the second line of defence against inflation.** Even for `confirmed`
(the claimed failure *can* occur), the verifier must answer whether a **real use case reaches it**,
with `file:line` or a concrete path. **"Possible in the code" alone does not keep something at
critical or ⛔.** When reachability is not backed by real code, lower `corrected_severity`, write
what would settle it into `reachability`, and route it to 👤.

Return **permanent defects** (invariant unenforced, guard missing, fail-open where it should be
fail-closed) separately from **probabilistic triggers** (one specific path, a deploy window,
malformed input). The former keeps its severity; the latter depends on reachability.

| Verdict | Disposition |
|---|---|
| `confirmed` | Keep. Re-bucket by `corrected_severity` when present. |
| `refuted` | Drop from Critical/⛔. Report the **count and a one-line summary only** — do not restate each finding or its evidence. |
| `uncertain` | Demote to 👤. |

---

## 6b. Challenging the clears, and hunting what was missed — against false negatives

One **skeptic** subagent, also fresh. May be launched in the same batch as 6a. It does three things.

**Challenge overconfident clears.** Find the high-risk places the find phase dismissed as "same as
existing", "same as siblings", or "no problem", and read the actual guard that backs that safety,
citing `file:line`. Where you cannot confirm it, upgrade to 👤 as an *unverified clear* — or to 🔴
if the concrete harm is legible. **"Matches siblings" alone never passes as grounds for a clear.**

**Hunt for what was missed.** Make one fresh pass over the most irreversible, highest-risk surfaces —
money, billing, external or government submission, authorization, PII, data migration, concurrency —
looking for failure modes the find phase did not raise. File anything found as a normal finding
(it then goes through 6a).

**Re-check design and system-wide concerns.** Confirm that cluster 0's 🧭 candidates were not
quietly dropped, and supply what is missing.

```
{ challenged: [{ id, upgraded_to, reason, evidence }],
  missed: [ ...normal finding schema ] }
```

---

## Recurring silent, irreversible failure patterns

Apply these in **both** phases, across clusters. They are the shapes that look clean in review and
become silent production incidents. When one matches, raise it even outside the diff.

**Global default × local compensation.** The change adds behaviour to a *shared default* — a task or
job catalog, a base class, common config, a DB default, a seed — and its correctness depends on
*compensating work at the call site* (populating a context, setting a flag, pre-processing).
Verify that **every entry path** performs that compensation, not just the one the PR touched. `grep`
out every other path that can trigger or modify the same aggregate — other controllers, use cases,
batch jobs, event handlers, screens — and check each against the requirement. **If no guard or
architecture test enforces the invariant, that is 🧭** (🔴 when you can read a path to real harm).

**Fail-open or fail-closed — which way does the silence fall?** Check the direction of the fallback
on a default value, an evaluation error, a missing context or key. If it makes an irreversible,
statutory, externally-submitted, or billable operation **silently skip, auto-complete, or no-op**,
ask whether that direction is right. **Failing silently is usually more harmful than failing loudly
or visibly over-executing**, especially for statutory and external submissions. → 🧭 / 🔴

**Duplicated source of truth.** A mapping, constant, or table declared authoritative in a design doc
or one location is **re-hardcoded** somewhere else — a seed, another layer, another path — with no
cross-check test. Drift then produces silent incidents. Look for the place the two are reconciled;
if there is none, file it. → 🟡

**Deploy ordering for LIVE-read seed and config.** When a seed, catalog, or config is read **fresh at
startup rather than from a snapshot**, changing it opens a rollout window: if it lands before the
code is fully deployed, the old code breaks on it. Determine whether a hard ordering gate is needed
and when it actually runs (seeded automatically or by hand, relative to the app rollout). → 👤 when
you cannot determine it.

**Observability of silent success.** When an irreversible operation can be **silently skipped or
auto-completed** under some condition, check that there is an *active signal* — a log line, a metric
— not just a row in the database afterward. Without one it is undetectable. → 🟡. **Do not casually
recommend standing up a new sweep or cron**; prefer one passive monitor plus manual recovery.
