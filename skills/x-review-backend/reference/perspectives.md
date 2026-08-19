# Backend layer — what to trace, and the perspective clusters

The two layer-specific parts of the review: **Step 2** (what to trace) and **Step 5** (the perspective
clusters to fan out across). Posture, the seven steps, and the finding discipline come from the skill
that sent you here.

If you arrived here without having read `finding-discipline.md` and `review-process.md`, **read those
first** — this file assumes both. `silent-failure-patterns.md` applies on top of whichever cluster you
are assigned.

**Read-only. Never modify code.**

---

## Step 2 — what to trace in this layer

1. **Changed units**: functions, classes, types, tables, contracts, config added, changed, or removed.
2. **Bidirectional dependency trace** (`grep` / reference search):
   - **Upstream (callers)**: every caller. A change to a shared utility, common foundation,
     shared kernel, or generic function requires **naming every module and pipeline that uses it**.
   - **Downstream (data)**: where the data this writes or emits ends up — other aggregates, other
     contexts, projections, batch jobs, API responses, external integrations.
3. **Related domains and bounded contexts**: enumerate **all** of them. Everything listed becomes
   required reading for the Step 5 subagents.
4. **Adjacent assets**: migrations, Prisma schema, DTOs, contracts, seeds, config, tests.

Suggested specialist agents when the repository defines them: `senior-architect`, `ddd-expert`,
`database-specialist`, or a domain expert. Fall back to `general-purpose` with the cluster checklist.

---

## Perspective clusters

### 0. Design soundness and the question one level up ★system-wide

Required even for a small diff. When collapsing the fan-out, this must still land in one subagent.

- Is this change, this design, **correct at all**? Is the feature needed, is the abstraction and
  boundary right, is there a simpler alternative?
- **Verify the foundation by reading it.** Open at least once the shared helper, base class, or
  existing pattern this change depends on, and confirm with `file:line` that its safety premises —
  idempotency, guards, tenant boundary, transaction boundary — actually hold. Do not skip it because
  "it already existed". Cannot confirm → 👤. Suspicious → 🧭.
- **Propagation risk**: is this adding the Nth instance to a known dangerous or unverified pattern
  (external submission with unverified guards, an untested family, a path that can double-apply)? → 🧭
- Naming, responsibility, over- and under-engineering: proliferating Service/Helper/Util layers,
  excessive generalisation, or spreading copy-paste.

### 1. Intent and semantic correctness ★always covered

**The largest category of bugs that survive review, by a wide margin.** Not a style concern — the code
does something other than what it was asked to do, and it reads as plausible while doing it.

- **Against the stated intent.** Read the spec, plan, or PR description first. Does each changed unit do
  what that says? A change that is internally consistent and answers a different question is the shape
  this cluster exists to catch, and it is invisible without the intent in hand. **If there is no stated
  intent, that is the finding** → 👤.
- **Exception and error handling** — the single most missed sub-cause. Is every thrown error handled at
  a level that can act on it? A `catch` that logs and continues, a swallowed error, a retry around a
  non-idempotent call, an error path that returns success. **The happy path being right says nothing.**
- **Missing cases.** Enumerate the inputs the change accepts: empty, zero, null, single element,
  boundary, the value the caller never sends today. Which branch handles each?
- **Wrong operator, comparison, or query.** `>=` for `>`, `&&` for `||`, an inverted guard, a join that
  multiplies rows, a filter on the wrong column. Read the condition against what it is meant to mean,
  not against whether it compiles.
- **Incomplete change.** One call site updated and its siblings not; a field added to a type and not to
  the mapper; a new state added to an enum and not to the switch that consumes it.

### 2. Architecture, aggregate boundaries, DDD

- Layer dependencies (Domain reaching back into Infra/API/QueryService); aggregate boundaries and
  granularity; cross-aggregate invariants; transaction boundaries.
