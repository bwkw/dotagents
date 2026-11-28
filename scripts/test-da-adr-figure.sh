#!/usr/bin/env bash
# x-present の ADR 図作成が、要約の無い図・要点を詰め込みすぎた図・壊れた定義を書き出しの前に弾き、文字があふれた図を成功扱いにしないことを確かめる。
# `check` と `html` は依存パッケージ無しで動く（CI は npm i をしない）。
# 書き出し（`build`）の検査は、依存が入っている時だけ走らせる。

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIG="$REPO/skills/x-present/figure/scripts/figure.mjs"
EXAMPLE="$REPO/skills/x-present/figure/reference/example.json"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/da-adr-figure.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

[[ -f "$FIG" ]] || { echo 'x-present から図の描画器を開けません' >&2; exit 1; }
# 動画用の依存を入れない環境でも ADR の図を生成できる。
export DA_DEMO_VIDEO_HOME="$TMP/video-not-installed"
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

ok_card='{"title":"t","parts":[{"tag":"決定","text":"a"},{"tag":"なぜ","text":"b"}]}'
sum='"summary":["要約"]'
expect_reject no-title   "{${sum},\"cards\":[$ok_card]}" 'title'
expect_reject no-summary "{\"title\":\"x\",\"cards\":[$ok_card]}" 'summary'
expect_reject many-summary "{\"title\":\"x\",\"summary\":[\"a\",\"b\",\"c\",\"d\"],\"cards\":[$ok_card]}" '3 行まで'
expect_reject no-cards   "{\"title\":\"x\",${sum},\"cards\":[]}" 'cards が空'
expect_reject many-cards "{\"title\":\"x\",${sum},\"cards\":[$(printf '%s,' $(for i in $(seq 1 10); do echo "$ok_card"; done))$ok_card]}" '10 枚まで'
# ADR の判断が 8 つなら、カード 8 枚を通す
node "$FIG" check <(printf '%s\n' "{\"title\":\"x\",${sum},\"cards\":[$(printf '%s,' $(for i in $(seq 1 7); do echo "$ok_card"; done))$ok_card]}") >/dev/null || { echo 'check がカード 8 枚を弾いた' >&2; exit 1; }
expect_reject no-ketsu   "{\"title\":\"x\",${sum},\"cards\":[{\"title\":\"t\",\"parts\":[{\"tag\":\"なぜ\",\"text\":\"b\"}]}]}" '決定'
expect_reject no-naze    "{\"title\":\"x\",${sum},\"cards\":[{\"title\":\"t\",\"parts\":[{\"tag\":\"決定\",\"text\":\"a\"}]}]}" 'なぜ'
expect_reject bad-tag    "{\"title\":\"x\",${sum},\"cards\":[{\"title\":\"t\",\"parts\":[{\"tag\":\"決定\",\"text\":\"a\"},{\"tag\":\"なぜ\",\"text\":\"b\"},{\"tag\":\"メモ\",\"text\":\"c\"}]}]}" 'メモ'
expect_reject alt-no-why "{\"title\":\"x\",${sum},\"cards\":[{\"title\":\"t\",\"parts\":[{\"tag\":\"決定\",\"text\":\"a\"},{\"tag\":\"なぜ\",\"text\":\"b\"},{\"tag\":\"ボツ案\",\"alternatives\":[{\"name\":\"案\"}]}]}]}" 'result'
expect_reject ragged-tbl "{\"title\":\"x\",${sum},\"cards\":[{\"title\":\"t\",\"parts\":[{\"tag\":\"決定\",\"text\":\"a\"},{\"tag\":\"なぜ\",\"text\":\"b\"},{\"table\":{\"head\":[\"a\",\"b\"],\"rows\":[[\"1\"]]}}]}]}" '列の数'
long71="$(printf 'あ%.0s' {1..71})"
expect_reject long-text   "{\"title\":\"x\",${sum},\"cards\":[{\"title\":\"t\",\"parts\":[{\"tag\":\"決定\",\"text\":\"${long71}\"},{\"tag\":\"なぜ\",\"text\":\"b\"}]}]}" '70 字まで'
long51="$(printf 'あ%.0s' {1..51})"
expect_reject long-title "{\"title\":\"x\",${sum},\"cards\":[{\"title\":\"${long51}\",\"parts\":[{\"tag\":\"決定\",\"text\":\"a\"},{\"tag\":\"なぜ\",\"text\":\"b\"}]}]}" '50 字まで'
expect_reject many-points "{\"title\":\"x\",${sum},\"cards\":[{\"title\":\"t\",\"parts\":[{\"tag\":\"決定\",\"text\":\"a\"},{\"tag\":\"なぜ\",\"points\":[\"1\",\"2\"]}]}]}" '1 個まで'
expect_reject many-alts   "{\"title\":\"x\",${sum},\"cards\":[{\"title\":\"t\",\"parts\":[{\"tag\":\"決定\",\"text\":\"a\"},{\"tag\":\"なぜ\",\"text\":\"b\"},{\"tag\":\"ボツ案\",\"alternatives\":[{\"name\":\"1\",\"result\":\"r\"},{\"name\":\"2\",\"result\":\"r\"}]}]}]}" '1 件まで'

