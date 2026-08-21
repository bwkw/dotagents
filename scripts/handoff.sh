#!/usr/bin/env bash
# What the next session needs to know, generated from the repository rather than remembered.
#
#   scripts/handoff.sh            print the handoff
#
# **Everything here is generated, so none of it can go stale.** There used to be a second half: a
# hand-written `docs/handoff-notes.md` carrying "what is half-finished and why". It was removed once the
# driver worked, because a hand-maintained copy of the repository's state is a copy that goes wrong --
# and it did, twice in one session: it offered a settled decision as an open question, and attributed a
# budget number to the wrong phase. Both were derivable from the tree it was meant to supplement.
#
# Written after a session lost its own thread twice: once when uncommitted work vanished, and once when
# the context was 13 merged PRs behind the repository and did not know it. Both are visible below.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}" || exit 1
LEDGER="${DOTAGENTS_LOOP_DIR:-${HOME}/.claude/.dotagents-loop}/ledger.jsonl"

say() { printf '%s\n' "$*"; }

say "# 引き継ぎ — $(date '+%Y-%m-%d %H:%M')"
say ""
say "\`scripts/handoff.sh\` が生成。**全部 git・台帳・gh から取っているので陳腐化しません。**"
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

# The two states that cost a session most. Both were paid for once.
if [[ "${dirty}" != "0" ]]; then
  say "⚠️ **未 commit があります。** 検査スイートやマージを挟む前に commit すること —— 一度まるごと失っています。"
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
say "**自分の文脈がこれより古いなら、まずここを読むこと。** 一度、13本のマージ済み PR より後ろの認識で"
say "作業して、既に main にある修正を入れ直しています。"
say ""

# --- 置き去りのブランチ -------------------------------------------------------
# The failure this exists for: the checkout moved without this session doing it -- the reflog showed a
# `checkout` and a `pull` nobody here typed -- and a finished commit sat on a branch that was no longer
# checked out. Looking only at HEAD would have reported it as gone. So every local branch that is not
# in main gets listed, whatever is checked out right now.
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
  say "**チェックアウトされていないだけの完成品がここに居ることがあります。** 実際に、このセッションが"
  say "打っていない \`checkout\` と \`pull\` でブランチが切り替わり、commit 済みの作業が HEAD から"
  say "見えなくなりました。**HEAD だけを見ると「消えた」と読めます。**"
  say ""
fi

# --- worktree -----------------------------------------------------------------
wt="$(git worktree list 2>/dev/null | tail -n +2)"
if [[ -n "${wt}" ]]; then
  say "## 残っている worktree"
  say ""
  printf '%s\n' "${wt}" | sed 's/^/    /'
  say ""
  say "実走の残りです。マージ済みか未確認のものが混ざります。"
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
  say "    (台帳がありません —— まだ一度も回していない)"
  say ""
fi

# --- 検査 ---------------------------------------------------------------------
say "## 最初に確かめること"
say ""
say '```bash'
say "bash scripts/check.sh          # 全項目。落ちたらそこが続き"
say '```'
say ""
say "**緑を額面で受け取らないこと。** このリポジトリでは *検査の側が壊れていた* 事例が4件記録されて"
say "います —— ヘルパ順序3件（bash は定義を**実行したとき**に関数にするので、使う場所の隣に置いた"
say "ヘルパはその上のケースから未定義コマンドになり、実装が正しいのにテストが落ちる）と、偽グリーン1件"
say "（実装を外しても緑のままだった assertion）。**疑わしい緑は、実装を外して赤くなるかで確かめる:**"
say ""
say '```bash'
say 'cp scripts/loop.sh /tmp/keep.sh && <実装を外す> && bash scripts/test-loop.sh; cp /tmp/keep.sh scripts/loop.sh'
say '```'
say ""
say "退避→削除→実行→復元を**1コマンドに**するのは、待ち時間に触ると確認が無効になるためです。"
say ""

# 判断の側は、もう書き写しません。半端なものは PR とその CI に、決めたことは docs/decisions.md に、
# 金と停止理由は台帳に出ます。どれも生きているので、写しを持つと写しの方が古くなります。
