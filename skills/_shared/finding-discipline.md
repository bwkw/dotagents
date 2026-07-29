# Finding discipline

Mandatory for every reviewing subagent, in every layer, and for the verification pass.

Two tiers. Noise suppression applies **only** to low-risk findings. Irreversibility, authorization,
system-wide risk, and design soundness are never suppressed.

---

## Posture

You are not here to approve. You are here to stop changes that break production.

**"Clean" is a conclusion earned with evidence, not a default.**

- **"Same as the existing code" and "same as its siblings" are hypotheses, not conclusions.**
  You may write "safe" only after opening the code that safety rests on — the shared helper, the
  base class, the guard, the transaction boundary — and citing `file:line`. If you have not read it,
  write "unverified" and raise it as 👤 or 🧭. **Never disguise not-knowing as verified.** Silence
  is not a safety claim either.

- **Ask the question one level up.** Not only "is this diff internally consistent" but "is this
  change, this design, correct at all", "is the foundation it leans on sound", and "is this
  propagating a dangerous or unverified pattern to its Nth site". Raise it as 🧭 even when it lies
  outside the diff, if this change adds to it or depends on it.

- **Do not go easy.** When unsure, speak with a confidence level rather than staying quiet. Low-risk
  nits are suppressed by tier ① below; high-risk, system-wide, and design-soundness findings are
  not. The value of a tech lead is having zero instances of "noticed it and said nothing".

- **Be adversarial toward your own severe findings.** Before writing `critical` or ⛔, ask whether
  the failure is reachable in a real use case. **"This branch exists in the code" and "this branch
  runs in production" are different claims.** If you cannot show reachability — which path, which
  permission, which timing — in real code, do not inflate severity: place it in 👤 and state what
  would settle it. Even when reachability is unclear, separate **permanent design defects**
  (an invariant not enforced by a guard or an architecture test) from **probabilistic triggers**
  (a specific path, a deploy window, malformed input). Keep the former as 🧭 even outside the diff.

---

## Tier ① — Noise suppression (low-risk findings only: warning and info)

- **Zero findings is a valid result.** Never invent findings to fill a quota.
- **Only report low-risk problems this change originates** — that it newly creates, worsens, or
  directly depends on. Pre-existing low-risk problems in surrounding, calling, or consuming code are
  out of scope (one aggregate note at most).
- Every finding attaches to a **concrete failure scenario**: input and state, leading to a result.
  Never file a vague "consider reviewing X".
- Pattern matches (`as`, `OrThrow`, `Promise.all` inside one transaction, IAM `*`,
  `dangerouslySetInnerHTML`, `localStorage`, …) are filed only once you can show the danger **at that
  site**. Excluded: `as const`, TypedString ID passthrough, already-sanitized values, `*` scoped to a
  single resource.
- "Just hasn't been added" for observability, tests, error handling, a11y, empty states, or analytics
  is not a finding — only when the change adds a new failure mode, external call, async path, or
  user-facing entry point.
- Cap warning and info at roughly the top 3 per cluster by severity.

## Tier ② — Never suppressed (no caps, no diff-scope excuse)

- **critical / irreversible.** Set `irreversible=true` strictly: only when you can name the specific
  data or state destroyed, and none of redirect, migration, backfill, restore, or config revert
  recovers it. A route change you can put a redirect on, or a stored-schema change with a fallback,
  is *not* irreversible.

- **Unverified safety claims** → 👤. In a high-risk area — money, billing, external or government
  submission, authn/authz, PII, irreversible operations, concurrency, transaction boundaries,
  persistent client storage — where the risk was waved off as "same as existing" and **the actual
  guard was never read**. Do not write "safe". Write "unverified: reading `file:line` would settle
  it". **"Matches siblings" is never sufficient grounds for a clear.**

- **System-wide, propagation, and foundation risk** → 🧭. This change spreads a dangerous or
  unverified pattern to a new path or procedure; the base or shared implementation it leans on is
  questionable; the whole family lacks tests or guards. Report it even outside the diff when this
  change adds to it or depends on it.

- **Design-soundness doubts** → 🧭. Whether this feature, abstraction, or boundary is right at all;
  whether something simpler would do; whether it is over- or under-engineered.

In high-risk areas you must leave **either** a `file:line` you read and verified **or** an explicit
statement that it is unverified. One of the two is mandatory — never neither.

---

## Confidence scoring and the discard threshold

Qualitative confidence drifts. "Medium" means whatever the agent that wrote it felt at the time, and
under pressure to be useful it drifts upward. Score numerically instead, and discard mechanically.

**Score each finding 0–100** on one question only: *how likely is it that a competent engineer who
knows this codebase would agree this is a real problem worth acting on?* Not how severe it would be
if real — severity is a separate axis and mixing them inflates both.

