# One-page Canvas review summary

Create one Canvas after all layer reports and the cross-layer synthesis are complete. It is the
primary review artifact in Cursor, designed so a reader can understand both the change and the
review result without reconstructing them from prose.

Include:

- the PR / diff title and review scope;
- the change summary, showing the before → after data or control flow;
- the layer classification and consolidated finding counts;
- all ⛔ / 🔴 / 🟡 findings and pulled-up 🧭 / 👤 items, each with key locations and an actionable
  next decision;
- cross-layer impact, or an explicit statement that there is none when only one layer changed;
- what was inspected and what remains unverified.

Use visual hierarchy to make the flow and highest-priority risks scannable. The Canvas does not
replace textual evidence: include locations, reachability, and suggested review comments in the
text report where applicable.

The final user-facing response must be concise and link to the Canvas. If Canvas support is
unavailable, say so and provide the same one-page structure in Markdown; do not silently omit it.
