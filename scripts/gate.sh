#!/usr/bin/env bash
# 検証ゲートを掛ける・外す。
#
#   gate.sh arm [dir]            このリポジトリのセッションを、チェックが通るまで止める
#   gate.sh disarm [dir]         止めるのをやめる
#   gate.sh record <check> [dir] 委任したチェックをユーザーが実行したと記録する
#   gate.sh status [dir]         掛かっているか、アイドル時間、記録済みの内容
#   gate.sh status --json [dir]  同じ内容を、人ではなくドライバー向けに出す
#   gate.sh verify [--json] [dir] ターンを終えずに、このリポジトリのゲートのチェックをいま実行する
#   gate.sh gc                   終わったセッションが掛けたまま残したゲートを回収する
#
# ゲートの hook は掛けられていなければ何もしない。呼ぶのはスキルだけでよい。
#
# 番兵ファイルには所属するリポジトリのルートを書き、hook はディレクトリ名ではなくその中身で照合する。
# 双方が同じ規則で slug を導く設計だと、2 つの実装が永遠に一致し続ける必要があり、ずれると
# 委任の記録が掛けたのとは別のディレクトリへ黙って書かれる。中身で照合すれば名前に誰も依存しない。
#
# リポジトリに掛けると、リンクされた worktree にも掛かる（`using-git-worktrees` が推奨する並行作業の
# 場所でゲートが外れないように）。カウンタは wt/<key> で worktree ごとに持つ。ゲートを継いでも
# 試行回数は他の作業と共有しない。

set -uo pipefail

GATE_DIR="${DOTAGENTS_GATE_DIR:-$HOME/.claude/.dotagents-gate}"

die() { printf 'gate: %s\n' "$1" >&2; exit 1; }

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

# リポジトリの絶対ルート。リポジトリでなければそのディレクトリ自身。
repo_root() {
  local d="${1:-$PWD}"
  [[ -d "$d" ]] || die "ディレクトリではない: $d"
  git -C "$d" rev-parse --show-toplevel 2>/dev/null || (cd "$d" && pwd)
}

# 人が ~/.claude/.dotagents-gate を読むための名前。どこでもパースしない。
# ブランチ名は入れない。worktree がゲートを継ぐので、`repo-main` が別ブランチの worktree の
# ゲートを持つと、ラベルが嘘をつく。
slug_for() {
  printf '%s' "$(basename "$1")" | tr -cs 'A-Za-z0-9._-' '-' | cut -c1-80
}

# 作業ツリー自身のカウンタの置き場。番兵の 1 段下なので、複数の worktree が継いだゲートでも
# 試行回数はツリーごとに 1 組になる。
state_dir_for() { # <armed-dir> <dir>
  printf '%s/wt/%s' "$1" "$(gate_worktree_key "$2")"
}

