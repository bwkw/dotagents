# Fix plan — worktree-unattended-run (`5b2d9e6`)

**The change was for:** `docs/loops.md` の「まだ測っていないこと」節を見直し、実測が付いた項目を「測った」側へ移す。`docs/loops.md` 1ファイルのみ、+49 −14。

**Source:** `/da-review-all` 1本（inline、layer skill 0本）。findings 3件（🔴1 / 🟡1 / 💡1）+ 🧭1 + 👤1。

## Fix now
| # | Finding | Location | The minimal fix | Order |
|---|---|---|---|---|
| F1 | レビュー天井の根拠が4点→6点に膨らんでいる。$2.00 は6点中 $5.64 / $6.19 の**下**なので「実測6点の散らばりの上に置いた」は成立しない | `docs/loops.md:805`, `:818` | 2箇所の「実測6点」を「（修正後の）実測4点」に。段が6点で測られていることと天井が4点の上に載っていることを別の文にする。根拠は `scripts/loop.sh:82-86` と本文 `:733` | 1 |

## Fix now, but smaller than proposed
| # | Finding | What was proposed | What is actually needed | Why the smaller version closes it |
|---|---|---|---|---|
| F2 | 台帳の行数が本文に焼き込まれ、書いた landing の中で既に古くなった（34→35） | 「34行時点」と限定する、または行数を落とす | 行数を落とし「`fix` と `pr` の行が増えました」だけ残す | 隣の構造的な主張（`fix`/`pr` が増えた・`ci` は0本）が論を運んでいる。行数は次のラウンドで必ず腐るので、限定句を足すより消すほうが保つ |

## Follow-up
| # | Finding | Why it can wait | What the issue needs to say |
|---|---|---|---|
| 🧭 | `loops.md` と `scripts/loop.sh` / `ledger.jsonl` を突き合わせるものが無い。F1 はまさにこれで生き延びた（数字が `loop.sh:82` のコメントではなく2節上の散文から来た） | この landing のドキュメント修正を止める理由にはならない。仕組みの追加は別の変更 | `verify-skills.sh` は skill 名と DMI リストのドリフトを守るが、loop の**文書化された数値**には等価物が無い。定数（`BUDGET_ROUND_*` など）を `loop.sh` から、行数・実測点数を `ledger.jsonl` から突き合わせる check を linter に足すか、文書側から数字を落とすかの選択 |

## Declined
| # | Finding | Reason |
|---|---|---|
| F3 | 「残りの」と「ここから出たのは1つだけ」の順序（`:802-805`） | style preference。💡 は reviewer 自身が optional として出したもので、どちらの読み方でも意味は通る。F1 で `:805` を触るが、この語順は正確性の問題ではない |

## Needs a decision
なし。人が選ばないと進めないものは無い。

## Ordering and interactions
- Irreversible first: 該当なし（docs のみ、migration も公開契約も無い）
- F1 と F2 は同一ファイルの別段落（`:805`/`:818` と `:814`）。`:814` と `:818` は同じ箇所に隣接するので、**F1 → F2 の順で1コミット**にまとめ、行番号ずれを後から発見しない
- Merged: なし（F1 と F2 は根本原因が同じ「手で写した数字」だが、直す文は別）
- Needs re-verification: なし

## Out of scope for this plan
- `:630` / `:728` の「`/da-review-all` 単体で $1.99 / 18 turns」と 76 KB→31 KB の数値（どちらも pre-existing、この diff に無い）
- 🧭 で挙げたドリフト check の実装
- `scripts/loop.sh` 本体

## Verification
`./scripts/verify-skills.sh`（docs のみの変更なので他の check は無い）+ `:805` / `:818` / `:814` を読み直し、「6点」が残っていないことと行数が消えていることを目視。

## 未確認（レビューの届かなかった範囲 — PR body の caveat へ）
1. `:718-725` の表の時刻が UTC 表記で、文書内の他の時刻が同じ規約かは未監査（pre-existing、内部的には一貫）
2. `:630` / `:728` の「$1.99 / 18 turns」は `ledger.jsonl` に無く、出所を特定できなかった
3. 76 KB→31 KB の review-process の数値は未測定（pre-existing）

Bash がこのセッションでほぼ拒否されたため、台帳の集計はプログラムではなく手計算。

## 採択率
accepted 3（Fix now 1 + smaller 1 + Follow-up 1）/ total 4 = **75%**。
前回（`docs/fix-plans/2026-08-11-loop-driver.md`）の記録は未参照。
