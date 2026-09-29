#!/usr/bin/env bash
# Stop hook。リポジトリ自身の検証が失敗している間、ターンを終わらせない。
#
# エージェントは作業が「終わったように見えた」時点で止まる。実行できるチェックが無ければそれが唯一の
# 合図になり、人間が検証ループの役を負う。
#
# 番兵で有効になる。スキルが次を作って掛けない限り何もしない。
#   ~/.claude/.dotagents-gate/<slug>/ACTIVE
# 常時有効な Stop hook は、質問に答えるだけのセッションでも毎回テストを回して使い物にならず、
# 結局外される。それは無いより悪い。
#
# 3 つのエージェントで動くが、強制力は違う。
#
#   Claude Code  Stop hook。  exit 2 でターンを止め、stderr がエージェントに渡る。他の終了コードでは
#                             止まらない（exit 1 は非ブロックのエラーでターンが終わる）。docs/harness-facts.md 参照。
#   Codex        Stop hook。  Claude Code と同じ契約で、payload も同じ形（turn_id などが足される）なので
#                             Claude Code として扱う。exit 0 の時に stdout へ平文を出してはならない。
#   Cursor       stop hook。  止められない。{"followup_message": "..."} を出すとメッセージが自動送信され、
#                             エージェントが作業を続ける。Cursor の loop_limit（既定 5）で頭打ちになる。
#
# Cursor 側は実際に弱い。チェックが赤のままでもユーザーは止められる。同等だとはどこにも書かない。

set -uo pipefail

# 以下の判断はすべて node を通す。node が無い時（GUI から起動したエージェントの PATH にバージョン
# マネージャーの shim が無い、が多い）は、ターンを通さずそう言わなければならない。
# 本当の原因についてのメッセージになるよう、何より先に確かめる。
GATE_NODE_MISSING=0
command -v node >/dev/null 2>&1 || GATE_NODE_MISSING=1

# `gate.sh verify` が設定し、エージェントのハーネスは設定しない。dry モードではターン終了時と同じく
# プロファイルを解決してチェックを実行し、その後は何も変えない。試行回数も verdict も heartbeat も
# 触らず、掛ける必要も無い。確認で予算を減らすと、予算が確認の頻度に左右されてしまうため。
GATE_DRY="${DOTAGENTS_GATE_DRY:-0}"
[[ "$GATE_DRY" == "1" ]] || GATE_DRY=0

GATE_DIR="${DOTAGENTS_GATE_DIR:-$HOME/.claude/.dotagents-gate}"
TRACE="$GATE_DIR/trace.log"

# 実体は下の共有ブロックにある。gate.sh も arm / disarm / record を同じログに書く。
trace() { gate_trace "$@"; }

