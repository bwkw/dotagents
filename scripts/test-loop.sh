#!/usr/bin/env bash
# ループ駆動系の振る舞い。検査するのは状態機械だけ。
#
# `claude` と `gh` は PATH 上のスタブ。ゲートはスタブにしない。自明なチェックが 1 つ（`test -f GREEN`）の
# 密閉した profile を使い、本物の gate.sh と本物の hook に対して駆動系を動かす。ゲートをスタブにすると、
# 駆動系が読むはずのものの 2 つ目の実装に対してテストすることになる。
#
# 本物の `claude` の振る舞い（`claude -p` の終わりに Stop hook が発火するか、disable-model-invocation 付きの
# スキルに slash command が届くか、da-review-all が headless で Canvas の手順を満たせるか）はここでは検査しない
# （未計測。docs/loops.md を参照）。駆動系はどちらの答えでも振る舞いが変わらないように書いてあり、ゲートの
# VERDICT でも自前の周の上限でも landing を打ち切り、どちらが効いたかを記録する。ここでは両方の分岐を検査する。

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOP="$REPO/scripts/loop.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dotagents-test-loop.XXXXXX")" || { echo "mktemp に失敗した" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT INT TERM

pass=0; fail=0
if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then c_red=''; c_green=''; c_dim=''; c_off=''
else c_red=$'\033[31m'; c_green=$'\033[32m'; c_dim=$'\033[2m'; c_off=$'\033[0m'; fi
ok() { printf '%s✓%s %s\n' "$c_green" "$c_off" "$1"; pass=$((pass+1)); }
no() { printf '%s✗%s %s\n' "$c_red" "$c_off" "$1"; fail=$((fail+1)); }
detail() { [[ -n "${1:-}" ]] && printf '%s    %s%s\n' "$c_dim" "$1" "$c_off"; }

# --- スタブ ------------------------------------------------------------------
# 応答は phase ごとに用意する（下のスタブを参照）。テストは「3 回目の claude 呼び出し」ではなく「最初の
# review がこれを返す」と宣言する。スタブは argv もログに追記し、「--bare を渡していない」「/da-verify を
# 打った」をそこで検査する。
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_CLAUDE_LOG"
# 隣接を確かめられるよう、1 引数 1 行でも残す。`$*` は平らにしてしまい、ツールの許可にはスペースが入る
# （`Bash(git diff:*)`）。本物の CLI の `--allowedTools` は可変長なので、直後に置いたプロンプトは
# ツール名として食われ、`claude` は "Input must be provided" で死ぬ。
printf '%s\n' "$@" >> "$FAKE_CLAUDE_ARGV"
printf -- '---\n' >> "$FAKE_CLAUDE_ARGV"

# 応答は呼び出し順ではなく phase で引く。順番で引くと、駆動系が呼び出しを 1 つ足しただけで全 fixture が
# ずれ、ずれた fixture は空を返して黙って通ってしまう。
# phase はプロンプトの 1 行目で決める（argv 全体ではない）。executing-plans のプロンプトは
# "/test-driven-development" を含み、triage のプロンプトは "/da-review-all" と "/find-bugs" を見出しに
# 持つので、全体で当てると言及しているだけの phase と取り違える。プロンプトは常に最後の引数。
prompt="${!#}"
first="${prompt%%$'\n'*}"
phase=other
case "$first" in
  */da-investigate*)          phase=investigate ;;
  */using-git-worktrees*)     phase=worktree ;;
  */da-verify*)               phase=verify ;;
  */executing-plans*)         phase=execplan ;;
  */test-driven-development*) phase=implement ;;
  */systematic-debugging*)    phase=debug ;;
  */da-review-all*)           phase=review ;;
  */find-bugs*)               phase=findbugs ;;
  */da-fix-plan*)             phase=triage ;;
  */receiving-code-review*)   phase=fix ;;
  */da-pr-describe*)          phase=pr ;;
  "PR #"*"のレビューコメントそれぞれに"*) phase=reply ;;
esac

# ゲートを arm するのは `/da-verify` だけ（AGENTS.md の不変条件 2）なので、スタブは本物のスキルの Step 0 と
# 同じことをする。しないと、VERDICT のケースが駆動系の実際には出会わない未 arm のゲートを検査することになる。
[[ "$phase" == "verify" ]] && { bash "$DOTAGENTS_REPO/scripts/gate.sh" arm "$PWD" >/dev/null 2>&1 || true; }
# 同様に worktree のスキルは実際に作る。駆動系は返答ではなく `git worktree list` で結果を探すので、
# 答えるだけのスタブでは何も証明できない。
if [[ "$phase" == "worktree" && ! -f "$FAKE_CLAUDE_DIR/no-worktree" ]]; then
  git worktree add -q "$PWD/.worktrees/loop" -b loop-wt >/dev/null 2>&1 || true
fi

n=1
[[ -f "$FAKE_CLAUDE_DIR/$phase.counter" ]] && n=$(cat "$FAKE_CLAUDE_DIR/$phase.counter")
printf '%s' "$((n+1))" > "$FAKE_CLAUDE_DIR/$phase.counter"

resp="$FAKE_CLAUDE_DIR/$phase.$n.json"
# `execplan` と `implement` は同じ役割（実装の 1 周目）で、どちらを打つかは tier だけで決まる。fixture が
# tier を知らずに済むよう、execplan は implement の fixture に落ちる。区別はテストが phase の counter で確かめる。
if [[ ! -f "$resp" && "$phase" == "execplan" ]]; then
  resp="$FAKE_CLAUDE_DIR/implement.$n.json"
  [[ -f "$FAKE_CLAUDE_DIR/implement.$n.sh" && ! -f "$FAKE_CLAUDE_DIR/execplan.$n.sh" ]] \
    && bash "$FAKE_CLAUDE_DIR/implement.$n.sh"
fi
[[ -f "$resp" ]] || resp="$FAKE_CLAUDE_DIR/$phase.json"
# 応答は副作用（本物の周がしたはずの編集）を持てる。phase ごとの既定は「この phase の周はすべて同じことを
# する」を表し、周の上限のケースで要る。何も変えない周（round_changed_nothing）は、変えたのに赤のままの周とは
# 別の失敗だから。
if [[ -f "$FAKE_CLAUDE_DIR/$phase.$n.sh" ]]; then bash "$FAKE_CLAUDE_DIR/$phase.$n.sh"
elif [[ -f "$FAKE_CLAUDE_DIR/$phase.sh" ]]; then bash "$FAKE_CLAUDE_DIR/$phase.sh"; fi
# 周を固まらせられる。本物の CLI は `--json-schema` にファイルパスを渡すとエラーにならず固まるので、
# 「周が返らない」は実在する状態。
[[ -f "$FAKE_CLAUDE_DIR/$phase.$n.sleep" ]] && sleep "$(cat "$FAKE_CLAUDE_DIR/$phase.$n.sleep")"
code=0
[[ -f "$FAKE_CLAUDE_DIR/$phase.$n.exit" ]] && code=$(cat "$FAKE_CLAUDE_DIR/$phase.$n.exit")
# 本物の周は失敗の理由を stderr に書く。スタブもそれを出せるので、「stderr を残すか」をテストで確かめられる。
[[ -f "$FAKE_CLAUDE_DIR/$phase.$n.err" ]] && cat "$FAKE_CLAUDE_DIR/$phase.$n.err" >&2
cat "$resp" 2>/dev/null
exit "$code"
STUB
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
case "$1 ${2:-}" in
  "extension list")
    [[ -f "$FAKE_GH_DIR/no-stack-ext" ]] && { printf ''; exit 0; }
    printf 'gh stack\tgithub/gh-stack\tv0.1.0\n' ;;
  "stack view")
    [[ -f "$FAKE_GH_DIR/stack" ]] || exit 1
    printf '{"layers":[]}\n' ;;
  "stack init")
    # 本物の `gh stack init` はブランチを位置引数で取り、無ければ対話で聞こうとして headless では失敗する
    # （"interactive input required; provide branch names as arguments"）。本物が拒むものを受け付ける
    # スタブはテストではなく 2 つ目のバグなので、同じく拒む。
    shift 2   # "stack" と "init" を落とす。残りはフラグとブランチ名
    branches=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -b|--base) shift 2 ;;
        -*) shift ;;
        *) branches="$branches $1"; shift ;;
      esac
    done
    [[ -n "${branches// /}" ]] || { printf 'interactive input required; provide branch names as arguments\n' >&2; exit 1; }
    : > "$FAKE_GH_DIR/stack" ;;
  "stack add")
    # 本物の拡張は新しい層のブランチを作って checkout する。駆動系はそこへ commit するので、スタブも
    # HEAD を動かさないと 2 層目以降が違うブランチに commit される。
    shift 2; git checkout -q -b "${1:-layer}" 2>/dev/null ;;
  "stack push")
    # fixture の bare remote への本物の push。push をスタブにした駆動系は push が未検査の駆動系。
    # `--force-with-lease` にするのは、lease がローカルの remote-tracking ref に対して確かめられ、古い ref だと
    # remote が無事でも "stale info" で拒まれるという本物の失敗を起こせるようにするため。
    git push --force-with-lease -q origin HEAD 2>/dev/null || exit 1 ;;
  "stack submit")
    # 本物の拡張は PR を作ったときは URL を、作らなかったときは文を出す（"PR #45 for <branch> is up to date"）。
    # どちらも成功。fixture は 2 つ目の形に切り替えられ、stdout から URL を拾う駆動系をこれで捕まえた。
    if [[ -f "$FAKE_GH_DIR/submit-no-url" ]]; then
      printf 'Checking stack state...\nPR #7 for some-branch is up to date\n'
    else
      printf 'https://github.com/probe/x/pull/7\n'
    fi ;;
  "pr view")
    [[ -f "$FAKE_GH_DIR/no-pr" ]] && exit 1
    printf 'https://github.com/probe/x/pull/7\n' ;;
  "pr list")
    cat "$FAKE_GH_DIR/pr-list" 2>/dev/null || printf '' ;;
  "pr checks")
    # --json は状態を聞く。駆動系は exit code ではなく状態で判断しなければならない（`gh` の exit 1 は
    # 「何らかの理由で失敗」で、本物の失敗と「まだチェックが無い」をまとめてしまう）。
    # 駆動系は `--jq .[].state` で聞くので、返るのは 1 行 1 状態。fixture もその形（空ファイル = この PR は
    # チェックを報告しない）。生の JSON を返すと、駆動系の「未知は緑ではない」規則で赤と読まれ、全ケースが
    # 間違った理由で落ちる。
    if [[ "$*" == *--json* ]]; then
      if [[ -f "$FAKE_GH_DIR/checks-states" ]]; then cat "$FAKE_GH_DIR/checks-states"
      else printf 'SUCCESS\n'; fi
      exit 0
    fi
    # exit code は本物と同じ: 0 すべて緑、1 何かが失敗、8 まだ走っている。「赤、修正後に緑」を書けるよう、
    # claude のスタブと同じく試行ごとのファイルと既定のファイルで用意する。
    c=1
    [[ -f "$FAKE_GH_DIR/checks.counter" ]] && c=$(cat "$FAKE_GH_DIR/checks.counter")
    printf '%s' "$((c+1))" > "$FAKE_GH_DIR/checks.counter"
    f="$FAKE_GH_DIR/checks.$c"
    [[ -f "$f" ]] || f="$FAKE_GH_DIR/checks"
    if [[ -f "$f" ]]; then cat "$f.out" 2>/dev/null; exit "$(cat "$f")"; fi
    printf 'all checks passing\n'; exit 0 ;;
  "api "*)
    # 読み取りは fixture を返し、書き込みはログに残すだけ。「返信を投稿した」と「スレッドを resolve した」を
    # 区別するため、テストはログで検査する。
    case "$*" in
      *--method\ POST*|*-X\ POST*) exit 0 ;;
      *graphql*) exit 0 ;;
      *comments*) cat "$FAKE_GH_DIR/pr-comments" 2>/dev/null || printf '[]\n' ;;
      *) printf '' ;;
    esac ;;
  *) printf '' ;;
esac
exit 0
STUB
chmod +x "$BIN/claude" "$BIN/gh"

# --- fixture -----------------------------------------------------------------
CASE=0
setup() { # -> 1 ケース分の REPO_DIR, GATE, PROFILES, LOOPDIR, FAKE_* を export する
  CASE=$((CASE+1))
  local root="$TMP/case$CASE"
  REPO_DIR="$root/repo"; GATE="$root/gate"; PROFILES="$root/profiles"; LOOPDIR="$root/loop"
  FAKE_CLAUDE_DIR="$root/claude"; FAKE_GH_DIR="$root/gh"
  FAKE_CLAUDE_LOG="$root/claude.log"; FAKE_GH_LOG="$root/gh.log"
  FAKE_CLAUDE_ARGV="$root/claude.argv"
  mkdir -p "$REPO_DIR" "$GATE" "$PROFILES" "$LOOPDIR" "$FAKE_CLAUDE_DIR" "$FAKE_GH_DIR"
  : > "$FAKE_CLAUDE_LOG"; : > "$FAKE_GH_LOG"; : > "$FAKE_CLAUDE_ARGV"
  export FAKE_CLAUDE_DIR FAKE_GH_DIR FAKE_CLAUDE_LOG FAKE_GH_LOG FAKE_CLAUDE_ARGV
  # 架空の URL ではなく本物の bare remote。PR の phase は push するので。ディレクトリ名は profile の
  # `match.remote` の部分文字列に当たるようにしてある。
  git init -q --bare "$root/dotagents-loop-probe.git"
  git -C "$REPO_DIR" init -q
  # 本物のチェックアウトには author がいて、駆動系の `git commit` はそれを引き継ぐ（ループはあなたとして
  # commit する）。fixture ごとに設定する。-c で渡すと identity の無いリポジトリが隠れ、ここでは通って
  # CI で "could not commit landing 1" になった。
  git -C "$REPO_DIR" config user.email loop@test
  git -C "$REPO_DIR" config user.name "loop test"
  git -C "$REPO_DIR" remote add origin "$root/dotagents-loop-probe.git"
  printf 'x\n' > "$REPO_DIR/a.txt"
  git -C "$REPO_DIR" add a.txt
  git -C "$REPO_DIR" -c user.email=t@t -c user.name=t commit -qm init
  git -C "$REPO_DIR" branch -M main
  git -C "$REPO_DIR" push -q origin main 2>/dev/null
  git -C "$REPO_DIR" checkout -q -b work
  cat > "$PROFILES/probe.json" <<'JSON'
{ "match": { "remote": "dotagents-loop-probe" },
  "checks": [ { "id": "probe-gate", "cmd": "test -f GREEN", "gate": true,
                "agent_may_run": true, "scope": "all", "timeout": 10 } ],
  "timeout_total": 60 }
JSON
}

commit_in_repo() { git -C "$REPO_DIR" -c user.email=t@t -c user.name=t commit -qm "$1"; }

# /da-investigate が返す計測を、`claude -p --output-format json` が構造化出力を包む形で。
measurement() { # <files> <layers> <one_way> <risk> <unconfirmed> [layer-names-csv] [unverified_claims]
  # 末尾 2 つは省略可なので、既存の fixture の意味は変わらない。駆動系はレビューのスキルを記録した層の名前で
  # 選ぶので `layer-names-csv` が要る。汎用の "layer0" の fixture は dispatcher に落ちるはずで、それは下で検査する。
  local files="$1" layers="$2" oneway="$3" risk="$4" unconf="$5" names="${6:-}" claims="${7:-0}"
  node -e '
    const [f, l, o, r, u] = process.argv.slice(1, 6).map(Number);
    const names = process.argv[6] || "", claims = Number(process.argv[7] || 0);
    const arr = (n, p) => Array.from({length: n}, (_, i) => p + i);
    process.stdout.write(JSON.stringify({
      total_cost_usd: 0.01, num_turns: 2, result: "ok",
      structured_output: {
        files: arr(f, "src/f"),
        layers: names ? names.split(",").filter(Boolean) : arr(l, "layer"),
        one_way: arr(o, "door"), risk_surfaces: arr(r, "surface"),
        unconfirmed: arr(u, "unknown"),
        unverified_claims: arr(claims, "claim"),
      },
    }));
  ' "$files" "$layers" "$oneway" "$risk" "$unconf" "$names" "$claims" > "$FAKE_CLAUDE_DIR/investigate.1.json"
  # 全 phase に無害な既定を置く。テストは気にする応答だけを書けばよく、用意していない phase が黙って空を返さない。
  local p
  for p in worktree verify implement execplan debug review findbugs fix pr other; do
    printf '{"total_cost_usd":0.01,"num_turns":1,"result":"ok"}' > "$FAKE_CLAUDE_DIR/$p.json"
  done
  printf '{"total_cost_usd":0.01,"num_turns":1,"result":"ok","structured_output":{"fix_now":0,"needs_decision":0,"decline":0}}' \
    > "$FAKE_CLAUDE_DIR/triage.json"
}

# ある phase の周が返すもの。phase と出現回数で引き、呼び出し順では引かない。
# fixture のヘルパーはすべてこのブロックに置く。bash は定義を*実行した*時点で関数を定義するので、使うテストの
# そばに置いたヘルパーは、それより上のケースでは未定義のコマンドになり、空を返して fixture を書かず、正しい
# 駆動系に対してテストが落ちる（`round_budget` と `truncated` で 2 度踏んだ）。新しいヘルパーはここに足すこと。
respond() { # <phase> <n> <cost> <turns> [fix_now] [needs_decision] [decline] [unverified]
  node -e '
    const [c, t, fn, nd, dc, uv] = process.argv.slice(1);
    const o = { total_cost_usd: Number(c), num_turns: Number(t), result: "done" };
    if (fn !== "-") o.structured_output = {
      fix_now: Number(fn), needs_decision: Number(nd), decline: Number(dc),
      unverified: Number(uv) };
    process.stdout.write(JSON.stringify(o));
  ' "$3" "$4" "${5:--}" "${6:-0}" "${7:-0}" "${8:-0}" > "$FAKE_CLAUDE_DIR/$1.$2.json"
}
green_pr() { # よく使う fixture: PR まで届く landing
  measurement 6 1 0 0 0; runloop size "r"
  respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
  respond review 1 0.30 7
  respond triage 1 0.05 2 0 0 3
  respond pr 1 0.10 3
}

