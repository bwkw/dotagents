# The decisions sweep — what nobody has settled yet

Runs at Step 4b, **on the someone-else's-PR path only**, after the layer reviews and before the
overview page. Its output is the page's final section, and the subset needing the author's answer
becomes review-body items.

**What is undecided is often worth more to the author than what is wrong.** A finding says "fix this".
This says "nobody has decided this yet", and those are the items that surface after release, when the
cost of deciding has gone up.

---

## Two sources, and the second is where the surprises are

### 1. Mechanical — over the whole diff

```bash
# every changed file, production and test
for f in $(git diff --name-only "$BASE" "$HEAD"); do
  git show "$HEAD:$f" 2>/dev/null | grep -nE 'TODO|FIXME|要確認|要仕様確認|暫定|未決|仮置き' | sed "s|^|$f:|"
done
```

Adjust the markers to the repository's own vocabulary — that list is what a Japanese codebase uses;
another will use `XXX`, `HACK`, `pending spec`. **Read the surrounding lines, not just the hit**: a
`TODO` inside a test fixture and a `TODO` on a constant that ships in the output are different items.

This finds what the author already knows about. It is cheap and it is not the point.

### 2. From the review itself — the ones with no marker

These have no TODO because nobody realised they were decisions. Each shape below was found this way in
a real review, and **none of them appeared in the PR description**:

| Shape | Question it hides |
|---|---|
| **A constant with a citation-shaped comment and no citation** | Its sibling in the same file carries a "verify against the source" TODO and this one does not. Why is one checked and the other not? |
| **A field the backend computes, stores and returns that no consumer reads** | Is it meant to be shown and the UI is missing, or is it not meant to be shown and the column is dead? Both are decisions; the code answers neither. |
| **A supported-range that expires** | A table valid for two fiscal years, a certificate, a schema version. **When it lapses, what happens, and who is holding the date?** |
| **A retention that nothing enforces** | Code comments claiming a lifecycle policy cleans up, where the infrastructure has none. The artefact people download, as separate from the intermediates. |
| **A naming or format convention the receiving system may own** | Filenames inside an archive, a header row, an encoding. Cheap now, a full regeneration later. |
| **A value that does not reach what was already produced** | A provisional constant "fixed later by changing one line" — true for new output, false for everything already shipped with the provisional value. |

## Write the consequence, not the marker

The TODO restated is worth nothing; the author wrote it. What they do not have is **what changes
depending on the answer**.

> ✗ 「`ver` 属性が暫定値です」
> ✓ 「`ver` を後から直しても、それまでに出した ZIP には遡及しません。年調ソフトが `ver` を見て弾く仕様なら、確定前に本番で出した分は全部出し直しになります。」

The second is the same fact with the decision attached, and it is what makes someone act this week
rather than next quarter.

## Grouping

Group by **what the answer changes**, not by file:

- **出力そのものが変わる** — highest cost to defer; anything already produced becomes wrong
- **誰が使えて誰が使えないか** — a tenant or user class silently excluded
- **失敗したときの扱い** — all-or-nothing versus partial, and what the operator does next
- **画面に出す情報** — computed but never surfaced
- **データの保持** — what is kept, for how long, and whether anything enforces it
- **リリース運用** — order, follow-up work, what expires

Then say which to settle first, and why — usually the group whose answer invalidates work already done.