# >>> dotagents:gate-shared -- byte-identical in scripts/gate.sh and hooks/dotagents-verify-gate.sh.
# lib から source せず複製している。不変条件 4（hook は消えうるパスに依存しない）のため。
# 2 つのコピーの一致は scripts/verify-skills.sh が検査する。
#
# --- 識別 -------------------------------------------------------------------
# 問いが違うので 2 段に分ける。
#   ゲートが掛かっているかはリポジトリの性質なので、共有の git ディレクトリで引く。
#   これでリンクされた worktree がメインのチェックアウトのゲートを継ぐ。
#   試行回数と委任の記録は作業ツリーの性質なので worktree ごとに持つ。継いでもカウンタは共有しない。
gate_abs() { # <dir> <rev-parse-flag> -> 絶対パス。決められなければ空
  local d="$1" f="$2" p
  p="$(git -C "$d" rev-parse --path-format=absolute "$f" 2>/dev/null || true)"
  case "$p" in /*) printf '%s' "$p"; return 0 ;; esac
  # git < 2.31 には --path-format が無く、素の --git-common-dir は問い合わせ元からの相対で返る。
  # 手で解決し、どれかが空なら推測しない。`cd ""` は成功して黙って $HOME を返す。
  p="$(git -C "$d" rev-parse "$f" 2>/dev/null || true)"
  [[ -n "$p" ]] || return 0
  case "$p" in /*) printf '%s' "$p"; return 0 ;; esac
  ( cd "$d" 2>/dev/null && cd "$p" 2>/dev/null && pwd ) || true
}

gate_common_dir() { gate_abs "$1" --git-common-dir; }

# git はリンクされた worktree ごとに一意の名前を <common>/worktrees/<name> に持っている。
# パスをハッシュするより再利用がよい。暗号も node も要らず、人が読めるディレクトリ名になる。
gate_worktree_key() { # <dir> -> この作業ツリーに一意な、ファイル名に使える ID
  local g c
  g="$(gate_abs "$1" --git-dir)"
  c="$(gate_abs "$1" --git-common-dir)"
  if [[ -n "$g" && -n "$c" && "$g" != "$c" ]]; then basename "$g"; else printf 'main'; fi
}

# 作業ツリー自身のカウンタの置き場。番兵の 1 段下なので、複数の worktree が継いだゲートでも
# 試行回数はツリーごとに 1 組になる。
state_dir_for() { # <armed-dir> <dir>
  printf '%s/wt/%s' "$1" "$(gate_worktree_key "$2")"
}

# --- トレース ---------------------------------------------------------------
# 1 イベント 1 行。「何も起きなかった」と「動かなかった」を見分けるため。$HOME の下で際限なく
# 育たないよう上限を設ける。
#
# hook だけでなく `gate.sh` もここへ書く。誰も覚えていないゲートを説明するのがこのファイルの役目で、
# arm / disarm / record が残らなければその役目を果たせない。
gate_trace() { # <who> <where> <what>
  [[ -d "$GATE_DIR" ]] || return 0
  local trace="$GATE_DIR/trace.log" tmp
  printf '%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${1:-?}" "${2:-?}" "${3:-}" >> "$trace" 2>/dev/null || true
  # 一時ファイルに切り詰めて rename する。`tail > f.trim && mv f.trim f` は 2 手の間に隙があり、
  # 同時に終わった 2 ターンが行を失いうる。
  if [[ "$(wc -l < "$trace" 2>/dev/null || echo 0)" -gt 200 ]]; then
    tmp="$trace.trim.$$"
    tail -100 "$trace" > "$tmp" 2>/dev/null && mv -f "$tmp" "$trace" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  fi
  return 0
}

# --- 時計 -------------------------------------------------------------------
# エポックは mtime ではなくファイルの中身に持つ。`touch -t` の計算は BSD と GNU で違い、テストは
# 時刻を決定的に動かす必要がある。`date +%s` は両方で同じ。
# DOTAGENTS_GATE_NOW はそのテスト用。他では設定しない。
gate_now() {
  local n="${DOTAGENTS_GATE_NOW:-}"
  case "$n" in ''|*[!0-9]*) date +%s ;; *) printf '%s' "$n" ;; esac
}

# 12 時間は計測ではなく選んだ値。長い無人実行より長く、一晩よりは短く。
gate_ttl_seconds() {
  local h="${DOTAGENTS_GATE_TTL_HOURS:-12}"
  case "$h" in ''|*[!0-9]*) h=12 ;; esac
  printf '%s' $(( h * 3600 ))
}

# このゲートで最後にターンが終わってからの秒数。経過時間ではなくアイドル時間。掛けた時点から
# 数えると、6 時間の無人実行が途中で期限切れになり、ゲートが黙って開く。
# heartbeat が無ければ空を返す。呼び出し側はこれを「無限にアイドル」と読んではいけない。
# 古い gate.sh で 1 分前に掛けたゲートを追い出してしまう。
gate_idle_seconds() { # <armed-dir>
  local hb now
  hb="$(cat "$1/HEARTBEAT" 2>/dev/null || true)"
  case "$hb" in ''|*[!0-9]*) return 0 ;; esac
  now="$(gate_now)"
  printf '%s' $(( now - hb ))
}

gate_touch_heartbeat() { # <armed-dir>
  local tmp="$1/HEARTBEAT.tmp.$$"
  gate_now > "$tmp" 2>/dev/null && mv -f "$tmp" "$1/HEARTBEAT" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# --- verdict ----------------------------------------------------------------
# verdict は「無い状態」ではなく「在るファイル」で表す。ACTIVE を消すだけだと、次のセッションの
# `status` は「not armed」と答え、一度も掛けなかったセッションと区別できない。
#
# 1 行 1 フィールド。hook が作業ファイルに使うのと同じ `sed -n Np` で読む。
#   1 時刻   2 理由   3 チェック ID   4 試行回数   5 終了コード   6 エージェント   7 コマンド   8 以降 出力
gate_write_verdict() { # <dir> <reason> <check> <attempts> <exit> <agent> <command> [output]
  local d="$1" tmp="$1/VERDICT.tmp.$$"
  {
    date -u +%Y-%m-%dT%H:%M:%SZ
    printf '%s\n%s\n%s\n%s\n%s\n' "${2:--}" "${3:--}" "${4:-0}" "${5:--}" "${6:--}"
    # 1 行に潰す。各フィールドは行番号で引くので、改行を含むコマンドが出力の末尾を記録の途中へ押し込む。
    printf '%s' "${7:--}" | tr '\n' ' '
    printf '\n%s\n' "${8:-}"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$d/VERDICT" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# trace.log の隣に置くが、切り詰めない。trace は 200 行で自動的に切り詰めるので、そこにしか無い
# verdict は通常運用で消える。
gate_log_verdict() { # <root> <reason> <detail>
  printf '%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${1:--}" "${2:--}" "${3:-}" \
    >> "$GATE_DIR/verdicts.log" 2>/dev/null || true
  return 0
}

# アイドルの番兵を回収する。ACTIVE は消してゲートを無効にする。ROOT と VERDICT は残し、`status` が
# 誰のゲートで、なぜ終わったかを答えられるようにする。回収したルートを出力する。
gate_expire() { # <armed-dir> <idle-seconds>
  local d="$1" idle="${2:-0}" root ttl
  root="$(cat "$d/ROOT" 2>/dev/null || true)"
  [[ -n "$root" ]] || root="$(cat "$d/ACTIVE" 2>/dev/null || true)"
  ttl="$(gate_ttl_seconds)"
  [[ -n "$root" ]] && printf '%s' "$root" > "$d/ROOT" 2>/dev/null
  gate_write_verdict "$d" expired - 0 - - - \
"アイドル $(( idle / 3600 ))h のため回収（ttl $(( ttl / 3600 ))h）。ゲートを掛けたセッションが、
解除せずに終わった。この verdict は何も検査していない。ゲートが止めるのをやめたことだけを
記録しており、作業が検証済みだとは言っていない。"
  rm -f "$d/ACTIVE"
  printf '%s' "$root"
}
# <<< dotagents:gate-shared

# インストール先は ~/.claude/hooks でリポジトリから離れているので、マニフェストにリポジトリの場所を
# 記録してある。DOTAGENTS_PROFILES はどちらより優先し、テストを外部から切り離すのに使う。
PROFILES="${DOTAGENTS_PROFILES:-}"
if [[ -z "$PROFILES" ]]; then
  PROFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../profiles"
  if [[ ! -d "$PROFILES" ]]; then
    PROFILES="$(node -e '
      try { console.log(require(process.env.HOME+"/.claude/.dotagents-managed.json").repo + "/profiles") } catch {}
    ' 2>/dev/null)"
  fi
fi

# ---------------------------------------------------------------- ゲート無し。何もしない

shopt -s nullglob
active=("$GATE_DIR"/*/ACTIVE)
if (( ${#active[@]} == 0 )) && (( GATE_DRY )); then
  # 何も掛かっていないが、dry 実行が問うのはゲートが止めるかではなくチェックが通るか。
  # 番兵のリストを空にして続ける。
  :
elif (( ${#active[@]} == 0 )); then
  trace "?" "$PWD" "呼ばれたが何も掛かっていない。通した"
  exit 0
fi

# 何かが掛かっている。ここから先ゲートは答えを出す責任があり、答えを出す手順はすべて node を通る
# （ペイロードがどのリポジトリを指すかの判定も含む）。node が無いと掛かっている番兵がこのリポジトリの
# ものか判定できず、「掛かっているが他所のもの、続行」とは結論できないので、ここで確かめる。
if [[ "$GATE_NODE_MISSING" == "1" ]]; then
  {
    echo "[dotagents] 検証ゲートには node が要るが、PATH に見つからない。何も検査できない。"
    echo
    echo "ゲートは掛かっているが、node が無いとこの hook はどのリポジトリのゲートかさえ判定できない。"
    echo "作業ではなくゲートの環境の不具合。エージェントの PATH を直すか、ゲートを外すこと。"
    echo "通過とみなさないこと。"
  } >&2
  exit 2
fi

# ペイロードは素の stdin ではなく、明示したディスクリプタから読む。
#
# fd 0 が（空ではなく）閉じている時、bash はコマンド置換のパイプに最小の空き番号、つまり fd 0 を
# 割り当てる。すると `payload="$(cat)"` の `cat` は自分の出力パイプを読んで永遠に止まり、ハーネスが
# タイムアウトで殺す。殺された hook は 0 でも 2 でもなく非ブロックで終わり、ゲートが開く。
#
# 先に fd 0 を fd 3 へ複製すると、stdin が無ければ複製がはっきり失敗し、以後 fd 0 を誤って渡される
# こともない。確かめはサブシェルで行う。コマンド無しの `exec` にリダイレクトを付けるとシェル全体に
# 恒久的に効き、`exec 3<&0 2>/dev/null` だと以後の stderr がすべて捨てられ block のメッセージが
# モデルに届かなくなる。
if ( exec 3<&0 ) 2>/dev/null; then
  exec 3<&0
else
  trace "?" "$PWD" "読める stdin が無い。ペイロードを空として扱う"
  exec 3</dev/null
fi
# 何かが掛かっているので、ここから先の想定外の失敗を「止まってよい」と読ませてはならない。
#
# 止められるのは exit 2 だけで、exit 1 は非ブロックのエラーとして Claude Code が先へ進む。この
# スクリプトは `set -u` で動くので未定義変数ひとつで落ちる（空白を含む cwd で算術比較が 127 で
# 落ちたことがある）。trap で構造的に防ぎ、一件ずつ直すのをやめる。
#
# ペイロードの解析より前に入れる。誤動作している間は「掛かっているが、このリポジトリのものでは
# ないかもしれない」とは結論できない。上の node 欠如のブロックと同じ理屈。
agent="claude"
cwd="$PWD"
slug_dir=""
_gate_work=""
gate_on_exit() {
  local code=$?
  [[ -n "$_gate_work" ]] && rm -f "$_gate_work" "$_gate_work.fail" "$_gate_work.out" "$_gate_work.timeout"
  # Cursor は止められないので、変換しても得るものが無く、読まれないストリームを汚すだけ。
  if [[ "$code" != "0" && "$code" != "2" && "$agent" != "cursor" ]]; then
    trace "$agent" "$cwd" "CRASHED（status ${code}）。block に変換した"
    {
      echo "[dotagents] 検証ゲートが想定外に終了した（status ${code}）。このリポジトリのチェックが"
      echo "通るかは分からない。"
      echo
      echo "作業ではなくゲートの不具合。ただし止められるのは exit 2 だけで、他の status なら何も"
      echo "検査しないままターンが終わっていた。通過とみなさず、ゲートが壊れたと報告すること${slug_dir:+。または $slug_dir のゲートを外すこと}。"
    } >&2
    exit 2
  fi
}
trap gate_on_exit EXIT

payload="$(cat <&3)"
exec 3<&-

# 2 つのエージェントはペイロードで見分ける。Cursor の stop hook は {status, loop_count} を送り cwd が
# 無い。Claude Code は cwd と hook_event_name を送る。
# 空白区切りではなく 1 行 1 フィールド。空白を含む cwd が loop_count に入り込み、`set -u` 下の
# `[[ "project 0" -ge 3 ]]` が 127 で落ちて（非ブロック）、~/my project のようなパスでゲートが開くため。
_fields="$(printf '%s' "$payload" | node -e '
  let s = ""; process.stdin.on("data", d => (s += d)).on("end", () => {
    let p = {}; try { p = JSON.parse(s) } catch {}
    const cursor = "loop_count" in p || ("status" in p && !("cwd" in p));
    const n = Number(p.loop_count);
    // サブエージェントの完了はターンの終わりではない。Claude Code は登録された Stop hook を
    // サブエージェントでは SubagentStop に変えるので、この hook はそこでも発火する。イベント名が
    // 無くても agent_id はある。ここにアポストロフィを書かないこと。スクリプト全体がシェルの
    // シングルクォート引数の中にあり、1 つで閉じてスクリプトの文面が出力に漏れる。
    const sub = p.hook_event_name === "SubagentStop" || "agent_id" in p ? "1" : "0";
    process.stdout.write([
      cursor ? "cursor" : "claude",
      p.cwd || "-",
      Number.isFinite(n) ? String(Math.trunc(n)) : "0",
      p.stop_hook_active ? "1" : "0",
      sub,
      String(p.agent_type || "-"),
    ].join("\n") + "\n");
  });
' 2>/dev/null)"

agent="$(sed -n 1p <<<"$_fields")"
cwd="$(sed -n 2p <<<"$_fields")"
loop_count="$(sed -n 3p <<<"$_fields")"
stop_active="$(sed -n 4p <<<"$_fields")"
is_subagent="$(sed -n 5p <<<"$_fields")"
agent_type="$(sed -n 6p <<<"$_fields")"
[[ "$is_subagent" == "1" ]] || is_subagent=0
[[ -n "$agent_type" ]] || agent_type="-"

# 既定値。loop_count は数値を保証し、下の算術が落ちないようにする。
[[ -n "$agent" ]] || agent="claude"
[[ "$loop_count" =~ ^[0-9]+$ ]] || loop_count=0
[[ "$stop_active" == "1" ]] || stop_active=0

# Cursor の stop ペイロードには cwd が無く、この hook のプロセスの cwd は ~/.cursor でワークスペース
# ではない。$PWD に頼ると別のリポジトリと比べ、毎ターン黙って通していた。
cwd_known=1
if [[ "$cwd" == "-" || -z "$cwd" ]]; then
  cwd_known=0
  cwd="$PWD"
fi

# このエージェントの流儀で block を出し、終了する。
# $1 = メッセージ
# $2 = トレース用の、何が赤か。block() は複数の場所から呼ばれ、最初期のものはチェックに ID が付く
#      前に動くので、グローバルから読まず明示的に渡す。
# Cursor は止められず、stop hook は次のユーザーターンとして自動送信されるメッセージで答える。
# block() と最後の諦めの両方が使い、どちらも同じ流儀で Cursor の loop 予算を守る。
emit_cursor_followup() { # $1 = メッセージ, $2 = 何が赤か（トレース用）
  if [[ "$loop_count" -ge 3 ]]; then
    trace "$agent" "$cwd" "loop_count=$loop_count で注入をやめた（${2:-ゲート} が赤のまま）"
    printf '%s' '{}'
    exit 0
  fi
  trace "$agent" "$cwd" "フォローアップを注入した（${2:-ゲート} が赤。Cursor では止められない）"
  # followup_message は「ユーザーのメッセージとして」自動送信される。出どころを書かないと、
  # エージェントは人の入力と区別できず、hook の要求をユーザーの意図と取り違える。
  {
    echo "[dotagents] 検証ゲートからの自動メッセージ。これはユーザーが書いたものではなく、"
    echo "ユーザーが止めるよう頼んだのでもない。チェックが失敗しているため hook が止めた。"
    echo
    printf '%s\n' "$1"
  } | node -e '
    let s = ""; process.stdin.on("data", d => (s += d)).on("end", () => {
      process.stdout.write(JSON.stringify({ followup_message: s.trimEnd() }));
    });
  '
  exit 0
}

block() {
  local _what="${2:-ゲート}"
  if [[ "$agent" == "cursor" ]]; then
    # loop_limit より前に注入をやめ、予算をこちらが黙って使い切らないようにする。
    emit_cursor_followup "$1" "$_what"
  fi
  # Claude Code は block の後この hook を再度呼び、エージェントはターンを終えないとユーザーに
  # 届かない。止め続けると閉じ込めてしまい、「ユーザーに聞け」という指示が実行できない。
  # なので再入時は一度だけ、はっきり言って制御を返す。
  if [[ "$stop_active" == "1" ]]; then
    # 赤のターンが終わるかを決めるのは block ではなくここなので、トレースに残す。Claude Code の
    # ハーネスの「8 回連続 block で解放」には届かない。最初の再入で解放するので、1 サイクルの
    # block はちょうど 1 回になる。
    trace "$agent" "$cwd" "RELEASED: $_what が赤のまま、チェック失敗中に制御を返した"
    {
      printf '[dotagents] %s\n' "$1"
      echo
      echo "ユーザーに届けられるよう、このターンはゲートを開ける。上のチェックはまだ失敗している。"
      echo "番兵は掛かったまま。何が赤で、何が必要かをはっきり伝えること。"
      echo "これは hook の発言で、ユーザーの発言ではない。"
    } >&2
    exit 0
  fi
  trace "$agent" "$cwd" "BLOCKED ($_what)"
  printf '[dotagents] %s\n' "$1" >&2
  exit 2
}

# ゲートが何をしたかの機械向けの記録。`DOTAGENTS_GATE_REPORT` がパスを指す時だけ書く。hook の
# stdout・終了コード・dry でない経路は何も変わらない。
#
# 「all gating checks green」と「nothing blocking」を文面の照合でしか見分けられず、飛ばしたチェックが
# 通ったチェックに見えていたため。`ran` は、実際にコマンドを実行したゲートのチェックの数。
#
# 全体で `${var:-}` を使う。`pass()` は `profile` の代入より前に 4 か所から呼ばれ、このファイルは
# `set -u` で動く。
write_gate_report() {
  [[ -n "${DOTAGENTS_GATE_REPORT:-}" ]] || return 0
  node -e '
    const [out, profile, ran, skipped, changed] = process.argv.slice(1);
    // "<id>:<reason>" の組。ID にコロンが入っても残るよう、最後のコロンで分ける。
    const skips = skipped.split(" ").filter(Boolean).map((s) => {
      const i = s.lastIndexOf(":");
      return i < 0 ? { id: s, reason: "unknown" } : { id: s.slice(0, i), reason: s.slice(i + 1) };
    });
    require("fs").writeFileSync(out, JSON.stringify({
      profile: profile || null,
      changed_files: Number(changed),
      ran: Number(ran),
      checked: Number(ran) > 0,
      skipped: skips,
    }));
  ' "$DOTAGENTS_GATE_REPORT" "${profile:-}" "${gate_ran:-0}" "${gate_skipped:-}" \
    "$(printf '%s' "${changed_root:-}" | grep -c . || true)" 2>/dev/null || true
}

# ターンを終わらせる。
pass() {
  trace "$agent" "$cwd" "passed${1:+: $1}"
  if (( GATE_DRY )); then
    # 声に出して言う。「緑」と「検査するものが無かった」は別の答えで、作業が検証済みなのは前者だけ。
    write_gate_report
    printf 'gate: nothing blocking%s\n' "${1:+ -- $1}"
    exit 0
  fi
  [[ "$agent" == "cursor" ]] && printf '%s' '{}'
  exit 0
}

# 各番兵は所属するリポジトリのルートを持つ。位置ではなくそれで照合する。2 つ掛かっていると、
# active[0] は一方を検査して他方について報告してしまう。
#
# リンクされた worktree の toplevel はそれ自身のパスなので、完全一致だけだと掛かったリポジトリの
# worktree すべてが「他所で掛かっている」になる。共有の git ディレクトリで照合し直して worktree に
# ゲートを継がせる。掛かりすぎはうるさく `disarm` で直せるが、掛かり漏れは黙っている。
gate_repo_root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || echo "$cwd")"
gate_common="$(gate_common_dir "$cwd")"
slug_dir=""
for _sentinel in ${active[@]+"${active[@]}"}; do
  _armed="$(cat "$_sentinel" 2>/dev/null)"
  [[ -n "$_armed" ]] || continue
  if [[ "$_armed" == "$gate_repo_root" ]]; then
    slug_dir="$(dirname "$_sentinel")"
    break
  fi
  # 掛かったパスがまだ解決できる時だけ。リポジトリが移動していたら上の完全一致しか主張できない。
  # 他所のゲートを自分のものとすると、別のリポジトリについて報告してしまう。
  if [[ -n "$gate_common" && -d "$_armed" ]]; then
    _armed_common="$(gate_common_dir "$_armed")"
    if [[ -n "$_armed_common" && "$_armed_common" == "$gate_common" ]]; then
      slug_dir="$(dirname "$_sentinel")"
      break
    fi
  fi
done

# エージェントが作業ディレクトリを渡さず、何も一致しなかった。番兵が 1 つだけなら候補はそれしか
# ないので、それを採って推定したことを記録する。Cursor でゲートが働くのはこのため。
if [[ -z "$slug_dir" && "$cwd_known" == "0" && ${#active[@]} -eq 1 ]]; then
  slug_dir="$(dirname "${active[0]}")"
  gate_repo_root="$(cat "${active[0]}" 2>/dev/null)"
  cwd="$gate_repo_root"
  trace "$agent" "$cwd" "唯一掛かっている番兵からリポジトリを推定した"
fi

# 複数掛かっていて見分ける手掛かりが無い。推測すると一方を検査して他方について報告するので、
# 通過に見せずに起きたことを言う。
if [[ -z "$slug_dir" && "$cwd_known" == "0" && ${#active[@]} -gt 1 ]]; then
  block "検証ゲートは、このターンがどのリポジトリについてのものか判定できなかった。

このエージェントは作業ディレクトリを報告せず、${#active[@]} 個のリポジトリにゲートが掛かっている。
作業していないものを 'scripts/gate.sh disarm' で外し、答えを 1 つにすること。何も検査していない。
通過とみなさないこと。"
fi

# ---------------------------------------------------------------- アイドルの番兵を回収する
# 掃除役は上の glob で、どのリポジトリのターン終了でも既に走っているので費用は無い。ガードレールを
# 外すための launchd ジョブは、誰も見ていない時に動く「開く装置」になる。
#
# 期限切れが構造的に開く側へ倒れないための規則:
#
#   呼び出しが追い出してよいのは、これから強制する番兵「以外」だけ。
#
# だからゲート G を期限切れにできるのは G を守っていなかった呼び出しだけで、1 回の呼び出しが
# 期限切れにしてその結果で通すことはない。照合と Cursor の推定の後に置く。推定した唯一の番兵が
# 古くても、強制するのが閉じる側の答えで、下の heartbeat 更新がそれを保つ。
_ttl="$(gate_ttl_seconds)"
for _sentinel in ${active[@]+"${active[@]}"}; do
  _d="$(dirname "$_sentinel")"
  [[ -n "$slug_dir" && "$_d" == "$slug_dir" ]] && continue
  _idle="$(gate_idle_seconds "$_d")"
  if [[ -z "$_idle" ]]; then
    # heartbeat を持たない版が掛けたもの。無いことを無限のアイドルと読むと 1 分前に掛けたゲートを
    # 追い出すので、時計をここから動かす。移行は自動で、誰かが覚えて実行するコマンドは無い。
    gate_touch_heartbeat "$_d"
    continue
  fi
  if (( _idle > _ttl )); then
    _root="$(gate_expire "$_d" "$_idle")"
    trace "$agent" "$cwd" "expired ${_root:-$_d}（アイドル $(( _idle / 3600 ))h、ttl $(( _ttl / 3600 ))h）"
    gate_log_verdict "${_root:-$_d}" expired "アイドル $(( _idle / 3600 ))h、$gate_repo_root のターン終了時に回収"
  fi
done

# 自分のものは期限切れにせず更新する。更新前の自分の番兵もこれで埋まり、長い無人実行もゲートを保つ。
# アイドル時間は掛けた時点ではなく、ここで最後にターンが終わった時点から測る。
(( GATE_DRY )) || { [[ -n "$slug_dir" ]] && gate_touch_heartbeat "$slug_dir"; }

# 掛かっているが、このリポジトリのものではない。関係ない。ただし dry 実行はゲートが止めるかを問わない。
# 自分の作業の確認は、ゲートを掛ける前の実装中にするものなので、`gate.sh verify` は何も掛かって
# いなくても動く。
if [[ -z "$slug_dir" ]] && ! (( GATE_DRY )); then
  pass "他所で掛かっており、$gate_repo_root 向けではない"
fi

# ---------------------------------------------------------------- サブエージェントはターンではない
# Claude Code は登録された Stop hook をサブエージェントでは SubagentStop に変えるので、完了のたびに
# この hook が発火する。ゲートが決めるのは「ユーザーのターン」が終わってよいかで、ここで問うのは
# 筋違い。放置すると、レビューのサブエージェントがテストの赤で止まれず、試行回数も無駄に減る。
if [[ "$is_subagent" == "1" ]]; then
  pass "subagent が完了した（${agent_type}）。ゲートが掛かるのはターンで、subagent ではない"
fi


# このリポジトリに掛かっているので、ここから先の誤動作は通さず止める。docs/decisions.md 参照。
if [[ "$GATE_NODE_MISSING" == "1" ]]; then
  block "検証ゲートには node が要るが、PATH に見つからない。何も検査できない。

作業ではなくゲートの環境の不具合。エージェントの PATH を直すか、$slug_dir のゲートを外すこと。
通過とみなさないこと。"
fi
if [[ -z "$PROFILES" || ! -d "$PROFILES" ]]; then
  block "検証ゲートがプロファイルのディレクトリを見つけられない（探した場所: ${PROFILES:-<unset>}）。

dotagents のチェックアウトが移動したのかもしれない。scripts/setup.sh install を再実行するか、
$slug_dir のゲートを外すこと。通過とみなさないこと。"
fi
# カウンタはリポジトリではなく作業ツリーのもの。2 つの worktree は 2 つの作業で、回数を持ち越すと
# まだ 1 回目も試していないツリーで段階が上がってしまう。
state_dir="$slug_dir/wt/$(gate_worktree_key "$cwd")"
mkdir -p "$state_dir" 2>/dev/null || true
attempts_file="$state_dir/attempts.json"

# worktree 対応前の配置は記録を番兵の隣に置いていた。このツリーに委任ファイルが無ければそこから読む。
# 委任の結果を失うと人にもう一度頼むことになり、1 版前に自分で書いたファイルを読むより悪い。
delegated_file="$state_dir/delegated.json"
if [[ ! -e "$delegated_file" && -e "$slug_dir/delegated.json" ]]; then
  delegated_file="$slug_dir/delegated.json"
fi

# カウンタの隣に verdict があれば、この作業ツリーのゲートは既に諦めている。上限を設けた意味として
# もう止めないが、緑とは読ませないので、トレースの文面は全通過のものと意図して変える。リポジトリ
# ではなく作業ツリー単位。1 つの worktree の行き詰まりで並行する他の作業のゲートを開けないため。
verdict_file="$state_dir/VERDICT"
if [[ -f "$verdict_file" ]]; then
  pass "以前 $(sed -n 3p "$verdict_file" 2>/dev/null) を $(sed -n 4p "$verdict_file" 2>/dev/null) 回試して諦めている。作業は検証されていない"
fi

# ---------------------------------------------------------------- プロファイルを解決する

remote="$(git -C "$cwd" remote get-url origin 2>/dev/null || true)"
if [[ -z "$remote" ]]; then
  # リポジトリでないか origin が無い。コマンドを選ぶ根拠が無いので推測しない。
  pass "$cwd に git remote が無い"
fi

profile="$(node -e '
  const fs=require("fs"), path=require("path");
  const [dir, remote] = process.argv.slice(1);
  let hit = null, broken = [];
  let names = [];
  try { names = fs.readdirSync(dir); } catch { process.stdout.write("ERR:unreadable\n"); process.exit(0); }
  for (const f of names) {
    if (!f.endsWith(".json") || f.startsWith("_")) continue;
    // try/catch はファイルごと。ループ全体を囲むと、壊れたプロファイル 1 つが readdir 順で後ろの
    // プロファイルをすべて隠し、それらのリポジトリでゲートが黙って開く。
    try {
      const p = JSON.parse(fs.readFileSync(path.join(dir, f), "utf8"));
      // `remote` は部分文字列 1 つか、そのリスト（どれか 1 つが一致すればよい）。1 つだけだと
      // 所有者を 1 つしか書けず、ゲートの掛かったリポジトリのフォークが何にも一致せず黙って通る。
      // scripts/gate.sh 側のコピーと同一に保つ。食い違うと、向こうはプロファイルを報告し、
      // こちらは見つけられない。
      const pats = p?.match?.remote == null ? [] : [].concat(p.match.remote);
      if (pats.some((s) => typeof s === "string" && s !== "" && remote.includes(s))) {
        hit = path.join(dir, f); break;
      }
    } catch { broken.push(f); }
  }
  if (hit) process.stdout.write(hit + "\n");
  else if (broken.length) process.stdout.write("ERR:broken:" + broken.join(",") + "\n");
' "$PROFILES" "$remote" 2>/dev/null)"

case "$profile" in
  ERR:unreadable)
    block "検証ゲートが $PROFILES を読めず、何も検査できない。
作業ではなくゲートの不具合。通過とみなさないこと。" ;;
  ERR:broken:*)
    block "次のプロファイルが正しい JSON ではなく、どれかがこのリポジトリに当てはまるか判定できない: ${profile#ERR:broken:}

$PROFILES の JSON を直すか、$slug_dir のゲートを外すこと。通過とみなさないこと。" ;;
esac

# 一致するプロファイルが無ければ、このリポジトリの検証方法が分からない。推測で止めるのは止めないより
# 悪い。ユーザーがゲートを無視するようになる。
[[ -n "$profile" ]] || pass "$remote に一致するプロファイルが無い"

repo_root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || echo "$cwd")"
sub="$(node -e 'try{console.log(require(process.argv[1]).cwd||"")}catch{}' "$profile")"
run_dir="$repo_root${sub:+/$sub}"
[[ -d "$run_dir" ]] || run_dir="$repo_root"

# ---------------------------------------------------------------- ゲートのチェックを実行する

# ゲートであり、かつ実行を許されたチェックだけ。委任のものは下で扱う。
# macOS の bash 3.2 でも動くよう、mapfile ではなくファイルに書いて `while read` で読み戻す。
# テンプレートは完全な形で渡す。BSD mktemp は `-t x` を接頭辞として扱い、GNU coreutils は XXXXXX を
# 要求して他はエラーにする。
work="$(mktemp "${TMPDIR:-/tmp}/dotagents-gate.XXXXXX" 2>/dev/null)"
if [[ -z "$work" || ! -f "$work" ]]; then
  # ゲートが準備できなかった。自分の誤動作でターンを通してはならない。開く側に倒れる
  # ガードレールは無いより悪い（docs/decisions.md）。
  block "検証ゲートが作業用ファイルを作れず、何も検査できない。

作業ではなくゲート自体の不具合。続ける前に直すか、$slug_dir の番兵を外すこと。
通過とみなさないこと。"
fi
# 2 つ目の trap にせず同じハンドラで登録する。ここで素の `trap ... EXIT` を書くと上のクラッシュ
# ガードを置き換え、失ったことはゲートが落ちるまで見えない。
_gate_work="$work"

# 既定値で、計測値ではない。実際のテストに足りるだけ大きく、止まったチェックがターンを開けっ放しに
# できない程度に有限。
GATE_CHECK_TIMEOUT_DEFAULT=120
GATE_TOTAL_TIMEOUT_DEFAULT=300

# リポジトリが禁じたコマンドはゲートも実行しない。`cmd` をそのまま `eval` すると、`cdk deploy` を
# 禁じたリポジトリでもターン終了のたびにゲートがそれを実行してしまう。スキルに書いた規則は依頼で
# あって保証ではなく、ガードレールは hook に置く（docs/mechanisms.md）。
#
# 空白を含む語句が残るよう 1 行 1 つ。`read` は行全体を変数に渡す。
forbidden_list="$(node -e '
  try { for (const f of require(process.argv[1]).forbidden || []) if (String(f).trim()) console.log(f) }
  catch {}
' "$profile" 2>/dev/null)"

# コマンドに含まれる最初の禁止語句。無ければ何も出さない。
forbidden_hit() { # <command>
  local phrase
  while IFS= read -r phrase; do
    [[ -n "$phrase" ]] || continue
    [[ "$1" == *"$phrase"* ]] && { printf '%s' "$phrase"; return 0; }
  done <<<"$forbidden_list"
  return 1
}

budget_total="$(node -e '
  try { const v = require(process.argv[1]).timeout_total;
        console.log(Number.isInteger(v) && v > 0 ? v : "") } catch {}
' "$profile" 2>/dev/null)"
case "$budget_total" in ''|*[!0-9]*|0) budget_total=$GATE_TOTAL_TIMEOUT_DEFAULT ;; esac

# ID・タイムアウト・mutates を先に、コマンドを最後に。タブを含みうるのはコマンドだけで、`read` は
# 行の残りを最後の変数に渡す。
node -e '
  const p = require(process.argv[1]);
  const dflt = Number(process.argv[2]);
  for (const c of p.checks || [])
    if (c.gate && c.agent_may_run) {
      const t = Number.isInteger(c.timeout) && c.timeout > 0 ? c.timeout : dflt;
      // シェルで回せるよう `paths` は空白で連結する。ここに載せないフィールドは下のループから見えない。
      //
      // 無い時は空文字ではなく "-"。タブは空白文字なので `IFS=$\t read` は連続するタブを潰し、
      // 途中の空フィールドで後ろの列がすべてずれ、コマンドが `pathspec` に入る。
      const paths = Array.isArray(c.paths) && c.paths.length ? c.paths.join(" ") : "-";
      console.log([c.id, t, c.mutates ? "1" : "0", paths, c.cmd].join("\t"));
    }
' "$profile" "$GATE_CHECK_TIMEOUT_DEFAULT" > "$work"

# 作業ツリーの様子を安く取る。`mutates` を宣言したチェックをこれで確かめる。
tree_fingerprint() {
  git -C "$repo_root" -c core.quotePath=false status --porcelain 2>/dev/null
}

# macOS には `timeout` も `gtimeout` も無いので、時計はここで作る。gate_now() ではなく実時間を使う。
# 測るのはコマンドが実際にかかった時間で、環境が動かせる時計だと予算を破る手段になる。
run_check() { # <seconds> <command>  -> check_out と check_code を設定する。殺した時は $work.timeout を作る
  local secs="$1" c="$2"
  rm -f "$work.timeout" "$work.out"

  # node の spawn で独自のプロセスグループとして実行し、タイムアウト時に木全体を殺す。
  # `eval` を動かす bash だけを殺すと、バックグラウンドの子（`pnpm test` が起こした node、dev
  # サーバー、コンテナ）が残ってポートと CPU を持ち続ける。
  #
  # コマンドは `eval` と同じく `bash -c` にそのまま渡り、`{files}` は置換前にファイル名ごとに
  # シェルクォートする。クォートの境界は変えておらず、変わったのは殺すプロセスだけ。
  #
  # ゲート自身の制御変数は子の環境から除く。チェックはリポジトリのコードでありゲートの内部ではない。
  # 残すと `gate.sh verify` の DOTAGENTS_GATE_DRY=1 がこのリポジトリのゲートのテストに漏れ、
  # テスト内の hook 呼び出しがすべて dry で動いて失敗する。
  node -e '
    const { spawn } = require("node:child_process");
    const fs = require("node:fs");
    const [cwd, cmd, secsRaw, outPath, markPath] = process.argv.slice(1);
    const out = fs.openSync(outPath, "w");
    const env = { ...process.env };
    for (const k of ["DOTAGENTS_GATE_DRY", "DOTAGENTS_GATE_NOW",
                     "DOTAGENTS_GATE_TTL_HOURS", "DOTAGENTS_GATE_MAX_ATTEMPTS"]) delete env[k];

    const child = spawn("bash", ["-c", cmd], { cwd, env, stdio: ["ignore", out, out], detached: true });
    let timedOut = false;
    let hardKill;

    const timer = setTimeout(() => {
      timedOut = true;
      // 殺す前に書く。でないと殺された子の非 0 がチェック自身の失敗と区別できず、「ゲートの時間
      // 切れ」が「チェックが壊れている」と報告される。
      try { fs.writeFileSync(markPath, "") } catch {}
      try { process.kill(-child.pid, "SIGTERM") } catch {}
      hardKill = setTimeout(() => { try { process.kill(-child.pid, "SIGKILL") } catch {} }, 2000);
    }, Number(secsRaw) * 1000);

    child.on("error", () => { clearTimeout(timer); process.exit(127) });
    child.on("exit", (code) => {
      clearTimeout(timer);
      if (hardKill) clearTimeout(hardKill);
      try { fs.closeSync(out) } catch {}
      process.exit(timedOut ? 124 : (code === null ? 128 : code));
    });
  ' "$run_dir" "$c" "$secs" "$work.out" "$work.timeout"
  check_code=$?

  check_out="$(cat "$work.out" 2>/dev/null)"
  rm -f "$work.out"
}

failed_id=""
failed_cmd=""
failed_out=""
failed_code=0
# どの所見か、つまりどの verdict になるか。「人が確認していない」は「コードが壊れている」ではなく、
# 混ぜた記録は後で読んでも役に立たない。
failed_kind="red"

# 何回連続で失敗したらゲートが止めるのをやめるか。2 ではない。2 でメッセージの段階が上がるので、
# 終点はそれより後でないと段階を上げた効果が出る前に終わる。テストがプロファイルを編集せずに
# 縮められるよう、環境変数を優先する。
max_attempts="${DOTAGENTS_GATE_MAX_ATTEMPTS:-}"
if [[ -z "$max_attempts" ]]; then
  max_attempts="$(node -e '
    try { const v = require(process.argv[1]).max_attempts;
          console.log(Number.isInteger(v) && v > 0 ? v : "") } catch {}
  ' "$profile" 2>/dev/null)"
fi
case "$max_attempts" in ''|*[!0-9]*|0) max_attempts=3 ;; esac

gate_started="$(date +%s)"
unrun=""
# write_gate_report 用に、ゲートが何をしたか。`gate_ran` はコマンドを実際に実行したチェックの数、
# `gate_skipped` は実行しなかったチェックの "<id>:<reason>"。記録されない skip をなくすための組。
gate_ran=0
gate_skipped=""

# 変更集合。ルート相対で 1 回だけ求める。使うのは {files} の置換と `paths` の判定の 2 か所で、
# git を 2 回呼ぶと間にツリーが動いた時に答えが 2 つになる。
#
# 基点は DOTAGENTS_GATE_DIFF_BASE があればそれ、無ければ HEAD。`scripts/loop.sh` はランディングの間
# merge-base に固定する。途中で commit するので、HEAD 相対だと検証すべき作業そのものが隠れるため。
gate_diff_base="${DOTAGENTS_GATE_DIFF_BASE:-HEAD}"
git -C "$repo_root" rev-parse --verify --quiet "$gate_diff_base" >/dev/null 2>&1 || gate_diff_base=HEAD
changed_root=""
while IFS= read -r -d '' _f; do
  [[ -n "$_f" ]] || continue
  changed_root="$changed_root$_f"$'\n'
done < <(
  git -C "$repo_root" -c core.quotePath=false diff -z --name-only --diff-filter=d "$gate_diff_base" 2>/dev/null
  git -C "$repo_root" -c core.quotePath=false ls-files -z --others --exclude-standard 2>/dev/null
)

# 変更されたパスのどれかが、チェックの宣言した接頭辞や glob に一致するか。どちらもルート相対。
# 末尾が `/**` のもの（よくある形）は接頭辞として扱い、他は bash のパターン照合に任せるので
# `docs/*.md` も素の `CLAUDE.md` も効く。
gate_paths_match() { # <改行区切りの変更パス> <空白区切りのパターン> -> 一致したものを出力する
  local paths="$1" pats="$2" f pat
  # `for pat in $pats` ではなく `read -a`。クォートしない単語分割はパス名展開もするので、
  # `docs/**` が docs/ の下の実在ファイルに置き換わり、パターンでなくなる。`read` は glob しない。
  local -a patarr
  IFS=' ' read -r -a patarr <<<"$pats"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    for pat in "${patarr[@]}"; do
      case "$pat" in
        */\*\*) [[ "$f" == "${pat%/\*\*}"/* ]] && { printf '%s\n' "$f"; break ;} ;;
        *)        [[ "$f" == $pat ]]              && { printf '%s\n' "$f"; break ;} ;;
      esac
    done
  done <<<"$paths"
}

# `cmd` は最後に置く。タブを含みうるのはこれだけで、read の最後の変数が残りを吸うので、コマンド中の
# タブが前の列をずらさない。
while IFS=$'\t' read -r id secs mutates pathspec cmd; do
  [[ -n "$id" ]] || continue
  case "$secs" in ''|*[!0-9]*|0) secs=$GATE_CHECK_TIMEOUT_DEFAULT ;; esac

  # このチェックは変更のどれかを受け持つか。`paths` はリポジトリルート相対。`paths` の無いチェックは
  # すべてを受け持つ。
  applicable="$changed_root"
  [[ "$pathspec" == "-" ]] && pathspec=""
  if [[ -n "$pathspec" ]]; then
    applicable="$(gate_paths_match "$changed_root" "$pathspec")"
    if [[ -z "$applicable" ]]; then
      gate_skipped="${gate_skipped:+$gate_skipped }$id:paths"
      continue
    fi
  fi

  # {files} は範囲の絞り込み。何も変わっていなければ検査するものは無い。
  if [[ "$cmd" == *"{files}"* ]]; then
    # 空白や非 ASCII を含むパスが残るよう NUL 区切り・quotePath オフで取る。結果は eval に渡るので
    # 置換前に名前ごとにシェルクォートする。しないと `a;touch pwned;b.ts` という名前のファイルが
    # 実行され、作業ツリーに書ける者なら誰でもその名前を選べる。
    #
    # 未追跡ファイルも含める。新しいファイルを足すだけのターンでリストが空になりチェックを丸ごと
    # 飛ばしていた。新しいファイルこそ検査が要る。
    #
    # パスは $run_dir 基準にする。コマンドは repo_root/<profile.cwd> で動くので、ルート相対だと
    # "cwd": "v2" の `vitest run {files}` に `v2/src/foo.ts` が渡り、開けない。上のルート相対の
    # 集合から導き、`<cwd>/` 接頭辞を外すことと、そのサブツリー外を落とすことの両方をここでする。
    # scripts/test-verify-gate.sh の `cwd: pkg` のケースがそれを確かめる。
    #
    # 絞り込みは `paths` との共通部分。paths: ["docs/**"] のチェックに src/a.ts を渡してはならない。
    files=""
    while IFS= read -r _f; do
      [[ -n "$_f" ]] || continue
      if [[ -n "$sub" ]]; then
        [[ "$_f" == "$sub"/* ]] || continue
        _f="${_f#"$sub"/}"
      fi
      files="$files $(printf '%q' "$_f")"
    done <<<"$applicable"
    # 黙らず記録する。記録しないと、ゲートのチェックがすべて {files} 付きのプロファイルが、きれいな
    # ツリーで本当の通過と同じ文面を出す。きれいなツリーでは検査するものが無いので、非ブロックで
    # exit 0 のまま。変わるのは、そう言うようになったこと。
    if [[ -z "${files// /}" ]]; then
      gate_skipped="${gate_skipped:+$gate_skipped }$id:no_files"
      continue
    fi
    cmd="${cmd//\{files\}/${files# }}"
  fi

  # 全体の予算が尽きたら新しいものは始めない。ハーネス自身の hook タイムアウトを超えるのは、ゲートが
  # 観測できない唯一の失敗。0 でも 2 でもなく非ブロックで終わり、ターンがきれいに見えて終わる。
  # 始める前に確かめ、既に始めたチェックを短くするのには使わない。残りに合わせて切ると、そのチェックと
  # 無関係な理由でタイムアウトと報告することになる。代わりに合計は最大でチェック 1 つ分のタイムアウト
  # だけ超えうる。templates/ の hook 設定が両方を見込んでいるのはこのため。
  if (( budget_total - ( $(date +%s) - gate_started ) <= 0 )); then
    unrun="${unrun:+$unrun }$id"
    gate_skipped="${gate_skipped:+$gate_skipped }$id:budget"
    continue
  fi

  # {files} の置換後に確かめる。比べるのは実際に実行されるコマンド。
  _forbidden="$(forbidden_hit "$cmd" || true)"
  if [[ -n "$_forbidden" ]]; then
    { printf '%s\n%s\n%s\n' "$id" "$cmd" "forbidden"
      printf '%s' "このリポジトリが禁じている。プロファイルの 'forbidden' に \"$_forbidden\" があり、
'$id' チェックはその語句を含むコマンドを実行するところだった。

ゲートは実行していない。このチェックは何も検査していないので、この block を失敗したテストと
読まないこと。プロファイルが自己矛盾しているか、禁じられたことをしないコマンドがこのチェックに要る。"
    } > "$work.fail"
    break
  fi

  before=""
  [[ "$mutates" == "1" ]] && before="$(tree_fingerprint)"

  run_check "$secs" "$cmd"
  gate_ran=$((gate_ran + 1))
  out="$check_out"
  code="$check_code"

  # `mutates` を宣言したチェックは自動修正で、実際のプロファイルはよく 2 つ（`lint:fix`、`format:fix`）
  # をゲートにする。成功だけでは緑と言えない。エージェントが終わったと判断した後に hook がツリーを
  # 書き換えており、ループなら次の回が自分の書いていないファイルを読む。なので変更を示して 1 回だけ
  # 止める。何も戻さない（修正は欲しいが、黙るのは困る）。次のターンは直すものが無く通る。
  if [[ "$mutates" == "1" && $code -eq 0 && "$(tree_fingerprint)" != "$before" ]]; then
    { printf '%s\n%s\n%s\n' "$id" "$cmd" "mutated"
      printf '%s' "'$id' チェックが実行中に作業ツリーを変更した。

成功しているので壊れてはいない。ただし、終えようとしていたファイルは自分が書いたファイルではない。
加えられた変更を確認してから、もう一度ターンを終えること。直すものが残っていなければ、この
チェックは通り、ゲートは退く。

現在の作業ツリー:
$(tree_fingerprint)

このチェック自身の出力:
$out"
    } > "$work.fail"
    break
  fi

  if [[ -f "$work.timeout" ]]; then
    { printf '%s\n%s\n%s\n' "$id" "$cmd" "timeout"; printf '%s' "$out"; } > "$work.fail"
    break
  fi
  if [[ $code -ne 0 ]]; then
    # 注意: このループはパイプではなく `done < "$work"` のファイルリダイレクトで回しているので、本体は
    # このシェルで動き、`block` の exit でスクリプトが終わる。`node ... | while ...` に変えると本体が
    # サブシェルになり、`block` はそれだけを終えて下の全通過の `pass` へ落ちる。黙って開く。
    { printf '%s\n%s\n%s\n' "$id" "$cmd" "$code"; printf '%s' "$out"; } > "$work.fail"
    break
  fi
done < "$work"

if [[ -f "$work.fail" ]]; then
  failed_id="$(sed -n 1p "$work.fail")"
  failed_cmd="$(sed -n 2p "$work.fail")"
  failed_code="$(sed -n 3p "$work.fail")"
  failed_out="$(tail -n +4 "$work.fail")"
  if [[ -f "$work.timeout" ]]; then
    # タイムアウトはコードについての所見ではなくゲートの誤動作。後日 verdict を読んだ時に、終わって
    # いないチェックを失敗と言わないよう、独自の理由で記録する。
    failed_kind="timeout"
    failed_out="ゲートがこのチェックを止めた。${secs}s でタイムアウトした。
コードが正しいかについては何も言っていない。ゲートが予算内に検査を終えられなかったことだけを示す。
プロファイルでこのチェックの 'timeout' を上げるか、チェックを速くすること。

止める前に取れた出力:
$failed_out"
  fi
fi

# 予算が届かなかったチェック。通過ではない。実行していないものを緑と報告することを、この節は防ぐ。
if [[ -z "$failed_id" && -n "$unrun" ]]; then
  failed_id="gate-budget"
  failed_kind="timeout"
  failed_cmd="（ゲートが全体の予算を使い切った）"
  failed_code="-"
  failed_out="次のゲートのチェックは実行していない: $unrun

ゲートがターン終了ごとに使うのは最大 ${budget_total}s（timeout_total）。エージェント自身の hook
タイムアウトで殺されると非ブロックで終わり、このターンが緑に見えたまま終わるので、その前に
チェックを始めるのをやめた。

プロファイルの 'timeout_total' を上げるか、scope: changed でチェックを絞るか、遅いものを
ゲートから外すこと。"
fi

# ファイルが変わったのに、ゲートのチェックが 1 つも受け持たなかった。`paths` を安全にするのはこの block。
#
# これが無いと `paths` は新しい穴を作る。{files} が空で飛ばすのはきれいなツリーでだけ起き、
# scripts/loop.sh の `round_changed_nothing` が拾う。`paths` では、ツリーが変わり、回が実際に作業し、
# 判定できたはずのチェックがすべて辞退する。`round_changed_nothing` は発火せず、ゲートは緑と言ってしまう。
#
#   変更集合が空   -> 通す。Stop hook はコードを読むだけのターンでも毎回発火し、それを止めると
#                     ゲートが外される。
#   変更ありで 0 件 -> ここで止める。
if [[ -z "$failed_id" && "$gate_ran" == "0" && -n "${changed_root//$'\n'/}" ]]; then
  failed_id="gate-nothing-ran"
  failed_kind="not_checked"
  failed_cmd="（変更されたファイルを受け持つゲートのチェックが無い）"
  failed_code="-"
  failed_out="宣言した paths が変わっていないため飛ばした: ${gate_skipped:-（なし）}

変更されたファイル: $(printf '%s' "$changed_root" | tr '\n' ' ')

何も検査していない。これは通過ではない。実行しなかったチェックは、変更されたコードについて何も
言わない。チェックに path が足りないか、path にチェックが足りない。

この block を消さず、プロファイルを直すこと。「ゲートを速くした」と「ゲートを黙らせた」を
分けているのはこの block だけ。"
fi

# ---------------------------------------------------------------- 委任したチェック

# エージェントが実行できないチェックも、行われなければならない。ユーザーが実行した証拠を、スキルが
# 記録したものとして求める。でないと「ユーザーに typecheck を頼んだ」が結果を見ずに終える手段になる。
if [[ -z "$failed_id" ]]; then
  node -e '
    const p = require(process.argv[1]);
    for (const c of p.checks || [])
      if (c.gate && !c.agent_may_run) {
        const paths = Array.isArray(c.paths) && c.paths.length ? c.paths.join(" ") : "-";
        console.log([c.id, paths, c.delegate_reason || ""].join("\t"));
      }
  ' "$profile" > "$work"

  # その場で止めず記録する。ここで止めると試行回数を通らず、実行できる人がいない委任チェックは
  # 毎ターン永遠に止め、どのカウンタも動かさない出口の無い壁になる。今は他と同じ予算を通る。
  while IFS=$'\t' read -r id pathspec reason; do
    [[ -n "$id" ]] || continue
    # 委任チェックも `paths` に従う。ドキュメントだけの変更で、影響しえない typecheck の証拠を人に
    # 求めてはならない。skip として記録し `ran` には数えない。委任チェックは何も実行していないので、
    # 数えると全部委任のプロファイルが検査済みに見える。`-` は「無し」の印（理由は出力側を参照）。
    [[ "$pathspec" == "-" ]] && pathspec=""
    if [[ -n "$pathspec" ]] && [[ -z "$(gate_paths_match "$changed_root" "$pathspec")" ]]; then
      gate_skipped="${gate_skipped:+$gate_skipped }$id:delegated_paths"
      continue
    fi
    if ! grep -qs "\"$id\"" "$delegated_file" 2>/dev/null; then
      failed_id="$id"
      failed_kind="needs_human"
      failed_cmd="（委任。エージェントは実行できない）"
      failed_code="-"
      failed_out="$reason"
      break
    fi
  done < "$work"
fi

# ---------------------------------------------------------------- dry 実行: 報告だけして何も変えない
# ここから下は状態を書く（試行回数、verdict、pass / block の流儀）。dry 実行はここまでで答えが
# 出ているので、ここで終える。
if (( GATE_DRY )); then
  write_gate_report
  if [[ -z "$failed_id" ]]; then
    printf 'gate: all gating checks green (%s)\n' "$gate_repo_root"
    exit 0
  fi
  {
    printf 'gate: %s\n' "$failed_id"
    printf '  kind    : %s\n' "$failed_kind"
    printf '  command : %s\n' "$failed_cmd"
    printf '  cwd     : %s\n' "$run_dir"
    printf '  exit    : %s\n' "$failed_code"
    echo
    echo "出力:"
    tail -20 <<<"$failed_out" | sed 's/^/  /'
  } >&2
  exit 1
fi

# ---------------------------------------------------------------- すべて通過

if [[ -z "$failed_id" ]]; then
  node -e 'require("fs").writeFileSync(process.argv[1],"{}\n")' "$attempts_file" 2>/dev/null || true
  pass "ゲートのチェックはすべて緑"
fi

# ---------------------------------------------------------------- 止める

# 一時ファイルに書いて rename する。同時に 2 つ書くと attempts.json が途中で切れ、下の catch の中の
# JSON.parse がそれを {} に変えて回数を黙ってリセットし、上限に届かなくなる。パースエラーに化けた開く側の失敗。
attempts="$(node -e '
  const fs=require("fs"); const [f,id]=process.argv.slice(1);
  let a={}; try{a=JSON.parse(fs.readFileSync(f,"utf8"))}catch{}
  a[id]=(a[id]||0)+1;
  const tmp = f + ".tmp." + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(a,null,2)+"\n");
  fs.renameSync(tmp, f);
  console.log(a[id]);
' "$attempts_file" "$failed_id" 2>/dev/null || echo 1)"
case "$attempts" in ''|*[!0-9]*) attempts=1 ;; esac

failed_detail="$(
  echo "  command : $failed_cmd"
  echo "  cwd     : $run_dir"
  echo "  exit    : $failed_code"
  echo
  echo "出力の末尾 20 行:"
  tail -20 <<<"$failed_out" | sed 's/^/  /'
)"

# 下の順序そのものが修正で、上限だけではない。再入時の解放はすべてを飛ばすので、終点の判断はその
# 前に置く。でないと、verdict を書くべきターンに書かれない。
if (( attempts >= max_attempts )); then
  gate_write_verdict "$state_dir" "$failed_kind" "$failed_id" "$attempts" "$failed_code" \
    "$agent" "$failed_cmd" "$failed_out"
  gate_log_verdict "$gate_repo_root" "$failed_kind" "$failed_id を $attempts 回試して諦めた"
  trace "$agent" "$cwd" "GAVE UP: $failed_id を $attempts 回試して諦めた ($failed_kind)"

  terminal_msg="$(
    printf 'ゲートは %s チェックを %s 回試して諦めた。\n' "$failed_id" "$attempts"
    echo
    echo "$failed_detail"
    echo
    echo "このゲートはこれから開き、このチェックではもう止めない。"
    echo "作業は検証されていない。完了と説明しない、通過として commit しない、緑と称して PR を"
    echo "出さないこと。何がまだ赤で、何を直せなかったかをはっきり伝えること。"
    echo
    echo "$state_dir/VERDICT に記録した。ゲートを掛け直すと試行回数はやり直しになる。"
  )"

  # 意図して block() を通さない。block() は再入時に解放するが、このメッセージは飲み込まれてはならない。
  # Claude Code では、閾値を越えた呼び出しでも exit 2 で終える。stderr をモデルに届けるのは exit 2 で、
  # 非ブロックの終了では確実に届かない。ここで解放すると、エージェントはゲートが諦めたと知らずに止まる。
  # 止めるターンが 1 回増えるのは安く、失敗がトランスクリプトに残る。
  if [[ "$agent" == "cursor" ]]; then
    emit_cursor_followup "$terminal_msg" "$failed_id (諦めた)"
  fi
  {
    printf '[dotagents] %s\n' "$terminal_msg"
    echo
    echo "これは hook の発言で、ユーザーの発言ではない。"
  } >&2
  exit 2
fi

block "$(
  if (( attempts >= 2 )); then
    # 修正を繰り返すと、失敗したやり方がコンテキストに積もり、試すたびに悪くなる。
    echo "'$failed_id' チェックが $attempts 回連続で失敗した（試行 ${attempts} / ${max_attempts}）。"
    echo
    echo "継ぎはぎをやめること。試すたびに失敗したやり方がこのコンテキストに積もり、次が成功しにくく"
    echo "なる。試したことと失敗した理由を書き出し、/clear してから、その知見をプロンプトに織り込んで"
    echo "やり直すこと。"
  else
    echo "終われない: '$failed_id' チェックが失敗している（試行 ${attempts} / ${max_attempts}）。"
  fi
  echo
  echo "$max_attempts 回に達するとこのゲートは止めるのをやめ、諦めたことを記録する。ひとりでに緑に"
  echo "なることはない。"
  echo
  echo "$failed_detail"
)" "$failed_id"
