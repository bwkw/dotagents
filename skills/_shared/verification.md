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

**Use the `x-review-verifier` agent.** It carries the refute-by-default asymmetry and the read-only
constraint in its own definition, which means those hold *before* it reads anything — passing them in
a prompt to `general-purpose` makes them a request instead. It is installed globally by this toolkit,
so it exists in every repository.

---

## 6a. Refutation — against false positives

Applies only to findings with `severity=critical` or `irreversible=true`.

**Batch by perspective cluster.** One verification subagent handles all of one cluster's findings.
Never spawn one agent per finding.

### The verify budget

**Verify spends at most `find + 3` subagents per layer**, where `find` is the tier this layer got from the
budget table in `review-process.md`. One number, so the two caps below cannot contradict each other:

| Find tier | 6a refutation + 6b skeptic | Three-lens headroom | Verify ceiling |
|---|---|---|---|
| **inline (0 finders)** | **1** — one subagent refutes and plays skeptic | 2 | **3** |
| 3 finders | **3** — batched by cluster, one of them the skeptic | 3 | **6** |
| 5 finders | **5** — batched by cluster, one of them the skeptic | 3 | **8** |

**The inline tier still spends a subagent here, and this is the one place that is not negotiable.** The
find phase went inline because context isolation is proportional to the reading; verification is not
about context at all. A verifier must not have watched the finding get made — that is the entire
mechanism, and you cannot refute your own reasoning from inside the context that produced it. So: zero
find subagents, **one verifier, always**. A review that skips it to reach zero has removed the part that
suppresses false positives, which is the half the reader actually relies on.

The `+3` is the three-lens pass and **nothing else may spend it.** It covers the single most irreversible
⛔/🔴 in the layer; at the 5-finder tier it may cover a second if the first came back unanimous and slots
remain. Everything else at ⛔/🔴 gets one verifier from the base allocation.

**When there are more findings than slots, prioritise by irreversibility then severity, and send the
remainder to 👤** — labelled as unverified rather than silently downgraded. Never buy another agent.
A diff that justified three finders does not justify eight verifiers, and a layer that produces more
⛔/🔴 than its budget can verify is telling you something the extra verifiers would not.

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
- **Bounded by the `+3` headroom in the verify budget above** — normally the single most irreversible
  ⛔/🔴 in the layer. The pass multiplies, and that is why it is metered: three lenses on three findings
  across three layers is 27 subagents re-reading one diff. **A layer with more ⛔/🔴 than its budget can
  three-lens has a bigger problem than verification depth** — say so, and 🔎 states which findings got
  three lenses and which got one.
- **Do not claim independence you do not have.** Three lenses reduce the chance of one bad run; they do
  not remove bias shared by all three, because it is the same model each time. Report it as "checked
  from three angles", not "three verifiers agreed", and route the pass to a different or stronger model
  when one is available.

### The verifier is biased too — three measured ways

The biases below are why `refuted` is the default and why the three lenses are *lenses* rather than
repetitions. **This is the only copy**, and it sits in the verify phase's own file because only the
verify phase acts on it.

**A verifier's verdicts are systematically tilted, and the tilt is not mainly about self-flattery.**
The obvious story is self-preference — a model rating its own family's output higher, reported in the
range of 10–25%. But that finding is contested: sanity-check work pushes back on it, and one analysis
attributes most of the effect to a **flat per-reviewer disposition** rather than to self-favouring, with
about a 2.8-point spread between the strictest and most lenient reviewer. Read together, the reliable
claim is narrower and more useful: **a verifier has a fixed lean, and you do not know which way yours
leans.**

> **`refuted` is the default because the lean is unknown, not because models are vain.** Three separate
> effects push toward over-confirming: anchoring on a claim that is already written down, the reviewer's
> own disposition, and the fact that models do not reliably self-correct without external evidence. The
> asymmetry is the counterweight to all three at once, and it does not depend on the self-preference
> number being right.

> **Different prompting matters more than a different instance.** If the lean is per-reviewer rather
> than self-directed, then a second look from the same model with the *same* framing buys little, while a
> genuinely different framing buys a lot. That is also the measured reason the **find** phase is capped
> rather than widened: scaling *homogeneous* agents — same model, same prompt, same discipline — shows
> marginal gain per agent collapsing toward zero, while a measurement of four differently-built reviewers
> over the same 146 pull requests found **93.4% of findings were caught by exactly one of the four, and
> none by all four**. Coverage comes from a different reviewer, not a sixth copy of this one — which is
> why the toolkit keeps `/find-bugs` and `/code-review` around instead of treating its own review as
> sufficient. Where a stronger or different model is available (this toolkit's `--advisor`), route the
> verify pass to it and say so in 🔎.

**Verbosity: a longer answer is judged 15–30 points more favourably.** An elaborate finding with three
paragraphs of reasoning reads as more credible than a one-line one citing a real line of code. **Length
is not evidence.** Judge the cited `file:line` and whether the path is reachable. If a finding's
persuasiveness drops once you look only at what it points at, that is a refutation.

**Position: order of presentation changes the verdict.** Do not judge findings in severity order and let
the first ⛔ set the tone for the rest. Each finding is judged against the code, not against its
neighbours.

**What this means for the three-lens pass.** Three lenses reduce *variance* — one verifier having an off
run — and, because the framings genuinely differ, they buy some real coverage. What they do **not** buy
is independence: the same model with the same disposition is behind all three. So three agreeing lenses
are not three independent opinions, and a report must not imply they are.

**The infrastructure exception overrides the reachability lens.** For a destructive or
permission-widening change — resource replacement, state loss, a delete that takes data with it, a
widened IAM grant — improbability is not a refutation. Refute only by showing the guard exists or that
the change is not in fact destructive. `x-review-verifier` carries this exception in its own definition.

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
