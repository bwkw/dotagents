#!/usr/bin/env bash
# da-review が、ホストが持つ入れ物で単独の 1 枚の概要ページを出し続けることを確かめる。
# 入れ物はホストごとに選び、6 つの節は変えない。入れ物を 1 つに決め打つと、無いホストで黙って何も出なくなる。

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$REPO/skills/da-review/SKILL.md"
DIFF="$REPO/skills/da-review/reference/diff.md"
REFERENCE="$REPO/skills/da-review/reference/overview-artifact.md"

require() {
  local file="$1" pattern="$2" explanation="$3"
  if ! grep -qF -- "$pattern" "$file"; then
    printf 'da-review の概要ページの指示が欠けている: %s\n' "$explanation" >&2
    exit 1
  fi
}

# スキルにその段階があり、参照ファイルを指している。
require "$SKILL" '${CLAUDE_SKILL_DIR}/reference/diff.md' "差分の経路"
require "$DIFF" "## Step 5. 1 枚の概要ページ" "概要を出す専用の段階"
require "$DIFF" "overview-artifact.md" "概要の中身を定める参照ファイル"
require "$DIFF" "Claude Code では Artifact、Cursor では Canvas" "ホストごとの入れ物"

# どの入れ物も名前が出ていて、黙って何も出さないホストが無い。
require "$REFERENCE" "Claude Code" "Claude Code の入れ物"
require "$REFERENCE" "Cursor" "Cursor の入れ物"
require "$REFERENCE" "どちらも無い場合" "どちらも無い時の代わり"

# ページは変更についてのもので、層の報告から外した正直さの行を載せる。
require "$REFERENCE" "何ができるようになったか" "変更で何ができるようになったか"
require "$REFERENCE" "既存との関係" "既存のものとの関係"
require "$REFERENCE" "決まっていないこと" "決まっていないことの洗い出しがページに載る"
require "$REFERENCE" "🔎" "読んだものと推測したものの区別"
require "$REFERENCE" "🔬" "除外したもの（選び方を後から検証できるように）"

printf '✓ da-review はこのホストの入れ物で 1 枚の概要ページを求める\n'

# fork に同じ PR 番号がある時も、下書きで確認したホスト・リポジトリ・head にだけ投稿する。
COMMENTS="$REPO/skills/_shared/pr-comments.md"
require "$COMMENTS" '--hostname "$HOST"' "指定した PR のホスト"
require "$COMMENTS" 'repos/$REPO/pulls/$NUMBER/reviews' "指定した PR のリポジトリと番号"
require "$COMMENTS" '"commit_id"' "下書きを確認した head"