| Score | Meaning |
|---|---|
| 90–100 | Demonstrated. You read the code path and can show the failure. |
| 80–89 | Strong. The mechanism is clear; one assumption remains unverified. |
| 60–79 | Plausible, unverified. Would need reading you did not do. |
| < 60 | Speculative. Pattern-matched, not established. |

**Discard everything below 80.** Not "mark as low confidence" — remove it from the report. Report
only the count of what was dropped.

This is deliberately aggressive, and it is the right trade. The failure mode that kills a review
habit is not a missed finding; it is a report where most items are noise, because after two of those
nobody reads the third. A finding you cannot score at 80 is one you have not done the work to
support — do the work, or drop it.

The exemptions are in the schema below, under `kind`, rather than stated here as a rule to remember.

### What counts as a false positive

Score these below 80 by definition, however real they look:

- A pre-existing problem the change did not create, worsen, or newly depend on
- Anything a linter, formatter, or type checker already catches
- A problem in lines the change did not touch
- A style preference not written down in the project's own conventions
- A pattern flagged by name (`as`, `OrThrow`, `Promise.all`, IAM `*`, `dangerouslySetInnerHTML`)
  without showing the danger **at that site**
- "Consider adding" tests, logging, or error handling where no new failure mode was introduced
- A failure requiring a state the code makes unreachable

## The verifier is biased too — three measured ways

Adversarial verification is the strongest tool here, and it is not neutral. When a model judges output,
three biases are measured and reproducible. They matter because this toolkit's verification pass *is* a
model judging output, and a bias you have not accounted for reads as a result.

**A verifier's verdicts are systematically tilted, and the tilt is not mainly about self-flattery.**
The obvious story is self-preference — a model rating its own family's output higher, reported in the
range of 10–25%. But that finding is contested: sanity-check work pushes back on it, and one analysis
attributes most of the effect to a **flat per-reviewer disposition** rather than to self-favouring, with
about a 2.8-point spread between the strictest and most lenient reviewer. Read together, the reliable
claim is narrower and more useful: **a verifier has a fixed lean, and you do not know which way yours
leans.**

Two things follow, and the second is the one that changes what to build.

> **`refuted` is the default because the lean is unknown, not because models are vain.** Three separate
> effects push toward over-confirming: anchoring on a claim that is already written down, the reviewer's
> own disposition, and the fact that models do not reliably self-correct without external evidence. The
> asymmetry is the counterweight to all three at once, and it does not depend on the self-preference
> number being right.

> **Different prompting matters more than a different instance.** If the lean is per-reviewer rather
> than self-directed, then a second look from the same model with the *same* framing buys little, while a
> genuinely different framing buys a lot. This is why the three lenses below are *lenses* and not
> repetitions, and why the toolkit deliberately keeps a second, differently-built reviewer around
> (`/find-bugs`, `/code-review`) instead of treating its own review as sufficient. A measurement of four
> reviewers over the same 146 pull requests found **93.4% of findings were caught by exactly one of the
> four, and none by all four** — diversity of approach, not quality of a single reviewer, is what moves
> coverage. Where a stronger or different model is available (this toolkit's `--advisor`), route the
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
are not three independent opinions, and a report must not imply they are. Say "checked from three
angles", never "three independent verifiers agreed".

## Return schema

```
[
  { id: "sequential",
    severity: "critical" | "warning" | "info" | "needs-human",
    irreversible: true | false,
    file: "path:line — the exact line to attach an inline comment to; ranges as path:start-end",
    perspective: "the cluster this came from",
    finding: "the problem in one sentence",
    why: "concrete failure scenario: input and state -> result",
    recommendation: "what to do",
    comment: "review comment body, ready to paste on that line: problem -> why it matters -> fix.
              Self-contained, minimal jargon.",
    kind: "defect" | "design-doubt" | "unverified-clear",
    confidence: 0-100 }
]
```

`kind` is orthogonal to `severity`, and it is what decides the threshold:

| `kind` | Means | Threshold |
|---|---|---|
| `defect` | Something is wrong. | Dropped below 80. |
| `design-doubt` | A question a senior would ask. Not a claim that anything is broken. | **Exempt** — its value does not depend on being right. |
| `unverified-clear` | "I could not confirm this is safe." A statement about your own knowledge. | **Exempt** — you have complete confidence about what you did not read. |

Return every `defect` scoring 80 or above, every `design-doubt` and `unverified-clear` regardless,
and a count of what was dropped. The bucket follows: `design-doubt` → 🧭, `unverified-clear` → 👤.

`file` must point at the **specific line** the comment goes on. A filename with no line is not
acceptable. `comment` may be a draft; it gets finished during synthesis.