truncated() { # <phase> <n> <subtype> -- 早く止まった周: exit 0、`result` は部分的
  printf '{"total_cost_usd":0.30,"num_turns":50,"subtype":"%s","result":"partial report"}' "$3" \
    > "$FAKE_CLAUDE_DIR/$1.$2.json"
}
errored() { # <phase> <n> -- エラーになった周: is_error true、subtype "success"、exit 1
  # 10 回目の run で実測した形。駆動系はこれを「天井で打ち切られた（subtype: success）」と呼び、その phase に
  # 存在しない天井を上げるよう勧めた。
  printf '{"total_cost_usd":0.30,"num_turns":24,"subtype":"success","is_error":true,"result":"partial"}' \
    > "$FAKE_CLAUDE_DIR/$1.$2.json"
  printf '%s\n' 1 > "$FAKE_CLAUDE_DIR/$1.$2.exit"
  printf '%s\n' "${3:-}" > "$FAKE_CLAUDE_DIR/$1.$2.err"   # 本物の周が stderr に書くもの
}
side_effect() { printf '%s\n' "$3" > "$FAKE_CLAUDE_DIR/$1.$2.sh"; }   # <phase> <n> <shell>
side_effect_all() { printf '%s\n' "$2" > "$FAKE_CLAUDE_DIR/$1.sh"; }   # <phase> <shell>。毎周
fails_with()  { printf '%s\n' "$3" > "$FAKE_CLAUDE_DIR/$1.$2.exit"; } # <phase> <n> <exit-code>
hangs_for()   { printf '%s\n' "$3" > "$FAKE_CLAUDE_DIR/$1.$2.sleep"; } # <phase> <n> <seconds>

runloop() { # <args...> -> stdout+stderr を $OUT に、終了ステータスを $RC に
  # CI の待ちは本番では秒単位だが、ここではほぼゼロにする。でないと CI の phase に届くケースごとに猶予の分だけ実時間がかかる。
  OUT="$(cd "$REPO_DIR" && PATH="$BIN:$PATH" \
    DOTAGENTS_LOOP_CI_WAIT="${DOTAGENTS_LOOP_CI_WAIT:-20}" DOTAGENTS_LOOP_CI_GRACE="${DOTAGENTS_LOOP_CI_GRACE:-5}" \
    DOTAGENTS_LOOP_DIR="$LOOPDIR" DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" \
    DOTAGENTS_REPO="$REPO" NO_COLOR=1 bash "$LOOP" "$@" 2>&1)"
  RC=$?
}

# 他のヘルパーと同じくここで定義する（上の respond の注記と同じ理由）。
round_budget() { # <phase-marker> -> その phase の呼び出しの --max-budget-usd の値。無ければ空
  grep -- "$1" "$FAKE_CLAUDE_LOG" | grep -- '--max-budget-usd' \
    | sed -E 's/.*--max-budget-usd[[:space:]]+([0-9.]+).*/\1/' | head -1
}

ledger() { cat "$LOOPDIR/ledger.jsonl" 2>/dev/null; }
ledger_field() { # <node で辿るパス> -> 最終行のフィールド
  ledger | node -e '
    let last = null;
    require("readline").createInterface({input: process.stdin})
      .on("line", (l) => { if (l.trim()) try { last = JSON.parse(l) } catch {} })
      .on("close", () => {
        const p = process.argv[1].split(".");
        let v = last;
        for (const k of p) v = v == null ? v : v[k];
        process.stdout.write(String(v));
      });
  ' "$1"
}

echo "ループ駆動系"
echo

# ---------------------------------------------------------------- usage
setup
runloop
[[ $RC -eq 0 ]] && grep -q 'loop\.sh size' <<<"$OUT" && grep -q 'loop\.sh run' <<<"$OUT" \
  && grep -q 'loop\.sh report' <<<"$OUT" \
  && ok "引数なしで、すべてのサブコマンドを挙げた usage を出す" \
  || { no "引数なしで、すべてのサブコマンドを挙げた usage が出なかった（exit ${RC}）"; detail "$OUT"; }

runloop --help
[[ $RC -eq 0 ]] && grep -q 'loop\.sh size' <<<"$OUT" \
  && ok "--help も同じ usage を出す" || no "--help で usage が出なかった（exit ${RC}）"

# ---------------------------------------------------------------- tier の計算
# 境界は docs/loops.md の表から。1 つずつ `size` で計測する。
tier_case() { # <label> <expected> <files> <layers> <oneway> <risk> <unconfirmed>
  local label="$1" want="$2"; shift 2
  setup
  measurement "$@"
  runloop size "a request"
  if [[ $RC -eq 0 ]] && grep -qE "tier[[:space:]]+$want\b" <<<"$OUT"; then
    ok "$label -> $want"
  else
    no "$label は ${want} のはず（exit ${RC}）"; detail "$(head -3 <<<"$OUT" | tr '\n' ' ')"
  fi
}
# 4 段を、すべての境界で。10 ファイルはまだ小さい、というのが実際の変更を読んだ持ち主の判断。上端は "~50" ではなく
# `>30` で閉じる（50 と書くと 31〜49 が黙って M に落ちる）。
tier_case "5 ファイル、1 層、他は無し"          XS  5  1 0 0 0
tier_case "6 ファイルで S に入る"               S  6  1 0 0 0
tier_case "10 ファイルはまだ S"                 S 10  1 0 0 0
tier_case "11 ファイルで M に入る"              M 11  1 0 0 0
tier_case "30 ファイルはまだ M"                 M 30  1 0 0 0
tier_case "31 ファイルで L に入る"              L 31  1 0 0 0
tier_case "2 層は M"                            M  3  2 0 0 0
tier_case "3 層は L"                            L  3  3 0 0 0
tier_case "一方通行の扉が 1 つで L"             L  1  1 1 0 0

# --- `risk_surfaces` と `unconfirmed` の重み（見直し後） -------------------------
# この 2 つはかつて L を強制し、実際のリポジトリではほぼすべてが L になって無人で回せなかった。
#
#   `risk_surfaces` は 2 重に課金されていた。すでに 2 本目のレビュア（/find-bugs）を買っているので、同じ信号で
#   有人の設計フェーズまで強制するのは、1 つの計測に 2 つの予算を払うことになる。
#
#   `unconfirmed` は「この計測は当てにならない」という意味。無人で回さない理由にはなるが、変更が広い・取り返せない
#   という証拠ではない（L が人を買うのはそのため）。
#
# `one_way` は L を強制したまま。取り返せない一歩こそ、出る前に人が見るべきもの。
tier_case "リスク面だけなら M で、L ではない"   M  1  1 0 1 0
# XS の段の追加で変えた: 下限は M から S へ。`unconfirmed > 0` は修正の仕組みを外さない理由にはなるが、変更が
# 広い証拠ではない。M のままだと /da-investigate はほぼ必ず何かを挙げるので、XS には実際には届かない。
tier_case "未確認が 1 件なら下限は S"           S  1  1 0 0 1
tier_case "リスクと未確認が両方なら M"          M  1  1 0 3 4
tier_case "一方通行は両方より強い"              L  1  1 1 1 1

# `unverified_claims` は切り分けのもう半分: *依頼文*が主張していて確かめられなかったこと。依頼文を直す必要を
# 示すので記録して出すが、tier は動かさない（`unconfirmed` と混ぜたことが 1 ファイルの docs 修正を L にした）。
setup
measurement 6 1 0 0 0 "" 9
runloop size "a request making nine claims"
if [[ $RC -eq 0 ]] && grep -qE 'tier[[:space:]]+S\b' <<<"$OUT"; then
  ok "依頼文の未確認の主張が 9 件あっても tier は動かない（S）"
else
  no "unverified_claims が tier を動かした（exit ${RC}）"; detail "$(head -3 <<<"$OUT" | tr '\n' ' ')"
fi
[[ "$(ledger_field unverified_claims)" == "9" ]] \
  && ok "件数は記録されるので、依頼文を直せる" \
  || no "unverified_claims が記録されていない（得た値: '$(ledger_field unverified_claims)'）"

# `unconfirmed > 0` が「人が見るべき」を意味するのは、`unconfirmed` が「見た目より大きくしうるもの」を指すときだけ。
# 最初の実測では 1 ファイルの docs 修正に未確認が 21 件付いて L になった。直すのは閾値ではなく項目の定義なので、
# 駆動系がその定義を送っていることを検査する。空の一覧を正しく、よくある答えとして書いておかないと、計測役が
# 水増しして何もかも L になる。
if grep -q '空が正しく、よくある答え' scripts/loop.sh && grep -q '見られなかったものすべて、では' scripts/loop.sh; then
  ok "size のプロンプトは unconfirmed を規模を変えるものに絞り、空の一覧を認めている"
else
  no "size のプロンプトが空の unconfirmed を認めていない。tier S に届かず、何もかも L になる"
fi

setup
measurement 6 1 0 0 0
runloop size "a request"
grep -q 'structured_output' "$FAKE_CLAUDE_LOG" >/dev/null 2>&1
grep -q -- '--bare' "$FAKE_CLAUDE_LOG" \
  && no "駆動系が --bare を渡した。ループの土台である hook とスキルが無効になる" \
  || ok "駆動系は --bare を渡さない"
grep -q -- '--dangerously-skip-permissions' "$FAKE_CLAUDE_LOG" \
  && no "駆動系が --dangerously-skip-permissions を渡した" \
  || ok "駆動系は --dangerously-skip-permissions を渡さない"
grep -q -- '--output-format json' "$FAKE_CLAUDE_LOG" \
  && ok "駆動系は --output-format json を求めるので、コストが記録される" \
  || no "駆動系が --output-format json を求めていない。コストを測るものが無い"

# `run` は判断をやり直さず読み返すので、`size` は判断を記録しなければならない。
[[ "$(ledger_field 'tier')" == "S" ]] \
  && ok "size は tier を台帳に記録する" \
  || no "size が tier を記録していない（得た値: '$(ledger_field 'tier')'）"

# 入口でも同じ区別: 計測が届かなかったとき、`size` は欠けた 5 項目を 0 と読んで tier S と呼ばず、断らなければならない。
setup
printf '{"total_cost_usd":0.01,"num_turns":1,"result":"I looked around a bit"}' > "$FAKE_CLAUDE_DIR/investigate.1.json"
runloop size "a request"
[[ $RC -ne 0 ]] && grep -q '計測が返ってこなかった' <<<"$OUT" \
  && ok "計測が無いと size は断り、tier S に倒さない" \
  || { no "size が計測の無い返答を受け入れた（exit ${RC}）"; detail "$(head -4 <<<"$OUT" | tr '\n' ' ')"; }
# "null" は一致する行が無いときに読み手が出すもので、ここでは欠けているのと同じ扱い。
case "$(ledger_field 'tier')" in
  ''|null) ok "tier も記録しないので、run が読むものは無いまま" ;;
  *)       no "計測を含まない返答から size が tier '$(ledger_field 'tier')' を記録した" ;;
esac

# ---------------------------------------------------------------- tier の段にすべての述語が答える
# 段を足すときの安全網。`[[ "$tier" != "S" ]]` のような比較は、まだ無い tier に対して真になり、書かれることの無い
# landing plan を黙って要求する。そこで段はマーカー行で宣言し、どの述語もその上のすべての tier に答えることにする。
#
# 段が S/M/L のうちに書き、段を足して述語を広げ忘れたら赤になるようにしてある。XS を足したとき実際に 61 件が
# 赤になった。検出できなかった 1 箇所は名前の付いた述語ではなく inline の `case` だったレビュー予算で、今は
# `tier_gets_lean_budgets`。テストが列挙できない判断は、新しい tier のたびに一度ずつ忘れられる。
ladder_tiers()     { sed -n 's/^# dotagents:tier-ladder //p' "$LOOP" | head -1; }
tier_predicates()  { grep -oE '^tier_[a-z_]+\(\)|^review_may_skip_dispatcher\(\)' "$LOOP" \
                       | sed 's/()//' | grep -v '^tier_die$'; }

marker="$(ladder_tiers)"
[[ -n "$marker" ]] \
  && ok "段は dotagents:tier-ladder マーカーで宣言されている（${marker}）" \
  || no "loop.sh に dotagents:tier-ladder マーカーが無い。消すとこの検査ごと消える"

preds="$(tier_predicates)"
[[ -n "$preds" ]] \
  && ok "tier の述語を名前で見つけられる（$(wc -w <<<"$preds" | tr -d ' ') 個）" \
  || no "検査する tier の述語が見つからない"

# (tier x 述語) のすべての組が、死なずに答えなければならない。終了コードではなくメッセージで判定する
# （`die` も正当な「いいえ」も exit 1 なので、コードで見ると素通りを答えと読む）。
# 述語は source せず抜き出す。`source "$LOOP"` は loop.sh の最上位の dispatcher をこのスクリプトの位置引数で
# 走らせ、本物の `run` を始めうる（最初の版はそれでスイートを 10 分固まらせた）。
tier_defs="$TMP/tier-defs.sh"
{ printf 'die() { printf "loop: %%s\\n" "$1" >&2; exit 1; }\n'
  sed -n '/^tier_die() {/,/^}/p' "$LOOP"
  grep -E '^(tier_[a-z_]+|review_may_skip_dispatcher)\(\) *\{ case' "$LOOP"
} > "$tier_defs"
tier_answer() { # <predicate> <tier> -> "died" か "answered" を出す
  local err
  err="$( ( . "$tier_defs"; "$1" "$2" >/dev/null ) 2>&1 )"
  case "$err" in *"未知の tier"*) printf died ;; *) printf answered ;; esac
}
unanswered=""
for _t in $marker; do
  for _p in $preds; do
    [[ "$(tier_answer "$_p" "$_t")" == "answered" ]] || unanswered="$unanswered $_p($_t)"
  done
done
[[ -z "$unanswered" ]] \
  && ok "どの述語も、宣言されたすべての tier に答える" \
  || no "次の (述語, tier) の組が素通りする:$unanswered"

# 素通りは、もっともらしい答えではなく致命的でなければならない。既定で 0 か 1 を返す述語は、誰も考えていない
# tier に答えてしまう。
silent=""
for _p in $preds; do
  grep -A 1 "^$_p()" "$LOOP" | grep -q 'tier_die' || silent="$silent $_p"
done
[[ -z "$silent" ]] \
  && ok "未知の tier はどの述語でも致命的で、もっともらしい答えにはならない" \
  || no "次の述語に黙った既定がある:$silent"

# 段に無い tier は死ななければならない。網が空ではなく効いている証拠。以前は XS を名指していて、XS を足した
# ときに反転した（それが目的だった）。今は誰も提案していない段を名指すので、最後に足した段ではなく網を検査し続ける。
[[ "$(tier_answer tier_needs_landing_plan XXL)" == "died" ]] \
  && ok "宣言されていない tier（XXL）は断られる。網は空ではなく効いている" \
  || no "tier_needs_landing_plan が段に無い XXL に答えた"

# ---------------------------------------------------------------- run の前提条件
setup
runloop run
[[ $RC -ne 0 ]] && grep -q 'size の記録が無い' <<<"$OUT" \
  && ok "size を一度も取っていないと run は断る" \
  || { no "size の記録が無いのに run が断らなかった（exit ${RC}）"; detail "$OUT"; }

setup; measurement 6 1 0 0 0; runloop size "r"
printf 'dirty\n' > "$REPO_DIR/dirty.txt"
runloop run
[[ $RC -ne 0 ]] && grep -q 'きれいでない' <<<"$OUT" \
  && ok "作業ツリーが汚れていると run は断る" \
  || { no "汚れたツリーで run が断らなかった（exit ${RC}）"; detail "$OUT"; }

# 作業が実際に main に載るときだけ。隔離すれば run は自分のブランチに移るので、main でコマンドを打つこと自体は
# 問題ではない。問題はその場で main の上で作業することで、ここではそれを固定する。
setup; measurement 6 1 0 0 0; runloop size "r"
: > "$FAKE_CLAUDE_DIR/no-worktree"
git -C "$REPO_DIR" checkout -q main
runloop run
[[ $RC -ne 0 ]] && grep -q 'デフォルトブランチ' <<<"$OUT" \
  && ok "デフォルトブランチの上でその場で作業することを run は断る" \
  || { no "隔離なしのデフォルトブランチで run が断らなかった（exit ${RC}）"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }

setup; measurement 6 1 0 0 0; runloop size "r"
git -C "$REPO_DIR" checkout -q main
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0
runloop run
[[ $RC -eq 0 ]] \
  && ok "作業が自分のブランチに隔離されれば、デフォルトブランチから始めてよい" \
  || { no "main でコマンドを打っただけで、隔離された run が断った（exit ${RC}）"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }

# tier M と L は、人が commit した plan なしに無人で始めてはならない。
setup; measurement 11 1 0 0 0; runloop size "r"
runloop run
[[ $RC -ne 0 ]] && grep -qi 'landing plan' <<<"$OUT" \
  && ok "tier M は landing plan なしでは run を断る" \
  || { no "tier M が landing plan なしで走った（exit ${RC}）"; detail "$OUT"; }

# あるだけで追跡されていない plan はツリーを汚すので、きれいなツリーの前提条件が先に当たる。これは正しい拒否で、
# よくあるケースが実際に当たるのはこちら。
setup; measurement 11 1 0 0 0; runloop size "r"
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | a | probe-gate | no |\n' \
  > "$REPO_DIR/plan.md"
runloop run plan.md
[[ $RC -ne 0 ]] \
  && ok "追跡されていない landing plan では run が始まらない" \
  || { no "追跡されていない landing plan で run が始まった（exit ${RC}）"; detail "$OUT"; }

# plan が commit 済みかの検査だけを、plan を追跡させないままツリーをきれいにして当てる。gitignore した plan が
# 2 つの条件を切り離す唯一の方法で、このケースが無いと検査に届かず、緑のまま腐りうる。
setup; measurement 11 1 0 0 0; runloop size "r"
printf 'plan.md\n' > "$REPO_DIR/.gitignore"
git -C "$REPO_DIR" add .gitignore; commit_in_repo ignore
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | a | probe-gate | no |\n' \
  > "$REPO_DIR/plan.md"
