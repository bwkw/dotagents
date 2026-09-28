#!/usr/bin/env bash
# `scripts/loop.sh` の halt 理由と `docs/loops.md` の表は、同じ集合でなければならない。
#
#   scripts/verify-halt-docs.sh
#
# 実際に 7 値ぶん黙ってずれていた（駆動系が `ci_pending` や `isolate_round_failed` で止めても、人を送る先の表に
# 行が無い）。表が古くなっても linter が見なければ誰も気づかないので、次の `halt` が同じことを繰り返せないように
# するのがこのファイル。
#
# 2 つがずれる方向は 3 つあるので、主張も 3 つ:
#
#   1. 駆動系が出せるもので表に無いものが無い。壊れていたのはこれ。
#   2. 駆動系が出せないものを説明する行が無い。今の `review_cap` がまさにそれ（台帳の古い行が持っているので
#      わざと残している）なので、例外は黙認せずデータとして*宣言*し、その宣言も現実と照合する。
#   3. 台帳に届かない理由には、そう印が付いている。`halt()` は stderr に書いて HALT を設定するだけで、台帳の
#      `halt_reason` に値を入れるのは `record()` の第 5 引数だけ。記録されずに run を止める理由があり、見出しを
#      文字どおり読んだ人は台帳を見に行って何も見つけない。新しくそうなるものは、後で見つかるのではなく表に書く。
#
# 宣言は `docs/loops.md` のマーカー行に置く（`AGENTS.md` invariant 7 と同じ形: 一覧はデータとして 1 か所にあり、
# このスクリプトはそれで振る舞いを決める）。マーカーを消しても通らない。マーカーが無ければエラー。

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}" || exit 1

LOOP="scripts/loop.sh"
DOC="docs/loops.md"
fails=0
err() { printf '\033[31m✗\033[0m %s\n' "$*"; fails=$((fails + 1)); }
ok() { printf '\033[32m✓\033[0m %s\n' "$*"; }

for f in "$LOOP" "$DOC"; do
  [[ -f "$f" ]] || { err "$f が無い"; exit 1; }
done

