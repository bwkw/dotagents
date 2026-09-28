#!/usr/bin/env bash
# Stop ゲートのテスト。閉じた環境で動く: 使い捨ての git リポジトリとプロファイルだけで、実ビルドはしない。
#
# ゲートは閉じて失敗しなければならない唯一の部品なので、振る舞いを前提にせず断言する。
# 下のケースはどれも実際に起きた失敗の形: アイドル中に発火する、知らないリポジトリのコマンドを
# 推測する、「ユーザーに実行を頼んだ」を証拠として受け取る。

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hooks/dotagents-verify-gate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
c_red=$'\033[31m'; c_green=$'\033[32m'; c_off=$'\033[0m'

check() { # check <name> <expected-exit> <actual-exit>
  if [[ "$2" == "$3" ]]; then
    printf '%s✓%s %s\n' "$c_green" "$c_off" "$1"; pass=$((pass+1))
  else
    printf '%s✗%s %s（期待した終了コード %s、実際は %s）\n' "$c_red" "$c_off" "$1" "$2" "$3"; fail=$((fail+1))
  fi
}

# 下にある `&& { printf ...; pass=... } || { printf ...; fail=... }` の形は古い書き方。新しい断言は ok/no を使う。
ok() { printf '%s✓%s %s\n' "$c_green" "$c_off" "$1"; pass=$((pass+1)); }
no() { printf '%s✗%s %s\n' "$c_red"   "$c_off" "$1"; fail=$((fail+1)); }

# --- 使い捨てのリポジトリ -------------------------------------------------------
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" remote add origin git@github.com:example/scratch.git
echo hello > "$REPO/a.txt"
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm init

# --- 使い捨てのプロファイル -----------------------------------------------------
PROFILES="$TMP/profiles"
mkdir -p "$PROFILES"
write_profile() { cat > "$PROFILES/scratch.json"; }

