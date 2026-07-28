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

### 1. Breaking changes and irreversibility ★highest priority

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

### 2. Security, authorization bypass, secret exposure ★focus

- XSS: `dangerouslySetInnerHTML`, `v-html`, direct DOM insertion, unsanitised input.
- **Authorization bypass**: is access enforced only by hiding UI? Is the server-side check actually
  there?
- Secrets reaching the client (private keys, full tokens, PII); where tokens and sessions are
  stored; CSRF; open redirect; `rel="noopener"` on external links; origin validation on `postMessage`
  and iframes.

### 3. State and data consistency

- Cache invalidation (query invalidation and key design); rollback consistency for optimistic
  updates; guarding against discarding unsaved form input; multiple submission and race conditions;
  how a global state change ripples to other screens.

### 4. Accessibility

- Keyboard operation and focus management; `aria-*` and roles; label association; contrast; focus
  trapping in modals; image alt text.

### 5. Performance, bundle, UX

- Unnecessary re-renders; heavy synchronous work; wrong `useEffect` dependency arrays (infinite
  loops); fetch waterfalls and N+1; bundle size from a heavy new dependency; layout shift.

### 6. Robustness, observability, compatibility

- **Error boundaries**; complete handling of loading, error, and empty states; client error
  reporting and analytics — **and whether PII is being put into that telemetry**; browser and device
  compatibility; responsive and mobile behaviour; feature flags and staged release.

### 7. i18n and type/contract consistency

- Hardcoded strings; whether all required locales are present; agreement with generated API types;
  type safety eroded by `any` or unnecessary `as`.
