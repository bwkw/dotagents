#!/usr/bin/env bash
# インストーラのテスト。偽の HOME に対して動かし、本物の HOME には触れない。
#
# インストーラは自分のものではないファイル（認証情報を持つエージェント設定、他ツールの hook）を
# 書き換えるので、構文検査だけでなく振る舞いのテストが要る。

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"

# 刈り込みを試すため、テスト中のリポジトリ内にプローブを 1 つ作る。途中で中断しても
# skills/ephemeral-probe が作業ツリーに残って commit されないよう、trap でも消す。
PROBE_STAGED="$REPO/skills/_ephemeral-probe"
PROBE_LIVE="$REPO/skills/ephemeral-probe"
trap 'rm -rf "$TMP" "$PROBE_STAGED" "$PROBE_LIVE"' EXIT INT TERM

pass=0; fail=0
c_red=$'\033[31m'; c_green=$'\033[32m'; c_off=$'\033[0m'
ok()   { printf '%s✓%s %s\n' "$c_green" "$c_off" "$1"; pass=$((pass+1)); }
no()   { printf '%s✗%s %s\n' "$c_red" "$c_off" "$1"; fail=$((fail+1)); }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (期待 [$2]、実際 [$3])"; fi; }

FAKE="$TMP/home"
mkdir -p "$FAKE/.claude" "$FAKE/.cursor"

# インストーラは linked worktree を拒むが、このテストは worktree の中でも動く必要がある。
# 偽の HOME なので守る対象の危険は無く、以下の install では逃げ道を開ける。拒否そのものは
# worktree の形をした小さなツリーで別に確かめる。
export DOTAGENTS_ALLOW_WORKTREE_INSTALL=1

# 本物らしい設定ファイル: 触ってはいけない秘密と、他ツールの hook。
cat > "$FAKE/.claude/settings.json" <<'JSON'
{
  "model": "opus",
  "env": { "SECRET_TOKEN": "do-not-touch-me" },
  "skillOverrides": { "pdf": "on", "someone-elses-skill": "off" },
  "hooks": {
    "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "other-tool hook" } ] } ],
    "Stop": [ { "matcher": "", "hooks": [ { "type": "command", "command": "~/notify.sh" } ] } ]
  }
}
JSON
cp "$FAKE/.claude/settings.json" "$TMP/settings.before"
printf '{ "version": 1, "hooks": { "preToolUse": [ { "command": "other-tool", "matcher": "Shell" } ] } }\n' \
  > "$FAKE/.cursor/hooks.json"
cp "$FAKE/.cursor/hooks.json" "$TMP/cursor.before"
mkdir -p "$FAKE/.codex/agents"
printf '{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "other-tool stop" } ] } ] } }\n' \
  > "$FAKE/.codex/hooks.json"
cp "$FAKE/.codex/hooks.json" "$TMP/codex.before"
printf 'name = "mine"\ndescription = "x"\ndeveloper_instructions = "x"\n' > "$FAKE/.codex/agents/mine.toml"

run_setup() { HOME="$FAKE" bash "$REPO/scripts/setup.sh" "$@" 2>&1; }
j() { node -e 'const f=process.argv[1];try{console.log(JSON.stringify(require(f)))}catch{console.log("{}")}' "$1"; }

echo "インストーラ"
echo

# 未インストールの環境で --no-opinions を先に試す。仕組みは入り、好みのキーは入らないこと。
# 仕組みごと飛ばしたインストールでも「無いこと」の検査は通るので、hook があることも同時に見る。
run_setup install --no-opinions >/dev/null
mech() { node -e 'const f=process.argv[1];try{const s=require(f);console.log(JSON.stringify(s.skillOverrides?.["claude-api"] ?? null), JSON.stringify(s.env?.OTEL_LOG_TOOL_DETAILS ?? null))}catch{console.log("ERR")}' "$FAKE/.claude/settings.json"; }
check "--no-opinions は好みのキーを入れない" "null null" "$(mech)"
grep -q 'dotagents-verify-gate' "$FAKE/.claude/settings.json" \
  && ok "--no-opinions でも Stop ゲートは配線する" || no "仕組みまで飛ばされた"

# 次に既定のインストール。
run_setup install >/dev/null
check "install は同梱のスキルを全部リンクする" \
  "$(ls "$REPO/skills" | grep -vc '^_')" "$(ls "$FAKE/.claude/skills" | wc -l | tr -d ' ')"
check "既定のインストールは好みのキーを入れる" '"name-only" "1"' "$(mech)"

grep -q 'do-not-touch-me' "$FAKE/.claude/settings.json" \
  && ok "書いていない秘密は無傷" || no "秘密が書き換えられた"