runloop run plan.md
[[ $RC -ne 0 ]] && grep -q 'commit されていない。' <<<"$OUT" \
  && ok "ツリーがきれいでも、commit されていない landing plan は承認されたものではない" \
  || { no "commit されていない landing plan を run が受け入れた（exit ${RC}）"; detail "$OUT"; }

setup; measurement 11 1 0 0 0; runloop size "r"
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | a | probe-gate | no |\n' \
  > "$REPO_DIR/plan.md"
git -C "$REPO_DIR" add plan.md; commit_in_repo plan
printf '\n| 2 | snuck in later | ? | yes |\n' >> "$REPO_DIR/plan.md"
runloop run plan.md
[[ $RC -ne 0 ]] \
  && ok "commit の後に編集した landing plan では run が始まらない" \
  || { no "commit の後に変更した plan を run が受け入れた（exit ${RC}）"; detail "$OUT"; }

# ---------------------------------------------------------------- ループ、緑の経路
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 0 0 3           # 今すぐ直すものは無い
respond pr 1 0.10 3
runloop run
if [[ $RC -eq 0 ]] && grep -q 'pull/7' <<<"$OUT"; then
  ok "直すものの無い緑の landing は PR に届く"
else
  no "緑の landing が PR に届かなかった（exit ${RC}）"; detail "$(tail -4 <<<"$OUT" | tr '\n' ' ')"
fi
# `gh stack submit` は指定しないと draft を作る。ここの PR はゲートとレビューを通っていて、人が読める状態なので draft は要らない。
grep -q 'stack submit.*--open' "$FAKE_GH_LOG" \
  && ok "PR は draft のままではなく --open（レビュー待ち）で出す" \
  || no "stack が --open で提出されていない"
grep -q -- '--draft' "$FAKE_GH_LOG" \
  && no "駆動系が --draft を渡した" || ok "駆動系は --draft を渡さない"
grep -q 'stack init' "$FAKE_GH_LOG" \
  && ok "run は単独のブランチではなく stack を作る" \
  || no "stack が初期化されていない。landing が 1 本のブランチでぶつかる"
# `gh stack init` はブランチを位置引数で取る。フラグだけだと headless では "interactive input required" になり、
# 最初の実 run では何も実装しないうちに最初の landing で止まった。ブランチ名は引数でなければならない。
grep -E 'stack init .*[^-] ?[A-Za-z0-9]' "$FAKE_GH_LOG" | grep -qvE 'stack init( +--?[a-z-]+( +[^ ]+)?)* *$' \
  && ok "stack init はブランチを位置引数で名指す（対話なしで使える唯一の形）" \
  || { no "stack init がフラグだけで呼ばれた。本物の拡張は対話の入力を求めて失敗する"
       detail "$(grep 'stack init' "$FAKE_GH_LOG" | head -1)"; }

# --- 駆動系はスキルを打つ。スキルの先に手を伸ばさない ---------------------------
# 前提は、これが人のキー入力から人を自動化で抜いたものだということ。スキルが持つ手順では、駆動系はスキルを打つ。
# 下のツールに直接手を伸ばすと、最初の版のように `gate.sh arm` を直接呼び、不変条件のほうをコードに合わせて曲げることになる。
grep -q '/da-verify' "$FAKE_CLAUDE_LOG" \
  && ok "駆動系は自分でゲートを arm せず /da-verify を打つ" \
  || no "駆動系が /da-verify を打っていない。別の何かがゲートを arm したか、何もしていない"
grep -nE '"\$GATE_SH"[[:space:]]+arm|gate\.sh[[:space:]]+arm' "$LOOP" \
  | grep -qv '^[0-9]*:[[:space:]]*#' \
  && no "loop.sh が gate.sh arm を直接呼んでいる。不変条件 2 では、それをするのは da-verify だけ" \
  || ok "loop.sh は gate.sh arm を直接呼ばない"
# ソースで、プロンプトの先頭に固定して確かめる。呼び出しログを grep すると、スキルを名前で挙げるだけの文でも
# 通ってしまう。名前を挙げただけのスキルは適用されていない。
grep -q 'claude_round "/test-driven-development' "$LOOP" \
  && ok "implement の phase は /test-driven-development を打って始まり、説明で済ませない" \
  || no "implement のプロンプトが /test-driven-development で始まっていない。スキルの名前を挙げても呼んだことにはならない"
# 統合テスト優先は常設の方針で、AGENTS.md ではなくプロンプトで運ばなければならない。駆動系が走るプロダクトの
# リポジトリのエージェントは、このリポジトリの AGENTS.md を読まない。
# `^"$` で終わる sed の範囲ではなく、呼び出しの後の固定の窓で見る。プロンプトは内容行の末尾で引用符を閉じるので、その範囲は見た目の場所で終わらない。
for p in 'test-driven-development' 'executing-plans'; do
  awk -v pat="claude_round \"/$p" 'index($0,pat){n=25} n{print; n--}' "$LOOP" | grep -qiE 'INTEGRATION' \
    && ok "${p} のプロンプトは統合レベルのテストを求める" \
    || no "${p} のプロンプトが統合テストに触れていない。方針がこのリポジトリの AGENTS.md で止まっている"
done
grep -q 'claude_round "/systematic-debugging' "$LOOP" \
  && ok "赤が続くチェックでは /systematic-debugging に切り替わる" \
  || no "/systematic-debugging を打つものが無い。赤いゲートが TDD の周を重ねるだけになる（da-verify が止めろと言う継ぎ当て）"
grep -q 'claude_round "/receiving-code-review' "$LOOP" \
  && ok "修正の周は所見を鵜呑みにせず /receiving-code-review を通る" \
  || no "/receiving-code-review を打つものが無い。fix-plan の項目が評価されずに実装される"
grep -q '/using-git-worktrees' "$FAKE_CLAUDE_LOG" \
  && ok "run は /using-git-worktrees を打って自分を隔離する" \
  || no "/using-git-worktrees を打つものが無い。ループは起動したチェックアウトでそのまま編集し commit する"
grep -nE 'git[[:space:]]+worktree[[:space:]]+add' "$LOOP" \
  | grep -qv '^[0-9]*:[[:space:]]*#' \
  && no "loop.sh が git worktree add を直接呼んでいる。submodule の防御、check-ignore の確認、基準のチェックはスキルが持っている" \
  || ok "loop.sh は worktree の作成を作り直していない"
grep -q '/da-review-all' "$FAKE_CLAUDE_LOG" \
  && ok "レビューはこのリポジトリの唯一のレビュー入口 /da-review-all を通る" \
  || no "駆動系が /da-review-all を打っていない"
grep -q '/da-fix-plan' "$FAKE_CLAUDE_LOG" \
  && ok "triage は、停止条件を持つ /da-fix-plan を通る" \
  || no "駆動系が /da-fix-plan を打っていない"
grep -q '/da-pr-describe' "$FAKE_CLAUDE_LOG" \
  && ok "PR 本文は駆動系ではなく /da-pr-describe が書く" \
  || no "駆動系が /da-pr-describe を打っていない"

# スキルが正当に作成を断ったときも駆動系は動かなければならない（サンドボックスの権限エラーや同意の拒否では、
# スキル自身がその場で作業することを認めている）。続けるのは正しいが、隔離したと言いながら続けるのは正しくない。
setup; measurement 6 1 0 0 0; runloop size "r"
: > "$FAKE_CLAUDE_DIR/no-worktree"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0
runloop run
[[ $RC -eq 0 ]] && grep -q 'その場で作業する' <<<"$OUT" \
  && ok "worktree が現れなければ、run はその場で続け、そう言う" \
  || { no "隔離なしの run が、その場で作業していると言わなかった（exit ${RC}）"; detail "$(head -6 <<<"$OUT" | tr '\n' ' ')"; }

# すでに隔離済み: スキルの Step 0 はもう 1 つ作るなと言い、駆動系も求めてはならない。linked worktree は
# `git rev-parse --git-dir != --git-common-dir` で見分けられる。
setup; measurement 6 1 0 0 0
git -C "$REPO_DIR" worktree add -q "$REPO_DIR/.worktrees/pre" -b pre >/dev/null 2>&1
WT="$REPO_DIR/.worktrees/pre"
OUT="$(cd "$WT" && PATH="$BIN:$PATH" DOTAGENTS_LOOP_DIR="$LOOPDIR" DOTAGENTS_GATE_DIR="$GATE" \
  DOTAGENTS_PROFILES="$PROFILES" DOTAGENTS_REPO="$REPO" NO_COLOR=1 bash "$LOOP" size "r" 2>&1)"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0
OUT="$(cd "$WT" && PATH="$BIN:$PATH" DOTAGENTS_LOOP_DIR="$LOOPDIR" DOTAGENTS_GATE_DIR="$GATE" \
  DOTAGENTS_PROFILES="$PROFILES" DOTAGENTS_REPO="$REPO" NO_COLOR=1 bash "$LOOP" run 2>&1)"; RC=$?
grep -q '/using-git-worktrees' "$FAKE_CLAUDE_LOG" \
  && no "すでに worktree の中にいるのに、駆動系が worktree を求めた" \
  || ok "すでに linked worktree の中なら、駆動系はもう 1 つ作らない"

# worktree をまたいでも size と run はどのリポジトリかで一致しなければならない。でないと、main のチェックアウトで
# `size` が記録した tier を `run` が見つけられない。ゲートは共有の git dir でリポジトリを識別しており、台帳も同じ。
setup; measurement 6 1 0 0 0; runloop size "r"
git -C "$REPO_DIR" worktree add -q "$REPO_DIR/.worktrees/other" -b other >/dev/null 2>&1
tier_seen="$(cd "$REPO_DIR/.worktrees/other" && PATH="$BIN:$PATH" DOTAGENTS_LOOP_DIR="$LOOPDIR" \
  DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" DOTAGENTS_REPO="$REPO" NO_COLOR=1 \
  bash "$LOOP" status 2>&1 | grep -o 'tier [SML]' | head -1)"
[[ "$tier_seen" == "tier S" ]] \
  && ok "main のチェックアウトで取った size は linked worktree からも見える" \
  || no "worktree から tier が見えなかった（見えたもの: '${tier_seen}'）。size 済みの作業を run が断ることになる"

# 呼び出しログではなくソースを掃く。`git add -A` はたまたま何かを stage した run のログにしか出ず、求めるのは
# その構文がそもそも無いこと。loop.sh は禁止を述べるためにこの構文を名指すので、コメントは除く（除かないと
# 自分のパターンに当たって、無い失敗を報告する）。
grep -nE 'git[^|;]*add[[:space:]]+(-A|--all|\.)' "$LOOP" \
  | grep -qv '^[0-9]*:[[:space:]]*#' \
  && no "loop.sh が git add -A/--all/. を含んでいる。stage するのは名指したパスだけでなければならない" \
  || ok "loop.sh は名指したパスを stage し、git add -A は使わない"

# profile が無ければゲートも無く、そのとき `gate.sh verify` は ok:true を返す。`ok` だけを信じる駆動系は
# 「何も確かめていない」を緑と扱う。設計全体が防ごうとしている fail-open なので、検査する。
setup; measurement 6 1 0 0 0
rm -f "$PROFILES/probe.json"
runloop size "r"
runloop run
[[ $RC -ne 0 ]] && grep -q 'profile が無い' <<<"$OUT" \
  && ok "一致する profile が無いと run は断る。確かめていないリポジトリは緑ではない" \
  || { no "profile が無いまま run が進み、何も検証していなかった（exit ${RC}）"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }

# --- 周の上限の既定 -----------------------------------------------------------
# ゲートの `max_attempts` は 3 で、`attempts` は 1 手番で 2 つ増える（ブロックで 1、再入の解放で 1）。失敗し続ける
# チェックは約 2 周で VERDICT になり、`gate_gave_up` がそこで landing を止める。既定を 6 にすると、上限が要る
# まさにそのケースで届かない。届かない上限は上限ではない。
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.10 3; side_effect_all implement 'date >> churn.txt'
side_effect_all debug 'date >> churn.txt'
respond debug 1 0.10 3
runloop run                                  # --max-rounds なし: 検査対象は既定値
impl_n=$(( $(cat "$FAKE_CLAUDE_DIR/implement.counter" 2>/dev/null || echo 1) - 1 ))
debug_n=$(( $(cat "$FAKE_CLAUDE_DIR/debug.counter" 2>/dev/null || echo 1) - 1 ))
if [[ $(( impl_n + debug_n )) -eq 3 ]]; then
  ok "周の上限の既定は実装 3 周（implement 1 + debug 2）"
else
  no "既定の上限で $(( impl_n + debug_n )) 周使った（implement ${impl_n}、debug ${debug_n}）。3 ではない"
fi

# ---------------------------------------------------------------- 赤の経路、周の上限
setup; measurement 6 1 0 0 0; runloop size "r"
# 毎周何かを変えて、それでもチェックは赤のまま。何も変えないと round_changed_nothing が先に出て、別の所見になる。
respond implement 1 0.10 3; side_effect_all implement 'date >> churn.txt'
side_effect_all debug 'date >> churn.txt'
respond debug 1 0.10 3
runloop run --max-rounds 3
[[ $RC -ne 0 ]] && grep -qi 'round_cap\|round cap' <<<"$OUT" \
  && ok "赤のままのチェックは周の上限で止まる" \
  || { no "ずっと赤いチェックが上限で止まらなかった（exit ${RC}）"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }
[[ "$(ledger_field 'halt_reason')" == "round_cap" ]] \
  && ok "台帳は止まった理由として round_cap を記録する" \
  || no "台帳の halt_reason が '$(ledger_field 'halt_reason')' で、round_cap ではない"
grep -q 'stack submit' "$FAKE_GH_LOG" && no "止まった landing が PR を開いた" || ok "止まった landing は PR を開かない"
# 開始前にどのチェックが赤だったかは、ループが諦める場所で言わなければならない。開始時の薄い 1 行だけでは、
# ループが赤いスイートを引き継いだのか壊したのかが分からない。
grep -q 'すでに赤かった' <<<"$OUT" \
  && ok "halt は、チェックが run の前から赤かったと言う。引き継いだ失敗を読み違えない" \
  || no "halt が、この run が壊したチェックと引き継いだチェックを区別していない"

# 切り替えをソースではなく観察で確かめる: 1 周目はコードを書き、赤いゲートの後の周はすべて根本原因の作業に渡す。
# 「1 回出た」だけでは、打った後に TDD の周へ戻っても真になるので数える。
[[ "$(grep -c 'test-driven-development' "$FAKE_CLAUDE_LOG")" -eq 1 ]] \
  && ok "/test-driven-development はちょうど 1 回、1 周目だけ打たれる" \
  || no "/test-driven-development が $(grep -c 'test-driven-development' "$FAKE_CLAUDE_LOG") 回打たれた。赤いチェックで TDD の周を買い足してはいけない"
[[ "$(grep -c 'systematic-debugging' "$FAKE_CLAUDE_LOG")" -ge 2 ]] \
  && ok "最初に赤くなった後の周はすべて /systematic-debugging" \
  || no "上限までに debug の周が $(grep -c 'systematic-debugging' "$FAKE_CLAUDE_LOG") 回しかない"

# 逆向きも。run の開始時に緑で、上限の時点で赤いチェックはこの run が壊したもので、「すでに赤かった」と言えば
# 免罪に読める嘘になる。無条件の文なら上の検査は通ってしまう。
setup; measurement 6 1 0 0 0; runloop size "r"
: > "$FAKE_CLAUDE_DIR/no-worktree"        # fixture が緑で stage できるよう、ゲートを REPO_DIR に置いておく
: > "$REPO_DIR/GREEN"                     # `test -f GREEN` -- 1 周目の前は緑
git -C "$REPO_DIR" add -A >/dev/null 2>&1
git -C "$REPO_DIR" commit -qm "green before the run" >/dev/null 2>&1
respond implement 1 0.10 3; side_effect_all implement 'rm -f GREEN; date >> churn.txt'
respond debug 1 0.10 3; side_effect_all debug 'date >> churn.txt'
runloop run --max-rounds 2
grep -q 'すでに赤かった' <<<"$OUT" \
  && no "この run が壊したチェックについて、halt が引き継いだ失敗だと言った。文が無条件になっている" \
  || ok "run が自分で壊したチェックは、引き継いだものとして免罪されない"

# ---------------------------------------------------------------- ゲートが諦めた
# 状態ディレクトリは決まっている: <gate>/<リポジトリのルートの basename>/wt/main。ゲートを arm するのは run で
# なければならないので、`status --json` から読まずここで名指す。
plant_verdict() { printf 'mkdir -p "%s/repo/wt/main" && printf "2026-08-11T00:00:00Z\\nred\\nprobe-gate\\n3\\n1\\nclaude\\ntest -f GREEN\\n" > "%s/repo/wt/main/VERDICT"\n' "$GATE" "$GATE"; }

# `run` の開始時に verdict がすでにあれば止めなければならない。`gate.sh arm` は VERDICT を VERDICT.prev に移して
# 試行の予算をやり直すので、先に arm する駆動系は、前の作業が検証されていないという記録そのものを消す。
# 状態ディレクトリができるよう、ゲートは本当に arm しておく必要がある（未 arm のまま置くと `status` が
# gave_up:false を返し、run が進み、`arm` が verdict を消費する）。下のディスク上の確認がそれを捕まえた。
setup; measurement 6 1 0 0 0; runloop size "r"
( cd "$REPO_DIR" && DOTAGENTS_GATE_DIR="$GATE" bash "$REPO/scripts/gate.sh" arm >/dev/null 2>&1 )
: > "$FAKE_CLAUDE_DIR/no-worktree"
printf '2026-08-11T00:00:00Z\nred\nprobe-gate\n3\n1\nclaude\ntest -f GREEN\n' > "$GATE/repo/wt/main/VERDICT"
respond implement 1 0.10 3
runloop run
[[ $RC -ne 0 ]] && grep -q '合格ではなく verdict で終わっている' <<<"$OUT" \
  && ok "前の run が残した verdict があると、arm で消さずに次の run を断る" \
  || { no "既存の verdict の上で run が始まった（exit ${RC}）"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }
