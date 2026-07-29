# Reviewing code an LLM probably wrote

Assume it did. In this workflow most diffs are agent-authored, and that changes **where the defects
are**, not just how many. The failure profile is specific and worth checking directly, because it is
almost the inverse of human error: the code compiles, reads well, follows the surrounding conventions,
and is confidently wrong about a fact.

> The signals that matter most here are **not** stylistic. They are: an unfamiliar API used
> confidently, a suspiciously precise function signature, and a dependency the team has never used
> before. When the author is a model, spend the review budget there.

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

## 4. Placeholder credentials and secrets

Placeholder API keys, tokens, and admin credentials get completed inline and read as configuration.
Grep the diff for anything key-shaped, and treat a "example"/"changeme"/"xxx" value in a code path as
either a real leak or a broken default — both are findings.

## 5. Plausible-but-wrong business logic

The hardest of these, and the reason a human still reads the diff. The code is well-formed and does
something *reasonable* that is not what was asked.

- **Read the requirement, then the code, in that order.** Reviewing the code first anchors you to the
  behaviour it implements, and the mismatch stops being visible.
- **Boundaries and rounding.** Inclusive versus exclusive ranges, off-by-one on dates, half-up versus
  banker's rounding on money, timezone applied at the wrong step.
- **Inverted conditions and negations** that read naturally in either direction.
- **Right type, wrong value.** An edge-case branch that returns a well-typed answer that is incorrect —
  zero instead of null, an empty list instead of an error, the first match instead of the best.

## 6. Over-abstraction

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