# skillOverrides はユーザーと共有する map。項目は足すが、ユーザーのものは書き換えない。
# `pdf` はこちらの指定と別の値にしてあり、「別の値が既にある」分岐を通す。
so() { node -e 'const f=process.argv[1];try{const s=require(f).skillOverrides||{};console.log(s[process.argv[2]]??"absent")}catch{console.log("absent")}' "$FAKE/.claude/settings.json" "$1"; }
check "ユーザーが別の値にした override はそのまま" "on"  "$(so pdf)"
check "知らないスキルの override は残る"           "off" "$(so someone-elses-skill)"
check "こちらの override が入る"      "name-only" "$(so claude-api)"
check "'off' の override が入る"      "off"       "$(so 'anthropic-skills:schedule')"

grep -q 'other-tool hook' "$FAKE/.claude/settings.json" \
  && ok "他ツールの PreToolUse hook は残る" || no "他ツールの hook が消えた"
grep -q 'notify.sh' "$FAKE/.claude/settings.json" \
  && ok "他ツールの Stop hook は残る" || no "他ツールの Stop hook が消えた"
grep -q 'other-tool' "$FAKE/.cursor/hooks.json" \
  && ok "他ツールの Cursor hook は残る" || no "他ツールの Cursor hook が消えた"

# hook のコマンドは絶対パスでないとシェルが起動できず、ガードレールが素通しになる。
grep -q '\$HOME' "$FAKE/.claude/settings.json" \
  && no "hook のコマンドに展開されていない \$HOME が残っている" \
  || ok "hook のコマンドは絶対パス"

# Stop hook には明示の timeout が要る。harness に殺された hook は 0 でも 2 でもなく終わり、
# ブロックしない（ゲートが黙って素通しになる）。ゲート自身の予算より大きくし、先にこちらの時計を鳴らす。
hook_timeout() { # <event> <substring>
  node -e '
    const s = require(process.argv[1]);
    let found = "absent";
    for (const slot of (s.hooks?.[process.argv[2]] ?? []))
      for (const h of (slot.hooks ?? []))
        if (found === "absent" && (h.command ?? "").includes(process.argv[3]))
          found = h.timeout ?? "absent";
    console.log(found);
  ' "$FAKE/.claude/settings.json" "$1" "$2"
}
st="$(hook_timeout Stop dotagents-verify-gate)"
[[ "$st" != "absent" ]] && (( st > 780 )) \
  && ok "Stop hook の timeout はゲートの最悪値（600+180）を超える（${st} 秒）" \
  || no "Stop hook の timeout が ${st} -- harness に殺されるとブロックしないので素通しになる"
[[ "$(hook_timeout PreToolUse dotagents-lint-skill-frontmatter)" != "absent" ]] \
  && ok "lint hook も timeout を宣言している" \
  || no "lint hook に timeout が無い"

# Codex の hook は Claude Code と同じ形なので、同じ項目（timeout 込み）が ~/.codex/hooks.json に入る。
codex_hook() { node -e 'const f=process.argv[1];try{const s=require(f);const h=(s.hooks?.[process.argv[2]]??[]).flatMap(m=>m.hooks??[]).find(h=>h.command.includes(process.argv[3]));console.log(h?`${h.timeout}`:"absent")}catch{console.log("absent")}' "$FAKE/.codex/hooks.json" "$1" "$2"; }
[[ "$(codex_hook Stop dotagents-verify-gate)" == "$(hook_timeout Stop dotagents-verify-gate)" ]] \
  && ok "Codex にも Stop ゲートを同じ timeout で配線する" || no "Codex の Stop ゲートが無いか timeout が違う"
[[ "$(codex_hook PreToolUse dotagents-lint-skill-frontmatter)" != "absent" ]] \
  && ok "Codex にも lint hook を配線する" || no "Codex に lint hook が無い"
grep -q 'other-tool stop' "$FAKE/.codex/hooks.json" && ok "Codex の他人の hook は残る" || no "Codex の他人の hook が消えた"

# サブエージェントは両方のエージェントに届かなければならない。Cursor が読むのは
# .cursor/agents/ と ~/.cursor/agents/ で、~/.claude/agents/ だけでは Cursor に届かない。
for a in $(ls "$REPO/agents" | sed 's/\.md$//'); do
  [[ -L "$FAKE/.claude/agents/$a.md" ]] \
    && ok "エージェント '${a}' が Claude Code 向けにリンクされている" || no "エージェント '${a}' が ~/.claude/agents に無い"
  [[ -L "$FAKE/.cursor/agents/$a.md" ]] \
    && ok "エージェント '${a}' が Cursor 向けにリンクされている" || no "エージェント '${a}' が ~/.cursor/agents に無い"
