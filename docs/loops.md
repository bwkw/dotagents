# ループを回す —— 駆動系の使い方

設計 → 実装 → 反復レビュー → PR（landing ごとに1本、stack）を、規模に応じて自動で回します。

**駆動系（`scripts/loop.sh`）は新しいエージェントではありません。人間が打つことを打つだけです。**
`claude -p "/da-verify"` はユーザ入力であって、モデルの自動発火ではない —— だから
`disable-model-invocation` の付いたスキル（`da-pr-describe`）も、そのフィールドを外さずに届きます。
あれが止めるのは*モデル*で、人ではありません。

**その帰結は先に書いておきます。読まない打ち手は comprehension debt の機械です。**
台帳（`ledger.jsonl`）は、transcript の代わりに人間が読むものとして存在します。台帳を読まないなら、
このループを回す意味はありません。

---

## 打つのは1つ

```bash
scripts/loop.sh "やりたいことを1文で"
```

**同じコマンドを打つたびに1歩進みます。** 次がどの段かも、計画ファイルのパスも覚えなくて良い
（`docs/plans/` から自分で見つけます）。

| いまの状態 | すること |
|---|---|
| 未測定 | 測って tier を出し、そのまま次へ |
| tier **S** | 端まで回す |
| tier **M・L**、計画なし | **「あなたの手番です」と言って止まる**（exit 0 —— 引き継ぎは失敗ではない） |
| tier **M・L**、計画が commit 済み | 計画を自分で見つけて端まで回す |
| 計画が2つ以上 | **推測せず並べて止まる** |

**駆動系は対話レーンを打ちません。** `/grilling` はあなたを面接するので、**相手が居ない面接は
虚空に質問を出すだけ**です。だから状態は「進める・引き継ぐ・回す」の3つで、
**引き継ぎは exit 0** —— 進めるところまで進んだ結果なので。

個別のサブコマンドも残っています（`size` / `design` / `run` / `report` / `status`）。
**普段打つ必要はありません** —— `report` を除いて。数字は読まないと意味がないので。

引数なしの `scripts/loop.sh` が一覧を印字します。

---

## 全体の形 —— 2つのレーン

**混ぜてはいけないものが2つあります。** 最初の版はこれを1つの表に書いていて、それが設計を曇らせていました。

```
対話レーン（人間 + エージェント）          無人レーン（駆動系）
──────────────────────────────         ────────────────────────────
loop.sh size "やりたいこと"        →     tier を決める（bash の算術）
loop.sh design                     →     何を打つか / 何が検証済みか
   ↓ S ならこのレーンは空
/grill-me → /grilling                    ← 要件を詰める（面接）
/research                                ← 外の世界（必要なとき）
/writing-plans                           ← spec。各ステップに「TDD」を明記
/documentation-and-adrs                  ← 決定を残す（したなら）
/da-design-review                        ← 🧱 Landing plan（会話の中）
人間が plan を commit                    ← これが承認の印
                                   →     loop.sh run <plan>
                                           /using-git-worktrees   隔離
                                           /da-verify             ゲートを arm
                                           /executing-plans       （S は /test-driven-development）
                                           /systematic-debugging  周2以降
                                           /da-review-all
                                           /find-bugs             risk surface のときだけ
                                           /da-fix-plan           両方の所見を受ける
                                           /receiving-code-review
                                           gh stack submit --open
                                           /da-pr-describe
人間: merge
```

**境界の規則は1つです: 駆動系は対話レーンを順序付けません。** できないからです ——
`test-non-interactive.sh` が対話経路の不在を検査しているので、`design` は**何も聞けません**。
対話レーンでの駆動系の仕事は**検査と記録だけ**です。

**打つスキルは11本**（`size` の `/da-investigate` を含めて12箇所）。使わないものと理由:

| 使わない | 理由 |
|---|---|
| `/subagent-driven-development` | **インストールはしています**（`writing-plans` が REQUIRED と宣言）が打ちません。あれ自身の判断グラフが「Stay in this session? **no** → executing-plans」と書いていて、駆動系は各周が別プロセスです。加えて「**Always specify the model explicitly**」は不変条件10の逆で、台帳・修正ループ・最終レビューが二重になります |
| `/simplify` `/security-review` | 前者は品質専用でバグ探しではなく、後者は `/find-bugs` の risk surface 条件と役割が重なります。**重複した2本目より、別の作りの2本目** |
| `/da-skills-audit` `/skill-scanner` | ツールキットの保守で、開発サイクルの段ではありません |

---

## `loop.sh design` —— ウィザードではなく、検査と記録

**何も聞きません。** 設計フェーズは全段が対話なので「どこまでやった?」と聞きたくなる場所ですが、
`test-non-interactive.sh` が対話経路の不在を検査しているので、聞いたらスイートが落ちます。
やるのは3つです:

1. tier に応じた**順序を印字**する（S: 無し / M: 2段 / L: 5段）
2. **検査できる成果物を検査**する
3. **検査できない段はそう言う**

| 段 | 成果物 | 検査 |
|---|---|---|
| `/writing-plans` | `docs/superpowers/plans/YYYY-MM-DD-*.md` | ✅ **強い。** `# … Implementation Plan` / `**Goal:**` / `## Global Constraints` / `- [ ]` が揃っているかまで見ます —— **パスだけ見ると、空ファイルがゲートを通ります** |
| `/documentation-and-adrs` | `docs/decisions/ADR-*.md` ほか | ⚠️ 弱い（パスが慣習依存） |
| 🧱 Landing plan | 人間が写した commit 済みファイル | ✅ 強い（`run` の前提条件） |
| `/research` | エージェントが選んだパス | ❌ **無い** |
| `/grill-me` → `/grilling` | 無し | ❌ **無い** |
| `/da-design-review` | **無し（会話のみ）** | ❌ **無い** |

**`da-design-review` はファイルを1つも書きません** —— 本文に「never writes code and never edits the
plan」とあります。つまり 🧱 Landing plan は**会話の中にしか無く、人間が写して commit する**必要が
あります。以前ここは「commit しろ」と書いて、**誰が書き出すのかを書いていませんでした。**

