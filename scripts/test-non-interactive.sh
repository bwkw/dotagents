#!/usr/bin/env bash
# ここにあるものが人を待たないことを確かめる。
#
# --non-interactive フラグはわざと作らない。今は何も尋ねないので、フラグを足すと立てた時だけ通る
# 別経路ができ、既定の経路が尋ねるように退化してもフラグ付きのテストは緑のままになる。
# 欲しい性質は「対話の経路が無いこと」で、それを選ばせずに検査する。
#
# 検査は 2 種類。入口を stdin を閉じ TTY なしで実行するものと、人を待つ構文をソースから探すもの。
# 構文は到達されずに足せるし、経路はそれらの構文なしでも到達できるので、両方要る。

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

pass=0; fail=0
if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then c_red=''; c_green=''; c_off=''
else c_red=$'\033[31m'; c_green=$'\033[32m'; c_off=$'\033[0m'; fi
ok() { printf '%s✓%s %s\n' "$c_green" "$c_off" "$1"; pass=$((pass+1)); }
no() { printf '%s✗%s %s\n' "$c_red" "$c_off" "$1"; fail=$((fail+1)); }

# macOS には `timeout` が無い。ここで固まると CI が固まる。
with_deadline() { # <seconds> <command...>  -> 終了コード。殺した時は 124
  local secs="$1"; shift
  "$@" >"$TMP/out" 2>&1 &
  local pid=$! ticks=0
  # 1 秒単位だと終わっていても入口ごとに 1 秒かかるので、0.2 秒刻みで見る。
  local limit=$(( secs * 5 ))
  while [[ $ticks -lt $limit ]]; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return $?; }
    sleep 0.2
    ticks=$((ticks+1))
  done
  kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 124
}

# /dev/null ではなく stdin を閉じる。終了済みのエージェントから呼ばれた hook には stdin が無く、
# 閉じた記述子への `read` は空ファイルへのものと振る舞いが違う。
run_headless() { # <label> <command...>
  local label="$1"; shift
  local code
  TERM=dumb NO_COLOR=1 with_deadline 30 "$@" <&- ; code=$?
  if [[ $code -eq 124 ]]; then
    no "${label} が stdin を閉じた状態で終わらなかった -- 何かが入力を待っている"
  else
    ok "${label} は stdin を閉じ TTY なしで終わる（exit ${code}）"
  fi
}

echo "非対話"
echo

FAKE="$TMP/home"; mkdir -p "$FAKE/.claude" "$FAKE/.cursor"

# 読み取り専用か dry run の入口だけ。`setup.sh install` は $HOME に書き、それは test-setup.sh の担当。
# このファイルが見るのは止まるかどうかで、何を書くかではない。
run_headless "check.sh --fast"          env HOME="$FAKE" bash "$REPO/scripts/check.sh" --fast
run_headless "verify-skills.sh"         bash "$REPO/scripts/verify-skills.sh"
run_headless "gate.sh -h"               bash "$REPO/scripts/gate.sh" -h
run_headless "gate.sh status"           env HOME="$FAKE" bash "$REPO/scripts/gate.sh" status "$REPO"
run_headless "gate.sh status --json"    env HOME="$FAKE" bash "$REPO/scripts/gate.sh" status --json "$REPO"
run_headless "gate.sh gc"               env DOTAGENTS_GATE_DIR="$TMP/gate" bash "$REPO/scripts/gate.sh" gc
run_headless "loop.sh (usage)"          env HOME="$FAKE" bash "$REPO/scripts/loop.sh"
run_headless "loop.sh status"           env HOME="$FAKE" DOTAGENTS_LOOP_DIR="$TMP/loop" bash "$REPO/scripts/loop.sh" status
run_headless "loop.sh report"           env HOME="$FAKE" DOTAGENTS_LOOP_DIR="$TMP/loop" bash "$REPO/scripts/loop.sh" report
# design フェーズは各段階に人が要るので尋ねたくなる唯一の場所。それでも stdin を閉じて終わること。
run_headless "loop.sh design"           env HOME="$FAKE" DOTAGENTS_LOOP_DIR="$TMP/loop" bash "$REPO/scripts/loop.sh" design
run_headless "setup.sh status"          env HOME="$FAKE" bash "$REPO/scripts/setup.sh" status
run_headless "setup.sh doctor"          env HOME="$FAKE" bash "$REPO/scripts/setup.sh" doctor
run_headless "setup.sh install --dry-run" env HOME="$FAKE" bash "$REPO/scripts/setup.sh" install --dry-run