done

# Codex は Markdown のエージェントを読まない。~/.codex/agents/*.toml の name・description・
# developer_instructions が必須で、model を書くとセッションのモデルを上書きする（不変条件 10）。
# 本物の TOML パーサが無いので、Codex が起動時に弾く形をここで最低限見る。
for a in $(ls "$REPO/agents" | sed 's/\.md$//'); do
  t="$FAKE/.codex/agents/$a.toml"
  if [[ -f "$t" ]]; then
    grep -q "^name = \"$a\"$" "$t" && grep -q '^description = "' "$t" && grep -q '^developer_instructions = "' "$t" \
      && ok "エージェント '${a}' が Codex 向けの TOML になっている" || no "エージェント '${a}' の TOML に必須キーが無い"
    grep -q '^model' "$t" && no "エージェント '${a}' の TOML がモデルを固定している" || ok "エージェント '${a}' の TOML はモデルを固定しない"
    grep -q '^sandbox_mode = "read-only"$' "$t" \
      && ok "readonly のエージェント '${a}' は Codex でも read-only" || no "エージェント '${a}' が Codex で書き込める"
  else
    no "エージェント '${a}' が ~/.codex/agents に無い"
  fi
done

# バックアップの無い対象（初めて作る ~/.codex/hooks.json）で、刈り取りがカレントディレクトリを列挙して
# 消しにいかないこと。prune_skills の nullglob が漏れると、空の glob で `ls -1` が cwd を並べ、4 件目以降を rm していた。
FRESH="$TMP/fresh-home"; CWDP="$TMP/cwd-probe"
mkdir -p "$FRESH" "$CWDP"; touch "$CWDP"/{a,b,c,d,e}
fresh_rc="$(cd "$CWDP" && HOME="$FRESH" bash "$REPO/scripts/setup.sh" install >/dev/null 2>&1; echo $?)"
check "バックアップの無い新しい HOME でも install が通る" 0 "$fresh_rc"
check "install はカレントディレクトリのファイルを消さない" 5 "$(ls "$CWDP" | wc -l | tr -d ' ')"

# 2 回目の install は何も変えない。冪等性は同じコマンドの再実行の性質なので、フラグも同じにする。
cp "$FAKE/.claude/settings.json" "$TMP/after1"
run_setup install >/dev/null
cmp -s "$TMP/after1" "$FAKE/.claude/settings.json" \
  && ok "install は冪等" || no "2 回目の install が設定をまた変えた"

# 何も変えない install はバックアップを残さない。区別できないバックアップの山は安全網にならず、
# 反復ごとに入れ直すループでは際限なく増える。
backups() { ls -1 "$FAKE/.claude/settings.json".dotagents-backup-* 2>/dev/null | wc -l | tr -d ' '; }
before_n="$(backups)"
run_setup install >/dev/null
[[ "$(backups)" == "$before_n" ]] \
  && ok "何も変えない install はバックアップを取らない" \
  || no "何も変えない install がバックアップを取った（${before_n} -> $(backups)）"

# worktree ガードが生きているか。REPO は setup.sh の場所から決まるので、`.git` を *ファイル* にした
# （linked worktree の形の）小さなツリーに同じインストーラを置き、逃げ道なしで呼ぶ。
WT_PROBE="$TMP/worktree-shaped"
mkdir -p "$WT_PROBE/scripts" "$WT_PROBE/skills" "$WT_PROBE/hooks" "$WT_PROBE/agents"
cp "$REPO/scripts/setup.sh" "$WT_PROBE/scripts/setup.sh"
printf 'gitdir: %s\n' "$TMP/fake-gitdir" > "$WT_PROBE/.git"
wt_home="$TMP/worktree-refuse-home"; mkdir -p "$wt_home"
wt_out="$(
  HOME="$wt_home" env -u DOTAGENTS_ALLOW_WORKTREE_INSTALL \
    bash "$WT_PROBE/scripts/setup.sh" install 2>&1
  echo "rc=$?"
)"
grep -q 'linked git worktree' <<<"$wt_out" && grep -q 'rc=1' <<<"$wt_out" \
  && ok "linked worktree の形のツリーからの install は拒否される" \
  || no "worktree ガードが拒否しなかった: $(tr '\n' ' ' <<<"$wt_out")"
[[ ! -e "$wt_home/.claude/.dotagents-managed.json" ]] && [[ ! -d "$wt_home/.claude/hooks" ]] \
  && ok "   ...拒否の前に何も書いていない" \
  || no "   worktree の形の install が何か書いた: $(ls -a "$wt_home/.claude" 2>/dev/null | tr '\n' ' ')"

