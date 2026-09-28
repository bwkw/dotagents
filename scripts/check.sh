#!/usr/bin/env bash
# このリポジトリの検査を 1 コマンドで全部回す。
#
#   scripts/check.sh          全部を実行
#   scripts/check.sh --fast   振る舞いのスイートを飛ばす（構文と lint だけ）
#
# 検査器が複数あるのは、確かめる対象も落ちる理由も違うため。覚えるものを 1 つにするためにこれがある。

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

FAST=0
[[ "${1:-}" == "--fast" ]] && FAST=1

# 色は人が見ているときだけ。無人のログやファイルへの取り込みでは ANSI は雑音と破損になる。
if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then
  c_green=''; c_red=''; c_dim=''; c_off=''
else
  c_green=$'\033[32m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
fi
failed=()

# $TMPDIR に従う（gate hook と同じ）。誰でも書けるディレクトリ下の予測できる名前は `>` のシンボリック
# リンク追従の標的になる。BSD mktemp は `-t x` を接頭辞と扱い GNU は XXXXXX を要求するので、完全な型で書く。
LOG="$(mktemp "${TMPDIR:-/tmp}/dotagents-check.XXXXXX")" || { echo "mktemp に失敗した" >&2; exit 1; }
trap 'rm -f "$LOG"' EXIT INT TERM

step() { # step <label> <command...>
  local label="$1"; shift
  printf '%s── %s%s\n' "$c_dim" "$label" "$c_off"
  if "$@" >"$LOG" 2>&1; then
    printf '%s✓%s %s\n' "$c_green" "$c_off" "$label"
  else
    printf '%s✗%s %s\n' "$c_red" "$c_off" "$label"
    # `tail -25` ではなく先頭と末尾。長い出力の最初のエラーが本当に要るもので、残りはたいていその帰結。
    if [[ "$(wc -l < "$LOG")" -gt 40 ]]; then
      head -20 "$LOG" | sed 's/^/    /'
      printf '    %s...（%s 行省略）...%s\n' "$c_dim" "$(( $(wc -l < "$LOG") - 40 ))" "$c_off"
      tail -20 "$LOG" | sed 's/^/    /'
      # スイートは assertion ごとに ✓/✗ を出すので、失敗は省略した中ほどに埋もれる。先頭・末尾は残した
      # うえで、失敗も一覧にする。
      if grep -q '✗' "$LOG"; then
        printf '    %s失敗:%s\n' "$c_red" "$c_off"
        # 失敗の次の行にはスイートの `detail`（理由を示す実際の出力）が来るので、それも出す。
        grep -A2 '✗' "$LOG" | sed 's/^/      /'
      fi
    else
      sed 's/^/    /' "$LOG"
    fi
    failed+=("$label")
  fi
  : > "$LOG"
}