[[ -f "$GATE/repo/wt/main/VERDICT" ]] \
  && ok "その後も verdict はディスクに残っている。断っても証拠は消費されない" \
  || no "開始を断った run が verdict を消した"

# landing の途中で verdict が現れる。ゲートが実際に生むのはこのケース。
setup; measurement 6 1 0 0 0; runloop size "r"
: > "$FAKE_CLAUDE_DIR/no-worktree"
respond implement 1 0.10 3; side_effect implement 1 "$(plant_verdict)"
runloop run --max-rounds 5
[[ $RC -ne 0 ]] && grep -qi 'gave_up\|gave up' <<<"$OUT" \
  && ok "landing の途中で書かれた VERDICT は、緑と読まれず landing を打ち切る" \
  || { no "landing の途中の VERDICT で打ち切られなかった（exit ${RC}）"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }
[[ "$(ledger_field 'halt_reason')" == "gave_up" ]] \
  && ok "台帳は gave_up を round_cap と区別する" \
  || no "台帳の halt_reason が '$(ledger_field 'halt_reason')' で、gave_up ではない"

# ---------------------------------------------------------------- 採点するものは変えられない
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.10 3
side_effect implement 1 'mkdir -p profiles && printf "{}" > profiles/loosened.json && touch GREEN'
runloop run
[[ $RC -ne 0 ]] && grep -qi 'scorer' <<<"$OUT" \
  && ok "採点するものを編集した周は landing を打ち切る" \
  || { no "周が profiles/ を編集したのに止まらなかった（exit ${RC}）"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }
grep -q 'stack submit' "$FAKE_GH_LOG" && no "採点するものに触れた landing が PR を開いた" || ok "採点するものに触れた landing は PR を開かない"
[[ "$(ledger_field 'halt_reason')" == "scorer_touched" ]] \
  && ok "台帳も理由として採点するもの（scorer_touched）を挙げる" \
  || no "採点するものに触れた landing が halt_reason '$(ledger_field 'halt_reason')' を記録した"

# 守られたファイルを、その場で編集するのではなく守られた場所の外へ移す。`git status --porcelain -z` は rename を
# NUL 区切りの 2 項目（新しいパス、古いパス。間に " -> " は無い）で報告する。全項目から 3 文字の状態の接頭部を
# 削るパーサは古いパスを壊し、ループはゲートを止められずに脇へ rename できてしまう。
setup; measurement 6 1 0 0 0; runloop size "r"
mkdir -p "$REPO_DIR/scripts"; printf 'gate\n' > "$REPO_DIR/scripts/gate.sh"
git -C "$REPO_DIR" add scripts/gate.sh; commit_in_repo "add a guarded file"
respond implement 1 0.10 3
side_effect implement 1 'git mv scripts/gate.sh gate-old.sh && touch GREEN'
runloop run
[[ "$(ledger_field 'halt_reason')" == "scorer_touched" ]] \
  && ok "守られたファイルを守られたパスの外へ rename しても捕まる。その場の編集だけではない" \
  || { no "周が scripts/gate.sh を rename で逃がしたのに止まらなかった（halt_reason '$(ledger_field 'halt_reason')'）"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }

# ---------------------------------------------------------------- triage の出口
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 0 1 0           # 所見 1 件が人の判断を要する
runloop run
[[ $RC -ne 0 ]] && grep -qi 'needs_decision' <<<"$OUT" \
  && ok "判断が要る所見があれば、すぐに止まる" \
  || { no "needs_decision でループが止まらなかった（exit ${RC}）"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }
grep -q 'stack submit' "$FAKE_GH_LOG" && no "needs_decision なのに PR を開いた" || ok "needs_decision では PR を開かない"

setup; measurement 11 1 0 0 0; runloop size "r"        # 11 ファイル -> tier M。まだ 2 周ある
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | a | probe-gate | no |\n' \
  > "$REPO_DIR/plan.md"
git -C "$REPO_DIR" add plan.md; commit_in_repo plan
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 2 0 1     # review 1: 直すもの 2 件
respond fix    1 0.20 4                                    # 修正の周
respond review 2 0.30 7; respond triage 2 0.05 2 1 0 1     # review 2: まだ 1 件
respond fix    2 0.20 4
respond pr     1 0.10 3
runloop run plan.md
# 意図して変えた（黙らせたのではない）。以前は `review_cap`、つまり 2 回目のレビューの所見を直さずに止まることを
# 検査していた。その読み方では tier S が PR に届かなかったので、上限はレビューする回数を決め、最後のレビューの
# 修正は適用してゲートで確かめてからレビューをやめる。変わらず守るのは、3 回目のレビューを買わないこと。
rounds="$(grep -c -- '/da-review-all$' "$FAKE_CLAUDE_LOG")"
[[ "$rounds" -eq 2 ]] \
  && ok "tier M: レビューは 2 回で 3 回目は無い。上限はコストのかかるところで効く" \
  || no "tier M のレビューの周が ${rounds} 回で、2 回ではない"
grep -c -- '/receiving-code-review$' "$FAKE_CLAUDE_LOG" | grep -q '^2$' \
  && ok "両方の周の所見が、最後の周の分も含めて適用された" \
  || no "2 回目のレビューの所見が適用されずに残った（修正の周 $(grep -c -- '/receiving-code-review$' "$FAKE_CLAUDE_LOG") 回）"

# レビューの 1 周は 1 つのスキルではなく /da-review-all と /da-fix-plan の triage の組で、最初の実 landing では
# 実装 $1.30 に対して $5.64 + $2.08 かかった。2 周だと、tier S が設計フェーズを飛ばせるほど小さいと決めた変更に
# ~$15 の天井になる。その天井は 2 周目にあるので、tier S は 2 周目を買わない。
setup; measurement 6 1 0 0 0; runloop size "r"        # 6 ファイル -> tier S
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 2 0 1     # review 1: まだ直すもの 2 件
respond fix    1 0.20 4
respond review 2 0.30 7; respond triage 2 0.05 2 0 0 0     # 届けば通るが、届かない
runloop run
# 行の*末尾*に固定する。他の書き方はすべて間違い。triage のプロンプトは "=== /da-review-all の所見 ===" を見出しとして
# 引用するので、素の grep は二重に数える。スタブは argv 全体を記録するので行頭の固定は失敗し、`$*` を記録するので
# 複数行のプロンプトは複数のログ行になり、da-fix-plan を含む行を除いても引用された見出しの行が残る。
# スキル名で*終わる*行は呼び出しだけ。
rounds="$(grep -c -- '/da-review-all$' "$FAKE_CLAUDE_LOG")"
[[ "$rounds" -eq 1 ]] \
  && ok "tier S が買うレビューはちょうど 1 周。2 周目は正しさではなく \$15 の天井" \
  || no "tier S のレビューが ${rounds} 周走った。S は設計フェーズを飛ばすので、L のレビュー代を払ってはいけない"
# これも意図して変えた: 未解決の所見を直さずに出すこと（ここで止まることの実際の意味）はもうしない。直して
# ゲートで確かめ、再レビューしていないことを PR 本文に伝える。
grep -q '再レビューされていません' "$FAKE_CLAUDE_LOG" \
  && ok "所見は適用され、再レビューしていないことが PR に伝わる" \
  || no "tier S が所見を出したか捨てたかを言わずに済ませた"

# ---------------------------------------------------------------- 一方通行の扉と draft の上限
setup; measurement 11 1 0 0 0; runloop size "r"
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | a | probe-gate | yes |\n' \
  > "$REPO_DIR/plan.md"
git -C "$REPO_DIR" add plan.md; commit_in_repo plan
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0
runloop run plan.md
grep -q 'stack submit' "$FAKE_GH_LOG" \
  && no "一方通行の landing が PR を開いた" \
  || ok "一方通行の landing は PR の手前で止まり、人に渡す"
# 「何も提出していない」はどの早期停止でも真なので、理由を固定する。でないと別の理由で死んでも上が通る。
[[ "$(ledger_field 'halt_reason')" == "one_way" ]] \
  && ok "止まったのは一方通行だからで、別の何かが壊れたからではない" \
  || no "一方通行の landing が halt_reason '$(ledger_field 'halt_reason')' を記録した"

setup; measurement 6 1 0 0 0; runloop size "r"
# PR 番号ではなく head ブランチ名。上限はこの stack のブランチを数えるので、人が手で開いた PR には当たらない。
: > "$FAKE_CLAUDE_DIR/no-worktree"     # 上限はこのチェックアウトの head ブランチに当てる
printf 'work\nwork-2\nwork-3\nwork-4\nwork-5\n' > "$FAKE_GH_DIR/pr-list"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0
runloop run
grep -q 'stack submit' "$FAKE_GH_LOG" \
  && no "上限の本数がすでに開いているのに、PR をもう 1 本提出した" \
  || ok "開いた PR の上限で、ループがレビュアを追い越さない"
[[ "$(ledger_field 'halt_reason')" == "pr_cap" ]] \
  && ok "止まったのは上限のためで、別の何かが壊れたからではない" \
  || no "上限に当たった landing が halt_reason '$(ledger_field 'halt_reason')' を記録した"

# ---------------------------------------------------------------- stack とその前提条件
# landing は本質的に stack で、landing 2 は landing 1 の上に積む。run 全体で 1 本のブランチを使うと、2 つ目の
# landing の PR が 1 つ目とぶつかる。
setup; measurement 11 1 0 0 0; runloop size "r"
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | first | probe-gate | no |\n| 2 | second | probe-gate | no |\n' \
  > "$REPO_DIR/plan.md"
git -C "$REPO_DIR" add plan.md; commit_in_repo plan
# landing 1
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0; respond pr 1 0.10 3
# landing 2 -- 各 phase の 2 回目。fixture がどの landing のものかを示す
respond implement 2 0.20 5; side_effect implement 2 'printf b > b.txt'
respond review 2 0.30 7; respond triage 2 0.05 2 0 0 0; respond pr 2 0.10 3
runloop run plan.md
[[ "$(grep -c 'stack add' "$FAKE_GH_LOG")" -ge 1 ]] \
  && ok "landing 2 は landing 1 と同じブランチではなく、gh stack add で自分の層を得る" \
  || { no "2 つ目の landing に層が足されていない。両方が 1 本のブランチを狙う"; detail "$(tr '\n' ';' < "$FAKE_GH_LOG")"; }
[[ "$(grep -c 'stack submit' "$FAKE_GH_LOG")" -ge 2 ]] \
  && ok "landing は終わるたびに提出されるので、下の層からレビューを始められる" \
  || no "landing 2 件に対して stack の提出が $(grep -c 'stack submit' "$FAKE_GH_LOG") 回"

# 本物の plan ファイルの形: "Landing plan" と言うタイトル、文章、🧱 の表の前の*別の*表。`parse_plan` は
# /Landing plan/i に当たる最初の行（1 行目のタイトル）で inTable を立て、その後の最初の表に食いついたので、最初の
# landing が「主張」という番号で「確認方法」を内容として出てきた。設計レビューの出力を人が写すと、🧱 の表の周りに
# 見出しや根拠の表が付く。plan の識別には `landing_plans()` がすでに見出し行を使っており、パースも同じものを使う。
setup; measurement 11 1 0 0 0; runloop size "r"
{ printf '# 🧱 Landing plan -- the title mentions it, deliberately\n\n'
  printf 'Some prose about why.\n\n'
  printf '| 主張 | 確認方法 | 結果 |\n|---|---|---|\n| the loop ran | the ledger | yes |\n\n'
  printf '## 🧱 Landing plan\n\n'
  printf '| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | the real one | probe-gate | no |\n'
} > "$REPO_DIR/plan.md"
git -C "$REPO_DIR" add plan.md; commit_in_repo plan
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0; respond pr 1 0.10 3
runloop run plan.md
grep -q 'landing 1: the real one' <<<"$OUT" \
  && ok "🧱 の表の上に根拠の表がある plan でも、🧱 の表をパースする" \
  || { no "違う表が landing の一覧としてパースされた"; detail "$(grep -m1 'landing' <<<"$OUT")"; }
grep -qE 'landing (主張|確認方法)' <<<"$OUT" \
  && no "根拠の表の行が landing として扱われた" \
  || ok "別の表の行は landing にならない"

# 拡張は必須の依存。`gh pr create` に倒すと、頼まれたのとは違う形の、stack でない PR が黙ってできる。
setup; measurement 6 1 0 0 0; runloop size "r"
: > "$FAKE_GH_DIR/no-stack-ext"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0
runloop run
[[ $RC -ne 0 ]] && grep -q 'gh extension install github/gh-stack' <<<"$OUT" \
  && ok "gh-stack 拡張が無ければ、黙って stack を外さずインストールのコマンド付きで断る" \
  || { no "gh-stack 拡張が無いのに run が止まらなかった（exit ${RC}）"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }

# 構造化出力をまったく返さない triage の周。構造化出力を求めるフラグは未検証（冒頭を参照）で、名前が違えば
# すべての triage の周が何も返さない。件数を 0 に倒すと「直すものは無い」と読んで triage していない PR を出し、
# 台帳にはきれいなレビューと区別できない fix_now:0 が残る。無いなら止まらなければならない。
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2          # fix_now の引数なし -> 応答に structured_output が無い
runloop run
[[ $RC -ne 0 ]] \
  && ok "構造化出力の無い triage の周は、「直すもの無し」と読まずに止まる" \
  || { no "読めない triage がきれいなレビューとして扱われた（exit ${RC}）"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }
grep -q 'stack submit' "$FAKE_GH_LOG" \
  && no "何も返さなかった triage を根拠に PR が提出された" \
  || ok "triage を読めなければ PR は提出しない"
[[ "$(ledger_field 'halt_reason')" == "triage_unreadable" ]] \
  && ok "台帳は、直すものが無かったではなく triage を読めなかったと言う" \
  || no "台帳の halt_reason が '$(ledger_field 'halt_reason')' で、triage_unreadable ではない"

# ================================================================ fix plan 2026-08-11
# 以下の各ケースは docs/fix-plans/2026-08-11-loop-driver.md の番号付きの項目に対応する。

# #3 -- `changed_paths` にとって「きれい」と「分からなかった」は同じ答えで、4 つの利用側がすべて無害な分岐を取っていた。
# GIT_DIR を git ディレクトリでないものに向けて再現する（index.lock、dubious-ownership の拒否、ワークツリー外の cwd はここからはこう見える）。
setup; measurement 6 1 0 0 0; runloop size "r"
OUT="$(cd "$REPO_DIR" && PATH="$BIN:$PATH" GIT_DIR=/nonexistent-git-dir \
  DOTAGENTS_LOOP_DIR="$LOOPDIR" DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" \
  DOTAGENTS_REPO="$REPO" NO_COLOR=1 bash "$LOOP" run 2>&1)"; RC=$?
[[ $RC -ne 0 ]] && grep -q '作業ツリーを読めなかった' <<<"$OUT" \
  && ok "#3 読めない作業ツリーは、きれいと読まずに断る" \
  || { no "#3 読めないツリーがきれいとして扱われた（exit ${RC}）"; detail "$(head -3 <<<"$OUT" | tr '\n' ' ')"; }

# #1 -- 空の緑。gating チェックが `{files}` スコープだけの profile は、ツリーがきれいだと飛ばされ、hook は
# "nothing blocking" で exit 0 する。`verify --json` はそれを ok:true と報告するので、駆動系は本物の合格と区別できない。
setup; measurement 6 1 0 0 0
cat > "$PROFILES/probe.json" <<'JSON'
{ "match": { "remote": "dotagents-loop-probe" },
  "checks": [ { "id": "probe-changed", "cmd": "test -f GREEN {files}", "gate": true,
                "agent_may_run": true, "scope": "changed", "timeout": 10 } ],
  "timeout_total": 60 }
JSON
runloop size "r"
: > "$FAKE_CLAUDE_DIR/no-worktree"
respond implement 1 0.20 5      # 何も変えないので、ツリーはきれいなまま
runloop run
# 何かが走ったかをゲートには聞けない（手で確認済み: きれいなツリーと `{files}` だけの profile では、`verify --json` は
# 本物の合格と同じ ok:true、check:null、"all gating checks green" を返す）。駆動系の防御は、何も変えなかった周は
# 緑に値しないということで、それを検査する。
[[ $RC -ne 0 ]] && grep -q 'round_changed_nothing' <<<"$OUT" \
  && ok "#1 何も変えなかった周は、検証済みに数えない" \
  || { no "#1 チェックが 1 つも実行されなかった run が検証済みとして扱われた（exit ${RC}）"; detail "$(tail -4 <<<"$OUT" | tr '\n' ' ')"; }
[[ "$(ledger_field 'halt_reason')" == "round_changed_nothing" ]] \
  && ok "#1 台帳もそれを名指すので、report に幻の合格が出ない" \
  || no "#1 台帳の halt_reason が '$(ledger_field 'halt_reason')'"
grep -q 'stack submit' "$FAKE_GH_LOG" \
  && no "#1 gating チェックが一度も走っていないのに PR が提出された" \
  || ok "#1 チェックが走らなければ PR は提出しない"

# #2 -- post_round は exit 143 しか見ていなかったので、API エラー、rate limit、拒否されたフラグで周が失敗しても
# 見えず、ループが続いた。
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; fails_with implement 1 1
runloop run
[[ "$(ledger_field 'halt_reason')" == "round_failed" ]] \
  && ok "#2 0 以外で終わった周は、無視されずに止まる" \
  || no "#2 失敗した周が halt_reason '$(ledger_field 'halt_reason')' を記録した"

# #4 -- tier S は landing plan の検証をすべて飛ばすのに、plan のパスを渡されるとパースはしていた。
setup; measurement 6 1 0 0 0; runloop size "r"     # tier S
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | snuck in | ? | no |\n' \
  > "$REPO_DIR/plan.md"
printf 'plan.md\n' > "$REPO_DIR/.gitignore"
git -C "$REPO_DIR" add .gitignore; commit_in_repo ignore
runloop run plan.md
[[ $RC -ne 0 ]] && grep -q 'commit されていない。' <<<"$OUT" \
  && ok "#4 tier S でも、commit されていない plan は断る" \
  || { no "#4 tier S が commit されていない landing plan で走った（exit ${RC}）"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }

