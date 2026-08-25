# Verification pass

> **Where the enforcement lives.** Four mechanisms exist; they are not interchangeable.
>
> | Mechanism | Cost | Enforces? | Use it for |
> |---|---|---|---|
> | Instructions in the prompt | free | no | the default. Everything starts here. |
> | `/goal` | re-evaluated **every turn** | no, but it re-asserts | a condition that must hold across a long session and that no script can express — "the public API shape must not change". Claude Code only. |
> | Stop hook | runs once per turn | **yes**, on Claude Code | anything a command can decide. Cheaper than `/goal` and not subject to persuasion. |
> | A separate `claude -p` round | one process | no, but it **is** independent | judgement calls a command cannot make — "does this diff satisfy the acceptance criteria?". A fresh process, unlike a subagent, is not the same context wearing a hat. |
>
> Prefer the Stop hook whenever the condition is mechanically checkable: it costs one run instead of
> one per turn, and it cannot be talked out of its answer. Reach for `/goal` only when the condition
> needs a model to evaluate it and has to survive many turns. The two are complements, not
> alternatives — the hook checks the build, `/goal` watches the invariant.


Run after the find phase. False positives and false negatives are asymmetric problems, so **both
6a and 6b are mandatory**. Skipping 6b is how a review produces a confident, wrong "clean".

## This pass is inline, and it is self-verification. Say so.

**No subagent.** This used to spawn a fresh `x-review-verifier` and called that non-negotiable, on the
grounds that you cannot refute your own reasoning from inside the context that produced it.

**That reasoning was right about the problem and wrong about the remedy.** A fresh subagent is the *same
model* re-reading the *same diff* under the *same discipline*. It does not have a different disposition;
it has the same one with an empty context — and the measured effects below say a verifier's lean is
**per-reviewer and per-framing**, not per-instance. So a second instance of yourself buys a cold-start
bill and the illusion of independence, which is worse than the honest version, because a report that says
"a verifier confirmed it" reads as stronger than one that says "I checked my own work".

**What you do instead, and it is not nothing:**

1. **Change the framing, deliberately.** The find phase asked "what is wrong here". This pass asks the
   opposite question — "show that this cannot happen" — and framing is the axis that measurably matters.
2. **Judge only what is on the page.** Re-read the cited `file:line` and the path around it. Do not
   re-run the reasoning that produced the finding; if a finding's persuasiveness survives only when you
   reread its argument rather than its evidence, that is a refutation.
3. **Say what it was.** 🔎 states **"self-verified inline, not independently"**. A reader who thinks an
   independent agent signed off will weight the clean parts wrongly, and that misweighting is the entire
   cost of doing this inline.

**Real independence is bought elsewhere, and the toolkit already buys it**: `/find-bugs` is a
**differently built** reviewer, and the measurement that justifies it is the one in `review-process.md`
— 93.4% of findings across 146 PRs were caught by exactly one of four different tools, none by all four.
Where a stronger or different model is available (`--advisor`), route this pass to it and say so in 🔎.
**A different tool or a different model is independence. A second copy of this one never was.**

---

## 6a. Refutation — against false positives

Applies only to findings with `severity=critical` or `irreversible=true`.

**Work them cluster by cluster**, not finding by finding: the same code path usually carries several, and
re-reading it once per finding is how this pass used to get expensive.

**Order matters, because you are your own verifier.** Take the findings in **reverse severity order
within this pass’s scope** — 🔴 first, ⛔ last. The measured position effect is that whatever you judge
first sets the tone for the rest, and judging your own ⛔ first is the arrangement most likely to launder
the whole list.

**This used to read "💡 and 🟡 first" — the two severities the line above excludes.** Resolving it went one
of two ways, and both lost something: widen the scope and you triple the cost of the cheap half of the
report, against the rule four paragraphs down; keep the scope and you drop the ordering, and with it the
position guard this paragraph exists for. **A pass may not be told to order findings it was told not to
take.**

**When there are more findings than you can genuinely re-read, prioritise by irreversibility then
severity and send the remainder to 👤** — labelled unverified rather than silently downgraded. **A layer
that produces more ⛔/🔴 than one pass can verify is telling you something** that another pass would not.

The instruction to apply to each finding, including the tie-breaking rule:

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

A finding checked one way survived **one way of being wrong**. For the two severities where being wrong
is expensive in both directions — a false ⛔ costs the reader's trust in the whole report, a missed one
costs production — make **three separate passes with different lenses** and let them disagree with each
other.

**Three passes, not three agents.** This is the part of the old three-verifier design that survives
intact, and it survives *because* the file already admitted what it was: "three lenses reduce the chance
of one bad run; they do not remove bias shared by all three, **because it is the same model each time**".
That was true of three subagents and it is true of three passes — so the subagents were paying a
cold-start bill for a diversity that came from the **framing**, which costs nothing to vary inline.

Three lenses, not three repetitions. Repetition mostly reproduces the same blind spot:

| Lens | The only question it answers |
|---|---|
| **reachability** | Does real execution reach this? Which caller, which permission, which timing? |
| **existing guard** | Is this already prevented somewhere else — a constraint, a middleware guard, a type that makes the state unrepresentable? |
| **severity** | Is ⛔/🔴 right for what the code actually does, or is this a 🟡/💡? |

Rules that make the diversity worth its cost:

- **Each pass answers only its own lens.** Write the verdict for that lens before starting the next, and
  do not soften one in anticipation of another — the separation is the only reason three beats one.
- **Two of three must not refute** for the finding to survive at ⛔/🔴. One refutation with concrete
  evidence beats two shrugs; weigh the evidence, not the tally, and say when you overrode the count.
- **The severity lens can only lower**, never raise. Raising is the find phase's job, and a verification
  pass that escalates is no longer verifying.
- **Scope is the point.** ⛔ and 🔴 only. Applying this to 🟡 and 💡 triples the cost of the cheap half
  of the report for findings nobody was going to act on urgently.
- **The 3 most irreversible ⛔/🔴 per layer** <!-- dotagents:lens-cap 3 -->; everything past that gets
  one lens. Inline the pass costs attention and output, but it no longer costs an agent — and **the
  agent was the whole cost basis for capping it.** Decision 16 set the cap at 3 while each lens was a
  cold subagent; the commit that removed every subagent cut it to *one* finding, and said only that the
  three lenses survive as three passes. **The number moved 3× in the tightening direction at the exact
  moment its reason disappeared**, and `docs/decisions.md` went on stating 3 — so the record described a
  review this file no longer performed. Restored to 3, and now checked in `verify-skills.sh`.
- **A layer with more ⛔/🔴 than it can three-lens has a bigger problem than verification depth** — say
  so, and 🔎 states which findings got three lenses and which got one.
- **Do not claim independence you do not have.** Three lenses reduce the chance of one bad run; they do
  not remove bias shared by all three, because it is the same model each time. Report it as "checked
  from three angles", never as agreement between reviewers, and route the pass to a different or
  stronger model when one is available.

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
the change is not in fact destructive. **This exception is easiest to lose inline**, because the
reachability lens is the one that feels most like diligence — "nobody would call it with that" is not a
guard, and on a destructive change it is not a refutation either.

---

## 6b. Challenging the clears, and hunting what was missed — against false negatives

**A distinct pass, run after 6a rather than interleaved with it** — the two ask opposite questions, and
running them together lets the refuting frame answer the hunting one. It does three things.

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
