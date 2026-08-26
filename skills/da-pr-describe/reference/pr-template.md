# PR body template and writing rules

## What goes in, and what stays out

A description exists so the change can be understood by reading it. Write **observable changes**
only; leave internal matters to the diff.

**Include** — anything that changes a reader's experience, a contract, or a result:

- What became possible, and what stopped being possible
- Changes to API responses, error conditions, validation, or output (CSV, ETL, …)
- Changes to default behaviour, classification, or transformation rules

**Leave out** — the diff covers these, and writing them adds noise:

- Internal refactoring, renaming, splitting functions or classes (when behaviour is unchanged)
- Seed data, test fixtures, local-only presets
- Unifying display strings, comments, documentation formatting
- Stating that something is unchanged

> The test: if you deleted this line, would a reviewer misunderstand the change? If not, leave it out.
> When an internal change *is* the crux of the review, give it one line under Notes — not the table.

---

## Template

Use only the sections you need. **Never emit an empty section — delete it.** 全体像 and 検討した代案
are the two that are usually absent, and both are deleted rather than left with a placeholder.

````markdown
## 全体像

<!-- 図が描ける変更のときだけ —— 変わったフロー、順序、触れる層、状態遷移。
     描かなかったなら**節ごと消す**（`検討した代案` と同じ）。埋めるために描かない。
     Artifact が使える環境（Claude）では Artifact。1枚に収まって読みやすいので。
     **投稿前に共有を済ませること** —— 既定で非公開で、未共有のリンクはレビュアには 404 です。 -->

📋 **変更サマリ** → <artifact URL>

<!-- Artifact が無い環境（Cursor など）ではこちら。GitHub が本文内で描画する。 -->

```mermaid
flowchart LR
```

## 概要

<!-- 何が変わり、なぜやるのか。2〜4文。ここだけで趣旨が伝わること。
     「なぜ」は解こうとしている問題 —— 障害・要望・目標。実装の説明ではない。
     チケット・issue・設計ドキュメント・ベンチマークの数字はここにリンクで置く。 -->

## 変わること

<!-- 観測できる変化を1行1件。「領域」は読み手の語彙で（画面名・API・CSV出力・運用手順など）、
     クラス名や関数名を主語にしない。変更前・変更後は短く、値や挙動そのもの。新規追加なら変更前は「—」。
     3列とも短い値であること。文を書きたくなったら、それは概要か補足の内容。 -->

<!-- dotagents:change-table | 領域 | 変更前 | 変更後 | -->
| 領域 | 変更前 | 変更後 |
|---|---|---|
| | | |

## 検討した代案

<!-- 実際に却下した対案がある時だけ。無ければ節ごと消す。
     1行1件で「対案 —— 却下した根拠（測った数字・壊れる条件）」。無理に埋めない。 -->

## テスト

<!-- 自動テストと CI が実際に何を担保しているか。「テストを追加した」ではなく検証された挙動を書く。 -->
- [x]

## 手動確認（ローカル / 実環境）

<!-- 自動テストで覆えず、マージ前に人が確かめるもの。テストの節とは混ぜない。
     未確認は `- [ ]` のまま。1行につき「何を確認するか」と「飛ばすと何が壊れるか」。無ければ省く。 -->
- [ ]

## 補足（任意）

<!-- レビュアが引っかかるであろう意図的な設計判断と、次フェーズに送った既知の欠落だけ。最小限に。 -->
````

**節見出しはリポジトリの言語に合わせます。** 上は日本語のリポジトリ向けの既定形です。マージ済み PR が英語のリポジトリでは英語の見出しを使ってください —— `全体像`=At a glance / `概要`=Overview / `変わること`=What changes / `検討した代案`=Alternatives considered / `テスト`=Tests / `手動確認`=Manual verification / `補足`=Notes。**表の構造と3列は言語によらず同じです。**


---

## Writing rules

**Title.** A **complete sentence written as an order** — "Fix the CSV export dropping the last row",
not "CSV export fix". Google's own rule, and the reason is that the first line has to stand alone in a
list of a hundred others. Around 50 characters. No `feat:`-style prefix (follow the repository's own
ticket-tag convention). Match the language the repository's other PR titles use.