# このリポジトリの指定マーカーを持つディレクトリ。中に書かれたルートで探し、見つからなければ
# 共有の git ディレクトリで探す（worktree がメインのチェックアウトのゲートを見つけられるように）。
#
# ACTIVE は「掛かっているか」、ROOT は「誰のものだったか」に答え、ROOT は回収後も残る。
# `status` が期限切れのゲートと一度も掛けなかったセッションを見分けられるのはこのため。
find_marked() { # <marker-filename> <root>
  local marker="$1" root="$2" f armed common armed_common
  common="$(gate_common_dir "$root")"
  shopt -s nullglob
  for f in "$GATE_DIR"/*/"$marker"; do
    armed="$(cat "$f" 2>/dev/null)"
    [[ -n "$armed" ]] || continue
    [[ "$armed" == "$root" ]] && { dirname "$f"; return 0; }
    # 記録されたパスがまだ解決できる時だけ。リポジトリが移動していたら、上の文字列一致しか主張できない。
    if [[ -n "$common" && -d "$armed" ]]; then
      armed_common="$(gate_common_dir "$armed")"
      [[ -n "$armed_common" && "$armed_common" == "$common" ]] && { dirname "$f"; return 0; }
    fi
  done
  return 1
}

find_armed() { find_marked ACTIVE "$1"; }
find_ended() { find_marked ROOT   "$1"; }

# ゲートのアイドル時間を、人向けに時間単位で。
idle_hours() { # <armed-dir>
  local s; s="$(gate_idle_seconds "$1")"
  [[ -n "$s" ]] || { printf 'unknown'; return; }
  printf '%sh' $(( s / 3600 ))
}

# このリポジトリのプロファイルはあるか。無いまま掛けると、「armed」と答えたうえで毎ターン黙って
# 通すゲートになる。守られていると思い込む状態で、docs/decisions.md が防ぎたいもの。
warn_if_no_profile() {
  local root="$1" remote profiles hit
  remote="$(git -C "$root" remote get-url origin 2>/dev/null || true)"
  profiles="$(node -e '
    try { console.log(require(process.env.HOME + "/.claude/.dotagents-managed.json").repo + "/profiles") } catch {}
  ' 2>/dev/null)"
  [[ -n "$profiles" && -d "$profiles" ]] || profiles="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/profiles"

  if [[ -z "$remote" ]]; then
    echo "  warning: git remote が無く、プロファイルを照合できない。ゲートは黙って通す。"
    return
  fi
  hit="$(node -e '
    const fs = require("fs"), path = require("path");
    const [dir, remote] = process.argv.slice(1);
    try {
      for (const f of fs.readdirSync(dir)) {
        if (!f.endsWith(".json") || f.startsWith("_")) continue;
        try {
          const p = JSON.parse(fs.readFileSync(path.join(dir, f), "utf8"));
          // 文字列か文字列のリストで、どれか 1 つが一致すればよい。
          // hooks/dotagents-verify-gate.sh 側のコピーと同一に保つ。
          const pats = p?.match?.remote == null ? [] : [].concat(p.match.remote);
          if (pats.some((s) => typeof s === "string" && s !== "" && remote.includes(s))) { console.log(f); break; }
        } catch {}
      }
    } catch {}
  ' "$profiles" "$remote" 2>/dev/null)"

  if [[ -n "$hit" ]]; then
    echo "  profile: $hit"
  else
    echo
    echo "  WARNING: $remote に一致するプロファイルが無い"
    echo "  ゲートは掛かったが実行するコマンドが無く、毎ターン黙って通す。"
    echo "  頼る前に $profiles/<name>.json を書くこと。/da-verify が手順を案内する。"
  fi
}

# 前の誰かが残した verdict を示し、ゲートがまた止められるよう脇へ退ける。あれば 0 を返し、
# 呼び出し側はそれを合図に試行回数をリセットする。
report_prior_verdict() { # <dir holding VERDICT>
  local d="$1"
  [[ -f "$d/VERDICT" ]] || return 1
  mv -f "$d/VERDICT" "$d/VERDICT.prev" 2>/dev/null || return 1
  echo
  echo "  NOTE: ここのゲートは解除ではなく verdict で終わっている:"
  printf '    reason  %s\n' "$(sed -n 2p "$d/VERDICT.prev" 2>/dev/null)"
  printf '    check   %s\n' "$(sed -n 3p "$d/VERDICT.prev" 2>/dev/null)"
  printf '    at      %s（%s 回試行後）\n' \
    "$(sed -n 1p "$d/VERDICT.prev" 2>/dev/null)" "$(sed -n 4p "$d/VERDICT.prev" 2>/dev/null)"
  echo "  その作業は検証されていない。完了扱いにする前に $d/VERDICT.prev を読むこと。"
  echo "  試行回数はここからやり直し。"
  return 0
}

cmd_arm() {
  local root; root="$(repo_root "${1:-}")"
  local dir state
  if dir="$(find_armed "$root")"; then
    # 掛かっている（いま居る worktree のメインのチェックアウトが掛けた場合も含む）。何もリセット
    # しないが、この作業ツリーのカウンタの置き場は用意する。
    state="$(state_dir_for "$dir" "$root")"
    mkdir -p "$state" 2>/dev/null || true
    gate_trace "gate.sh" "$root" "arm を要求されたが既に掛かっている"
    echo "already armed: $dir"
    # 再度の arm は、新しいセッションが /da-verify 経由で必ず通る唯一の経路。前のセッションの
    # verdict はここで示し、試行回数もここでやり直す。でないと諦めたゲートは何度掛け直しても止めない。
    report_prior_verdict "$state" && printf '{}\n' > "$state/attempts.json"
    warn_if_no_profile "$root"
    return 0
  fi
  # slug はただのラベルなので、basename が同じ 2 つのリポジトリが同じディレクトリを欲しがりうる。
  # 番兵のあるディレクトリへ書くと、他のリポジトリのゲートを乗っ取る。
  local base n=0
  base="$GATE_DIR/$(slug_for "$root")"
  dir="$base"
  # 自分の期限切れディレクトリは再利用する（下で前の verdict を示すため）。掛かっているもの、
  # ROOT が別リポジトリを指すものは使わない。
  while [[ -e "$dir/ACTIVE" ]] \
     || { [[ -e "$dir/ROOT" ]] && [[ "$(cat "$dir/ROOT" 2>/dev/null)" != "$root" ]]; }; do
    n=$((n+1))
    dir="$base-$n"
  done
  mkdir -p "$dir" || die "$dir を作れなかった"
  printf '%s' "$root" > "$dir/ACTIVE" || die "番兵を書き込めなかった"
  # ROOT は同じ中身で、消さない。`status` と `gc` が、掛かっていないゲートについて素の
  # 「not armed」以上のことを答えられるのはこれがあるから。
  printf '%s' "$root" > "$dir/ROOT"
  gate_now > "$dir/ARMED_AT"
  gate_touch_heartbeat "$dir"
  state="$(state_dir_for "$dir" "$root")"
  mkdir -p "$state" || die "$state を作れなかった"
  printf '{}\n' > "$state/attempts.json"
  : > "$state/delegated.json"
  gate_trace "gate.sh" "$root" "armed"
  echo "armed: $dir"
  echo "  $(basename "$root") のゲートのチェックが失敗している間、ターンは終わらない"
  echo "  このリポジトリの worktree も継ぐ。試行回数は worktree ごと"
  echo "  ここでターンが終わらないまま $(( $(gate_ttl_seconds) / 3600 ))h 経つと自動で回収する"
  # verdict の待ち場所は 2 つ。アイドルで回収されたなら番兵の隣、諦めたならこのツリーのカウンタの隣。
  # 掛け直す人にとってはどちらも同じ意味。
  report_prior_verdict "$dir"   || true
  report_prior_verdict "$state" || true
  warn_if_no_profile "$root"
}

cmd_disarm() {
  local root; root="$(repo_root "${1:-}")"
  local dir
  if ! dir="$(find_armed "$root")"; then
    echo "not armed"
    return 0
  fi
  # $HOME の下で動くので、glob を使わず名前で指定する。
  # 意図した解除はきれいな終わりなので verdict を残さない。説明が要る回収との違いがここ。
  rm -f "$dir/ACTIVE" "$dir/ROOT" "$dir/ARMED_AT" "$dir/HEARTBEAT" "$dir/VERDICT" "$dir/VERDICT.prev"
  rm -rf "$dir/wt"
  rm -f "$dir/attempts.json" "$dir/delegated.json"   # worktree 対応前の配置
  rmdir "$dir" 2>/dev/null || true
  gate_trace "gate.sh" "$root" "意図して解除した"
  echo "disarmed: $dir"
}

# アイドルのゲートを、他のリポジトリのターン終了を待たずにいま回収する。ドライバーや CI 向け。
# 何を回収したかを出す。何も言わない掃除は、何も見つからなかった掃除と区別できない。
cmd_gc() {
  local f dir idle root ttl found=0
  ttl="$(gate_ttl_seconds)"
  shopt -s nullglob
  for f in "$GATE_DIR"/*/ACTIVE; do
    dir="$(dirname "$f")"
    idle="$(gate_idle_seconds "$dir")"
    if [[ -z "$idle" ]]; then
      # heartbeat を持たない版が掛けたもの。古いとみなさず、時計をここから動かす。
      gate_touch_heartbeat "$dir"
      echo "clock started: $(cat "$f" 2>/dev/null)（いままで heartbeat の記録なし）"
      found=1
      continue
    fi
    if (( idle > ttl )); then
      root="$(gate_expire "$dir" "$idle")"
      gate_log_verdict "${root:-$dir}" expired "アイドル $(( idle / 3600 ))h、gc が回収"
      echo "reclaimed: ${root:-$dir}（アイドル $(( idle / 3600 ))h、ttl $(( ttl / 3600 ))h）"
      found=1
    fi
  done
  (( found )) || echo "回収するものはない（$(( ttl / 3600 ))h を超えてアイドルのゲートは無い）"
}

