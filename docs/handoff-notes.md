## 持ち越し

**このファイルはセッションを終える側が書き換えます。** `scripts/handoff.sh` が生成する上半分は git と
台帳から取れる事実で、こちらは**取れないもの** —— 何が半端で、なぜそうなっているか。

### いま半端なもの

- **PR が3本、マージ待ちです。** #55（レビュー観点）・#56（この引き継ぎ機構）・#57（台帳の PR 到達）。
  3本ともファイルの重なりはゼロで、順序の制約もありません。**マージだけは自動では実行できませんでした**
  —— `gh pr merge` が権限分類器に止められるので、人が押す必要があります
- **`fa5bb58`（台帳が PR 到達を数えない件）はもう回し切ってあります。** `bash scripts/check.sh` 全12項目緑、
  main に rebase 済み（`0f2f2c1`）。**残っているのは実走**で、`pr-reached` を記録する経路は一度も
  走っていません
- **`CHANGELOG.md` が main に存在しません。** `release/v1.0.0` と `portability/remaining-items-onto-main`
  が**別々に**「Unreleased を 1.0.0 に確定」しようとしていて、**どちらも入っていない**。`LICENSE`・
  `CONTRIBUTING.md`・`SECURITY.md` は入っているので、公開の作業は途中まで landing しています

### 未マージのローカルブランチ 16本 —— patch-id で見た分類

`git cherry origin/main <branch>` で判定（`-` は同じ patch が main に既にある）。**ブランチ名から
推測しないこと**、と同時に**16本あるという表示に怯まないこと** —— 実際に未着手なのは4本です。

| 状態 | ブランチ | 扱い |
|---|---|---|
| **内容は main にある**（全 commit が `-`） | `feat/skill-body-integrity` `fix-cursor-model-claim` `portability/remaining-items` `portability/works-on-another-machine` `pr-describe-table-and-japanese` `revert-model-pin` `review-perspectives-and-change-map` | 削除して良い |
| **一部だけ未 landing** | `portability/remaining-items-onto-main`（4本中1本 = CHANGELOG の 1.0.0） | 上の CHANGELOG の件と同じ |
| **未 landing** | `release/v1.0.0`（CHANGELOG）`review-fanout-cost` `worktree-dotagents-work` `worktree-unattended-landing` `worktree-unattended-run` | 下記 |
| **PR 待ち** | `chore/handoff-script` `feat/review-perspectives-twins` `fix/ledger-records-pr-arrival` | #55 / #56 / #57 |

- **`review-fanout-cost` は前提が消えています。** レビューは subagent 0本になったので、ファンアウトに
  予算を付ける変更は入れる先がありません（`AGENTS.md` の invariant 10 が「the review now runs zero
  subagents」と書いている）
- **`worktree-*` の3本は実走の産物**で、いずれも `docs/loops.md` か `README.md` の1ファイル編集です。
  その後の docs 編集と重なっている可能性が高いので、**差分を読んでから**判断すること
- `origin` に残っているのは `feat/skill-body-integrity` 1本だけで、**PR が無いまま**残っています

### 次にやること（優先順）

1. **tier XS の初実走。** 実装もテストも入っているが**一度も走っていない**。テストでしか通っていない
   経路が3つ: `advanced-untriaged` の台帳記録 / レビュー報告のディスク保存（`$LOOP_DIR/reviews/`）/
   PR 本文の未 triage 注記
2. **review の天井を上げる。** 現在 $1.50 に対し実測 $0.88〜$2.07 で、**$2.07 の回が `round_failed`
   で死んでいる**。根拠は揃っているので $2.50 前後へ
3. **implement に天井が無い。** 実測 $0.83〜$4.56 と5倍以上振れる。**1サンプルで決めると必ず外す**
4. **ゲートが landing の壁時計を支配**（`docs/decisions.md` §29、未対処）。ただし「docs 1ファイルの
   ゲートが 5〜8分から3秒」になった PR があるので、部分的に解消している可能性あり —— **未確認**
5. **`CHANGELOG.md` と 1.0.0 をどうするか決める。** ファイルが main に無い状態で、確定しようとした
   ブランチが2本ある

### 繰り返し出ている形（次も出ます）

**握り潰された失敗は、別の場所の嘘になる。** 実測3件:

| 本当の原因 | 報告された姿 |
|---|---|
| `--allowedTools` が可変長でプロンプトを食う | 「スキルが隔離を断った」 |
| `gh stack submit` が URL でなく散文を返す | `pr_failed`（PR は実在） |
| `pr` の記録位置が CI/describe の後 | `reached PR 0%`（PR は実在） |

**停止条件にするフィールドは「空であることが正常な結果として起こりうるか」を先に確かめること。**
起こりえないなら、それは停止条件ではなく計器です。`unconfirmed > 0` → tier L、
`needs_decision > 0` → landing 停止、`review_cap`（修正の適用前に判定）の3件が、どれも自分の下流を
到達不能にしていました。

### 測ってあるもの / 選んだだけの数字

- **測ってある**: review $0.88〜$2.07（20〜28 turns）、implement $0.83〜$4.56、size $0.44〜$1.98、
  triage $0.59〜$0.74、`gh pr checks` の終了コード 8 = 実行中
- **選んだだけ**: 天井（review / triage / findbugs / size / pr / ci）、`MAX_ROUNDS=3`、
  `CI_ATTEMPTS=2`、`CI_WAIT_SECONDS=900`、段の閾値
