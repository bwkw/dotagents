# Fix plan — ループ駆動系（`scripts/loop.sh`）

**The change was for:** 設計 → 実装 → 反復レビュー → landing ごとに1本の stacked PR を、変更の規模に
応じて自動で回す駆動系と台帳を足す。**プロダクトリポジトリには触らない**、**`gate.sh` と `hooks/` は
触らない**（それらが採点器なので）。

**Source:** fail-open 経路に絞った1本のレビュー、所見12件（うち2件は到着前に修正済み）。

---

## 到着前に修正済み（triage の対象外）

レビュアが読んだのは40分前の版で、以下2件はその後に別経路で見つけて直しています。**バケットに入れず、
ここに置くのは二重計上を避けるため**です。採択率の分母にも入れません。

| レビュア所見 | 状態 |
|---|---|
| #3 の一部: `structured_output` 不在 / 非数値が「直すものなし」と読まれる | 修正済み。`triage_unreadable` で停止。テスト3件 |
| #4: `cmd_size` の risk フィールド不在が tier S になる | 修正済み。`round_has_structured` で不在と空配列を区別 |

---

## Fix now

| # | Finding | Location | The minimal fix | Order |
|---|---|---|---|---|
| 1 | **`{files}` scope のチェックはツリーがクリーンだと skip され、hook は exit 0 → `ok:true`。「検証済み」と「検査するものが無かった」が区別されない** | `loop.sh:209-219` / `hooks/dotagents-verify-gate.sh:790,398` | `gate_verify_ok` が `detail` の `nothing blocking` を緑として扱わない。**hook 側は触らない** —— 採点器なので | 2 |
| 2 | **`post_round` は exit 143 しか見ない。API エラー等の非ゼロ終了はそのまま進む** | `loop.sh:425` | 0 以外の終了はすべて `round_failed` で停止。143 は今のまま `interrupted` | 3 |
| 3 | **`changed_paths` が「クリーン」と「判定できなかった」を同一視。消費者4つが全部 benign 側に倒れる** | `loop.sh:166-187`, 192, 690, 577, 636 | git の終了状態を見て、失敗は空文字ではなく失敗として返す。呼び出し側は停止 | 1 |
| 4 | **tier S は landing plan の検証を全部飛ばすのに、渡された plan は `parse_plan` に通す** | `loop.sh:710-720, 769` | `$plan` が空でなければ tier に関係なく検証する | 4 |
| 5 | **`isolate` が自分の作っていない worktree に `cd` しうる。`before` が空だと既存の全 worktree が「新規」。`isolate \|\| return 1` は到達不能** | `loop.sh:380-395, 723` | `before` の取得失敗を検出し、`cd` 後に `in_linked_worktree` と `repo_key` の一致を確認。失敗時は非ゼロを返す | 5 |
| 6 | **`STACK_BASE_BRANCH` は `gh stack init` 経路でしか設定されない → 再開時に上限が発火せず、層名が `<l1>-2-3` と複合する** | `loop.sh:605-611, 626-627` | 短絡経路でも設定する（1箇所） | 6 |
| 7 | **`--budget-usd` の値を省略すると無限ループ**（`shift 2` が引数1個で何も shift しない） | `loop.sh:678-686` | 値の存在と数値性を検証してから `shift` | 7 |

## Fix now, but smaller than proposed

| # | Finding | What was proposed | What is actually needed | Why the smaller version closes it |
|---|---|---|---|---|
| 8 | `gate_has_profile` が空の `GATE_JSON` で true、`gate_gave_up` が status 失敗で false | 各ヘルパを個別に堅牢化 | **`GATE_JSON` が空なら停止する1つのガード**。両方とも同じ根 —— JSON ヘルパが parse 失敗を benign な答えとして返す | レビュア自身が「PR には到達せず round_cap で6周分払って死ぬ」と書いている。到達性は低く、代償は金銭。1ガードで両方閉じる |
| 9 | `commit_landing` が `git add` 全失敗でも成功を報告 | ステージング結果の検証 | `git add` の終了状態を捨てない | #3 を直せば下流の `dirty_at_pr` が確実に捕まえる。ここは台帳の汚染を止めるだけで足りる |
| 10 | `record` の手組み JSON が未エスケープ → check id に `"` が入ると行ごと消え、`halt_reason` も消える | 全体を作り直す | `ledger_append` と同じく node で組む | 計器が黙って行を落とすのを止めるのが目的で、それ以上は要らない |