syntax() {
  local f
  for f in scripts/*.sh hooks/*.sh; do bash -n "$f" || return 1; done
  # macOS の bash は 3.2。以下の構文は CI では通り、手元で落ちる。
  # このファイルは除外する。下のパターン自体を書いているので、自分に当たって偽の失敗になる。
  ! grep -rqE --exclude=check.sh \
    '^[^#]*\b(mapfile|readarray)\b|declare -A|\$\{[a-zA-Z_]+\^\^\}|\$\{[a-zA-Z_]+,,\}' scripts/ hooks/ || return 1

  # UTF-8 ロケールの bash 3.2 は、波括弧なしの変数の直後の全角文字を変数名に取り込み、存在しない名前を
  # 引いて `unbound variable` で落ちる。macOS の CI でだけ落ちるので、波括弧で囲む。
  #
  # `grep -P` ではなく perl: macOS の BSD grep に -P が無い。コメントはこの説明自体に当たるので飛ばす。
  # `close ARGV if eof` でファイルごとに $. を戻す。戻さないと行番号が累積して意味をなさない。
  local mb
  mb="$(perl -ne 'close ARGV if eof; next if /^\s*#/; print "$ARGV:$.\n" if /\$[A-Za-z_]\w*[^\x00-\x7F]/' \
        scripts/*.sh hooks/*.sh 2>/dev/null)"
  if [[ -n "$mb" ]]; then
    printf '変数展開の直後にマルチバイト文字がある。${var} と波括弧で囲むこと:\n%s\n' "$mb"
    return 1
  fi
  return 0
}

# リポジトリ全体の書き換えはシンボリックリンクを飛ばすこと。`perl -pi` はリンクを通常ファイルに置き換え、
# CLAUDE.md を黙って壊す。`git ls-files` の代わりにこれでファイル一覧を作る。
#
#   for f in $(scripts/check.sh --rewritable); do perl -pi -e '...' "$f"; done
rewritable() { git ls-files | while read -r f; do [[ -f "$f" && ! -L "$f" ]] && printf '%s\n' "$f"; done; }
[[ "${1:-}" == "--rewritable" ]] && { rewritable; exit 0; }

# 配るスクリプトはすべて実行可能であること。スイートは `bash <file>` で呼ぶので +x が落ちても全部通り、
# README の手順の `scripts/gate.sh arm` だけが permission denied で落ちる。新しいファイルに書いて元へ
# 改名する書き換えで 644 になる。
executable_bits() {
  local bad
  bad="$(git ls-files -s scripts/*.sh hooks/*.sh | awk '$1!="100755"{print $4}')"
  [[ -z "$bad" ]] && return 0
  printf '実行可能になっていない（mode は 100755 であること）:\n%s\n' "$bad"
  return 1
}

symlink_intact() {
  # Claude Code は AGENTS.md を読まないので、CLAUDE.md がリンクでなくなると常時読み込み層が黙ってずれる。
  [[ "$(git ls-files -s CLAUDE.md | awk '{print $1}')" == "120000" ]] \
    && [[ "$(readlink CLAUDE.md)" == "AGENTS.md" ]]
}

step "シェル構文と bash 4 構文の不使用" syntax
step "CLAUDE.md が AGENTS.md へのリンクのまま" symlink_intact
step "配るスクリプトがすべて実行可能" executable_bits
step "スキルの lint（不変条件、予算、エージェント、上書き範囲）" ./scripts/verify-skills.sh
step "da-review-all の概要出力の契約" ./scripts/test-da-review-all-overview.sh
step "da-demo-video が壊れたシナリオを撮影前に弾く" ./scripts/test-da-demo-video.sh
# 意図して高速レーンに置く。静的な突き合わせでミリ秒で済み、守る対象はドキュメントだけの変更（振る舞いの
# スイートを飛ばす変更そのもの）で編集される。
step "停止理由: loop.sh と docs/loops.md が一致" ./scripts/verify-halt-docs.sh

if (( ! FAST )); then
  # インストーラのスイートは刈り取りを試すため、このリポジトリ内でスキルを作って消す。そこで前後の
  # ツリーを比べる。何か残すスイートは、次のループの反復でその残骸を commit させる。
  tree_before="$(git status --porcelain 2>/dev/null)"

  step "verify-gate の振る舞い"    ./scripts/test-verify-gate.sh
  step "lint-hook と lint の範囲" ./scripts/test-lint-hook.sh
  step "インストーラの振る舞い"      ./scripts/test-setup.sh
  step "ループ駆動の振る舞い"    ./scripts/test-loop.sh
  step "人の入力を待たない" ./scripts/test-non-interactive.sh

  tree_clean() { [[ "$(git status --porcelain 2>/dev/null)" == "$tree_before" ]]; }
  step "スイートが作業ツリーを元のまま残した" tree_clean
fi

echo
if (( ${#failed[@]} )); then
  printf '%s%d 件失敗:%s %s\n' "$c_red" "${#failed[@]}" "$c_off" "${failed[*]}"
  exit 1
fi
printf '%s✓ すべての検査に合格%s%s\n' "$c_green" "$( (( FAST )) && printf '（fast: 振る舞いのスイートは省略）')" "$c_off"