**概要 (Overview).** Two to four sentences carrying **both what changes and why**, and it is the part
that must land alone, because some reviewers read nothing else. **The why is the problem** — the
incident, the request, the goal — not a restatement of the change and not a benefit. **Links go here**:
the ticket, the issue, the design document, the benchmark numbers. Google's guidance names exactly those
as body content, and this template had nowhere to put them, so they ended up crammed into a table cell
or left out.

**変わること (What changes) — the table. Three columns, all of them short values.**

| Column | What goes in it | The failure it prevents |
|---|---|---|
| **領域** | The area **in the reader's vocabulary** — a screen, an API, a CSV export, an operational procedure. **Never a class, function, or flag.** | "added `LoadOutboundUsecase`" instead of "customer-facing CSV export" |
| **変更前** | The current behaviour or value, short. **`—` for a pure addition.** | — |
| **変更後** | What it becomes. Short — a value, a state, an observable behaviour. | A row describing the implementation rather than the effect. A change that cannot be written as a before/after pair is usually internal churn that does not belong in the table at all. |

**なぜ was the fourth column and it has been taken out of the table.** Not because the *why* matters
less — Google's guidance makes it the more important of the two things a description must carry — but
because it was **the only column holding sentences**, and a column of sentences is what makes the other
three unreadable.

**This is a property of the medium, not a matter of taste.** GitHub's own table documentation offers
only *inline* formatting inside a cell — links, inline code, text styling. No list, no fenced block, no
paragraph break; a literal `|` has to be escaped. So a cell that must carry "the problem, plus the
alternative that was rejected, plus the number that ruled it out" has exactly one shape available to it:
one long run-on sentence. Meanwhile the table has no column widths, so that sentence sets the width of
the row and squeezes 領域/変更前/変更後 — the three columns that were doing the scannable work.

**Where it went**: the problem into 概要, the rejected alternative into 検討した代案 — which is a
section, so it can hold a list, a number, a link. And it is **omitted entirely when nothing was
rejected**, which is the outcome this file already learned to want the hard way (see below).

**検討した代案 (Alternatives considered).** Only when a real alternative was rejected. One line each:
the alternative, then the evidence that ruled it out — a measured number, the condition it breaks
under, the case it would hide. **Delete the whole section when there is none.** Do not restate the
problem here to fill it.

**変更前 / 変更後 was a separate "Before → After" section once.** It was merged because a change to
existing behaviour appeared twice — one row describing it in prose, another contrasting the two values —
and the prose row was always the weaker of the two. As columns they are shorter than the prose they
replace, and they enforce the observable-change rule for free: **`LoadOutboundUsecase を追加` cannot be
written as a before/after pair**, which is the signal that it was never a reader-facing change.

**なぜ was two columns once — 変更目的 and この形にした理由 — and it was merged after the split failed
on its own first use. Read this as the reason 検討した代案 is a section that gets deleted, rather than
a column that sits there empty.** The concepts are genuinely different (*why do this* versus *why like this*), but
the second only has content when a real alternative was rejected with evidence, which is the minority of
rows. Where no alternative existed the writer had nothing to put there, so the purpose got restated in
different words — in the PR that introduced the split, two of five rows kept the columns distinct and
three did not, and one of those three had quietly become a *what I did* column. **A required column that
is usually empty trains restatement, which is the failure it was added to prevent.** Keep both facts; do
not give the second one a column it cannot fill.

**Every cell is a value or a short phrase — never a sentence.** If a cell wants to be a sentence, its
content belongs in 概要, 検討した代案, or 補足. That rule used to be "one or two sentences", which was a
rule fighting the medium: the table cannot hold a sentence well, so the fix was to stop putting them
there rather than to keep asking for shorter ones.

Bad row: `| typecheck | 遅い | 速い |`
Good row: `| CI の typecheck | `--checkers 2` | `--singleThreaded` に固定 |`

The bad row fails twice: 領域 is a flag rather than something a reader experiences, and 変更前/変更後
give no values, so nothing in the row is verifiable.

The good row's *why* is not in it, and that is the point. It reads, in 概要: 「CI 待ちがレビューの律速に
なっていた」。And in 検討した代案: 「`--checkers 2` —— このコードベースでは約2.4倍遅く、メモリも約40%多い（実測）」。
**Both are longer and more precise than the cell they came from**, because a section can hold a number
and a link and a cell cannot.