# こちらのものではない置き場所があれば、何も書く前に install を止める。途中で止まると
# 一部のスキルだけリンクされ、hook も設定もマニフェストも無い（uninstall できない）状態になる。
CLASH="$TMP/clash-home"
mkdir -p "$CLASH/.claude" "$CLASH/.agents/skills/da-verify"     # リンクがあるべき場所に実ディレクトリ
clash_out="$(HOME="$CLASH" bash "$REPO/scripts/setup.sh" install 2>&1; echo "rc=$?")"
grep -q 'rc=0' <<<"$clash_out" \
  && no "他人のディレクトリの上への install が成功した -- 拒否すべき" \
  || ok "他人のディレクトリの上への install は拒否される"
[[ ! -e "$CLASH/.claude/.dotagents-managed.json" ]] && [[ ! -d "$CLASH/.claude/hooks" ]] \
  && ok "   ...何も書いていない（マニフェストも hook も無い）" \
  || no "   拒否の前に何か書いた: $(ls -a "$CLASH/.claude" | tr '\n' ' ')"
grep -q '何も変更していない' <<<"$clash_out" \
  && ok "   ...そう伝えている" || no "   何も変えていないと伝えずに拒否した"

# このファイルの本題: リポジトリから消したスキルは、フラグなしでインストールされなくなる。
mkdir -p "$PROBE_STAGED"
cat > "$PROBE_STAGED/SKILL.md" <<'SK'
---
name: ephemeral-probe
description: Temporary. Use when testing the installer.
metadata:
  source: bwkw/dotagents
---
## Preconditions
none
SK
mv "$PROBE_STAGED" "$PROBE_LIVE"
run_setup install >/dev/null
[ -e "$FAKE/.claude/skills/ephemeral-probe" ] && ok "新しいスキルが拾われる" || no "新しいスキルがリンクされていない"
rm -r "$PROBE_LIVE"
run_setup install >/dev/null
[ -e "$FAKE/.claude/skills/ephemeral-probe" ] \
  && no "消したスキルがまだ入っている -- 刈り込みが自動でない" \
  || ok "消したスキルはフラグなしで刈り込まれる"
[ -L "$FAKE/.claude/skills/ephemeral-probe" ] \
  && no "宙に浮いたシンボリックリンクが残った" || ok "宙に浮いたシンボリックリンクは残らない"

# uninstall は足したものを過不足なく戻す。
run_setup uninstall >/dev/null

