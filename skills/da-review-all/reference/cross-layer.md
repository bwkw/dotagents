# Silent failures in their cross-layer form

Read this during Step 4, after every layer report is in. It is the only reference `review-all` loads,
and the reason is that **no layer review can reach any of these**: each copy, each half, each side is
locally correct, so a reviewer scoped to one layer has nothing to report.

Read [`silent-failure-patterns.md`](silent-failure-patterns.md) first if you have not. These are the
same five patterns, in the shape they take when the cause and the consequence sit in different layers.
Do not stop at re-applying the patterns as written — a pattern applied within one layer has already
been applied, by that layer.

Severity and discipline are unchanged: [`finding-discipline.md`](finding-discipline.md) governs, and a
finding here needs the same traced path and confidence score as anywhere else. Being a known
cross-layer shape is not evidence.

---

## 1. Global default in one layer, compensating work in another

A shared default — a job catalog, a base class, a database default, a seed — whose correctness depends
on the **frontend** sending a particular value, or a **batch job** setting a flag, or an
**infrastructure** parameter being present.

Read alone, each layer is right. The backend default is reasonable; the frontend sends what it was told
to send; the infrastructure supplies what it was asked for.

What to do:

1. `grep` every entry path **across all layers**, not only within the layer that owns the default.
   Other controllers, other screens, batch jobs, event handlers, admin tooling, IaC that writes the
   same value.
2. Check each against the compensation individually.
3. Ask what **enforces** the invariant when the next caller is added in a third layer. A guard, a
   constraint, an architecture test, a contract test? **If nothing does, that is the finding** → 🧭, or
   🔴 when you can read a path to real harm.

The third step is the one that gets skipped. "Every current caller happens to be correct" is a
snapshot, and the next caller is written by someone who read one layer.

## 2. Fail-open across a layer boundary

The direction of the fallback when the value arrives **from somewhere else**: a config the
infrastructure was meant to supply, a header the frontend was meant to send, a claim the gateway was
meant to inject, a field the upstream service was meant to populate.

If the receiving layer treats **absent as permitted**, or silently skips an irreversible, statutory, or
billable action when the input is missing, the two layers are individually defensible and jointly
wrong. Ask which layer is *responsible* for the value being present, and whether anything fails loudly
when it is not.

> **Failing silently is worse than failing loudly**, and a layer boundary is exactly where silence
> hides — each side assumes the other handled it. → 🧭 / 🔴

## 3. One source of truth, re-declared in another layer

A mapping, enum, constant, or correspondence declared authoritative in backend code and
**re-hardcoded** in an infrastructure template, a frontend constant, a seed, a CI variable, or a
migration.

**Search for the literal values, not the identifier.** The names will differ across layers — that is
why this survives review. A backend `OrderStatus.CANCELLED` and a Terraform `"cancelled"` and a
frontend `'CANCELLED'` are the same fact spelled three ways, and nothing compares them.

If no test reconciles them, they will drift, and the drift is silent. → 🟡

## 4. Live-read config against a multi-layer rollout

A parameter store value, seeded catalog, or feature flag read **fresh on each access** takes effect the
moment infrastructure writes it — **not** when the application code that understands it finishes
deploying.

Establish the ordering across *both* pipelines:

- When does the infrastructure change take effect — on merge, on apply, or by a manual step?
- When does the application code that reads it finish rolling out?
- Is there a **hard gate** enforcing that order, or is the safe order a convention someone remembers?

If you cannot determine it from the repositories, that is **👤 needs human**, not a clean pass. This is
the pattern most likely to be obvious to whoever built it and invisible to everyone else.

## 5. Detectability split across layers

The irreversible action happens in one layer and the only signal lands in another: a log line the
backend emits that nothing alerts on, a metric the infrastructure collects for an action it cannot
interpret, an error the frontend swallows because the backend "already logged it".

Each layer looks instrumented. In practice the failure is undetectable, because no one owns the join.
Name which layer would have to change for the failure to be noticed. → 🟡

> **Do not propose a new sweep or cron as the fix.** Prefer one passive monitor plus a documented manual
> recovery; suggest a standing process only when recovery genuinely cannot wait for a human.

---

## Reporting these

They go under **🔗 Cross-layer irreversibility and consistency risks**, and each row names **both**
layers. Follow each with one 📍 location per side — for a backend ↔ frontend contract issue that means a
line in each repository or directory — and one 💬 suggested comment.

A cross-layer finding whose 📍 points at only one layer has not been traced across the boundary yet.
