#!/usr/bin/env bash
# 次のセッションが知るべきことを、記憶ではなくリポジトリから生成する。
#
#   scripts/handoff.sh            引き継ぎを出力
#
# **ここは全部生成なので陳腐化しない。** 手書きの引き継ぎメモは持たない。リポジトリの状態の手書きの
# 写しは必ずずれる（決着済みの判断を未決として出す、など）。

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}" || exit 1
LEDGER="${DOTAGENTS_LOOP_DIR:-${HOME}/.claude/.dotagents-loop}/ledger.jsonl"

say() { printf '%s\n' "$*"; }

say "# 引き継ぎ — $(date '+%Y-%m-%d %H:%M')"
say ""
say "\`scripts/handoff.sh\` が生成。**すべて git・台帳・gh から取るので陳腐化しない。**"
say ""

# --- 現在地 -------------------------------------------------------------------
branch="$(git branch --show-current 2>/dev/null || echo '(detached)')"
head_line="$(git log --oneline -1 2>/dev/null)"
main_line="$(git log --oneline origin/main -1 2>/dev/null || echo '(origin/main 不明)')"
dirty="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
unpushed="$(git log --oneline origin/main..HEAD 2>/dev/null | wc -l | tr -d ' ')"

say "## 現在地"
say ""
say '```'
say "branch : ${branch}"
say "HEAD   : ${head_line}"
say "main   : ${main_line}"
say "tree   : ${dirty} 件の未 commit"
say "ahead  : ${unpushed} 件が未 push"
say '```'
say ""

# セッションに最も高くつく 2 つの状態。
if [[ "${dirty}" != "0" ]]; then
  say "⚠️ **未 commit がある。** 検査スイートやマージを挟む前に commit すること（一度まるごと失っている）。"
  git status --short | sed 's/^/    /'
  say ""
fi
if [[ "${unpushed}" != "0" ]]; then
  say "**未 push の commit:**"
  git log --oneline origin/main..HEAD | sed 's/^/    /'
  say ""
fi

# --- 直近に何が起きたか -------------------------------------------------------
say "## main の直近"
say ""
git log --oneline -8 origin/main 2>/dev/null | sed 's/^/    /'
say ""
say "**自分の文脈がこれより古いなら、まずここを読むこと。** 古い認識のまま作業すると、既に main にある"
say "修正を入れ直すことになる。"
say ""

# --- 置き去りのブランチ -------------------------------------------------------
# このセッションの知らないうちにチェックアウトが動くと、完成した commit が HEAD から見えないブランチに
# 残る。HEAD だけ見ると消えたように見えるので、main に入っていないローカルブランチを全部出す。
stray=""
for b in $(git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null); do
  [[ "${b}" == "main" ]] && continue
  git merge-base --is-ancestor "${b}" origin/main 2>/dev/null && continue
  stray="${stray}${b}|$(git log --oneline -1 "${b}" 2>/dev/null)"$'\n'
done
if [[ -n "${stray}" ]]; then
  say "## main に入っていないローカルブランチ"
  say ""
  printf '%s' "${stray}" | while IFS='|' read -r b line; do
    [[ -n "${b}" ]] && say "    ${b}"$'\n'"        ${line}"
  done
  say ""
  say "**チェックアウトされていないだけの完成品がここにあることがある。** このセッションが打っていない"
  say "\`checkout\` や \`pull\` でブランチが切り替わると、commit 済みの作業が HEAD から見えなくなる。"
  say "**HEAD だけを見ると「消えた」と読める。**"
  say ""
fi

# --- worktree -----------------------------------------------------------------
wt="$(git worktree list 2>/dev/null | tail -n +2)"
if [[ -n "${wt}" ]]; then
  say "## 残っている worktree"
  say ""
  printf '%s\n' "${wt}" | sed 's/^/    /'
  say ""
  say "実走の残り。マージ済みか未確認のものが混ざる。"
  say ""
fi

# --- 開いている PR ------------------------------------------------------------
prs="$(gh pr list --state open --limit 10 --json number,title,headRefName \
        --jq '.[] | "#\(.number) \(.headRefName) — \(.title)"' 2>/dev/null)"
say "## 開いている PR"
say ""
if [[ -n "${prs}" ]]; then printf '%s\n' "${prs}" | sed 's/^/    /'; else say "    (なし)"; fi
say ""

# --- 台帳 ---------------------------------------------------------------------
say "## ループの台帳"
say ""
if [[ -f "${LEDGER}" ]]; then
  say '```'
  bash "${REPO}/scripts/loop.sh" report 2>/dev/null | sed -n '1,8p'
  say '```'
  say ""
  say "**直近の実走:**"
  say ""
  node -e '
    const fs = require("fs"), lines = fs.readFileSync(process.argv[1], "utf8").split("\n");
    const rows = lines.filter(Boolean).map((l) => { try { return JSON.parse(l) } catch { return null } })
                      .filter(Boolean).filter((r) => r.phase !== "size");
    for (const r of rows.slice(-8)) {
      const halt = r.halt_reason ? "  halt=" + r.halt_reason : "";
      process.stdout.write("    " + r.ts.slice(5, 19) + "  " + String(r.phase).padEnd(10) +
        String(r.outcome).padEnd(22) + "$" + Number(r.cost_usd || 0).toFixed(2) + halt + "\n");
    }
  ' "${LEDGER}" 2>/dev/null
  say ""
else
  say "    (台帳が無い。まだ一度も回していない)"
  say ""
fi

# --- 検査 ---------------------------------------------------------------------
say "## 最初に確かめること"
say ""
say '```bash'
say "bash scripts/check.sh          # 全項目。落ちたらそこが続き"
say '```'
say ""
say "**緑を額面で受け取らないこと。** このリポジトリには *検査の側が壊れていた* 事例がある。bash は"
say "関数を定義の**実行時**に作るので、使う場所の隣に置いたヘルパはそれより上のケースで未定義になる。"
say "実装を外しても緑のままの assertion もあった。**疑わしい緑は、実装を外して赤くなるかで確かめる:**"
say ""
say '```bash'
say 'cp scripts/loop.sh /tmp/keep.sh && <実装を外す> && bash scripts/test-loop.sh; cp /tmp/keep.sh scripts/loop.sh'
say '```'
say ""
say "退避→削除→実行→復元を**1 コマンドに**するのは、待ち時間に触ると確認が無効になるため。"
say ""

# 判断の側は書き写さない。半端なものは PR と CI に、決めたことは docs/decisions.md に、金と停止理由は
# 台帳に出る。写しを持つと写しの方が古くなる。