cmd_record() {
  local check="${1:-}"
  [[ -n "$check" ]] || die "record にはチェック ID が要る"
  local root; root="$(repo_root "${2:-}")"
  local dir state
  dir="$(find_armed "$root")" || die "ゲートが掛かっておらず、記録する先が無い。
先に 'gate.sh arm' を実行するか、/da-verify に任せること。"
  # 委任の結果は 1 つの作業ツリーについての証拠なので、この作業ツリーに記録する。
  state="$(state_dir_for "$dir" "$root")"
  mkdir -p "$state" || die "$state を作れなかった"
  # 1 行 1 JSON オブジェクトで追記する。hook はパースせず ID を grep する。
  printf '{"%s": "passed"}\n' "$check" >> "$state/delegated.json"
  gate_trace "gate.sh" "$root" "委任したチェックを記録した: $check"
  echo "recorded: $check"
}

# 唯一の機械向けの出力。上の文をパースするドライバーは言い回しを変えた途端に壊れるので JSON にする。
# エスケープを間違えないよう node で組む。`status` と同じく読み取りのみ。
cmd_status_json() {
  local root dir state ended
  root="$(repo_root "${1:-}")"
  dir="$(find_armed "$root" || true)"
  ended=""
  [[ -n "$dir" ]] || ended="$(find_ended "$root" || true)"
  state=""
  [[ -n "$dir" ]] && state="$(state_dir_for "$dir" "$root")"
  node -e '
    const fs = require("fs");
    const [root, dir, state, ended, idle, ttl] = process.argv.slice(1);
    const read = (p) => { try { return fs.readFileSync(p, "utf8") } catch { return "" } };
    const verdict = (p) => {
      const raw = read(p);
      if (!raw) return null;
      const l = raw.split("\n");
      return { at: l[0] ?? "", reason: l[1] ?? "", check: l[2] ?? "", attempts: Number(l[3]) || 0,
               exit: l[4] ?? "", agent: l[5] ?? "", command: l[6] ?? "" };
    };
    let attempts = {};
    try { attempts = JSON.parse(read(state + "/attempts.json") || "{}") } catch {}
    const recorded = read(state + "/delegated.json").split("\n").filter(Boolean)
      .map((l) => { try { return Object.keys(JSON.parse(l))[0] } catch { return null } }).filter(Boolean);
    const gaveUp = verdict(state + "/VERDICT");
    process.stdout.write(JSON.stringify({
      repo: root,
      armed: Boolean(dir),
      dir: dir || null,
      state_dir: state || null,
      idle_seconds: idle === "" ? null : Number(idle),
      ttl_seconds: Number(ttl),
      gave_up: Boolean(gaveUp),
      verdict: gaveUp || verdict(ended + "/VERDICT"),
      attempts,
      recorded,
    }, null, 2) + "\n");
  ' "$root" "$dir" "$state" "$ended" "$( [[ -n "$dir" ]] && gate_idle_seconds "$dir" )" "$(gate_ttl_seconds)"
}

