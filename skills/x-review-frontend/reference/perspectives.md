# Frontend layer — what to trace, and the perspective clusters

The two layer-specific parts of the review: **Step 2** (what to trace) and **Step 5** (the perspective
clusters to fan out across). Posture, the seven steps, and the finding discipline come from the skill
that sent you here.

If you arrived here without having read `finding-discipline.md` and `review-process.md`, **read those
first** — this file assumes both. `silent-failure-patterns.md` applies on top of whichever cluster you
are assigned.

**Read-only. Never modify code.**

---

## Step 2 — what to trace in this layer

1. **Changed units**: components, hooks, stores, routes, API clients and generated types, i18n
   resources, config.
2. **Bidirectional usage trace** (`grep`):
   - A change to shared UI, a hook, a store, or a util requires **naming every screen and route that
     uses it**. One component change reaches many screens.
   - The API contract this consumes (generated types) against what the backend actually provides.
3. **Related screens and flows**: name **every** route, screen, and user flow affected, and include
   them in the Step 5 reading.
4. **Adjacent assets**: route definitions, shared UI, state management, API client, i18n, forms.

Note on the discipline: in this layer, the "unverified safety claim" that matters most is
authorization. **Reading only the client is never enough** — the guard is the server-side check.
Either cite the `file:line` of that check, or mark it unverified.

---

## Step 2b — the conformance sweep in this layer

`review-process.md` Step 2b is the whole-diff, mechanical pass that **no diff size excuses**. Report a
verdict per row, citing the rule and a `file:line`.

| Row | Frontend form |
|---|---|
| **Placement** | Route-colocated files versus shared ones — a hook two routes will need does not belong under one of them, and a component placed in `shared/` that only one screen uses is the same mistake mirrored. Check against this repository's own convention, not a general instinct. |
| **Dependency direction** | `grep` the diff's imports: a route reaching into another route's private directory; a shared component importing feature-specific state; a presentational component importing the API client directly. |
| **Irreversible surfaces** | **Public routes and their parameters** — a renamed path breaks bookmarks and inbound links, and no test fails. **Persisted client state** — a changed shape in `localStorage`, IndexedDB or a URL-encoded filter that existing users already hold, with no migration and no tolerant read. |
| **Authorization boundary** | Every new screen, action and route guard. **Hidden UI is not a control**: for each, cite the server-side check by `file:line` or mark it unverified. A finding here is a backend finding — say that. |
| **New entry points** | Every new mutation, upload, download or navigation that leaves the app: does it handle the failure path, and is the disabled/empty state reachable and explicable to the user? |

**One row is specific to this layer and easy to skip: a value the API returns that the UI never
reads.** `grep` each new response field across the route's directory. A field the backend computes,
stores and returns with no consumer is either a missing screen or a dead column, and it is invisible
from either side alone — observed as a count of excluded records that nothing displayed.

## Perspective clusters

### 0. Design soundness and the question one level up ★system-wide

Required even for a small diff. When collapsing the fan-out, this must still land in one subagent.

- Is this screen, state, or flow design **correct at all**? Is it needed, is the boundary right, is
  there a simpler alternative?
- **Verify the foundation by reading it.** Open at least once the shared UI, hook, or store this
  depends on, and the authorization premise — **especially the server-side check** — and confirm
  with `file:line` that the safety premise holds. Cannot confirm → 👤. Suspicious → 🧭.
- **Propagation risk**: is this adding the Nth instance of a dangerous pattern — authorization by
  hiding UI, a persisted-schema change with no fallback, a form with no double-submit guard? → 🧭
- Naming, responsibility, over- and under-engineering: component decomposition, where state lives.

### 1. Intent and semantic correctness ★always covered

**The largest category of bugs that survive review, by a wide margin.** The component renders, and
renders something other than what was asked for.

- **Against the stated intent.** Read the spec, ticket, or design first. Does the change produce what it
  describes? **If there is no stated intent, that is the finding** → 👤.
- **Error and empty states — the most missed sub-cause here too.** What renders while loading, on a
  failed request, on an empty list, on a partial response? A swallowed fetch error that leaves the
  previous data on screen is worse than an error message.