- Module and context boundaries (going through an adapter rather than reaching into another
  context's internals); CQRS separation (Command depending on Query).
- Are business rules expressed in the domain layer? Is logic leaking into repositories or use cases?
- Abstraction level; does naming reflect the domain?
- New or updated dependencies: is there no alternative, licence, known CVEs, direct imports only as
  direct dependencies, transitive pins via overrides, and is the lockfile diff intentional?

### 3. Data model, persistence, migrations ★irreversibility

- **Migration irreversibility**: dropping or renaming a column, changing a type, adding NOT NULL,
  changing a default, adding a constraint or FK — will it fail against existing data, and can it be
  rolled back?
- **Backfill soundness**: idempotent, resumable, completes at production row counts (avoiding
  timeouts and hot-table locks), produces the same result as the online path, safe to re-run after
  partial application.
- Additive-only? Are destructive changes split expand → migrate → contract? Are constraints being
  added without checking the production and staging data distribution?
- **"The real data is fine" is a claim, and the local database is not the real data** — it is whatever
  the last reset and seed made it. For a new constraint, a stricter read, or the removal of a data
  assumption, require a query that can be run against **production or staging**, and the count it
  returned. Data baked into snapshots and fixtures (task JSON, recorded payloads) counts as data.
- **Machinery kept for values that do not exist.** Several indexes and a branch, or an inference rule
  ("one disappeared and one appeared, so treat it as a rename") — ask **how many rows actually carry a
  non-default value in that column**, in production. Zero means the whole apparatus is protecting
  nothing; deleting one such mechanism removed 160 lines.
- Index design; schema shapes that induce N+1; soundness of Temporal or event-sourcing usage; joins
  and relations onto views; new uses of `OrThrow`.
- Timezone and date boundaries (date-only versus datetime, storing UTC, DST and month-end edges).
- Data retention, deletion, and anonymisation policy (PII retention periods, regulation).

### 4. Security, multi-tenancy, PII ★focus

- Cross-tenant leakage: the tenant boundary filter, including inside joins and subqueries; whether
  it is applied via the infra layer or the request context.
- Authentication and authorization: guards on new endpoints, permission scope, non-human actors.
- PII and credential storage (encryption, hashing, tokenisation) and exposure in logs or responses;
  input validation; SSRF; token leakage.
- Are reads and writes of sensitive data (national ID numbers and similar) captured in an audit log?
  Can the design satisfy a data subject's deletion, disclosure, or retention request?

### 5. API contracts, backward compatibility, schema evolution, runtime compatibility ★irreversibility

- Breaking changes to public APIs (oRPC/REST/OpenAPI): removal, rename, making a field required,
  type change, route change.
- Breaking changes to event, message, or queue schemas — consumer compatibility.
- Are optional DTO fields nullable? Error localisation. Versioning and staged migration.

### 6. Reliability, idempotency, concurrency, resource lifetime, performance

Double-application and data corruption are irreversible — file them with `irreversible=true`.

**Concurrency, named explicitly because it is a measured missed category (4.3%) and reads as correct in
isolation.** Two requests interleaving on the same row; a read-then-write with no lock, version, or
conditional update; a "check then act" where the check can go stale; a consumer that assumes it is the
only one; a rebalance or restart mid-batch. Ask what happens when **two of these run at the same
instant**, not what happens when one runs.

**Resource lifetime (1.6% of missed bugs, and the least-caught category).** Every acquired thing needs a
release on **every** path including the error path: connections, file handles, streams, subscriptions,
timers, listeners, spans. An unbounded buffer, cache, or in-memory accumulator that grows per request is
the same defect with a slower fuse.

**Guards before the first side effect.** A validation that runs *after* the mutation it exists to prevent
turns a rejection into an undo: the version and position check landing after the row is claimed, the
quota check after the counter is incremented, the eligibility check after the notification is queued. Ask
of every new guard **what has already happened by the time it fails.** Reordering it is usually free, and
it deletes the rollback path — which is where the next item's bugs live.

**Compensation handed back to the caller.** A function that returns *what should be undone* — a rollback
descriptor, a list of side effects to reverse, a cleanup callback — has moved a side effect into a value,
and the compiler does not force anyone to spend it. One caller applies it, the next drops it on the floor,
and the state is left half-changed with nothing failing and nothing logged. Two questions: **is there
exactly one applier, and does every path that produces one reach it?** Ask the same of pairs that must
always happen together — release the claim *and* revert the status. **A two-step pair assembled by hand at
five call sites is wrong at the fifth**, and the omission is invisible in a diff that shows only the
site being added.

- Idempotency: re-runs, retries, and duplicate delivery must not double-apply — double provisioning,
  double billing, duplicate notifications. Retry and backoff behaviour.
- **Concurrent write conflicts** — lost update, check-then-write TOCTOU, unique-constraint races —
  protected by pessimistic locking (`SELECT FOR UPDATE`), optimistic locking (a version column), or
  a database constraint. Does the aggregate's read-modify-write survive contention?
- Queries in the same transaction parallelised with `Promise.all` (they must be serialised);
  consistency under partial failure; rollback when an external call fails; runaway guards on batch
  and pagination loops.
- N+1, O(N²), database access inside loops, connection exhaustion, rate limits and per-tenant quotas
  on expensive endpoints (noisy-neighbour prevention).

### 7. Observability, operability, deploy safety

- Are logs, metrics, and traces sufficient to investigate an incident? Are alerts and monitoring
  included?
- **Schema ↔ code deploy ordering**: does reading a new column break under the deploy order? Is the
  read backward compatible? Feature flags, staged rollout, kill switches, old-and-new coexistence
  during migration.
- Configuration and secret management; error-handling design (neverthrow `Result`, exhaustiveness,
  nothing swallowed, no assertion abuse).
- **Graceful shutdown.** On SIGTERM, does in-flight work finish or get dropped? Does the readiness check
  start failing *before* the process stops accepting connections? A new long-running handler, consumer,
  or background task adds a way to lose work on **every** deploy — which happens daily, silently, and
  presents as an intermittent data problem rather than as a shutdown bug.
- **Capacity headroom this change consumes.** Connection pool size, worker concurrency, a per-tenant
  quota, an upstream rate limit. The question is not "is it fast enough" but "what is now closer to its
  ceiling, and what happens when it gets there".

### 8. Type design — do the types carry the invariants?

A separate lens from architecture. Architecture asks whether the boundaries sit in the right place;
this asks whether the type system does any work at those boundaries, or whether every invariant
lives in a comment and the hope of a careful reviewer.

Report anything that fails one of these, naming the specific field or signature:

- **Encapsulation** — can a caller construct an invalid value? A DTO where every field is optional
  and nullable pushes validation onto every consumer, permanently.
- **Invariants in the type** — "non-empty", "these two fields are set together or not at all", "this
  ID belongs to this tenant". Expressed as a type, or as a convention nothing enforces? A union of
  valid shapes beats a record of optionals.
- **Usefulness** — does the type make the common correct thing easy, or does every call site repeat
  the same three lines of narrowing?
- **Enforcement** — is there a path around it? An `as` cast, a raw query typed `any`, a `JSON.parse`
  with no schema at the boundary.
- **A structural subset standing in for a declared port.** Typing a dependency inline —
  `deps: { findById(id): Promise<X> }` — rather than importing the abstract repository from where it is
  declared compiles forever: the real class can gain a parameter, change a return type, or move, and
  **nothing points at the mismatch**, because structural typing only asks whether *this* shape is
  satisfied. Test doubles satisfy the hand-written shape too, so the suite stays green while the fake and
  the real one drift apart. Ask why the declared interface is not imported — "it made the test easier to
  write" is the reason that produces this, and it trades a compile error for a runtime one.
- **Modelled on one side only.** The commonest half-done version: the *set* of kinds gets narrowed
  (`z.enum(['FIXED','TODAY'])`) while **kind and value stay separate fields**, so `{kind:'TODAY',
  value:'2020-04-01'}` is still constructible. That looks like "we typed it" and is not. Ask the
  invariant question **per layer**: the wire contract, the domain's input type, the state the domain
  holds, the frontend's editing state — **which of them makes this unrepresentable?** If the answer for
  any of them is "a runtime check", say so and make the author justify why a type cannot carry it.
  What it costs to leave: every consumer keeps defensive code for a state that should not exist, forever.
- **Every construction site, not just the one in the diff.** When a discriminated union or a refined type
  is introduced, the same shape usually exists in several places — ETL runtime types, snapshot Zod
  schemas, test helpers — and the PR fixes the domain one. **List all of them** (show the `grep`), and
  ask whether construction can be funnelled through a single point.
- **Exhaustiveness that the compiler enforces.** `as const satisfies readonly T[]` **type-checks on a
  subset**: add a kind on the server and the frontend list keeps compiling, silently short. A
  `Record<Union, …>` does not. Whenever you see an array plus `satisfies` for options, orderings or
  label maps, ask: **if the server adds one tomorrow, does this fail to compile?**

Worth most where money, permissions, tenancy, or irreversible operations are involved: an invariant
the type guarantees cannot be forgotten at the eleventh call site somebody adds next quarter.

### 8b. Where the rule lives, and whether it behaves the same on both sides

- **Aggregate invariants written into Repository, QueryService or UseCase.** The test is one question:
  **if another persistence path is added tomorrow, does this check have to be copied?** If yes, it
  belongs in the domain. A rule enforced at the call site is a rule the next call site forgets.
- **The same state handled two different ways.** Look for asymmetry between the read path and the write
  path — "the query silently skips the malformed row, the aggregate rejects it". It sounds prudent
  ("degrade the view, protect the screen; keep the aggregate strict") and to the user it reads as
  **"it is not on the screen, yet saving 500s"**. Where an asymmetry exists, ask whether it is coherent
  *from outside*, and whether the reason given is really a fact about the implementation (the
  QueryService did not return a `Result`, so it could not fail) dressed up as intent.
- **Does the error fit what happened?** An unreachable branch returning a message about a different
  situation ("the fixed value is empty" used for "no default was supplied") is a lie the next reader
  believes. And the status code: **corrupted stored data is not 4xx** — the caller cannot fix their
  request.
- **A predicate that carries only half of the invariant.** The rule is "the latest submission **and**
  the caller's own step". Extracted as a helper answering the version half alone, it reads *complete* at
  the call site — its name does not say what is missing — so the position half gets checked in some
  callers and forgotten in others. Both halves of the fix matter: give the predicate the whole question
  (**one `Result` carrying the reason**, not two booleans every caller must remember to AND), and put it
  on the aggregate whose fields it reads. **A helper that opens two fields of one aggregate to decide
  something about that aggregate is that aggregate's method**; the fields merely being reachable from
  outside is not an argument for deciding it outside.
- **Which failure wins is domain knowledge too.** When two guards can reject the same request, their
  order decides the message the user sees. Ordered independently in each handler, the same state answers
  differently depending on the route taken to it, and correcting one leaves the other. Ask whether the
  precedence exists in exactly one place.
- **The rule, and its `WHERE` clause.** A status predicate written once as `isSubmitted()` on the entity
  and once as SQL for the list screen is two rules that agree today. The tell is an **exclusion list**:
  `status NOT IN ('Recalled')`, or `!== 'Recalled'`, **admits every status added after it** — the next
  state joins the set silently, and a screen starts showing rows it was never meant to. The inclusion
  form excludes new states instead, which fails visibly and cheaply. So: which direction is safe here,
  and can both sides be derived from one place? Where a screen genuinely needs a different set, that
  divergence belongs in the code as a **named exception with its reason** — the returned-items tab needs
  the status the aggregate excludes — not as two expressions that happen to differ.

### 9. Dependencies, licensing, and supply chain

Measured as part of *analysis checks* — 9.1% of missed bugs — and the paper's own example is a license
header missing from a new file, which broke the build rather than being caught in review.

- **A new or bumped dependency**: is it maintained, and does its **license** permit this use? Copyleft
  arriving in a proprietary service, or a licence change on a version bump, is a legal problem that no
  test fails on. Name the licence in the finding.
- **Does the file need a licence or copyright header** by this repository's own convention? A missing one
  is caught by a linter, if there is one — and if there is not, it is caught in production tooling.
- **Version pinning**: does the change widen a range such that a future install differs from this one?
- **Hallucinated or squatted packages** — cross-check that the package exists and is the one meant. See
  `llm-authored-code.md`; roughly 20% of agent-authored samples reference packages that do not exist.

### 10. Test coverage and verifiability

- Tests for new entities, commands, and handlers; boundary values; failure paths. Integration tests
  for database writes, external integrations, and anything spanning a transaction.
- **Is each test necessary, and is it at the right level?** The same rule asserted at contract, entity
  and sql level is one rule paid for three times — and a rule that is a pure function should not be
  reachable only through a sql test. The reason is not tidiness: **a rule pinned only by a slow sql or
  end-to-end test is a rule whose test is deleted the next time the suite is too slow** — and the guard
  deciding whether a button is enabled is a pure function of the aggregate, so pin it at that level.
  Conversely, **an invariant the change moved into the type leaves a test behind that now either fails to
  compile or asserts nothing.** Test names and comments describing a state the types no longer permit
  ("sending the value alongside is normalised") are stale by construction.
- Do the tests exercise the production read and DI paths (no shortcut assertions, no swallowed
  `Result`s)?
- **Where a path has silent, irreversible side effects** (see `silent-failure-patterns.md`), is the
  *chain that goes silent when broken* pinned by one integration test — not just the happy path in
  isolation? The failure to detect is "unit tests green, chain unverified".