**3段が検査不能であることを、緑に見せません。** 6個のチェックのうち3個しか検証していないのに
6個の緑を出すチェックリストは、チェックリストが無いより悪いので。

---

## 段（S / M / L）—— 設計フェーズは規模で分岐する

**「自動か手動か」ではなく「人間がどれだけ深く入るか」の分岐です。** 上2段に人は必ず居ます:

- `/grill-me` は質問攻めの面接。**相手が居ない面接は面接ではない。**
- `da-design-review` の Step 1 は「Restate the plan … **Show this to the user.**」——
  読み違えた計画のレビューは、自信のある無関係な所見を生む。それを一番安く捕まえる場所がそこ。

| 段 | 判定（OR。1つ当たれば上の段） | 設計フェーズ | 人間の位置 |
|---|---|---|---|
| **S** | ≤5 files・1 layer・one-way 0・risk surface 0・unconfirmed 0 | **無し。** landing 1本として直行 | ループの**上**。台帳を読む |
| **M** | ≤15 files ／ ≤2 layers ／ **risk surface** ／ **unconfirmed** | `/da-design-review` を対話で1周 | 承認1回。Landing plan を commit |
| **L** | >15 files ／ 3 layers ／ **one-way door** | `/grill-me` → `/writing-plans` → `/da-design-review` を対話で | ループの**中** |

**risk surface** は新設の語彙ではなく `skills/_shared/verification.md` の 6b と同じもの ——
money / billing / 外部・行政提出 / authorization / PII / データ移行 / 並行性。

### 軸が2つあることを、1つの表に潰していた

最初の規則は `risk surface` と `unconfirmed` も単独で L を出していました。**その結果、段が崩壊します。**
実際のリポジトリでは backend の変更はほぼ必ず authorization に触り、`da-investigate` は確認できなかった
ことを名指しするのが仕事なので必ず何かを挙げる。**全部 L で、無人で端まで回るものが1つも無い。**
入力が全部同じクラスに落ちる分類器は、分類していません。

**規模**（どれだけ process が要るか）と**不可逆性**（人間が見なければならないか）は別の軸です。潰した
結果、2つとも間違った向きに効いていました:

- **`risk surface` は二重に課金されていました。** これは既に2本目のレビュア `/find-bugs` を買っています
  （`loop.sh` の review 段は risk_surfaces が非ゼロのときだけ打つ）。同じ計測に、対話の設計フェーズと
  いう別の予算も払わせていた。**いまは M の床**です。
- **`unconfirmed` は「この計測は信頼できない」という意味です。** それは無人で回すなという理由になりますが、
  **変更が広い／不可逆だという証拠ではありません** —— L が人間を呼ぶのはそっちのためです。**いまは M の床。**
- **`one_way` は引き続き L を出します。** ここは改定の対象外。取り返しのつかない一歩は、誰かが見ないまま
  出てはいけないものそのものです。

### `unconfirmed` の定義を直した、という以前の記述は**持ちませんでした**

この節はかつて「同じ依頼を測り直して **L → S、21 → 0**。直したのは閾値ではなく入力です」で終わって
いました。**その後の実測で、同じ形の変更（1ファイルの docs 修正）が `unconfirmed 9` を返して再び L に
なりました。** 定義を絞る修正（「外していたら上の件数が示すよりこの変更を大きく・危険にするもの」、
小さな変更では空リストが正しいと明記）は入っていて、それでも 9 件出た。

**つまり閾値も間違っていたのであって、定義だけの問題ではなかった。** そして 9 件の中身が理由を教えて
います —— それらは変更の規模についてではなく、**依頼文の主張**についてでした（「台帳に pr が1回も無い」
「テスト件数を更新する」）。フィールドが2つのものを混ぜたままだったので、`unverified_claims` に分けました:

| フィールド | 意味 | 段に影響するか |
|---|---|---|
| `unconfirmed` | 外していたら、この**変更**が件数より大きく・危険になるもの | **する**（M の床） |
| `unverified_claims` | **依頼文**が主張していて、確認できなかったこと | **しない**。印字と台帳だけ |

**依頼文に未確認の主張が9件ある1行の編集は、それでも1行の編集です。** 後者は依頼文を直す材料で、
段を上げる理由ではありません。

S に設計フェーズが無い根拠は `README.md` の常設規則そのまま ——
**「差分を1文で説明できるなら計画は飛ばす」**。S の gate はこのリポジトリの gating checks です。

### 判定はモデルではなく bash がします

`size` は `/da-investigate` に測らせ、**表の適用は bash の算術**です。

レビューのファンアウトは「Scale the fan-out to the change」と書いてあった期間、**毎回最大値になって
いました。検査できるものが何も無かったからです。** 段をモデルに選ばせるのは、名前を変えた同じ失敗です。

**そのファンアウト自体は、その後まるごと廃止されました**（下記「レビューは subagent を1つも使わない」）。
教訓の方は残ります —— *検査できない指示は最大値に解決する*。段が bash の算術なのは、そのためです。

**上振れは1条件で決まり、下振れはありません。** 駆動系が段を下げることはない。

---

## `run` が始まらない条件

止まったときは、どれに当たったかが標準エラーに出ます。

| 条件 | なぜ |
|---|---|
| 作業ツリーが汚れている | 自分の変更と人の変更を区別できないループは、何を commit したか言えない |
| デフォルトブランチに居る | push して PR を開くので |
| **profile が一致しない** | gating check が無い＝検証者が居ない。しかも `gate.sh verify` は**その場合 `ok:true` を返す**ので、`ok` だけを信じると「何も検査していない」を緑と読む |
| `size` の記録が無い | 段が未決のまま無人で走らせないため。`run` を直接打って front door を回避できない |
| S 以外で Landing plan が無い / commit されていない / commit 後に改変されている | **commit が承認の印です。** 承認フラグは作りません —— フラグは読まずに打てるものだから |
| **前回が VERDICT で終わっている** | 下記 |

