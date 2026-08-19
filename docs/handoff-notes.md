## 持ち越し

**このファイルはセッションを終える側が書き換えます。** `scripts/handoff.sh` が生成する上半分は git と
台帳から取れる事実で、こちらは**取れないもの** —— 何が半端で、なぜそうなっているか。

### いま半端なもの

- **PR は3本ともマージ済みです**（#55 レビュー観点 / #56 この引き継ぎ機構 / #57 台帳の PR 到達）。
  合流後の main で `check.sh` を回し直しています —— **3本は別々の main に対して検査していたので、
  3本が同時に載った状態は誰も走らせていませんでした。**
- **`fa5bb58` は PR #57 として入りました**（`0f2f2c1`）。`pr-opened` は `pr-reached` に改名してあります
  —— `opened-pr` と語順しか違わない outcome は、タイプミス1回と grep 1回で互いに読み替わるため。
  **残っているのは実走で、`pr-reached` を書く経路はまだ一度も走っていません。**
- **`CHANGELOG.md` は「入っていない」のではなく、外すと決めてあります。** `5eda631`（移植性を直すことと
  製品にすることを混同していた）で削除され、`docs/decisions.md`（「外したもの: `CHANGELOG.md`、タグ」）と
  `docs/portability.md` の9行目（「**やらないと決めた**」）に理由ごと残っています。**この項は一度
  「1.0.0 をどうするか決める」という未決事項として書かれました** —— ブランチ名と `git cherry` だけを見て、
  **決定の記録を検索しなかった**ためです。**未マージのブランチは、未着手の作業とは限りません。**

### 残っているローカルブランチ 6本 —— 整理済み

**37本を7本（main + 6）にしました。** 判定は `git cherry origin/main <branch>` の patch-id です:
内容が main にあるもの10本（マージ済み3本を含む）と、main の祖先21本を削除しました。後者は
`git branch -d` —— **未マージなら拒否される側**を使っているので、原理的に取り違えが起きません。

| 残っているもの | なぜ |
|---|---|
| `release/v1.0.0` `portability/remaining-items-onto-main` | **決定により不要**（上の CHANGELOG の項） |
| `review-fanout-cost` | **前提が消えている** —— レビューは subagent 0本（`AGENTS.md` invariant 10） |
| `worktree-unattended-landing` | **内容は main にある**（`CI_ATTEMPTS` / `CI_WAIT_SECONDS` は `docs/loops.md:667,686`）。捨てて良い |
| `worktree-unattended-run` | 停止理由の「中心／外周」表 88行が **main に無い**。中身の検証が要る |
| `worktree-dotagents-work` | README の実走記述を直す変更。**本文自体が古い**ので、取り込まず今日の台帳から書き直した |

**`origin` には `feat/skill-body-integrity` が PR 無しで残っています**（内容は main）。remote 側の
削除はしていません。

### 次にやること（優先順）

1. **tier XS の初実走。** 実装もテストも入っているが**一度も走っていない**。テストでしか通っていない
   経路が3つ: `advanced-untriaged` の台帳記録 / レビュー報告のディスク保存（`$LOOP_DIR/reviews/`）/
   PR 本文の未 triage 注記
2. **review の天井は、もう上がっています —— 次は測ること。** この項は「現在 $1.50 に対し実測
   $0.88〜$2.07、$2.07 の回が `round_failed` で死んでいる」と書かれていましたが、**二重に誤り**でした:
   `$1.50` は `BUDGET_ROUND_PR`（PR 本文を書く周）で、review の天井は `BUDGET_ROUND_REVIEW=5.00` /
   `_LEAN=3.00`（当時 `_S=2.00`）。そして `round_failed` は予算超過ではなく「**exited N。何をしたかに
   ついては何も主張しない**」（`scripts/loop.sh:1006`）。**8回目が $2.07 で死んだのは天井超過が
   `round_failed` に化けていたから**で、判定順も天井も修正済みです（`loop.sh:991-1003` がこの回を
   名指しで記録）。**残っているのは、上げたあとの実走が1本も無いこと** —— いまの $3.00 は測定では
   なく選び直した数字です
3. **implement に天井が無い。** 実測 $0.83〜$4.56 と5倍以上振れる。**1サンプルで決めると必ず外す**
4. **ゲートが landing の壁時計を支配**（`docs/decisions.md` §29、未対処）。ただし「docs 1ファイルの
   ゲートが 5〜8分から3秒」になった PR があるので、部分的に解消している可能性あり —— **未確認**
5. **`worktree-unattended-run` の88行を読んで、入れるか捨てるか決める。** 停止理由を「中心／外周」に
   分けた表で、main には無い唯一の未 landing な中身です

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