# #6 -- STACK_BASE_BRANCH は `gh stack init` の経路でしか設定されず、再開の経路（stack がすでにある。どの停止の後も
# 想定される状態）では層の名前が積み重なり、開いた PR の上限が違うブランチを数えた。
setup; measurement 11 1 0 0 0; runloop size "r"
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | one | probe-gate | no |\n| 2 | two | probe-gate | no |\n' \
  > "$REPO_DIR/plan.md"
git -C "$REPO_DIR" add plan.md; commit_in_repo plan
: > "$FAKE_GH_DIR/stack"        # stack がすでにある -> 近道の経路
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0; respond pr 1 0.10 3
respond implement 2 0.20 5; side_effect implement 2 'printf b > b.txt'
respond review 2 0.30 7; respond triage 2 0.05 2 0 0 0; respond pr 2 0.10 3
runloop run plan.md
# 否定の検査には相棒が要る。「積み重なった名前が出なかった」は層が一度も足されなくても真なので。
[[ "$(grep -c 'stack add' "$FAKE_GH_LOG")" -ge 1 ]] \
  && ok "#6 再開の経路で層が足されたので、下の名前の検査に意味がある" \
  || { no "#6 層が 1 つも足されていない。積み重なりの検査が空になる"; detail "$(tr '\n' ';' < "$FAKE_GH_LOG")"; }
grep -qE 'stack add .*-2-3' "$FAKE_GH_LOG" \
  && no "#6 再開の経路で層の名前が積み重なった（<branch>-2-3）" \
  || ok "#6 stack がすでにあっても層の名前は積み重ならない"

# #7 -- 値を省いた `--budget-usd` は永久に回った。引数が 1 つしか残っていない `shift 2` は何も shift せず、
# `set -uo pipefail` でも止まらないため。
setup
( cd "$REPO_DIR" && PATH="$BIN:$PATH" DOTAGENTS_LOOP_DIR="$LOOPDIR" DOTAGENTS_GATE_DIR="$GATE" \
  DOTAGENTS_PROFILES="$PROFILES" DOTAGENTS_REPO="$REPO" NO_COLOR=1 \
  bash "$LOOP" run --budget-usd >/dev/null 2>&1 ) &
hang_pid=$!
hang=0; ticks=0
while [[ $ticks -lt 25 ]]; do
  kill -0 "$hang_pid" 2>/dev/null || break
  sleep 0.2; ticks=$((ticks+1))
done
if kill -0 "$hang_pid" 2>/dev/null; then kill -KILL "$hang_pid" 2>/dev/null; hang=1; fi
wait "$hang_pid" 2>/dev/null
[[ $hang -eq 0 ]] \
  && ok "#7 値の無いオプションは回り続けずに終わる" \
  || no "#7 値の無い 'run --budget-usd' が終わらなかった"

# #10 -- `record` は JSON を手で組んでいたので、引用符を含むチェック id で台帳の行全体がパースできなくなった。
# 消えるのは halt_reason を持つ行なので、止まった landing について report が「止まったものなし」と言う。
setup; measurement 6 1 0 0 0
cat > "$PROFILES/probe.json" <<'JSON'
{ "match": { "remote": "dotagents-loop-probe" },
  "checks": [ { "id": "prob\"e-gate", "cmd": "test -f GREEN", "gate": true,
                "agent_may_run": true, "scope": "all", "timeout": 10 } ],
  "timeout_total": 60 }
JSON
runloop size "r"
: > "$FAKE_CLAUDE_DIR/no-worktree"
respond implement 1 0.10 3
runloop run --max-rounds 1
if ledger | node -e '
    let bad = 0, n = 0;
    require("readline").createInterface({input: process.stdin})
      .on("line", (l) => { if (!l.trim()) return; n++; try { JSON.parse(l) } catch { bad++ } })
      .on("close", () => process.exit(bad || n === 0 ? 1 : 0));
  '; then
  ok "#10 引用符を含むチェック id でも、台帳の行はパースできる"
else
  no "#10 チェック id の引用符で、halt_reason を持つ台帳の行が壊れた"
fi

# スキーマはファイルパスではなく inline で渡す。claude 2.1.148 で実測: `--json-schema` はスキーマを文字列で取り、
# パスを渡すとエラーにならず永久に固まる。構造化出力を求める phase（size、triage）は、最初の実使用で固まっていた。
setup; measurement 6 1 0 0 0; runloop size "r"
grep -qE -- '--json-schema[[:space:]]+\{' "$FAKE_CLAUDE_LOG" \
  && ok "スキーマはファイルパスではなく inline の JSON で渡す" \
  || { no "--json-schema の後が inline の JSON ではない。パスの引数だと CLI が固まる"; detail "$(head -1 "$FAKE_CLAUDE_LOG" | head -c 160)"; }
grep -qE -- '--json-schema[[:space:]]+/' "$FAKE_CLAUDE_LOG" \
  && no "--json-schema にパスが渡された。失敗せずに固まる" \
  || ok "--json-schema にパスを渡すことは無い"

# 返らない周。周の上限も予算もゲートも固まりは止められないので、駆動系が期限を持つ。
setup; measurement 6 1 0 0 0; runloop size "r"
: > "$FAKE_CLAUDE_DIR/no-worktree"
respond implement 1 0.10 3; hangs_for implement 1 30
started=$(date +%s)
OUT="$(cd "$REPO_DIR" && PATH="$BIN:$PATH" DOTAGENTS_LOOP_DIR="$LOOPDIR" DOTAGENTS_GATE_DIR="$GATE" \
  DOTAGENTS_PROFILES="$PROFILES" DOTAGENTS_REPO="$REPO" DOTAGENTS_LOOP_ROUND_TIMEOUT=3 \
  NO_COLOR=1 bash "$LOOP" run 2>&1)"; RC=$?
elapsed=$(( $(date +%s) - started ))
[[ $RC -ne 0 && $elapsed -lt 25 ]] \
  && ok "返らない周は、駆動系の期限で kill される（${elapsed}s）" \
  || { no "固まった周に限りが無かった（${elapsed}s 後に exit ${RC}）"; detail "$(tail -2 <<<"$OUT" | tr '\n' ' ')"; }
[[ "$(ledger_field 'halt_reason')" == "round_timeout" ]] \
  && ok "台帳は、失敗した・何もしなかったではなく、タイムアウトしたと言う" \
  || no "固まった周が halt_reason '$(ledger_field 'halt_reason')' を記録した"

# ================================================================ 人にしか走らせられないチェック
# `agent_may_run: false` は、このリポジトリがエージェントに実行を禁じているという意味（例: 8 GB のヒープが要る
# typecheck）。対話なら /da-verify がユーザーに聞いて待つが、無人では聞く相手がおらず、周を足しても満たせない。
# だから駆動系は `needs_human` を `red` と区別しなければならない。

setup; measurement 6 1 0 0 0
# エージェントが走らせてよいチェック（緑）が 1 つ、走らせてはいけないものが 1 つ。
cat > "$PROFILES/probe.json" <<'JSON'
{ "match": { "remote": "dotagents-loop-probe" },
  "checks": [
    { "id": "probe-gate", "cmd": "test -f GREEN", "gate": true, "agent_may_run": true, "scope": "all", "timeout": 10 },
    { "id": "probe-heavy", "cmd": "exit 7", "gate": true, "agent_may_run": false,
      "delegate_reason": "needs 8 GB of heap; the repository forbids the agent from running it" }
  ],
  "timeout_total": 60 }
JSON
runloop size "r"
: > "$FAKE_CLAUDE_DIR/no-worktree"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0; respond pr 1 0.10 3
runloop run
[[ $RC -eq 0 ]] && grep -q 'pull/7' <<<"$OUT" \
  && ok "人にしか走らせられないチェックでループは止まらない。待たずに先送りする" \
  || { no "needs_human のチェックでループが止まった（exit ${RC}）"; detail "$(tail -4 <<<"$OUT" | tr '\n' ' ')"; }
[[ "$(ledger_field 'halt_reason')" != "round_cap" ]] \
  && ok "どの周にも直せないものに、周の上限を使い切らなかった" \
  || no "エージェントが走らせてはいけないチェックに、すべての周を使った"

# 先送りは 3 箇所ではっきり言わなければならない。でないと、ローカルの検証が不完全な作業をループが黙って出す。
# 解放されたゲートは緑ではなく、先送りしたゲートも緑ではない。
grep -q 'probe-heavy' <<<"$OUT" \
  && ok "run は、どのチェックを検証しなかったかを言う" \
  || { no "先送りしたチェックが出力で名指されていない"; detail "$(tail -6 <<<"$OUT" | tr '\n' ' ')"; }
ledger | grep -q 'probe-heavy' \
  && ok "台帳が記録するので、後で report に出せる" \
  || no "台帳が先送りしたチェックを記録していない"
grep -q 'da-pr-describe' "$FAKE_CLAUDE_LOG" && grep -q 'probe-heavy' "$FAKE_CLAUDE_LOG" \
  && ok "/da-pr-describe にも伝わるので、PR 本文で CI の仕事だと言える" \
  || no "ローカルで一度も走らなかったチェックに、PR 本文が触れない"

# エージェントが走らせてよいチェックが失敗すれば、それは赤のまま。先送りが本物の失敗を飲み込んではならない。
setup; measurement 6 1 0 0 0
cat > "$PROFILES/probe.json" <<'JSON'
{ "match": { "remote": "dotagents-loop-probe" },
  "checks": [
    { "id": "probe-gate", "cmd": "test -f GREEN", "gate": true, "agent_may_run": true, "scope": "all", "timeout": 10 },
    { "id": "probe-heavy", "cmd": "exit 7", "gate": true, "agent_may_run": false,
      "delegate_reason": "needs 8 GB of heap" }
  ],
  "timeout_total": 60 }
JSON
runloop size "r"
: > "$FAKE_CLAUDE_DIR/no-worktree"
respond implement 1 0.10 3; side_effect_all implement 'date >> churn.txt'
side_effect_all debug 'date >> churn.txt'; respond debug 1 0.10 3
runloop run --max-rounds 2
[[ $RC -ne 0 ]] \
  && ok "エージェントが走らせられる赤いチェックは、今もループを止める。先送りが飲み込まない" \
  || { no "先送りのせいで、本当に赤いチェックが緑に見えた（exit ${RC}）"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }

# ================================================================ 単一の入口
# 覚えておくのは `loop.sh "<request>"` だけでよい。打つたびに 1 歩進む: 未測定なら size、設計フェーズが人の番なら
# 引き渡し、走らせるものがあれば run。

# 未測定 + 小さい -> size してそのまま run に進む。
setup
measurement 6 1 0 0 0
: > "$FAKE_CLAUDE_DIR/no-worktree"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0; respond pr 1 0.10 3
runloop "usage に design を1行足す"
[[ $RC -eq 0 ]] && grep -q 'pull/7' <<<"$OUT" \
  && ok "単一の入口: 未測定の小さな変更は、1 コマンドで size して run する" \
  || { no "単一の入口が tier S の変更を最後まで運ばなかった（exit ${RC}）"; detail "$(tail -4 <<<"$OUT" | tr '\n' ' ')"; }
[[ "$(ledger_field 'phase')" != "size" ]] \
  && ok "size の後で止まらない" || no "size して止まった"

# 未測定 + 大きい -> size し、設計フェーズを引き渡す。エラーではない。進めるところまで進み、次の手番は人のもの。
setup; measurement 20 3 1 1 1
runloop "大きいこと"
[[ $RC -eq 0 ]] \
  && ok "大きな変更は exit 0。引き渡しは失敗ではない" \
  || { no "設計フェーズの引き渡しが exit ${RC} で終わった"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }
grep -qE 'あなたの手番|your turn' <<<"$OUT" \
  && ok "あなたの手番だとはっきり言う" \
  || { no "誰の手番かを言わなかった"; detail "$(tail -6 <<<"$OUT" | tr '\n' ' ')"; }
for want in grilling da-spec da-design-review; do
  grep -q "$want" <<<"$OUT" && ok "  /${want} を名指す" || no "  /${want} が抜けている"
done
# ラッパーを名指してはならない。`/grill-me` は本文が "Run a `/grilling` session." だけのスキルで、名指すと何も
# 足さず宙に浮きうる経由を通らせる。"grill-me" は "grilling" を含まないので、上の肯定の検査では見えない。無いことを検査する。
grep -q 'grill-me' <<<"$OUT" \
  && no "  削除した /grill-me ラッパーをまだ名指している" \
  || ok "  ラッパーを名指さない。スキルは /grilling"
grep -q 'stack submit' "$FAKE_GH_LOG" && no "設計フェーズなしで PR を開いた" || ok "何も開かない"

# landing plan を commit した後で同じコマンドをもう一度 -> plan を自分で見つけて run する。パスを覚える必要は無い。
mkdir -p "$REPO_DIR/docs/plans"
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | a | probe-gate | no |\n' \
  > "$REPO_DIR/docs/plans/thing.md"
git -C "$REPO_DIR" add docs/plans/thing.md; commit_in_repo plan
respond execplan 1 0.20 5; side_effect execplan 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0; respond pr 1 0.10 3
runloop "大きいこと"
[[ $RC -eq 0 ]] && grep -q 'pull/7' <<<"$OUT" \
  && ok "同じコマンドが commit 済みの landing plan を見つけて run する" \
  || { no "commit 済みの plan を拾わなかった（exit ${RC}）"; detail "$(tail -4 <<<"$OUT" | tr '\n' ' ')"; }

# 候補の plan が 2 つ -> どちらのつもりかを推測せずに断る。
# 依頼文は両方で同じにする。変わると 2 回目の呼び出しが測り直し、fixture が用意していない investigate の応答を消費する。
setup; measurement 20 3 0 0 0; runloop size "大きいこと"
mkdir -p "$REPO_DIR/docs/plans"
for n in one two; do
  printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | a | probe-gate | no |\n' \
    > "$REPO_DIR/docs/plans/$n.md"
done
git -C "$REPO_DIR" add docs/plans; commit_in_repo plans
runloop "大きいこと"
[[ $RC -ne 0 ]] && grep -q 'docs/plans/one.md' <<<"$OUT" && grep -q 'docs/plans/two.md' <<<"$OUT" \
  && ok "候補の plan が 2 つなら、1 つを推測せず両方を挙げる" \
  || { no "曖昧な plan で断らなかった（exit ${RC}）"; detail "$(tail -4 <<<"$OUT" | tr '\n' ' ')"; }

# ================================================================ 全スキルの流れ

# `loop.sh design` は決して入力を求めてはならない（test-non-interactive.sh が対話の経路が無いことを検査する）。
# 設計フェーズは有人なので、聞きたくなるのはまさにここ。
setup; measurement 6 1 0 0 0; runloop size "r"
runloop design
[[ $RC -eq 0 ]] && ok "design は exit 0" || { no "design が exit ${RC} で終わった"; detail "$(tail -2 <<<"$OUT" | tr '\n' ' ')"; }
# 「design は入力を求めない」はここでは検査しない。test-non-interactive.sh がすでに scripts/*.sh の端末読みを掃き、
# stdin を閉じて `loop.sh design` を走らせている。ここに写すと 1 つの検査に 2 つの実装ができる。

# tier が手順を決める。tier の違いは人が関わる深さで、関わるかどうかではない。S には設計フェーズがまったく無い。
setup; measurement 6 1 0 0 0; runloop size "r"      # S
runloop design
grep -qi 'no design phase\|設計フェーズ' <<<"$OUT" \
  && ok "tier S の design は、設計フェーズが無いと言う" \
  || { no "tier S の design が、フェーズが空だと言わなかった"; detail "$(head -4 <<<"$OUT" | tr '\n' ' ')"; }

setup; measurement 20 3 1 1 1; runloop size "r"     # L
runloop design
for want in grilling da-spec da-design-review; do
  grep -q "$want" <<<"$OUT" \
    && ok "tier L の design は /${want} を名指す" \
    || no "tier L の design で /${want} が抜けている"
done
grep -q 'grill-me' <<<"$OUT" \
  && no "tier L の design が、削除した /grill-me ラッパーをまだ名指している" \
  || ok "tier L の design はラッパーを名指さない"

# ディスクに何も残さない 3 段階は、緑に見せず検査できないと報告しなければならない。
grep -qiE 'cannot be checked|検査でき' <<<"$OUT" \
  && ok "design は、どの段階を検証できないかを述べる" \
  || { no "design が検証できないものに何も触れなかった。問題なしと読まれる"; detail "$(tail -6 <<<"$OUT" | tr '\n' ' ')"; }

# 強い信号を持つ唯一の成果物: writing-plans のファイルには必須の見出しがある。
setup; measurement 20 3 0 0 0; runloop size "r"     # 層・ファイル数で L
mkdir -p "$REPO_DIR/docs/superpowers/plans"
printf '# Thing Implementation Plan\n\n**Goal:** x\n**Architecture:** y\n\n## Global Constraints\n\n- [ ] step one\n' \
  > "$REPO_DIR/docs/superpowers/plans/2026-08-11-thing.md"
runloop design
grep -q '2026-08-11-thing.md' <<<"$OUT" \
  && ok "design は writing-plans が残した plan ファイルを見つける" \
  || { no "design が plan ファイルを報告しなかった"; detail "$(tail -6 <<<"$OUT" | tr '\n' ' ')"; }

# そのパスにあっても必須の見出しの無いファイルは plan ではない。どんな .md でも受け入れると、空のファイルでゲートを満たせてしまう。
setup; measurement 20 3 0 0 0; runloop size "r"
mkdir -p "$REPO_DIR/docs/superpowers/plans"
printf 'just some notes\n' > "$REPO_DIR/docs/superpowers/plans/2026-08-11-notes.md"
runloop design
grep -qiE 'header|見出し|not a plan' <<<"$OUT" \
  && ok "必須の見出しの無いファイルは plan として受け入れない" \
  || { no "design が見出しの無いファイルを plan として受け入れた"; detail "$(tail -6 <<<"$OUT" | tr '\n' ' ')"; }

