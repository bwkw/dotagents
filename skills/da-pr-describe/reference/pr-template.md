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

```markdown
📋 **変更サマリ（ビジュアル）** → <artifact URL>

> 差分を開く前に、変わることを一目で。共有を有効にしないと開けない場合があります。

## 概要

<!-- 2〜3文。何が変わり、なぜやるのか。ここだけで趣旨が伝わること。 -->

## 変わること

<!-- 観測できる変化を1行1件。「領域」は読み手の語彙で（画面名・API・CSV出力・運用手順など）、
     クラス名や関数名を主語にしない。各セルは1文。理由が1文に収まらないときは1行だけ補足へ。 -->

| 領域 | 何が変わるか | 変更目的 | この形にした理由 |
|---|---|---|---|
| | | | |

## 変更前 → 変更後（任意）

<!-- 既存の挙動が変わる項目だけ。対比が誤読を防ぐ場合に限る。
     新規追加（変更前が空になるもの）と内部変更は対象外。該当が無ければ節ごと省く。 -->

| 項目 | 変更前 | 変更後 |
|---|---|---|
| | | |

## テスト

<!-- 自動テストと CI が実際に何を担保しているか。「テストを追加した」ではなく検証された挙動を書く。 -->
- [x]

## 手動確認（ローカル / 実環境）

<!-- 自動テストで覆えず、マージ前に人が確かめるもの。テストの節とは混ぜない。
     未確認は `- [ ]` のまま。1行につき「何を確認するか」と「飛ばすと何が壊れるか」。無ければ省く。 -->
- [ ]

## 補足（任意）

<!-- レビュアが引っかかるであろう意図的な設計判断と、次フェーズに送った既知の欠落だけ。最小限に。 -->
```

**節見出しはリポジトリの言語に合わせます。** 上は日本語のリポジトリ向けの既定形です。マージ済み PR が英語のリポジトリでは英語の見出しを使ってください —— `概要`=Overview / `変わること`=What changes / `変更前 → 変更後`=Before → After / `テスト`=Tests / `手動確認`=Manual verification / `補足`=Notes。**表の構造と列は言語によらず同じです。**


---

## Writing rules

**Title.** Concise, around 50 characters. No `feat:`-style prefix (follow the repository's own
ticket-tag convention). Match the language the repository's other PR titles use.

**概要 (Overview).** Two or three sentences: what changes, and why. The point must land from
this alone, because it is the only part some reviewers read.

**変わること (What changes) — the table.** One row per observable change. Four columns, and each
earns its place:

| Column | What goes in it | The failure it prevents |
|---|---|---|
| **領域** | The area **in the reader's vocabulary** — a screen, an API, a CSV export, an operational procedure. **Never a class, function, or flag.** | "added `LoadOutboundUsecase`" instead of "customer-facing CSV export" |
| **何が変わるか** | The observable difference. What became possible, what stopped being possible. | A row that describes the implementation rather than the effect |
| **変更目的** | **Why this is being done at all** — the problem, the request, the incident, the goal. | A change nobody can tell was worth making |
| **この形にした理由** | **Why this shape and not the obvious alternative** — the constraint, measurement, or failure mode that ruled the alternative out. | The reviewer opening the diff to ask 「なぜこの形？」 |

**The last two columns are different questions and both are required.** 変更目的 is *why do this*;
この形にした理由 is *why like this*. A row with only the first reads as an unjustified implementation
choice; a row with only the second reads as a solution to an unstated problem.

**Keep every cell to one sentence.** Four columns of prose renders cramped on GitHub. When a reason
genuinely needs more than a sentence, put the short version in the cell and one line in 補足.

Bad row: | typecheck | `--singleThreaded` を指定 | 高速化 | 速いから |
Good row: | CI の typecheck | 実行時間が約2.4倍短縮 | CI 待ちがレビューの律速になっていた | `--checkers 2` はこのコードベースでは約2.4倍遅くメモリも約40%多かったため、`--singleThreaded` に固定 |

The bad row fails three ways: the 領域 is a flag rather than something a reader experiences, 変更目的
restates the change instead of the problem, and この形にした理由 gives no measurement — so nothing
rules out the alternative.

**Nothing from the "leave out" list goes in the table.** When an internal change *is* the crux of the
review, it gets one line under 補足, not a row.

**変更前 → 変更後 (Before → After).** Only where **existing behaviour changes** and the contrast prevents a
misunderstanding — for example, "records with an empty unique key were counted as successful rows →
they are now excluded as errors". New additions and internal changes do not belong in a table; the
bullets are enough. Optional; omit the section when nothing qualifies.

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

## Visual summary

Only when the Artifact tool is available in the current environment.

- **The at-a-glance view is the body's 変わること table, not the artifact.** Markdown tables are the
  thing to put in a PR body; **raw HTML is not** — GitHub strips much of it and what survives renders
  badly. That distinction is the whole rule: a Markdown table in the body, yes; an HTML table in the
  body, never.
- So an artifact now has to earn its place by doing what Markdown cannot — grouping by area,
  before/after side by side, a diagram. **A page that restates the table is one more link to open and
  dismiss.** Read the `artifact-design` skill first. Same selection rules as the body.
- **Artifacts are private by default.** Add one line telling the reviewer that sharing may need to be
  enabled, so they are not met with a dead link.
- Some overlap with 概要 is fine. Overlap with the 変わること table is not — that is the duplication
  this section exists to avoid now that the body carries the scannable view.
- For a set of PRs spanning several repositories, publish one artifact per PR and link each to its
  own.
