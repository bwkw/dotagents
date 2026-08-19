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