# バイトではなく内容で比べる。マージは JSON を 2 スペース固定で書き直すので、別の整形の原本は
# バイト一致では戻らない。require ではなく JSON.parse を使うのは、拡張子の無いフィクスチャを
# require が JavaScript として読んで落ちるため。
pretty() { node -e '
  const fs = require("fs");
  console.log(JSON.stringify(JSON.parse(fs.readFileSync(process.argv[1], "utf8")), null, 2));
' "$1"; }

same_content() { # same_content <before> <after> <label>
  if node -e '
    const fs = require("fs");
    const load = (f) => JSON.parse(fs.readFileSync(f, "utf8"));
    const deep = (x, y) => {
      if (x === y) return true;
      if (typeof x !== typeof y || x === null || y === null || typeof x !== "object") return false;
      if (Array.isArray(x) !== Array.isArray(y)) return false;
      const kx = Object.keys(x), ky = Object.keys(y);
      return kx.length === ky.length && kx.every((k) => deep(x[k], y[k]));
    };
    process.exit(deep(load(process.argv[1]), load(process.argv[2])) ? 0 : 1);
  ' "$1" "$2"; then ok "$3"; else no "$3"; diff <(pretty "$1") <(pretty "$2") | head -8; fi
}
same_content "$TMP/settings.before" "$FAKE/.claude/settings.json" \
  "uninstall で設定のキーがすべて元の値に戻る"
same_content "$TMP/codex.before" "$FAKE/.codex/hooks.json" \
  "uninstall で Codex の hook が元の値に戻る"
same_content "$TMP/cursor.before" "$FAKE/.cursor/hooks.json" \
  "uninstall で Cursor の hook が元の値に戻る"

grep -q 'dotagents' "$FAKE/.claude/settings.json" \
  && no "uninstall がこちらの項目を残した" || ok "設定にこちらのものは何も残らない"
[ -d "$FAKE/.claude/skills" ] && [ "$(ls "$FAKE/.claude/skills" | wc -l | tr -d ' ')" = "0" ] \
  && ok "スキルのリンクは残らない" || no "uninstall 後もスキルのリンクが残っている"

echo
# uninstall は両方のエージェントのディレクトリを片付ける。片方が残ると、消えたはずのツールの
# サブエージェントに Cursor がまだ振り分ける。
left="$(ls "$FAKE/.claude/agents" "$FAKE/.cursor/agents" 2>/dev/null | grep -c '\.md$' || true)"
left_codex="$(ls "$FAKE/.codex/agents" 2>/dev/null | grep -c '\.toml$' || true)"
[[ "$left_codex" == "1" ]] \
  && ok "uninstall は Codex の生成物だけを消し、他人の TOML は残す" \
  || no "uninstall 後の ~/.codex/agents の TOML が ${left_codex} 個（期待 1: 他人のもの）"
[[ "$left" == "0" ]] \
  && ok "uninstall はどちらのディレクトリにもエージェントのリンクを残さない" \
  || no "uninstall 後もエージェントのリンクが ${left} 個残った"

# --- 状態の上限（uninstall の比較の後） ----------------------------------------
# 最後に置くのは、以下が設定のフィクスチャを上書きしてマージを起こし、上の uninstall の比較が
# 原本のバイトに依るため。
run_setup install >/dev/null

# 数に上限がある。スタンプは秒単位で、1 秒内の連続 install は同じファイル名になり何も証明しないので、
# ループで入れる代わりに古い別々のスタンプを種として置く。
for d in 20200101000001 20200101000002 20200101000003 20200101000004 20200101000005; do
  : > "$FAKE/.claude/settings.json.dotagents-backup-$d"
done
seeded="$(backups)"
# わざと変更を起こさない。上限は何も変えない install にも効く必要がある。
run_setup install >/dev/null
(( $(backups) <= 3 )) \
  && ok "バックアップは 3 世代に刈り込まれる（${seeded} から $(backups) へ）" \
  || no "種 ${seeded} 個に対してバックアップが $(backups) 個残った -- 数に上限が無い"
# 残すのは新しい方。でないと本当に欲しい変更前の姿を捨てることになる。
ls -1 "$FAKE/.claude/settings.json".dotagents-backup-* 2>/dev/null | grep -q '20200101000001' \
  && no "刈り込みが最古を残し、新しい方を捨てた" \
  || ok "   捨てられたのは古い方"

# マニフェストは uninstall が戻すものの唯一の記録で、重複は存在しないものの削除要求になる。
# settings.json 側は旧表記も消すが、マニフェスト側が追記だけだと旧表記が残り続ける。
mrec() { node -e '
  const m = require(process.argv[1]);
  console.log((m[process.argv[2]] ?? []).length);
' "$FAKE/.claude/.dotagents-managed.json" "$1"; }

# 旧表記（展開されていない $HOME）はきれいな偽の HOME では再現できず、修正なしでも通ってしまうので、
# 種として入れておく。
node -e '
  const fs = require("fs"), p = process.argv[1];
  const m = JSON.parse(fs.readFileSync(p, "utf8"));
  m.settingsHooks = [
    { event: "Stop", matcher: "", command: "$HOME/.claude/hooks/dotagents-verify-gate.sh" },
    ...(m.settingsHooks ?? []),
    { event: "PreToolUse", matcher: "", command: "someone-elses-hook.sh" },
  ];
  m.cursorHooks = [
    { event: "stop", command: "$HOME/.claude/hooks/dotagents-verify-gate.sh" },
    ...(m.cursorHooks ?? []),
  ];
  fs.writeFileSync(p, JSON.stringify(m, null, 2) + "\n");
' "$FAKE/.claude/.dotagents-managed.json"
printf '{"model":"haiku"}\n' > "$FAKE/.claude/settings.json"    # 実際のマージを起こす
run_setup install >/dev/null
check "hook の旧表記はマニフェストから消え、溜まらない" 3 "$(mrec settingsHooks)"
check "Cursor 側も同じ" 2 "$(mrec cursorHooks)"
node -e '
  const m = require(process.argv[1]);
  process.exit((m.settingsHooks ?? []).some(h => (h.command ?? "").includes("someone-elses-hook")) ? 0 : 1);
' "$FAKE/.claude/.dotagents-managed.json" \
  && ok "   ...こちらのものではない記録はマニフェストに残る" \
  || no "   他人のマニフェスト記録が消えた -- uninstall がそれを知らなくなる"


if (( fail )); then printf '%s成功 %d 件、失敗 %d 件%s\n' "$c_red" "$pass" "$fail" "$c_off"; exit 1; fi

printf '%s✓ 成功 %d 件%s\n' "$c_green" "$pass" "$c_off"