## Follow-up

| # | Finding | Why it can wait | What the issue needs to say |
|---|---|---|---|
| 11 | **`scorer_touched` の守る対象が dotagents 固有のパスにハードコードされている。他リポジトリでは何も守らない** | 機構の追加（profile に `scorer` フィールド？）が必要で、それは設計判断。**ただし「本文の過大主張」は Fix now で直す**（下記） | どのリポジトリでも採点器を宣言できる仕組み。`profiles/_schema.json` に足すのが素直だが、schema は採点器そのものなので順序の判断が要る |
| 12 | 失敗したラウンドのコストが 0 として記録され、予算に効かない | 予算の停止判定ではなく会計精度の問題 | `ROUND_COST` が取れないときは行に `cost_unknown: true` を立てる。`report` の合計が過少であることを言えるように |

## Declined

| # | Finding | Reason |
|---|---|---|
| 13 | 「ラウンドが自分でコミットすれば `changed_paths` から見えず、`{files}` チェックも空振りする」（#2 後半） | **speculative** —— レビュア自身が「`--permission-mode acceptEdits` は Bash を自動承認せず、`Bash(git commit…)` の allowlist も TDD スキルのコミット指示も見つからなかった」と書いています。存在しない allowlist に依存する経路で、前半（マルチリポジトリ）は #11 で扱う |

## Needs a decision

| # | Question | Who decides | What they need to decide it |
|---|---|---|---|
| A | **`verify --json` に「何も実行しなかった」を表す構造化フィールドを足すか。** 今は `detail` の散文（`nothing blocking`）を grep するしかなく、これで **prose 結合が2つ目**（`no profile matches` に続いて） | あなた | `gate.sh` と `hooks/` は**この変更のスコープ外**で、かつ**採点器そのもの**。散文結合2つを抱えるか、採点器に手を入れるか。入れるなら別 landing で、`test-verify-gate.sh` に契約テストを足すのが筋 |

## Ordering and interactions

- **`#3`（`changed_paths`）が最初。** 4つの消費者を直すので、`#9` の下流の捕捉が確実になるのはこの後。
  `#9` を先にやると、まだ fail-open な下流に対して直すことになる。
- **`#1` は2番目。** これを直すと `#2` の「非ゼロ終了で進む」経路のうち verify 起因のものが消えるので、
  `#2` の必要範囲が確定する。
- **`#9` は `#3` の後に再検証が必要** —— `changed_paths` の返り値の意味が変わるため。
- **同一ファイル同一関数に触るもの**: `#1` と `#8` はどちらも `gate_*` ヘルパ群。順に。
- **`#5` と `#6` は独立**、まとめて1コミットで良い。
- **`#7` は他と干渉しない**（引数パース）。最後でも良いが1行なので `#5`/`#6` に同梱可。
- **`#11` の「本文の過大主張」だけは Fix now 相当**: `loop.sh` のヘッダ rule 3 と `docs/loops.md` が
  「a test suite を触ると landing を中止する」と書いているが、**dotagents 以外では真ではない**。
  ガードレールについての偽の主張はこのリポジトリが最も嫌う形なので、**機構を待たずに文面を正す。**

## Out of scope for this plan

- **`hooks/` と `scripts/gate.sh`** —— 採点器。項目 A の判断が出るまで触らない。
- **既知の別欠陥**: 赤い `gate.sh verify` が「ゲートの故障」と誤報する件（crash guard が dry-run の
  `exit 1` を 2 に変換）。別タスクとして起票済み。
- **前提1〜3の測定**（`claude -p` で Stop hook が発火するか等）—— このマシンの `claude` が壊れており、
  `npm install -g @anthropic-ai/claude-code` が要る。**駆動系はどちらでも壊れないように書いてある。**

## Verification

