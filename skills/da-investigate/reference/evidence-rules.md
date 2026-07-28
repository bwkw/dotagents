# Evidence rules

How to report what you found, and — the part that carries the weight — what you did not.

## The rules

**Report only what you verified directly.** Not what the naming implies, not what the pattern
elsewhere suggests, not what would be reasonable. If you did not open it, you did not verify it.

**Cite locations as `path/to/file.ts:L42`.** A claim without a location is not checkable, and an
uncheckable claim is indistinguishable from a guess. Ranges as `:L42-58`.

**When you have no basis, say so.** Write "could not confirm" and name what would settle it. Never
fill a gap with a plausible sentence — a fluent guess is more damaging than an admitted gap, because
it does not look like one.

**Separate fact from inference, visibly.** Both are useful; conflating them is not.

- Fact: "`TenantGuard` is applied at `src/api/foo.controller.ts:L12`."
- Inference: "So requests through this controller are probably tenant-scoped — assuming the guard
  reads the same tenant key the repository filters on, which I did not verify."

**Attach a URL to any external claim.** Documentation, issues, release notes, Stack Overflow.
Without a URL it is a memory, and memory about library behaviour is where confident errors come from.

**Name the absences.** "I did not read the batch path" is a finding. Saying nothing about the batch
path reads as "the batch path is fine".

## Confidence levels

| Level | Means |
|---|---|
| **Confirmed** | Read it. Cited. |
| **Inferred** | Follows from something confirmed, plus a stated assumption. The assumption is written down. |
| **Unconfirmed** | Did not check. What would settle it is named. |

Use exactly these words. "Probably", "should be", "it seems", "likely" all collapse the distinction
between the second and third, which is precisely the distinction that matters.

## Search-negative results

"I searched and found nothing" is a real result, but only with the search shown:

> No other caller found. Searched: `rg 'createInvoice' --type ts` across the repo (3 hits, all in
> tests), `rg 'createInvoice' --type json` for config-driven dispatch (0 hits). **Not covered:**
> dynamic dispatch by string, and any caller in another repository.

Without the query, "found nothing" is unverifiable, and the reader cannot see the hole you left.

## Worked contrast

Bad:

> The tenant filter is applied in the repository layer, so cross-tenant access should not be
> possible.

Two problems: no location, and "should not be possible" is inference presented as fact.

Good:

> **Confirmed** — `PersonRepository.findMany` applies `where: { tenantId }` at
> `src/hr/person.repository.ts:L88`.
> **Inferred** — calls going through this repository are therefore tenant-scoped, *assuming*
> `tenantId` comes from the request context rather than a parameter the caller supplies. I did not
> trace where it is populated.
> **Unconfirmed** — raw SQL. `rg 'queryRaw' src/hr` returns 4 hits I did not read. That is the next
> thing to check.
