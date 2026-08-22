# Reviewing code an LLM probably wrote

Assume it did. In this workflow most diffs are agent-authored, and that changes **where the defects
are**, not just how many. The failure profile is specific and worth checking directly, because it is
almost the inverse of human error: the code compiles, reads well, follows the surrounding conventions,
and is confidently wrong about a fact.

> The signals that matter most here are **not** stylistic. They are: an unfamiliar API used
> confidently, a suspiciously precise function signature, a dependency the team has never used
> before, and a guard for a state nothing constructs. When the author is a model, spend the review
> budget there.

---

## 1. Fabricated dependencies — check they exist before anything else

Roughly **one in five** agent-authored samples references a package that does not exist. This is not a
rare edge case, and it has a matching attack: **slopsquatting**, where someone registers the
hallucinated name and waits for it to be installed.

For every added or changed dependency:

- **Does the package exist, and is it the one intended?** Check the registry, not the lockfile — the
  lockfile records what was resolved, which may be the attacker's package.
- **Is the name plausibly a typo or a near-miss** of a well-known package? One transposed character,
  a scoped/unscoped swap, a hyphen where the real one has a dot.
- **Is the pinned version real, and is it current?** A yanked version, or one pinned just before a
  disclosed CVE, is a common shape — the model reproduces what it saw during training.
- **Was a new direct dependency added for something the codebase already does?** Check for the existing
  helper before accepting a new package.

A dependency that cannot be confirmed to exist is **⛔**, not a nit. It is the one finding here that
justifies blocking on its own.

## 2. Fabricated APIs and signatures

Confident use of a method, option, or field that the installed version does not have. It looks right
because it is the API the library *should* have.

- **Open the installed version** — `node_modules`, the vendor directory, the lockfile's resolved
  version, the type definitions — not the current online documentation. The docs describe the latest
  release; the repository pins something else.
- **Precision is a warning sign, not reassurance.** An exact-looking signature with named options that
  nobody on the team recognises is more suspect than a vague one.
- For a dynamically typed call path with no type checking, the failure is a runtime `undefined` on a
  path that tests do not cover. Ask which test would have caught it.

## 3. Happy-path bias

Agent-authored code handles the described case well and the undescribed cases structurally poorly.
Specific shapes to grep for in the diff:

- **Network or IPC calls with no timeout.** The single most common omission, and the one that turns a
  slow dependency into an outage. Ask what the default timeout is — for many clients it is *none*.
- **No retry, or retry with no backoff and no cap.** Retry without backoff converts a blip into a
  self-inflicted denial of service.
- **A catch-all that swallows.** `catch { }`, `except Exception: pass`, a logged-and-continued error
  whose caller then proceeds as if it succeeded. Compare against the fail-open direction question in
  `silent-failure-patterns.md`.
- **Missing null / empty / absent-key handling** on inputs the code does not control.
- **Pagination, streaming, and loop termination** — the case where there is one more page than expected,
  or zero.

## 4. Guards for states the type should not have allowed

The mirror image of happy-path bias, and the one a sweep for missing guards will mistake for
diligence. Where a type admits a state the domain does not have, agent-authored code fills it in — a
branch, a fallback, a `?? null`. Nothing was omitted. The author handled every state the signature
offered, which is the right thing to do with that signature.

The cost lands on the reviewer. Whether a guard is **live or dead** cannot be read off the function
holding it; it takes tracing every site that constructs the value, and that answer is never written
down, so the next reader traces it again. Three independent flags on one record put eight states in
reach where four exist, and each surplus state buys a branch somebody has to adjudicate.

- **For every defensive branch in the diff, name the state that reaches it.** If no construction site
  produces it, the finding is **the type, not the branch** — report the field that admits the state,
  not the guard that handles it. Deleting the guard and leaving the type is the fix that comes back.
- **A record of optionals where the domain has a sum.** A loading flag plus `data | null` plus
  `error | null` is the canonical shape: eight combinations, four meanings. Ask whether the states can
  be enumerated instead, each variant carrying only the data it actually has — then the surplus
  branches have nowhere to attach.
- **A `default` clause, or a `catch` that continues, over a closed set of cases.** The compiler had the
  whole set and was talked out of using it, so the case added elsewhere next month is absorbed in
  silence. Where a total branch is genuinely wanted, ask for the form that still fails to compile — an
  exhaustiveness assertion rather than a fallback.
- **Two branches with the same body for different reasons.** Usually one of them is real and the other
  is the type's slack. Worth separating before either is trusted.
- **When the invariant genuinely cannot be a type, ask where it is enforced.** A lint rule or a schema
  check fails on the machine that runs it; the same rule written into a review checklist or an
  instruction file fails only when somebody remembers it. Prefer the one CI can lose sleep over, and
  treat "the convention is documented" as unenforced.

Severity is usually `design-doubt`, on the same footing as over-abstraction below — the code is correct
today and the next change pays. It becomes correctness when the surplus state **is** reachable and the
branch handles it wrongly, which is the "right type, wrong value" shape arriving by this route.

## 5. Placeholder credentials and secrets

Placeholder API keys, tokens, and admin credentials get completed inline and read as configuration.
Grep the diff for anything key-shaped, and treat a "example"/"changeme"/"xxx" value in a code path as
either a real leak or a broken default — both are findings.

## 6. Plausible-but-wrong business logic

The hardest of these, and the reason a human still reads the diff. The code is well-formed and does
something *reasonable* that is not what was asked.

- **Read the requirement, then the code, in that order.** Reviewing the code first anchors you to the
  behaviour it implements, and the mismatch stops being visible.
- **Boundaries and rounding.** Inclusive versus exclusive ranges, off-by-one on dates, half-up versus
  banker's rounding on money, timezone applied at the wrong step.
- **Inverted conditions and negations** that read naturally in either direction.
- **Right type, wrong value.** An edge-case branch that returns a well-typed answer that is incorrect —
  zero instead of null, an empty list instead of an error, the first match instead of the best.

## 7. Over-abstraction

The opposite failure to the usual review instinct. Agent-authored code tends toward *more* structure
than the problem needs: a strategy interface with one implementation, a config option nobody sets, a
generic helper used once. `finding-discipline.md` suppresses ordinary nits, but this one is a
`design-doubt` worth raising, because each layer is permanent and the next change pays for it.

---

## How to report these

Same discipline as everything else — a traced path, a confidence score, `file:line`. Two adjustments:

- **Say when a finding is of this kind.** "This package may not exist" and "this guard is missing" are
  acted on differently: the first is verified in a registry in ten seconds, the second needs judgement.
- **Do not fill a report with these on a diff the author clearly hand-wrote.** The point is to spend the
  budget where the defects actually are. If the diff shows signs of human authorship — inconsistent
  style, a half-finished refactor, a commented-out attempt — weight the ordinary clusters instead.
