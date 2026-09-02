# The one-page overview

Read at Step 5. **The container depends on the host; the six sections do not.**

## Pick the container

| Host | Container | How |
|---|---|---|
| **Claude Code** | Artifact | Write the HTML to a file, then publish it with the `Artifact` tool. Load the `artifact-design` skill first — it is required before writing any artifact. |
| **Cursor** | Canvas | Use the `canvas` skill and follow it exactly. Exactly one Canvas. |
| **Neither available** | An HTML file | Write it to disk and give the path. **Say which container was unavailable and why** — a missing page silently is the failure this row exists to stop. |

The response links the page either way. **Do not build one on the own-work path unless asked** — offer
it in one line instead.

## The page is about the change, not about the review

This is the section that gets it wrong when it goes wrong. The instinct is to render the finding table
with better typography, and a finding table is what the comment drafts are for.

**What a reader wants from this page is the thing no PR description gave them: what this feature
actually does, and how it sits against what already exists.** Findings are the reviewer's output;
orientation is the reader's need, and only one of the two is missing everywhere else.

Measured on a real run: the reviewer produced both, and the reader's follow-up questions were all about
the orientation half.

## The six sections

1. **何ができるようになったか** — before → after, in the user's terms rather than the system's. A
   before/after pair of cards beats a paragraph. Name the concrete artefact the user ends up with.
2. **既存との関係** — the sibling feature this resembles, as a difference table: what is shared, what
   diverges, and **what changed in the existing thing**. A change that touches an existing feature at
   one point should say so at that level of precision.
3. **処理フロー** — a Mermaid diagram. Artifacts and Canvas both render ```mermaid fences and
   `<pre class="mermaid">` natively, so no library is loaded. Nodes are what the reader recognises —
   screens, endpoints, tables, queues, stages — never file paths or class names.
4. **コードの置きどころ** — where the new code went, by layer, and **why there**. This is where the
   Step 2b conformance sweep surfaces for a human: "the adapter is defined in the owning module, per
   the repository's own rule" is worth stating, and is invisible in a diff.
5. **リポジトリ間の依存とリリース順序** — for a change spanning repositories: what depends on what,
   the safe order, and **what breaks in each wrong order**. A three-row table.
6. **決まっていないこと** — the Step 4b sweep, grouped by what the answer changes.

## Plus two honesty rows, and they are not optional

The layer reports do not reach the terminal on this path, so **their 🔎 and 🔬 have nowhere else to
live.** Without them a short finding list reads as a thorough review.

- **🔎 読んだもの / 仮定したもの** — how much of the diff was actually opened ("本番 65 ファイル中 30"),
  what was never opened by name, which clusters got a token pass, and what was not run (typecheck,
  tests, `terraform plan`). State plainly that a clean result means "not detected at this depth".
- **🔬 除外したもの** — how many findings were raised and refuted, how many fell below the confidence
  threshold, and one line each for the notable refutations. **A review that filtered nothing has not
  been calibrated**; say so if the count is zero.

`pr-comments.md` selects the PR subset on the premise that everything else "is still in the report".
**On this path the page is that report** for the excluded items — one line each is enough, and it is
what keeps the selection auditable.

## Design

The `artifact-design` skill governs. Two things specific to this page:

- **It is a document, not a dashboard.** Typographic hierarchy and a real type scale carry it. Resist
  the severity-chip treatment; the severities are in the drafts.
- **Tables for anything N×M**, and let wide tables scroll inside their own container rather than making
  the page scroll sideways.

Name it after the feature, not after the review: `年末調整 国税庁XMLエクスポート`, not
`レビュー結果`. It sits in a gallery beside other pages and has to be findable by what it is about.