echo

# hook は harness から stdin を読むので、読むこと自体は正当（規則は「*人* を待たない」）。
# 入力が全く無くても終わること、ペイロードを読めなくてもゲートが閉じたまま失敗することを見る。
run_headless "lint hook（ペイロードなし）"  bash "$REPO/hooks/dotagents-lint-skill-frontmatter.sh"
run_headless "gate hook（ペイロードなし）"  env DOTAGENTS_GATE_DIR="$TMP/empty-gate" \
  bash "$REPO/hooks/dotagents-verify-gate.sh"

# ゲートが arm 済みでペイロードが読めなければブロックする。通すと、stdin を閉じたエージェントが
# ただでターンを終えられる。
GATE="$TMP/armed-gate"
PROFILES="$TMP/profiles"; mkdir -p "$PROFILES"
SCRATCH="$TMP/scratch"; mkdir -p "$SCRATCH"
git -C "$SCRATCH" init -q
git -C "$SCRATCH" remote add origin git@github.com:example/headless.git
echo x > "$SCRATCH/a.txt"; git -C "$SCRATCH" add -A
git -C "$SCRATCH" -c user.email=t@t -c user.name=t commit -qm init
cat > "$PROFILES/headless.json" <<'JSON'
{ "match": { "remote": "example/headless" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
DOTAGENTS_GATE_DIR="$GATE" bash "$REPO/scripts/gate.sh" arm "$SCRATCH" >/dev/null 2>&1

( cd "$SCRATCH" && TERM=dumb DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" \
    bash "$REPO/hooks/dotagents-verify-gate.sh" >/dev/null 2>&1 <&- )
armed_code=$?
[[ "$armed_code" == "2" ]] \
  && ok "arm 済みのゲートはペイロードが読めなければ通さずブロックする（exit 2）" \
  || no "arm 済みのゲートが stdin を閉じた状態で exit ${armed_code} -- stdin を閉じてもターンを終えられてはならない"

echo

# ソースの走査。上の実行で到達しない構文も足せるので、ソースも読む。リダイレクトや here-string から
# 読む `read` は問題ない（ゲートは作業ファイルをそう読む）。止まるのは何も繋がっていない `read`。
offenders=""
for f in "$REPO"/scripts/*.sh "$REPO"/hooks/*.sh; do
  base="$(basename "$f")"
  # このファイルは禁じる構文を全部書いているので、含めると自分を報告する。
  [[ "$base" == "test-non-interactive.sh" ]] && continue
  hits="$(grep -nE 'read[[:space:]]+-[a-zA-Z]*p|/dev/tty|[^a-zA-Z_-]stty[[:space:]]|[^a-zA-Z_-]tput[[:space:]]' "$f" \
          | grep -v '^[[:space:]]*[0-9]*:[[:space:]]*#' || true)"
  [[ -n "$hits" ]] && offenders="$offenders
$base: $hits"
done
if [[ -z "${offenders// /}" ]]; then
  ok "端末から読むスクリプトは無い（read -p、/dev/tty、stty、tput なし）"
else
  no "端末から読むものがある:${offenders}"
fi

# `select` は対話メニューのためだけの bash 組み込み。止まらない使い方は無い。
if grep -qnE '^[[:space:]]*select[[:space:]]+[a-zA-Z_]' "$REPO"/scripts/*.sh "$REPO"/hooks/*.sh 2>/dev/null; then
  no "尋ねるためだけにある 'select' を使っているスクリプトがある"
else
  ok "'select' を使うスクリプトは無い"
fi

echo
if (( fail )); then
  printf '%s成功 %d 件、失敗 %d 件%s\n' "$c_red" "$pass" "$fail" "$c_off"; exit 1
fi
printf '%s✓ 成功 %d 件%s\n' "$c_green" "$pass" "$c_off"