### VERDICT が残っているときは始めません

`gate.sh arm` は既存の `VERDICT` を `VERDICT.prev` に**移して** attempt 予算を作り直します。
人間が新しいセッションを始めるときは正しい挙動ですが、**無人の駆動系が黙ってそれをやると、
「前の作業は検証されていない」と言うために存在する唯一の記録を、読む前に消します。**

なので `run` は arm より**先に** `gave_up` を見て、立っていたら始めません。ファイルはそのまま残ります。

> これは実装中にテストが見つけた欠陥です。最初の版は arm してから見ていたので、証拠が消えていました。

---

## 1 landing の中身

```
（run 開始時）/using-git-worktrees  ← 作業を隔離。既に linked worktree なら作りません
（run 開始時）/da-verify        ← ゲートを arm するのはこれ。駆動系は gate.sh arm を叩きません
implement   周1  tier M・L: /executing-plans <plan>   ← commit 済みの計画があるので
                 tier S:    /test-driven-development  ← 実行する計画が無いので
            周2以降 /systematic-debugging   ← 赤いままなら「書く」から「原因を探す」へ切替
            毎周のあと gate.sh verify --json を読む（state-free の probe）
            緑になったら commit（変更パスを名指し。git add -A は使わない）
review      /da-review-all
            + /find-bugs   ← risk surface があるときだけ。2本目、意図的に別の作り
triage      /da-fix-plan（両方の所見の全文を受け、件数を構造化出力で返す）
            needs_decision > 0  → 即停止
            fix_now > 0         → /receiving-code-review で1回だけ適用 → 再検証 → もう1周だけ review
            fix_now == 0        → 次へ
pr          gh stack push → gh stack submit --auto --open → /da-pr-describe <番号>
```

### `/executing-plans` は TDD を保証しません —— プロンプトが保証します

あのスキルの Step 2 は「plan のステップに従え」で、**自前の実装ループを持ちません。**
`Reference skills when plan says to` とあるとおり、**TDD が発火するのは plan の各ステップが
そう書いているときだけ**です。だから駆動系のプロンプトが「各ステップで TDD」と明示し、
`/writing-plans` の出力にも同じことを入れます。**それがこの経路の唯一の担保です。**

そして `/executing-plans` は `superpowers:finishing-a-development-branch` を REQUIRED SUB-SKILL と
宣言します。入れてあるので解決しますが、**あれは「ブランチをどう統合するか」を人間に問う段**で、
無人レーンでは答える人が居ません。**そこで止まるのは正しい停止**として扱います。

### 赤いゲートに TDD を積み直さない

`da-verify` 自身の Next にこう書いてあります —— **「同じチェックが2回連続で落ちたら、パッチを当てるのを
やめろ」**。最初の版はそれを無視して `/test-driven-development` を最大6回打ち直していました。
**2つのスキルは交換可能ではありません**: 一方は意図からコードを書き、もう一方は
**根本原因を持つまで修正案を出すことを拒否します**。周2以降は後者です。

同じ理由で fix ラウンドは `/receiving-code-review` を通します。`da-fix-plan` が
**何を直す価値があるか**を既に決めているので、この段が決めるのは**その処方が実際に正しいか**です。
書いてあるから適用する、はあのスキルが止めるために存在する失敗です。

### 隔離も `git worktree add` を叩かずスキルを打つ

`using-git-worktrees` が持っているのは判断だけではなく、**1行の呼び出しには無い5つ**です:

- **submodule ガード** —— `--git-dir != --git-common-dir` は**submodule の中でも真**なので、
  素朴な比較は submodule を「既に隔離済み」と誤判定します
- ディレクトリ選択の優先順位（`.worktrees` > `worktrees` > 既定）
- **`git check-ignore` の検証** —— ignore されていない worktree ディレクトリは、
  **ツリーごとリポジトリに commit されます**
- クリーンなベースラインの確認
- sandbox が拒否したときのフォールバック

**駆動系が持つのは「何が起きたかを知ること」だけ**で、それは返答ではなく
`git worktree list` から読みます —— `/da-verify` を打ってから `gate.sh status --json` を読むのと同じ分担。

**作られなかったときは、その場で作業して、そう言います。** スキャンダルではなく、
スキルが sandbox 拒否と consent 拒否のときに認めている経路です。**黙って続けるのが問題**なので。

そしてこの変更で挙動が1つ良くなりました: **`main` の上でコマンドを打っても問題ではなくなりました** ——
作業は自分のブランチに移るので。**その場で作業する場合の `main` は今も拒否します。**

### 台帳の repo キーは worktree ではなく共有 git dir

`size` は今立っているチェックアウトで取り、`run` は linked worktree で走ります。
**toplevel をキーにすると、`run` が `size` の記録した tier を見つけられません。**
gate が同じ問題を同じやり方で解いているので合わせました ——
**リポジトリの同一性は共有 git dir、作業ツリーの状態は worktree ごと。**
`worktree` フィールドは別に残るので、行はどこで起きたかを言えます。

### 段はスキルを「打つ」。下の道具に手を伸ばさない

**駆動系が自分でやるのは、スキルが持っていない仕事だけです** —— 段の判定の算術、台帳、採点器の指紋、
`gh stack` の層の作成。**スキルが持っている段は、スキルを打ちます。**

区別が効いた実例が1件あります。最初の版は `gate.sh arm` を直接叩いていて、
`AGENTS.md` の不変条件2（「`gate.sh arm` を走らせるのは `da-verify` だけ」）を
**「唯一の*スキル*」に書き換えて自分の実装を通しました。順序が逆です。**
そして書き換えは理由も落としていました —— arm は単独の操作ではなく、
**証拠テーブル・`agent_may_run: false` のチェックの人間への委譲・profile が無いときの停止**と
束になっています。直接叩く駆動系は arm だけ得て、そのどれも得ません。

`gate.sh verify --json` を毎周読むのは重複ではありません —— `da-verify` 自身の Step 3 が
「これを使え、何度でも走らせて良い」と書いている probe です。**規則は1箇所、決定の出どころも1箇所。**