cmd_status() {
  if [[ "${1:-}" == "--json" ]]; then cmd_status_json "${2:-}"; return 0; fi
  local root; root="$(repo_root "${1:-}")"
  local dir state deleg attempts ended
  if ! dir="$(find_armed "$root")"; then
    # 掛かっていない。ただし「not armed」だけでは、一度も掛けなかったのか、放置されたゲートが
    # 回収されたのか区別できない。ここでは報告だけで回収しない。状態を読むことでゲートが開いてはならない。
    if ended="$(find_ended "$root")" && [[ -f "$ended/VERDICT" ]]; then
      echo "not armed  ($root)"
      echo "  ended    $(sed -n 2p "$ended/VERDICT" 2>/dev/null) at $(sed -n 1p "$ended/VERDICT" 2>/dev/null)"
      [[ "$(sed -n 3p "$ended/VERDICT" 2>/dev/null)" == "-" ]] \
        || echo "  check    $(sed -n 3p "$ended/VERDICT" 2>/dev/null)"
      echo "  verdict  $ended/VERDICT"
      echo "  このゲートが止めていた作業は検証されていない。完了と言う前に verdict を読むこと。"
    else
      echo "not armed  ($root)"
    fi
    return 0
  fi
  state="$(state_dir_for "$dir" "$root")"
  echo "armed      $dir"
  echo "  repo     $root"
  echo "  idle     $(idle_hours "$dir")（$(( $(gate_ttl_seconds) / 3600 ))h を超えると回収）"
  if [[ -f "$dir/VERDICT" ]]; then
    echo "  GAVE UP  $(sed -n 2p "$dir/VERDICT" 2>/dev/null)。$(sed -n 3p "$dir/VERDICT" 2>/dev/null) を $(sed -n 4p "$dir/VERDICT" 2>/dev/null) 回試して諦めた"
    echo "           このゲートはもう止めない。$dir/VERDICT を参照"
  fi
  [[ "$(cat "$dir/ACTIVE" 2>/dev/null)" == "$root" ]] \
    || echo "  inherited from $(cat "$dir/ACTIVE" 2>/dev/null)"
  # worktree 対応前の配置は記録を番兵の隣に置いていた。更新をまたいで委任の結果を失わないよう読む。
  # 失えば人にもう一度頼むことになり、1 版前に自分で書いたファイルを読むより悪い。
  deleg="$state/delegated.json";     [[ -e "$deleg" ]]    || deleg="$dir/delegated.json"
  attempts="$state/attempts.json";   [[ -e "$attempts" ]] || attempts="$dir/attempts.json"
  if [[ -s "$deleg" ]]; then
    echo "  recorded $(tr '\n' ' ' < "$deleg")"
  else
    echo "  recorded （まだ無い）"
  fi
  if [[ -s "$attempts" ]] && ! grep -qx '{}' "$attempts"; then
    echo "  attempts $(tr -d '\n ' < "$attempts")"
  fi
}

