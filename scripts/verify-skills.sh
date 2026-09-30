#!/usr/bin/env bash
# このリポジトリの全スキルを lint する。
#
#   verify-skills.sh [path ...]     既定は <repo>/skills
#
# エラーが 1 つでもあれば非 0 で終わる。警告では失敗しない。
#
# 検査は AGENTS.md の不変条件を符号化したもの。どれも、破っても黙って壊れる
# （メニューには出るが、書いてあることをもうしない）から置いてある。

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTS=("$@")
[[ ${#ROOTS[@]} -eq 0 ]] && ROOTS=("$REPO/skills")

# スキル本文はセッション中ずっとコンテキストに残り、読み直されない。自動圧縮の後は
# 各本文の先頭 ~5,000 トークンしか戻らず、その先は黙って失われる。
MAX_BYTES=12288
MAX_LINES=500
# 全スキルの説明文は常駐し、数が増えるほど 1 つずつが圧縮される。大事なものが読める程度に合計を抑える。
MAX_DESC_TOTAL=8000
MAX_DESC_ONE=500

errors=0
warnings=0
desc_total=0
count=0

c_red=$'\033[31m'; c_yellow=$'\033[33m'; c_green=$'\033[32m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
err()  { printf '%s✗%s %s: %s\n' "$c_red" "$c_off" "$1" "$2"; errors=$((errors+1)); }
warn() { printf '%s!%s %s: %s\n' "$c_yellow" "$c_off" "$1" "$2"; warnings=$((warnings+1)); }

# YAML frontmatter から最上位の `key: value` を取り出す。
frontmatter_value() {
  awk -v key="$2" '
    NR==1 && $0=="---" { inside=1; next }
    inside && $0=="---" { exit }
    inside {
      k=$0; sub(/:.*/,"",k); gsub(/^[ \t]+|[ \t]+$/,"",k)
      if (k==key) { v=$0; sub(/^[^:]*:[ \t]*/,"",v); print v; exit }
    }
  ' "$1"
}

has_frontmatter_key() {
  awk -v key="$2" '
    NR==1 && $0=="---" { inside=1; next }
    inside && $0=="---" { exit }
    inside {
      k=$0; sub(/:.*/,"",k); gsub(/^[ \t]+|[ \t]+$/,"",k)
      if (k==key) { found=1; exit }
    }
    END { exit !found }
  ' "$1"
}

# 下の awk ヘルパーは frontmatter を緩く読む（最初のコロンの後を全部取る）が、本物の YAML パーサーは違う。
# その差で、ここの検査を全部通ったのにパースできないスキルが出荷されたので、妥当性を先に別で見る。
#
# YAML パーサーではなく、平らな frontmatter が実際に壊れる形だけを見る的を絞った検査。CI が本物のパーサーを通す。
frontmatter_problem() {
  awk 'NR==1&&$0=="---"{i=1;next} i&&$0=="---"{exit} i' "$1" | node -e '
    let raw = "";
    process.stdin.on("data", (d) => (raw += d));
    process.stdin.on("end", () => {
      for (const [n, line] of raw.split("\n").entries()) {
        if (!line.trim() || /^\s*#/.test(line)) continue;
        if (/^\s+/.test(line)) continue;                       // 継続行か入れ子のブロック
        const m = line.match(/^([A-Za-z0-9_-]+)\s*:\s?(.*)$/);
        if (!m) { console.log(`${n + 1} 行目: key: value の組ではない -- ${line.trim().slice(0, 60)}`); return; }
        const v = m[2];
        if (v === "" || /^["'"'"'[{>|]/.test(v)) continue;      // 引用・フロー・ブロックスカラー
        // プレーンスカラーは ": " を含めない。YAML が入れ子のマッピングと読んでエラーになる。
        if (/:\s/.test(v)) {
          console.log(`${n + 1} 行目: '"'"'${m[1]}'"'"' が引用なしで ": " を含む -- YAML は入れ子のマッピングと読む。値を引用するか、em ダッシュを使う。`);
          return;
        }
        if (/^[@`*&!%]/.test(v)) {
          console.log(`${n + 1} 行目: '"'"'${m[1]}'"'"' が YAML の指示子文字で始まる -- 引用する。`);
          return;
        }
        if (/\t/.test(line)) { console.log(`${n + 1} 行目: タブ文字 -- YAML はインデントにタブを禁じている。`); return; }
      }
    });
  ' 2>/dev/null
}

check_skill() {
  local dir="$1"
  local name; name="$(basename "$dir")"
  local skill="$dir/SKILL.md"
  local id="skills/$name"

  [[ -f "$skill" ]] || { err "$id" "SKILL.md が無い"; return; }
  count=$((count+1))

  head -1 "$skill" | grep -qx -- '---' || { err "$id" "SKILL.md が YAML frontmatter で始まっていない"; return; }

  # --- frontmatter が実際にパースできること ------------------------------------
  local yaml_problem; yaml_problem="$(frontmatter_problem "$skill")"
  if [[ -n "$yaml_problem" ]]; then
    err "$id" "frontmatter が不正 -- $yaml_problem"
    return
  fi

  # --- 必須フィールド ---------------------------------------------------------
  local fm_name desc
  fm_name="$(frontmatter_value "$skill" name)"
  desc="$(frontmatter_value "$skill" description)"

  [[ -n "$fm_name" ]] || err "$id" "frontmatter に 'name' が無い"
  [[ -n "$desc"    ]] || err "$id" "frontmatter に 'description' が無い"

  # 下の agents ループと同じ規則。スキルの `model:` はその実行全体のモデルを切り替え、利用者が選んだモデルを
  # 黙って別のものにする（不変条件 10 が防ぐもの）。スキルでは Claude 専用のフィールドなので、2 エージェント間で
  # 振る舞いも割れる。別のモデルが要るなら、それは利用者が決めることで、スキルが代わりに決めることではない。
  if has_frontmatter_key "$skill" model; then
    smodel="$(frontmatter_value "$skill" model)"
    [[ "$smodel" == "inherit" ]] \
      || err "$id" "frontmatter が 'model: $smodel' を固定している -- スキルは利用者が選んだモデルを切り替えてはならない。フィールドを削除する"
  fi

  # 呼び出し名はディレクトリから決まるので、`name` が食い違うと何を打つかを読み手が誤る。
  if [[ -n "$fm_name" && "$fm_name" != "$name" ]]; then
    warn "$id" "frontmatter の name '$fm_name' がディレクトリ名 '$name' と違う（呼び出しは /${name}）"
  fi

  # --- 説明文の予算 ------------------------------------------------------------
  local dlen=${#desc}
  desc_total=$((desc_total + dlen))
  if (( dlen > MAX_DESC_ONE )); then
    warn "$id" "説明文が ${dlen} 文字（目標は ${MAX_DESC_ONE} 以下）"
  fi
  # 自動呼び出しは、モデルが依頼と照合できるきっかけの語に依存する。
  # dotagents:when-clause-tokens use (this|it|when)|when |after |before |時|する場合
  # hooks/dotagents-lint-skill-frontmatter.sh の一覧と同一に保つ（下の検査が確かめる）。
  # 食い違うと、ここを通った日本語の説明文がフックの権限プロンプトで止まる。lint の失敗ではなく停止になる。
  if ! grep -qiE 'use (this|it|when)|when |after |before |時|する場合' <<<"$desc"; then
    warn "$id" "説明文にいつ使うかの句が無い -- 自動呼び出しが当てにならない"
  fi

  # --- サイズ --------------------------------------------------------------------
  local bytes lines
  bytes=$(wc -c <"$skill" | tr -d ' ')
  lines=$(wc -l <"$skill" | tr -d ' ')
  if (( bytes > MAX_BYTES )); then
    if [[ "$dir" == "$REPO/skills/"* ]]; then
      err "$id" "SKILL.md が ${bytes} バイト（上限 ${MAX_BYTES}）-- 詳細を reference/ へ移す"
    else
      warn "$id" "SKILL.md が ${bytes} バイト（上限 ${MAX_BYTES}）-- 呼ぶとその分がセッション中ずっとコンテキストに居座る。削除を検討する"
    fi
  fi
  (( lines > MAX_LINES )) && warn "$id" "SKILL.md が ${lines} 行（目標は ${MAX_LINES} 以下）"

  # --- 不変条件: disable-model-invocation は名前で呼ばれないスキルにだけ ---
  # 人が打つワークフローには公式に正しい書き方で、説明の予算も食わない。誤りになるのは名前で呼ばれるスキルだけ。
  # プログラムからの Skill 呼び出しとサブエージェントの事前読み込みもエラーなしで塞ぐため。docs/decisions.md を参照。
  # 照合は $id ではなく $name で行う。$id は "skills/<name>" で、素の case パターンには当たらない。
  if has_frontmatter_key "$skill" disable-model-invocation; then
    # データとして宣言し、case パターンに書き下さずに照合する。下の相互検査がこの 2 行を本ファイルとフックの両方から読む。
    DMI_GATE="da-verify"                                                  # dotagents:dmi-gate
    DMI_DISPATCH="x-review-backend x-review-frontend x-review-infra"      # dotagents:dmi-dispatch

    # `gate.sh arm` を実行するのは /da-verify だけ。自動呼び出しが無いと Stop ゲートが arm されず毎ターン素通りする。
    if [[ " $DMI_GATE " == *" $name "* ]]; then
      err "$id" "'disable-model-invocation' を付けてはならない -- 'gate.sh arm' を実行するのはこれだけで、付けると Stop ゲートが arm されず毎ターン素通りする（開いたまま失敗する）"
    # da-review-all がサブエージェント経由で名前で呼ぶ。
    elif [[ " $DMI_DISPATCH " == *" $name "* ]]; then
      err "$id" "da-review-all が名前で呼ぶ先 -- 'disable-model-invocation' はプログラムからの Skill 呼び出しとサブエージェントの事前読み込みも塞ぐので、da-review-all はこの層をレビュー済みと報告しつつ何もレビューしなくなる"
    fi
    # それ以外は正当: 人が打つ専用で、予算は 0、名前で呼ぶものも無い。
  fi

  # --- 不変条件: Cursor が見るのは name/description/paths だけ -------------------
  # Claude 専用の frontmatter は最適化としては許すが、同じ制約を本文にも書かないと Cursor で黙って振る舞いが変わる。
  local body; body="$(awk 'NR==1&&$0=="---"{i=1;next} i&&$0=="---"{i=0;next} !i' "$skill")"

  if has_frontmatter_key "$skill" allowed-tools; then
    # 活用形（"never modifies"、"never writes"）も当てる。でないと制約をきちんと書いた文を弾く。
    if grep -qiE 'never (modif|writ|edit|chang|touch)|read-only|does not (modify|write|touch)|only reports|読み取り専用|変更しない|書き換えない|触らない|報告だけ' <<<"$body"; then
      :
    elif [[ "$dir" == "$REPO/skills/"* ]]; then
      err "$id" "'allowed-tools' を宣言しているが本文が制約を書いていない -- Cursor では強制されない（docs/decisions.md を参照）"
    else
      warn "$id" "'allowed-tools' を宣言しているが本文が制約を書いていない -- その制約は Cursor には存在しない"
    fi
  fi

  # 本文がサブエージェントに振るのに allowed-tools が Task を欠くスキルは、存在理由そのものを最適化で禁じられている
  # （decisions.md §3 が仕組みにしてはならないとするもの）。Cursor では無音、Claude では権限プロンプトになる。
  if has_frontmatter_key "$skill" allowed-tools \
     && grep -qiE 'parallel subagents|dispatch (them|the)|Task tool|launch .*subagent|サブエージェントを(並列|起動|立ち上げ)' <<<"$body" \
     && ! grep -qE '^allowed-tools:.*\bTask\b' <<<"$(frontmatter_value "$skill" allowed-tools | sed 's/^/allowed-tools: /')"; then
    err "$id" "本文はサブエージェントに振るのに 'allowed-tools' に Task が無い -- 書いてあることをスキルが実行できない"
  fi

  if has_frontmatter_key "$skill" context; then
    grep -qiE 'subagent|sub-agent|Task tool|separate context|fresh context|サブエージェント|別のコンテキスト' <<<"$body" \
      || err "$id" "'context:' を宣言しているが本文がサブエージェントで実行するよう書いていない -- Cursor では無視される（docs/decisions.md を参照）"
  fi

  # --- 出どころ ------------------------------------------------------------------
  # グローバルに入れると、自作は 20 余りのサードパーティのスキルに混ざる。印が無いと、どれが自分の責任か
  # （人が /skills を読む時も、da-skills-audit が削除を提案してよいか決める時も）答えられない。
  # このリポジトリのスキルだけに限る。インストール先に対して走らせると、全サードパーティが印なしと報告され、
  # 報告の大半が雑音になって読まれなくなる（finding-discipline.md が扱う失敗そのもの）。
  if [[ "$dir" == "$REPO/skills/"* ]]; then
    local fm_block; fm_block="$(awk 'NR==1&&$0=="---"{i=1;next} i&&$0=="---"{exit} i' "$skill")"
    grep -q 'source: bwkw/dotagents' <<<"$fm_block" \
      || err "$id" "frontmatter に 'metadata.source: bwkw/dotagents' が無い -- 自作はインストール済みのサードパーティのスキルと見分けられなければならない"
  fi

  # --- シンボリックリンクはリポジトリの中に留まること -----------------------------
  # reference/ はエージェントが指示に従って読む。外を指すリンクがあると「reference を読め」が
  # 「指す先を何でも読め」（~/.ssh/id_rsa、.env など）になる。自作は _shared/ を指すので問題ない。
  local link target
  while IFS= read -r link; do
    [[ -n "$link" ]] || continue
    if [[ ! -e "$link" ]]; then
      err "$id" "リンク先の無いシンボリックリンク: ${link#"$dir"/} -> $(readlink "$link")"
      continue
    fi
    target="$(cd "$(dirname "$link")" && cd "$(dirname "$(readlink "$link")")" 2>/dev/null && pwd)"
    if [[ -n "$target" && "$target" != "$REPO"/* && "$target" != "$REPO" ]]; then
      err "$id" "シンボリックリンクがリポジトリの外を指す: ${link#"$dir"/} -> $target"
    fi
  done < <(find "$dir" -type l 2>/dev/null)

  # --- reference ファイルは絶対パスで指すこと -------------------------------------
  # 相対パスは cwd の違うサブエージェントの中では解決しない。
  if [[ -d "$dir/reference" ]]; then
    # ファイル単位ではなくパス単位で見る。以前は本文に CLAUDE_SKILL_DIR が一度でも出れば通り、
    # 実際のパスは相対のままだった（x-review-* の 3 つがそうだった）。状態ではなく仕組みを検査する。
    local bare
    bare="$(grep -oE '(^|[^/${])reference/[a-z0-9_-]+\.md' <<<"$body" | sed 's/^[^r]*//' | sort -u | tr '\n' ' ')"
    if [[ -n "${bare// /}" ]]; then
      err "$id" "reference ファイルを相対パスで指している（${bare% }）-- サブエージェントの cwd はこちらと違うので、\${CLAUDE_SKILL_DIR}/reference/... を使う"
    fi

    local ref
    for ref in "$dir"/reference/*; do
      [[ -f "$ref" ]] || continue
      grep -qF "$(basename "$ref")" <<<"$body" \
        || warn "$id" "reference/$(basename "$ref") が SKILL.md のどこにも出てこない"
    done

    # 逆向きも見る。言及されているのにファイルが無い方が悪い。その文に従った人は開くものが無い。
    local mentioned
    for mentioned in $(grep -oE 'reference/[a-z0-9_-]+\.md' <<<"$body" | sed 's|^reference/||' | sort -u); do
      [[ -e "$dir/reference/$mentioned" ]] \
        || err "$id" "reference/$mentioned を名指しているが、そのファイルが無い -- この指示に従っても開くものが無い"
    done

    # さらに一段外: reference ファイルが兄弟ファイルを素のファイル名で指す場合。AGENTS.md は層の perspectives.md が
    # 共有の観点を 1 行で指すとしており、その 1 行が効いている。リンクが消えても文は自然に読めて何も開かない。
    # シンボリックリンクでない reference ファイルだけを見る。_shared/ 同士の参照は、両方をリンクするスキルでは解決し、
    # しないスキルでは宙に浮くが、それは別の問題で、塞ぐと読ませたくないファイルまでリンクすることになる。
    local sibling
    for ref in "$dir"/reference/*.md; do
      [[ -f "$ref" && ! -L "$ref" ]] || continue
      for sibling in $(grep -oE '`[a-z0-9_-]+\.md`' "$ref" | tr -d '`' | sort -u); do
        [[ -e "$dir/reference/$sibling" ]] \
          || err "$id" "reference/$(basename "$ref") が $sibling を名指しているが、このスキルの reference/ に無い -- 書き直しの代わりに置いた 1 行の参照の先が空"
      done
    done
  fi

  # --- 不変条件: user-invocable: false は呼び出し先にだけ ------------------------
  # / メニューから消すがモデルからは呼べる。何も呼ばないスキルに付けると、打てず、説明文の照合でしか見つからない。
  # disable-model-invocation と併用すると、どこからも届かない。
  if has_frontmatter_key "$skill" user-invocable; then
    local ui
    ui="$(awk 'NR==1&&$0=="---"{i=1;next} i&&$0=="---"{exit} i' "$skill" \
          | sed -n 's/^user-invocable:[[:space:]]*//p' | tr -d '"'"'"' ')"
    if [[ "$ui" == "false" ]]; then
      case "$name" in
        x-review-backend|x-review-frontend|x-review-infra) : ;;  # da-review-all が呼ぶ
        *)
          err "$id" "'user-invocable: false' を付けているが、これを呼ぶものが無い -- / メニューから消え、説明文の照合でしか届かない。この検査の呼び出し先一覧に足すか、フィールドを削除する" ;;
      esac
      has_frontmatter_key "$skill" disable-model-invocation \
        && err "$id" "'user-invocable: false' と 'disable-model-invocation' を両方付けている -- 前者は打つのを、後者はモデルを塞ぎ、スキルはどの経路からも届かない"
    fi
  fi

  # --- 構成 ------------------------------------------------------------------------
  grep -qiE '^##+ .*(precondition|実行条件)' <<<"$body" \
    || warn "$id" "実行条件の節が無い -- 不正な入力で綺麗に止まれない"
}

echo "スキルを lint する"
echo
for root in "${ROOTS[@]}"; do
  [[ -d "$root" ]] || { err "$root" "ディレクトリではない"; continue; }
  for dir in "$root"/*/; do
    [[ -d "$dir" ]] || continue
    [[ "$(basename "$dir")" == _* ]] && continue   # _shared ほか _ で始まる補助ディレクトリ（_template はここではなくリポジトリ直下）
    check_skill "${dir%/}"
  done
done

# --- 保護対象の名前が実在し、2 つの強制箇所が一致すること ----
# disable-model-invocation の範囲は 2 ファイルにハードコードしたスキル名の一覧。片方だけ直してリネームすると、
# ガードレールは入ったまま何も強制しなくなる（`da-` 接頭辞の導入時に実際に起きた）。なので実物と突き合わせる。
if [[ -d "$REPO/skills" ]]; then
  echo
  echo "disable-model-invocation の範囲を検査する"
  hook_file="$REPO/hooks/dotagents-lint-skill-frontmatter.sh"

  # 両ファイルはマーカー付きの行で一覧を宣言し、振る舞いもその宣言で決まる。case パターンを解析せずマーカーで読む。
  # 接頭辞に依らないので、将来の接頭辞も誰かが広げるのを覚えていなくても拾える。
  # $0 ではなく ${BASH_SOURCE[0]} を使う。source された時の $0 は呼び出し元になる。
  # 名前を取り出す前にマーカーコメントを剥がすので、`dmi-gate` や `dmi-dispatch` 自体はスキル名として読まれない。
  # `#` と `//` の両方を受ける。片方は bash、もう片方はフックに埋め込んだ JS。
  marked_names() { # <file> <marker>
    grep -E "dotagents:$2([^-a-z0-9]|$)" "$1" 2>/dev/null \
      | sed 's|[#/]*[[:space:]]*dotagents:.*$||' \
      | grep -oE '[a-z][a-z0-9]*(-[a-z0-9]+)+' | sort -u
  }
  linter_names="$( { marked_names "${BASH_SOURCE[0]}" dmi-gate; marked_names "${BASH_SOURCE[0]}" dmi-dispatch; } | sort -u)"
  hook_names="$(   { marked_names "$hook_file"        dmi-gate; marked_names "$hook_file"        dmi-dispatch; } | sort -u)"

  scope_ok=1
  if [[ -z "$linter_names" ]]; then
    err "scope" "'dotagents:dmi-gate'/'dotagents:dmi-dispatch' の宣言が verify-skills.sh に無い -- 2 つの一覧を比べられるのはこのマーカーのおかげで、消すと検査も消える"
    scope_ok=0
  fi
  if [[ -z "$hook_names" ]]; then
    err "scope" "'dotagents:dmi-gate'/'dotagents:dmi-dispatch' の宣言が lint フックに無い -- 2 つの一覧を比べられるのはこのマーカーのおかげで、消すと検査も消える"
    scope_ok=0
  fi
  while read -r pn; do
    [[ -n "$pn" ]] || continue
    [[ -f "$REPO/skills/$pn/SKILL.md" ]] \
      || { err "scope" "'$pn' は disable-model-invocation から保護されているが skills/$pn が無い -- リネームで一覧が追従しておらず、ガードレールは何も守っていない"; scope_ok=0; }
  done <<<"$linter_names"

  if [[ -n "$hook_names" && -n "$linter_names" ]] && [[ "$linter_names" != "$hook_names" ]]; then
    err "scope" "verify-skills.sh と lint フックが保護する名前が違う -- 両方が一致しないと、片方が黙って強制をやめる"
    printf '%s  linter: %s%s\n' "$c_dim" "$(tr '\n' ' ' <<<"$linter_names")" "$c_off"
    printf '%s  hook:   %s%s\n' "$c_dim" "$(tr '\n' ' ' <<<"$hook_names")" "$c_off"
    scope_ok=0
  fi

  (( scope_ok )) && printf '%s✓%s 保護対象の名前は実在し、2 つの強制箇所が一致: %s\n' \
    "$c_green" "$c_off" "$(tr '\n' ' ' <<<"$linter_names")"
fi

# --- 共有のゲートブロック -------------------------------------------------------
# scripts/gate.sh と hooks/dotagents-verify-gate.sh は、センチネルがどのリポジトリに属し、作業ツリーのカウンタが
# どこにあるかを両方で決める。lib から source せず複製しているのは、不変条件 4（フックは消えうるパスに依存しない）のため。
# 複製が安全なのは写しが同一の間だけ。解決の仕方がずれると片方が arm し、もう片方は別のディレクトリを強制する。
gate_sh="$REPO/scripts/gate.sh"
gate_hook="$REPO/hooks/dotagents-verify-gate.sh"
if [[ -f "$gate_sh" && -f "$gate_hook" ]]; then
  echo
  echo "共有のゲートブロックを検査する"
  extract_identity() {
    sed -n '/^# >>> dotagents:gate-shared/,/^# <<< dotagents:gate-shared/p' "$1"
  }
  ident_a="$(extract_identity "$gate_sh")"
  ident_b="$(extract_identity "$gate_hook")"
  if [[ -z "$ident_a" ]]; then
    err "gate-shared" "scripts/gate.sh に '# >>> dotagents:gate-shared' ブロックが無い -- 複製を検査できるのはこのマーカーのおかげで、消すと検査も消える"
  elif [[ -z "$ident_b" ]]; then
    err "gate-shared" "hooks/dotagents-verify-gate.sh に '# >>> dotagents:gate-shared' ブロックが無い -- 複製を検査できるのはこのマーカーのおかげで、消すと検査も消える"
  elif [[ "$ident_a" != "$ident_b" ]]; then
    err "gate-shared" "2 つの写しがずれている -- gate.sh がリポジトリや作業ツリーをフックと違うように解決し、片方が arm したディレクトリをもう片方が強制しなくなる"
    printf '%s  最初の差分:%s\n' "$c_dim" "$c_off"
    diff <(printf '%s\n' "$ident_a") <(printf '%s\n' "$ident_b") | head -8 | sed "s/^/$(printf '%s' "$c_dim")    /"
    printf '%s%s\n' "$c_off" ""
  else
    printf '%s✓%s 共有のゲートブロックは gate.sh とフックでバイト単位で一致（%s 行）\n' \
      "$c_green" "$c_off" "$(printf '%s\n' "$ident_a" | wc -l | tr -d ' ')"
  fi
fi

# --- 設計レビューは着地計画を出すこと -------------------------------------------
# 作業をどの変更に分けて出すかは、ほかのどこでも決めない（da-fix-plan は 1 変更内のコミット順、da-review-all は
# 所見として問うだけ）。その節は da-design-review の必須出力で、文章でだけ求める必須節は黙って出なくなるのでここで見る。
dr="$REPO/skills/da-design-review/SKILL.md"
if [[ -f "$dr" ]]; then
  echo
  echo "設計レビューの着地計画を検査する"
  if ! grep -q 'Landing plan' "$dr"; then
    err "landing-plan" "skills/da-design-review が 'Landing plan' 節を出さなくなった -- 作業をどの変更に分けて出すかを決めるものがツールキットにほかに無い"
  elif ! grep -q 'What gates it' "$dr"; then
    err "landing-plan" "着地計画の表から 'What gates it' 列が消えた -- ゲートを名指せない着地は検証できず、この列が表をただの一覧以上のものにしている"
  else
    printf '%s✓%s 設計レビューは着地ごとのゲート付きで着地計画を出す\n' "$c_green" "$c_off"
  fi
fi

# --- サブエージェント禁止の規則は reference/ だけでなく本文に書くこと -----
# Cursor には ${CLAUDE_SKILL_DIR} も同等のものも無い。reference/ にだけある規則は Claude Code は従い Cursor は
# 従わないかもしれず、その失敗は見えない。不変条件 1（制約は本文に書き、Claude 専用の経路はその上の最適化）を、
# レビューのコストを決める規則に当てたもの。
#
# 以前は逆の内容（0/3/5 の fan-out 予算）を求めていた。レビューはもう何も起動しないので、本文にサブエージェントの
# 許可が残っていれば、半分だけ当たった変更の古い半分になる。**検査は消さずに向け直した**。理由は規則に依らない:
# 支出を縛るものは両エージェントで効かなければならず、両方で効くのは本文だけ。
echo
echo "サブエージェント禁止の規則が本文に書かれているか検査する"
budget_missing=""
for bs in x-review-backend x-review-frontend x-review-infra da-review-all; do
  bf="$REPO/skills/$bs/SKILL.md"
  [[ -f "$bf" ]] || { budget_missing="$budget_missing $bs(absent)"; continue; }
  bbody="$(awk 'NR==1&&$0=="---"{i=1;next} i&&$0=="---"{i=0;next} !i' "$bf")"
  # 禁止と、報告が持つべき語の両方を見る。"no subagents" だけなら別の話の文にありうるし、"inline" だけなら何の副詞でもよい。
  grep -qiE 'no subagents' <<<"$bbody" && grep -qiE 'inline' <<<"$bbody" \
    || budget_missing="$budget_missing $bs"
done
if [[ -n "$budget_missing" ]]; then
  err "no-subagent-rule" "サブエージェント禁止の規則が次の本文に無い:$budget_missing -- Cursor は \${CLAUDE_SKILL_DIR} を解決できないので、reference/ にだけある規則はそこで効かない"
else
  printf '%s✓%s fan-out の予算とそのインライン段が、レビューの本文 4 つすべてにある\n' "$c_green" "$c_off"
fi

# --- 差分サイズの計測はレビュー対象の範囲に絞ること ---
# レビュー系スキルはどれも読む前に差分の大きさを測り、その数でどの手順を読むかと、報告がレビューを名乗れるかが決まる。
# da-review-all は層ごとのファイル一覧を渡して「差分全体を導き直すな」と言うのに、計測は範囲なしで測っていた。
# すると 45 ファイルを 15/15/15 に分けた変更で、各層が 45 を測って自分を標本扱いした。報告が実際より控えめになる
# 方向の失敗なので、何もおかしく見えない。
#
# 実際に走るのはスニペットなので、文章ではなくスニペットを検査する。`SCOPE` はファイル内で代入され（未設定にならない）、
# サイズを測る `git diff` はすべてそれを渡すこと。
echo
echo "差分サイズの計測がレビュー対象のパスに絞られているか検査する"
# 一覧にせず導出する。5 つをハードコードすると、6 つ目のレビュー系スキルが黙って免除される。
# `--shortstat` は計測スニペットにしか出ないので、それを含むファイルが検査対象そのもの。
scope_bad=""
scope_files="$(grep -rlF -- '--shortstat' "$REPO/skills" 2>/dev/null | sort)"
scope_n="$(printf '%s\n' "$scope_files" | grep -c .)"
if (( scope_n < 5 )); then
  err "diff-size-scope" "skills/ 配下で差分を測るファイルが $scope_n 個しか無い -- 5 個あったので、1 つは範囲を絞られたのではなく計測手順ごと失った"
fi
for sp in $scope_files; do
  sf="${sp#"$REPO/skills/"}"
  grep -qE '^[[:space:]]*SCOPE=' "$sp" || { scope_bad="$scope_bad $sf(no-SCOPE)"; continue; }
  # `--shortstat` は計測の 1 行にしか出ず、その行は `--name-only | wc -l` の半分も持つ。両方が範囲を取るよう、
  # 行内に 2 回出ることを求める。範囲なしの `git diff --name-only` を正当に示す別の文には当てない
  # （範囲をそもそも決めるのは差分全体に対する操作）。
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    n_scoped="$(grep -o -- '-- \$SCOPE' <<<"$line" | wc -l | tr -d ' ')"
    (( n_scoped >= 2 )) || scope_bad="$scope_bad $sf(unscoped)"
  done < <(grep -F -- '--shortstat' "$sp")
done
if [[ -n "$scope_bad" ]]; then
  err "diff-size-scope" "次の箇所で差分サイズの計測がレビュー対象のパスに絞られていない:$scope_bad -- 振られた層が変更全体を測り、自分の作業を標本と報告する"
else
  printf '%s✓%s 差分サイズの計測は 5 つの計測スニペットすべてで範囲が絞られている\n' "$c_green" "$c_off"
fi

# --- レビューの上限は、記録とも自分自身とも食い違わないこと ---
# 3 観点の検証は、最も重い所見のうち何件を 1 つではなく 3 つの角度から見るかという、レビューの品質の上限。
# 決定 16 は各観点がサブエージェントだった頃のコスト論で「層ごとに最も不可逆な 3 件」とした。daa6ad9 がサブエージェントを
# 全廃した同じコミットで上限を 1 件に下げたが、docs/decisions.md は古い数のままで、何も失敗しなかった。
#
# 現に効いている記述それぞれにマーカーを置いて比べる。履歴は触らない（過去を記録する行にマーカーは置かない）。
echo
echo "3 観点の上限が規則と記録で一致しているか検査する"
lens_caps="$(grep -rhoE 'dotagents:lens-cap [0-9]+' \
  "$REPO/skills/_shared/verification.md" "$REPO/docs/decisions.md" 2>/dev/null | grep -oE '[0-9]+')"
lens_n="$(printf '%s\n' "$lens_caps" | grep -c .)"
lens_uniq="$(printf '%s\n' "$lens_caps" | sort -u | grep -c .)"
if (( lens_n < 2 )); then
  err "lens-cap" "3 観点の上限に付いた 'dotagents:lens-cap <n>' マーカーが 2 つ未満 -- skills/_shared/verification.md（規則）と docs/decisions.md（記録）の両方に書く。でないと次の変更がまた記録されない"
elif (( lens_uniq != 1 )); then
  err "lens-cap" "3 観点の上限が規則と記録で食い違う（$(printf '%s ' $lens_caps)）-- docs/decisions.md がスキルの実際にしないレビューを説明することになる"
else
  printf '%s✓%s 3 観点の上限は規則と記録の両方で %s\n' "$c_green" "$c_off" "$(printf '%s\n' "$lens_caps" | head -1)"
fi

# --- 受け付けない所見を並べさせないこと -------------------------------------------
# 6a の対象は critical/irreversible。daa6ad9 はそこに、6a が除外する 2 つの重大度を名指す並べ方の規則を足した。
# モデルは範囲を広げる（同じファイルが禁じるコスト増）か並べ方を捨てる（位置効果の防御を失う）かを黙って選ぶことになる。
echo
echo "反証パスが除外した所見を並べさせていないか検査する"
# 最初の形は `grep -q '<範囲の文>' && <本当の検査>` で、自分の持ち物でない文を言い換えるだけで黙って無効になり、
# 開いたまま失敗した。開くガードレールは無いより悪いので、アンカーは条件にせず主張し、並べ方の検査は 6a の節に絞る
# （「重大度の順」は後ろのバイアスの注記にも出る）。
vf="$REPO/skills/_shared/verification.md"
if [[ -f "$vf" ]]; then
  if ! grep -q '対象は `severity=critical` の所見だけ' "$vf"; then
    err "verify-scope" "skills/_shared/verification.md が、この検査のアンカーの形で 6a の範囲を書かなくなった -- ファイルと一緒に検査も言い換える。でないとアンカーが見つからないことで検査が通る"
  else
    # 6a は自分の見出しから 6b の見出しまで。並べ方の規則は 6a が除外する重大度を名指してはならない。
    sect="$(awk '/^## 6a\./{i=1} /^## 6b\./{i=0} i' "$vf")"
    if grep -A1 '重大度の順' <<<"$sect" | grep -qE '💡|🟡'; then
      err "verify-scope" "6a は critical/irreversible しか受けないのに、並べ方の規則が 💡/🟡 を名指す -- 取るなと言った所見を並べろと言っている"
    else
      printf '%s✓%s 反証パスは受け付ける重大度だけを並べる\n' "$c_green" "$c_off"
    fi
  fi
fi

# --- 経路の裏付けが無くて保留した重大度には、確定させる場所があること ------
# finding-discipline.md は、到達性を示せない所見を膨らませず、低く置いて何で確定するかを書けと言う。6a の対象は
# critical/irreversible で、重大度の観点は「下げることしかできない」。すると低く置いた所見は、見直せる唯一のパスから
# 見えず、見えても引き上げられず、仮置きが判定の顔で出荷された。
#
# 不変条件は文面ではなく継ぎ目: 6a は下げるだけ、6b はどちらの向きにも確定させる。両半分にマーカーを置く。
# 失敗の向きは 2 つとも守る: 6b が確定の役目を失う（穴が再び開く）、6a に引き上げを許して「直す」（同じファイルが禁じる）。
echo
echo "暫定の重大度を確定させるパスがあるか検査する"
vf="$REPO/skills/_shared/verification.md"
if [[ -f "$vf" ]]; then
  sd_markers="$(grep -c 'dotagents:severity-direction' "$vf" || true)"
  if ! grep -q 'dotagents:severity-direction 6a-lowers-only' "$vf" \
    || ! grep -q 'dotagents:severity-direction 6b-settles' "$vf"; then
    err "severity-direction" "skills/_shared/verification.md に 'dotagents:severity-direction' マーカーが足りない（${sd_markers} 個。6a-lowers-only と 6b-settles が要る）-- マーカーが検査そのもので、消すとどのパスが重大度を上げてよいかの守りが消える"
  else
    # アンカーは条件に使わず主張する。言い換えた文は検査を黙って無効にせず、大きく失敗させる（上の並べ方の検査の教訓）。
    a6="$(awk '/^## 6a\./{i=1} /^## 6b\./{i=0} i' "$vf")"
    b6="$(awk '/^## 6b\./{i=1;print;next} /^## /{i=0} i' "$vf")"
    if ! grep -q '下げることしかできない' <<<"$a6"; then
      err "severity-direction" "6a が、重大度の観点は下げることしかできないと書かなくなった -- ファイルと一緒に検査も言い換える。でないとアンカーが見つからないことで検査が通る"
    elif ! grep -q '暫定の重大度を確定させる' <<<"$b6"; then
      err "severity-direction" "6b が暫定の重大度を確定させる役目を失った -- 到達性の裏付けが無くて低く置いた所見を仕上げるパスが無くなり、仮置きが判定として出荷される"
    elif ! grep -q 'ここでは引き上げてよい' <<<"$b6"; then
      err "severity-direction" "6b は確定を書くが引き上げを許さなくなった -- 下げるだけの確定では、偽陰性の側の穴が開いたまま"
    elif grep -qE '引き上げてよい|引き上げられる' <<<"$a6"; then
      err "severity-direction" "6a が重大度の引き上げを許している -- 反証パスの中での引き上げは同じファイルが禁じている。暫定の重大度は 6b で確定させる"
    else
      printf '%s✓%s 6a は下げるだけで、6b が暫定の重大度を確定させる\n' "$c_green" "$c_off"
    fi
  fi
fi

# --- 何にも数えられない切り捨ては、40 ファイル閾値と同じ形 ---------------
# 発見フェーズは以前 warning/info を「クラスタごとに重大度で上位 3 件」に絞っていた。報告側がすでに上限を持ち、
# 溢れを集計の注記に畳み、🔬 が反証・確信度不足を数える。4 件目はそのどれより前に捨てられ、どこにも数えられなかった。
# 外側がすでに開示している上限の内側にもう 1 つ置くと、情報を消すだけ。出力に見えず、報告が完全に見える。
echo
echo "発見フェーズに開示されない順位の上限が無いか検査する"
fd="$REPO/skills/_shared/finding-discipline.md"
if [[ -f "$fd" ]]; then
  # 1 つの言い回しは上限の書き方の 1 つにすぎない。実際に戻ってきた形を並べる。
  if grep -qiE '(top|highest|first|best) [0-9]+ per cluster|cap [^.]{0,30} (at|to) [0-9]+ per cluster|[0-9]+ per cluster by severity|クラスタ(ごと|あたり)[^。]{0,20}(上位|最大|先頭) ?[0-9]+' "$fd"; then
    err "find-rank-cap" "発見フェーズがまた順位で所見を絞っている -- 順位の上限が捨てたものは誰も数えない。report-format.md の出力予算を使えば、溢れは読み手に見える注記に畳まれる"
  else
    printf '%s✓%s 発見フェーズは、どの枠にも数えられないものを捨てない\n' "$c_green" "$c_off"
  fi
fi

# --- 振り分けを、実行時に何も読まないファイルにだけ置かないこと ----------------
# README.md だけが「spec をディスクに（リポジトリが openspec を使うならそちら）」と書いていた。README.md は実行時に
# 読まれない（AGENTS.md から `@` で取り込んでいない）ので、毎回括弧書きが無視され、上流の既定の場所に計画が書かれた。
# 効かない場所に書いた規則はエラーを出さず、古い振る舞いを出すだけ。
#
# 封じ込めとして、ドキュメントが振り分けの根拠とするものはスキル本文にも書かせる。フィールドは `spec_system` で、
# スキーマでの宣言とスキルでの読み取りの両方向を見る（誰も読まないプロファイルのフィールドも同じ失敗）。
echo
echo "spec システムの振り分けが読まれる場所で効いているか検査する"
spec_bad=""
docs_mention="$(grep -rlF 'openspec' "$REPO/README.md" "$REPO/docs" 2>/dev/null | head -1)"
# reference ファイルではなく SKILL.md の**本文**。Cursor は ${CLAUDE_SKILL_DIR} を解決できず、reference/ にだけある
# 振り分けはそこで効かない（README に置くのと同じ失敗）。
#
# 最初に当たった本文で止めると、兄弟を見ない（不変条件 7 の失敗）。実際に da-spec の本文でフィールド名を仮の名前に
# 変えたのに、da-design-review 側が本物の名前を持っていて緑だった。共有ファイルを使う本文はすべてフィールドを名指すこと。
skill_mention=""
spec_partial=""
for smf in "$REPO"/skills/*/SKILL.md; do
  [[ -e "$smf" ]] || continue
  sbody="$(awk 'NR==1&&$0=="---"{i=1;next} i&&$0=="---"{i=0;next} !i' "$smf")"
  grep -qF 'spec-system.md' <<<"$sbody" || continue      # これで振り分けるスキルではない
  if grep -qF 'spec_system' <<<"$sbody"; then
    skill_mention="$smf"
  else
    spec_partial="$spec_partial $(basename "$(dirname "$smf")")"
  fi
done
if [[ -n "$spec_partial" ]]; then
  spec_bad="次のスキルは reference/spec-system.md を読むのに spec_system フィールドを名指さない:$spec_partial -- フィールド名を変えたり仮の名前にしたりした本文は、どのプロファイルにも無いキーを指す"
elif [[ -n "$docs_mention" && -z "$skill_mention" ]]; then
  spec_bad="ドキュメントは spec システムで振り分けるが、それを読むスキル本文が無い"
elif [[ -n "$skill_mention" ]] && ! grep -qF '"spec_system"' "$REPO/profiles/_schema.json" 2>/dev/null; then
  spec_bad="スキルは spec_system を読むがプロファイルのスキーマが宣言していないので、additionalProperties:false がそれを設定したプロファイルをすべて弾く"
fi
if [[ -n "$spec_bad" ]]; then
  err "spec-system" "$spec_bad -- README.md は実行時に読まれないので、そこにだけ書いた振り分けは振り分けではない"
else
  printf '%s✓%s spec システムの振り分けはスキル本文に書かれ、スキーマで宣言されている\n' "$c_green" "$c_off"
fi

# --- tier の段は 2 か所に書くので、2 つの写しは同じスキルを名指すこと ---
# README.md と docs/loops.md の両方が M/L の行を持ち、設計フェーズの欄は人が打つスキルを名指す。入口を 1 つリネームした
# 瞬間にずれた（README は /da-spec、loops.md は /writing-plans のまま）。文章は意図して違う（片方は案内、片方は手引き）ので、
# 違ってはならない部分、つまり名指すスキルの集合だけを比べる。
echo
echo "tier の段が両方の写しで同じスキルを名指しているか検査する"
# 行の有無と中身は別の問い。混ぜると、両方で正当に「無し」になった段（XS と S はすでにそう）を行の欠落と報告する。
# 欄の中のエスケープした \| は awk の列を黙ってずらすので、誤読せず大きく拒む。
tier_line() { grep -m1 "^| \*\*$2\*\* |" "$1" 2>/dev/null; }
tier_cell() { awk -F'|' '{print $4}' <<<"$1" | grep -oE '/[a-z][a-z0-9-]+' | sort -u | tr '\n' ' '; }
tier_bad=""
for tier in M L; do
  l_readme="$(tier_line "$REPO/README.md" "$tier")"
  l_loops="$(tier_line "$REPO/docs/loops.md" "$tier")"
  [[ -n "$l_readme" ]] || { tier_bad="$tier_bad $tier(absent-in-README)"; continue; }
  [[ -n "$l_loops"  ]] || { tier_bad="$tier_bad $tier(absent-in-loops)"; continue; }
  case "$l_readme$l_loops" in
    *'\|'*) tier_bad="$tier_bad $tier(escaped-pipe-in-cell)"; continue ;;
  esac
  r_readme="$(tier_cell "$l_readme")"
  r_loops="$(tier_cell "$l_loops")"
  [[ "$r_readme" == "$r_loops" ]] || tier_bad="$tier_bad $tier(README:${r_readme:-none}vs loops:${r_loops:-none})"
done
if [[ -n "$tier_bad" ]]; then
  err "tier-ladder" "tier の設計フェーズが走らせるスキルについて README.md と docs/loops.md が食い違う:$tier_bad -- 片方が、もう片方の廃止したコマンドを打てと言っている"
else
  printf '%s✓%s M と L の tier は README と docs/loops.md で同じスキルを名指す\n' "$c_green" "$c_off"
fi

# --- 変更表は 3 か所に書くので、3 つは 1 つの表であること -------
# 決定 15 は、レビュー報告の「変更内容」を da-pr-describe の「変わること」に意図して揃えた。同じ変更に 2 つの語彙があると
# 読み手が突き合わせる羽目になる。揃いは写しが一致する間だけ本物で、4 列を 3 列に絞った時、3 ファイル中 2 つだけ直しても
# 全部直したのと同じに見えた。
#
# 列はマーカー行で宣言し、文章を解析せずデータを読む（dotagents:dmi-gate や dotagents:lens-cap と同じ形）。
# マーカーを消すと検査が消えるので、欠けていれば黙って飛ばさずエラーにする。
echo
echo "変更表が 3 つの写しすべてで同じ表か検査する"
change_tbl_files="$REPO/skills/_shared/report-format.md $REPO/skills/_shared/review-process-brief.md $REPO/skills/da-pr-describe/reference/pr-template.md"
change_cols=""; change_bad=""
for ctf in $change_tbl_files; do
  [[ -f "$ctf" ]] || { change_bad="$change_bad $(basename "$ctf")(absent)"; continue; }
  marker="$(grep -m1 -oE 'dotagents:change-table \|.*\|' "$ctf" | sed 's/dotagents:change-table //')"
  if [[ -z "$marker" ]]; then
    change_bad="$change_bad $(basename "$ctf")(no-marker)"; continue
  fi
  # マーカーが列を宣言し、その下の表は実際にその列でなければならない。
  hdr="$(grep -A1 -F 'dotagents:change-table' "$ctf" | sed -n '2p' | sed 's/[[:space:]]*$//')"
  [[ "$hdr" == "$marker" ]] || change_bad="$change_bad $(basename "$ctf")(header≠marker)"
  change_cols="$change_cols$marker"$'\n'
done
uniq_cols="$(printf '%s' "$change_cols" | grep -c . )"
distinct="$(printf '%s' "$change_cols" | sort -u | grep -c .)"
if [[ -n "$change_bad" ]]; then
  err "change-table" "変更表の 3 つの写しを比べられない:$change_bad -- 決定 15 は、1 つの変更について読み手が 2 つの語彙を突き合わせずに済むよう揃えた"
elif (( uniq_cols != 3 )); then
  err "change-table" "宣言された変更表は 3 つのはずが $uniq_cols 個 -- 写しの 1 つがマーカーを失い、印の無い写しは失敗せずにずれる"
elif (( distinct != 1 )); then
  err "change-table" "3 つの変更表が違う列を宣言している:$(printf ' %s' $(printf '%s' "$change_cols" | sort -u | tr ' ' '_')) -- 1 か所だけ表を絞るのは、決定 15 が防ぐずれそのもの"
else
  printf '%s✓%s 変更表は 3 つの写しすべてで %s\n' "$c_green" "$c_off" "$(printf '%s' "$change_cols" | head -1)"
fi

# --- スキーマの形と、それを読む指示が一致すること ---------------
# 注入の余地を消すため profiles/_schema.json の `validate` をシェル文字列から argv に変えたのに、実行の仕方を教える
# ファイルは「コマンド。change id を差し込む」のまま、素のシェル行を載せていた。スキーマはその指示の形を弾く。
#
# スキーマの型と文章の段落には共有面が無いので、ここで作る: スキーマが配列なら、指示も配列を示し id の制約を持つこと。
echo
echo "検証コマンドの指示がスキーマの形と一致するか検査する"
sch="$REPO/profiles/_schema.json"
ss="$REPO/skills/_shared/spec-system.md"
if [[ -f "$sch" && -f "$ss" ]]; then
  val_is_array="$(node -e '
    try { const v = require(process.argv[1]).properties.spec_system.properties.validate;
          console.log(v && v.type === "array" ? "yes" : "no") } catch { console.log("absent") }
  ' "$sch" 2>/dev/null)"
  case "$val_is_array" in
    yes)
      vbad=""
      grep -qF '["pnpm", "openspec"' "$ss" || vbad="$vbad no-argv-example"
      grep -qF 'a-z0-9._-' "$ss"           || vbad="$vbad no-id-constraint"
      grep -qiE 'refuse an argv whose|`sh`, `bash`' "$ss" || vbad="$vbad no-shell-refusal"
      if [[ -n "$vbad" ]]; then
        err "validate-shape" "スキーマは spec_system.validate を argv と宣言しているのに、skills/_shared/spec-system.md がそう教えていない（${vbad}）-- エージェントが従う指示がスキーマの弾く形を説明し、id がシェルに戻る"
      else
        printf '%s✓%s 検証コマンドの指示はスキーマと一致: argv、id に制約あり、シェルは拒否\n' "$c_green" "$c_off"
      fi ;;
    no)
      err "validate-shape" "spec_system.validate がまたシェル文字列で宣言されている -- プロファイルにパイプラインを持たせず、change id がコマンドに漏れないよう argv にした" ;;
    *)
      printf '%s—%s spec_system.validate の宣言が無い -- 飛ばす\n' "$c_dim" "$c_off" ;;
  esac
fi

# --- スキル本文は認証情報の読み取りやシェルへのパイプを指示しないこと ---
# frontmatter は最初から検査してきたが、本文はしていなかった。本文はデータではなく、利用者のリポジトリで利用者の権限の
# まま従われる指示で、1 文が意図の見えない振る舞いの変更になる。lint フックは書き込み時に同じことを言うが警告だけ。
# こちらは閉じる側の半分で、決めてよいこのリポジトリ自身のスキルに走る。
#
# 形は想像ではなく計測で選んだ: 読む・送る動詞と同じ行に出る認証情報の置き場所と、シェルへのパイプ / base64 /
# 貼り付けサイトの形。既存の本文と reference ファイルに当てて 0 行だったので、基準も差分も許可リストも無しでエラーにできる。
#
# 抜け道はその行に理由を書く。理由なしの「許可」は許可リストが規則になる入口。
#
# hooks/dotagents-lint-skill-frontmatter.sh の一覧と同一に保つ。パターンはここに 2 度書かず下のマーカーコメントから読むので、
# 比べるものと使うものが同じになる。
# dotagents:sensitive-body-patterns (cat|read|open|curl|wget|send|post|upload|include|echo)[^.]{0,40}(~/\.aws|~/\.ssh|\.env\b|id_rsa|\.netrc|credentials|keychain)|(~/\.aws|~/\.ssh|\.env\b|id_rsa|\.netrc|credentials|keychain)[^.]{0,40}(を読|を送|に送|include|report)|\|\s*(ba)?sh\b|base64\s+-d|nc\s+-|webhook\.site|pastebin
echo
echo "スキル本文に認証情報の置き場所やシェルへのパイプの形が無いか検査する"
sens_line() { grep -o 'dotagents:sensitive-body-patterns.*' "$1" | head -1 | sed 's/^dotagents:sensitive-body-patterns *//'; }
sens_pat="$(sens_line "$0")"
if [[ -z "$sens_pat" ]]; then
  err "sensitive-body" "'dotagents:sensitive-body-patterns' マーカーが verify-skills.sh に無い -- マーカーがパターンそのもので、消すと検査も消える"
else
  sens_hits=0
  for sroot in "${ROOTS[@]}"; do
    [[ -d "$sroot" ]] || continue
    while IFS= read -r sf; do
      while IFS= read -r hit; do
        [[ -n "$hit" ]] || continue
        case "$hit" in *dotagents:allow-sensitive*) continue ;; esac
        err "${sf#"$REPO/"}:${hit%%:*}" "スキル本文が認証情報の置き場所か、シェルへのパイプの形を含む -- $(printf '%s' "${hit#*:}" | sed 's/^[[:space:]]*//' | cut -c1-100)"
        sens_hits=$((sens_hits+1))
      done < <(grep -niE "$sens_pat" "$sf" 2>/dev/null)
    done < <(find "$sroot" -type f -name '*.md' 2>/dev/null | sort)
  done
  (( sens_hits == 0 )) \
    && printf '%s✓%s 認証情報の読み取りやシェルへのパイプを指示するスキル本文は無い\n' "$c_green" "$c_off"
fi

# --- 本文の機密検査の 2 つの強制箇所が一致すること ----------------------------
# 下の when 句の一覧と同じ理屈。食い違いうる 2 つの写しは、いずれ食い違う。
# フックは書いている人が出会う方、こちらはコミットを止める方。
lint_hook_sens="$REPO/hooks/dotagents-lint-skill-frontmatter.sh"
if [[ -f "$lint_hook_sens" ]]; then
  echo
  echo "本文の機密パターンの一覧を検査する"
  sens_b="$(sens_line "$lint_hook_sens")"
  if [[ -z "$sens_b" ]]; then
    err "sensitive-body" "'dotagents:sensitive-body-patterns' マーカーが lint フックに無い -- 2 つの一覧を比べられるのはこのマーカーのおかげで、消すと検査も消える"
  elif [[ "$sens_pat" != "$sens_b" ]]; then
    err "sensitive-body" "リンターと lint フックがスキル本文で探すものが違う -- 片方を通った本文がもう片方で止まる"
    printf '%s  linter: %s%s\n' "$c_dim" "$sens_pat" "$c_off"
    printf '%s  hook:   %s%s\n' "$c_dim" "$sens_b" "$c_off"
  else
    printf '%s✓%s 2 つの強制箇所はスキル本文で同じ形を探す\n' "$c_green" "$c_off"
  fi
fi

# --- スキル内の相対リンクはすべて解決すること ----------------------
# reference/ は指示に従って読まれるので、解決しないリンクは利用者に見える 404 ではなく、従えと言われて従えなかった指示になる。
# スキルは読み込まれ、普通に見える報告を出し、失われるのはまさに別に書き留める価値があると誰かが考えた部分。
#
# アンカー、http(s)、mailto は飛ばす。それ以外はリンク元ファイルのディレクトリから解決する。両エージェントが reference の
# パスをそう解決するため（Cursor には ${CLAUDE_SKILL_DIR} が無く、ファイルからの相対が両方で効く唯一の書き方）。
echo
echo "スキル内の相対リンクが解決するか検査する"
link_bad=0
for lroot in "${ROOTS[@]}"; do
  [[ -d "$lroot" ]] || continue
  while IFS= read -r lf; do
    ldir="$(dirname "$lf")"
    while IFS= read -r target; do
      [[ -n "$target" ]] || continue
      case "$target" in http://*|https://*|mailto:*|"#"*) continue ;; esac
      target="${target%%#*}"            # アンカーを剥がす
      target="${target%% *}"            # リンクのタイトルを剥がす
      [[ -n "$target" ]] || continue
      [[ -e "$ldir/$target" ]] || {
        err "${lf#"$REPO/"}" "リンクが解決しない: $target -- reference/ は指示に従って読まれるので、これはエージェントが従えない指示"
        link_bad=$((link_bad+1))
      }
    done < <(grep -o ']([^)]*)' "$lf" 2>/dev/null | sed 's/^](//;s/)$//')
    # `-type f` に加えて `-type l` も要る。`find -type f` は指す先ではなくリンク自体を判定するので、シンボリックリンク
    # （reference/ 配下のファイルはすべてそう）を飛ばす。`-type f` だけだと _shared/ しか見ずに緑を出していた。
  done < <(find "$lroot" \( -type f -o -type l \) -name '*.md' 2>/dev/null | sort)
done
(( link_bad == 0 )) \
  && printf '%s✓%s スキル内の相対リンクはすべて解決する\n' "$c_green" "$c_off"

# --- 逆向き: どのドキュメントにも辿り着けること ------------------
# 上はリンクがファイルを見つけるかを問い、これはファイルにリンクがあるかを問う。誰も参照しないドキュメントは
# 壊れてはいないが見えない。
#
# README.md と AGENTS.md は 2 つの入口で、両エージェントに届く唯一の組（Claude Code は CLAUDE.md のシンボリックリンク経由で
# AGENTS.md を、Cursor はそのまま読み、人は README から始める）。どちらからもリンクされないドキュメントは、パスを
# 知っている人のためにしか存在しない。
echo
echo "すべてのドキュメントに README か AGENTS.md から辿り着けるか検査する"
doc_bad=0
if [[ -d "$REPO/docs" ]]; then
  index="$(cat "$REPO/README.md" "$REPO/AGENTS.md" 2>/dev/null)"
  for df in "$REPO"/docs/*.md; do
    [[ -e "$df" ]] || continue
    rel="docs/$(basename "$df")"
    grep -qF "$rel" <<<"$index" || {
      err "$rel" "README.md からも AGENTS.md からもリンクされていない -- 誰も参照しないドキュメントは誰にも見つからず、リンク検査にも CI にも見えない"
      doc_bad=$((doc_bad+1))
    }
  done
fi
(( doc_bad == 0 )) \
  && printf '%s✓%s docs/*.md はすべて README.md か AGENTS.md からリンクされている\n' "$c_green" "$c_off"

# --- 別のスキルを名指すスキルは、そこへ届くこと ---------------
# このマシンで 3 つ同時に起きており、どれも同じく黙って壊れた: 参照元は読み込まれ、メニューに出て、走るが、
# 中心にした指示が何も指していない。
#
#   grill-me             -> /grilling                                    （本文はその 1 行だけ）
#   executing-plans      -> superpowers:finishing-a-development-branch   （REQUIRED SUB-SKILL と宣言）
#   systematic-debugging -> superpowers:verification-before-completion
#
# この検査がある理由は 1 つ目: `/grill-me` は README のユースケース 1 の最初の項目で、機能を始める公式の手順が
# インストールされていないスキルを指していた。動かない推奨は、守らないガードレールと同じ形で、無いより悪い。
# そのラッパーは今は文書化された集合に無い（決定 38）。動機となった事例として、起きた時の形のまま残す。
#
# このリポジトリではなくインストール済みの集合を見る。宙に浮いた参照はすべて上流の本文にあった。
# そのディレクトリが無ければ理由を出して飛ばす。CI にはインストール済みのスキルが無く、黙って何もしない検査こそ直す対象。
#
# dotagents:builtin-slash-commands clear login logout help doctor config hooks permissions review security-review simplify code-review run init loop goal schedule skill-doctor compact resume model agents mcp memory export bug cost status context usage sandbox privacy-settings rewind todos output-style statusline feedback plugin workflows fast effort tasks add-dir ide vim terminal-setup install-github-app pr-comments upgrade release-notes migrate-installer
#
# この許可リストは組み込みコマンドで、スキルではなくディレクトリに解決しない。新しいものが出れば足す必要がある。
# 失敗の向きは意図的: 足りない項目は 1 件の大きな誤検知になり、黙った穴にはならない。
echo
echo "スキルが名指すスキルにすべて届くか検査する"
INSTALLED="${DOTAGENTS_INSTALLED_SKILLS:-$HOME/.agents/skills}"
if [[ ! -d "$INSTALLED" ]]; then
  printf '%s—%s %s にインストール済みのスキルが無い -- 飛ばす（これはマシン上で走り、CI では走らない）\n' \
    "$c_dim" "$c_off" "$INSTALLED"
else
  builtins="$(grep -m1 'dotagents:builtin-slash-commands' "${BASH_SOURCE[0]}" \
              | sed 's/.*dotagents:builtin-slash-commands //')"
  ref_bad=0
  for sf in "$INSTALLED"/*/SKILL.md; do
    [[ -e "$sf" ]] || continue
    from="$(basename "$(dirname "$sf")")"
    body="$(awk 'NR==1&&$0=="---"{i=1;next} i&&$0=="---"{i=0;next} !i' "$sf")"
    # `superpowers:skill-name` と `/skill-name`。実際の 3 件に両方の形が出た。
    # `anthropic-skills:` は意図して追わない。プラグインの名前空間で、プラグインのスキルはインストール済み集合の
    # ディレクトリではない（da-skills-audit が名指す anthropic-skills:skill-creator は届く）。
    while read -r ref; do
      [[ -n "$ref" ]] || continue
      [[ "$ref" == "$from" ]] && continue                      # 自分自身を名指す
      printf '%s\n' $builtins | grep -qx "$ref" && continue    # スキルではなく組み込みコマンド
      [[ -d "$INSTALLED/$ref" ]] && continue
      err "$from" "スキル '$ref' を名指すが、インストールされていない -- それを中心にした指示が何も指していない。インストールする: npx skills@1.5.20 add <owner>/<repo> -g -a claude-code -a cursor -s $ref"
      ref_bad=$((ref_bad+1))
    done < <( {
      printf '%s\n' "$body" \
        | grep -oE '(^|[^a-zA-Z0-9_./-])superpowers:[a-z][a-z0-9]*(-[a-z0-9]+)+' \
        | sed 's/.*://'
      printf '%s\n' "$body" \
        | grep -oE '(^|[^a-zA-Z0-9_./`-])/[a-z][a-z0-9]*(-[a-z0-9]+)+' \
        | sed 's|.*/||'
      printf '%s\n' "$body" \
        | grep -oE '`/[a-z][a-z0-9]*(-[a-z0-9]+)+`' | tr -d '`' | sed 's|^/||'
    } | sort -u )
  done
  (( ref_bad == 0 )) \
    && printf '%s✓%s インストール済みのスキルが名指すスキルはすべて解決する\n' "$c_green" "$c_off"
fi

# --- status が報告する上流スキルは、まだ文書化されていること ---------
# `setup.sh status` は、文書化された流れに要るのに無い上流スキルを報告する。その一覧が役に立つのは、README.md が実際に
# 入れろと言うスキルを名指す間だけ。上流でリネームされると、誰も文書化しない名前を探し続け、置き換えた方には黙る。
setup_sh="$REPO/scripts/setup.sh"
if [[ -f "$setup_sh" ]]; then
  echo
  echo "上流の流れのスキルが文書化されているか検査する"
  up_line="$(grep -o 'dotagents:upstream-flow-skills.*' "$setup_sh" | head -1 | sed 's/^dotagents:upstream-flow-skills *//')"
  if [[ -z "$up_line" ]]; then
    err "upstream-flow" "'dotagents:upstream-flow-skills' マーカーが scripts/setup.sh に無い -- 一覧を検査できるのはこのマーカーのおかげで、消すと検査も消える"
  else
    up_undocumented=""
    for up in $up_line; do
      grep -q -- "$up" "$REPO/README.md" || up_undocumented="$up_undocumented $up"
    done
    if [[ -n "$up_undocumented" ]]; then
      err "upstream-flow" "status が README.md の一度も触れないスキルを報告している:$up_undocumented -- インストール方法を書くか、報告をやめる"
    else
      printf '%s✓%s status が報告する上流スキルはすべて README.md に名前がある\n' "$c_green" "$c_off"
    fi
  fi
fi

# --- いつ使うかの 2 つの強制箇所が一致すること -----------------------------
# 本ファイルは説明文に when 句が無いと警告し、lint フックは書いている人に同じことを言う。以前はフックの方が厳しく、
# 日本語の句を受けなかったので、lint を通った説明文がフックの権限プロンプトで止まった（無人実行では特に悪い）。
# 1 つの一覧・2 つの言語。文章で求めたせいでずれたので、機械的に検査する。
lint_hook="$REPO/hooks/dotagents-lint-skill-frontmatter.sh"
if [[ -f "$lint_hook" ]]; then
  echo
  echo "いつ使うかのトークン一覧を検査する"
  tok_line() { grep -o 'dotagents:when-clause-tokens.*' "$1" | head -1 | sed 's/^dotagents:when-clause-tokens *//'; }
  tok_a="$(tok_line "$0")"
  tok_b="$(tok_line "$lint_hook")"
  if [[ -z "$tok_a" || -z "$tok_b" ]]; then
    err "when-tokens" "'dotagents:when-clause-tokens' マーカーが $( [[ -z "$tok_a" ]] && echo verify-skills.sh || echo lint フック ) に無い -- 2 つの一覧を比べられるのはこのマーカーのおかげ"
  elif [[ "$tok_a" != "$tok_b" ]]; then
    err "when-tokens" "リンターと lint フックが受け付けるいつ使うかのトークンが違う -- 片方を通った説明文がもう片方で止まる"
    printf '%s  linter: %s%s\n' "$c_dim" "$tok_a" "$c_off"
    printf '%s  hook:   %s%s\n' "$c_dim" "$tok_b" "$c_off"
  else
    printf '%s✓%s 2 つの強制箇所は同じきっかけのトークンを受け付ける: %s\n' "$c_green" "$c_off" "$tok_a"
  fi
fi

# --- エージェント ----------------------------------------------------------------
# エージェントを名前で呼ぶスキルは、そのエージェントが無いと黙って壊れる。呼び出し側は general-purpose に落ち、
# エージェント定義が持っていた姿勢がそのまま無くなる。
if [[ -d "$REPO/agents" ]]; then
  echo
  echo "エージェントを検査する"
  agent_defs=""
  for af in "$REPO"/agents/*.md; do
    [[ -f "$af" ]] || continue
    aid="$(basename "$af" .md)"
    agent_defs="$agent_defs $aid"
    afm="$(awk 'NR==1&&$0=="---"{i=1;next} i&&$0=="---"{exit} i' "$af")"
    grep -q '^name:' <<<"$afm" || err "agents/$aid" "frontmatter に 'name' が無い"
    grep -q '^description:' <<<"$afm" || err "agents/$aid" "frontmatter に 'description' が無い"
    [[ "$(grep '^name:' <<<"$afm" | sed 's/^name:[[:space:]]*//')" == "$aid" ]] \
      || err "agents/$aid" "frontmatter の 'name' がファイル名と違う -- Cursor は一致を要求する"
    # エージェントはモデルを固定してはならない。固定は利用者がセッションに選んだモデルを黙って上書きし、プロンプトにも
    # 記録にも出ない。トークン最適化として一度出荷され、差し戻された。次にコストを測る人がまた持ち込みやすい。
    # スキルの `model:` と違い Claude 専用ではない: Cursor もサブエージェントの model を読み既定は `inherit` なので、
    # 両エージェントで利用者を上書きする。コストは何で走らせるかではなく、何個走らせるかで削る。
    amodel="$(grep '^model:' <<<"$afm" | sed 's/^model:[[:space:]]*//')"
    if [[ -n "$amodel" && "$amodel" != "inherit" ]]; then
      err "agents/$aid" "'model: $amodel' を固定している -- 利用者がセッションに選んだモデルを黙って上書きする。'model: inherit' を使う"
    fi
    # Cursor は name/description/model/readonly しか読まないので、`tools:` だけで書いた制限はそこに無い。本文にも書くこと。
    if grep -q '^tools:' <<<"$afm"; then
      abody="$(awk 'NR==1&&$0=="---"{i=1;next} i&&$0=="---"{i=0;next} !i' "$af")"
      grep -qiE 'read-only|never modify|do not modify|読み取り専用|変更しない' <<<"$abody" \
        || warn "agents/$aid" "'tools:' を宣言しているが本文が制限を書いていない -- Cursor は 'tools:' を無視する"
    fi
  done
  # テンプレートのプレースホルダーはリネームの罠: `x-review-<layer>` は本物の呼び出し指示なのに、名前での一括置換に
  # 当たらず、2 度壊れた。そうしたプレースホルダーの接頭辞を主張する。
  while read -r ph; do
    [[ -n "$ph" ]] || continue
    err "placeholder" "'$ph' は接頭辞の誤った呼び出し先を名指す -- 内部スキルは x-* なので、実名での一括置換では直らない"
  done < <(grep -rhoE '`da-review-<[a-z]+>`' "$REPO"/skills/*/SKILL.md 2>/dev/null | sort -u)

  # _shared/ に対応物があるものは、それへのシンボリックリンクでなければならない。以前は写しで、写しがずれ、_shared/ に
  # 書いた要件がレビュー系スキルのどれにも届かなかった。古い写しも妥当なファイルなので何も報告しない。
  # 中身ではなく仕組みを主張する。今日一致している写しは明日ずれる。
  for shared in "$REPO"/skills/_shared/*.md; do
    [[ -f "$shared" ]] || continue
    sname="$(basename "$shared")"
    for user in "$REPO"/skills/*/reference/"$sname"; do
      [[ -e "$user" || -L "$user" ]] || continue
      rel="${user#"$REPO"/skills/}"
      if [[ ! -L "$user" ]]; then
        err "_shared" "$rel は _shared/$sname の写しで、シンボリックリンクではない -- _shared/ を直しても届かず、それを報告するものも無い"
      elif [[ "$(readlink "$user")" != "../../_shared/$sname" ]]; then
        err "_shared" "$rel が ../../_shared/$sname ではなく '$(readlink "$user")' を指している"
      fi
    done
  done

  # 見えない文字。Unicode Tag（U+E0000-E007F）は何も表示されず、人のレビュアーに見えない指示を運ぶ（エージェント向け
  # スキルの密輸の手口として知られる）。Bidi の上書きは行を実際と逆の意味に読ませうる。このリポジトリは公開で PR を
  # 受けるので、空に見える差分が空でないことを許さない。パターンを説明するファイル内の U+FE0F と U+200B は想定内。
  while read -r bad; do
    [[ -n "$bad" ]] || continue
    err "unicode" "$bad"
  done < <(python3 - "$REPO" <<'PYEOF'
import pathlib, sys, unicodedata
root = pathlib.Path(sys.argv[1])
BAD = {
    "Unicode Tag": lambda o: 0xE0000 <= o <= 0xE007F,
    "bidi override": lambda o: 0x202A <= o <= 0x202E or 0x2066 <= o <= 0x2069,
    "zero-width": lambda o: o in (0x200B, 0x200C, 0x200D, 0xFEFF),
    "private use": lambda o: 0xE000 <= o <= 0xF8FF,
}
for f in sorted(root.rglob("*.md")):
    if ".git" in f.parts:
        continue
    try:
        text = f.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        continue
    for label, test in BAD.items():
        hits = sorted({ord(c) for c in text if test(ord(c))})
        if not hits:
            continue
        if label == "zero-width" and "injection" in f.name:
            continue
        codes = " ".join(f"U+{h:04X}" for h in hits[:4])
        print(f"{f.relative_to(root)} が {label} の文字を含む（{codes}）-- レビュアーには見えず、モデルには読める")
PYEOF
)

  # スキルが名指すエージェントはすべて存在すること。無いと呼び出しがエラーなしで劣化する。
  while read -r ref; do
    [[ -n "$ref" ]] || continue
    [[ " $agent_defs " == *" $ref "* ]] && continue
    err "agents" "スキルは '$ref' に振るが agents/$ref.md が無い -- 呼び出し側は黙って general-purpose に落ちる"
  done < <(grep -rhoE '\b(x-review-verifier|x-codebase-explorer)\b' "$REPO"/skills/*/SKILL.md "$REPO"/skills/_shared/*.md 2>/dev/null | sort -u)
  printf '%s✓%s 定義済みのエージェント %s 個:%s\n' "$c_green" "$c_off" "$(printf '%s' "$agent_defs" | wc -w | tr -d ' ')" "$agent_defs"
fi

# 口調のプロファイルはツールキットの直下にあるが、それを名指すスキルは既定でファイルを `reference/` 配下に並べる。
# その既定を当てた読み手は `reference/profiles/review-voice.md` を探して見つけられず、プロファイルが無いと報告する
# （実際に起き、下書きが手で再構成した口調で書かれた）。なのでパスはどこでも直下からの相対で書き、`reference/` 相対の形は禁じる。
voice_path() {
  local bad rc=0
  bad="$(grep -rn 'reference/profiles/review-voice' "$REPO"/skills 2>/dev/null || true)"
  if [[ -n "$bad" ]]; then
    err "voice-profile" "口調のプロファイルはツールキットの直下にあり、スキルの reference/ 配下ではない:"
    printf '%s\n' "$bad" | sed 's/^/      /'
    rc=1
  fi
  # 言及はすべて直下からの相対の `profiles/review-voice.md` であること。ディレクトリ無しの `review-voice.md` も同じ誤読を招く。
  bad="$(grep -rn 'review-voice\.md' "$REPO"/skills 2>/dev/null \
         | grep -v 'profiles/review-voice\.md' || true)"
  if [[ -n "$bad" ]]; then
    err "voice-profile" "口調のプロファイルは 'profiles/review-voice.md'（直下からの相対）で引用する:"
    printf '%s\n' "$bad" | sed 's/^/      /'
    rc=1
  fi
  # 例は出荷し続けること。pr-comments.md の「止まって聞く」がコピーを勧めるのはこれ。
  if [[ ! -f "$REPO/profiles/_example.review-voice.md" ]]; then
    err "voice-profile" "profiles/_example.review-voice.md が無い -- pr-comments.md は利用者にこれをコピーするよう言う"
    rc=1
  fi
  return $rc
}
if voice_path; then
  printf '%s✓%s 口調のプロファイルはどこでも直下からの相対で引用されている%s\n' "$c_green" "$c_off" "${c_dim}${c_off}"
fi

echo
if (( desc_total > MAX_DESC_TOTAL )); then
  warn "budget" "説明文の合計が ${count} スキルで ${desc_total} 文字（目標は ${MAX_DESC_TOTAL} 以下）"
else
  printf '%s✓%s 予算: 説明文 %s 文字、%s スキル%s\n' \
    "$c_green" "$c_off" "$desc_total" "$count" "${c_dim}${c_off}"
fi

echo
if (( errors )); then
  printf '%sエラー %d 件、警告 %d 件%s\n' "$c_red" "$errors" "$warnings" "$c_off"
  exit 1
fi
printf '%s✓ %d スキル OK%s%s\n' "$c_green" "$count" \
  "$( (( warnings )) && printf '、警告 %d 件' "$warnings")" "$c_off"