**各周は `claude -p` の別プロセス、つまり毎回まっさらな context です。** これはこのリポジトリ自身の
規則（「計画と実装の間で `/clear`」「同じ問題で2回失敗したらセッションを捨てる」）を、印字するのを
やめて実際に強制することになります。周を渡るのは**台帳とディスクの plan だけ**。

### レビューは2周で切ります。3周目は correctness ではなく合意を買っている

唯一の厳密な公開実験（23 model×harness / 29 run、[cost to a merged
feature](https://blog.insight-services-apac.dev/2026/07/06/cost-to-a-merged-feature)）の結果:

- **LLM レビューゲートは、38個の単体テストのうち 12〜20 個が落ちるコードを承認した。**
- **レビュー周回を増やすと「承認される確率」だけが上がり、客観的な正しさは上がらなかった。**
- 総コストの **97%** がレビューゲート側だったケースがある（実装側は 3%）。
- 「実装側が自己レビューしてからゲートへ」が外部サイクルを 3→1 に減らした。

だから **correctness を決めるのは `gate.sh verify` だけ**で、`da-review-all` の所見は
**人間が読むための材料**です。上限を超えた所見は台帳に残して人間に返します。

**tier S は1周です**（`REVIEW_ROUNDS_S`）。**1レビュー周は1スキルではありません** ——
`/da-review-all` + `/da-fix-plan` の triage で、初めて実走した landing の実測は
**$5.64（50ターン）+ $2.08（20ターン）**、レビューされた実装のほうは **$1.30** でした。
2周は **約$15の天井**で、それを**設計フェーズを飛ばすほど小さいと判定した変更**に掛けています。

**これは深さを削ったのではなく、最悪ケースに蓋をしただけです。** その landing でレビューは
**既に最下段まで自分で絞っていました** —— 11行1ファイルなので `skills/_shared/review-process.md`
の予算表どおり「inline、find サブエージェント0」。**削る深さは残っていませんでした。**
50ターンは11個の主張をコードに突き合わせるのに使われ、**そのうち1つが実際に誤りでした。**
そこを削るのは、安い誤答を買うことです。

`da-fix-plan` の5バケットがそのまま停止条件になります（あのスキル自身が
「Decline の無いループは出口の無いループ」と書いています）:

| バケット | 駆動系 |
|---|---|
| Fix now / Fix now smaller | 1周だけ適用して再検証 |
| Follow-up / Decline | ブロックしない。件数だけ台帳へ |
| **Needs a decision** | **即停止。残り予算に関係なく。** 直すかどうかは、どう直すかより前 |

---

## 採点器には触らせません

`karpathy/autoresearch` は `train.py` だけを書き込み可能にし、採点器を**エージェントの手の届かない
ところ**に置きました。それが「最適化ループ」と「報酬ハックループ」を分ける構造です。

**このリポジトリでは採点器が同じ checkout の中にあります**（`profiles/dotagents.json` が gate の中身）。
だから駆動系は毎周のあと変更パスを見て、以下に触っていたら **landing を止めます**:

```
profiles/   hooks/   scripts/gate.sh   scripts/check.sh
scripts/verify-skills.sh   scripts/loop.sh   scripts/test-*.sh   <landing plan>
```

何も revert しません。見て、人間が決めます。

> **このリポジトリでのループの合法な作業領域は `skills/` `docs/` `agents/` `templates/` と
> 上位の Markdown です。** 機構の大半が `scripts/` と `hooks/` にあるので、そこは対象外 ——
> gate を変えたいなら手で変えてください。実際の制限なので明記しています。

### この守りは **dotagents 以外では効きません**

**守っているパスは dotagents 自身のものだけ**で、他のリポジトリでは1つも一致しません。つまり
そこでは**落ちているテストを編集・削除してゲートを正当に緑にできます。**

以前ここと `loop.sh` のヘッダは「テストスイートを触ると landing を中止する」と、この限定なしに
書いていました。**このリポジトリ以外では偽です。** そして
**ガードレールについての偽の主張は、ガードレールが無いことより悪い** —— 無ければ人は用心しますが、
あると書いてあれば用心をやめます。リポジトリごとに採点器を宣言できる仕組みは
[fix plan](fix-plans/2026-08-11-loop-driver.md) の Follow-up に置いてあります。

**他のリポジトリに向けるなら、それが済むまでは採点器の防御が無いものとして扱ってください。**

---

## 台帳と `report`

置き場は `~/.claude/.dotagents-loop/ledger.jsonl`（`DOTAGENTS_LOOP_DIR` で変えられます）。
**リポジトリを問わず1本、各行が自分の `repo` と `branch` を持ちます** —— `verdicts.log` と同じ形。
**絶対に trim しません**: `trace.log` は 200 行で自己 trim するので、そこにしか無い記録は通常運用で
消えます。gate はそれで一度刺されて `verdicts.log` を分けました。

1周 = 1行:

```jsonc
{ "ts": "…", "repo": "…", "branch": "work", "phase": "review", "landing": 2, "round": 1,
  "gate": { "ok": false, "check": "unit", "kind": "red" },
  "fix_now": 1, "needs_decision": 0, "decline": 4,
  "cost_usd": 0.41, "turns": 11, "exit": 0, "spent_usd": 1.83,
  "scorer_touched": [], "outcome": "held", "halt_reason": null }
```

`phase` が入っている理由は上の 97% です。**実装側だけ計器を付けると 3% を測ることになります。**

```
$ scripts/loop.sh report
landings attempted      7
reached PR              4   (57%)
cost per accepted       $3.12
rounds per landing      2.4
cost by phase           implement $4.90 / review $7.20 / verify $0.40
halted                  needs_decision 2, gave_up 1
```

**採択率が 50% を下回っていたらループは負けています** —— レビュー作業を人間に押し戻しているだけ。
`report` はそのとき自分でそう言います。`da-fix-plan` も「採択率 <50% ならレビュー側を直せ」と
書いているので、語彙は揃っています。

### 止まる理由の一覧

`halt_reason` に入る値。全部「人間に返す」で終わります。

| 理由 | 意味 |
|---|---|
| `round_cap` | 6周でゲートが緑にならなかった。**ここは request を書き直す場所**で、もう1周買う場所ではない |
| `gave_up` | gate が VERDICT を書いてブロックをやめた。**解放は緑ではない** |
| `needs_decision` | 判断が要る所見。retry では潰せない |
| `review_cap` | 上限（tier S は1周、M・L は2周）を終えても Fix now が残っている |
| `red_after_fix` | レビューの修正がゲートを赤くした。**修正についての所見** |
| `scorer_touched` | その周が採点器を編集した |
| `budget` | `--budget-usd`（既定 $10）を超えた |
| `interrupted` | exit 143（SIGTERM）。作業について何も主張しない |
| `one_way` / `pr_cap` | 検証は通ったが submit はしない（下記）。層はローカルに残る |
| `stack_failed` | `gh stack init` / `add` が失敗した |
| `isolate_failed` | 隔離できなかった。worktree 一覧が取れなかった（空は「1つも無い」ではなく git の失敗。本チェックアウトが必ず居るので）／現れたディレクトリに `cd` できなかった／**入った先がこのリポジトリの linked worktree ではなかった**。最後のは、別の run が同時に作った worktree がここからは同じに見えるため —— 他人のチェックアウトで landing を丸ごと回さないための拒否 |
| `round_timeout` | その周が `ROUND_TIMEOUT`（既定 1800s）以内に返らず、プロセスグループごと kill した（`claude` が落とした道具がポートを掴んだまま残るので）。**ハングは周回上限・予算・ゲートのどれも捕まえられない唯一の失敗**。繰り返すなら `claude` が得られないログインを待っていないか見る |
| `round_failed` | その周が 143・124 以外の非ゼロで終了した —— API エラー、rate limit、拒否されたフラグ。`claude_round` は stderr を捨てて 0 を返すので、ここで見ないと**失敗が見えないまま次に進みます**。何をしたかについて何も主張しません |
| `round_changed_nothing` | その周が編集も commit もしていない（変更パスが空で HEAD も動いていない）。**そのあとの緑は、周が始まる前から緑**でした —— `{files}` スコープのチェックはクリーンなツリーでは丸ごと飛ばされ、ゲートは本物の合格と**バイト単位で同じ** `ok:true` を返します。ゲートには「何か走ったか」を聞けないので、駆動系側で見ています |
| `gate_unran` | **1つも検査が走らなかった。** 2つの出方がある: `verify --json` が空（`gate.sh` か node が落ちた —— 空を「問題なし」と読まないため）か、`gate: nothing blocking`。後者は**チェックが飛ばされた**のではなく、**チェックを走らせる前にゲートが降りた**という意味で、`pass()`（`hooks/dotagents-verify-gate.sh:400`）からしか出ません —— 他のリポジトリ向けに arm 済み（`:498`）／サブエージェントのターン（`:508`）／既に VERDICT がある（`:545`）／git remote が無い（`:553`）の4つ。**クリーンなツリーで `{files}` のチェックが飛ぶ場合はここに入りません** —— そのときの出力は `gate: all gating checks green` で（`:934`）、本物の合格と**バイト単位で同じ**です。それは1つ上の `round_changed_nothing` が捕まえます。**周を足しても、降りたゲートは登りません。** |
| `commit_failed` | 変更パスの `git add` が1つでも失敗した、または `git commit` が失敗した。**部分的な set は commit しません** —— 半分を黙って落とした commit は、commit が無いより悪いので。add の結果を捨てていた版では、空の index が「何も無い、順調」と読まれて landing が続いていました |
| `triage_unreadable` | `da-fix-plan` の周がバケット件数を返さなかった、または数値でない値を返した。**欠けているのは 0 ではありません** —— 0 と読むと「レビューは直すものを見つけなかった」になり、triage されていない PR が、きれいなレビューと区別の付かない台帳の行と共に出ます |
| `tree_unreadable` | `git status --porcelain` 自体が失敗した（index.lock、dubious ownership、work tree でない cwd）。commit 前なら何を commit すべきか分からず、PR 前なら「何も残っていない」を確かめられない。**`changed_paths` の空はクリーンと git の失敗の両方を意味する**ので、読めるかどうかを別に、先に聞いています |
| `dirty_at_pr` | submit 直前でツリーが汚れている。commit されていない変更は PR に入らないので、そのまま出すと**手元にしか無いものを含んだ「検証済み」**になります |
| `push_failed` | `gh stack push` が失敗した |
| `pr_failed` | `gh stack submit --auto --open` が PR の URL を出さなかった。番号が取れないので `/da-pr-describe` に渡す殻がありません |

---

## PR は landing ごとに1本、stack にする —— 記録済みの判断の反転

`README.md` は「PR の作成とマージは自動化しません」と書いていました。**ここを反転させます。**
**merge は今も人間です。**

### なぜ stack なのか

**landing は構造上すでに stack です。** landing 2 は landing 1 の上に建ち、
どこで分かれるかとそれぞれの gate は `da-design-review` が既に決めています。

> **駆動系の最初の版は全 landing を1ブランチに載せていました。** landing 2 の PR が landing 1 の
> PR と衝突します。「PR を stack にしておいて」と言われて気づいた欠陥で、
> **landing の性質を実装が写していなかった**という素直な間違いです。

そして stack は、エージェント PR を実際に殺している原因への答えでもあります。
[MSR 2026 / AIDev](https://arxiv.org/html/2606.13468v1) が 33,596 PR を調べて、
**46.41% が reject され、最大バケットは「誰も関わらなかった」（inactivity 17.3%）。**
大きい diff 1本は読み手を止め、小さい層の連なりは**上が完成する前から**1層ずつ読めます。
だから **landing が終わるたびに submit** します（最後にまとめてではなく）。

GitHub の stacked PR は **2026-07-30 に public preview**、`gh-stack` 拡張が local 側を担います
（[About stacked pull requests](https://docs.github.com/en/pull-requests/get-started/about-stacked-prs) ·
[CLI コマンド](https://docs.github.com/en/pull-requests/reference/stacked-prs-cli-commands)）。

```
landing 1  →  現在のブランチが layer 1（gh stack init -b <trunk>）
landing 2  →  gh stack add <branch>-2       ← layer 2 は layer 1 を base にする
各 landing 完了時: gh stack push → gh stack submit --auto --open
```

**`--open` が要ります。** `gh stack submit` は既定で draft を作りますが、この層は既にゲートを通り
レビューを1周しているので、**draft ではなく ready for review** です。

**拡張が無ければ止まります。** `gh pr create` にフォールバックしません ——
それは全 landing の PR を trunk に並べる、**頼まれたのと違う形の出力を黙って出す**ことです。

```bash
gh extension install github/gh-stack
```

### submit する条件（全部 AND）

- `gate.sh verify --json` が `ok: true`
- `fix_now == 0` かつ `needs_decision == 0`
- `gave_up: false`
- この landing の `One-way?` が `no`
- 作業ツリーがクリーン
- 採点器に触っていない
- **この stack の open PR が5本未満**

最後の1つ: stack は1層ずつ読める形ですが、**まだ誰も読んでいない出力である事実は変わりません。**
**人間の読む速度が律速だと認めた上限**です。数えるのは head ブランチ名がこの stack のものである PR
だけ —— `--author @me` で数えると**手で開いた PR で上限が発火**し、上限は切られます。

やっていること: `gh stack push` → `gh stack submit --auto --open`（殻）→
`claude -p "/da-pr-describe <番号>"`（中身）。**駆動系が殻を作り、スキルが中身を書きます。**
これで `da-pr-describe` の前提（「PR が既に存在する」「頼まれずに PR を作るな」）が
字義通り成立したまま使えます。

**merge は人間です。** stack 全体をまとめて merge するなら `gh stack merge`、下から1本ずつでも。
下の層が merge されると、残りは GitHub 側が自動で rebase / retarget します。

> **stacked PR は public preview で、変わる可能性があります。** ここが変わったら
> `submit_landing` と `stack_layer` の2箇所です。

---

## 測ったこと（2026-08-11）

**前提を推測で置いたままにしないために測りました。そして2件の欠陥が出ました。**

| 前提 | 結果 |
|---|---|
| `claude -p` のターン終了で Stop hook が発火するか | ✅ **発火する。** armed + 赤いゲートで実測: `BLOCKED (probe-red)` → `RELEASED while probe-red red -- handed control back with checks failing`、`attempts: {"probe-red": 2}`。**`gave_up` 経路は到達可能** |
| `-p` でスラッシュコマンドが届くか | ✅ **届く。** `/da-verify` が profile を名指しして `## Verification` を出した（15ターン、$0.59）。**`disable-model-invocation` 付きも本文が読まれた** —— 「駆動系は打つ人」の中心の前提が実測で成立 |
| `da-review-all` が headless で完走するか | ✅ **完走。** 18ターン、$1.99、Canvas に言及、`report-format.md` 準拠。変更マップを省略した理由まで明記していた |
| `/grill-me` が何かを実行するか | ❌→✅ **していなかった。** `grilling` がディスクのどこにも無く、`/grill-me` は「これはスタブです」と報告するだけだった。上流から入れて解決（[判断の記録 §22](decisions.md)） |
| `--json-schema` のフラグ名 | ✅ 存在。**ただしファイルパスを渡すとエラーにならず永久にハングする** —— スキーマは文字列で取ります |

**`attempts` が1ターンで 2 になります。** ブロックで1、再入の解放で1。つまり `max_attempts: 3` は
**2ターンで到達**します —— 「3回落ちると VERDICT」は正確には「3カウント」で、無人ループの体感周回数は
それより少ないです。

**コストの実測**（このリポジトリで初めての数字）:
`/da-review-all` **$1.99** · `/da-verify` $0.59 · `/grilling` $0.76 · 自明な1ターン $0.09。
**レビュー1回で約$2** —— 引用してきた「総コストの大半がレビュー側」が、自分の数字でも同じ向きです。

### 1 landing を最後まで通した実測（2026-08-12）

**11行の docs 表を足す tier S の landing。**

| 段 | 実測 | |
|---|---|---|
| `size` | $1.98 / 5t | 測るだけ |
| **implement** | **$1.30 / 13t** | **実際の仕事** |
| `/da-review-all` | $5.64 / 50t | |
| `/da-fix-plan` | $2.08 / 20t | |
| 計 | **$12.03** | 予算 $10 超過で停止 |

**実装の6倍が測定とレビューです。** そして `report` の `cost by phase` はセッション全体で
**`size $5.39`** —— 3回測っていて、**総額の37%が測定だけ**に消えました。

**レビューは空振りではありませんでした。** 50ターンは11個の主張をコードに突き合わせるのに使われ、
**うち1つが実際に誤りでした**（駆動系が書いた `gate_unran` の説明が、フックの挙動と逆だった）。
`/da-review-all` は単体で $1.99 / 18ターンでしたが、**ループの中では $5.64 / 50ターン** ——
2.8倍。差は文脈ではなく**検証の量**です。

**`size` は1回 $1.68 / $1.72 / $1.98**（13・14・5ターン）。**測ることがレビューに迫る値段**です ——
「まず測ってから段を決める」は無料の慎重さではなく、レビュー1回とほぼ同額の支出。S の landing で
設計を飛ばして浮くぶんの一部を、その判定に払っています。**ここが次に削るべき場所です。**

### 2周目（2026-08-12、同じ形の landing）と、レビューが何を買っていたか

**同じく1ファイルの README 修正。** `size` $1.53 / 12t → `implement` $1.50 / 17t →
`/da-review-all` **$6.19 / 50t** → `/da-fix-plan` $1.90 / 12t。**計 $10.93 で、また予算超過で PR 手前**。
2周連続で同じ死に方をしました。

**そして `num_turns` が2回ともちょうど 50 でした** —— 同じ台帳の他の段は全部 5〜20 です。丸すぎる。
原因を探して、これが出ました:

```
$ claude --print --permission-mode acceptEdits "Run: git status --short"
DENIED — This command requires approval
```

**`echo hi` ✅ / `Read` ✅ / `git` ❌ / `Glob` ❌。** そして `/da-review-all` の Step 1 は `git diff` です。
**つまりレビュー段は差分を確立できていません。** 50ターンと $6.19 は深さではなく、承認されない
コマンドへの再試行でした。無人実行に承認する人はいないので、拒否で確定します。

**これは「レビューが高い」とは別の問題です。** 高い上に、買っていたものが違った。同じ日に走らせた
レビューが自分の 🔎 でそう書いていました —— 「every `git diff` / `git log` / `git show` and every
`grep` invocation was denied by the permission layer」。

**確定していないこと**: 上の表にある「`da-review-all` が headless で完走（18ターン、$1.99、
`report-format.md` 準拠）」が同じ壁の中で起きたのかどうか。あの行が本当なら当時は git が通っていた
はずで、その後に権限の判定が変わった可能性があります。**今日の環境で拒否されることだけが確認済み**で、
当時どうだったかはこの台帳からは言えません。

対処は round ごとの `--allowedTools` で、**読み取り専用の git を1つずつ名指し**します
（`Bash(git:*)` は `push` と `reset --hard` と `branch -D` まで無人ラウンドに渡すので）。

**そして最初の実装は、書いたマシンの上で no-op でした。**

```
--allowedTools "Bash(git status:*)"      → DENIED, "This command requires approval"
--allowedTools "Bash"                    → 実行された
--allowedTools "Bash(rtk git status:*)"  → 実行された
```

**コマンドを書き換える PreToolUse フックは、権限の照合より前に走ります。** このマシンのフックは
`git status` を `rtk git status` に書き換えるので、素のパターンは**何にも当たりません** ——
しかも黙って。「権限を渡していない」のと**区別がつかない失敗の形**です。

いまは**素の形と `rtk` 付きの形を両方、静的に**並べています。フックの有無を検出しないのは、
このツールキットが rtk の無いマシンでも動く必要があるからで、**当たらないパターンのコストはゼロ**。
探索して組み立てるリストは、探索が外れたときに新しい壊れ方をします。

**これは「効くと確かめずに入れた」ことの記録でもあります。** 「git が拒否される」ことは実測したのに、
「このフラグで通るようになる」ことは試さずに commit しました。**前者だけを測ると、後者は測った気に
なります。**

### 削った固定費（実測は未取得 —— 次の実走が答えます）

| | 前 | 後 |
|---|---|---|
| レイヤレビューが読む process 本文 | 76 KB ≈ **19K トークン** | 31 KB ≈ **7.9K トークン**（−58%） |
| tier S の review round の天井 | **無し** | review $1.50 + triage $0.75 + findbugs $1.50 |
| `size` の天井 | **無し**（実測 $1.53〜$1.98） | $1.25 |
| `pr` の天井 | **無し** | $1.50 |

**打ち切り検出には穴が2つ空いていました。** 検出は `post_round` にあり、そこを通らない `claude_round`
が4つあります —— `size` / `worktree` / `pr` / `verify`。うち2つは**自分の効果を後から観測する**作りなので
（worktree phase は `git worktree list`、verify phase は gate を読む）、打ち切りは観測可能な失敗として
表に出ます。残る2つは、それぞれ別の形で盲目でした:

- **`size`** —— 打ち切られると構造化出力が返らず、それは**スキーマフラグが違う**のと区別がつきません。
  実際そう報告していました。**誤診は CLI を調べに行かせます。答えはこのファイルの数字なのに。**
- **`pr`** —— 止めても取り返せない唯一の場所です。`gh stack submit` は本文を書く**前**に PR を開くので、
  打ち切られた `/da-pr-describe` は**実在する開いた PR に書きかけの説明**を残し、`opened-pr` として
  記録されます。run は止めません（deferred gate と同じ前例 —— 通らなかったのはコードではなく散文）が、
  `opened-pr-partial-body` として記録し、赤字で言います。**`report` の採択数には数えます** ——
  landing の**コード**はゲートもレビューも通っていて、切れたのは文章の方なので。

**固定費のバグは順序でした。** レイヤスキルは「finding-discipline + review-process + perspectives を
必ず読む」(47 KB) と言い、予算を決める差分計測は `review-process.md` の Step 1b —— **その47 KBの中**。
**予算を決める計測が、予算を使い切った後に行われていた。** 計測を本文の先頭に引き上げ、下段は
`review-process-brief.md` 1枚に分岐します。**落としたのは散文で、問いではありません** ——
常時カバーの5クラスタ・80点しきい値・検証1本は brief にもあります。

### レビューは subagent を1つも使わない

固定費と天井を削った後も残っていた最後の塊が**ファンアウトそのもの**でした。廃止した理由は3つで、
決め手は3つ目です:

- **subagent は「2つ目の意見」ではありません。** 同じモデル・同じ差分・同じ規律なので、返ってくるのは
  **自分の盲点にコールドスタートの請求書が付いたもの**です。独立性は**作りの違うレビュア**から来ます ——
  146 PR の測定で、所見の 93.4% は4つの*異なる*ツールのうち**ちょうど1つだけ**が捕まえ、4つ全部が
  捕まえたものは**ゼロ**でした。`/find-bugs` がその役で、同じスキルのコピーは違います。
- **節約すると称して払っていました。** 実測 **2.6〜5.9倍のトークン、しかも wall-clock は速くならない**。
  subagent は親のキャッシュ済みプレフィクスを継がないので、参照を全部買い直します。
- **2つのエージェントで同じ意味になりません。** `Task` は Claude Code のもので、Cursor の subagent は
  別の仕組みです。**「何本 dispatch したか」に厳密さが宿るレビューは、Cursor では同じレビューではない。**
  invariant 1 が言っているのは本文が方法を運べということで、inline なら**同じファイルが両方で同じ
  レビューを生みます。**

**検証は失われていません。形が変わりました。** 「検証者は所見が作られる過程を見ていてはいけない」は
正しい問題設定で、**間違っていたのは処方**です —— fresh subagent は*同じモデルが空のコンテキストを
持っただけ*で、`verification.md` 自身が既に認めていました（「3つのレンズが同じ盲点を共有しないわけでは
ない。**毎回同じモデルだから**」）。多様性は**フレーミング**から来ていて、それは inline でも無料で
変えられます。だから3レンズは3パスとして残り、`x-review-verifier` は消えました。

**代わりに 🔎 が "self-verified inline, not independently" と書きます。** 独立したエージェントが
署名したと読者が思えば、綺麗な部分の重みを読み違える —— **その読み違えが inline 化の全コスト**です。

**正直な半分**: これは全面的な節約ではありません。`silent-failure-patterns.md` と
`llm-authored-code.md` は「subagent が読むから自分は読むな」でした。渡す相手が消えたので、
**約11KB がこのコンテキストに戻ります。** ファンアウトを外すことは、読む量を*N回のコールドスタート
から1回の温かい読み込みに移す*ことであって、消すことではありません。

**天井を厳しくできる理由は、超過が声を上げるようになったからです。** 以前は打ち切られたラウンドが
exit 0 と部分的な `result` を返し、`advanced` として記録され、書きかけの所見が triage に渡っていた ——
だから天井は緩くしか置けなかった（きつい天井は静かに悪いレビューを買う）。いまは `truncated` で
landing が止まり台帳に残ります。**きつすぎれば目に見える停止と上げるべき数字が出て、緩すぎれば
$6.19 と PR に届かない run が出る。2回とも後者でした。**

## まだ測っていないこと

- **S / M / L の閾値と `MAX_ROUNDS` / `REVIEW_ROUNDS` / `BUDGET_USD` / `MAX_OPEN_PRS` /
  `ROUND_TIMEOUT` と、round ごとの `BUDGET_ROUND_*`。** 全部**選んだ数字**で、測定値ではありません
  —— gate の `max_attempts: 3` と 12h TTL と同じ status です。
  **閾値についてはここに「否定されたのは閾値ではなく入力の方でした」と書いてありました。2回目の実測が
  それを否定しました** —— 入力を直した後も同じ形の変更が `unconfirmed 9` で L になり、**閾値の方も
  間違っていた**（上の `unconfirmed` の節）。片方だと分かった時点で他方を無罪にしたのが誤りです。
- **採択1件あたりのコストは、まだ出ていません** —— そして**理由は予算ではありません**。
  3回の実走は `stack_failed` → 引き継ぎ → `budget` で止まりましたが、**天井を $7.7 にした後でも
  同じ依頼は PR に届きません**: triage が **Fix now の所見を実際に見つけている**ので、`review_cap`
  で止まるのが正しい動作だからです。**ループは正しく動いていて、指標だけが埋まっていない。**
  `cost per accepted` が `--` の間は、**計器は動いても測定は済んでいない**と読んでください。
  `report` はこれを自分で言います —— 「採択率が50%未満: ループはレビュー作業をあなたから
  引き取るのではなく、あなたに返しています」。

---

## エージェントが走らせてはいけないチェック（`agent_may_run: false`）

**「無視」ではなく「CI に委ねた」として扱います。** 区別が要るのは、禁止の中身が
**「走らせるな」であって「検証せずに出荷しろ」ではない**からです。

| 呼び手 | 扱い |
|---|---|
| `/da-verify`（対話） | **今のまま。** コマンドと `delegate_reason` を見せて人間に頼み、**出力を待つ** |
| 駆動系（無人） | **`deferred` として記録し、進む** |

無人で「待つ」も「周回する」も間違いです。**聞く相手が居ないし、どのラウンドも直せません** ——
実際に `MAX_ROUNDS` を6周使い切って `round_cap` で止まることを実測しました。

**だから連鎖はこうなります: ローカルのゲートは走らせて良いものを走らせ、CI が残りを走らせ、
PR がどちらがどちらかを言う。** これは禁止を字義通り守っています —— リポジトリは実行を禁じており、
駆動系は何も実行しません。

**そして黙ってはいけません。3箇所に出します:**

```
実行中     typecheck: the repository forbids the agent from running this -- deferred to CI
台帳       "deferred": ["typecheck"]
PR 本文    /da-pr-describe に「ローカルで未検証」として渡す
実行後     「CI が gate です —— merge 前にそこが緑であることを確認してください」
```

**解放されたゲートが緑でないのと同じく、委ねられたゲートも緑ではありません。**
`report` は台帳から `deferred` を読めるので、あとから「何を自分では見ていなかったか」を数えられます。

> **エージェントが走らせて良いチェックが赤いときは、今までどおり止まります。** 委譲は本物の失敗を
> 飲み込みません —— ゲートが `kind: red` を返したら赤で、`kind: needs_human` のときだけ委ねます。

## 他のリポジトリに向けるとき

1. そのリポジトリに profile があること。無ければ `/da-verify` が manifest から書き起こします。
   **profile が無いと `run` は始まりません** —— gating check が無いのは、緑ではなく未検査です。
2. **`agent_may_run: false` のチェックは `deferred` になり、CI が gate になります**（上記）。
   実例: `dresscode-backend` の `typecheck` は 8GB ヒープを理由にリポジトリ側が禁止しています。
   **駆動系は走らせず、PR に「ローカル未検証」と書き、CI に渡します。**
   だから**そのリポジトリの CI が typecheck を走らせていることが前提**です —— 走らせていないなら、
   委ねる先が無いので、`gate: false` にするか CI を足すかの判断が要ります。
3. 採点器の一覧（`scorer_paths`）はこのリポジトリの構造に合わせてあります。他のリポジトリでは
   そこが違うので、**何がそのリポジトリの採点器かを決めてから**向けてください。
