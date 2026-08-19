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

## 0b. Aggregate and transaction boundaries ★a rewrite if wrong

The skill body weights these with architecture and security, **above where code review weights them**,
and this dimension is where that weighting is spent: at plan stage a boundary is a paragraph, and
afterwards it is every call site that grew around it. **A plan silent on all of this is ❓, not a pass.**

- **What is one aggregate here, and what is one transaction?** For every write the plan describes: which
  aggregate owns it, and does a single transaction cover the whole state change? "Update the submission
  and advance the flow" without saying whether that is one transaction has not decided anything yet.
- **Write the invariants as sentences, then ask what can see them.** "Only the latest submission may be
  approved, and only by the current step's approver" names two things. **Can one aggregate see everything
  the sentence names?** If not, the invariant is cross-aggregate, and the plan must say what holds it:
  the same transaction, a lock, or an accepted window in which it can be violated.
- **A lock in the plan is a statement about the boundary, not a detail of it.** Reaching for an advisory
  lock, a `SELECT FOR UPDATE` across two tables, or a serialisable transaction says the boundary sits
  somewhere the invariant does not. Sometimes that is the cheaper answer — but ask the alternative out
  loud: **can the invariant be made local**, one side holding the value it needs instead of reading the
  other's? And if the lock stays: **what forces every future entry point to take it?** A choke point or
  an architecture test, never a comment enumerating today's callers
  (`silent-failure-patterns.md`, pattern 1).
- **If the plan needs to undo, the two boundaries already disagree.** Release the claim, revert the
  status, cancel what was sent — that is a saga, and it must be planned as one: **one applier, reached by
  every failing path**, not "roll back on error" left to the implementation. Where the effect left the
  system, no compensation exists at any layer — that belongs in dimension 1.
- **Guards before the first side effect.** Ordering is free in a plan and expensive in code: validate
  before claiming, incrementing, sending or writing. Every guard the plan places after a mutation is a
  rollback path somebody has to write, test and get right.
- **Where will the rule live once written?** The test to apply now: **if a second entry point — an admin
  screen, a batch job, a new endpoint — is added next quarter, must this check be copied?** If yes, the
  plan should say the rule sits on the aggregate. The same for ports: the repository interface belongs in
  the domain, its implementation outside.
- **One rule, one definition — including the read side.** A list screen filtering on status in SQL while
  the aggregate decides the same thing in code is one rule written twice; they agree until the next status
  exists. The plan should name which is authoritative and how the other derives from it.

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

## Landing boundaries

Where the work divides into separate changes to ship. The inputs are the two sections around this one:
what is irreversible, and what must deploy in order.

- **A one-way door is its own landing.** Shipped alongside reversible work, reverting it takes back
  things that did not need taking back.
- **A contract and its consumer: same landing, or ordered?** `da-review-all` raises this as a finding
  after the code exists. Answered here, it never becomes one.
- **expand → migrate → contract is three landings**, not one. "Add the column, backfill it, drop the
  old one" is three.
- **Fold together anything with no ordering constraint.** Splitting has a cost -- each landing is
  another review, another gate run, another merge. Separate only what must be.
- **Every landing needs a gate you can name.** `gate.sh verify` is what runs it. If you cannot say
  what proves a landing is done, it cannot be verified, and the plan is not finished.

A plan that is genuinely one landing is one row with a reason. An absent table means nobody decided,
which is the state this section exists to end.

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

## 9. Production readiness ★the tech-lead gate

The dimensions a production-readiness review covers, applied at plan stage where they are still cheap to
change. Do not treat this as a checkbox sweep — the value is finding the dimension the plan is **silent**
on, because silence is where the surprise comes from.

| Dimension | The question that catches things |
|---|---|
| **Service levels** | What does "working" mean numerically, and who notices when it stops? A plan with no target has no way to fail visibly. |
| **Architecture** | Covered by §0 and §5 above. |
| **Performance and capacity** | At what load does this stop working? What happens at 10×? Is there a quota, a connection pool, or a rate limit that this change moves closer to its ceiling? |
| **Observability** | §7. |
| **Testing** | §8. |
| **Deployment and rollback** | §2 and §4. |
| **Documentation and runbook** | When this pages someone at 3am, what do they read? A plan that changes operational behaviour and ships no runbook change has moved work onto the on-call rotation without saying so. |
| **Dependency readiness** | **The most commonly skipped one.** This plan depends on other services, teams, quotas, or infrastructure being ready. Are they? Has anyone asked them, or is it assumed? A dependency that is "nearly done" elsewhere is a scheduling risk this plan owns. |

Two failure modes worth naming, because they are documented pitfalls of this kind of review rather than
hypotheticals: treating readiness as a **one-time gate** (it changes as the system does), and
**checkbox culture** — answering the dimension instead of thinking about it. If every row gets a
confident one-line answer, the review has not happened.

---

## Calibration

Apply `finding-discipline.md` throughout. Two adjustments for reviewing plans rather than code:

**A plan is allowed to be incomplete.** Not every unanswered question is a defect. Ask whether the
answer is needed *before implementation starts* or can be settled during it. Only the former is 🔴.

**Reachability is weaker evidence here.** In code review you can often demonstrate that a path is
unreachable. In a plan the code does not exist yet, so err toward raising the concern and marking
confidence honestly — but do not inflate severity to compensate for the uncertainty.