# スキルはリンク経由で配られる。リンクのパスから呼んでも、黙って何もせずに終わらない
ln -s "$REPO/skills/x-present" "$TMP/linked-skill"
out="$(node "$TMP/linked-skill/figure/scripts/figure.mjs" check "$EXAMPLE" 2>&1)" || true
[[ "$out" == ok* ]] || { printf 'リンク経由の check が何もしなかった: 「%s」\n' "$out" >&2; exit 1; }

# html は文字を書き換えずに載せ、利用者の文をマークアップとして解釈しない
printf '%s\n' "{\"title\":\"<script>x</script> と \`code\` と **強調**\",${sum},\"cards\":[$ok_card]}" > "$TMP/escape.json"
node "$FIG" html "$TMP/escape.json" "$TMP/escape.html" >/dev/null
grep -q '&lt;script&gt;x&lt;/script&gt;' "$TMP/escape.html" || { echo 'html が < をエスケープしていない' >&2; exit 1; }
grep -q '<code>code</code>' "$TMP/escape.html" || { echo 'html がバッククォートを code にしていない' >&2; exit 1; }
grep -q '<b>強調</b>' "$TMP/escape.html" || { echo 'html が ** を太字にしていない' >&2; exit 1; }

# 要約は 1 行目が結論で、2 行目以降と見た目を分ける
printf '%s\n' "{\"title\":\"x\",\"summary\":[\"結論\",\"補足\"],\"cards\":[$ok_card]}" > "$TMP/summary.json"
node "$FIG" html "$TMP/summary.json" "$TMP/summary.html" >/dev/null
grep -q '<li class="main">結論</li><li>補足</li>' "$TMP/summary.html" || { echo 'html が要約の 1 行目を結論として分けていない' >&2; exit 1; }

# カードは 3 枚までなら 1 列に並べ、空いた枠を作らない
printf '%s\n' "{\"title\":\"x\",${sum},\"cards\":[$ok_card,$ok_card,$ok_card]}" > "$TMP/three.json"
node "$FIG" html "$TMP/three.json" "$TMP/three.html" >/dev/null
grep -q 'grid-template-columns:repeat(3,1fr)' "$TMP/three.html" || { echo 'html がカード 3 枚を 1 列に並べていない' >&2; exit 1; }

# 書き出しは依存がある時だけ確かめる
DEPS="${DA_ADR_FIGURE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/da-adr-figure}"
if [[ -d "$DEPS/node_modules/playwright" ]]; then
  node "$FIG" build "$EXAMPLE" "$TMP/example.png" >/dev/null
  [[ -s "$TMP/example.png" ]] || { echo 'build が PNG を書かなかった' >&2; exit 1; }

  long="$(printf 'あ%.0s' {1..400})"
  printf '%s\n' "{\"title\":\"x\",${sum},\"overview\":{\"stages\":[{\"title\":\"s\",\"rows\":[[{\"name\":\"${long}\",\"nowrap\":true}]]}]},\"cards\":[$ok_card]}" > "$TMP/overflow.json"
  if out="$(node "$FIG" build "$TMP/overflow.json" "$TMP/overflow.png" 2>&1)"; then
    echo 'build が文字のあふれた図を成功扱いにした' >&2; exit 1
  fi
  [[ "$out" == *'あふれ'* ]] || { printf 'build のあふれの報告が違う:\n%s\n' "$out" >&2; exit 1; }
else
  echo "skip: 書き出しの検査（依存が無い: ${DEPS}）"
fi

echo "ok"