GATE="$TMP/gate"
GATE_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gate.sh"
# 本物のスクリプトで arm する。自作のヘルパーで真似ると、何も arm できないままテストだけが通る。
arm()   { DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" arm "$REPO" >/dev/null; }
disarm(){ DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" disarm "$REPO" >/dev/null 2>&1 || true; rm -rf "$GATE"; }

# hook の trace() は $GATE_DIR が無いと何もせず戻り、下のいくつかのケースは `rm -rf "$GATE"` する。
# だからログが無いのは「何もトレースされていない」という正当な答えで、エラーではない。
trace_has() { grep -q "$1" "$GATE/trace.log" 2>/dev/null; }

# $REPO のリンクされた worktree。ブランチ名は検査に関係なく、--detach なら後のケースと衝突しない。
mk_worktree() { # mk_worktree <name> -> worktree のパスを出す。失敗なら非 0
  local p="$TMP/wt-$1"
  git -C "$REPO" worktree add -q --detach "$p" >/dev/null 2>&1 || return 1
  printf '%s' "$p"
}

# ACTIVE がこのリポジトリを指す arm 済みディレクトリ。slug は解釈しない約束なので、テストも導出せず、
# hook と同じく中身で探す。検査対象の仕組みをテストで再実装すると、壊れていても通ってしまう。
gate_dir_for() { # gate_dir_for <repo>
  local want f
  want="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$1")"
  for f in "$GATE"/*/ACTIVE; do
    [[ -f "$f" ]] || continue
    [[ "$(cat "$f")" == "$want" ]] && { dirname "$f"; return 0; }
  done
  return 1
}

invoke_at() { # invoke_at <dir> [extra-json-fields]
  printf '{"cwd":"%s"%s}' "$1" "${2:+,$2}" \
    | DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" bash "$HOOK" 2>"$TMP/stderr"
  echo $?
}

invoke() { invoke_at "$REPO"; }

# Cursor の stop hook は {status, loop_count} だけで cwd を送らないので、hook は $PWD に頼る。
# Cursor は止められないので、stdout に {"followup_message": ...} で答える。
invoke_cursor() { # invoke_cursor [loop_count]
  printf '{"status":"completed","loop_count":%s}' "${1:-0}" \
    | (cd "$REPO" && DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" \
        bash "$HOOK" 2>"$TMP/stderr" >"$TMP/stdout")
  echo $?
}

echo "verify-gate"
echo

# 1. sentinel 無し: arm されていないセッションは、リポジトリの状態にかかわらず止めない。
disarm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "always-fails", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
check "sentinel が arm されていない -> 発火しない" 0 "$(invoke)"

# 2. arm 済みでチェックが通る。
arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "ok", "cmd": "true", "gate": true, "agent_may_run": true } ] }
JSON
check "arm 済み、チェックが通る -> 終了を許す" 0 "$(invoke)"

# 3. arm 済みでチェックが落ちる。これが本題。
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "echo 'type error on line 4'; false", "gate": true, "agent_may_run": true } ] }
JSON
check "arm 済み、チェックが落ちる -> 止める" 2 "$(invoke)"
grep -q "boom" "$TMP/stderr" && grep -q "type error on line 4" "$TMP/stderr" \
  && { printf '%s✓%s   落ちたチェックとその出力を報告する\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   stderr にチェック ID か出力が無い\n' "$c_red" "$c_off"; fail=$((fail+1)); }

# 4. 2 回連続の失敗で「直せ」から「止めて /clear」に上がる。
invoke >/dev/null
grep -qi "clear" "$TMP/stderr" \
  && { printf '%s✓%s   2 回目の失敗で /clear に上がる\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   2 回目の失敗で上がらない\n' "$c_red" "$c_off"; fail=$((fail+1)); }

# 5. gate:false は、どれだけ落ちても止めない。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "advisory", "cmd": "false", "gate": false, "agent_may_run": true } ] }
JSON
check "ゲート対象外のチェックが落ちる -> 終了を許す" 0 "$(invoke)"

# 6. プロファイルの無いリポジトリ: コマンドの根拠が無いので、でっち上げない。
write_profile <<'JSON'
{ "match": { "remote": "somebody/else" },
  "checks": [ { "id": "x", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
check "一致するプロファイルが無い -> 推測せず終了を許す" 0 "$(invoke)"

# 7. 結果の記録が無い委任チェックは止める。でないと「ユーザーに頼んだ」が抜け道になる。
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "typecheck", "cmd": "true", "gate": true, "agent_may_run": false,
                "delegate_reason": "needs 8GB of heap" } ] }
JSON
check "委任チェックが未確認 -> 止める" 2 "$(invoke)"
grep -q "8GB of heap" "$TMP/stderr" \
  && { printf '%s✓%s   委任の理由を示す\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   stderr に委任の理由が無い\n' "$c_red" "$c_off"; fail=$((fail+1)); }

# 8. 記録すれば止めなくなる。
DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" record typecheck "$REPO" >/dev/null
check "委任チェックが確認済み -> 終了を許す" 0 "$(invoke)"

# 9. 変更が無いときの {files} は何もしない。失敗ではない。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "unit", "cmd": "test -n '{files}'", "gate": true,
                "agent_may_run": true, "scope": "changed" } ] }
JSON
check "scope:changed で作業ツリーがきれい -> 飛ばして終了を許す" 0 "$(invoke)"

# 10. ...実際に変更があれば実行する。
echo modified >> "$REPO/a.txt"
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "unit", "cmd": "echo files={files}; false", "gate": true,
                "agent_may_run": true, "scope": "changed" } ] }
JSON
check "scope:changed で作業ツリーに変更あり -> 実行し、止めうる" 2 "$(invoke)"
grep -q "files=a.txt" "$TMP/stderr" \
  && { printf '%s✓%s   変更したファイルを差し込む\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   {files} が差し込まれていない（stderr: %s）\n' "$c_red" "$c_off" "$(tr '\n' ' ' <"$TMP/stderr")"; fail=$((fail+1)); }

echo
echo "verify-gate — 故障時は閉じて失敗する"
echo

# パスに空白を含むリポジトリ。空白区切りでフィールドを渡すと cwd が切れ、git が落ち、ゲートが黙って開く。
SPACED="$TMP/my project"
mkdir -p "$SPACED"
git -C "$SPACED" init -q
git -C "$SPACED" remote add origin git@github.com:example/scratch.git
echo x > "$SPACED/a.txt"
git -C "$SPACED" add -A
git -C "$SPACED" -c user.email=t@t -c user.name=t commit -qm init

rm -rf "$GATE"
DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" arm "$SPACED" >/dev/null
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
spaced_exit="$(printf '{"cwd":"%s","hook_event_name":"Stop"}' "$SPACED" \
  | DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" bash "$HOOK" 2>/dev/null; echo $?)"
check "パスに空白を含むリポジトリ -> それでも止める" 2 "$spaced_exit"
DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" disarm "$SPACED" >/dev/null

# node が無ければ通さず止める。PATH を絞り、bash は絶対パスで呼ぶ。
rm -rf "$GATE"; arm
# /usr/bin:/bin には cat・sed・git はあるが、パッケージマネージャー配下の node は無い。
if PATH=/usr/bin:/bin command -v node >/dev/null 2>&1; then
  printf '%s!%s この環境では node が /usr/bin:/bin にある -- node 不在のケースを飛ばす\n' "$c_red" "$c_off"
else
  node_exit="$(printf '{"cwd":"%s","hook_event_name":"Stop"}' "$REPO" \
    | env PATH=/usr/bin:/bin DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" \
      /bin/bash "$HOOK" 2>/dev/null; echo $?)"
  check "node が使えない -> 止める（開いて失敗しない）" 2 "$node_exit"
fi

# プロファイルのディレクトリが消えた（リポジトリを移した）ら止める。
moved_exit="$(printf '{"cwd":"%s","hook_event_name":"Stop"}' "$REPO" \
  | DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$TMP/gone" bash "$HOOK" 2>/dev/null; echo $?)"
check "プロファイルのディレクトリが無い -> 止める" 2 "$moved_exit"

# 壊れたプロファイルで探索が止まると、readdir 順で後ろのプロファイルが隠れ、正しいプロファイルのリポジトリでゲートが開く。
rm -rf "$GATE"; arm
printf '{ "match": { "remote": "x" }, "checks": [ ,,, ] }' > "$PROFILES/aaa-broken.json"
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
check "壊れたプロファイルが、一致するプロファイルを隠さない" 2 "$(invoke)"

# ...ただし一致が無く、読めないものがあるなら、検査したとは言えない。
write_profile <<'JSON'
{ "match": { "remote": "nobody/else" },
  "checks": [ { "id": "x", "cmd": "true", "gate": true, "agent_may_run": true } ] }
JSON
check "一致なし + 壊れたプロファイル -> 該当なしと決めつけず止める" 2 "$(invoke)"
grep -q 'aaa-broken.json' "$TMP/stderr" \
  && { printf '%s✓%s   壊れたファイルを名指す\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   壊れたファイルを名指さない\n' "$c_red" "$c_off"; fail=$((fail+1)); }
rm -f "$PROFILES/aaa-broken.json"

# --- match.remote: owner に依存せず、リストも取る ------------------------------
# owner を含む部分文字列だけだと、fork や別アカウントでの clone でプロファイルが引けず、ゲートが黙って通る。
# 偽の origin は git@github.com:example/scratch.git なので、'/scratch' だけのプロファイルが一致しなければ
# ならない。fork でも残る書き方で、https の URL にも当たる。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "/scratch" },
  "checks": [ { "id": "x", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
check "owner 無しでリポジトリを名指すプロファイルが一致する（fork でも効く）" 2 "$(invoke)"

# リストはどれか 1 つが当たれば一致する。1 つのリポジトリが複数の名前で届く場合のため。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": ["nobody/else", "example/scratch"] },
  "checks": [ { "id": "x", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
check "remote のリストはどれか 1 つで一致する" 2 "$(invoke)"

# ...そして何にも当たらないリストは一致しない。配列を文字列に連結して受けると、どのリストもどの remote にも
# 当たり、厳しく見えて緩いゲートになる。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": ["nobody/else"] },
  "checks": [ { "id": "x", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
check "何にも当たらないリストはプロファイルを引かない" 0 "$(invoke)"

# シェルのメタ文字を含むファイル名を実行しない。引用なしの {files} と eval だと実行される。
rm -rf "$GATE"; arm
evil='a;touch pwned-by-filename;b.ts'
: > "$REPO/$evil" 2>/dev/null || evil=""
if [[ -n "$evil" ]]; then
  write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "unit", "cmd": "echo got={files}", "gate": true,
                "agent_may_run": true, "scope": "changed" } ] }
JSON
  invoke >/dev/null
  [ ! -f "$REPO/pwned-by-filename" ] \
    && { printf '%s✓%s メタ文字を含むファイル名が実行されない\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
    || { printf '%s✗%s INJECTION: ファイル名が実行された\n' "$c_red" "$c_off"; fail=$((fail+1)); }
  rm -f "$REPO/$evil" "$REPO/pwned-by-filename"
fi

# 未追跡の新規ファイルも飛ばさず検査する。このターンは新規ファイルだけを足す。
rm -rf "$GATE"; arm
git -C "$REPO" checkout -q -- . 2>/dev/null || true
echo 'brand new' > "$REPO/newfile.ts"
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "unit", "cmd": "echo files={files}; false", "gate": true,
                "agent_may_run": true, "scope": "changed" } ] }
JSON
check "未追跡の新規ファイル -> 飛ばさず検査する" 2 "$(invoke)"
grep -q 'newfile.ts' "$TMP/stderr" \
  && { printf '%s✓%s   新規ファイルがコマンドに届く\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   {files} に新規ファイルが無い\n' "$c_red" "$c_off"; fail=$((fail+1)); }
rm -f "$REPO/newfile.ts"

# Cursor は cwd を送らず、プロセスの cwd はワークスペースではなく ~/.cursor。sentinel が 1 つなら、
# 違うリポジトリと比べずに推定する。でないと Cursor の毎ターンを黙って通す。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
noc="$(printf '{"status":"completed","loop_count":0}' \
  | (cd "$TMP" && DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" \
      bash "$HOOK" 2>/dev/null >"$TMP/stdout"); echo $?)"
check "payload に cwd 無し、arm は 1 つ -> リポジトリを推定してゲートを掛ける" 0 "$noc"
grep -q followup_message "$TMP/stdout" \
  && { printf '%s✓%s   黙って通さず follow-up を出す\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   黙って通した（stdout: %s）\n' "$c_red" "$c_off" "$(cat "$TMP/stdout")"; fail=$((fail+1)); }

# arm が 2 つで cwd 無し: 推測すると、あるリポジトリを検査して別のリポジトリに報告してしまう。
SECOND="$TMP/second"; mkdir -p "$SECOND"; git -C "$SECOND" init -q
git -C "$SECOND" remote add origin git@github.com:example/second.git
DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" arm "$SECOND" >/dev/null 2>&1 || true
amb="$(printf '{"cwd":"","hook_event_name":"Stop"}' \
  | (cd "$TMP" && DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" \
      bash "$HOOK" 2>"$TMP/stderr"); echo $?)"
check "cwd 無し、arm が複数 -> 推測せず止める" 2 "$amb"
DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" disarm "$SECOND" >/dev/null 2>&1 || true

# 再入（stop_hook_active）では一度制御を返す。でないとエージェントが閉じ込められる:
# ターンを終えないとユーザーに届かず、どのターンも止められている。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
reentry="$(printf '{"cwd":"%s","hook_event_name":"Stop","stop_hook_active":true}' "$REPO" \
  | DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" bash "$HOOK" 2>"$TMP/stderr"; echo $?)"
check "block の後の再入 -> ユーザーに届くよう一度解放する" 0 "$reentry"
grep -qi 'まだ失敗している' "$TMP/stderr" \
  && { printf '%s✓%s   解放しつつ、チェックがまだ赤だと言う\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   理由を言わずに解放した\n' "$c_red" "$c_off"; fail=$((fail+1)); }

# ...そして解放はトレースに残す。赤のターンを終わらせるのは block ではなく解放なので、block だけを
# 記録するトレースでは「何も起きなかった」と「一度も動かなかった」を区別できない。
if trace_has 'RELEASED'; then ok "   block だけでなく解放もトレースされる"
else no "   トレースの行なしで解放した（trace: $(cat "$GATE/trace.log" 2>/dev/null | tr '\n' '|' | tail -c 200)）"; fi
if trace_has 'boom'; then ok "   トレースがまだ赤のチェックを名指す"
else no "   解放のトレースが失敗したチェックを名指さない"; fi

# block のメッセージで、委任の結果を偽造する方法をエージェントに教えない。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "typecheck", "cmd": "true", "gate": true, "agent_may_run": false,
                "delegate_reason": "needs a lot of heap" } ] }
JSON
invoke >/dev/null
grep -q 'delegated.json' "$TMP/stderr" \
  && { printf '%s✗%s block のメッセージがまだ記録の偽造方法を渡している\n' "$c_red" "$c_off"; fail=$((fail+1)); } \
  || { printf '%s✓%s block のメッセージが偽造の手順を渡さない\n' "$c_green" "$c_off"; pass=$((pass+1)); }

echo
echo "verify-gate — worktree はゲートを継ぐ"
echo

# ゲートが欲しいほどの作業は worktree に移る（`using-git-worktrees` スキルの目的がそれ）。sentinel を
# toplevel と照合すると、メインの checkout で掛けたゲートがどの worktree にも「armed elsewhere」と答える。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
WT1="$(mk_worktree one)" || WT1=""
WT2="$(mk_worktree two)" || WT2=""

if [[ -z "$WT1" || -z "$WT2" ]]; then
  no "リンクされた worktree を作れない -- worktree のケースは実行されていない"
else
  check "メインの checkout で arm -> リンクされた worktree もゲートが止める" 2 "$(invoke_at "$WT1")"

  # ゲートを継いでもカウンタは共有しない。試行回数は作業ツリーのもので、持ち越すとまだ 1 回目の
  # worktree で段階が上がる。
  invoke_at "$WT1" >/dev/null              # WT1 はこれで 2 回連続の失敗
  grep -qi '2 回連続' "$TMP/stderr" \
    && ok "   同じ worktree での 2 回目の失敗で段階が上がる" \
    || no "   同じ worktree での 2 回目の失敗で段階が上がらない"
  invoke_at "$WT2" >/dev/null              # 別の worktree で 1 回目の失敗
  grep -qi '2 回連続' "$TMP/stderr" \
    && no "   試行回数が worktree をまたいで漏れた（WT2 が 1 回目の失敗で上がった）" \
    || ok "   試行回数は worktree ごとで、共有されない"

  # 委任の記録は 1 つの作業ツリーについての証拠。どこでも認めると、誰も実行していない worktree を通してしまう。
  rm -rf "$GATE"; arm
  write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "typecheck", "cmd": "true", "gate": true, "agent_may_run": false,
                "delegate_reason": "needs 8GB of heap" } ] }
JSON
  DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" record typecheck "$REPO" >/dev/null
  check "   メインの checkout の記録では worktree を満たさない" 2 "$(invoke_at "$WT1")"
  check "   ...記録した checkout は満たす" 0 "$(invoke)"

  # gate.sh も hook と同じ結論になること。一致し続けなければならない 2 つの実装なので断言する。
  # grep にパイプせず捕まえる。`armed` は status の 1 行目なので、`grep -q` が先に終わると gate.sh が
  # SIGPIPE を受け、pipefail で 141 になる。下の古い `| grep -q` は探す文字列が最終行なので無事なだけ。
  wt_status="$(DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" status "$WT1" 2>&1)"
  grep -q '^armed' <<<"$wt_status" \
    && ok "   worktree の中から gate.sh status が継いだゲートを見る" \
    || no "   arm 済みリポジトリの worktree の中で gate.sh status が not armed と言う: $(tr '\n' '|' <<<"$wt_status")"

  # worktree の中からの記録は、hook が探す場所に入る。
  DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" record typecheck "$WT1" >/dev/null 2>&1
  check "   worktree で作った記録はその worktree を満たす" 0 "$(invoke_at "$WT1")"
fi

# 無関係なリポジトリには関わらない。継ぐのは arm 済みリポジトリの worktree だけ。
UNREL="$TMP/unrelated"; mkdir -p "$UNREL"; git -C "$UNREL" init -q
git -C "$UNREL" remote add origin git@github.com:example/scratch.git
echo z > "$UNREL/a.txt"; git -C "$UNREL" add -A
git -C "$UNREL" -c user.email=t@t -c user.name=t commit -qm init
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
check "同じ remote の別リポジトリ -> 変わらず armed elsewhere" 0 "$(invoke_at "$UNREL")"

echo
echo "verify-gate — {files} はコマンドを実行する場所からの相対パス"
echo

# コマンドは repo_root/<profile.cwd> で動くので、{files} も cwd からの相対にする。リポジトリルートからの
# 相対だと、"cwd": "v2" の vitest に `v2/src/foo.ts` が渡り、偽の失敗か空振りの成功になる。
rm -rf "$GATE"
SUBREPO="$TMP/subrepo"; mkdir -p "$SUBREPO/pkg/src"
git -C "$SUBREPO" init -q
git -C "$SUBREPO" remote add origin git@github.com:example/sub.git
echo base > "$SUBREPO/pkg/src/a.ts"
git -C "$SUBREPO" add -A
git -C "$SUBREPO" -c user.email=t@t -c user.name=t commit -qm init
echo changed >> "$SUBREPO/pkg/src/a.ts"
DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" arm "$SUBREPO" >/dev/null
cat > "$PROFILES/sub.json" <<'JSON'
{ "match": { "remote": "example/sub" },
  "cwd": "pkg",
  "checks": [ { "id": "unit", "cmd": "echo files={files}; false", "gate": true,
                "agent_may_run": true, "scope": "changed" } ] }
JSON
check "cwd + scope:changed のプロファイル -> 実行し、止めうる" 2 "$(invoke_at "$SUBREPO")"
grep -q 'files=src/a.ts' "$TMP/stderr" \
  && ok "   パスが cwd からの相対なので、pkg/ のランナーが開ける" \
  || no "   基点のディレクトリが違う: $(grep -o 'files=[^ ]*' "$TMP/stderr" | head -1)"
rm -f "$PROFILES/sub.json"

echo
echo "verify-gate — 作業ツリーを書き換えるチェックは緑を報告できない"
echo

# `lint:fix` や `format:fix` をゲートにすると、エージェントが終えた後に hook が作業ツリーを書き換え、
# 成功すればコードを変えたことを隠して緑になる。ゲートは報告するもので、黙って直さない。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "fixer", "cmd": "echo autofixed >> touched-by-the-gate.txt", "gate": true,
                "agent_may_run": true, "mutates": true } ] }
JSON
check "作業ツリーを変える mutating なチェック -> 緑にせず止める" 2 "$(invoke)"
grep -qi '作業ツリーを変更した' "$TMP/stderr" \
  && ok "   ゲート自身がファイルを変えたと言う" \
  || no "   変更について何も言わない: $(tr '\n' '|' < "$TMP/stderr" | head -c 250)"

# ...直すものが無くなれば邪魔をしない。
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "fixer", "cmd": "true", "gate": true, "agent_may_run": true, "mutates": true } ] }
JSON
check "   何も変えない mutating なチェック -> 通る" 0 "$(invoke)"
rm -f "$REPO/touched-by-the-gate.txt"

echo
echo "verify-gate — forbidden のコマンドはゲートでも実行しない"
echo

# `forbidden` を文書だけにすると、`cdk deploy` を禁じたリポジトリでもゲートが毎ターン実行しうる。
# スキルに書いたルールは依頼で保証ではないので、hook で強制する。
rm -rf "$GATE"; arm
# 証拠は報告の文字列ではなくディスク上の副作用で取る。コマンド文は通常の失敗詳細にも出るので、
# stderr を grep しても「実行した」と「引用した」を区別できない。
rm -f "$TMP/forbidden-ran"
cat > "$PROFILES/scratch.json" <<JSON
{ "match": { "remote": "example/scratch" },
  "forbidden": [ "prisma migrate deploy", "git push --force" ],
  "checks": [ { "id": "danger", "cmd": "touch $TMP/forbidden-ran; prisma migrate deploy",
                "gate": true, "agent_may_run": true } ] }
JSON
check "cmd が forbidden のチェック -> 止める" 2 "$(invoke)"
[[ -e "$TMP/forbidden-ran" ]] \
  && no "   forbidden のコマンドが実行された" \
  || ok "   ...実行はしない"
# コマンド文は通常の失敗報告にも出るので grep しない。`forbidden` の語はゲートが断った時にだけ出る。
grep -qi 'forbidden' "$TMP/stderr" \
  && ok "   ...プロファイルが禁じているので断ったと言う" \
  || no "   拒否ではなく失敗したチェックとして報告した: $(tr '\n' '|' < "$TMP/stderr" | head -c 200)"

# `forbidden` の無いプロファイルは今までどおりに動く。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "ok", "cmd": "true", "gate": true, "agent_may_run": true } ] }
JSON
check "forbidden の一覧が無い -> 影響なし" 0 "$(invoke)"

# 似ているだけの部分文字列では引っかからない。照合はコマンドに対してで、`deploy-docs` は `cdk deploy` ではない。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "forbidden": [ "cdk deploy" ],
  "checks": [ { "id": "docs", "cmd": "echo deploying docs is fine", "gate": true, "agent_may_run": true } ] }
JSON
check "forbidden の句を含まないコマンドは実行する" 0 "$(invoke)"

echo
echo "verify-gate — サブエージェントの完了はターンの終わりではない"
echo

# サブエージェントでは `Stop` hook が `SubagentStop` に変換される（公式ドキュメント）。放置すると
# サブエージェントが完了するたびにゲートが走り、テストの赤でレビューのサブエージェントが止まれず、
# 試行回数も無駄に減る。ゲートが見るのはユーザーのターンが終われるかどうかだけ。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
check "赤のチェックで SubagentStop -> 通し、サブエージェントを止めない" 0 \
  "$(invoke_at "$REPO" '"hook_event_name":"SubagentStop"')"
check "   agent_id を持つ Stop の payload -> これも通す" 0 \
  "$(invoke_at "$REPO" '"hook_event_name":"Stop","agent_id":"a1","agent_type":"x-review-backend"')"
trace_has 'subagent' \
  && ok "   そう書き残すので、トレースがきれいな pass に見えない" \
  || no "   黙って通した: $(cat "$GATE/trace.log" 2>/dev/null | tr '\n' '|' | tail -c 160)"

# 本物のターンの終わりは止め続ける。でないと修正でゲートを消したことになる。
check "   ユーザー自身のターンの終わりは止める" 2 "$(invoke)"

# サブエージェントの停止で試行回数も減らさない。
rm -rf "$GATE"; arm
invoke_at "$REPO" '"hook_event_name":"SubagentStop"' >/dev/null
invoke_at "$REPO" '"hook_event_name":"SubagentStop"' >/dev/null
invoke >/dev/null
grep -qi '試行 1 / ' "$TMP/stderr" \
  && ok "   サブエージェントの停止で試行回数が減らない" \
  || no "   サブエージェントの停止で試行回数が減った: $(grep -o '試行 [0-9] / [0-9]' "$TMP/stderr" | head -1)"

echo
echo "verify-gate — 予期しないクラッシュを止めてよい合図にしない"
echo

# Claude Code は終了コード 1 を止めないエラーとして扱い、止めるのは 2 だけ（公式ドキュメント）。
# hook は `set -u` で動くので、未定義変数で 1 で終わると何も検査せずにターンが終わる。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "ok", "cmd": "true", "gate": true, "agent_may_run": true } ] }
JSON
# 注入する故障: 途中で未定義変数を参照する hook のコピー。
CRASH="$TMP/crashing-hook.sh"
sed 's|^payload="\$(cat <&3)"|payload="$(cat <\&3)"; : "$DOTAGENTS_DELIBERATELY_UNSET_FOR_TEST"|' \
  "$HOOK" > "$CRASH"
crash_code="$(printf '{"cwd":"%s","hook_event_name":"Stop"}' "$REPO" \
  | DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" bash "$CRASH" 2>/dev/null; echo $?)"
[[ "$crash_code" == "2" ]] \
  && ok "arm 済みゲートがクラッシュすると 1 ではなく 2 で終わる -- 止めるのは 2 だけ" \
  || no "クラッシュの終了コードが ${crash_code}。Claude Code は止めないので、ターンが未検査で終わる"

echo
echo "verify-gate — kill されたチェックは何も残さない"
echo

# watchdog が `eval` のサブシェルだけを kill すると、チェックがバックグラウンドに出した子（node、dev server、
# docker run）がタイムアウト後も残り、ポートと CPU を握り続ける。
rm -rf "$GATE"; arm
rm -f "$TMP/orphan.pid"
cat > "$PROFILES/scratch.json" <<JSON
{ "match": { "remote": "example/scratch" },
  "max_attempts": 1,
  "checks": [ { "id": "spawns", "timeout": 1, "gate": true, "agent_may_run": true,
                "cmd": "sh -c 'sleep 60 & echo \$! > $TMP/orphan.pid; sleep 60'" } ] }
JSON
invoke >/dev/null
orphan="$(cat "$TMP/orphan.pid" 2>/dev/null || true)"
if [[ -z "$orphan" ]]; then
  no "プローブが子の pid を記録しない -- 孤児のケースは実行されていない"
else
  # 判定の前に、kill が伝わるのを少し待つ。
  sleep 1
  if kill -0 "$orphan" 2>/dev/null; then
    no "バックグラウンドの子がタイムアウト後も生きている（pid ${orphan}）-- ゲートが諦めた後もポートと CPU を握る"
    kill -9 "$orphan" 2>/dev/null || true
  else
    ok "バックグラウンドの子がチェックと一緒に kill される"
  fi
fi

echo
echo "verify-gate — {files} はデータで、コードではない"
echo

# `{files}` + eval は、作業ツリーにファイル名を書けるものによる任意コード実行と隣り合わせ。その境界を広く断言する。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "unit", "cmd": "echo got={files}", "gate": true,
                "agent_may_run": true, "scope": "changed" } ] }
JSON
git -C "$REPO" checkout -q -- . 2>/dev/null || true
rm -f "$REPO"/pwned-* 2>/dev/null || true
made=0
for evil in 'a;touch pwned-semi;b.ts' \
            'a`touch pwned-backtick`b.ts' \
            'a$(touch pwned-dollar)b.ts' \
            "a'; touch pwned-quote; 'b.ts" \
            'a|touch pwned-pipe|b.ts' \
            'a&&touch pwned-and&&b.ts' \
            '--touch=pwned-dash.ts'; do
  : > "$REPO/$evil" 2>/dev/null && made=$((made+1))
done
if (( made == 0 )); then
  no "攻撃用のファイル名を 1 つも作れない -- 注入のケースは実行されていない"
else
  invoke >/dev/null
  hits="$(ls -1 "$REPO" 2>/dev/null | grep '^pwned-' | tr '\n' ' ' || true)"
  [[ -z "${hits// /}" ]] \
    && ok "攻撃用のファイル名 ${made} 個がデータとしてコマンドに届く（$(basename "$REPO") はきれい）" \
    || no "INJECTION: ファイル名が実行された -- $hits"
fi
rm -f "$REPO"/pwned-* 2>/dev/null || true
git -C "$REPO" clean -qfd 2>/dev/null || true
git -C "$REPO" checkout -q -- . 2>/dev/null || true

echo
echo "verify-gate — ゲートは自分で時間を測る"
echo

# ハーネスのタイムアウトで kill された hook は 0 でも 2 でもなく終わり、止めない。遅いスイートで
# ゲートが黙って無効になるので、`eval "$cmd"` に自分で上限を掛ける。
#
# タイムアウトはコードの所見ではなくゲートの故障なので、止めて独自の理由で記録する。上限の回数にも
# 数える。でないと本当に固まるチェックが永遠に止め続ける。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "max_attempts": 1,
  "checks": [ { "id": "hangs", "cmd": "sleep 30", "gate": true, "agent_may_run": true, "timeout": 1 } ] }
JSON
check "タイムアウトを超えるチェック -> 通さず止める" 2 "$(invoke)"
grep -qi 'タイムアウトした' "$TMP/stderr" \
  && ok "   失敗したチェックではなく、タイムアウトしたと言う" \
  || no "   タイムアウトに触れていない: $(tr '\n' '|' < "$TMP/stderr" | head -c 250)"
verdict="$(find "$GATE" -name VERDICT | head -1)"
[[ -n "$verdict" && "$(sed -n 2p "$verdict")" == "timeout" ]] \
  && ok "   'red' ではなく 'timeout' で記録する -- コードについては何も言っていない" \
  || no "   verdict の理由が違う: $(sed -n 2p "${verdict:-/dev/null}")"

# 速いチェックには影響しない。通常の経路を変える watchdog なら、無い方がまし。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "quick", "cmd": "true", "gate": true, "agent_may_run": true, "timeout": 30 } ] }
JSON
check "タイムアウト内のチェック -> 通る" 0 "$(invoke)"

rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "slow-but-fine", "cmd": "sleep 1; echo done", "gate": true,
                "agent_may_run": true, "timeout": 30 } ] }
JSON
check "1 秒かかるが成功するチェック -> 通る" 0 "$(invoke)"

# チェック数 x 個別のタイムアウトはハーネスの上限を超えうるが、それは観測できない失敗。だから全体の
# 予算が尽きたら新しいチェックを始めない。実行していないゲートのチェックは pass ではない。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "timeout_total": 1,
  "checks": [ { "id": "first",  "cmd": "sleep 2", "gate": true, "agent_may_run": true, "timeout": 30 },
              { "id": "second", "cmd": "true",    "gate": true, "agent_may_run": true, "timeout": 30 } ] }
JSON
check "全体の予算が尽きる -> 緑を報告せず止める" 2 "$(invoke)"
grep -qi '実行していない' "$TMP/stderr" \
  && ok "   実行できなかったものを名指す" \
  || no "   飛ばしたチェックについて何も言わない: $(tr '\n' '|' < "$TMP/stderr" | head -c 250)"
grep -q 'second' "$TMP/stderr" \
  && ok "   ...チェック ID で" \
  || no "   実行していないチェックを ID で名指さない"

echo
echo "verify-gate — 止める回数には上限があり、諦めたことは記録する"
echo

# 無人ループは /clear できないので、上限なしに止め続けると出口の無い壁になる。だから止める回数に上限を
# 置く。ただし黙って諦めると嘘になる。終端の状態は「存在する」ファイルにする。ACTIVE を消すだけだと
# 次のセッションの status が not armed になり、誰もゲートを掛けなかった作業と区別できない。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "echo 'still broken'; false", "gate": true, "agent_may_run": true } ] }
JSON
check "試行 1 / 3 -> 止める" 2 "$(invoke)"
grep -qi '試行 1 / 3' "$TMP/stderr" \
  && ok "   上限を示すので、エージェントがやみくもに繰り返さない" \
  || no "   何回目の試行か言わない: $(tr '\n' '|' < "$TMP/stderr" | head -c 200)"
check "試行 2 / 3 -> まだ止める" 2 "$(invoke)"
check "試行 3 / 3 -> もう一度止め、これが最後" 2 "$(invoke)"

# 上限を越える呼び出しは解放せず 2 で終わる。stderr を確実にモデルへ渡すのは 2 だけで、ここで解放すると
# エージェントはゲートが諦めたことを知らないまま止まる。
grep -qi '検証されていない' "$TMP/stderr" \
  && ok "   最後のメッセージが作業は検証されていないと言う" \
  || no "   最後のメッセージが作業は未検証だと言わない: $(tr '\n' '|' < "$TMP/stderr" | head -c 300)"
grep -qi '/clear' "$TMP/stderr" \
  && no "   最後のメッセージがまだ無人ループに /clear を指示している" \
  || ok "   最後のメッセージが、無人では実行できない /clear を指示しない"

verdict="$(find "$GATE" -name VERDICT | head -1)"
[[ -n "$verdict" ]] \
  && ok "   VERDICT ファイルが書かれる" \
  || no "   ゲートのディレクトリのどこにも VERDICT ファイルが無い"
if [[ -n "$verdict" ]]; then
  [[ "$(sed -n 2p "$verdict")" == "red" ]] \
    && ok "   理由は 'red' -- チェックが失敗し続けた" \
    || no "   理由が違う: $(sed -n 2p "$verdict")"
  [[ "$(sed -n 3p "$verdict")" == "boom" ]] \
    && ok "   チェックを名指す" \
    || no "   verdict がチェックを名指さない: $(sed -n 3p "$verdict")"
fi
grep -q 'red' "$GATE/verdicts.log" 2>/dev/null \
  && ok "   verdicts.log にも追記される" \
  || no "   verdicts.log に何も無い"
trace_has 'GAVE UP' \
  && ok "   諦めたことがトレースされる" \
  || no "   トレースの行なしで諦めた"

# ここからゲートは止めるのをやめる（それが目的）が、緑に見えてはならない。
check "諦めた後 -> 止めるのをやめる" 0 "$(invoke)"
trace_has '回試して諦めている' \
  && ok "   その pass は文面で 'all gating checks green' と区別できる" \
  || no "   トレースで、諦めた後の pass がきれいな pass と区別できない"

# 新しいセッションが確実に通るのは /da-verify による arm し直しなので、前の verdict はそこで示す。
arm_out="$(DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" arm "$REPO" 2>&1)"
grep -qi 'verdict' <<<"$arm_out" \
  && ok "arm し直すと、前のセッションが残した verdict を示す" \
  || no "arm し直しても前の verdict について何も言わない: $(tr '\n' '|' <<<"$arm_out" | head -c 200)"
check "   ...arm し直した後はまた止める" 2 "$(invoke)"

# 誰も確認しない委任チェックも同じ上限で打ち切るが、別の所見として記録する。
# 「人が確認していない」は「コードが壊れている」ではない。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "typecheck", "cmd": "true", "gate": true, "agent_may_run": false,
                "delegate_reason": "needs 8GB of heap" } ] }
JSON
invoke >/dev/null; invoke >/dev/null
check "未確認の委任チェックにも上限がある" 2 "$(invoke)"
check "   ...その後は止めるのをやめる" 0 "$(invoke)"
verdict="$(find "$GATE" -name VERDICT | head -1)"
[[ -n "$verdict" && "$(sed -n 2p "$verdict")" == "needs_human" ]] \
  && ok "   red ではなく needs_human で記録する" \
  || no "   未確認の委任チェックの理由が違う: $(sed -n 2p "${verdict:-/dev/null}")"

# 上限は設定できる。テストでは短く、遅いリポジトリでは長くしたいことがある。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
check "DOTAGENTS_GATE_MAX_ATTEMPTS=1 -> 1 回目の失敗で諦める" 2 "$(DOTAGENTS_GATE_MAX_ATTEMPTS=1 invoke)"
check "   ...直後から止めるのをやめる" 0 "$(DOTAGENTS_GATE_MAX_ATTEMPTS=1 invoke)"

rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "max_attempts": 1,
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
check "プロファイルで max_attempts を設定できる" 2 "$(invoke)"
check "   ...それが守られる" 0 "$(invoke)"

# ある worktree で諦めても、別の worktree のゲートは解放しない。カウンタが worktree ごとなので verdict もそう。
if [[ -n "${WT1:-}" ]]; then
  rm -rf "$GATE"; arm
  write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
  DOTAGENTS_GATE_MAX_ATTEMPTS=1 invoke >/dev/null          # メインの checkout が諦める
  check "ある作業ツリーで諦めても、別のツリーは解放しない" 2 "$(invoke_at "$WT1")"
fi

echo
echo "verify-gate — アイドルのゲートは回収する"
echo

# 解除が手順任せだと、途中で終わったセッションがリポジトリを arm したまま残す。
# 測るのは arm からの時間ではなくアイドル時間。arm からの TTL だと、長い無人実行の途中で失効して黙って開く。
NOW="$(date +%s)"
LATER=$(( NOW + 13 * 3600 ))     # 既定の 12h を過ぎる
SOON=$(( NOW + 60 ))

# 失効が構造的に開いて失敗しないための不変条件: 1 回の呼び出しで sentinel を失効させ、その失効を根拠に
# 通すことはしない。ゲート G を失効させられるのは G 以外の呼び出しだけで、それは G が守る呼び出しではない。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
ex_own="$(DOTAGENTS_GATE_NOW=$LATER invoke_at "$REPO")"
check "強制中のゲートは自分の呼び出しでは失効しない" 2 "$ex_own"
[[ -f "$(gate_dir_for "$REPO")/ACTIVE" ]] \
  && ok "   ...その後も sentinel が残っている" \
  || no "   呼び出しが、自分で強制しているゲートを失効させた"

# 強制するたびに heartbeat を更新する。これで長い無人実行が生き残る。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "ok", "cmd": "true", "gate": true, "agent_may_run": true } ] }
JSON
DOTAGENTS_GATE_NOW=$SOON invoke_at "$REPO" >/dev/null
hb="$(cat "$(gate_dir_for "$REPO")/HEARTBEAT" 2>/dev/null || echo 0)"
[[ "$hb" == "$SOON" ]] \
  && ok "緑で終わるターンが heartbeat を更新する" \
  || no "heartbeat が更新されていない（期待は ${SOON}、実際は ${hb}）"

# 掃除役は別リポジトリのターンの終わり。全セッションで 1 分に何度も走るので cron は要らない。
# ガードレールを外すのが仕事の常駐プロセスは、誰も見ていない時に開いて失敗する装置になる。
rm -rf "$GATE"; arm
STRANGER="$TMP/stranger"; mkdir -p "$STRANGER"; git -C "$STRANGER" init -q
git -C "$STRANGER" remote add origin git@github.com:example/stranger.git
echo s > "$STRANGER/a.txt"; git -C "$STRANGER" add -A
git -C "$STRANGER" -c user.email=t@t -c user.name=t commit -qm init
armed_dir="$(gate_dir_for "$REPO")"
check "無関係なリポジトリのターンの終わりは通る（ゲートは掛かっていない）" 0 "$(DOTAGENTS_GATE_NOW=$LATER invoke_at "$STRANGER")"
[[ ! -f "$armed_dir/ACTIVE" ]] \
  && ok "   ...途中で見つけたアイドルの sentinel を回収する" \
  || no "   アイドルの sentinel が掃除で残った"
trace_has 'expired' \
  && ok "   回収がトレースされる" \
  || no "   トレースの行なしで回収した"
[[ -s "$GATE/verdicts.log" ]] \
  && ok "   トレースの切り詰めが触れない verdicts.log にも記録される" \
  || no "   verdicts.log に何も書かれていない"
[[ -f "$armed_dir/ROOT" ]] \
  && ok "   回収後も ROOT が残るので、status が誰のゲートだったかを言える" \
  || no "   ROOT が消えたので、失効したゲートがきれいなセッションと区別できない"

# アイドルが十分に長くないゲートには触れない。
rm -rf "$GATE"; arm
armed_dir="$(gate_dir_for "$REPO")"
DOTAGENTS_GATE_NOW=$SOON invoke_at "$STRANGER" >/dev/null
[[ -f "$armed_dir/ACTIVE" ]] \
  && ok "アイドルの猶予内のゲートは回収しない" \
  || no "まだ新しいゲートを回収した"

# 古い gate.sh が書いた sentinel には heartbeat が無い。無限にアイドルと見なすと 1 分前のゲートも
# 回収するので、代わりに埋める。更新は勝手に移行し、誰かが覚えて実行するコマンドは要らない。
rm -rf "$GATE"; arm
armed_dir="$(gate_dir_for "$REPO")"
rm -f "$armed_dir/HEARTBEAT" "$armed_dir/ARMED_AT"
DOTAGENTS_GATE_NOW=$LATER invoke_at "$STRANGER" >/dev/null
if [[ -f "$armed_dir/ACTIVE" && "$(cat "$armed_dir/HEARTBEAT" 2>/dev/null)" == "$LATER" ]]; then
  ok "更新前の sentinel は回収されず heartbeat を与えられる"
else
  no "更新前の sentinel が回収されたか、heartbeat の無いまま残った"
fi

echo
echo "gate.sh — 回収と報告"
echo

# status でゲートを開けてはならない。状態を読むことは変えてよい理由にならない。
rm -rf "$GATE"; arm
armed_dir="$(gate_dir_for "$REPO")"
DOTAGENTS_GATE_NOW=$LATER DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" status "$REPO" >/dev/null 2>&1
[[ -f "$armed_dir/ACTIVE" ]] \
  && ok "status は回収せずに古さを報告する" \
  || no "status がゲートを回収した -- 読むだけで開いてしまう"
st="$(DOTAGENTS_GATE_NOW=$LATER DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" status "$REPO" 2>&1)"
grep -qi 'idle' <<<"$st" \
  && ok "   ...アイドル時間を言う" \
  || no "   status がアイドルに触れていない: $(tr '\n' '|' <<<"$st")"

# gc は明示的な経路。ターンの終わりを待たずに掃除したいドライバーや CI 向け。
gc_out="$(DOTAGENTS_GATE_NOW=$LATER DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" gc 2>&1)"
[[ ! -f "$armed_dir/ACTIVE" ]] \
  && ok "gc がアイドルのゲートを回収する" \
  || no "gc がアイドルのゲートを arm したまま残した"
grep -q "$(basename "$REPO")" <<<"$gc_out" \
  && ok "   ...回収したものを名指す" \
  || no "   gc が何をしたか言わない: $(tr '\n' '|' <<<"$gc_out")"

# 回収後に not armed とだけ言うと、何も arm しなかったセッションと区別できない。ROOT を残すのはこれに答えるため。
st="$(DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" status "$REPO" 2>&1)"
grep -qi 'expired' <<<"$st" \
  && ok "status が 'not armed' だけでなく、ゲートが失効したと説明する" \
  || no "status が失効を隠す: $(tr '\n' '|' <<<"$st")"

echo
echo "gate.sh verify — ターンを終えず、ゲートにも触れずに検査する"
echo

# 実装の途中で自分の作業を検査できるように、`verify` は hook を再実装せずに駆動する。実装が 1 つなら、
# 2 つ目の写しがずれることもない。
verify() { # verify [--json] [dir]
  DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" \
    bash "$GATE_SH" verify "$@" >"$TMP/vout" 2>"$TMP/verr"
  echo $?
}

rm -rf "$GATE"
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "ok", "cmd": "true", "gate": true, "agent_may_run": true } ] }
JSON
check "すべて緑で verify -> exit 0" 0 "$(verify "$REPO")"

# 肝心な点: ゲートを arm していなくても動く。検査は作業の途中でするもの。
[[ ! -e "$GATE" ]] || [[ -z "$(find "$GATE" -name ACTIVE 2>/dev/null)" ]] \
  && ok "   ...何も arm されていない、実際に使いたい状態で" \
  || no "   verify が何かを arm した"

write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "echo the-real-failure; false", "gate": true, "agent_may_run": true } ] }
JSON
vrc="$(verify "$REPO")"
[[ "$vrc" != "0" ]] \
  && ok "赤のチェックで verify -> 非 0" \
  || no "赤のチェックで verify が成功を報告した"
grep -q 'boom' "$TMP/vout" "$TMP/verr" 2>/dev/null \
  && ok "   ...チェックを名指す" || no "   失敗したチェックを名指さない"
grep -q 'the-real-failure' "$TMP/vout" "$TMP/verr" 2>/dev/null \
  && ok "   ...その出力を示す" || no "   チェックの出力を示さない"

# ゲートの状態を消費しない。自己検査で試行を使うと、上限が検査した回数に左右され、検査を妨げる。
rm -rf "$GATE"; arm
armed_dir="$(gate_dir_for "$REPO")"
hb_before="$(cat "$armed_dir/HEARTBEAT" 2>/dev/null)"
verify "$REPO" >/dev/null
att="$(find "$armed_dir" -name attempts.json | head -1)"
[[ "$(tr -d ' \n' < "$att" 2>/dev/null)" == "{}" ]] \
  && ok "verify が試行を消費しない" \
  || no "verify が試行回数を使った: $(cat "$att" 2>/dev/null | tr -d '\n')"
[[ -z "$(find "$armed_dir" -name VERDICT 2>/dev/null)" ]] \
  && ok "   ...verdict を書かない" || no "   verify が VERDICT を書いた"
[[ "$(cat "$armed_dir/HEARTBEAT" 2>/dev/null)" == "$hb_before" ]] \
  && ok "   ...heartbeat を更新しない" \
  || no "   verify が heartbeat を更新した -- 作業を検査するだけで古いゲートが生き延びる"
[[ -f "$armed_dir/ACTIVE" ]] \
  && ok "   ...ゲートを arm したまま残す" || no "   verify がゲートを解除した"

# ドライバー向けの --json。status --json と同じ。
rm -rf "$GATE"
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
verify --json "$REPO" >/dev/null
vj() { node -e '
  let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
    try { console.log(String(JSON.parse(s)[process.argv[1]])) } catch { console.log("parse-error") }
  });' "$1" < "$TMP/vout"; }
[[ "$(vj ok)" == "false" ]] \
  && ok "verify --json が ok=false を報告する" || no "verify --json ok=$(vj ok)（raw: $(head -c 120 "$TMP/vout")）"
[[ "$(vj check)" == "boom" ]] \
  && ok "   ...チェックを文ではなくフィールドで名指す" || no "   check=$(vj check)"

# --- ゲートが何をしたかをフィールドで -----------------------------------------------
# `ok: true` は「検証済み」ではない。実行しなかったチェックと通ったチェックを文面で見分けずに済むよう、
# フィールドで出す。
[[ "$(vj ran)" == "1" ]] \
  && ok "   ...実際に実行したゲートのチェック数を報告する" || no "   ran=$(vj ran)、期待は 1"
[[ "$(vj checked)" == "true" ]] \
  && ok "   ...1 つ実行すれば checked が true" || no "   checked=$(vj checked)"
[[ "$(vj profile)" == *"scratch"* || "$(vj profile)" == *".json" ]] \
  && ok "   ...解決したプロファイルを名指すので、文面を grep しなくて済む" \
  || no "   profile=$(vj profile)"

# きれいな作業ツリーで、ゲートのチェックが {files} 対象だけ。チェックは飛ばされる。止めはしない
# （本当に検査するものが無い）が、本物の pass と区別できなければならない。
rm -rf "$GATE"
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "only-changed", "cmd": "false {files}", "gate": true, "agent_may_run": true,
                "scope": "changed" } ] }
JSON
git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm clean >/dev/null 2>&1
verify --json "$REPO" >/dev/null
[[ "$(vj ran)" == "0" ]] \
  && ok "きれいな作業ツリーでは {files} のチェックを実行せず、ran=0 と言う" \
  || no "   きれいな作業ツリーで ran=$(vj ran)、期待は 0"
[[ "$(vj checked)" == "false" ]] \
  && ok "   ...だから checked は false -- 「何も実行していない」は「緑」ではない" || no "   checked=$(vj checked)"
node -e '
  let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
    let o=null; try { o=JSON.parse(s) } catch {}
    const sk=(o&&o.skipped)||[];
    process.exit(sk.some(x=>x.id==="only-changed"&&x.reason==="no_files")?0:1);
  });' < "$TMP/vout" \
  && ok "   ...飛ばしたチェックを理由つきで名指し、消えない" \
  || no "   skipped が only-changed:no_files を名指さない（raw: $(head -c 200 "$TMP/vout")）"

# 閉じて失敗する。sidecar が無い・読めないは「分からない」で、答えが無いことは yes ではない。`verify` は
# sidecar を必ず自分で書くので、固定すべきは壊れた sidecar へのマージの反応。下の妥当性テストで直接断言する。
# --- `paths`: 変更に該当するチェックだけを実行する -------------------------------
# 間違った理由で通る 2 つの道を、作りで塞ぐ:
#   1. 飛ばしたチェックがどのみち通る -> 飛ばす方は `exit 1` にし、実行しない時だけ緑になる
#   2. 何も変わらず、別の理由で何も実行されない -> 先に本物のファイルを書く
rm -rf "$GATE"
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "needs-src",  "cmd": "exit 1", "gate": true, "agent_may_run": true,
                "paths": ["src/**"] },
              { "id": "needs-docs", "cmd": "true",   "gate": true, "agent_may_run": true,
                "paths": ["docs/**"] } ] }
JSON
mkdir -p "$REPO/docs"; printf 'x\n' > "$REPO/docs/x.md"
rc="$(verify --json "$REPO")"
[[ "$rc" == "0" ]] \
  && ok "paths: docs の変更では src 専用のチェック（実行すれば失敗する）を実行しない" \
  || no "   verify の終了コードが ${rc} -- src のチェックが実行されたか、別の何かが止めた（raw: $(head -c 200 "$TMP/verr")）"
[[ "$(vj ran)" == "1" ]] \
  && ok "   ...実行したチェックはちょうど 1 つ" || no "   ran=$(vj ran)、期待は 1"
node -e '
  let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
    let o=null; try { o=JSON.parse(s) } catch {}
    const sk=(o&&o.skipped)||[];
    process.exit(sk.some(x=>x.id==="needs-src"&&x.reason==="paths")?0:1);
  });' < "$TMP/vout" \
  && ok "   ...飛ばしたことを reason=paths で名指し、黙らない" \
  || no "   skipped が needs-src:paths を名指さない（raw: $(head -c 200 "$TMP/vout")）"

# 変更したファイルに該当するゲートのチェックが無い。ここのチェックは実行すれば通るので、止まるなら
# 赤のせいではなく「何も検査していない」ことだけが理由になる。
rm -rf "$GATE"
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "needs-src", "cmd": "true", "gate": true, "agent_may_run": true,
                "paths": ["src/**"] } ] }
JSON
rc="$(verify --json "$REPO")"
[[ "$rc" != "0" ]] \
  && ok "どのチェックも該当しない変更ファイルは、チェックが通るはずでも止める" \
  || no "   verify が 0 で終わった -- 「何も実行していない」が緑として報告された。これが防ぎたい失敗そのもの"
[[ "$(vj kind)" == "not_checked" ]] \
  && ok "   ...kind=not_checked で。これは red とは違う" || no "   kind=$(vj kind)"
[[ "$(vj ran)" == "0" ]] \
  && ok "   ...ran=0 がフィールドでそう言う" || no "   ran=$(vj ran)"

# 後方互換: `paths` の無い同じプロファイルは実行して通る。フィールド 1 つで結果が逆になる。
rm -rf "$GATE"
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "needs-src", "cmd": "true", "gate": true, "agent_may_run": true } ] }
JSON
rc="$(verify --json "$REPO")"
[[ "$rc" == "0" && "$(vj ran)" == "1" ]] \
  && ok "paths の無いチェックは今までどおり -- 常に実行する" \
  || no "   exit=$rc ran=$(vj ran)。paths 無しの経路が退行した"

# `paths` のチェックがあり作業ツリーがきれいなのは別の分岐: 何も変えていないので検査するものが無く、
# コードを読むだけのターンを Stop hook が止めてはならない。
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm docs >/dev/null 2>&1
rm -rf "$GATE"
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "needs-src", "cmd": "true", "gate": true, "agent_may_run": true,
                "paths": ["src/**"] } ] }
JSON
rc="$(verify --json "$REPO")"
[[ "$rc" == "0" ]] \
  && ok "paths のチェックでも作業ツリーがきれいなら通る -- 読むだけのターンは止めない" \
  || no "   きれいな作業ツリーで verify の終了コードが ${rc}。これではゲートを切られる"
[[ "$(vj changed_files)" == "0" ]] \
  && ok "   ...changed_files=0 で「何も検査していない」と区別できる" \
  || no "   changed_files=$(vj changed_files)"

# `paths` はルートからの相対、`{files}` は cwd からの相対。どちらを逆にしても黙って壊れるので 1 ケースで両方見る。
rm -rf "$GATE"
mkdir -p "$REPO/pkg/src"; printf 'a\n' > "$REPO/pkg/src/a.ts"; printf 'b\n' > "$REPO/other.txt"
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" }, "cwd": "pkg",
  "checks": [ { "id": "pkg-only", "cmd": "echo files={files}; false", "gate": true,
                "agent_may_run": true, "scope": "changed", "paths": ["pkg/src/**"] } ] }
JSON
rc="$(verify --json "$REPO")"
# stderr ではなく JSON の `detail` から読む。--json では gate.sh が hook の報告を文書に畳み、stderr には
# 何も出さない。stderr を見ると「漏れなし」の断言が空のファイルで空振りする。
[[ "$rc" != "0" ]] && grep -q 'files=src/a.ts' "$TMP/vout" \
  && ok "paths はルートからの相対で当たり、{files} は cwd からの相対のまま（files=src/a.ts）" \
  || no "   期待は files=src/a.ts（exit=$rc ran=$(vj ran) changed=$(vj changed_files) kind=$(vj kind)）"
grep -q 'other.txt' "$TMP/vout" \
  && no "   {files} にチェックの paths の外のパスが漏れた" \
  || ok "   ...{files} は共通部分 -- other.txt は渡されていない"
git -C "$REPO" checkout -q -- . 2>/dev/null; rm -rf "$REPO/pkg" "$REPO/other.txt" "$REPO/docs"

printf 'not json at all' > "$TMP/mangled"
node -e '
  // gate.sh と同じマージを壊れた sidecar に当てる。ok は false に強制し、フィールドは楽観せず null にする。
  const fs=require("fs");
  let rep=null; try { rep=JSON.parse(fs.readFileSync(process.argv[1],"utf8")) } catch {}
  const sane = rep && typeof rep === "object" && Number.isInteger(rep.ran);
  process.exit(sane ? 1 : 0);
' "$TMP/mangled" \
  && ok "読めない sidecar を妥当と見なさないので、verify --json は ok=false に強制する" \
  || no "壊れた sidecar が妥当性テストを通った"

# ゲート自身の制御変数をチェックに渡さない。渡すと、このテストが DOTAGENTS_GATE_DRY=1 を継いで hook を
# すべて dry で呼び、自分のスイートを失敗と報告する。チェックはリポジトリのコードで、ゲートの内部ではない。
rm -rf "$GATE"
cat > "$PROFILES/scratch.json" <<JSON
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "env-leak",
                "cmd": "printenv DOTAGENTS_GATE_DRY > $TMP/leaked 2>&1; printenv DOTAGENTS_GATE_NOW >> $TMP/leaked 2>&1; true",
                "gate": true, "agent_may_run": true } ] }
JSON
rm -f "$TMP/leaked"
DOTAGENTS_GATE_NOW=1 verify "$REPO" >/dev/null
[[ ! -s "$TMP/leaked" ]] \
  && ok "ゲートの制御変数がチェックに届かない" \
  || no "チェックに漏れた: $(tr '\n' ' ' < "$TMP/leaked")"

echo
echo "gate.sh — 機械が読む出力"
echo

# ドライバーが解釈してよい唯一の出力。文面は言い換えられるので頼らない。`status` と同じく読み取り専用。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "typecheck", "cmd": "true", "gate": true, "agent_may_run": false,
                "delegate_reason": "needs heap" } ] }
JSON
DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" record typecheck "$REPO" >/dev/null
js="$(DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" status --json "$REPO" 2>/dev/null)"
jf() { node -e '
  let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
    try { const v = process.argv[1].split(".").reduce((o,k)=>o?.[k], JSON.parse(s));
          console.log(typeof v === "object" ? JSON.stringify(v) : String(v)); }
    catch { console.log("parse-error"); }
  });' "$1" <<<"$js"; }
[[ "$(jf armed)" == "true" ]] \
  && ok "status --json が armed を報告する" \
  || no "status --json armed=$(jf armed)（raw: $(head -c 120 <<<"$js")）"
[[ "$(jf gave_up)" == "false" ]] && ok "   止めている間は gave_up が false" \
                                 || no "   gave_up=$(jf gave_up)"
grep -q typecheck <<<"$(jf recorded)" && ok "   委任の記録が並ぶ" \
                                      || no "   recorded=$(jf recorded)"
[[ "$(jf ttl_seconds)" == "43200" ]] && ok "   回収までの猶予が暗黙ではなく明示される" \
                                     || no "   ttl_seconds=$(jf ttl_seconds)"

# ...諦めた後も、ドライバーは文面を読まずにそれが分かる。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
DOTAGENTS_GATE_MAX_ATTEMPTS=1 invoke >/dev/null
js="$(DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" status --json "$REPO" 2>/dev/null)"
[[ "$(jf gave_up)" == "true" ]] && ok "status --json が諦めたことを報告する" \
                                || no "   ゲートが諦めた後で gave_up=$(jf gave_up)"
[[ "$(jf verdict.reason)" == "red" ]] && ok "   ...理由つきで" \
                                      || no "   verdict.reason=$(jf verdict.reason)"
[[ "$(jf verdict.check)" == "boom" ]] && ok "   ...チェックも" \
                                      || no "   verdict.check=$(jf verdict.check)"

# arm されていなくても正しい JSON を返す。でないとドライバーが特別扱いを要する。
disarm
js="$(DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" status --json "$REPO" 2>/dev/null)"
[[ "$(jf armed)" == "false" ]] && ok "arm されていないリポジトリも正しい JSON で答える" \
                               || no "   armed=$(jf armed)（raw: $(head -c 120 <<<"$js")）"

echo
echo "gate.sh — arm の仕組み"
echo

g() { DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" "$@"; }

rm -rf "$GATE"
g status "$REPO" 2>/dev/null | grep -q '^not armed' \
  && { printf '%s✓%s 何も arm する前は not armed と報告する\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s status が not armed と報告しない\n' "$c_red" "$c_off"; fail=$((fail+1)); }

g arm "$REPO" >/dev/null
# sentinel はリポジトリのルートを持つ。これで slug の導出から切り離される。
sentinel="$(find "$GATE" -name ACTIVE | head -1)"
[ -n "$sentinel" ] && [ "$(cat "$sentinel")" = "$(git -C "$REPO" rev-parse --show-toplevel)" ] \
  && { printf '%s✓%s sentinel がリポジトリのルートを記録する\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s sentinel が無いか、リポジトリのルートを持っていない\n' "$c_red" "$c_off"; fail=$((fail+1)); }

# 2 回 arm しても 2 つ目のディレクトリを作らない。
g arm "$REPO" >/dev/null
[ "$(find "$GATE" -name ACTIVE | wc -l | tr -d ' ')" = "1" ] \
  && { printf '%s✓%s 2 回 arm しても冪等\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s 2 回 arm すると sentinel が複数できた\n' "$c_red" "$c_off"; fail=$((fail+1)); }

g record typecheck "$REPO" >/dev/null
g status "$REPO" | grep -q typecheck \
  && { printf '%s✓%s record が status から見える場所に入る\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s 記録したチェックが status から見えない\n' "$c_red" "$c_off"; fail=$((fail+1)); }

# 別のリポジトリに掛けたゲートは、このリポジトリを止めない。
OTHER="$TMP/other"; mkdir -p "$OTHER"; git -C "$OTHER" init -q
git -C "$OTHER" remote add origin git@github.com:example/other.git
g arm "$OTHER" >/dev/null
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
g disarm "$REPO" >/dev/null    # 別のリポジトリだけが arm のまま
check "別のリポジトリだけが arm -> このリポジトリは止めない" 0 "$(invoke)"

g disarm "$OTHER" >/dev/null
g status "$REPO" | grep -q '^not armed' \
  && { printf '%s✓%s disarm が sentinel を消す\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s disarm してもゲートが arm のまま\n' "$c_red" "$c_off"; fail=$((fail+1)); }

echo
echo "verify-gate — Cursor の方言"
echo

json_field() { node -e '
  let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
    try { const v = JSON.parse(s)[process.argv[1]]; console.log(v === undefined ? "" : v) }
    catch { console.log("") }
  });' "$1" < "$TMP/stdout"; }

# 11. Cursor は止められないので、失敗でも exit 0。ただし followup_message を載せる。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "echo 'type error'; false", "gate": true, "agent_may_run": true } ] }
JSON
check "cursor: チェックが落ちる -> exit 0（止められない）" 0 "$(invoke_cursor 0)"
msg="$(json_field followup_message)"
[ -n "$msg" ] && grep -q "boom" <<<"$msg" \
  && { printf '%s✓%s   チェックを名指す followup_message を出す\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   使える followup_message が無い（stdout: %s）\n' "$c_red" "$c_off" "$(cat "$TMP/stdout")"; fail=$((fail+1)); }

# 差し込んだメッセージはユーザーのメッセージとして届く。出どころを書かないと、エージェントは hook の要求を
# ユーザーの意図と取り違える。
msg="$(json_field followup_message)"
grep -q 'dotagents' <<<"$msg" && grep -qi 'ユーザーが書いたものではな' <<<"$msg" \
  && { printf '%s✓%s   follow-up がユーザーではなく自動のものだと言う\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   follow-up がユーザーのメッセージと区別できない\n' "$c_red" "$c_off"; fail=$((fail+1)); }

# 12. Cursor の経路では stderr に何も出さない。Cursor は stdout を読み、stderr は雑音になる。
[ ! -s "$TMP/stderr" ] \
  && { printf '%s✓%s   stderr に何も書かない\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   stderr に書いた: %s\n' "$c_red" "$c_off" "$(head -1 "$TMP/stderr")"; fail=$((fail+1)); }

# 13. チェックが通る -> 正しい空の JSON。Cursor が不正な応答と見なさないように。
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "ok", "cmd": "true", "gate": true, "agent_may_run": true } ] }
JSON
check "cursor: チェックが通る -> exit 0" 0 "$(invoke_cursor 0)"
[ "$(cat "$TMP/stdout")" = "{}" ] \
  && { printf '%s✓%s   空の本文ではなく {} を出す\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   期待は {}、実際は: %s\n' "$c_red" "$c_off" "$(cat "$TMP/stdout")"; fail=$((fail+1)); }

# 14. Cursor は follow-up のループを 5 回で打ち切る。その前に差し込みをやめる。でないとゲートが上限を
#     使い切り、エージェントがいつまでも落ち着かない。
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
invoke_cursor 3 >/dev/null
[ "$(cat "$TMP/stdout")" = "{}" ] \
  && { printf '%s✓%s   loop_count が 3 に達したら差し込みをやめる\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   loop_count=3 でまだ差し込んでいる: %s\n' "$c_red" "$c_off" "$(cat "$TMP/stdout")"; fail=$((fail+1)); }

# 15. この経路でも、arm されていないセッションには触れない。
disarm
check "cursor: sentinel が arm されていない -> 発火しない" 0 "$(invoke_cursor 0)"

echo
if (( fail )); then
  printf '%s成功 %d 件、失敗 %d 件%s\n' "$c_red" "$pass" "$fail" "$c_off"; exit 1
fi
printf '%s✓ 成功 %d 件%s\n' "$c_green" "$pass" "$c_off"