**Nothing from the "leave out" list goes in the table.** When an internal change *is* the crux of the
review, it gets one line under 補足, not a row.

**テスト (Tests).** What automated tests and CI actually cover, one line each, describing the *behaviour
verified* rather than "added tests". Done is `- [x]`; outstanding is `- [ ]`. CI coverage as
`- [x] CI: typecheck / lint / unit`. **Anything that cannot be verified automatically goes in the
next section, not here.**

**手動確認 (Manual verification).** Checkboxes for what must be confirmed by hand or in a real environment
before merge. Typical: real external API response shapes, real integration behaviour, migrations
against production-like data, a typecheck the agent is not permitted to run, end-to-end against a
real tenant, environment-dependent configuration and permissions. Each line states **what to check
and why it matters — what breaks if it is skipped**. This section is a hold on merging until it is
filled in. Omit it entirely when automated tests genuinely suffice. Where useful, add one line to
補足 about how the item could become an automated test later, so this list shrinks over time.

**補足 (Notes).** Only deliberate design decisions and known deferred gaps. No listing of implementation,
nothing self-evident. Omit if empty.

---

## 全体像 (At a glance)

**It is a section now, and the heading is the test.** It used to be an unheaded block at the top, which
made it the one part of the body with no name — so "is there one?" had no place to be answered, and the
guidance about skipping it lived only in this file. As a section it behaves like 検討した代案: **present
when there is something, deleted when there is not**, and that is one fewer rule to remember because the
two now work the same way.

**It stays above 概要.** A reader who opens a PR to decide whether to review it now sees the shape first;
the argument for putting it after the prose is real, and it is written down at the end of this section.

**Artifact where the environment has one; Mermaid where it does not.** An Artifact is one page — it can
group by area, put before and after side by side, and carry a diagram at a readable size, which is more
legible than a fence in a description. Read `artifact-design` before publishing one.

| Environment | What goes in 全体像 |
|---|---|
| **Artifact tool available (Claude)** | Publish one page, share it, link the URL |
| **No Artifact tool (Cursor, or anywhere else)** | A ` ```mermaid ` fence inline — GitHub renders it for every reader with no account and no hosting |

### Sharing is a step, not a footnote

**An Artifact is private by default, and the tool cannot share it.** Publishing returns a URL to a page
only the author can open; making it visible to teammates is an action the **human** takes in the artifact
view. There is no share action in the tool, so nothing in this skill can do it for you.

**So a PR body with an unshared Artifact link is a PR body whose visual is a 404 for every reviewer** —
and it fails quietly, because the author *can* open it. That is the whole reason this is a numbered step
rather than a line of advice:

1. Publish the page.
2. **Stop and tell the user to share it**, naming the URL. Wait.
3. Only then put the link in the body.

**If the user does not want to share it, do not link it** — use a Mermaid fence instead. A link the
reviewer cannot open is worse than no visual, because it reads as content that exists.

**Never fabricate a URL**, and never link an Artifact whose sharing has not been confirmed.

**Neither is mandatory, and a bad one is worse than none.** The visual earns its place only when the
change *has a shape*: a flow that changed, a sequence, which layers are touched, a state machine. A flag
value changing has no shape — the table already says everything, and a diagram of it is noise. **Do not
draw something to fill the slot.**

**Do not restate the 変わること table.** The body already carries the scannable view; a page or diagram
that repeats it is one more thing for the reviewer to open and dismiss. Overlap with 概要 is fine.

**Markdown tables and Mermaid fences belong in a PR body; raw HTML does not** — GitHub strips much of it
and what survives renders badly. That is the whole distinction: the table and the diagram go inline, an
HTML page goes behind a link.

For a set of PRs spanning several repositories, give each PR its own visual and link each to its own.

**The open question, recorded rather than settled**: a diagram of an unfamiliar system is hard to read
before the two sentences that say what it is for, which argues for 概要 first. The counter is that the
visual exists to be seen *before* deciding to read anything, and a reader who has to scroll past prose to
reach it has lost that. **Kept above 概要 because that is what the skill has always done and nothing has
gone wrong with it** — change it on evidence from a real PR, not on this paragraph.
