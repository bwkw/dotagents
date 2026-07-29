# Silent, irreversible failure patterns

**Read this in both phases — finding and verifying.** These are patterns that look clean in a diff and
become silent production incidents. They are cross-cutting: none of them belong to a single
perspective cluster, and each one has been missed by a review that was otherwise careful.

When one applies, raise it **even if the cause sits outside the diff**. The diff is where you started
looking, not the boundary of what you may report.

---

## 1. Global default × local compensation

The change adds behaviour to something **shared** — a task or job catalog, a base class, common
config, a database default, a seed — and its correctness depends on **callers compensating**:
embedding a context value, setting a flag, running a preprocessing step.

The failure: the PR's one path compensates correctly. The other four do not.

What to do, concretely:

1. `grep` for **every** path that can invoke or modify the same aggregate or pattern — other
   controllers, use cases, batch jobs, event handlers, admin tooling, tests that stand in for
   production paths.
2. Check each one against the compensation, individually. Do not stop at the path the PR touched.
3. Then ask what *forces* the invariant. A guard, a database constraint, or an architecture test that
   fails when a new caller forgets? **If nothing does, that is a finding** → **🧭**, or **🔴** when you
   can read a path to real harm.

The last step is the one that gets skipped. "All current callers happen to be correct" is a snapshot,
not an invariant; the fifth caller is written by someone who never read this PR.

## 2. Fail-open or fail-closed — which way does the silence fall?

For every default value, evaluation error, missing context, or absent key, establish the **direction
of the fallback**.

If an irreversible, legally mandated, externally visible, or billable action falls toward **silently
skipping, auto-completing, or no-op**, ask whether that direction is correct. Usually it is not.

> **Failing silently is more harmful than failing loudly** — and often more harmful than visible
> over-execution. A loud failure gets fixed the same day. A silent skip is discovered by an auditor,
> a customer, or a regulator.

Raise the direction itself as the finding, not just the missing branch. → **🧭 / 🔴**

## 3. SSOT declared once, hardcoded twice

A mapping table, constant, or correspondence declared authoritative in one place — a design document,
a domain constant, an enum — gets **re-hardcoded elsewhere**: a seed, another layer, a different
entry path, a test fixture, an infrastructure template.

Look for the place where the two are cross-checked against each other. **If no test compares them,
they will drift, and the drift is silent.** Report it. → **🟡**

This one is cheap to find and almost never looked for: search for the literal values, not the
identifier.

## 4. Seed and config read live, against deploy ordering

If a seed, catalog, or config is read **fresh on each access rather than snapshotted at startup**,
changing it opens a rollout window: the new data is live while the old code is still running on some
instances.

Establish three things:

- **When** the change takes effect — automatically on merge, on deploy, or by a manual step.
- **Relative to** the application rollout — before, during, or after.
- Whether a hard ordering gate exists, or the safe order is only a convention someone remembers.

If you cannot determine the execution timing from the repository, that is `👤 needs human` — not a
clean pass. Deploy ordering is exactly the kind of thing that is obvious to whoever wrote it and
invisible to everyone else.

## 5. Observability of silent success

If an irreversible action can be **conditionally skipped or auto-completed**, ask what signal exists
afterwards. A row in a table is passive evidence: it tells you the state, but only if someone thinks
to look. An **active signal** — a log line, a metric, an alert — is what makes the skip detectable.

If there is none, the failure mode is undetectable, which is a finding. → **🟡**

> **Do not casually propose a resident sweep or a cron job as the fix.** That trades a detection gap
> for a new always-on component with its own failure modes. Prefer one passive monitor plus a
> documented manual recovery. Suggest the standing process only when the recovery genuinely cannot
> wait for a human.

---

## Applying these

One pass, across the clusters, in both phases:

| Phase | What this file is for |
|---|---|
| **find** | A checklist to run *in addition to* your assigned perspective. If your cluster is "tests", pattern 1 still applies to what you are reading. |
| **verify** | The place to look for what the find pass missed. A clean cluster report is a claim; these five are where that claim is usually wrong. |

Findings from here follow the same discipline as everything else — see
[`finding-discipline.md`](finding-discipline.md). Being a known pattern does not exempt a finding
from needing a traced path and a confidence score.
