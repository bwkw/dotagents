#!/usr/bin/env bash
# da-demo-video の `check` が、壊れたシナリオを撮影の前に弾き続けることを確かめる。
# 壊れたシナリオは数分撮影してから落ち、保存を伴う画面では後始末の前に変更が残る。先に落とすのはそのため。
# `check` は依存パッケージ無しで動く（CI は npm i をしない）。

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO="$REPO/skills/da-demo-video/scripts/demo.mjs"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/da-demo-video.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

node --check "$DEMO"
node --check "$REPO/skills/da-demo-video/scripts/overlay.js"

# 同梱の見本は通る
node "$DEMO" check "$REPO/skills/da-demo-video/reference/example-scenario.mjs" >/dev/null

expect_reject() { # expect_reject <名前> <シナリオ本文> <出力に含まれるべき文>
  local name="$1" body="$2" want="$3" out
  printf '%s\n' "$body" > "$TMP/$name.mjs"
  if out="$(node "$DEMO" check "$TMP/$name.mjs" 2>&1)"; then
    printf 'check が壊れたシナリオを通した: %s\n' "$name" >&2; exit 1
  fi
  if [[ "$out" != *"$want"* ]]; then
    printf 'check の理由が違う（%s）: 期待「%s」、実際:\n%s\n' "$name" "$want" "$out" >&2; exit 1
  fi
}

ok_ready='ready: (p) => p.locator("h1")'
expect_reject dup-id    "export default { url: 'https://example.com/', $ok_ready, scenes: [{ id: 'a', say: 'x' }, { id: 'a', say: 'y' }] };" '重複'
expect_reject no-say    "export default { url: 'https://example.com/', $ok_ready, scenes: [{ id: 'a', say: ' ' }] };" 'say が空'
expect_reject bad-url   "export default { url: 'example.com', $ok_ready, scenes: [{ id: 'a', say: 'x' }] };" 'url'
expect_reject no-ready  "export default { url: 'https://example.com/', scenes: [{ id: 'a', say: 'x' }] };" 'ready'
expect_reject no-scenes "export default { url: 'https://example.com/', $ok_ready, scenes: [] };" 'scenes が空'
expect_reject bad-id    "export default { url: 'https://example.com/', $ok_ready, scenes: [{ id: '../x', say: 'x' }] };" 'ファイル名'

echo "ok"
