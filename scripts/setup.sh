#!/usr/bin/env bash
# dotagents のインストーラ。
#
#   install [--dry-run] [--no-opinions]     スキルのリンク、hook のコピー、settings のマージ、
#                                          リポジトリが配らなくなった導入物の削除
#
#     --no-opinions    機構（`hooks`）だけをマージし、settings テンプレートの $opinionKeys にある
#                      キー（詳細テレメトリ、同梱・プラグインのスキルを黙らせる skillOverrides）を省く。
#                      利用者は作者一人なので既定で有効。同梱スキルに手を出したくない機械でだけ使う。
#   status                                  何が入っていて最新か
#   doctor                                  ずれと故障の診断
#   uninstall [--dry-run]                   入れたものだけを正確に外す
#
# スキルはシンボリックリンクにする。編集がすぐ効くため。Cursor と Codex は ~/.agents/skills を直接読む。
# Codex のサブエージェントは TOML しか読まないので agents/*.md から生成し、hook は Claude Code と同じ定義を
# ~/.codex/hooks.json に入れる（docs/decisions.md の決定 39）。
# hook はコピーにする。宙に浮いた hook のリンクは 127 で終わり、Claude Code はそれを非ブロックと
# 扱うので、ガードレールが閉じずに開く。docs/decisions.md を参照。

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

AGENTS_SKILLS="$HOME/.agents/skills"
CLAUDE_SKILLS="$HOME/.claude/skills"
CLAUDE_HOOKS="$HOME/.claude/hooks"
# 両方のエージェントのディレクトリへリンクする。Cursor が ~/.claude/agents/ も読むという根拠は
# ドキュメントに無く（書かれているのは .cursor/agents/ と ~/.cursor/agents/）、実際に Cursor 側では
# サブエージェントが見えていなかった。
CLAUDE_AGENTS="$HOME/.claude/agents"
CURSOR_AGENTS="$HOME/.cursor/agents"
# Codex は Markdown のエージェントを読まず、TOML だけを読む（~/.codex/agents/*.toml）。リンクできないので
# 生成する。スキルは Codex も ~/.agents/skills を直接読むので何もしない（Cursor と同じ）。
CODEX_AGENTS="$HOME/.codex/agents"
CODEX_MARK="# dotagents:generated"
MANIFEST="$HOME/.claude/.dotagents-managed.json"

DRY_RUN=0
# 既定で有効。`--no-opinions` で切る。冒頭を参照。
WITH_OPINIONS=1

# マージ中の、絞り込んだ settings スニペットを置く。`set -e` でも `die` でも関数を途中で抜けるので、
# どの終了経路でも消す。誰も消さない $TMPDIR の一時ファイルは、刈られないバックアップと同じ無限増殖になる。
SETTINGS_SCRATCH=""
trap '[[ -n "$SETTINGS_SCRATCH" ]] && rm -f "$SETTINGS_SCRATCH"' EXIT

# チルダそのもの。インラインで \~ と書くと bash 3.2 の置換でバックスラッシュが残る。
TILDE="~"

c_red=$'\033[31m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
ok()   { printf '%s✓%s %s\n' "$c_green" "$c_off" "$1"; }
warn() { printf '%s!%s %s\n' "$c_yellow" "$c_off" "$1"; }
bad()  { printf '%s✗%s %s\n' "$c_red" "$c_off" "$1"; }
note() { printf '%s  %s%s\n' "$c_dim" "$1" "$c_off"; }
run()  { if (( DRY_RUN )); then note "実行予定: $*"; else "$@"; fi; }
# 起きたことを報告し、起きたはずのことは報告しない。「コピーした」と出す dry run は嘘になる。
did()  { if (( DRY_RUN )); then note "予定: $1"; else ok "$1"; fi; }

die() { bad "$1"; exit 1; }