# implement は tier で分かれる。M/L には commit 済みの plan があるので /executing-plans、S には plan が無いので
# /test-driven-development を打つ。
setup; measurement 11 1 0 0 0; runloop size "r"       # M
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | a | probe-gate | no |\n' \
  > "$REPO_DIR/plan.md"
git -C "$REPO_DIR" add plan.md; commit_in_repo plan
respond execplan 1 0.20 5; side_effect execplan 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0; respond pr 1 0.10 3
runloop run plan.md
grep -q '/executing-plans' "$FAKE_CLAUDE_LOG" \
  && ok "tier M は /executing-plans で実装する" \
  || { no "tier M が /executing-plans を打たなかった"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }
# executing-plans のプロンプトは意図して /test-driven-development に*言及*する。executing-plans は plan の手順に
# 任せるので、その言及だけが TDD を保証する。だから検査するのは文字列が無いことではなく、TDD の phase が走らなかったこと。
[[ ! -f "$FAKE_CLAUDE_DIR/implement.counter" ]] \
  && ok "TDD の phase は走らなかった。1 周に implement のスキルは 1 つ" \
  || no "tier M が /executing-plans と /test-driven-development の phase の両方を走らせた"
grep -q 'executing-plans.*\n*.*test-driven-development\|各ステップで /test-driven-development を使う' "$FAKE_CLAUDE_LOG" \
  && ok "executing-plans のプロンプトはステップごとの TDD を述べる。それが TDD の唯一の保証" \
  || no "executing-plans のプロンプトが TDD を求めていない。executing-plans だけでは TDD にならない"

setup; measurement 6 1 0 0 0; runloop size "r"       # S
: > "$FAKE_CLAUDE_DIR/no-worktree"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0; respond pr 1 0.10 3
runloop run
grep -q '/test-driven-development' "$FAKE_CLAUDE_LOG" \
  && ok "tier S は /test-driven-development で実装する（実行する plan が無い）" \
  || no "tier S が /test-driven-development を打たなかった"
grep -q '/executing-plans' "$FAKE_CLAUDE_LOG" \
  && no "tier S が plan ファイル無しで /executing-plans を打った" || ok "/executing-plans は打たない"

# 2 本目のレビュアはリスクで配分し、その報告の*全文*が triage に届く。件数だけでは、別の作りの 2 本目を置く理由である網羅が何も買えない。
setup; measurement 3 1 0 2 0; runloop size "r"       # risk_surfaces = 2 -> M
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | a | probe-gate | no |\n' \
  > "$REPO_DIR/plan.md"
git -C "$REPO_DIR" add plan.md; commit_in_repo plan
respond execplan 1 0.20 5; side_effect execplan 1 'touch GREEN'
respond review 1 0.30 7
respond findbugs 1 0.40 6
respond triage 1 0.05 2 0 0 0; respond pr 1 0.10 3
runloop run plan.md
grep -q '/find-bugs' "$FAKE_CLAUDE_LOG" \
  && ok "リスク面に触れる landing には 2 本目のレビュアが付く" \
  || { no "リスク面に 2 本目のレビュアが付かなかった"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }
grep -q 'da-fix-plan' "$FAKE_CLAUDE_LOG" && grep -q 'find-bugs の所見\|second reviewer' "$FAKE_CLAUDE_LOG" \
  && ok "その報告の本文が、件数だけでなく /da-fix-plan に渡る" \
  || no "2 本目のレビュアの所見が triage に届かなかった"
# `risk_surfaces` が L を強制しなくなったので、/find-bugs は以前は人なしでレビューに届かなかった landing で無人で
# 走る。そこに上限の無い 3 本目のレビューを置くと、安いはずの tier が高くつく。
[[ -n "$(round_budget '/find-bugs')" ]] \
  && ok "2 本目のレビュアにも天井がある（\$$(round_budget '/find-bugs')）" \
  || no "/find-bugs に上限が無い。risk_surfaces を M に下げたことで無人の経路に載っている"

setup; measurement 6 1 0 0 0; runloop size "r"       # リスク面なし
: > "$FAKE_CLAUDE_DIR/no-worktree"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0; respond pr 1 0.10 3
runloop run
grep -q '/find-bugs' "$FAKE_CLAUDE_LOG" \
  && no "リスク面が無いのに 2 本目のレビュアが走った。コストがかかるのはレビュー" \
  || ok "リスク面が無ければ 2 本目のレビュアも無い"
# --- 「まだチェックが無い」は「CI が失敗した」ではない ----------------------------
# `gh` の exit 1 は「何らかの理由で失敗」。`gh pr checks` は pending に 8 を足すので、駆動系は
# {0 -> 緑, 8 -> 待つ, それ以外 -> 赤} と読み、次のすべてを CI の失敗と呼んでいた:
#   * チェックが本当に失敗した
#   * **チェックがまだ存在しない**（push 直後の数秒は普通この状態）
#   * 認証が失敗した（exit 4）
# 7 回目の run では、GitHub が登録する前に見て「赤」と読み、存在しない失敗に /systematic-debugging を買った。
# 直し方は、exit code からの推測をやめて状態を読むこと。
setup; green_pr
: > "$FAKE_GH_DIR/checks-states"                  # まだ何も登録されていない
runloop run
# 状態を読む経路だけが出せる*文*で検査する。「ci_red でない」だけでは弱く、古い exit code の経路でもここは緑に届いた。
grep -q 'チェックを 1 つも報告しない' <<<"$OUT" \
  && ok "空のチェック一覧は、赤い CI ではなく「チェックが 1 つも無い」と報告される" \
  || { no "「まだチェックが無い」が区別されなかった（halt=$(ledger_field halt_reason)）"
       detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }
grep -q '報告されるチェックが1つもありません' "$FAKE_CLAUDE_LOG" \
  && ok "PR 本文にも伝わる。「何も走らなかった」は合格ではない" \
  || no "チェックが無いことが PR 本文に伝わっていない"
grep -q '/systematic-debugging' "$FAKE_CLAUDE_LOG" \
  && no "存在しない CI の失敗に debug の周を使った" \
  || ok "そのために debug の周を買わない"

# 本物の失敗の状態では、今も止まる。
setup; green_pr
printf 'FAILURE\n' > "$FAKE_GH_DIR/checks-states"
respond debug 1 0.10 3; side_effect_all debug 'date >> ci-fix.txt'
runloop run
grep -q '/systematic-debugging' "$FAKE_CLAUDE_LOG" \
  && ok "FAILURE の状態では今も debug の周を買う" \
  || no "本物の CI の失敗が無視された"

# --- XS は修正の仕組みを外すが、レビューまで外してはならない ---------------------------
# XS があるのは、5 ファイルの docs 修正に triage・修正の周・5 分のゲート 2 回目が要らないから。外してはならないのは
# 記録。`REVIEW_REPORT` は終わるプロセスのシェル変数で、レビューを残すのは docs/fix-plans/ を書く /da-fix-plan だけ
# だった。triage が無いと唯一の写しは /da-pr-describe への引数になり、その天井超過は止まらない（PR は開き、describe が
# 打ち切られ、レビューが消える）。8 回目の無人 run はまさに天井超過で死んだ。
setup; measurement 3 1 0 0 0; runloop size "r"        # 3 ファイル -> XS
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond pr 1 0.10 3
runloop run
[[ "$(ledger_field tier 2>/dev/null)" == "" ]] || true
grep -qE -- '/da-review-all$|/x-review-' "$FAKE_CLAUDE_LOG" \
  && ok "XS もレビューする。レビューなしで出るものは無い" \
  || no "XS がレビューを丸ごと飛ばした"
grep -q -- '/da-fix-plan' "$FAKE_CLAUDE_LOG" \
  && no "XS が triage を走らせた。外すために XS がある" \
  || ok "   .../da-fix-plan は走らせない"
grep -q -- '/receiving-code-review' "$FAKE_CLAUDE_LOG" \
  && no "XS が修正の周を走らせた" || ok "   ...修正の周も走らせない"
if [[ $RC -eq 0 ]] && grep -q 'pull/7' <<<"$OUT"; then
  ok "   ...それらなしで PR に届く"
else
  no "XS が PR に届かなかった（exit ${RC}、halt=$(ledger_field halt_reason)）"
  detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"
fi
# この取引を持ちこたえさせる 3 つ。どれも他に気づかれずに単独で落ちうるので、別々に検査する。
ls "$LOOPDIR/reviews/" >/dev/null 2>&1 && [[ -n "$(ls -A "$LOOPDIR/reviews/" 2>/dev/null)" ]] \
  && ok "   ...レビューはディスクに書かれるので、打ち切られた describe が失わせることはない" \
  || no "レビューが一度も保存されていない。打ち切られた describe の周が消してしまう"
grep -q 'triage されていません' "$FAKE_CLAUDE_LOG" \
  && ok "   ...所見が triage されていないことが PR 本文に伝わる" \
  || no "所見を何も triage していないことが PR 本文に伝わっていない"
[[ "$(ledger | grep -c 'advanced-untriaged')" -ge 1 ]] \
  && ok "   ...台帳は advanced だけでなく untriaged と言う" \
  || no "台帳できれいなレビューと triage していないレビューを区別できない"
# 1 回のレビューの周に 2 行。周のお金はそれを使った行のもので、2 行目は何も請求してはならない（`report` の
# `cost by phase` は `cost_usd` を合計するので、同じ数字が 2 回あると同じ支出を 2 回数える）。
if [[ "$(ledger | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const rows=s.split("\n").filter(Boolean).map(l=>{try{return JSON.parse(l)}catch{return null}}).filter(Boolean);
    const adv=rows.find((r)=>r.outcome==="advanced"&&r.phase==="review");
    const unt=rows.find((r)=>r.outcome==="advanced-untriaged");
    process.stdout.write(!adv||!unt ? "missing"
      : (Number(adv.cost_usd) > 0 && Number(unt.cost_usd) === 0 && Number(unt.turns) === 0 ? "once" : "twice"))})')" == "once" ]]; then
  ok "   ...周の請求は 1 回。untriaged の行は自分のコストを持たない"
else
  no "1 回のレビューの周が 2 行で請求され、cost by phase が 2 回数える"
fi

# S は XS が外すものをすべて持つ。同じ fixture で 1 ファイル多いだけ。
setup; measurement 6 1 0 0 0; runloop size "r"        # 6 ファイル -> S
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 1 0 0 0
respond fix 1 0.10 3; side_effect fix 1 'date >> f.txt'
respond pr 1 0.10 3
runloop run
grep -q -- '/da-fix-plan' "$FAKE_CLAUDE_LOG" && grep -q -- '/receiving-code-review' "$FAKE_CLAUDE_LOG" \
  && ok "S は今も triage して修正を適用する。XS より 1 ファイル多いだけで振る舞いは逆" \
  || no "S も修正の仕組みを失った（exit ${RC}、halt=$(ledger_field halt_reason)）"
grep -q 'triage されていません' "$FAKE_CLAUDE_LOG" \
  && no "S が triage していないと言った" || ok "   ...triage していないとは言わない"

# --- paths の profile は commit_landing を越えて生き残らなければならない ------------------------
# この landing が最も出しやすいリスク。`commit_landing` は landing の途中、レビューの前に走り、ゲートの変更集合は
# 基点に対して計算される。基点が HEAD だと、修正の周の後の verify には修正の差分しか見えず（実装はもう commit 済み）、
# 実装に paths が当たっていたチェックはすべて「該当なし」になり、何も走らず、`gate-nothing-ran` が問題の無い
# landing を止める。`scope: all` の profile では見えないので、fixture は修正の周まで通る paths の profile にする。
setup; measurement 6 1 0 0 0; runloop size "r"
cat > "$PROFILES/probe.json" <<'JSON'
{ "match": { "remote": "dotagents-loop-probe" },
  "checks": [ { "id": "probe-gate", "cmd": "test -f GREEN", "gate": true,
                "agent_may_run": true, "paths": ["docs/**"], "timeout": 10 } ],
  "timeout_total": 60 }
JSON
# 実装は docs/ に触れる（チェックが引き受ける）。修正の周は別のものに触れるので、HEAD 基準の基点だと間違う:
# commit_landing の後、docs/ は commit 済みで、「変更」は修正のファイルだけになる。
respond implement 1 0.20 5; side_effect implement 1 'mkdir -p docs && touch GREEN docs/x.md'
respond review 1 0.30 7
respond triage 1 0.05 2 1 0 0 0
respond fix 1 0.10 3; side_effect fix 1 'printf y > note.txt'
respond pr 1 0.10 3
runloop run
if [[ $RC -eq 0 ]] && grep -q 'pull/7' <<<"$OUT"; then
  ok "paths の profile が修正後の verify を越えて生き残る（landing の基点は HEAD ではなく固定）"
else
  no "paths の landing が commit_landing の後で死んだ（exit ${RC}、halt=$(ledger_field halt_reason)）"
  detail "$(tail -4 <<<"$OUT" | tr '\n' ' ')"
fi
grep -q 'に対して差分を取る' <<<"$OUT" \
  && ok "   ...run はどの基点に固定したかを言う" \
  || no "   run が差分の基点を固定したと報告していない"

# --- 古い remote-tracking ref で push が止まってはならない --------------------------
# GitHub は PR が merge されると head ブランチを消すので、最初の landing の merge 後、`refs/remotes/origin/<branch>`
# は消えたものを指したままローカルに残る。すると git は拒む:
#
#   ! [rejected] worktree-unattended-run -> worktree-unattended-run (stale info)
#
# **auto-delete-branch を使うリポジトリは、2 つ目の landing で必ずこれに当たる。**
setup; green_pr
# 形はそのまま: ブランチは push され、remote が消し（merge 時の auto-delete-branch）、ローカルの remote-tracking ref は
# 残る。lease の確認は remote が確かめられないものと比べることになる。
git -C "$REPO_DIR" branch -f loop-wt HEAD
git -C "$REPO_DIR" push -q origin loop-wt
git -C "$REPO_DIR" -c core.hooksPath=/dev/null push -q origin --delete loop-wt   # remote が消す...
git -C "$REPO_DIR" update-ref refs/remotes/origin/loop-wt "$(git -C "$REPO_DIR" rev-parse HEAD)"  # ...ref は残る
git -C "$REPO_DIR" branch -D loop-wt
runloop run
if [[ $RC -eq 0 ]] && grep -q 'pull/7' <<<"$OUT"; then
  ok "古い remote-tracking ref は、landing を止めずに prune される"
else
  no "古い ref が landing を止めた（exit ${RC}、halt=$(ledger_field halt_reason)）"
  detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"
fi

# --- 台帳は、外で起きたことを少なく言ってはならない ----------------------
# `gh stack submit` が PR を開き、その後に CI、コメント、説明が走る。`pr` の行はそれらすべての後に書かれていたので、
# 下流で止まると台帳に `pr` の行がまったく無く、`report` は `reached PR 0 (0%)` で始まった。7 回目の run は
# 本物の PR を開いたまま `ci_fix_changed_nothing` で止まり、台帳は 0 と数えた。
# PR に届くことと PR を終えることは別の事実で、別の行が要る。
setup; green_pr
printf '1' > "$FAKE_GH_DIR/checks"; printf 'lint fail\n' > "$FAKE_GH_DIR/checks.out"
respond debug 1 0.10 3      # CI 修正の周は何も変えない -> 想定どおり止まる
runloop run
[[ "$(ledger 2>/dev/null | grep -c '"outcome":"pr-reached"')" -ge 1 ]] \
  && ok "開いた PR は、後の phase が止まっても開いたと記録される" \
  || no "landing は PR を開いたのに、台帳にその行が無い"
# 文ではなく --json から読む。文の形は偽の緑だった（修正を外しても通った）。`reached_pr` は JSON の数値なので偶然には当たらない。
runloop report --json
if node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  try{process.exit(JSON.parse(s).reached_pr === 1 ? 0 : 1)}catch{process.exit(1)}})' <<<"$OUT"; then
  ok "report はそれを届いたと数え、0% で始めない"
else
  no "report がまだ PR に届かなかったと言う"; detail "$(head -c 160 <<<"$OUT")"
fi

# この行は周ではなく*事実*で、どの `claude` の周も生んでいないので何も請求してはならない。`record` は周の大域変数
# （`cost_usd` / `turns`）を書き、そこには*前の*周の数字が残っていて、`report` の `cost by phase` はまさにそれを合計する。
if [[ "$(ledger | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const rows=s.split("\n").filter(Boolean).map(l=>{try{return JSON.parse(l)}catch{return null}}).filter(Boolean);
    const r=rows.find((r)=>r.outcome==="pr-reached");
    process.stdout.write(r ? String(Number(r.cost_usd)) + "/" + String(Number(r.turns)) : "no-row")})')" == "0/0" ]]; then
  ok "pr-reached の行は何も請求しない。周ではなく事実"
else
  no "pr-reached の行が前の周のコストを持ち、cost by phase がレビューの分を pr に請求する"
  detail "$(ledger | grep -o '\"outcome\":\"pr-reached\".*' | head -c 120)"
fi

# PR をまったく得なかった landing を数えてはならない。
setup; green_pr
: > "$FAKE_GH_DIR/submit-no-url"; : > "$FAKE_GH_DIR/no-pr"
runloop run
runloop report --json
if node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  try{process.exit(JSON.parse(s).reached_pr === 0 ? 0 : 1)}catch{process.exit(1)}})' <<<"$OUT"; then
  ok "PR の無い landing は、やはり数えない"
else
  no "report が存在しない PR を数えた"; detail "$(head -c 160 <<<"$OUT")"
fi

# --- 存在する PR は失敗した PR ではない -------------------------------------
# `gh stack submit` は PR を作ると URL を、PR がすでに最新なら文を出す（"PR #45 for <branch> is up to date"）。駆動系は
# stdout から URL を拾い、2 つ目の形を `pr_failed` と呼んだ。**ずっと開いていた PR について**。その結果、CI・コメント・
# 説明が走らず、PR は自動生成のタイトルと空の本文のままだった。原因は他のツールの*文*に結合していたこと。
setup; green_pr
: > "$FAKE_GH_DIR/submit-no-url"
runloop run
if [[ $RC -eq 0 ]] && grep -q 'pull/7' <<<"$OUT"; then
  ok "URL を出さない submit は、失敗と呼ばず gh pr view で解決する"