# このリポジトリのゲートのチェックをいま実行する。hook のループを作り直さず、Stop hook を駆動する。
# 「このリポジトリが何をどう検査するか」の実装を 1 つに保ち、ずれる 2 つ目のコピーを作らないため
# （da-verify/SKILL.md が散文でループを書いていた頃、未追跡ファイルの扱いが hook とずれていた）。
#
# DOTAGENTS_GATE_DRY を付けると、hook はプロファイルを解決し、チェックを実行し、報告して、何も
# 変えない。試行回数も verdict も heartbeat も触らず、番兵も要らない。自分の作業の確認は無料で
# なければならない。でないと試行回数が、どれだけ確認したかに左右される。
cmd_verify() {
  local as_json=0
  [[ "${1:-}" == "--json" ]] && { as_json=1; shift; }
  local root; root="$(repo_root "${1:-}")"

  # インストール済みではなく、このリポジトリのコピーを使う。インストール済みのほうは古いことがあり、
  # その差は `setup.sh doctor` が報告する。インストール済みを優先すると、テスト中の機能より古い版を
  # `verify` が黙って動かす。
  local hook; hook="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hooks/dotagents-verify-gate.sh"
  [[ -f "$hook" ]] || die "このスクリプトの隣に hooks/dotagents-verify-gate.sh が見つからない"

  local out err report rc=0
  out="$(mktemp "${TMPDIR:-/tmp}/dotagents-verify.XXXXXX")" || die "mktemp に失敗した"
  err="$(mktemp "${TMPDIR:-/tmp}/dotagents-verify.XXXXXX")" || die "mktemp に失敗した"
  report="$(mktemp "${TMPDIR:-/tmp}/dotagents-verify.XXXXXX")" || die "mktemp に失敗した"
  # shellcheck disable=SC2064
  trap "rm -f '$out' '$err' '$report'" EXIT

  # DOTAGENTS_GATE_REPORT は、hook に実行内容の機械向けの記録を求める。設定するのは `verify` だけ
  # なので、ターン終了時の実行はバイト単位で変わらない。
  printf '{"cwd":"%s","hook_event_name":"Stop"}' "$root" \
    | DOTAGENTS_GATE_DRY=1 DOTAGENTS_GATE_REPORT="$report" bash "$hook" >"$out" 2>"$err" || rc=$?

  if (( as_json )); then
    node -e '
      const fs = require("fs");
      const [outP, errP, rc, root, reportP] = process.argv.slice(1);
      const read = (p) => { try { return fs.readFileSync(p, "utf8") } catch { return "" } };
      const detail = (read(outP) + read(errP)).trim();
      // 失敗の報告では、hook が 1 行目に "gate: <check id>" を出す。
      const m = detail.match(/^gate:\s*(\S+)/m);
      const id = m && m[1] !== "all" && m[1] !== "nothing" ? m[1] : null;
      const kind = (detail.match(/^\s*kind\s*:\s*(\S+)/m) || [])[1] ?? null;

      // 散文に任せていた事実はサイドカーが運ぶ。無い・読めない時は閉じる側に倒す。
      // `checked: null` と `ok: false` にし、「実行したとみなす」ことはしない。
      // `verify` は意図してリポジトリ内の hook を動かすので、版のずれに配慮する場面は無い。
      let rep = null;
      try { rep = JSON.parse(read(reportP)) } catch {}
      const sane = rep && typeof rep === "object" && Number.isInteger(rep.ran);
      let ok = rc === "0";
      if (!sane) ok = false;

      process.stdout.write(JSON.stringify({
        repo: root, ok, exit: Number(rc), check: id, kind, detail,
        profile: sane ? (rep.profile ?? null) : null,
        changed_files: sane ? (rep.changed_files ?? null) : null,
        ran: sane ? rep.ran : null,
        checked: sane ? rep.ran > 0 : null,
        skipped: sane ? (rep.skipped ?? []) : null,
      }, null, 2) + "\n");
    ' "$out" "$err" "$rc" "$root" "$report"
  else
    cat "$out"
    cat "$err" >&2
  fi
  return "$rc"
}

# 行番号ではなくパターンで拾う。行番号で拾うと、ヘッダーにサブコマンドを足した時に範囲から押し出され、
# `gate.sh -h` が黙ってそれを載せなくなる。
usage() { grep -E '^#   gate\.sh ' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

[[ $# -gt 0 ]] || usage 1
cmd="$1"; shift
case "$cmd" in
  arm)       cmd_arm    "${1:-}" ;;
  disarm)    cmd_disarm "${1:-}" ;;
  record)    cmd_record "${1:-}" "${2:-}" ;;
  status)    cmd_status "${1:-}" "${2:-}" ;;
  gc)        cmd_gc ;;
  verify)    cmd_verify "${1:-}" "${2:-}" ;;
  -h|--help) usage ;;
  *) die "不明なコマンド: $cmd" ;;
esac
