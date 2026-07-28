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

**Use the `da-review-verifier` agent.** It carries the refute-by-default asymmetry and the read-only
constraint in its own definition, which means those hold *before* it reads anything — passing them in
a prompt to `general-purpose` makes them a request instead. It is installed globally by this toolkit,
so it exists in every repository.

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

**Severity recalibration.** Apply the reachability rule from `finding-discipline.md` and return
`corrected_severity` and `reachability` accordingly. That is where the rule is defined; it is not
restated here.

| Verdict | Disposition |
|---|---|
| `confirmed` | Keep. Re-bucket by `corrected_severity` when present. |
| `refuted` | Drop from Critical/⛔. Report the **count and a one-line summary only** — do not restate each finding or its evidence. |
| `uncertain` | Demote to 👤. |

### Perspective-diverse verification, for ⛔ and 🔴 only

A finding that survives one verifier survived **one way of being wrong**. For the two severities where
being wrong is expensive in both directions — a false ⛔ costs the reader's trust in the whole report, a
missed one costs production — run **three verifiers with different lenses** instead of one, and let them
disagree.

Three lenses, not three repetitions. Repetition mostly reproduces the same blind spot:

| Lens | The only question it answers |
|---|---|
| **reachability** | Does real execution reach this? Which caller, which permission, which timing? |
| **existing guard** | Is this already prevented somewhere else — a constraint, a middleware guard, a type that makes the state unrepresentable? |
| **severity** | Is ⛔/🔴 right for what the code actually does, or is this a 🟡/💡? |

Rules that make the diversity worth its cost:

- **Each verifier judges only its own lens.** Tell it so. It must not speculate about the other two or
  soften its verdict anticipating them — independence is the only reason three is better than one.
- **Two of three must not refute** for the finding to survive at ⛔/🔴. One refutation with concrete
  evidence beats two shrugs; weigh the evidence, not the tally, and say when you overrode the count.
- **The severity lens can only lower**, never raise. Raising is the find phase's job, and a verifier
  that escalates is no longer verifying.
- **Scope is the point.** ⛔ and 🔴 only. Applying this to 🟡 and 💡 triples the cost of the cheap half
  of the report for findings nobody was going to act on urgently.

**The infrastructure exception overrides the reachability lens.** For a destructive or
permission-widening change — resource replacement, state loss, a delete that takes data with it, a
widened IAM grant — improbability is not a refutation. Refute only by showing the guard exists or that
the change is not in fact destructive. `da-review-verifier` carries this exception in its own definition.

---

## 6b. Challenging the clears, and hunting what was missed — against false negatives

One **skeptic** subagent, also fresh. May be launched in the same batch as 6a. It does three things.

**Challenge overconfident clears.** Find the high-risk places the find phase dismissed as "same as
existing" or "no problem", and read the actual guard, citing `file:line`. Where you cannot confirm
it, return `kind: "unverified-clear"` — or a `defect` if the concrete harm is legible.

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

These live in [`silent-failure-patterns.md`](silent-failure-patterns.md) — **read it now if you have
not already.**

They are deliberately not duplicated here, because they are not a verify-phase concern. The find phase
applies them too, and keeping the only copy in this file is exactly the mistake that once removed them
from the find phase entirely: the patterns were still written down, still correct, and no longer read
by the pass that had the best chance of catching them early.

What belongs to *this* phase is the second look:

- A cluster that reported clean is a **claim**. These five patterns are where such a claim is most
  often wrong, because each one is locally invisible — every individual file reads correctly.
- When you match a pattern here that the find phase did not, record both the finding **and the fact
  that find missed it**. That second part calibrates 🔎: it is direct evidence about how much the clean
  portions of this review are worth.
