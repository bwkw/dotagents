#!/usr/bin/env bash
# da-adr-figure が、壊れた図の定義を書き出しの前に弾き、文字があふれた図を成功扱いにしないことを確かめる。
# `check` と `html` は依存パッケージ無しで動く（CI は npm i をしない）。
# 書き出し（`build`）の検査は、依存が入っている時だけ走らせる。

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIG="$REPO/skills/da-adr-figure/scripts/figure.mjs"
EXAMPLE="$REPO/skills/da-adr-figure/reference/example.json"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/da-adr-figure.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

node --check "$FIG"

# 同梱の見本は通る
node "$FIG" check "$EXAMPLE" >/dev/null

expect_reject() { # expect_reject <名前> <JSON> <出力に含まれるべき文>
  local name="$1" body="$2" want="$3" out
  printf '%s\n' "$body" > "$TMP/$name.json"
  if out="$(node "$FIG" check "$TMP/$name.json" 2>&1)"; then
    printf 'check が壊れた定義を通した: %s\n' "$name" >&2; exit 1
  fi
  if [[ "$out" != *"$want"* ]]; then
    printf 'check の理由が違う（%s）: 期待「%s」、実際:\n%s\n' "$name" "$want" "$out" >&2; exit 1
  fi
}

ok_card='{"title":"t","parts":[{"tag":"決定","text":"a"},{"tag":"なぜ","points":["b"]}]}'
expect_reject no-title   "{\"cards\":[$ok_card]}" 'title'
expect_reject no-cards   '{"title":"x","cards":[]}' 'cards が空'
expect_reject no-ketsu   '{"title":"x","cards":[{"title":"t","parts":[{"tag":"なぜ","text":"b"}]}]}' '決定'
expect_reject no-naze    '{"title":"x","cards":[{"title":"t","parts":[{"tag":"決定","text":"a"}]}]}' 'なぜ'
expect_reject bad-tag    '{"title":"x","cards":[{"title":"t","parts":[{"tag":"決定","text":"a"},{"tag":"なぜ","text":"b"},{"tag":"メモ","text":"c"}]}]}' 'メモ'
expect_reject alt-no-why '{"title":"x","cards":[{"title":"t","parts":[{"tag":"決定","text":"a"},{"tag":"なぜ","text":"b"},{"tag":"ボツ案","alternatives":[{"name":"案"}]}]}]}' 'result'
expect_reject ragged-tbl '{"title":"x","cards":[{"title":"t","parts":[{"tag":"決定","text":"a"},{"tag":"なぜ","text":"b"},{"table":{"head":["a","b"],"rows":[["1"]]}}]}]}' '列の数'
long91="$(printf 'あ%.0s' {1..91})"
expect_reject long-text   "{\"title\":\"x\",\"cards\":[{\"title\":\"t\",\"parts\":[{\"tag\":\"決定\",\"text\":\"${long91}\"},{\"tag\":\"なぜ\",\"text\":\"b\"}]}]}" '90 字まで'
expect_reject many-points '{"title":"x","cards":[{"title":"t","parts":[{"tag":"決定","text":"a"},{"tag":"なぜ","points":["1","2","3"]}]}]}' '2 個まで'
expect_reject many-alts   '{"title":"x","cards":[{"title":"t","parts":[{"tag":"決定","text":"a"},{"tag":"なぜ","text":"b"},{"tag":"ボツ案","alternatives":[{"name":"1","result":"r"},{"name":"2","result":"r"},{"name":"3","result":"r"}]}]}]}' '2 件まで'
expect_reject many-lead   "{\"title\":\"x\",\"lead\":[\"a\",\"b\"],\"cards\":[$ok_card]}" '1 行まで'

# html は文字を書き換えずに載せ、利用者の文をマークアップとして解釈しない
printf '%s\n' "{\"title\":\"<script>x</script> と \`code\` と **強調**\",\"cards\":[$ok_card]}" > "$TMP/escape.json"
node "$FIG" html "$TMP/escape.json" "$TMP/escape.html" >/dev/null
grep -q '&lt;script&gt;x&lt;/script&gt;' "$TMP/escape.html" || { echo 'html が < をエスケープしていない' >&2; exit 1; }
grep -q '<code>code</code>' "$TMP/escape.html" || { echo 'html がバッククォートを code にしていない' >&2; exit 1; }
grep -q '<b>強調</b>' "$TMP/escape.html" || { echo 'html が ** を太字にしていない' >&2; exit 1; }

# 書き出しは依存がある時だけ確かめる
DEPS="${DA_ADR_FIGURE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/da-adr-figure}"
if [[ -d "$DEPS/node_modules/playwright" ]]; then
  node "$FIG" build "$EXAMPLE" "$TMP/example.png" >/dev/null
  [[ -s "$TMP/example.png" ]] || { echo 'build が PNG を書かなかった' >&2; exit 1; }

  long="$(printf 'あ%.0s' {1..400})"
  printf '%s\n' "{\"title\":\"x\",\"overview\":{\"stages\":[{\"title\":\"s\",\"rows\":[[{\"name\":\"${long}\",\"nowrap\":true}]]}]},\"cards\":[$ok_card]}" > "$TMP/overflow.json"
  if out="$(node "$FIG" build "$TMP/overflow.json" "$TMP/overflow.png" 2>&1)"; then
    echo 'build が文字のあふれた図を成功扱いにした' >&2; exit 1
  fi
  [[ "$out" == *'あふれ'* ]] || { printf 'build のあふれの報告が違う:\n%s\n' "$out" >&2; exit 1; }
else
  echo "skip: 書き出しの検査（依存が無い: ${DEPS}）"
fi

echo "ok"
