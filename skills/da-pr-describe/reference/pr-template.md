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

Use only the sections you need. Never emit an empty section. The visual summary link goes first
when there is one.

````markdown
<!-- 冒頭のビジュアル。変更に「形」がある場合だけ。Artifact が使える環境なら1つ目、
     使えない環境（Cursor など）なら2つ目。どちらも無理に作らない。 -->

📋 **変更サマリ（ビジュアル）** → <artifact URL>

> 差分を開く前に、変わることを一目で。共有を有効にしないと開けない場合があります。

```mermaid
%% Artifact が無い環境ではこちら。GitHub が本文内で描画する。
flowchart LR
```

## 概要

<!-- 2〜3文。何が変わり、なぜやるのか。ここだけで趣旨が伝わること。 -->

## 変わること

<!-- 観測できる変化を1行1件。「領域」は読み手の語彙で（画面名・API・CSV出力・運用手順など）、
     クラス名や関数名を主語にしない。変更前・変更後は短く、値や挙動そのもの。新規追加なら変更前は「—」。
     「なぜ」は解こうとしている問題。対案を却下した場合だけ、同じセルにその根拠も書く。
     収まらないときは1行だけ補足へ。 -->

| 領域 | 変更前 | 変更後 | なぜ |
|---|---|---|---|
| | | | |

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

**節見出しはリポジトリの言語に合わせます。** 上は日本語のリポジトリ向けの既定形です。マージ済み PR が英語のリポジトリでは英語の見出しを使ってください —— `概要`=Overview / `変わること`=What changes / `変更前 → 変更後`=Before → After / `テスト`=Tests / `手動確認`=Manual verification / `補足`=Notes。**表の構造と列は言語によらず同じです。**


---

## Writing rules

**Title.** Concise, around 50 characters. No `feat:`-style prefix (follow the repository's own
ticket-tag convention). Match the language the repository's other PR titles use.

**概要 (Overview).** Two or three sentences: what changes, and why. The point must land from
this alone, because it is the only part some reviewers read.

**変わること (What changes) — the table.** One row per observable change. Four columns:

| Column | What goes in it | The failure it prevents |
|---|---|---|
| **領域** | The area **in the reader's vocabulary** — a screen, an API, a CSV export, an operational procedure. **Never a class, function, or flag.** | "added `LoadOutboundUsecase`" instead of "customer-facing CSV export" |
| **変更前** | The current behaviour or value, short. **`—` for a pure addition.** | — |
| **変更後** | What it becomes. Short — a value, a state, an observable behaviour. | A row describing the implementation rather than the effect. A change that cannot be written as a before/after pair is usually internal churn that does not belong in the table at all. |
| **なぜ** | **The problem being solved** — the incident, the request, the goal. **And, only when an obvious alternative was rejected, the evidence that ruled it out**, in the same cell. | A change nobody can tell was worth making, and a shape the reviewer opens the diff to question |

**変更前 / 変更後 was a separate "Before → After" section once.** It was merged because a change to
existing behaviour appeared twice — one row describing it in prose, another contrasting the two values —
and the prose row was always the weaker of the two. As columns they are shorter than the prose they
replace, and they enforce the observable-change rule for free: **`LoadOutboundUsecase を追加` cannot be
written as a before/after pair**, which is the signal that it was never a reader-facing change.

**なぜ was two columns once — 変更目的 and この形にした理由 — and it was merged after the split failed
on its own first use.** The concepts are genuinely different (*why do this* versus *why like this*), but
the second only has content when a real alternative was rejected with evidence, which is the minority of
rows. Where no alternative existed the writer had nothing to put there, so the purpose got restated in
different words — in the PR that introduced the split, two of five rows kept the columns distinct and
three did not, and one of those three had quietly become a *what I did* column. **A required column that
is usually empty trains restatement, which is the failure it was added to prevent.** Keep both facts; do
not give the second one a column it cannot fill.

**Keep 変更前 / 変更後 to a value or a short phrase, and なぜ to one or two sentences.** When a reason
genuinely needs more, put the short version in the cell and one line in 補足.

Bad row: | typecheck | 遅い | 速い | 高速化 |
Good row: | CI の typecheck | `--checkers 2` | `--singleThreaded` に固定 | CI 待ちがレビューの律速になっていた。`--checkers 2` はこのコードベースでは約2.4倍遅くメモリも約40%多かった |

The bad row fails three ways: 領域 is a flag rather than something a reader experiences, 変更前/変更後
give no values so nothing is verifiable, and なぜ names a benefit rather than the problem — so nothing
rules out the alternative.

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

## 冒頭のビジュアル

**Two paths, and both produce something.** This used to be Artifact-only, so a PR written from Cursor
silently got no visual at all. Pick by what the environment actually has, and **say which path you
took** — never fabricate a URL.

| Environment | What goes at the top |
|---|---|
| **Artifact tool available (Claude)** | Publish one HTML page and link the URL. It can group by area, place before/after side by side, or carry a diagram — things a Markdown table cannot. Read the `artifact-design` skill first. **Artifacts are private by default**, so add the one line telling the reviewer sharing may need enabling. |
| **No Artifact tool (Cursor, or anywhere else)** | A **Mermaid block inline in the body.** GitHub renders ```mermaid fences natively in PR descriptions, so this needs no tool and no hosting, and it looks the same to every reviewer. |

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