- **Missing cases.** Zero items, one item, very many; the longest realistic string; a null optional
  field; a user without the permission the component assumes.
- **Wrong condition or wrong value displayed.** An inverted boolean, a wrong class or variant, the wrong
  field of the right object, a stale value from a closure. Read the JSX against the intended output.
- **Incomplete change.** One usage of a component updated and its other call sites not; a prop added and
  a default missing; a new variant added and the styles for it not.

### 2. Breaking changes and irreversibility ★highest priority

- Changing, removing, or redirecting a **public URL or route** — broken bookmarks, inbound links,
  shared links, SEO.
- **Persisted schema changes** in `localStorage`, `IndexedDB`, or cookies that are incompatible with
  what existing users already have stored — is there a migration or a fallback?
- Consumer-side contract breakage: generated types drifting from the real API, a field made required
  with no handling.
- Destructive actions — deletion, irreversible updates, submissions — do they have confirmation or
  an undo window, and a double-submit guard?

> Calibration: a route change you can put a redirect on, and a `localStorage` schema change with a
> fallback, are **not** irreversible. Reserve `irreversible=true` for state that is genuinely
> unrecoverable.

### 3. Security, authorization bypass, secret exposure ★focus

- XSS: `dangerouslySetInnerHTML`, `v-html`, direct DOM insertion, unsanitised input.
- **Authorization bypass**: is access enforced only by hiding UI? Is the server-side check actually
  there?
- Secrets reaching the client (private keys, full tokens, PII); where tokens and sessions are
  stored; CSRF; open redirect; `rel="noopener"` on external links; origin validation on `postMessage`
  and iframes.
- **CSP.** Does the change need `unsafe-inline` or `unsafe-eval` to work? That is a finding, not a
  configuration detail — prefer a nonce or a hash. **A new frontend dependency or embedded widget means
  the policy needs re-reading**: an added allowlisted origin is a permanent hole and nobody goes back to
  remove it. Count the allowlisted domains before and after.
- **Third-party scripts are client-side supply chain.** An analytics tag, a chat widget, or a tag
  manager runs with full page privileges and **can change after your review without a deploy**. Per
  script added: what can it reach, is it pinned by integrity hash, and does it see PII it should not?
  The dependency checks in `llm-authored-code.md` apply to client packages too.

### 4. State and data consistency

- Cache invalidation (query invalidation and key design); rollback consistency for optimistic
  updates; guarding against discarding unsaved form input; multiple submission and race conditions;
  how a global state change ripples to other screens.

**Screen state held as a product of flags.** `isLoading` plus `data | null` plus `error | null` is this
layer's most common instance of the shape in `llm-authored-code.md` — eight combinations in reach where
four have meanings, and every render path then carries a branch for one of the surplus four. The tell in
a diff is **two branches rendering the same empty state**: one for "loaded and empty", one for "not
loading, no error, no data", which is not a state the screen has. Ask whether the states are a union with
the data attached to the variant that owns it, and whether the render is exhaustive over it rather than a
chain of early returns.

### 5. Accessibility — against WCAG 2.2

**2.2 is the current standard** and supersedes 2.1; it adds nine criteria aimed at low vision,
cognitive and motor disability, and touch devices. Check against it rather than against a general sense
of "accessible".

- Keyboard operation and focus management; `aria-*` and roles; label association; focus trapping in
  modals; image alt text.
- **Contrast (1.4.3 text, 1.4.11 non-text)** — the most commonly failed criterion anywhere. New
  brand colours, disabled states, placeholder text, and icons on coloured backgrounds are where it
  breaks. A hex pair is checkable in seconds; do it rather than guessing.
- **Accessible Authentication (3.3.8)** — a cognitive function test cannot be the *only* way to
  authenticate. Concretely: **paste must work in password and one-time-code fields**, and autofill must
  not be blocked. Disabling paste "for security" is now a conformance failure, and it is a common
  regression because it looks like hardening.
- **Focus not obscured (2.4.11)** — a sticky header, cookie banner, or floating action button covering
  the focused element. Easy to introduce with a layout change, invisible to a mouse user.
- **Target size (2.5.8)** — interactive targets at least 24×24 CSS pixels, or adequately spaced.
- Respect `prefers-reduced-motion` on any new animation or transition.

