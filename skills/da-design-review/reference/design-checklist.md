# Design review dimensions

Work through these against the plan. Group them into parallel subagents when the plan is
substantial. Dimension 0 is never skipped, however small the plan.

Each dimension asks the same underlying question in a different place: **what does this plan make
impossible to take back, and does it know that it is doing so?**

---

## 0. Soundness and the level above ★never skipped

- Is this the right problem? Does the plan solve what was actually asked, or something adjacent?
- Is there a materially simpler approach that gets most of the value? Name it and say what it gives up.
- Over- or under-engineered: abstraction with a single implementation, configuration nobody will
  change, generality bought before a second case exists — or the reverse, a special case that will
  obviously need to generalise within a month.
- **What the plan assumes stays true.** List the assumptions and mark the load-bearing ones. An
  unstated assumption is the usual root cause of a plan that was right when written.
- **Does this propagate a pattern?** If the plan follows an existing pattern, is that pattern sound,
  or is this the Nth instance of something nobody has revisited? Open it once and check. → 🧭

## 1. One-way doors ★highest priority

The distinguishing question of a design review: **what becomes irreversible, and when?**

- **Data**: dropped columns, destructive backfills, deletions, anonymisation. Once the old value is
  gone it is gone.
- **Public contracts**: a released API shape, an event schema consumers have started reading, a URL
  that has been linked to. Reversible only if nobody has depended on it yet — and you rarely know.
- **External effects**: anything sent outside the system. A submitted government filing, a charged
  card, a dispatched email or webhook. No rollback exists at any layer.
- **Identifiers**: anything persisted or exchanged that others key off.
- **Infrastructure**: a replaced stateful resource, a deleted key, a released DNS name.

For each: **at what moment** does it become irreversible — merge, deploy, first request, first
record? That moment is where a gate has to sit, if one is needed.

## 2. Migration and ordering

- Is the change **additive-first**? Is anything destructive split into expand → migrate → contract?
- **Deploy order** between schema, code, config, and infrastructure. Does every intermediate state
  work, or only the final one? Whatever ships first runs against whatever has not shipped yet.
- **In-flight work** during the transition: open requests, queued jobs, running batches, active
  sessions, an open browser tab holding old JavaScript.
- **Backfill**: idempotent, resumable, sized for production row counts, and producing the same
  result as the online path. Safe to re-run after partial application.
- **Config and seed read live at startup** rather than from a snapshot: changing it opens a rollout
  window where new data meets old code.

## 3. Backward compatibility

- Does anything existing break — a caller, a consumer, a stored value, a bookmark?
- Are old and new able to coexist for the duration of the rollout, or does the plan assume
  everything switches at once?
- Is there a deprecation path for what is being replaced, or does it just disappear?

## 4. Failure and rollback

- **What is the rollback?** Not "revert the commit" — what happens to data written by the new code
  while it was live?
- Is there a point of no return, and does the plan acknowledge it?
- **Which way does failure fall?** When a default is missing, an evaluation errors, a context key is
  absent — does the operation **silently skip, auto-complete, or no-op**? For anything irreversible,
  statutory, externally-submitted, or billable, **failing silently is worse than failing loudly**.
- Partial failure: half the batch, half the resources, one of two services deployed.

## 5. Blast radius

- Which modules, screens, stacks, and teams does this touch? Does the plan name them, or has it only
  considered the primary path?
- **Shared code**: does the plan change something with other consumers? Are they enumerated?
- Are there other entry paths to the same behaviour — another controller, a batch job, an event
  handler, an admin screen — that the plan has not accounted for?

## 6. Security and data protection

- New surface: endpoints, permissions, roles, external integrations.
- Tenant boundary, if the system is multi-tenant. Does the plan say how it is enforced, or assume it?
- PII and secrets: what is stored, where it is logged, what crosses a boundary.
- Authorization: is it enforced server-side, or does the plan describe hiding something in the UI?

## 7. Operability

- **How will you know it worked?** Not the absence of errors — an active signal. Especially where a
  path can succeed silently by doing nothing.
- How will you know it broke, and how fast?
- Is there a kill switch, a feature flag, a staged rollout — and does the plan say who flips it?
- What does the on-call person need to know that is not in the plan?

## 8. Verifiability

- Can the acceptance criteria actually be executed? A criterion nobody can run is a wish.
- What cannot be covered by automated tests and will need manual or real-environment verification?
  The plan should name these rather than discover them at merge time.
- Does the plan's definition of done include evidence, or only "implemented"?

---

## Calibration

Apply `finding-discipline.md` throughout. Two adjustments for reviewing plans rather than code:

**A plan is allowed to be incomplete.** Not every unanswered question is a defect. Ask whether the
answer is needed *before implementation starts* or can be settled during it. Only the former is 🔴.

**Reachability is weaker evidence here.** In code review you can often demonstrate that a path is
unreachable. In a plan the code does not exist yet, so err toward raising the concern and marking
confidence honestly — but do not inflate severity to compensate for the uncertainty.