```bash
./scripts/test-loop.sh          # 各 Fix now に落ちるテストを先に足す
./scripts/check.sh              # 全スイート
scripts/gate.sh verify --json   # ok: true
```

加えて **`#1` には専用のテストが要る**: `{files}` scope のチェックだけを持つ profile を用意し、
ツリーがクリーンな状態で `gate_verify_ok` が緑を返さないことを確認する。**これは今のスイートに無い形**
—— hermetic profile が `scope: all` だけだったので、この経路は一度も踏まれていません。

---

## 実施後の記録（2026-08-11）

**テストは85件、`check.sh` は全スイート緑。** 実施中に所見2件の内容が変わりました。

### #1 —— レビュアの示した信号は存在しなかった

レビュアは「skip されたとき hook は `nothing blocking` と印字する（`hook:400`）」と書いていました。
**それは `pass()` の経路**（remote 無し / profile 無し / 既存 VERDICT）で、
**`{files}` が skip される経路ではありません。** 実測しました:

```
clean tree + {files} のみの profile  →  ok: true, check: null,
                                        detail: "gate: all gating generic checks green"
```

つまり **JSON でも散文でも、本物の pass と区別できません。** grep する信号が無いので、
提案された修正は成立しませんでした。

**代わりに駆動系側で閉じました**: **何も変更しなかったラウンドは緑を「獲得」しておらず、
ラウンド開始前から真だった緑を「継承」しているだけ**。ツリーが無変更かつ HEAD が動いていなければ
`round_changed_nothing` で停止します。ゲートに問い合わせる必要がなく、prose 結合も増えません。

**そして項目A（`verify --json` に構造化フィールド）の必要性は上がりました** ——
散文の回避策すら存在しないことが分かったので。

### #10 —— 反証されました

「check id に `"` が入ると台帳の行ごと消え、`halt_reason` も失われる」。**消えません。**
`ledger_append` は `try { v = JSON.parse(v) } catch {}` なので、parse 失敗時は**文字列として残る**
—— 行は valid JSON のままで、データ損失はありません。`cmd_report` は `gate` を読まないので影響もなし。
**先にテストを書いたら修正前から通ったのが証拠**です。修正なし、これは所見ではありませんでした。

### 実施の内訳

| 項目 | 状態 |
|---|---|
| #1 空振り緑 | **別の機構で修正**（`round_changed_nothing`）。信号は存在しなかった |
| #2 `post_round` が 143 のみ | 修正（`round_failed`） |
| #3 `changed_paths` の不可読 | 修正（`tree_readable` を4消費者すべての前に） |
| #4 tier S が plan 検証を飛ばす | 修正（渡されたら tier に関係なく検証） |
| #5 `isolate` の同一性 | 修正（`before` 空を検出、`cd` 後に `repo_key` 一致を確認、失敗で非ゼロ） |
| #6 `STACK_BASE_BRANCH` | 修正（短絡経路でも設定） |
| #7 `--budget-usd` の無限ループ | 修正（値の存在と数値性を検証してから shift） |
| #8 空 `GATE_JSON` | 修正（`gate_has_profile` / `gate_verify_ok` の両方） |
| #9 `git add` の失敗を無視 | 修正（部分コミットを拒否） |
| #10 台帳行が壊れる | **反証。修正なし** |
| #11 前半（本文の過大主張） | 修正（ヘッダと `docs/loops.md`） |
| #11 後半（機構）・#12 | Follow-up のまま |

### 更新後の採択率

**10 / 12 = 83%**（#13 Decline、#10 反証）。前回記録なし。
**80% を超えているので「gate してよい」域ですが、反証が1件出たことの方が重要**です ——
検証パスが機能した証拠で、100% は転記の兆候だという表の逆側にあたります。

## 採択率

**11 / 12 = 92%**（Fix now 7 + Fix now smaller 3 + Follow-up 2 = 12 のうち、Decline 1）。
※ 到着前に修正済みの2件は分母から除外。

**80% を超えているので「gate してよいレビュア」の域**ですが、100% ではないことと、
**レビュア自身が自分の疑い1件（rename の解析）を検証して取り下げている**のが、
転記ではなく triage が働いた証拠です。1本のレビューの数字は何も言わないので、次回と併記すること。
