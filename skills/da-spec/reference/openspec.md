# openspec — 形と、validator が実際に検査すること

`spec_system.kind` が `openspec` の時だけ読む。**`openspec/config.yaml` がこのファイルに優先する**。このファイルは形式を、あちらは*このリポジトリ*の埋め方の規則を書いている。

## 形

```
openspec/
  config.yaml                        # schema: spec-driven, plus the repository's own rules
  specs/<capability>/spec.md         # deployed truth. Current behaviour, not proposals
  changes/<change-id>/
    proposal.md                      # Why / What Changes / Impact
    design.md                        # how, and where responsibility sits
    tasks.md                         # ordered checklist, with paths and expected results
    specs/<capability>/spec.md       # the DELTA against specs/<capability>/spec.md
    .openspec.yaml
```

**`specs/` は出荷したもの、`changes/<id>/specs/` は変わるもの**。提案を `specs/` に書くと、まだ存在しないものをデプロイ済みの事実として書くことになり、後からそれを推測と示すものがツリーに何も残らない。

**change id は結果のスラッグで、兄弟に揃える**。`add-*` など、リポジトリがすでに使う動詞。新しい流儀を作る前に既存の id を読む。

## delta の見出し

change の spec ファイルは次の見出しだけを使う。

```markdown
## ADDED Requirements
## MODIFIED Requirements
## REMOVED Requirements
## RENAMED Requirements
```

**`MODIFIED` は要件ブロック全体（見出しとすべてのシナリオ）を再掲する**。部分更新は拒否される。アーカイブした change は何年後も単独で読めなければならず、差分の差分は読めないからである。

**デプロイ済み spec がある能力に `ADDED` はたいてい誤りで、`MODIFIED` である**。見出しを選ぶ前に `specs/<capability>/spec.md` を確かめる。最も多い validator の失敗で、書いている間は正しく見える。

## 要件とシナリオ

- 規範語彙は **SHALL / MUST / MUST NOT** で、その能力の spec がすでに使う語に揃える。システムが強制することに「should」を混ぜない。
- **すべての要件に少なくとも 1 つの `#### Scenario:` を付ける**。箇条は `GIVEN` / `WHEN` / `THEN` / `AND`。シナリオの無い要件は誰もテストできない文で、validator もそう言う。
- シナリオは**状態と入力、次に結果**を書く。「THEN 動く」はシナリオではない。

## `validate --strict` が見つけるもの、見つけられないもの

**見つけるのは形**。見出しの欠落、シナリオの無い要件、4 種以外の delta 見出し、全体でない `MODIFIED` ブロック、存在しない能力への参照。

**見つけられないもの**。その要件が*正しい*要件か、既存 spec に対して `ADDED` を `MODIFIED` にすべきだったか、シナリオが失敗経路を覆うか、兄弟の能力の spec と矛盾しないか。

よって validator の緑は**成果物の形式が正しい**という意味でしかない。報告ではそのとおりに書く。「validate --strict が通った」を「設計が健全」と読ませない。`/da-design-review` がこのスキルの代わりではなく後に走るのはそのためである。

## 既存の change を更新する

- **既存の delta の、属する見出しの下に足す**。2 つ目の `## ADDED Requirements` ブロックを追加せず、既存のものにまとめる。
- 新しい要件が、この change ですでに足した要件を修正するなら、**そのブロックを直す**。1 つの change に同じ要件が 2 版あると、validator も読み手も解決できない。
- `<change-id>/tasks.md` のチェックリストは順序つき。新しいタスクは末尾ではなく依存関係が決める位置に置く。
- 作成後だけでなく、編集のたびに validator を再実行する。