### 6. Performance, bundle, UX

Measure against the current Core Web Vitals thresholds rather than "feels fast": **LCP ≤ 2.5s,
INP ≤ 200ms, CLS ≤ 0.1**.

- **INP is the one that fails.** It replaced FID, and roughly 43% of sites miss the 200ms threshold. It
  is almost always **JavaScript occupying the main thread while the user is interacting** — a long task
  triggered by a click, an expensive synchronous handler, a large re-render on keystroke. Look for work
  that should be chunked, deferred, or moved off the interaction path.
- Unnecessary re-renders; heavy synchronous work; wrong `useEffect` dependency arrays (infinite
  loops); fetch waterfalls and N+1.
- **CLS**: images and embeds without reserved dimensions, late-injected banners, web fonts swapping
  metrics.
- Bundle size from a heavy new dependency — and whether it is tree-shakeable and actually needed on the
  critical path.

### 7. Robustness, observability, platform compatibility

- **Error boundaries**; complete handling of loading, error, and empty states; client error
  reporting and analytics — **and whether PII is being put into that telemetry**; browser and device
  compatibility; responsive and mobile behaviour; feature flags and staged release.

### 8. i18n and type/contract consistency


- Hardcoded strings; whether all required locales are present; agreement with generated API types;
  type safety eroded by `any` or unnecessary `as`.

**Knowledge that belongs to the backend, re-stated here.** Which attributes are eligible, which kinds
exist, what the ordering is — if the frontend enumerates it a second time, the two lists diverge the
first time the backend adds one. **The server should send it and the frontend should follow.** When you
see such a list in frontend code, ask what makes it impossible for it to disagree with the server.

When the re-stated rule is a **conjunction**, check that every term survived the copy. An enablement
check that keeps "this step is mine" and drops "this is the latest version" renders a button that looks
actionable on stale data, and the missing term surfaces only as an error *after* the click. The safe
shape is the server deciding and sending the single answer, with the reason attached for the disabled
case.

**Exhaustiveness the compiler enforces.** `as const satisfies readonly T[]` **type-checks on a subset**:
the backend adds a kind, this list stays short, and nothing fails to compile. `Record<Union, …>` does
not have that hole. For any options list, ordering or label map, ask: **if the server adds one tomorrow,
does this file fail to build?**

**Vocabulary matching the backend's, and nothing pointing at the old shape.** Types, constants and
translation keys named after fields that were renamed or removed send the next reader looking for a
shape that no longer exists. Search the diff's removed identifiers across the frontend too.

**Dependency direction.** Importing a hook only to reach the type it happens to return is the shape to
question — the type should live where it can be imported on its own.

**And the ceiling on tightening.** This is the layer where type-level cleverness actually appears —
conditional types, deep generics, a mapped type encoding the rule. Stronger is not automatically
better: the four conditions a type has to meet to be worth having are in `llm-authored-code.md` under
over-abstraction. Where a named union would carry the same rule, prefer it, and say so when a diff
chooses the computed form.

### 9. Readability and extensibility — what the next change pays

Not style. `finding-discipline.md` suppresses taste and **explicitly does not suppress this**: the test
is whether you can **name the next change and what it has to touch**. These land in 🧭, where a finding's
value does not depend on being right.

- **State that is derived but stored.** A value kept in `useState` that is a function of props or of
  server state — every future write path has to remember to update it too.
- **A prop that only exists to be threaded.** Three components deep to reach one leaf; the fourth screen
  that needs it will thread it again.
- **Exhaustiveness the compiler does not check.** `as const satisfies readonly T[]` for options, labels
  or orderings type-checks on a *subset*: the server adds a case tomorrow and this list stays silently
  short. `Record<Union, …>` fails to compile instead.
- **The comment that is the only enforcement.** A docstring enumerating the callers, a "always call X
  first", a "keep these in sync" — true the day it is written, silently false when the next entry point
  appears, and its author never reads it. Ask what *forces* it instead.
- **The thing that will be copied next.** This change is the second instance of a shape; the third is
  written by someone who reads only this one. Is the shape worth propagating, and does anything make the
  third copy consistent?