# --- 駆動系が出せるもの ------------------------------------------------------------------
# コメント行は除く。このファイルの地の文も loop.sh のコメントもこれらの値の半分を名指ししていて、コメントを
# 数える grep こそ、このスクリプトが防ぎたい失敗の形。
node -e '
  const fs = require("fs");
  const lines = fs.readFileSync(process.argv[1], "utf8").split("\n").filter((l) => !/^\s*#/.test(l));
  const src = lines.join("\n");
  const halted = new Set([...src.matchAll(/record\s+\S+[^\n]*?halted ([a-z_]+)/g)].map((m) => m[1]));
  const emitted = new Set([...src.matchAll(/^\s*halt ([a-z_]+)[\s"]/gm)].map((m) => m[1]));
  const stderrOnly = [...emitted].filter((r) => !halted.has(r)).sort();
  const all = [...new Set([...halted, ...emitted])].sort();
  process.stdout.write(JSON.stringify({ all, stderrOnly }));
' "$LOOP" > /tmp/.halt-sets.$$ || { err "$LOOP から halt 理由を読み出せなかった"; exit 1; }

read -r ALL STDERR_ONLY < <(node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.stdout.write(s.all.join(",") + " " + (s.stderrOnly.join(",") || "-"));
' "/tmp/.halt-sets.$$")
rm -f "/tmp/.halt-sets.$$"

# --- 表が記述しているもの -----------------------------------------------------------------
# `dotagents:halt-table` マーカーが導く表だけに絞り、ファイル中のすべての表の行は見ない。文書全体で
# `^| \`name\`` を読むと、別の表の行（`size`、`unverified`、`claude`）を幻の理由として報告した。狼少年のチェックは
# 消されるので、範囲は推測せず宣言する。最初のセルには理由が複数入りうる（`one_way` / `pr_cap` が 1 行を共有）ので、
# その中の名前はすべて数える。
DOCUMENTED="$(node -e '
  const fs = require("fs");
  const lines = fs.readFileSync(process.argv[1], "utf8").split("\n");
  const names = new Set();
  // `pending` は、Markdown ではマーカーと表の間に空行が入るため。その空行を表の終わりと読むと行が 0 件になり、
  // すべての理由を未記述と報告する —— 間違った理由で大声を出すチェックも、壊れたチェック。
  let inTable = false, pending = false;
  for (const line of lines) {
    if (line.includes("dotagents:halt-table")) { pending = true; continue; }
    if (pending) {
      if (line.trim() === "") continue;
      if (!line.startsWith("|")) { pending = false; continue; }
      pending = false; inTable = true;
    }
    if (!inTable) continue;
    if (!line.startsWith("|")) { inTable = false; continue; }
    const cell = line.slice(1).split("|")[0];
    for (const m of cell.matchAll(/`([a-z_]+)`/g)) names.add(m[1]);
  }
  process.stdout.write([...names].sort().join(","));
' "$DOC")"
[[ -n "$DOCUMENTED" ]] || err "$DOC に '<!-- dotagents:halt-table -->' の印が付いた表が無い —— 範囲が宣言されていないので、このチェックには比べる相手が無い"

marker() { # <marker-name> -- 宣言された一覧。行が無ければ空文字列
  grep -oE "<!-- dotagents:$1[^>]*-->" "$DOC" | head -1 \
    | sed -E "s/<!-- dotagents:$1 *//; s/ *-->//" | tr -s ' ' ',' | sed 's/^,//; s/,$//'
}
HISTORICAL_LINE="$(grep -c "dotagents:halt-historical" "$DOC")"
STDERR_LINE="$(grep -c "dotagents:halt-stderr-only" "$DOC")"
HISTORICAL="$(marker halt-historical)"
DECLARED_STDERR="$(marker halt-stderr-only)"

# マーカーは効いている: 行が無いと主張 2 と 3 は何とも比べずに緑のチェックを出す。`AGENTS.md` invariant 7 に、
# 同じ罠に実際に掛かった記録がある。
(( HISTORICAL_LINE >= 1 )) || err "$DOC に '<!-- dotagents:halt-historical ... -->' の行が無い —— 無いと、駆動系がもう出せない理由の行が気づかれずに通る"
(( STDERR_LINE >= 1 )) || err "$DOC に '<!-- dotagents:halt-stderr-only ... -->' の行が無い —— 無いと、台帳に届かない理由が届くものとして記述される"

list_diff() { # <csv-a> <csv-b> -> a にあって b に無いもの
  node -e '
    const a = (process.argv[1] || "").split(",").filter((x) => x && x !== "-");
    const b = new Set((process.argv[2] || "").split(",").filter(Boolean));
    process.stdout.write(a.filter((x) => !b.has(x)).join(" "));
  ' "$1" "$2"
}

# 1. 駆動系が出せるもので、記述されていないものが無い。
missing="$(list_diff "$ALL" "$DOCUMENTED")"
if [[ -z "$missing" ]]; then
  ok "駆動系が出せる halt 理由はすべて $DOC に行がある"
else
  err "次の halt 理由は $DOC に行が無い: $missing"
fi

# 2. 理由をでっち上げる行が無い —— 台帳の古い行のために残すと宣言したものを除く。
phantom="$(list_diff "$DOCUMENTED" "$ALL,$HISTORICAL")"
if [[ -z "$phantom" ]]; then
  ok "駆動系が出せない停止を説明する行は無い（historical と宣言: ${HISTORICAL:-なし}）"
else
  err "次の行は $LOOP が決して出さない理由を説明していて、historical とも宣言されていない: $phantom"
fi

# 2b. 宣言も現実と照合する: *戻ってきた*理由は例外から外さないと、起きうるのに起きないと表が言い続ける。
stale_historical="$(node -e '
  const declared = (process.argv[1] || "").split(",").filter(Boolean);
  const all = new Set((process.argv[2] || "").split(",").filter(Boolean));
  process.stdout.write(declared.filter((x) => all.has(x)).join(" "));
' "$HISTORICAL" "$ALL")"
if [[ -z "$stale_historical" ]]; then
  ok "historical の宣言は、今も起きえない理由だけを記述している"
else
  err "historical と宣言されているが、$LOOP がまた出している: $stale_historical"
fi

# 3. 台帳に届かずに run を止める理由は、宣言されたものとちょうど一致する。
if [[ "$(list_diff "$STDERR_ONLY" "$DECLARED_STDERR")" == "" \
   && "$(list_diff "$DECLARED_STDERR" "$STDERR_ONLY")" == "" ]]; then
  ok "台帳に届かない理由は宣言されていて、正確（${STDERR_ONLY//,/ }）"
else
  err "台帳に届かない理由と宣言が食い違っている。
    $LOOP が記録せずに止めるもの: ${STDERR_ONLY//,/ }
    $DOC の宣言:                   ${DECLARED_STDERR//,/ }"
fi

echo
if (( fails )); then
  printf '\033[31m%d 件失敗\033[0m\n' "$fails"
  exit 1
fi
printf '\033[32m✓ %s と %s は、すべての halt 理由で一致している\033[0m\n' "$LOOP" "$DOC"