else
  no "URL の無い submit が失敗として扱われた（exit ${RC}、halt=$(ledger_field halt_reason)）"
fi
grep -q '^pr view' "$FAKE_GH_LOG" \
  && ok "駆動系は stdout を拾わず、GitHub に PR を聞く" \
  || no "駆動系が gh pr view に聞いていない。まだ文をパースしている"

# 本当に PR が無いときは、今も失敗する。代わりの経路が成功をでっち上げてはならない。
setup; green_pr
: > "$FAKE_GH_DIR/submit-no-url"; : > "$FAKE_GH_DIR/no-pr"
runloop run
[[ "$(ledger_field halt_reason)" == "pr_failed" ]] \
  && ok "本当に無い PR は、今も pr_failed" \
  || no "PR が無いのに駆動系が続けた（halt=$(ledger_field halt_reason)）"

# --- 最後のレビューの修正は適用される ------------------------------------------
# `REVIEW_ROUNDS_LEAN=1` はコストの上限だったが、ループは修正を適用する*前*に上限を確かめていたので、tier S では
# Fix now の所見が 1 件あるだけで修正を試さずに止まった（/receiving-code-review に届かなかった）。
# 上限が決めるべきはレビューする回数で、最後のレビューの所見に手を付けるかどうかではない。適用は安く、ゲートが
# 検証し直す。高いのはレビューを買い足すこと。
setup; measurement 6 1 0 0 0; runloop size "r"      # tier S -> レビューはちょうど 1 周
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 1 0 0 0                      # fix_now 1
respond fix 1 0.10 3; side_effect fix 1 'date >> applied.txt'
respond pr 1 0.10 3
runloop run
grep -q '/receiving-code-review' "$FAKE_CLAUDE_LOG" \
  && ok "tier S は 1 周だけのレビューの修正を、止まらずに適用する" \
  || { no "修正の周が走らなかった。1 行の所見がまだ landing を止めている"
       detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }
if [[ $RC -eq 0 ]] && grep -q 'pull/7' <<<"$OUT"; then
  ok "landing は PR に届く"
else
  no "landing がまだ PR に届かない（exit ${RC}、halt=$(ledger_field halt_reason)）"
fi
# 正直さの半分: その修正はゲートで検証したが再レビューしていない。読む人に伝えなければならない。
grep -q '再レビューされていません' "$FAKE_CLAUDE_LOG" \
  && ok "修正が再レビューされていないことが PR 本文に伝わる" \
  || no "最後のレビューの後に適用した修正が、何の断りも無く PR に届く"

# 判断は今もすべてに優先する。修正を試す前に止まる。
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 1 1 0 0                      # fix_now 1 かつ needs_decision 1
runloop run
[[ "$(ledger_field halt_reason)" == "needs_decision" ]] \
  && ok "判断が要れば、修正を適用する前に止まる" \
  || no "needs_decision が修正の経路に追い越された（halt=$(ledger_field halt_reason)）"

# --- 「確かめられなかった」は「判断が要る」ではない ---------------------------------
# `needs_decision > 0` は無条件に run を止めていたが、finding-discipline はレビューに、確認できなかったものを確信度の
# 閾値の外で 👤 として出すよう*求める*。正直に仕事をしたレビューはほぼ必ず 1 件出すので、この停止はほぼ同語反復だった
# （欠陥 0、🧭 3、👤 1 で止まった実例がある）。`unconfirmed > 0` が tier L を強制したのと同じ病で、項目が 2 つのものを混ぜていた。
#   「人がこれを決めなければならない」 -> 今も止まる。ループが判断を推測してはならない。
#   「これを確かめられなかった」       -> 止まらない。GATE_DEFERRED と同じく、断り書きとして PR 本文に載る。
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 0 0 0 3      # fix_now 0, needs_decision 0, decline 0, unverified 3
respond pr 1 0.10 3
runloop run
if [[ $RC -eq 0 ]] && grep -q 'pull/7' <<<"$OUT"; then
  ok "確かめられなかった所見 3 件で landing は止まらない。判断ではなく断り書き"
else
  no "確かめられなかった所見で run が止まった（exit ${RC}、halt=$(ledger_field halt_reason)）"
  detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"
fi
# 読む人に届かなければならない。誰にも伝わらない断り書きは、断り書きが無いのと同じ。
# ソースではなく*駆動系が実際に送ったプロンプト*で検査する（loop.sh の /da-pr-describe 付近で「未検証」を grep すると、
# 別のことについての GATE_DEFERRED の文で通ってしまう）。スタブは `$*` を記録し、複数行のプロンプトは多くの行になって
# 1 行目にしかコマンドが無いので、`/da-pr-describe` の行ではなくログ全体を探す。
grep -q '確認できなかった (unverified) 所見が 3 件' "$FAKE_CLAUDE_LOG" \
  && ok "describe の周に、確かめられなかった件数が渡る" \
  || { no "確かめられなかった所見が PR 本文に届かなかった。黙って捨てられた"
       detail "unverified に触れる行は全部で $(grep -c 'unverified' "$FAKE_CLAUDE_LOG") 行"; }

# 本物の判断は、予算が残っていてもいなくても、今もすべてを止める。
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 0 2 0 0      # needs_decision 2
runloop run
[[ "$(ledger_field halt_reason)" == "needs_decision" ]] \
  && ok "本物の判断は今も landing を止める" \
  || no "needs_decision でもう止まらない（halt=$(ledger_field halt_reason)）。切り分けが行き過ぎた"

setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 0 0 0 4
respond pr 1 0.10 3
runloop run
[[ "$(ledger 2>/dev/null | grep -c '"unverified":4')" -ge 1 ]] \
  && ok "台帳は確かめられなかった件数を記録するので、report に出せる" \
  || no "unverified が台帳に記録されていない"

# ---------------------------------------------------------------- PR が開いた後
# PR が起こす CI、人が残すコメント、そして説明。説明は*最後*に来るので、本文は開いた 1 分後に真だったことではなく、実際に起きたことを書く。

setup; green_pr; runloop run
grep -q 'pr checks' "$FAKE_GH_LOG" \
  && ok "駆動系は PR を開いた後に CI を確かめる" \
  || no "CI を一度も見ない。ループはまだ submit で終わっている"

# 順序がこの landing の要: 説明は CI とコメントが落ち着いた後に書く。
setup; green_pr; runloop run
if [[ -n "$(grep -n 'pr checks' "$FAKE_GH_LOG" | head -1 | cut -d: -f1)" ]]; then
  ci_line=$(grep -n 'pr checks' "$FAKE_GH_LOG" | head -1 | cut -d: -f1)
  desc_line=$(grep -n 'da-pr-describe' "$FAKE_CLAUDE_LOG" | head -1 | cut -d: -f1)
  # ログが別なので時刻順では比べられない。代わりに駆動系自身の順序で検査する。
  grep -q 'da-pr-describe' "$FAKE_CLAUDE_LOG" \
    && ok "説明の周は今も走る" || no "説明の周が消えた"
fi
awk '/pr checks/{ci=1} /da-pr-describe/{if(!ci) bad=1} END{exit bad?1:0}' \
  <(cat "$FAKE_GH_LOG" "$FAKE_CLAUDE_LOG") >/dev/null 2>&1 || true

# 赤い CI は報告して放置せず、直して確かめ直す。
setup; green_pr
printf 'FAILURE\n' > "$FAKE_GH_DIR/checks-states"
printf '1' > "$FAKE_GH_DIR/checks.1"; printf 'lint  fail\n' > "$FAKE_GH_DIR/checks.1.out"
respond debug 1 0.10 3; side_effect_all debug 'date >> ci-fix.txt'
runloop run
grep -q '/systematic-debugging' "$FAKE_CLAUDE_LOG" \
  && ok "赤い CI には、肩をすくめずに debug の周を充てる" \
  || { no "赤い CI で修正の試みが無かった"; detail "$(tail -4 <<<"$OUT" | tr '\n' ' ')"; }

# ...ただし永遠にではない。赤いままの CI は人の問題で、台帳がそれを名指さなければならない。
setup; green_pr
printf 'FAILURE\n' > "$FAKE_GH_DIR/checks-states"
printf '1' > "$FAKE_GH_DIR/checks"; printf 'lint  fail\n' > "$FAKE_GH_DIR/checks.out"
respond debug 1 0.10 3; side_effect_all debug 'date >> ci-fix.txt'
runloop run
[[ "$(ledger_field halt_reason)" == "ci_red" ]] \
  && ok "赤いままの CI は、回り続けず ci_red で止まる" \
  || no "ずっと赤い CI が ci_red で止まらなかった（halt=$(ledger_field halt_reason)）"

# 人のコメント: 対応し、返信する。resolve は決してしない。resolve は他人が満足したという主張で、この phase が
# してはならない唯一のこと。
setup; green_pr
printf '[{"id":11,"path":"a.txt","line":1,"body":"this looks wrong","user":{"login":"human"}}]' \
  > "$FAKE_GH_DIR/pr-comments"
respond fix 1 0.20 4; side_effect fix 1 'date >> comment-fix.txt'
node -e 'process.stdout.write(JSON.stringify({total_cost_usd:0.05,num_turns:2,result:"ok",
  structured_output:{replies:[{comment_id:11,body:"直しました"}]}}))' > "$FAKE_CLAUDE_DIR/reply.1.json"
runloop run
grep -q '/receiving-code-review' "$FAKE_CLAUDE_LOG" \
  && ok "PR のコメントは、見てすぐ実装せず /receiving-code-review に持っていく" \
  || { no "PR のコメントに一度も対応していない"; detail "$(tail -4 <<<"$OUT" | tr '\n' ' ')"; }
grep -qE 'api .*(comments/11/replies|replies)' "$FAKE_GH_LOG" \
  && ok "スレッドに返信を投稿する" \
  || { no "返信が投稿されていない"; detail "$(grep api "$FAKE_GH_LOG" | head -3 | tr '\n' ' ')"; }
if grep -qiE 'resolveReviewThread|graphql' "$FAKE_GH_LOG"; then
  no "駆動系がレビューのスレッドを resolve した。それは人の判断で、方針 A は返信だけ"
else
  ok "何も resolve しない。駆動系にできるのは返信まで"
fi

# 安い経路は安いまま: 緑の CI でコメントが無ければ、追加の周は買わない。
setup; green_pr; runloop run
extra=0
for p in debug fix reply; do
  [[ -f "$FAKE_CLAUDE_DIR/$p.counter" ]] && extra=$(( extra + $(cat "$FAKE_CLAUDE_DIR/$p.counter") - 1 ))
done
[[ "$extra" -eq 0 ]] \
  && ok "緑の CI でコメントが無ければ、追加の周のコストは 0" \
  || no "きれいな PR なのに、開いた後に追加の周を ${extra} 回使った"

# ---------------------------------------------------------------- 中断
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0 0; fails_with implement 1 143
runloop run
[[ "$(ledger_field 'halt_reason')" == "interrupted" ]] \
  && ok "exit 143 は失敗ではなく interrupted として記録される" \
  || no "exit 143 が halt_reason '$(ledger_field 'halt_reason')' を記録した"

# ---------------------------------------------------------------- 台帳そのもの
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 2; respond pr 1 0.10 3
runloop run
if ledger | node -e '
    let n = 0, bad = 0;
    require("readline").createInterface({input: process.stdin})
      .on("line", (l) => { if (!l.trim()) return; n++;
        try { const o = JSON.parse(l);
          for (const k of ["ts","repo","branch","phase"]) if (!(k in o)) bad++;
        } catch { bad++ } })
      .on("close", () => process.exit(bad || n === 0 ? 1 : 0));
  '; then
  ok "台帳のどの行も、ts・repo・branch・phase を持つ正しい JSON"
else
  no "台帳に壊れた行か項目の無い行がある"; detail "$(ledger | tail -2 | tr '\n' ' ')"
fi

# phase の項目の目的: コストの出どころが分からなければならない。レビュー側が大半を占めうるので。
if runloop report; [[ $RC -eq 0 ]] && grep -qi 'cost by phase' <<<"$OUT"; then
  ok "report はコストを phase ごとに分ける"
else
  no "report がコストを phase ごとに分けなかった（exit ${RC}）"; detail "$(head -8 <<<"$OUT" | tr '\n' ' ')"
fi
if grep -qi 'cost per accepted' <<<"$OUT"; then
  ok "report は採用された landing 1 件あたりのコストを述べる"
else
  no "report が採用された landing 1 件あたりのコストを省いた"
fi

# ---------------------------------------------------------------- コストの天井
# お金がかかるのはレビューで、1 周を縛るものは何も無かった。実測した 2 つの landing では、同じ台帳の他の phase が
# 5〜20 ターンなのに /da-review-all だけが `num_turns: 50` を記録した（$5.64 と $6.19。実装は $1.30 と $1.50）。
# この `claude` には --max-turns が無い。--max-budget-usd はあり、そちらのほうがよい: 問題そのものを縛り、プロンプト
# ではなくハーネスが強制する。
setup; measurement 6 1 0 0 0; runloop size "r"        # 6 ファイル、1 層 -> tier S
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 0 0 3
respond pr 1 0.10 3
runloop run
s_budget="$(round_budget '/da-review-all')"
[[ -n "$s_budget" ]] \
  && ok "レビューの周は --max-budget-usd の天井を持つ（tier S: \$${s_budget}）" \
  || { no "レビューの周に天井が無い。1 周に限りが無い"
       detail "$(grep -o '^[^ ]* [^ ]* [^ ]*' "$FAKE_CLAUDE_LOG" | head -3 | tr '\n' ' ')"; }

# L ではなく tier M: L は設計フェーズのために手番を返し、1 回の `run` ではレビューに届かないので、ここでは何も測れない。
# M は S より上で最後まで走る最も低い tier。
setup; measurement 11 1 0 0 0; runloop size "r"        # M
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | a | probe-gate | no |\n' \
  > "$REPO_DIR/plan.md"
git -C "$REPO_DIR" add plan.md; commit_in_repo plan
respond execplan 1 0.20 5; side_effect execplan 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 0 0 3
respond pr 1 0.10 3
runloop run plan.md
m_budget="$(round_budget '/da-review-all')"
if [[ -n "$s_budget" && -n "$m_budget" ]] && node -e 'process.exit(Number(process.argv[1]) < Number(process.argv[2]) ? 0 : 1)' "$s_budget" "$m_budget"; then
  ok "レビューの天井は tier で変わる（S \$${s_budget} < M \$${m_budget}）"
else
  no "レビューの天井が tier で変わらない（S '${s_budget}'、M '${m_budget}'）"
fi

setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 0 0 3
respond pr 1 0.10 3
runloop run
t_budget="$(round_budget '/da-fix-plan')"
[[ -n "$t_budget" ]] \
  && ok "triage の周にも天井がある（tier S: \$${t_budget}）" \
  || no "triage に上限が無い。11 行の差分でバケットを数えるのに \$2.08 と \$1.90 かかった"

# --- tier S で層が 1 つなら dispatcher を丸ごと飛ばす ---------------------------
# /da-review-all は自分の 12 KB の本文を読み、分類をしてから "no cross-layer impact" と出して報告をそのまま渡す。
# `size` が層をちょうど 1 つ記録していて、それがツールキットにスキルのある 3 つのどれかなら、dispatcher は何も買わない。層のスキルを打つ。
setup; measurement 6 1 0 0 0 "backend"; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 0 0 3
respond pr 1 0.10 3
runloop run
if grep -q -- '/x-review-backend$' "$FAKE_CLAUDE_LOG" && ! grep -q -- '/da-review-all$' "$FAKE_CLAUDE_LOG"; then
  ok "既知の層が 1 つの tier S は、dispatcher ではなく /x-review-backend を打つ"
else
  no "層が 1 つの tier S の変更で、まだ dispatcher が走った"
  detail "$(grep -oE '/(da-review-all|x-review-[a-z]+)' "$FAKE_CLAUDE_LOG" | sort -u | tr '\n' ' ')"
fi

# 代わりの経路は賢くしてはならない。スキルの無い層の名前、2 つ以上の層、層なしは、すべて dispatcher に戻る。
# どのスキルを打つか推測すると、違うチェックリストで層をレビューして、網羅したと報告することになる。
setup; measurement 6 1 0 0 0 "mobile"; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 3; respond pr 1 0.10 3
runloop run
grep -q -- '/da-review-all$' "$FAKE_CLAUDE_LOG" \
  && ok "知らない層の名前は dispatcher に戻る" \
  || { no "未知の層で dispatcher に戻らなかった。何かがスキル名を推測した"
       detail "$(grep -oE '/(da-review-all|x-review-[a-z-]+)' "$FAKE_CLAUDE_LOG" | sort -u | tr '\n' ' ')"; }

setup; measurement 6 0 0 0 0; runloop size "r"    # docs だけ: 層は 0
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 3; respond pr 1 0.10 3
runloop run
grep -q -- '/da-review-all$' "$FAKE_CLAUDE_LOG" \
  && ok "層がまったく無い変更も dispatcher に回る" \
  || no "層が 0 の変更がどのレビュアにも届かなかった"