# リポジトリ内のスキルディレクトリ全部。_ で始まるもの（テンプレート、共有断片）は除く。
skill_names() {
  local d
  for d in "$REPO"/skills/*/; do
    [[ -d "$d" ]] || continue
    local n; n="$(basename "$d")"
    [[ "$n" == _* ]] && continue
    [[ -f "$d/SKILL.md" ]] || { warn "skills/$n に SKILL.md が無い。スキップ" >&2; continue; }
    printf '%s\n' "$n"
  done
}

hook_names() {
  local f
  for f in "$REPO"/hooks/*.sh; do
    [[ -f "$f" ]] || continue
    basename "$f"
  done
}

agent_names() {
  local f
  for f in "$REPO"/agents/*.md; do
    [[ -f "$f" ]] || continue
    local n; n="$(basename "$f" .md)"
    [[ "$n" == _* ]] && continue
    printf '%s\n' "$n"
  done
}

# マニフェストの一覧を 1 行 1 件で出す。マニフェストが無いか壊れていれば失敗する。刈り取りは
# `|| true` で空として扱い、uninstall は `set -e` で止まる（記録なしに外すものを決めない）。
manifest_list() {
  node -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));(m[process.argv[2]]||[]).forEach(x=>console.log(x))' "$MANIFEST" "$1"
}

# シンボリックリンクを 1 段だけ解決する（macOS には既定で `readlink -f` が無い）。
link_target() { readlink "$1" 2>/dev/null || true; }

# $1 が既に $2 を指すシンボリックリンクなら真。
points_at() { [[ -L "$1" && "$(link_target "$1")" == "$2" ]]; }

# ---------------------------------------------------------------- インストール

link_skill() {
  local name="$1"
  local src="$REPO/skills/$name"

  # 実体の入口: ~/.agents/skills/<name> -> <repo>/skills/<name>
  if [[ -e "$AGENTS_SKILLS/$name" && ! -L "$AGENTS_SKILLS/$name" ]]; then
    bad "$AGENTS_SKILLS/$name はこちらのものではない実ディレクトリ。置き換えない"
    return 1
  fi
  if points_at "$AGENTS_SKILLS/$name" "$src"; then
    note "最新: ~/.agents/skills/$name"
  else
    run ln -sfn "$src" "$AGENTS_SKILLS/$name"
    did "リンク ~/.agents/skills/$name"
  fi

  # リンクが要るのは Claude Code だけ。Cursor と Codex は ~/.agents/skills をそのまま読み（実測で確認）、
  # 両方の経路から見えるスキルも一覧には 1 回しか出ない。docs/decisions.md を参照。
  local dest="$CLAUDE_SKILLS/$name"
  local rel="../../.agents/skills/$name"   # ~/.claude/skills/<n> -> ~/.agents/skills/<n>
  if [[ -e "$dest" && ! -L "$dest" ]]; then
    bad "$dest はこちらのものではない実ディレクトリ。置き換えない"
  elif points_at "$dest" "$rel"; then
    note "最新: ~/.claude/skills/$name"
  else
    run ln -sfn "$rel" "$dest"
    did "リンク ~/.claude/skills/$name"
  fi

}

link_agent() {
  local name="$1"
  local src="$REPO/agents/$name.md"
  local d dir label

  # コピーではなくリンク。hook と違い、宙に浮いたエージェントのリンクは開く側に倒れない。解決できず
  # general-purpose に落ちるだけで、それはトランスクリプトに見える。
  for dir in "$CLAUDE_AGENTS" "$CURSOR_AGENTS"; do
    d="$dir/$name.md"
    label="${dir/#$HOME/$TILDE}/$name.md"
    if [[ -e "$d" && ! -L "$d" ]]; then
      bad "$d はこちらのものではない実ファイル。置き換えない"
      return 1
    fi
    if points_at "$d" "$src"; then
      note "最新: $label"
    else
      run ln -sfn "$src" "$d"
      did "リンク $label"
    fi
  done
}

# 生成物なので、中身が同じなら書かない。先頭行のマーカーの無い同名ファイルは他人のもので、preflight が断る。
gen_codex_agent() {
  local name="$1" dest="$CODEX_AGENTS/$1.toml" want
  if codex_agent_current "$name"; then
    note "最新: ~/.codex/agents/$name.toml"
    return
  fi
  want="$(node "$REPO/scripts/lib/codex-agent.mjs" "$REPO/agents/$name.md")" || return 1
  if (( ! DRY_RUN )); then printf '%s\n' "$want" > "$dest"; fi
  did "生成 ~/.codex/agents/$name.toml"
}

codex_agent_current() {
  [[ -f "$CODEX_AGENTS/$1.toml" && "$(cat "$CODEX_AGENTS/$1.toml")" == "$(node "$REPO/scripts/lib/codex-agent.mjs" "$REPO/agents/$1.md")" ]]
}

is_codex_generated() { [[ -f "$1" ]] && head -1 "$1" | grep -q "^$CODEX_MARK"; }

# リポジトリから消えたエージェントは、放っておくとリンクが残って呼ばれ続ける。
prune_agents() {
  local current recorded f name dir label
  local dirs=("$CLAUDE_AGENTS" "$CURSOR_AGENTS")
  current="$(agent_names | tr '\n' ' ')"
  recorded="$(manifest_list agents 2>/dev/null | tr '\n' ' ' || true)"

  for dir in "${dirs[@]}"; do
   [[ -d "$dir" ]] || continue
   label="${dir/#$HOME/$TILDE}"
   for f in "$dir"/*.md; do
    # `-e` はリンクをたどるので、刈るべき「先が改名・削除されたリンク」でちょうど偽になる。`-L` も見る。
    [[ -e "$f" || -L "$f" ]] || continue
    name="$(basename "$f" .md)"
    # 形（このリポジトリの agents/ を指すリンク）かマニフェストの記録でこちらのものと判断する。
    # それ以外は他人のものなので触らない。
    if points_at "$f" "$REPO/agents/$name.md" || [[ " $recorded " == *" $name "* ]]; then
      [[ " $current " == *" $name "* ]] && continue
      [[ -L "$f" ]] || { warn "$label/$name.md はシンボリックリンクではない。残す"; continue; }
      run rm -f "$f"
      did "刈り取り $label/$name.md（リポジトリから消えた）"
    fi
   done

  # 記録に無い名前でも、このリポジトリの agents/ を指す宙に浮いたリンクは掃く。2 回の install の間の
  # 改名は旧名のリンクを残し、上のループはそれをマニフェストでも `points_at` でも拾えない。
   for f in "$dir"/*.md; do
    [[ -L "$f" && ! -e "$f" ]] || continue
    [[ "$(link_target "$f")" == "$REPO/agents/"* ]] || continue
    run rm -f "$f"
    did "刈り取り $label/$(basename "$f")（リンク先が無い）"
   done
  done

  # Codex の生成物はマーカーで判断する。改名で残った旧名も同じ規則で拾える。
  for f in "$CODEX_AGENTS"/*.toml; do
    is_codex_generated "$f" || continue
    name="$(basename "$f" .toml)"
    [[ " $current " == *" $name "* ]] && continue
    run rm -f "$f"
    did "刈り取り ~/.codex/agents/$name.toml（リポジトリから消えた）"
  done
}

copy_hook() {
  local f="$1"
  local src="$REPO/hooks/$f"
  local dest="$CLAUDE_HOOKS/$f"
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    note "最新: ~/.claude/hooks/$f"
    return
  fi
  run cp "$src" "$dest"
  run chmod +x "$dest"
  did "コピー ~/.claude/hooks/$f"
}

# リポジトリから消えたスキルはリンクを 3 本残し、write_manifest がその存在を忘れるので uninstall でも
# 回収できなくなる。マニフェストを書き直す前に刈る。
prune_skills() {
  local shipped; shipped="$(skill_names)"
  local recorded n q
  recorded="$(manifest_list skills 2>/dev/null || true)"
  for n in $recorded; do
    grep -qxF "$n" <<<"$shipped" && continue
    for q in "$CLAUDE_SKILLS/$n" "$AGENTS_SKILLS/$n"; do
      # 消すのはシンボリックリンクだけ。実ディレクトリは他人のもの。
      if [[ -L "$q" ]]; then run rm -f "$q"; did "刈り取り ${q/#$HOME/$TILDE}"
      elif [[ -e "$q" ]]; then warn "${q/#$HOME/$TILDE} はシンボリックリンクではない。残す"; fi
    done
  done

  # マニフェストだけでは足りない。スキル一覧は install ごとに書き直されるので、自動刈り取り以前に
  # できた孤児はどこにも記録が無い。そこで記録に頼らず形でも掃く: こちらの書き方で先を指す、宙に
  # 浮いたリンク。どちらのパターンも他人のリンクには当たらない。
  local l t
  # nullglob は使わない。一致が無い時のリテラルは下の `-L` で落ちる。漏れた nullglob は backups_of の前身を
  # 「cwd を列挙して消す」に変えていた。
  for l in "$AGENTS_SKILLS"/*; do
    [[ -L "$l" && ! -e "$l" ]] || continue
    t="$(link_target "$l")"
    [[ "$t" == "$REPO/skills/"* ]] || continue
    run rm -f "$l"; did "孤児を刈り取り ${l/#$HOME/$TILDE}（リンク先がリポジトリから消えた）"
  done
  for l in "$CLAUDE_SKILLS"/*; do
    [[ -L "$l" && ! -e "$l" ]] || continue
    t="$(link_target "$l")"
    [[ "$t" == "../../.agents/skills/"* ]] || continue
    run rm -f "$l"; did "孤児を刈り取り ${l/#$HOME/$TILDE}（リンクの連鎖が切れている）"
  done
}

prune_hooks() {
  local shipped; shipped="$(hook_names)"
  local installed f
  # 以前の実行が記録したものだけを刈る。入れていないファイルには触らない。
  installed="$(manifest_list hooks 2>/dev/null || true)"
  for f in $installed; do
    if ! grep -qxF "$f" <<<"$shipped"; then
      run rm -f "$CLAUDE_HOOKS/$f"
      did "古い hook を刈り取り ~/.claude/hooks/$f"
    fi
  done
}

# 対象ごとに残す変更前の写しの数。悪い install を 1 回戻すには 3 で足り、見分けがつく量に収まる。
# install を毎回回すループがあるので、上限が無いと際限なく増える。
BACKUP_KEEP=3

# マージを実行し、対象が実際に変わったときだけバックアップを残す。
#
# 変更前の写しはまず一時ファイルに取り、本当に変わったときだけバックアップに昇格させる。無条件に
# 取って後で消す順序だと、一瞬でも起きていないことを示す状態ができる。
merge_with_backup() { # <target> <label> <merge command...>
  local target="$1" label="$2"; shift 2
  local pre="" rc=0
  if [[ -f "$target" ]]; then
    pre="$(mktemp "${TMPDIR:-/tmp}/dotagents-pre.XXXXXX" 2>/dev/null)" || pre=""
    [[ -n "$pre" ]] && cp "$target" "$pre"
  fi

  "$@" || rc=$?

  if [[ -n "$pre" ]]; then
    if cmp -s "$pre" "$target"; then
      rm -f "$pre"
      note "$label は変更なし。バックアップは取らない"
    else
      # タイムスタンプに加えて $$。刻みが秒なので、同じ秒の 2 回の install が同名になり後が前を上書きした。
      local backup="$target.dotagents-backup-$(date +%Y%m%d%H%M%S)-$$"
      mv "$pre" "$backup"
      note "バックアップ: ${backup/#$HOME/$TILDE}"
    fi
  fi

  # バックアップを取った時だけでなく毎回刈る。作る経路でだけ上限をかけると、変わらなくなったファイルの
  # 既存の山には二度と手が届かない。
  prune_backups "$target"
  return "$rc"
}

# glob の設定に左右されずにバックアップを列挙する。`ls -1 <glob>` は nullglob の下で一致が無いと
# 引数なしの `ls` になり、カレントディレクトリを並べる。刈り取りはそれを消しにいっていた。
backups_of() { local f; for f in "$1".dotagents-backup-*; do [[ -e "$f" ]] && printf '%s\n' "$f"; done; return 0; }

# 新しい方から BACKUP_KEEP 個を残す。刻みが %Y%m%d%H%M%S なので名前の辞書順で並ぶ。
prune_backups() { # <target>
  local target="$1" f n=0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    n=$((n+1))
    if (( n > BACKUP_KEEP )); then
      run rm -f "$f"
      did "古いバックアップを刈り取り ${f/#$HOME/$TILDE}"
    fi
  done < <(backups_of "$target" | sort -r)
}

# テンプレートが宣言するキーだけをマージする。こちらが書いていない既存の値（とくに平文の API キーを
# 持つ env.OTEL_EXPORTER_OTLP_HEADERS）は読みも書き直しもしない。
#
# --no-opinions のときは、テンプレート自身の $opinionKeys にあるキーを先に落とし、機構（`hooks`）だけを
# 残す。hooks はそれが無いと何も動かないので常にマージする。
#
# 2 回目のマージではなく一時ファイルに絞り込んでから渡す。merge-settings.mjs は manifest.settingsHooks を
# 渡されたスニペットの宣言で置き換えるので、`hooks` の無いスニペットで 2 回目を回すと hook の記録が消え、
# uninstall の手がかりが無くなる。
effective_settings_snippet() { # <template> -> path to merge (may be a temp file)
  local tmpl="$1"
  if (( WITH_OPINIONS )); then printf '%s\n' "$tmpl"; return; fi

  local out
  out="$(mktemp "${TMPDIR:-/tmp}/dotagents-settings.XXXXXX" 2>/dev/null)" || out=""
  if [[ -z "$out" ]]; then
    # 一時ファイルが無いと絞り込めない。絞らないテンプレートをマージすると頼まれていない意見キーまで
    # 当たるので、マージ全体を断って理由を言う。
    die "settings テンプレートを絞り込む一時ファイルを作れない。マージを中止する（絞らずにマージすると、
省くよう指定された意見キーまで当たるため）。TMPDIR を設定するか、--no-opinions を外すこと。"
  fi
  SETTINGS_SCRATCH="$out"
  node -e '
    const fs = require("fs");
    const snippet = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    // 一覧の置き場はテンプレート 1 か所。ここに写すと更新箇所が 2 つになる。
    const drop = new Set(snippet.$opinionKeys ?? []);
    for (const k of drop) delete snippet[k];
    delete snippet.$opinionKeys;
    fs.writeFileSync(process.argv[2], JSON.stringify(snippet, null, 2) + "\n");
  ' "$tmpl" "$out"
  printf '%s\n' "$out"
}

merge_settings() {
  local tmpl="$REPO/templates/claude.settings.snippet.json"
  local target="$HOME/.claude/settings.json"
  [[ -f "$tmpl" ]] || { note "settings スニペットが無い。スキップ"; return; }

  local eff; eff="$(effective_settings_snippet "$tmpl")"

  if (( DRY_RUN )); then
    note "実行予定: templates/claude.settings.snippet.json のキーを ~/.claude/settings.json へマージ"
    (( WITH_OPINIONS )) || note "（機構のみ。--no-opinions で env/skillOverrides を省く）"
    node "$REPO/scripts/lib/merge-settings.mjs" --print-keys "$eff" | sed 's/^/    /'
    rm -f "$SETTINGS_SCRATCH"; SETTINGS_SCRATCH=""
    return
  fi

  merge_with_backup "$target" "~/.claude/settings.json" \
    node "$REPO/scripts/lib/merge-settings.mjs" "$eff" "$target" "$MANIFEST"
  rm -f "$SETTINGS_SCRATCH"; SETTINGS_SCRATCH=""
  ok "settings を ~/.claude/settings.json へマージした$( (( WITH_OPINIONS )) || echo '（機構のみ）')"
}

# Cursor と Codex の hooks.json に、こちらの hook 項目を足す。Cursor は形が違うので専用のスニペット、
# Codex は Claude Code の `hooks` と同じ形なので Claude Code のスニペットの `hooks` だけを使う。
merge_hook_file() { # <cursor|codex> <スニペット> <対象>
  local kind="$1" tmpl="$2" target="$3"
  local label="${target/#$HOME/$TILDE}"
  [[ -f "$tmpl" ]] || return 0
  if (( DRY_RUN )); then
    note "実行予定: hook 項目を $label へマージ"
    return 0
  fi
  mkdir -p "$(dirname "$target")"
  merge_with_backup "$target" "$label" \
    node "$REPO/scripts/lib/merge-settings.mjs" "--$kind" "$tmpl" "$target" "$MANIFEST"
  ok "hook を $label へマージした"
  # 管理下でない hook は、ユーザーが定義を信頼するまで黙ってスキップされる。信頼はセキュリティ設定なので触らない。
  [[ "$kind" == codex ]] && warn "Codex は /hooks で信頼するまでこの hook を実行しない（定義が変わるたびに再度）"
  return 0
}

write_manifest() {
  (( DRY_RUN )) && return
  local skills hooks agents
  skills="$(skill_names)"; hooks="$(hook_names)"; agents="$(agent_names)"
  node -e '
    const fs=require("fs"), p=process.argv[1];
    let m={}; try { m=JSON.parse(fs.readFileSync(p,"utf8")); } catch {}
    m.repo=process.argv[2];
    const list = (s) => s.split("\n").filter(Boolean);
    m.skills=list(process.argv[3]);
    m.hooks=list(process.argv[4]);
    m.agents=list(process.argv[5]);
    m.updatedAt=new Date().toISOString();
    fs.writeFileSync(p, JSON.stringify(m,null,2)+"\n");
  ' "$MANIFEST" "$REPO" "$skills" "$hooks" "$agents"
}

# 断る可能性のあるものを、何かを書く前に全部確かめる。
#
# `link_skill` と `link_agent` は、行き先がこちらのものではない実体だと 1 を返す。`set -e` の下では
# 途中で終了し、スキルの一部だけリンクされ、hook もマニフェストも無い状態が残る。先に断れば、
# 結果は全部か無しかになる。
preflight() {
  local n blocked=0
  while read -r n; do
    [[ -n "$n" ]] || continue
    if [[ -e "$AGENTS_SKILLS/$n" && ! -L "$AGENTS_SKILLS/$n" ]]; then
      bad "$AGENTS_SKILLS/$n はこちらのものではない実ディレクトリ"; blocked=1
    fi
    if [[ -e "$CLAUDE_SKILLS/$n" && ! -L "$CLAUDE_SKILLS/$n" ]]; then
      bad "$CLAUDE_SKILLS/$n はこちらのものではない実ディレクトリ"; blocked=1
    fi
  done < <(skill_names)
  while read -r n; do
    [[ -n "$n" ]] || continue
    local d
    for d in "$CLAUDE_AGENTS" "$CURSOR_AGENTS"; do
      if [[ -e "$d/$n.md" && ! -L "$d/$n.md" ]]; then
        bad "$d/$n.md はこちらのものではない実ファイル"; blocked=1
      fi
    done
    if [[ -e "$CODEX_AGENTS/$n.toml" ]] && ! is_codex_generated "$CODEX_AGENTS/$n.toml"; then
      bad "$CODEX_AGENTS/$n.toml はこちらの生成物ではない"; blocked=1
    fi
  done < <(agent_names)

  (( blocked )) && die "インストールを中止した。何も変更していない。上のパスを移動か削除してから再実行すること。"
  return 0
}

cmd_install() {
  # linked worktree から入れると全リンクがその worktree を指し、worktree を消すとツール一式が黙って
  # 消える。逃げ道はインストーラのテスト専用（test-setup.sh とループは linked worktree の中で動く）。
  if [[ -f "$REPO/.git" && -z "${DOTAGENTS_ALLOW_WORKTREE_INSTALL:-}" ]]; then
    die "$REPO は linked git worktree に見える。メインのチェックアウトから入れること --
    worktree を消すと、入れたスキルが全部道連れになる。"
  fi

  # settings のマージとマニフェストはすべて node を通る。途中で落ちるとガードレールもマニフェストも
  # 無い状態が残るので、何かを変える前に確かめる。
  command -v node >/dev/null || die "node（18 以上）が必要。何も変更していない。"

  preflight

  run mkdir -p "$AGENTS_SKILLS" "$CLAUDE_SKILLS" "$CLAUDE_HOOKS" \
    "$CLAUDE_AGENTS" "$CURSOR_AGENTS" "$CODEX_AGENTS"

  local n
  while read -r n; do [[ -n "$n" ]] && link_skill "$n"; done < <(skill_names)
  while read -r n; do [[ -n "$n" ]] && copy_hook  "$n"; done < <(hook_names)
  while read -r n; do [[ -n "$n" ]] && link_agent "$n"; done < <(agent_names)
  while read -r n; do [[ -n "$n" ]] && gen_codex_agent "$n"; done < <(agent_names)

  # 常に刈る。install は「導入状態をリポジトリに合わせる」ことで、配らなくなったものの削除も含む。
  # 刈り取りは以前の実行がマニフェストに記録したものにしか触らない。
  prune_skills
  prune_hooks
  prune_agents
  merge_settings
  merge_hook_file cursor "$REPO/templates/cursor.hooks.snippet.json" "$HOME/.cursor/hooks.json"
  merge_hook_file codex "$REPO/templates/claude.settings.snippet.json" "$HOME/.codex/hooks.json"
  write_manifest

  echo
  ok "インストール完了$( (( DRY_RUN )) && echo '（dry run。何も変更していない）')"
  note "確認: scripts/setup.sh status"
}

# ---------------------------------------------------------------- status / doctor

cmd_status() {
  local n missing=0 total=0
  echo "スキル"
  while read -r n; do
    [[ -n "$n" ]] || continue
    total=$((total+1))
    local a="$AGENTS_SKILLS/$n" c="$CLAUDE_SKILLS/$n"
    if [[ -d "$a" && -d "$c" ]]; then
      ok "$n  ${c_dim}（~/.agents に実体、~/.claude からリンク、Cursor は ~/.agents を直接読む）${c_off}"
    else
      local where=""
      [[ -d "$a" ]] || where+=" agents"
      [[ -d "$c" ]] || where+=" claude"
      bad "$n  不足:$where"; missing=$((missing+1))
    fi
  done < <(skill_names)

  # スキルはリンクなので、導入済みの指示はこの作業ツリーそのもの。編集は次に読まれた時点で効き、
  # 記録は残らない（エージェントが同じセッションで自分の従う指示を書き換えた場合も）。
  #
  # ハッシュは持たない。git が既に正確に記録しており、導入時の基準は未レビューの変更まで基準にして
  # しまう。基準は git、比較は `git status`。
  echo
  echo "スキル本文と最新コミットの比較"
  if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    local drift; drift="$(git -C "$REPO" status --porcelain -- skills/ 2>/dev/null)"
    if [[ -z "$drift" ]]; then
      ok "HEAD と一致 ${c_dim}($(git -C "$REPO" rev-parse --short HEAD 2>/dev/null))${c_off}"
    else
      # 失敗ではない。スキルの編集はこのリポジトリの普通の作業で、要は「見える」こと。
      warn "未コミット。したがって既に効いている:"
      while IFS= read -r line; do [[ -n "$line" ]] && note "  $line"; done <<<"$drift"
    fi
  else
    warn "$REPO は git のチェックアウトではない。スキル本文を比べる基準が無い"
  fi

  echo
  echo "hook"
  while read -r n; do
    [[ -n "$n" ]] || continue
    if [[ ! -f "$CLAUDE_HOOKS/$n" ]]; then
      bad "$n  未導入"; missing=$((missing+1))
    elif cmp -s "$REPO/hooks/$n" "$CLAUDE_HOOKS/$n"; then
      ok "$n"
    else
      warn "$n  導入済みのコピーがソースと違う。実行: scripts/setup.sh install"
    fi
  done < <(hook_names)

  echo
  echo "エージェント"
  while read -r n; do
    [[ -n "$n" ]] || continue
    total=$((total+1))
    local where=""
    points_at "$CLAUDE_AGENTS/$n.md" "$REPO/agents/$n.md" && where="claude"
    points_at "$CURSOR_AGENTS/$n.md" "$REPO/agents/$n.md" && where="${where:+$where+}cursor"
    codex_agent_current "$n" && where="${where:+$where+}codex"
    if [[ "$where" == "claude+cursor+codex" ]]; then
      ok "$n  ${c_dim}（~/.claude/agents・~/.cursor/agents・~/.codex/agents）${c_off}"
    elif [[ -n "$where" ]]; then
      warn "$n  $where にしか無い。他のエージェントからは届かない"; missing=$((missing+1))
    elif [[ -e "$CLAUDE_AGENTS/$n.md" || -e "$CURSOR_AGENTS/$n.md" ]]; then
      warn "$n  あるが、こちらのリンクではない。触らない"
    else
      bad "$n  未導入"; missing=$((missing+1))
    fi
  done < <(agent_names)

  echo
  echo "hook の配線"
  local file who
  for who in "Claude:.claude/settings.json" "Cursor:.cursor/hooks.json" "Codex:.codex/hooks.json"; do
    file="$HOME/${who#*:}"
    for n in "dotagents-verify-gate:Stop ゲート" "dotagents-lint-skill-frontmatter:frontmatter lint"; do
      if grep -qs "${n%%:*}" "$file"; then ok "${who%%:*} の ${n#*:}"; else warn "${who%%:*} の ${n#*:}  未配線"; fi
    done
  done
  note "Cursor の stop hook はブロックできず、追いメッセージを差し込むだけ。同等ではない（docs/decisions.md）。"
  note "Codex は /hooks で信頼するまで hook を実行しない。配線済みでも未信頼なら素通り。"

  echo
  if (( missing )); then
    bad "$missing 件が不足（スキルとエージェント計 $total 件）"
    return 1
  fi
  ok "$total 件すべて導入済み"
}

cmd_doctor() {
  local problems=0

  # README.md の手順は、このリポジトリが意図して同梱しない upstream スキルに作業を渡す。何もそれを
  # 入れず、無いことも言わないので、最初の手順（`/research`）が黙って存在しなかった。報告だけして
  # 直さない。入れるのは `npx skills add` で、利用者の判断（README.md に手順あり）。
  #
  # 一覧はここ 1 か所で宣言する。scripts/verify-skills.sh が各名前が README.md にあることを確かめる。
  # dotagents:upstream-flow-skills research grilling documentation-and-adrs writing-plans executing-plans test-driven-development systematic-debugging receiving-code-review using-git-worktrees skill-scanner
  echo "手順書の流れが使う upstream スキル"
  # 写しを持たずマーカーそのものを読む。写しは verify-skills.sh の検査を受けずにずれる。
  local UPSTREAM_FLOW_SKILLS; UPSTREAM_FLOW_SKILLS="$(sed -n 's/^ *# dotagents:upstream-flow-skills //p' "${BASH_SOURCE[0]}")"
  local u umissing=0
  for u in $UPSTREAM_FLOW_SKILLS; do
    [[ -d "$AGENTS_SKILLS/$u" ]] || { umissing=$((umissing+1)); note "不足: /$u"; }
  done
  if (( umissing == 0 )); then
    ok "すべてある"
  else
    warn "$umissing 件が未導入。手順書の該当ステップは黙って欠ける。README.md を参照"
  fi

  echo
  # 上が全部緑でも、ゲートが何も検査できない機械はある。ゲートはリポジトリごとに有効化され、git remote に
  # 合うプロファイルから実行内容を決める。プロファイルが無ければ設計どおり pass する。数え方はゲートと
  # 同じ: `_` で始まるファイルはテンプレートで、一致しない。
  echo "プロファイル"
  local pn=0 pf
  for pf in "$REPO"/profiles/*.json; do
    [[ -f "$pf" ]] || continue
    case "$(basename "$pf")" in _*) continue ;; esac
    pn=$((pn+1))
  done
  if (( pn > 0 )); then
    ok "$REPO/profiles にプロファイル $pn 件 ${c_dim}（ゲートが検査するのは remote が一致するリポジトリだけ）${c_off}"
  else
    warn "プロファイルが無い。ゲートはどのリポジトリでも黙って pass する。profiles/_example.*.json をコピーするか、/da-verify を実行すること"
  fi

  echo
  echo "環境"
  [[ -d "$HOME/.claude" ]] && ok "~/.claude あり" || { bad "~/.claude が無い"; problems=$((problems+1)); }
  [[ -d "$HOME/.cursor" ]] && ok "~/.cursor あり" || { warn "~/.cursor が無い。Cursor 側は動かない"; }
  [[ -d "$HOME/.codex" ]] && ok "~/.codex あり" || { warn "~/.codex が無い。Codex 側は動かない"; }
  command -v node >/dev/null && ok "node $(node -v)" || { bad "node が見つからない（settings のマージに必要）"; problems=$((problems+1)); }

  echo
  echo "宙に浮いたリンク"
  local d found=0
  for d in "$AGENTS_SKILLS"/* "$CLAUDE_SKILLS"/*; do
    [[ -L "$d" ]] || continue
    if [[ ! -e "$d" ]]; then
      bad "${d/#$HOME/$TILDE} -> $(link_target "$d")  （壊れている）"
      found=1; problems=$((problems+1))
    fi
  done
  (( found )) || ok "なし"

  echo
  echo "こちらの名前空間にある他人の項目"
  # こちらが作っていない実ディレクトリ。たとえば npx skills の --copy で入れたスキル。
  found=0
  local ours; ours="$(skill_names)"
  for d in "$CLAUDE_SKILLS"/*; do
    [[ -e "$d" ]] || continue
    local n; n="$(basename "$d")"
    grep -qxF "$n" <<<"$ours" || continue
    [[ -L "$d" ]] || { warn "$n は実ディレクトリだが、同名のスキルをこちらが配っている"; found=1; }
  done
  (( found )) || ok "なし"

  echo
  echo "hook のブロック契約"
  # ガードレールには実際にブロックする経路が要る: Stop/PostToolUse なら exit 2、PreToolUse なら
  # permissionDecision の deny/ask。それ以外の終了コードは非ブロック扱いで、全部を素通しする。
  found=0
  local f
  for f in "$REPO"/hooks/*.sh; do
    [[ -f "$f" ]] || continue
    # ここで配る hook はすべてガードレールなので、すべてにブロック経路が要る。
    grep -qE 'exit 2|permissionDecision|followup_message' "$f" \
      || { warn "$(basename "$f") にブロック経路が無い（'exit 2' も permissionDecision も無い）。何も止められない"; found=1; }
  done
  (( found )) || ok "ガードレールの hook はすべてブロックできる"

  echo
  (( problems )) && { bad "問題 $problems 件"; return 1; }
  ok "問題なし"
}

# ---------------------------------------------------------------- アンインストール

cmd_uninstall() {
  [[ -f "$MANIFEST" ]] || die "${MANIFEST/#$HOME/$TILDE} にマニフェストが無い。導入の記録が無い"

  local skills hooks agents
  skills="$(manifest_list skills)"
  hooks="$(manifest_list hooks)"
  agents="$(manifest_list agents)"

  local n
  for n in $skills; do
    local p
    for p in "$CLAUDE_SKILLS/$n" "$AGENTS_SKILLS/$n"; do
      # 消すのはシンボリックリンクだけ。実ディレクトリは他人のものなので残す。
      if [[ -L "$p" ]]; then run rm -f "$p"; did "削除 ${p/#$HOME/$TILDE}"
      elif [[ -e "$p" ]]; then warn "${p/#$HOME/$TILDE} はシンボリックリンクではない。残す"; fi
    done
  done

  for n in $hooks; do
    [[ -f "$CLAUDE_HOOKS/$n" ]] && { run rm -f "$CLAUDE_HOOKS/$n"; did "削除 ~/.claude/hooks/$n"; }
  done

  for n in $agents; do
    local a d
    for d in "$CLAUDE_AGENTS" "$CURSOR_AGENTS"; do
      a="$d/$n.md"
      if [[ -L "$a" ]]; then run rm -f "$a"; did "削除 ${d/#$HOME/$TILDE}/$n.md"
      elif [[ -e "$a" ]]; then warn "${d/#$HOME/$TILDE}/$n.md はシンボリックリンクではない。残す"; fi
    done
    if is_codex_generated "$CODEX_AGENTS/$n.toml"; then
      run rm -f "$CODEX_AGENTS/$n.toml"; did "削除 ~/.codex/agents/$n.toml"
    fi
  done

  # バックアップも一緒に消す。編集していたファイルの変更前の写しで、アンインストール後はごみになる。
  local t
  for t in "$HOME/.claude/settings.json" "$HOME/.cursor/hooks.json" "$HOME/.codex/hooks.json"; do
    local b
    while IFS= read -r b; do
      [[ -n "$b" ]] || continue
      run rm -f "$b"
      did "削除 ${b/#$HOME/$TILDE}"
    done < <(backups_of "$t")
  done

  if [[ -f "$REPO/templates/claude.settings.snippet.json" ]]; then
    if (( DRY_RUN )); then
      note "実行予定: マニフェストに記録した settings のキーを戻す"
    else
      node "$REPO/scripts/lib/merge-settings.mjs" --revert "$HOME/.claude/settings.json" "$MANIFEST"
      ok "追加した settings のキーを戻した"
    fi
  fi

  local kind
  for kind in cursor codex; do
    t="$HOME/.$kind/hooks.json"
    [[ -f "$t" ]] || continue
    if (( DRY_RUN )); then
      note "実行予定: マニフェストに記録した hook 項目を ${t/#$HOME/$TILDE} から外す"
    else
      node "$REPO/scripts/lib/merge-settings.mjs" "--revert-$kind" "$t" "$MANIFEST"
      ok "${t/#$HOME/$TILDE} に追加した hook 項目を戻した"
    fi
  done

  (( DRY_RUN )) || rm -f "$MANIFEST"
  echo
  ok "アンインストール完了$( (( DRY_RUN )) && echo '（dry run。何も変更していない）')"
}

# ---------------------------------------------------------------- メイン

usage() {
  # 冒頭のブロックを最初の '#' だけの行まで出す。行番号の決め打ちは、フラグを書き足すたびにずれる。
  sed -n '2,/^#$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
  exit "${1:-0}"
}

[[ $# -gt 0 ]] || usage 1
cmd="$1"; shift

for arg in "$@"; do
  case "$arg" in
    --dry-run)       DRY_RUN=1 ;;
    --no-opinions)   WITH_OPINIONS=0 ;;
    -h|--help)       usage ;;
    *) die "不明なオプション: $arg" ;;
  esac
done

case "$cmd" in
  install)   cmd_install ;;
  status)    cmd_status ;;
  doctor)    cmd_doctor ;;
  uninstall) cmd_uninstall ;;
  -h|--help) usage ;;
  *) bad "不明なコマンド: $cmd"; usage 1 ;;
esac
