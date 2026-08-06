# Silent failures in their cross-layer form

Read this during Step 4, after every layer report is in. It is the only reference `review-all` loads,
and the reason is that **no layer review can reach any of these**: each copy, each half, each side is
locally correct, so a reviewer scoped to one layer has nothing to report.

Read [`silent-failure-patterns.md`](silent-failure-patterns.md) first if you have not. These are the
same five patterns, in the shape they take when the cause and the consequence sit in different layers.
Do not stop at re-applying the patterns as written — a pattern applied within one layer has already
been applied, by that layer.

**When only one layer ran, this file is the only one to read** — skip `silent-failure-patterns.md` and
`llm-authored-code.md`. The layer skill already applied both internally, in its find phase *and* its
verify phase, and with no boundary for a cross-layer pattern to straddle, re-reading them here just
re-applies a single-layer lens to a single layer and re-finds what the layer already reported. What is
left for the dispatcher is this file's skeleton and the pull-up of 🧭 and 👤.

Severity and discipline are unchanged: [`finding-discipline.md`](finding-discipline.md) governs, and a
finding here needs the same traced path and confidence score as anywhere else. Being a known
cross-layer shape is not evidence.

---

## The four structural forms — take these before the five patterns

These are about **order and ownership** rather than about a pattern in the code, which is why they come
first: they are answerable from the layer reports you already have, without opening anything.

- **Schema ↔ code deploy-order coupling.** Do the database or contract change (backend), the code that
  reads it, and the infrastructure deploy survive being applied in the **real** order? Is it a
  backward-compatible staged rollout, or does it only work if everything lands at once?
- **API contract, backend ↔ frontend.** Does the contract change land in the same PR or release as the
  frontend that consumes it, or does one side shipping first break the other?
- **Infrastructure change versus application assumptions.** Does renaming, replacing, or re-scoping a
  resource break a runtime assumption held in backend or frontend code?
- **Release order and rollback.** The safe order to ship this change, and what stays consistent if only
  one side is rolled back.

Then the five patterns below, and the sixth that exists only across a boundary. All ten checks are what
"applied the cross-layer forms" means.

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

## 6. A fabrication both layers agree on

Specific to agent-authored change, and the cross-layer half of
[`llm-authored-code.md`](llm-authored-code.md). A model writing both sides of a boundary in one pass makes
them **consistent with each other and wrong about the outside world**:

- The frontend calls an endpoint and the backend defines it — but the path, method, or field names are not
  what the deployed contract or the generated client says. Each half reviews as correct because it matches
  the other half.
- Both sides adopt the same name for a value the upstream service actually calls something else.
- A shared constant is introduced in two layers with the same plausible value, and the value is wrong.
- Infrastructure provisions a resource under the name the application expects, and neither matches what the
  platform actually assigns.

The layer reviews structurally cannot catch this: internal consistency is precisely what each of them
checks. **Check one side against something that is not the other side** — the generated client, the
OpenAPI document, the deployed schema, the provider's documentation, a caller that predates this change.
If both halves are new, there is no anchor inside the diff at all, and that is itself the finding. → 🔴

---

## Reporting these

They go under **🔗 Cross-layer irreversibility and consistency risks**, and each row names **both**
layers. Follow each with one 📍 location per side — for a backend ↔ frontend contract issue that means a
line in each repository or directory — and one 💬 suggested comment.

A cross-layer finding whose 📍 points at only one layer has not been traced across the boundary yet.

**Attach the three-part set only to the 🔗 findings raised here.** Each layer report already carries its
own 📍 location, plain explanation, and 💬 suggested comment per finding — **do not restate them.** The
dispatcher adds presentation to what it newly raises, and passes the rest through untouched.

---

## The report skeleton

```markdown
## Cross-Layer Review Summary

### Layers touched
- infra: N files / backend: M files / frontend: K files (unclassified: L)

### Layer reports
- 🏗️ Infra / ⚙️ Backend / 🖥️ Frontend — see each report for detail
- Counts are consolidated in 📊 below; not repeated here
- Each report carries, per ⛔/🔴 finding: 📍 exact line, the detailed why-this-is-wrong, a plain explanation, and 💬 a pasteable comment

### 🔗 Cross-layer irreversibility and consistency risks (highest priority)
| Risk | Layers | What breaks | Ship order / must confirm |
|---|---|---|---|
| e.g. contract field made required, backend deployed first | backend→frontend | old frontend fails validation | ship frontend first, or accept both during a staged migration |

Follow each 🔗 row with **one 📍 per side**, the detailed why-this-is-wrong, and one 💬 pasteable comment.

### 🧭 Design and system-wide doubts / unverified clears (pulled up from every layer)
- Which layer, and what would settle it.

### 🔎 Confidence of this review
- What each layer actually read versus assumed, in one or two lines. State plainly that a clean
  result means "not detected at this depth", not a design sign-off.

### 📊 Summary
| Layer | ⛔ | 🔴 | 🟡 | 💡 | 🧭 | 👤 |
|---|---|---|---|---|---|---|
| infra | | | | | | |
| backend | | | | | | |
| frontend | | | | | | |
| 🔗 cross-layer | | | | | | |
```