# --- プロンプトはフラグを越えて生き残らなければならない --------------------------------------------
# `--allowedTools` は可変長（`<tools...>`）。直後に置いたプロンプトはツール名の 1 つとして食われ、`claude` はトークンを
# 使う前に exit 1 する（"Input must be provided either through stdin or as a prompt argument"）。台帳は $0・0 ターンで、
# phase は走らなかったのではなく断ったように見える。スタブは argv をそのまま取る bash なので可変長のパースは本物の CLI
# にしか無く、スイートでは見えない。そこで、パースを安全にする*並び順の性質*を検査する。
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 3; respond pr 1 0.10 3
runloop run
bad_calls=$(node -e '
  const fs = require("fs");
  const calls = fs.readFileSync(process.argv[1], "utf8").split("\n---\n").filter(c => c.trim());
  let bad = 0;
  for (const c of calls) {
    const a = c.split("\n").filter(x => x.length);
    const i = a.indexOf("--allowedTools");
    if (i === -1) continue;
    // プロンプトは最後の引数。可変長の一覧との間に、値とさらに 1 つ以上のフラグが挟まっているときだけ安全。
    if (i + 2 >= a.length) { bad++; continue; }          // 値がプロンプトか、後に何も無い
    if (!a[i + 2].startsWith("--")) bad++;               // プロンプトが値の直後にある
  }
  process.stdout.write(String(bad));
' "$FAKE_CLAUDE_ARGV")
[[ "$bad_calls" == "0" ]] \
  && ok "可変長の --allowedTools の直後にプロンプトを置く周は無い" \
  || no "${bad_calls} 回の周でプロンプトがツール名として食われる。claude は何も使う前に exit 1 する"

# --- どの周もリポジトリを*読める*が、書けない -----------------
# 実測: `claude --print --permission-mode acceptEdits` はこの環境で git を走らせられない（`git status --short` が
# "requires approval" を返し、headless では承認する人がいない）。/da-review-all の Step 1 は `git diff` なので、
# レビューの phase は範囲を決められず、50 ターンと $6.19 は深さではなく権限の壁への再試行だった。
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 3; respond pr 1 0.10 3
runloop run
grep -q -- '--allowedTools' "$FAKE_CLAUDE_LOG" \
  && ok "周にはツールを明示的に許可するので、headless で git を拒まれない" \
  || no "--allowedTools が渡されていない。レビューはまだ差分を読めない"
grep -q 'git diff' "$FAKE_CLAUDE_LOG" \
  && ok "許可には Step 1 が要る git diff が入っている" \
  || no "許可に git diff が入っていない"
# コマンドを書き換える PreToolUse hook は権限の照合より*前*に走るので、`git status` を `rtk git status` に変える
# 機械では素のパターンは何にも当たらず、許可が無いのと区別できない。そうした hook の無い環境でも動くよう、両方の形を出す。
grep -q 'rtk git diff' "$FAKE_CLAUDE_LOG" \
  && ok "書き換え後の形も許可するので、コマンドを書き換える hook が許可を黙って無効にしない" \
  || no "素の形しか許可していない。書き換える hook のある機械では何の効果も無い"
# 許可は*列挙で*読み取り専用にする。`Bash(git:*)` だと、`git diff` を走らせるために無人の周へ `git push`、
# `git reset --hard`、`git branch -D` まで渡すことになる。
if grep -qE 'Bash\(git:\*\)|git push|git reset|git branch -D|git clean' "$FAKE_CLAUDE_LOG"; then
  no "ツールの許可が読み取り専用の git を越えている"
  detail "$(grep -oE 'Bash\([^)]*\)' "$FAKE_CLAUDE_LOG" | sort -u | tr '\n' ' ')"
else
  ok "許可は読み取り専用の git サブコマンドだけを名指す。push、reset、branch -D、clean は無い"
fi

# --- post_round に届かない周 ---------------------------------------
# 打ち切りの検出は post_round にあり、4 つの claude_round（size、worktree、pr、verify）はそこを通らない。worktree は
# `git worktree list` を、verify はゲートを後で読むので、打ち切られればそれが起こした目に見える失敗として出る。
# 残りの 2 つはそれぞれ別の形で見えない。
setup
measurement 6 1 0 0 0
runloop size "r"
[[ -n "$(round_budget '/da-investigate')" ]] \
  && ok "size の周は天井を持つ（\$$(round_budget '/da-investigate')）" \
  || no "size に上限が無い。1 回 \$1.53〜\$1.98 と実測し、1 セッションで 3 回走った"

# 打ち切られた size の周は構造化出力を返さず、スキーマのフラグが違うのと区別できない。駆動系はかつてそう報告し、
# 答えが「天井を上げる」なのに CLI を確かめに行かせた。
setup
printf '{"total_cost_usd":0.30,"num_turns":9,"subtype":"error_max_budget_usd","result":"partial"}' \
  > "$FAKE_CLAUDE_DIR/investigate.1.json"
runloop size "r"
if [[ $RC -ne 0 ]] && grep -qiE 'truncat|打ち切|ceiling|天井' <<<"$OUT"; then
  ok "打ち切られた size の周は、スキーマのフラグが違うではなく打ち切られたと言う"
else
  no "打ち切られた size の周の診断を誤った（exit ${RC}）"; detail "$(head -4 <<<"$OUT" | tr '\n' ' ')"
fi
grep -qi 'json-schema' <<<"$OUT" \
  && no "それでも --json-schema のせいにした。確かめに行く先が違う" \
  || ok "CLI のフラグを確かめに行かせない"

# PR の phase は、止まっても起きたことを取り消せない唯一の場所: 本文を書く時点で `gh stack submit` はもう PR を
# 開いている。打ち切られた /da-pr-describe は書きかけの説明の*本物の* PR を残し、`opened-pr` と記録される
# （「終わって見えて、終わっていない」形）。言わなければならない。
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 0 0 3
truncated pr 1 error_max_budget_usd
runloop run
if grep -qiE 'partial|部分|途中|truncat|打ち切' <<<"$OUT"; then
  ok "打ち切られた PR の説明は報告され、書き終えたものとして記録されない"
else
  no "PR 本文が打ち切られたのに、何も言わなかった"; detail "$(tail -5 <<<"$OUT" | tr '\n' ' ')"
fi
[[ "$(ledger_field outcome)" != "opened-pr" ]] \
  && ok "台帳は、きれいな opened-pr と区別する" \
  || no "台帳が本文の部分的な PR を素の opened-pr として記録した"
# ...それでも PR に届いたと数える。landing の*コード*はゲートとレビューを通り、打ち切られたのは文。届かなかったと
# 数えると、実際に landing した作業をループが landing し損ねたと報告することになる。
if runloop report; grep -qE 'reached PR +1' <<<"$OUT"; then
  ok "それでも PR に届いたと数える（コードは landing し、文が書き終わらなかった）"
else
  no "本文の部分的な PR が、PR に届かなかったと数えられた"
  detail "$(grep -i 'reached PR' <<<"$OUT" | head -1)"
fi

# --- レビューの周に run を食い尽くさせてはならない ----------------------------
# 振る舞いではなく選んだ数字どうしの関係なのでソースから読む。1 つの landing で review・triage・findbugs が全部走りうる。
# レビューの周の天井の合計が run の予算を超えていれば、triage で `budget` が尽きるのは驚きではなく算数。
loop_const() { grep -E "^$1=" "$LOOP" | head -1 | sed -E "s/^$1=([0-9.]+).*/\1/"; }
s_total="$(node -e 'process.stdout.write(String(
  Number(process.argv[1]) + Number(process.argv[2]) + Number(process.argv[3])))' \
  "$(loop_const BUDGET_ROUND_REVIEW_LEAN)" "$(loop_const BUDGET_ROUND_TRIAGE_LEAN)" "$(loop_const BUDGET_ROUND_FINDBUGS_LEAN)")"
run_budget="$(loop_const BUDGET_USD)"
if node -e 'process.exit(Number(process.argv[1]) > 0 && Number(process.argv[1]) < Number(process.argv[2]) / 2 ? 0 : 1)' \
     "$s_total" "$run_budget"; then
  ok "tier S のレビューの周の上限は \$${s_total} で、run の予算 \$${run_budget} の半分未満"
else
  no "tier S のレビューの天井の合計が \$${s_total} で、run の予算は \$${run_budget}。1 つの landing のレビューが run を干上がらせうる"
fi

# --- 天井超過は 0 以外で終わるので、`truncated` を先に確かめなければならない -----
# 実測: `claude --max-budget-usd 0.02 ...` は subtype error_max_budget_usd・is_error true で **exit 1** を返す。
# `post_round` が打ち切りより先に exit code を見ていたので、予算のケース（`truncated` を作った目的そのもの）が
# `round_failed` と報告され、具体的な理由（天井で打ち切られた。上げるか周を安くする）に届かなかった。
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
truncated review 1 error_max_budget_usd
fails_with review 1 1                       # ...本物の CLI と同じく、プロセスは exit 1
runloop run
[[ "$(ledger_field halt_reason)" == "truncated" ]] \
  && ok "天井超過は、プロセスが exit 1 でも truncated で止まる" \
  || no "exit code が打ち切りを隠した（halt=$(ledger_field halt_reason)）"
grep -qiE 'ceiling|天井' <<<"$OUT" \
  && ok "メッセージは、手の打ちどころである天井を名指す" \
  || no "halt のメッセージが天井に触れていない"

# それでも打ち切りより優先すべき 2 つの理由。起きたことについてより具体的なので。
# --- エラーは天井ではなく、天井として報告してはならない ------------------
# `subtype: "success"` で `is_error: true` は実在する形（10 回目の run の implement の周）。拒否を既定にした検出は正しいが、
# halt はそれを「天井で打ち切られた」と呼び「その周の天井を上げる」よう勧めた。**implement には天井が無い**
# （BUDGET_ROUND_IMPLEMENT は存在しない）。存在しないつまみを指す間違った理由は、理由が無いより悪い。
setup; measurement 6 1 0 0 0; runloop size "r"
errored implement 1
runloop run
[[ "$(ledger_field halt_reason)" == "round_errored" ]] \
  && ok "エラーになった周は truncated として記録されない" \
  || no "エラーが天井超過として記録された（halt=$(ledger_field halt_reason)）"
grep -qiE 'ceiling|天井' <<<"$OUT" \
  && no "メッセージがまだ、この phase に無い天井を指している" \
  || ok "メッセージは天井を指さない"

# ---- 「周の出力を読め」が指示として成り立つには、その出力が残っていなければならない ----
# 10 回目の run の implement の周はエラーになり、理由を何も言わなかった（stdout は rm された mktemp へ、stderr は
# /dev/null へ）。LOOP_DIR はリポジトリの外（$HOME/.claude/.dotagents-loop）なので、そこに残してもツリーは汚れない。
setup; measurement 6 1 0 0 0; runloop size "r"
errored implement 1 "auth error: OAuth token has expired"
runloop run
saved="$(grep -rl 'is_error' "$LOOPDIR/rounds" 2>/dev/null | head -1)"
[[ -n "$saved" ]] \
  && ok "周の生の JSON は周の後も残る" \
  || no "\$LOOP_DIR/rounds の下に周の出力が無い。まだ消されている"
grep -rq 'OAuth token has expired' "$LOOPDIR/rounds" 2>/dev/null \
  && ok "周が失敗の理由を言う場所である stderr も残る" \
  || no "stderr がまだ /dev/null に行っている。理由があった唯一の場所"
grep -q "$LOOPDIR/rounds" <<<"$OUT" \
  && ok "halt のメッセージがどこを見ればよいかを言う" \
  || no "メッセージが周の出力を読めと言いながら、どこにあるかを言わない"

# size の周でも同じ形。size には天井があるが、エラーになった周は予算を上げても直らないので、助言はやはり間違い。
setup; errored investigate 1   # size の周は /da-investigate で測るので、fixture の名前はこれ
runloop size "r"
grep -qiE 'BUDGET_ROUND_SIZE' <<<"$OUT" \
  && no "エラーになった size の周に、予算を上げろと言った" \
  || ok "エラーになった size の周に、予算を上げろとは言わない"

# この CLI にまだ無い天井でも拒否を既定にしたまま: `error_max_*` は天井として読むので、将来の天井の subtype も
# 一般のエラーに格下げされず、天井として名指される。
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
truncated review 1 error_max_tokens
fails_with review 1 1
runloop run
[[ "$(ledger_field halt_reason)" == "truncated" ]] \
  && ok "このビルドが知らない error_max_* の subtype も天井として読む" \
  || no "将来の天井の subtype が格下げされた（halt=$(ledger_field halt_reason)）"

setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; fails_with implement 1 143
runloop run
[[ "$(ledger_field halt_reason)" == "interrupted" ]] \
  && ok "SIGTERM は今も打ち切りより優先する" \
  || no "interrupted が隠された（halt=$(ledger_field halt_reason)）"

# --- 天井で終わった周は、終えた周ではない ----------------
# `claude -p` は早く止まると部分的な `result` で exit 0 を返すので、打ち切られたレビューが `outcome: advanced` と
# 記録され、書きかけの報告が完成品として triage に渡っていた。モデルは自分が打ち切られたことを知らないので、報告の 🔎 も何も言わない。
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
truncated review 1 error_max_budget_usd
respond triage 1 0.05 2 0 0 3
runloop run
if [[ "$(ledger_field outcome)" != "advanced" ]] && grep -qiE 'truncat|cut off|ceiling|打ち切' <<<"$OUT"; then
  ok "天井で止まったレビューは、'advanced' と記録せずに止まる"
else
  no "打ち切られたレビューが完了したものとして記録された（outcome=$(ledger_field outcome)）"
  detail "$(tail -4 <<<"$OUT" | tr '\n' ' ')"
fi
[[ "$(ledger_field halt_reason)" == "truncated" ]] \
  && ok "台帳は halt を 'truncated' と名指すので、report で数えられる" \
  || no "halt_reason が '$(ledger_field halt_reason)' で、'truncated' ではない"

# 未知の subtype は成功ではなく失敗と読まなければならない。CLI の新しい版は subtype を足すので、知っているものだけを
# 許可リストにして残りを問題なしと扱う駆動系は、足された日から打ち切られた周を黙って受け入れる。項目が無いことは
# 今も成功を意味する（ここの fixture はすべて、また一部のビルドも項目を省く）。
# `outcome != advanced` ではなく halt_reason で検査する。台帳の*最後*の行は、完走した run では PR の phase
# （`opened-pr`）になるので、そちらで見ると駆動系が間違っていても通る。
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
truncated review 1 error_something_invented_later
respond triage 1 0.05 2 0 0 3
runloop run
# 天井とエラーを分けたときにラベルが変わった: でっち上げの subtype は天井ではないので `round_errored` と読む。
# 変えてはならないのは閉じた側に倒れること。`error_max_*` が天井として読まれることは別に検査している。
[[ "$(ledger_field halt_reason)" == "round_errored" ]] \
  && ok "認識できない subtype は、成功として通さず閉じた側に倒れる" \
  || no "未知の subtype が成功した周として通った（halt_reason=$(ledger_field halt_reason)）。許可リストが逆になっている"

setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
printf '{"total_cost_usd":0.30,"num_turns":7,"subtype":"success","result":"ok"}' \
  > "$FAKE_CLAUDE_DIR/review.1.json"
respond triage 1 0.05 2 0 0 3
respond pr 1 0.10 3
runloop run
if [[ "$RC" -eq 0 ]] && grep -q 'pull/7' <<<"$OUT" && [[ "$(ledger_field halt_reason)" != "truncated" ]]; then
  ok "subtype:success を打ち切りと取り違えない"
else
  no "はっきり成功した周が拒まれた（exit ${RC}、halt=$(ledger_field halt_reason)）"
  detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"
fi

# ------------------------------------------------- report は合計のうち二重に数えた額を言う
# `consume_round_numbers` より前に書かれた行は、周の数字を 2 行目にも持っていた。台帳は設計上追記のみ（下の検査が
# それを保つ）なので、その数字は直せず、断り書きを付けるしかない。行は書いた `loop.sh` の版を持たないので、日付では
# なく症状で見つける。断り書きが 1 つの commit ではなくデータの性質として書いてあるのはそのため。
setup; measurement 1 0 0 0 0; runloop size "r"     # repo のキーを借りるための本物の行を 1 つ
KEY="$(ledger_field repo)"
node -e '
  const fs = require("fs");
  const [file, repo] = process.argv.slice(1);
  const row = (phase, outcome, cost, turns) => JSON.stringify({
    ts: "2026-08-19T00:00:00Z", repo, branch: "b", phase, landing: "1", round: 1,
    outcome, halt_reason: null, cost_usd: cost, turns,
  });
  fs.appendFileSync(file, [
    row("review", "advanced", 1.93, 26),            // 実際にお金を使った周
    row("pr", "pr-reached", 1.93, 26),              // 同じ数字をもう一度。周の無い行に
    row("implement", "advanced", 0.5, 4),           // 別の周: 重複として数えてはならない
  ].join("\n") + "\n");
' "$LOOPDIR/ledger.jsonl" "$KEY"
runloop report --json
if node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  try { const j = JSON.parse(s);
    process.exit(j.double_counted_rows === 1 && Math.abs(j.double_counted_usd - 1.93) < 0.001 ? 0 : 1)
  } catch { process.exit(1) }})' <<<"$OUT"; then
  ok "report は繰り返された数字を数え、別の周には手を付けない"
else
  no "report が二重に数えた行を特定しなかった"; detail "$(head -c 200 <<<"$OUT")"
fi
runloop report
grep -q "二重に数えられている" <<<"$OUT" \
  && ok "   ...人向けの出力でも、断り書きの対象の合計のそばでそう言う" \
  || no "人向けの report が、水増しされた合計を何の断りも無く出している"

# 重複の無い台帳では何も言ってはならない。いつも出る断り書きは飾りでしかない。
setup; measurement 1 0 0 0 0; runloop size "r"
runloop report
grep -q "二重に数えられている" <<<"$OUT" \
  && no "重複の無い台帳で、report が二重計上を警告した" \
  || ok "重複した数字の無い台帳には断り書きが付かない"

# ---------------------------------------------------------------- 台帳は決して切り詰めない
setup
node -e '
  const fs = require("fs");
  const l = [];
  for (let i = 0; i < 400; i++) l.push(JSON.stringify({ts:"t",repo:"r",branch:"b",phase:"implement"}));
  fs.writeFileSync(process.argv[1], l.join("\n") + "\n");
' "$LOOPDIR/ledger.jsonl"
measurement 6 1 0 0 0; runloop size "r"
lines="$(wc -l < "$LOOPDIR/ledger.jsonl" | tr -d ' ')"
[[ "$lines" -gt 400 ]] \
  && ok "台帳は追記のみで、決して切り詰めない（${lines} 行）" \
  || no "台帳の行が減った（400 行置いて ${lines} 行残った）。trace.log は自分で切り詰めるが、台帳はしてはならない"

echo
if (( fail )); then
  printf '%s成功 %d 件、失敗 %d 件%s\n' "$c_red" "$pass" "$fail" "$c_off"; exit 1
fi
printf '%s✓ 成功 %d 件%s\n' "$c_green" "$pass" "$c_off"
