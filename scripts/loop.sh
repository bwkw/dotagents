#!/usr/bin/env bash
# 設計 → 実装 → レビュー → landing ごとに積み重ねた PR 1 本、を駆動する。
#
#   loop.sh "<やりたいこと>"        普段使うのはこれだけ。今どの段階でも 1 歩進める
#   loop.sh size "<やりたいこと>"   変更を測り、どの tier かを出す
#   loop.sh design                  設計フェーズ。次に打つものと、検証できるものを出す
#   loop.sh run [<landing-plan>]    landing を回す（tier S より上は plan が必須）
#   loop.sh report [--json]         採用された landing あたりのコストと、お金の行き先
#   loop.sh status                  直近の size の判定と、ゲートの状態
#
# このスクリプトは人が打つものを打つだけで、新しいエージェントではない。ここの `claude -p` はすべて
# ユーザーのプロンプトなので、`disable-model-invocation` 付きのスキルもその項目を外さずに呼べる（止めるのは
# モデルによる呼び出しで、人の打鍵ではない）。
#
# 読まない打ち手は理解負債を生む。台帳（ledger）は、誰も開かないトランスクリプト以外に読むものを残すためにある。
#
# 破らない規則が 3 つある:
#
#   1. 作業が正しいかは決めない。決めるのは `gate.sh verify`。レビューの所見は人への材料で、合否ではない
#      （LLM のレビューゲートは周回を増やすほど承認率だけが上がり、正しさは上がらなかった）。だからレビューは上限付き。
#   2. ゲートを再実装しない。`gate.sh verify --json` と `gate.sh status --json`（どちらも駆動系向けと明記）を読む。
#   3. **このリポジトリでは**採点器を編集しない。ここでは採点されるものと採点するものが同じチェックアウトなので、
#      profiles/、hooks/、ゲート、チェック実行器、このスクリプト、scripts/test-*.sh に触れた周は landing を止める。
#      ゴールポストを動かすのが人の行為でなければ、緑に意味がない。
#
#      **守っているのは dotagents 自身のパスだけ。** 他のリポジトリでは何にも当たらないので、失敗していた
#      テストを周が編集・削除すればゲートは正当に緑になる。リポジトリごとに宣言できるようにする件は
#      docs/fix-plans/2026-08-11-loop-driver.md に follow-up として記録してある。
#
# tier XS と S は無人で最後まで回る。`/grilling` は面談で、`da-design-review` は最初のステップで
# 「ユーザーに見せる」と言うので、どちらも人が要る。tier の違いは人がどこまで深く入るかで、居るかどうかではない。
#
# 未検証（ただし結果に依存しない書き方にしてある）: `claude -p` のターン終了で Stop hook が発火するか。
# 発火すればゲートが試行を数えて max_attempts で VERDICT を書き、駆動系がそれを読む。発火しなければ VERDICT は
# 出ず、駆動系自身の周回上限が landing を止める。どちらも中断し、台帳に*どちらか*が残る。docs/loops.md を参照。

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_SH="$HERE/gate.sh"
LOOP_DIR="${DOTAGENTS_LOOP_DIR:-$HOME/.claude/.dotagents-loop}"
LEDGER="$LOOP_DIR/ledger.jsonl"

# 測った値ではなく決めた値（ゲートの max_attempts 3 や 12h TTL と同じ扱い）。普段使いでコマンドラインに
# 何も渡さずに済むようにここに置く。機械ごとに打ち直すフラグは何も買わない（docs/decisions.md）。
# MAX_ROUNDS は 6 ではなく 3。ゲートの `max_attempts` は 3 で、`attempts` は 1 ターンに 2 ずつ増える（ブロックと
# 再入場の解放）ので、落ち続けるチェックは約 2 周で VERDICT になり `gate_gave_up` が止める。6 では周ごとに*別の*
# チェックが落ちる場合にしか届かず、それは周を足しても収束しない場合。届かない上限は上限ではない。
MAX_ROUNDS=3          # landing ごとの実装の試行回数。超えたら人に返す
REVIEW_ROUNDS=2       # tier M/L のレビュー周回数。3 周目で買えるのは承認で、正しさではない
REVIEW_ROUNDS_LEAN=1     # tier S。最悪ケースの天井で、レビューの深さを削るものではない（run_landing 参照）
MAX_OPEN_PRS=5        # 1 つの stack で開いておく層の数。ボトルネックはレビュアで、エージェントではない
# **15 は好みではなく算数。** このリポジトリの台帳で測った各フェーズの最大値: size $0.74 · implement $4.56 ·
# review $2.07（打ち切りなので実際はもっと上）· triage $0.74 · fix $1.19 · describe $1.50（天井、未到達）。
# 合計で **CI 修正を 1 周もしない時点で $10.8** なので、$10 の run では landing を 1 つも完了できなかった。
#
# 本当に下げるべきは `implement`（上限なし）。run の予算を上げても何も安くならない。これは目標ではなく、
# tier S の landing 1 つの正直なコストとして置いている。
BUDGET_USD=15         # `run` 1 回あたり

# 周ごとの天井。$BUDGET_USD は run 全体を縛るが、これが無いと 1 つのフェーズが run の予算を食い尽くしても
# halt は `budget` としか言わず、どの周がやったかが分からない。
#
# 食い尽くすのはレビューの周。値は測ったものではなく決めたもの: brief 形式（skills/_shared/review-process-brief.md）の
# レビューがかかるはずの額より上で、上限なしのレビューが実際にかかった額より下。
BUDGET_ROUND_REVIEW=5.00     # tier M/L
BUDGET_ROUND_REVIEW_LEAN=3.00   # tier S。安く済ませるためにある tier
# **3.00 は測った値で、2 回上げた。** tier S のレビュー 6 回で $0.88〜$2.07（最後は 2.00 の天井で打ち切り）。
# ばらつきが広がるのは変更ではなく*ファイル*が大きくなるから（レビューは変更行のあるファイルを読む）。だから
# 正しい直し方は数字を上げることではなくファイルを小さくすること。また超えたら、天井ではなく*問い*を上げる。
#
# 上げても何も弱まらない。`truncated` は相変わらず大きな音で止まる。
BUDGET_ROUND_TRIAGE=3.00     # tier M/L
BUDGET_ROUND_TRIAGE_LEAN=0.75   # 11 行の差分でバケット 3 つを数えるのに $2.08 と $1.90 かかった
BUDGET_ROUND_FINDBUGS=3.00   # 2 本目のレビュア、tier M/L
BUDGET_ROUND_FINDBUGS_LEAN=1.50 # tier S
# `size` は tier が決まる前に走るので値は 1 つ。測るのにお金がかかるのはよいが、作業より高くついてはいけない。
BUDGET_ROUND_SIZE=1.25
# 1 回しか測っていない（$1.55）。値は数字ではなく非対称性で決めた: 低すぎると PR 本文がまるごと失われて
# landing は続き（`opened-pr-partial-body` は止まらない）、高すぎてもお金がかかるだけで `truncated` として表に出る。
# 1 サンプルでは決められないので、同じ種類の作業の値を使う。
BUDGET_ROUND_PR=2.50         # PR 本文を 1 つ書く。COMMENTS と同じ種類の作業なので同じ値
BUDGET_ROUND_CI=2.00         # 赤い CI への 1 回の試み
BUDGET_ROUND_COMMENTS=2.50   # 人のレビューコメント 1 周分への対応
BUDGET_ROUND_REPLY=1.00      # 返信の作文（投稿は周ではなく駆動系の仕事）

# PR を開いた後。
CI_ATTEMPTS=2         # 赤い CI への修正の試行回数。超えたら人の問題
CI_WAIT_SECONDS="${DOTAGENTS_LOOP_CI_WAIT:-900}"    # pending のチェックが落ち着くまで待つ秒数
CI_GRACE_SECONDS="${DOTAGENTS_LOOP_CI_GRACE:-120}"  # push 後にチェックが*現れる*まで待つ秒数

# **tier S の値はわざときつい。安全なのは、超えたときに大きな音が出るから。** `truncated` が無かった頃は、
# 途中で切られた周が exit 0 と部分的な答えを返して `advanced` と記録され、書きかけの所見がそのまま triage に
# 渡った。今は天井に当たると landing が止まり台帳に残る。きつすぎれば見える halt と上げるべき数字、緩すぎれば
# $6.19 と PR 手前で死ぬ run、とリスクの向きが逆になった。
#
# これらの値のために削っていないもの: 常にカバーする 5 つのクラスタ、80 点の閾値、新しい検証役 1 人。
# どれもレビュースキルの側にあり、`review-process-brief.md` が 3 つとも保っている。

# claude 2.1.148 で測った: `--json-schema` はあり、スキーマを*インライン JSON 文字列*で受け取る。ファイルパスを
# 渡すとエラーにならず、stdin を閉じたまま永久に*固まる*。下の締め切りが必須なのはこのため（固まるのは
# 周回上限・予算・ゲートのどれも止められない唯一の失敗）。
SCHEMA_FLAG="--json-schema"

# 測った: `claude --print --permission-mode acceptEdits` は無人の run で git を実行できない（"This command requires
# approval" が返り、承認する人がいないので拒否される）。`/da-review-all` の Step 1 は `git diff` なので、許可が
# 無いとレビューの周は範囲すら確定できない。
#
# **読み取り専用のものを列挙する。** `Bash(git:*)` だと `git diff` のために `git push`・`git reset --hard`・
# `git branch -D` まで渡してしまう。commit・branch・push は駆動系が bash でやるので、書き込みが要る周は無い。
#
# `--allowedTools` は許可を*足す*もので、残りを外す allowlist ではない（Edit と Write は acceptEdits のまま使える）。
#
# **どれも素のものと `rtk` 付きの 2 回書く。** 念のためではない。コマンドを書き換える PreToolUse hook は許可の
# 照合より*前*に走るので、`git status` を `rtk git status` に書き換える機械では素のパターンが黙って何にも当たらない。
# hook を検出せず両方を静的に並べるのは、rtk の無い機械でも動く必要があり、探って作る一覧は探りを誤ると新しい
# 形で間違うから。当たらないパターンはコストゼロ。
ROUND_ALLOWED_TOOLS="Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git status:*),Bash(git rev-parse:*),Bash(git symbolic-ref:*),Bash(git ls-files:*),Bash(git diff-tree:*),Bash(gh pr view:*),Bash(rtk git diff:*),Bash(rtk git log:*),Bash(rtk git show:*),Bash(rtk git status:*),Bash(rtk git rev-parse:*),Bash(rtk git symbolic-ref:*),Bash(rtk git ls-files:*),Bash(rtk git diff-tree:*),Bash(rtk gh pr view:*),Grep,Glob"

# `claude -p` 1 回にかけてよい秒数。決めた値で、測っていない。環境変数の上書きはテスト用。
ROUND_TIMEOUT="${DOTAGENTS_LOOP_ROUND_TIMEOUT:-1800}"

if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then c_red=''; c_green=''; c_dim=''; c_off=''
else c_red=$'\033[31m'; c_green=$'\033[32m'; c_dim=$'\033[2m'; c_off=$'\033[0m'; fi

usage() { grep -E '^#   loop\.sh ' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die()   { printf 'loop: %s\n' "$1" >&2; exit 1; }
say()   { printf '%s\n' "$1"; }
dim()   { printf '%s%s%s\n' "$c_dim" "$1" "$c_off"; }

# ---------------------------------------------------------------- 識別
# 台帳は全リポジトリで 1 つで、各行が自分の `repo` と `branch` を持つ（verdicts.log と同じ形）。ここで slug と
# worktree の仕組みをもう 1 つ作ると、すでに 2 か所にある識別の 3 つ目の実装になる。
repo_root() { git rev-parse --show-toplevel 2>/dev/null || pwd; }
branch()    { git rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'HEAD'; }

# 台帳にとっての「どのリポジトリか」で、作業ツリーでは*ない*。`size` は立っているチェックアウトで取られ、`run` は
# linked worktree の中で走ることがあるので、toplevel で引くと run が必要な tier が見えなくなる。ゲートと同じく
# 共有 git dir で識別し、`worktree` は別の項目として残す。
repo_key() {
  local c
  c="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  case "$c" in /*) printf '%s' "$c"; return 0 ;; esac
  repo_root
}

# すでに隔離済みか。`--git-dir != --git-common-dir` で判定するが submodule の中でも真になるので、submodule の
# 確認が先に要る（using-git-worktrees スキルが名指ししている罠）。
in_linked_worktree() {
  local g c
  g="$(git rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
  c="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [[ -n "$g" && -n "$c" && "$g" != "$c" ]] || return 1
  [[ -z "$(git rev-parse --show-superproject-working-tree 2>/dev/null)" ]]
}

default_branch() {
  local b
  b="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')"
  [[ -n "$b" ]] && { printf '%s' "$b"; return 0; }
  printf 'main'
}

# ---------------------------------------------------------------- 台帳
# 追記のみで、切り詰めない。trace.log は設計上 200 行で自分を切り詰めるので、そこにしか無い記録は普通の運用で
# 消える（ゲートはそれで verdicts.log を分けた）。これは計測器なので長く残す側に置く。
ledger_append() { # <波括弧なしの JSON 項目...>  node 経由のキーと値の組
  mkdir -p "$LOOP_DIR" 2>/dev/null || return 0
  node -e '
    const fs = require("fs");
    const [ledger, ...kv] = process.argv.slice(1);
    const o = { ts: new Date().toISOString() };
    for (let i = 0; i < kv.length; i += 2) {
      const k = kv[i]; let v = kv[i + 1];
      if (v === "__null__") v = null;
      else if (/^-?\d+(\.\d+)?$/.test(v)) v = Number(v);
      else if (v === "true" || v === "false") v = v === "true";
      else if (v.startsWith("{") || v.startsWith("[")) { try { v = JSON.parse(v) } catch {} }
      o[k] = v;
    }
    fs.appendFileSync(ledger, JSON.stringify(o) + "\n");
  ' "$LEDGER" "$@" 2>/dev/null || true
}

# このリポジトリで、あるフェーズの最新行。`run` は tier を決め直さずここから読むので、`run` が正面玄関の
# 抜け道にならない。
ledger_last() { # <phase> <field>
  [[ -f "$LEDGER" ]] || return 0
  node -e '
    const fs = require("fs");
    const [ledger, repo, phase, field] = process.argv.slice(1);
    let last = null;
    for (const line of fs.readFileSync(ledger, "utf8").split("\n")) {
      if (!line.trim()) continue;
      try { const o = JSON.parse(line); if (o.repo === repo && o.phase === phase) last = o } catch {}
    }
    if (last && last[field] != null) process.stdout.write(String(last[field]));
  ' "$LEDGER" "$(repo_key)" "$1" "$2" 2>/dev/null || true
}

# ---------------------------------------------------------------- 採点
# 合否を決めるものすべて。これを編集した周は受けている試験を変えたことになるので landing を止める。わざと広い:
# このリポジトリでは仕組みの大半が scripts/ と hooks/ にあるので、ループが合法に触れるのは skills/、docs/、
# agents/、templates/ と最上位の Markdown になる。実際の制約で、docs/loops.md に書いてある。
scorer_paths() {
  printf '%s\n' profiles hooks scripts/gate.sh scripts/check.sh scripts/verify-skills.sh \
                scripts/loop.sh scripts/test-loop.sh
  git ls-files 'scripts/test-*.sh' 2>/dev/null
  [[ -n "${PLAN_PATH:-}" ]] && printf '%s\n' "$PLAN_PATH"
  return 0
}

# git がそもそも答えられるか。`changed_paths` はツリーがきれいなときも git が失敗したとき（index.lock、
# dubious ownership、work tree でない cwd）も空を返し、4 つの利用側はどれも空を無害な答えと読む。だから読めるかを
# 先に別に聞く。
tree_readable() { git status --porcelain -z >/dev/null 2>&1; }

# 作業ツリーで変わったもの（追跡・未追跡とも）をリポジトリ相対パスで返す。
#
# rename は*両方*のパスを返す。採点器のチェックは、守っているファイルが移動したことを見る必要がある。`-z` では
# rename は NUL 区切りの 2 項目（ステータス付きの新パス、続いて接頭辞なしの旧パス）で、" -> " は `-z` なしの出力に
# しか無い。旧パスを壊すと `git mv scripts/gate.sh gate-old.sh` でゲートをどけた周を止められない。
changed_paths() {
  git status --porcelain -z 2>/dev/null | node -e '
    let s = "";
    process.stdin.on("data", (d) => s += d).on("end", () => {
      const fields = s.split("\0");
      const out = [];
      for (let i = 0; i < fields.length; i++) {
        const e = fields[i];
        if (!e) continue;
        const xy = e.slice(0, 2);
        out.push(e.slice(3));
        // どちらかの列が R か C なら次の項目は元のパス。ここで消費し、独立したエントリとして読まない。
        if (xy[0] === "R" || xy[0] === "C" || xy[1] === "R" || xy[1] === "C") {
          i++;
          if (fields[i]) out.push(fields[i]);
        }
      }
      if (out.length) process.stdout.write(out.join("\n") + "\n");
    });
  ' 2>/dev/null || true
}

scorer_touched() { # -> 違反したパスを改行区切りで。きれいなら空
  local changed sp
  tree_readable || { printf '<作業ツリーを読めなかった>\n'; return 0; }
  changed="$(changed_paths)"
  [[ -n "$changed" ]] || return 0
  sp="$(scorer_paths)"
  # 守る一覧はプロセス置換ではなく argv で渡す。`<(...)` の /dev/fd パスを readFileSync で読めるかは環境次第で、
  # 読めないと「何も触っていない」というフェイルオープンの答えになる（フェイルクローズであるべきチェックで）。
  printf '%s\n' "$changed" | node -e '
    const guarded = process.argv[1].split("\n").filter(Boolean);
    let s = "";
    process.stdin.on("data", (d) => s += d).on("end", () => {
      const hits = s.split("\n").filter(Boolean).filter((p) =>
        guarded.some((g) => p === g || p.startsWith(g.replace(/\/*$/, "") + "/")));
      if (hits.length) process.stdout.write([...new Set(hits)].join("\n") + "\n");
    });
  ' "$sp" 2>/dev/null || true
}

# ---------------------------------------------------------------- ゲート
gate_verify_ok() { # -> gating チェックが実際に*走り*、緑だったときだけ 0
  local out
  out="$(bash "$GATE_SH" verify --json 2>/dev/null)"
  GATE_JSON="$out"
  # 空は「作業に問題なし」ではなく gate.sh か node の失敗。以降のヘルパーは $GATE_JSON を読み、空の文書には
  # どれも無害に答えてしまう。
  [[ -n "$out" ]] || { GATE_UNRAN="unreadable"; return 1; }
  # `ok: true` は「検証済み」ではない（一度も実行されなかったチェックも、通ったチェックと同じ報告をする）。
  # `verify --json` の `checked` は gating チェックが 1 つでも実際にコマンドを走らせたときだけ true なので、文を
  # 照合せずにそれを聞く。`checked: null` はゲートが答えられなかったということで、yes ではない。
  case "$(gate_json_field checked)" in
    true) GATE_UNRAN="" ;;
    false) GATE_UNRAN="$(gate_json_field skipped_ids)"; GATE_UNRAN="${GATE_UNRAN:-skipped}"; return 1 ;;
    *) GATE_UNRAN="unreadable"; return 1 ;;
  esac

  # `agent_may_run: false` は、リポジトリが*エージェント*にこのチェックの実行を禁じているという意味で、未検証で
  # 出してよいという意味ではない。無人では尋ねる相手がおらず、何周しても満たせないので、待つのも周回も誤り
  # （MAX_ROUNDS を使い切って、どの周にも直せないもので止まる）。
  #
  # だから*先送り*にし、先送りしたことを大きく言う。ローカルのゲートは走らせてよいものを走らせ、CI が残りを
  # 走らせ、PR がどちらかを書く。禁止はそのまま守る（ここでは走らせない）。黙って先送りしてはいけない:
  # 先送りしたゲートは、解放されたゲートと同じく緑ではない。
  local kind; kind="$(node -e '
    let s = "";
    process.stdin.on("data", (d) => s += d).on("end", () => {
      try { const o = JSON.parse(s); if (!o.ok && o.kind) process.stdout.write(String(o.kind)) } catch {}
    });
  ' <<<"$out")"
  if [[ "$kind" == "needs_human" ]]; then
    local id; id="$(gate_field check)"
    case " $GATE_DEFERRED " in *" $id "*) : ;; *) GATE_DEFERRED="${GATE_DEFERRED:+$GATE_DEFERRED }$id" ;; esac
    dim "   $id: このリポジトリがエージェントに実行を禁じている。CI に先送りし、ここでは検証していない"
    return 0
  fi
  node -e '
    let s = "";
    process.stdin.on("data", (d) => s += d).on("end", () => {
      try { process.exit(JSON.parse(s).ok ? 0 : 1) } catch { process.exit(1) }
    });
  ' <<<"$out"
}

gate_field() { # 直近の verify の <field>
  node -e '
    let s = "";
    process.stdin.on("data", (d) => s += d).on("end", () => {
      try { const v = JSON.parse(s)[process.argv[1]]; if (v != null) process.stdout.write(String(v)) }
      catch {}
    });
  ' "$1" <<<"${GATE_JSON:-}" 2>/dev/null || true
}

# profile が無ければ gating チェックも無く、`verify` はそれに ok:true と答えるので `ok` だけは信用できない。
# `verify --json` は解決した profile のパスか、何も一致しなければ null を返す。
#
# 自分で verify を走らせず*直近の* verify を読む。1 回でスイート全体（このリポジトリでは数分）かかるので。
# 先に gate_verify_ok を呼ぶこと。
gate_has_profile() {
  [[ -n "${GATE_JSON:-}" ]] || return 1     # 空は「分からない」で、「yes」ではない
  [[ -n "$(gate_json_field profile)" ]]
}

# 付随項目の読み手を 1 つにし、文の照合に戻らないようにする。`skipped_ids` は合成した値で、ゲートが走らせ
# なかったチェックの id を空白区切りで並べる（halt のメッセージで名指しするため）。
gate_json_field() { # <checked|profile|ran|skipped_ids> -> 値。無いか読めなければ空
  node -e '
    let s = "";
    process.stdin.on("data", (d) => s += d).on("end", () => {
      let o = null; try { o = JSON.parse(s) } catch {}
      if (!o) return;
      const f = process.argv[1];
      if (f === "skipped_ids") {
        const a = Array.isArray(o.skipped) ? o.skipped : [];
        process.stdout.write(a.map((x) => x && x.id).filter(Boolean).join(" "));
        return;
      }
      const v = o[f];
      if (v != null) process.stdout.write(String(v));
    });
  ' "$1" <<<"${GATE_JSON:-}" 2>/dev/null || true
}

gate_gave_up() { # -> VERDICT が記録されていれば 0
  bash "$GATE_SH" status --json 2>/dev/null | node -e '
    let s = "";
    process.stdin.on("data", (d) => s += d).on("end", () => {
      try { process.exit(JSON.parse(s).gave_up ? 0 : 1) } catch { process.exit(1) }
    });
  '
}

# 諦めたチェックが、始める前から落ちていたものと同じかを、諦める場所で言う。言わないと、他人の壊れで全周を
# 使い切った場合と landing 自身の失敗が同じに読める。名前が違うときはわざと黙る: A が赤で始まり B で死んだ
# run は B を壊しているので、それを許すと駆動系が自分に渡す言い訳になる。
inherited_note() {
  [[ -n "${STARTED_RED_CHECK:-}" ]] || return 0
  [[ "$(gate_field check)" == "$STARTED_RED_CHECK" ]] || return 0
  printf '\n  このチェックは run の開始前から**すでに赤かった** —— ループが壊したのではない。直してほしいと頼んだ
  ものか、landing が引き継いだ壊れかのどちらかで、いずれにせよここで何周しても緑にはならず、作業はこの
  チェックに対して検証されていない。'
}

# ---------------------------------------------------------------- 周回
SPENT=0
GATE_UNRAN=""
GATE_DEFERRED=""
ROUND_TIMED_OUT=0
REVIEW_REPORT=""
SECOND_REPORT=""
ROUND_COST=0; ROUND_TURNS=0; ROUND_EXIT=0; ROUND_OUT=""
ROUND_BUDGET=""       # 周ごとの天井（USD）。空は上限なし。呼び出し側が設定し、ここで消す。
ROUND_TRUNCATED=""    # 周を打ち切った subtype。*空*なら最後まで走った。`0` ではない --
ROUND_BAD_KIND=""     # "ceiling" | "error" | "" -- ROUND_TRUNCATED をどう*報告*するか。
ROUND_ERR=""          # 周の stderr（halt で引用する）。
ROUND_LOG_BASE=""     # $LOOP_DIR/rounds/<stamp>-<repo>-<phase>-<pid>。.json と .err をこれに付ける。
ROUND_LOG_DIR=""
                      # これは `-n` で読まれ、文字列 "0" は空ではないので、ここを `0` にすると claude_round を
                      # 経ずに post_round に来た瞬間すべての周が止まる。

# `claude -p` を 1 回。--bare は使わない: hook・スキル・CLAUDE.md を切るスイッチで、ここではそれが仕組みの
# すべて（公式ドキュメントはスクリプトからの呼び出しに勧めるが、このループにとっては手順書の中の唯一のフェイル
# オープン）。--dangerously-skip-permissions も使わない。acceptEdits と profile の `forbidden` 一覧と採点器の
# チェックが封じ込め。
claude_round() { # <prompt> [インラインのスキーマ JSON]
  local prompt="$1" schema="${2:-}" raw out pid t
  # 文字列を引用なしで展開せず*配列*にする。ツールの許可には空白と括弧（`Bash(git diff:*)`）が含まれ、単語分割
  # されると `Bash(git` と `diff:*)` という何にも当たらない 2 つになる。添字配列と `+=` は bash 3.2 で使える
  # （連想配列は不可）ので macOS でも安全。
  local args
  # *順序が効いている。* `--allowedTools` は可変長（`<tools...>`）で次のフラグまで引数を食い、プロンプトは最後の
  # 引数。最後に置くとプロンプトがツール名として食われ、`claude` は "Input must be provided either through stdin
  # or as a prompt argument" で exit 1 する（$0・0 ターンで、フェーズが辞退したように見える）。
  #
  # `--permission-mode` を常に許可の直後に置き、終端を無条件にしている（`--max-budget-usd` がたまたま終端に
  # なっていたので、天井の無い周だけが壊れていた）。
  args=(--print --output-format json)
  args+=(--allowedTools "$ROUND_ALLOWED_TOOLS")
  args+=(--permission-mode acceptEdits)
  # このビルドに --max-turns は無く、周ごとの天井は --max-budget-usd だけ。問題になっているもの（お金）を縛り、
  # プロンプトではなくハーネスが強制するので、こちらの方がよい。
  [[ -n "$ROUND_BUDGET" ]] && args+=(--max-budget-usd "$ROUND_BUDGET")
  [[ -n "$schema" ]] && args+=("$SCHEMA_FLAG" "$schema")
  out="$(mktemp "${TMPDIR:-/tmp}/dotagents-loop-round.XXXXXX")" || die "mktemp に失敗した"

  # 周自身の出力を残す場所と理由。消してしまうと halt が「出力を読め」と言っても出力が残っていない。再診断
  # できない誤診が一番高くつく。
  #
  # LOOP_DIR（$HOME/.claude/.dotagents-loop）の下に置き、チェックアウトの中には置かない。リポジトリに書いた
  # ファイルは何かを編集した周に見え、別の（誤った）halt になる。
  #
  # 刈り込まない。trace.log の自己切り詰めで記録が消えた前例がある（AGENTS.md）。診断材料は予定どおりに蒸発
  # してはいけない。1 周数 KB。
  ROUND_LOG_DIR="$LOOP_DIR/rounds"
  mkdir -p "$ROUND_LOG_DIR" 2>/dev/null || true
  # フェーズは渡されないので、プロンプトの 1 行目（スキル名、つまりフェーズそのもの）から取る。ファイル名に
  # 入るので無害化する。`$$` は 1 回の run の全周で同じなので、ファイルは run ごとにまとまり、その中で時刻順に並ぶ。
  local label; label="$(printf '%s' "${prompt%%$'\n'*}" | tr -cd 'A-Za-z0-9-' | cut -c1-40)"
  ROUND_LOG_BASE="$ROUND_LOG_DIR/$(date -u +%Y%m%dT%H%M%S)-$$-${label:-round}"
  errf="$(mktemp "${TMPDIR:-/tmp}/dotagents-loop-round-err.XXXXXX")" || die "mktemp に失敗した"

  # 時間を区切り、stdin を閉じる。macOS には `timeout` が無いので scripts/test-non-interactive.sh と同じく
  # ポーリングする。stdin を閉じるのは、認証が切れた `claude` が無人では得られないログインを待ち続けるから。
  # stderr は /dev/null ではなくファイルへ: 周が失敗の*理由*を言う場所で、かつ駆動系の出力を読みやすく保つため。
  claude "${args[@]}" "$prompt" >"$out" 2>"$errf" </dev/null &
  pid=$!
  t=0
  ROUND_TIMED_OUT=0
  while (( t < ROUND_TIMEOUT * 5 )); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
    t=$((t + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    # プロセスグループごと。kill された `claude` が起動した道具がポートを掴んだまま残ることがある。
    kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    sleep 1
    kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    ROUND_TIMED_OUT=1
  fi
  wait "$pid" 2>/dev/null; ROUND_EXIT=$?
  (( ROUND_TIMED_OUT )) && ROUND_EXIT=124

  raw="$(cat "$out" 2>/dev/null)"
  ROUND_ERR="$(cat "$errf" 2>/dev/null)"
  # 一時ファイルを消す*前*にコピーし、halt が名指しできるようにパスを残す。`mv` でなく `cp` なので、ここで
  # 失敗しても駆動系がメモリに持っているものは失われない。
  cp "$out" "$ROUND_LOG_BASE.json" 2>/dev/null || true
  [[ -s "$errf" ]] && { cp "$errf" "$ROUND_LOG_BASE.err" 2>/dev/null || true; }
  rm -f "$out" "$errf"
  ROUND_OUT="$raw"
  ROUND_COST="$(node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s).total_cost_usd??0))}catch{process.stdout.write("0")}})' <<<"$raw")"
  ROUND_TURNS="$(node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s).num_turns??0))}catch{process.stdout.write("0")}})' <<<"$raw")"
  SPENT="$(node -e 'process.stdout.write(String(Number(process.argv[1])+Number(process.argv[2])))' "$SPENT" "${ROUND_COST:-0}")"

  # 早く止まった周は exit 0 で*部分的な* `result` を返す。これを見ないと、途中で切れたレビューが `advanced` と
  # 記録され、書きかけの所見が完成品として triage に渡る（モデル自身も切られたことを知らないので、🔎 にも出ない）。
  #
  # *既定で拒否*: "success" 以外の subtype は、後の CLI が作ったものも含めて打ち切り扱い。今日知っている失敗の
  # allowlist は、新しい失敗を黙って受け入れ始める。項目が*無い*のは成功（省くビルドがあり、失敗扱いにすると
  # そこで全周が止まる）。
  ROUND_TRUNCATED="$(node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    try { const o = JSON.parse(s);
      const bad = (o.subtype != null && o.subtype !== "success") || o.is_error === true;
      process.stdout.write(bad ? String(o.subtype ?? "is_error") : "") }
    catch { process.stdout.write("") }})' <<<"$raw")"
  # 天井とエラーは別の失敗。上の検出は既定で拒否のまま、ここで決めるのは呼び方だけ。`error_max_*` は天井
  # （将来の CLI の `error_max_tokens` も天井と読む）。それ以外は、`is_error: true` かつ `subtype: "success"` も
  # 含めてエラーで、何も主張しない。
  #
  # エラーを天井と呼ぶと「その周の天井を上げよ」と助言してしまうが、**BUDGET_ROUND_IMPLEMENT は存在しない**。
  case "$ROUND_TRUNCATED" in
    "")            ROUND_BAD_KIND="" ;;
    error_max_*)   ROUND_BAD_KIND="ceiling" ;;
    *)             ROUND_BAD_KIND="error" ;;
  esac
  ROUND_BUDGET=""   # 1 周に天井 1 つ。漏れると次のフェーズまで黙って縛る。
  return 0
}

# 周の返答テキスト。あるスキルの報告を次のスキルのプロンプトに運ぶのに使う。レビュースキルはファイルを書かない
# ので、所見がプロセス境界を越える手段はこれしかない。
round_result() {
  node -e '
    let s = "";
    process.stdin.on("data", (d) => s += d).on("end", () => {
      try { const r = JSON.parse(s).result; if (r) process.stdout.write(String(r)) } catch {}
    });
  ' <<<"$ROUND_OUT" 2>/dev/null || true
}

round_has_structured() {
  node -e '
    let s = "";
    process.stdin.on("data", (d) => s += d).on("end", () => {
      try { const o = JSON.parse(s); process.exit(o && typeof o.structured_output === "object" && o.structured_output !== null ? 0 : 1) }
      catch { process.exit(1) }
    });
  ' <<<"$ROUND_OUT" 2>/dev/null
}

round_structured() { # <field> -> structured_output の値。無ければ空
  node -e '
    let s = "";
    process.stdin.on("data", (d) => s += d).on("end", () => {
      try { const v = JSON.parse(s).structured_output?.[process.argv[1]];
            if (v != null) process.stdout.write(String(v)) } catch {}
    });
  ' "$1" <<<"$ROUND_OUT" 2>/dev/null || true
}

# ---------------------------------------------------------------- サイズ
TIER=""; M_FILES=0; M_LAYERS=0; M_ONEWAY=0; M_RISK=0; M_UNCONF=0

# モデルが測り、ここが決める。レビューの fan-out に「変更の規模に合わせよ」と書いていた頃は毎回最大が出た
# （確かめられるものが何も無かったため）。モデルが自分で選ぶ tier も、名前が違うだけで同じ失敗。
# 軸は 2 つ。**どれだけ大きいか**でどれだけのプロセスが要るかが決まり、**取り返せない一歩があるか**で人が見る
# べきかが決まる。混ぜると、実際のリポジトリではほぼすべてのバックエンド変更が認可に触れ、/da-investigate は
# ほぼ常に何かを未確認と言うので、全部 L になり tier が情報を持たなくなる。
#
# 各入力の扱い:
#
#   `risk_surfaces` は 2 本目のレビュア（/find-bugs は 0 でないときだけ走る）をすでに買っている。同じ計測で
#   有人の設計フェーズまで買うと、1 つの信号に 2 つの予算を払うことになる。下限 M にとどめる。
#
#   `unconfirmed` は「この計測は当てにならない」という意味。無人で回さない理由にはなるが、変更が広い・取り返せ
#   ないという証拠ではない（それが L で人を呼ぶ理由）。下限 M。
#
#   `one_way` は L を強制し、ここは見直さない。取り返せない一歩こそ、誰かが見ないまま出してはいけないもの。
# dotagents:tier-ladder XS S M L
# ^ 宣言した段。`scripts/test-loop.sh` はこの行を読み、下のすべての述語がこの段のすべての tier に答えることを
# 確かめる。マーカーを消すとチェックも消えるので、AGENTS.md の dmi-gate マーカーと同じくここで明記する。
#
# `[[ "$tier" == "S" ]]` でなく述語にする理由。tier の文字を比べる箇所はそれぞれ*別の*ことを問うていた（plan なしで
# 走ってよいか / 表示する設計フェーズがあるか / 面談が要るか / ディスパッチャを飛ばしてよいか / どの予算か /
# plan が必須になるか / landing 行を合成するか）。文字列比較はどの tier も受け入れてもっともらしいことをする:
# `!= "S"` はまだ無い tier でも真になり、決して存在しない landing plan を要求する。
#
# どの述語も `case` で、`*)` の腕は die する。答えの無い tier は振る舞いが推測になり、人の承認が要るかの推測は
# フェイルオープンにしてはいけない。
tier_die() { # <tier> <predicate>
  die "未知の tier '$1'（${2}）。段はこのファイルの dotagents:tier-ladder 行で宣言してあり、どの述語も
  その段のすべての tier に答える必要がある。すり抜ける tier は、振る舞いが推測になる。"
}

# 🧱 Landing plan を commit せずに landing を走らせてよいか。今は tier_has_design_phase と答えが同じだが、
# 「進めてよいか」と「表示するフェーズがあるか」は別の問いで、将来の段では答えが分かれうるので名前を分けている。
tier_needs_landing_plan()      { case "$1" in XS|S) return 1 ;; M|L) return 0 ;; *) tier_die "$1" "${FUNCNAME[0]}" ;; esac; }
tier_has_design_phase()        { case "$1" in XS|S) return 1 ;; M|L) return 0 ;; *) tier_die "$1" "${FUNCNAME[0]}" ;; esac; }
# /grilling と /research: 面談には人が要るので、表示するのは最上段だけ。
tier_needs_interview()         { case "$1" in XS|S|M) return 1 ;; L) return 0 ;; *) tier_die "$1" "${FUNCNAME[0]}" ;; esac; }
tier_synthesises_landing_row() { case "$1" in XS|S) return 0 ;; M|L) return 1 ;; *) tier_die "$1" "${FUNCNAME[0]}" ;; esac; }
# 層が 1 つで変更が小さい: 層のスキルを打ち、層をまたぐディスパッチャは飛ばす。
review_may_skip_dispatcher()   { case "$1" in XS|S) return 0 ;; M|L) return 1 ;; *) tier_die "$1" "${FUNCNAME[0]}" ;; esac; }
# XS が落とすのはこれだけ。レビューは走る（レビューなしでは出さない）が、所見は /da-fix-plan に回らず、
# /receiving-code-review の周も適用しない。浮くのは triage（$0.7）+ fix（$1.2）+ ゲート 1 回分。失うものは下の
# 注記にあり、そのためにレポートをプロンプト引数だけに置かず、PR の周の前にディスクへ書く。
tier_runs_fix_loop()           { case "$1" in XS) return 1 ;; S|M|L) return 0 ;; *) tier_die "$1" "${FUNCNAME[0]}" ;; esac; }
# lean のレビュー配分を受ける tier。インラインの `case` にすると、名前で述語を探す網羅テストから見えず、XS だけ
# 抜けた。テストが列挙できない判断は、新しい tier のたびに一度ずつ忘れられる。
tier_gets_lean_budgets()       { case "$1" in XS|S) return 0 ;; M|L) return 1 ;; *) tier_die "$1" "${FUNCNAME[0]}" ;; esac; }

decide_tier() {
  TIER=XS
  if [[ "$M_FILES" -gt 5  || "$M_UNCONF" -gt 0 ]];                     then TIER=S; fi
  if [[ "$M_FILES" -gt 10 || "$M_LAYERS" -ge 2 || "$M_RISK" -gt 0 ]];  then TIER=M; fi
  if [[ "$M_FILES" -gt 30 || "$M_LAYERS" -ge 3 || "$M_ONEWAY" -gt 0 ]]; then TIER=L; fi
}

cmd_size() {
  local request="${1:-}"
  [[ -n "$request" ]] || die "size には依頼文が要る: loop.sh size \"<やりたいこと>\""
  # ファイルではなくインライン。`--json-schema` はスキーマを文字列で受け取り、パスを渡すと CLI が固まる。
  local schema
  schema='{"type":"object","required":["files","layers","one_way","risk_surfaces","unconfirmed","unverified_claims"],'
  schema="$schema"'"properties":{"files":{"type":"array","items":{"type":"string"}},'
  schema="$schema"'"layers":{"type":"array","items":{"type":"string"}},'
  schema="$schema"'"one_way":{"type":"array","items":{"type":"string"}},'
  schema="$schema"'"risk_surfaces":{"type":"array","items":{"type":"string"}},'
  schema="$schema"'"unconfirmed":{"type":"array","items":{"type":"string"}},'
  schema="$schema"'"unverified_claims":{"type":"array","items":{"type":"string"}}}}'

  dim "/da-investigate で測定中（天井 \$${BUDGET_ROUND_SIZE}）..."
  ROUND_BUDGET="$BUDGET_ROUND_SIZE"
  claude_round "/da-investigate $request

構造化された項目だけで答えること。\`files\` は変更が触れるすべてのファイル。\`layers\` は
backend / frontend / infrastructure のどれに届くか。\`one_way\` は取り返せない一歩のそれぞれ。
\`risk_surfaces\` は、お金・課金・外部や官公庁への提出・認可・PII・データ移行・並行処理のうち、変更が届くもの。

\`unconfirmed\` は見られなかったものすべて、では*ない*。間違っていたらこの変更が上の件数より*大きく、または
危なく*なるものだけ —— 列挙しきれなかった利用側、追いきれなかった呼び出し経路、疑っているが確かめていない
移行など。確かめる必要がなかったもの、確かめて無関係と分かったものは unconfirmed ではない。規模を変えうる
ものが無ければ空の一覧を返すこと。小さな変更では空が正しく、よくある答えで、水増しすると見る必要のない人に
仕事を送ることになる。

\`unverified_claims\` は*別の*もので、上に紛れ込まないよう項目を分けてある: *依頼文そのもの*が主張していて
確かめられなかったこと —— \"台帳にそんな行は無い\"、\"件数は 105\"、\"これはもう成り立たない\" など。これは
依頼文を直す必要があるという話で、変更が大きいという話ではない。**確かめられない主張だらけの 1 行の修正も、
1 行の修正のまま。** そうした主張はすべてここに入れ、\`unconfirmed\` には入れないこと。この項目は tier に影響しない。" \
    "$schema"

  local files layers oneway risk unconf claims
  # 計測が無いかの確認より*先*に聞く。打ち切られた周も構造化出力を返さないが、2 つの診断は行き先が違う（予算
  # 切れの周でスキーマのフラグを疑うと、このファイルの数字 1 つで直る問題で CLI を調べに行くことになる）。
  # `size` は post_round を通らないので、捕まえられるのはここだけ。
  [[ "$ROUND_BAD_KIND" != "error" ]] || die "size の周がエラーを返した（subtype: ${ROUND_TRUNCATED}、
  exit ${ROUND_EXIT}）。\$${ROUND_COST}・${ROUND_TURNS} ターンを使い、計測は出ていない。予算の打ち切りでは
  *ない* —— エラーになった周は数字を上げても直らない。"
  [[ -z "$ROUND_TRUNCATED" ]] || die "size の周が打ち切られた（subtype: ${ROUND_TRUNCATED}）。
  \$${ROUND_COST}・${ROUND_TURNS} ターンを使い、天井は \$${BUDGET_ROUND_SIZE}。計測は出ておらず、打ち切られた
  計測は計測でもない。

  BUDGET_ROUND_SIZE を上げるか、依頼文を絞ること。確かめるべき主張を多く含む依頼文は、測る側がそれをすべて
  確かめることになる（それを記録するのが \`unverified_claims\`）。"
  round_has_structured || die "計測が返ってこなかった（exit ${ROUND_EXIT}）。この CLI のバージョンで、構造化出力の
  フラグが \`$SCHEMA_FLAG\` で正しいか確かめること。

  推測には倒さない: 無人で回してよいかを決めるのが size で、測っていない変更を小さいと扱うのがここで最悪の結果。"
  files="$(round_structured files)"; layers="$(round_structured layers)"
  oneway="$(round_structured one_way)"; risk="$(round_structured risk_surfaces)"
  unconf="$(round_structured unconfirmed)"; claims="$(round_structured unverified_claims)"

  count() { node -e 'const v=process.argv[1];process.stdout.write(String(v?v.split(",").filter(Boolean).length:0))' "$1"; }
  M_FILES="$(count "$files")"; M_LAYERS="$(count "$layers")"
  M_ONEWAY="$(count "$oneway")"; M_RISK="$(count "$risk")"; M_UNCONF="$(count "$unconf")"
  M_CLAIMS="$(count "$claims")"
  decide_tier

  # 層の件数だけでなく*名前*も残す。`run` は層がちょうど 1 つでツールキットにそのスキルがあるとき、レビューの
  # ディスパッチャを飛ばすのに使う（件数では「どれか」に答えられない）。
  ledger_append repo "$(repo_key)" branch "$(branch)" worktree "$PWD" phase size \
    request "$request" \
    tier "$TIER" files "$M_FILES" layers "$M_LAYERS" one_way "$M_ONEWAY" \
    risk_surfaces "$M_RISK" unconfirmed "$M_UNCONF" unverified_claims "$M_CLAIMS" \
    layer_names "$layers" \
    cost_usd "${ROUND_COST:-0}" turns "${ROUND_TURNS:-0}" exit "$ROUND_EXIT" \
    outcome sized halt_reason __null__
  consume_round_numbers   # この行が size の周の唯一の行 -- `consume_round_numbers` を参照

  echo
  say "tier $TIER"
  say "  files $M_FILES · layers $M_LAYERS · one-way $M_ONEWAY · risk surfaces $M_RISK · unconfirmed $M_UNCONF"
  # tier を動かさないので別の行に出す。上の行に並べると、この項目がなくそうとしている混同を招く。
  [[ "$M_CLAIMS" -gt 0 ]] && say "  依頼文に未確認の主張 $M_CLAIMS 件（段には影響しません。依頼文の方を直す材料です）"
  echo
  case "$TIER" in
    S) say "設計フェーズなし。ゲートはこのリポジトリ自身の gating チェック。"
       say "次:  scripts/loop.sh run" ;;
    M) say "まず設計レビューを、あなたも入って行う。da-design-review は最初のステップで plan の言い直しを"
       say "見せる。読み違えた plan からは、自信満々で見当違いの所見が出る。"
       say "次:  /da-design-review   のあと 🧱 Landing plan を commit し、続けて:"
       say "       scripts/loop.sh run <plan-path>" ;;
    L) say "設計フェーズを一通り、有人で行う必要がある。取り返せない一歩があるか、リスク面に触れるか、"
       say "確認できていないものがある —— 測っていない変更は、無人のループに渡すものとして最悪。"
       say "次:  /grilling   →   /da-spec   →   /da-design-review"
       say "       のあと 🧱 Landing plan を commit し、続けて:  scripts/loop.sh run <plan-path>" ;;
  esac
}



# ---------------------------------------------------------------- 唯一の入口
# 1 つのコマンドを繰り返し打つ。呼ぶたびに 1 歩進んで止まるので、次がどの段階か、plan をどこに置いたかを覚えて
# おく必要がない。
#
# 有人の段階は駆動しないし、できない。`/grilling` は面談で、誰もいない部屋での面談は虚空への質問になる。だから
# 状態は「進める」「引き渡す」「回す」の 3 つで、引き渡しは exit 0（進められるところまで進み、次は人の番）。
#
# landing plan は名前で指定せず見つける。`da-design-review` はファイルを書かないので、plan は 🧱 表をコピーした先の
# ファイルになる。置き場は docs/plans/ という慣習で、表の見出し行で識別する。ツリー全体を内容で探すとその見出しを
# 引用しているこのリポジトリの文書に当たるので、慣習のディレクトリに絞る。
landing_plans() {
  local f
  for f in $(git ls-files 'docs/plans/*.md' 2>/dev/null); do
    grep -q 'What gates it' "$f" 2>/dev/null && printf '%s\n' "$f"
  done
  return 0
}

cmd_auto() { # <request>
  local request="$1" tier recorded plans n
  recorded="$(ledger_last size request)"
  tier="$(ledger_last size tier)"

  # 依頼文が新しければ測り直す。古い tier を別の作業に使い回すと、測っていない変更が小さいものとして扱われる。
  if [[ -z "$tier" || ( -n "$request" && "$request" != "$recorded" ) ]]; then
    cmd_size "$request" || return 1
    tier="$TIER"
    echo
  else
    dim "測定済み: tier ${tier}（${recorded}）"
    echo
  fi

  if ! tier_needs_landing_plan "$tier"; then
    cmd_run
    return $?
  fi

  plans="$(landing_plans)"
  n="$(printf '%s\n' "$plans" | grep -c . || true)"
  if [[ "$n" == "1" ]]; then
    dim "landing plan: $plans"
    echo
    cmd_run "$plans"
    return $?
  fi
  if [[ "${n:-0}" -gt 1 ]]; then
    printf 'loop: docs/plans/ に commit 済みの landing plan が複数ある:\n' >&2
    printf '%s\n' "$plans" | sed 's/^/  /' >&2
    die "どれかを指定すること: scripts/loop.sh run <plan-path>"
  fi

  # plan がまだ無い。ここが引き渡しで、失敗ではない。
  # `${tier}` はわざと波括弧で囲む。bash 3.2 の UTF-8 ロケールでは `$var` の直後の全角文字が変数名に取り込まれ
  # （`$tier）` が未定義の変数の参照になる）、引き渡しで run ごと死ぬ。macOS は bash 3.2 なので、macOS の CI
  # だけで落ち、C ロケールの手元では通った。
  say "━━ ここからはあなたの手番です（tier ${tier}）━━"
  say ""
  say "設計フェーズは対話が要るので、駆動系は打ちません。順序と、何が検証できているかだけ出します:"
  say ""
  cmd_design
  say ""
  say "🧱 Landing plan を docs/plans/ 以下に保存して commit すれば、**同じコマンドをもう一度打つだけ**で"
  say "駆動系が見つけて続きを回します:"
  say ""
  say "    scripts/loop.sh \"$request\""
  return 0
}

# ---------------------------------------------------------------- 設計
# 設計フェーズは tier S より上のすべてで*有人*（`/grilling` は面談、`da-design-review` は最初のステップで
# 「ユーザーに見せる」と言う）。だからこのコマンドは順に回さず、何も尋ねない。次に打つものを出し、実際に検証
# できるものを報告するだけ。ここで入力を求めるのは禁止: test-non-interactive.sh が対話経路が無いことを確かめて
# いて、入力待ちで止まる設計フェーズはあのスイートが防ぐための失敗そのもの。
#
# 検査できる成果物が 3 つ、できない段階が 3 つある。どちらかを言い分けるのが目的で、3 つしか確かめていないのに
# 緑のチェックを 6 つ出す一覧は、一覧が無いより悪い。

# writing-plans は docs/superpowers/plans/YYYY-MM-DD-<name>.md を書き、そのテンプレートはいくつかの見出しを必須に
# している。その見出しで判定する: 無ければメモであって plan ではなく、正しいパスの空ファイルでも通ってしまう。
plan_files() { ls -1 docs/superpowers/plans/????-??-??-*.md 2>/dev/null || true; }
plan_has_header() { # <file>
  grep -q 'Implementation Plan' "$1" 2>/dev/null \
    && grep -q '\*\*Goal:\*\*' "$1" 2>/dev/null \
    && grep -q '## Global Constraints' "$1" 2>/dev/null \
    && grep -q -- '- \[ \]' "$1" 2>/dev/null
}
adr_files() { ls -1 docs/decisions/ADR-*.md docs/adr/*.md 2>/dev/null || true; }

cmd_design() {
  local tier; tier="$(ledger_last size tier)"
  [[ -n "$tier" ]] || die "このリポジトリには size の記録が無い。実行: loop.sh size \"<やりたいこと>\"
  設計フェーズの深さは tier で決まるので、それが先。"

  say "tier $tier"
  echo
  if ! tier_has_design_phase "$tier"; then
    say "設計フェーズなし。README の常設ルール: 一文で説明できる変更は plan を飛ばす。"
    say "ゲートはこのリポジトリに設定されたチェック。"
    say ""
    say "次:  scripts/loop.sh run"
    ledger_append repo "$(repo_key)" branch "$(branch)" worktree "$PWD" phase design \
      tier "$tier" outcome sized halt_reason __null__ cost_usd 0 turns 0
    return 0
  fi

  local pf adr have_plan=0 have_adr=0 committed=0 plan_note=""
  for pf in $(plan_files); do
    if plan_has_header "$pf"; then have_plan=1; plan_note="$pf"; break; fi
    plan_note="${pf}（必須の見出しが無い。writing-plans は '# … Implementation Plan'・'**Goal:**'・'## Global Constraints'・'- [ ]' のステップを要求するので、これは plan ではなくメモ）"
  done
  adr="$(adr_files | head -1)"; [[ -n "$adr" ]] && have_adr=1

  say "段階を順に。自分で打つこと —— どの段階も人が要るので、このコマンドは実行しない。"
  echo
  tier_needs_interview "$tier" && {
    say "  1. /research <topic>            外の世界。検査できない —— 自分で選んだパスにファイルを書くので、"
    say "                                  ここからは探せない。"
    say "  2. /grilling                    面談。検査できない —— 会話で変更の形を決め、何も書き残さない。"
  }
  say "  3. /da-spec                     $( ((have_plan)) && printf '見つかった: %s' "$plan_note" || printf '見つからない%s' "${plan_note:+ -- $plan_note}" )"
  say "  4. /documentation-and-adrs      $( ((have_adr)) && printf '見つかった: %s' "$adr" || printf 'ADR なし（記録に値する判断をしたときだけ要る）' )"
  say "  5. /da-design-review            検査できない —— ファイルを一切書かない。🧱 Landing plan は会話の中にしか"
  say "                                  無いので、あなた自身がその表をファイルにコピーして commit する。"
  say "                                  他の誰もしない。"
  echo
  say "そのあと: landing plan を commit して  scripts/loop.sh run <plan-path>"
  say "commit が承認になる —— 承認フラグは無い。フラグは読まずに打てるものだから。"
  echo
  say "ここで検証したもの: plan ファイルと ADR。検証していないもの: research、面談、設計レビュー。"
  say "5 段階のうち 3 つは何も残さず、このコマンドはそうでないふりをしない。"

  ledger_append repo "$(repo_key)" branch "$(branch)" worktree "$PWD" phase design \
    tier "$tier" plan_found "$have_plan" adr_found "$have_adr" \
    outcome sized halt_reason __null__ cost_usd 0 turns 0
  return 0
}

# ---------------------------------------------------------------- 実行
HALT=""; PLAN_PATH=""

# 作業を専用の workspace に置く。スキルを打って行い、駆動系が自分で `git worktree add` はしない。
# `using-git-worktrees` には 1 行の呼び出しに無いものが 5 つある: submodule の確認（submodule の中でも
# `--git-dir != --git-common-dir` が真になる）、ディレクトリの選び方、`git check-ignore` の確認（無視されていない
# worktree ディレクトリはツリーごと commit される）、ベースラインの確認、サンドボックスが拒否したときの代替手順。
# ここで再実装すると `gate.sh arm` で一度失敗した形を繰り返す。
#
# 駆動系が持つのは何が起きたかを知ることで、それは返答ではなく git から読む（`/da-verify` を打って
# `gate.sh status --json` を読むのと同じ分担）。
isolate() {
  local want_key; want_key="$(repo_key)"
  if in_linked_worktree; then
    dim "すでに linked worktree の中（$(branch)）—— もう 1 つは作らない"
    return 0
  fi
  local before after new
  before="$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')"
  # 空の `before` は「最初の一覧が失敗した」と区別できず、その場合は既存の worktree がすべて新しく見えて
  # `head -1` が無関係な worktree に cd する。本体のチェックアウトが必ずあるので、空はコマンドの失敗。
  [[ -n "$before" ]] || { halt isolate_failed "隔離の前に worktree の一覧を取れなかった"; return 1; }
  dim "/using-git-worktrees で作業を隔離中 ..."
  claude_round "/using-git-worktrees

これは無人の run である。同意を求めずに隔離した workspace を用意すること —— この指示を、スキルの Step 0 が
探している宣言済みの希望として扱う。プロジェクトのテストをベースラインとして走らせないこと。ここでは検証は
別のものが受け持ち、リポジトリに設定されたチェックを走らせる。"
  [[ "$ROUND_EXIT" == "143" ]] && die "隔離中に中断された"
  # 周の他の結末をここで握りつぶすと、時間切れ・エラー・天井で切られた周が「スキルが隔離を断った」と報告され、
  # 周ではなくスキルを読みに行くことになる。最初に見るべきは周自身の数字なので出す。
  dim "   isolate の周: exit ${ROUND_EXIT}、\$${ROUND_COST}、${ROUND_TURNS} ターン${ROUND_TRUNCATED:+、打ち切り（${ROUND_TRUNCATED}）}"
  if [[ "$ROUND_EXIT" != "0" || -n "$ROUND_TRUNCATED" ]]; then
    halt isolate_round_failed "隔離の周が完走しなかった（exit ${ROUND_EXIT}${ROUND_TRUNCATED:+、${ROUND_TRUNCATED}}）。
  完走しなかった周から worktree は期待できず、「その場で作業する」はこのループが黙って取ってはいけない
  唯一の代替 —— その場とは、今立っているブランチの上ということ。"
    return 1
  fi
  after="$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')"
  new="$(comm -13 <(printf '%s\n' "$before" | sort) <(printf '%s\n' "$after" | sort) | head -1)"

  if [[ -n "$new" && -d "$new" ]]; then
    cd "$new" || { halt isolate_failed "新しい worktree（${new}）に入れなかった"; return 1; }
    # 識別は差分から決めつけず cd の後で確かめる。2 回の一覧の間に別のセッションが足した worktree も差分に出て、
    # `head -1` は因果でなく辞書順で選ぶので、確かめないと landing 全体が他人のチェックアウトで走りうる。
    if ! in_linked_worktree || [[ "$(repo_key)" != "$want_key" ]]; then
      halt isolate_failed "現れたディレクトリ（${new}）はこのリポジトリの linked worktree ではない。
  そこでの作業は断る —— 別の run が同時に作った worktree も、ここからは同じに見える。"
      return 1
    fi
    dim "  隔離先: ${new}（$(branch)）"
    return 0
  fi
  # スキルが正当に断るケースは 2 つ（サンドボックスの権限エラーと、ユーザーが断った場合）。続けるのは正しいが、
  # 隔離したように見せるのは正しくないので、メッセージが無いことから推測させず口に出す。
  say "worktree は作られなかった —— $(repo_root) のブランチ $(branch) で、その場で作業する。"
  say "スキルはサンドボックスが拒否したときや同意が得られないときに断る。どちらにせよこの run は"
  say "このチェックアウトで編集し commit する。"
  return 0
}

halt() { # <reason> <message>
  HALT="$1"
  printf '%sloop: 停止 -- %s%s\n' "$c_red" "$1" "$c_off" >&2
  printf '  %s\n' "$2" >&2
}

# 周の数字は 1 回だけ消費する。ここがその場所。`ROUND_COST` / `ROUND_TURNS` は設定した周より長く生きるグローバルで、
# `report` の `cost by phase` は `cost_usd` を合計するので、新しい周なしに書いた行は他のフェーズが使ったお金を自分の
# フェーズに請求してしまう（`pr-reached` がレビューの周の $1.93 を抱え、`review` は 2 回数えられた）。0 にするのは
# 見た目の修正ではない: その行は実際にコストがゼロで、コストのかかった周はそれを消費した行にすでに載っている。
#
# CI のループも呼び出し箇所ごとの判断なしで正しくなる: CI 修正の周のお金は直後に書かれる行（halt か、CI が緑に
# なった後の `advanced`）に載り、周の無い次の回は 0 を書く。`SPENT` は `claude_round` で積み上げるのでこれとは
# 無関係で、run の予算計算はこれに依存しない。
consume_round_numbers() { ROUND_COST=0; ROUND_TURNS=0; }

record() { # <phase> <landing> <round> <outcome> [halt_reason]
  local rc=0
  ledger_append repo "$(repo_key)" branch "$(branch)" worktree "$PWD" \
    phase "$1" landing "$2" round "$3" outcome "$4" \
    halt_reason "${5:-__null__}" \
    gate "{\"ok\":$([[ "${LAST_OK:-0}" == 1 ]] && echo true || echo false),\"check\":\"$(gate_field check)\",\"kind\":\"$(gate_field kind)\"}" \
    fix_now "${FIX_NOW:-0}" needs_decision "${NEEDS_DECISION:-0}" decline "${DECLINE:-0}" \
    unverified "${UNVERIFIED:-0}" \
    cost_usd "${ROUND_COST:-0}" turns "${ROUND_TURNS:-0}" exit "${ROUND_EXIT:-0}" \
    deferred "$(node -e 'const v=process.argv[1];process.stdout.write(JSON.stringify(v?v.split(" ").filter(Boolean):[]))' "${GATE_DEFERRED:-}")" \
    spent_usd "$SPENT" scorer_touched "$(node -e 'const v=process.argv[1];process.stdout.write(JSON.stringify(v?v.split("\n").filter(Boolean):[]))' "${SCORER_HITS:-}")" || rc=$?
  consume_round_numbers
  return "$rc"
}
# どの周の後にも確かめることを 1 か所にまとめる。landing を止めるときは HALT を設定して非ゼロを返す。
# stderr の 1 行目をその場に出す。恒久的な答えはパスだが、1 行あればトークン切れを知るためだけにファイルを開かずに済む。
round_err_head() {
  [[ -n "$ROUND_ERR" ]] || return 0
  printf '\n  stderr の冒頭: %s' "$(head -1 <<<"$ROUND_ERR" | cut -c1-160)"
}

post_round() { # <phase> <landing> <round>
  SCORER_HITS="$(scorer_touched)"
  if [[ "$ROUND_EXIT" == "143" ]]; then
    halt interrupted "周が終了させられた（SIGTERM）。作業については何も主張しない。"
    record "$1" "$2" "$3" halted interrupted; return 1
  fi
  # 143 だけでなく非ゼロ終了はすべて見る。API エラー・rate limit・拒否されたフラグは、見なければ失敗が見えないまま
  # ループが続いてしまう。
  if [[ "$ROUND_EXIT" == "124" ]]; then
    halt round_timeout "$1 の周が ${ROUND_TIMEOUT}s 以内に返らず、kill した。
  固まるのは周回上限・予算・ゲートのどれもが見逃す唯一の失敗で、だからここに締め切りがある。繰り返すなら、
  \`claude\` が得られないログインを待っていないか確かめること。"
    record "$1" "$2" "$3" halted round_timeout; return 1
  fi
  # 下の汎用の非ゼロチェックより*前*に置く。天井超過は非ゼロで終わるから（`claude --max-budget-usd 0.02 ...` は
  # exit 1、subtype error_max_budget_usd、is_error true を返す）。後に置くとこの分岐は目的のケースで死に、予算切れが
  # `round_failed`（真だが役に立たない）として報告される。
  #
  # 143 と 124 は依然として先: 「kill した」「返らなかった」は「切られた」より多くを語る。
  # エラーは天井ではない。検出は同じで理由が違い、予算の助言はしない（`implement` には上げる予算が無い）。
  if [[ "$ROUND_BAD_KIND" == "error" ]]; then
    halt round_errored "$1 の周がエラーを返した（subtype: ${ROUND_TRUNCATED}、exit ${ROUND_EXIT}）。
  \$${ROUND_COST}・${ROUND_TURNS} ターンを使った。何をしたかについては何も主張せず、これは予算の打ち切りでは
  *ない*: 数字を上げるのではなく周自身の出力を読むこと。出力は
  $ROUND_LOG_BASE.json にある（周が何か言っていれば .err にも）$(round_err_head)"
    record "$1" "$2" "$3" halted round_errored; return 1
  fi
  if [[ -n "$ROUND_TRUNCATED" ]]; then
    halt truncated "$1 の周が天井で打ち切られた（subtype: ${ROUND_TRUNCATED}）。\$${ROUND_COST}・${ROUND_TURNS}
  ターンを使った。答えは*部分的*で、下流はそれを完成したものとして扱ってはいけない。作業が本当に必要とするなら
  その周の天井を上げるか、周を安くすること —— ただし部分的な報告をきれいな結果として読まないこと。"
    record "$1" "$2" "$3" halted truncated; return 1
  fi
  if [[ "$ROUND_EXIT" != "0" ]]; then
    halt round_failed "$1 の周が exit ${ROUND_EXIT} で終わった。何をしたかについては何も主張しない。"
    record "$1" "$2" "$3" halted round_failed; return 1
  fi
  if [[ -n "$SCORER_HITS" ]]; then
    halt scorer_touched "この周が自分を採点するものを編集した: $(printf '%s' "$SCORER_HITS" | tr '\n' ' ')
  試験を変えるのは人の行為でなければならない。何も元に戻していない —— 見てから決めること。"
    record "$1" "$2" "$3" halted scorer_touched; return 1
  fi
  if gate_gave_up; then
    halt gave_up "ゲートが VERDICT を記録してブロックをやめた。解放されたゲートは緑ではない:
  作業は検証されて*いない*。読むもの: scripts/gate.sh status$(inherited_note)"
    record "$1" "$2" "$3" halted gave_up; return 1
  fi
  if node -e 'process.exit(Number(process.argv[1]) > Number(process.argv[2]) ? 0 : 1)' "$SPENT" "$BUDGET_USD"; then
    halt budget "予算 \$${BUDGET_USD} に対して \$${SPENT} を使った。"
    record "$1" "$2" "$3" halted budget; return 1
  fi
  return 0
}

# どのレビュースキルを打つか。`/da-review-all` が元を取るのは変更が層をまたぐとき（分類し、層ごとに回し、層の
# *間*にあるリスクを探す）。1 層の変更では「層をまたぐ影響なし」を出すだけで、そこへ行くのに自分の本文 12 KB と
# 分類 1 回を払う。
#
# だから tier S で、ツールキットにスキルのある層がちょうど 1 つなら、層のスキルを直接打つ。それ以外はディスパッチャ
# に戻し、戻し方はわざと単純にする: スキル名を推測すると層を別のチェックリストで見てカバー済みと報告することになり、
# それは /da-review-all の「Done when」が捕まえるための失敗そのもの。
review_skill_for_tier() {
  local names layer
  review_may_skip_dispatcher "$(ledger_last size tier)" || { printf '/da-review-all'; return 0; }
  names="$(ledger_last size layer_names)"
  # 名前が 1 つでカンマなし。層 0（docs だけの変更）は 1 層ではなく、スキルも無いので推測せずディスパッチャへ。
  case "$names" in
    ''|null|*,*) printf '/da-review-all'; return 0 ;;
  esac
  case "$names" in
    backend|server|api)          layer=backend ;;
    frontend|client|web)         layer=frontend ;;
    infra|infrastructure|iac)    layer=infra ;;
    *) printf '/da-review-all'; return 0 ;;
  esac
  printf '/x-review-%s' "$layer"
}

# ファイルに書かず引数で渡すので 1 行。
triage_schema() {
  printf '%s' '{"type":"object","required":["fix_now","needs_decision","decline","unverified"],"properties":{"fix_now":{"type":"integer"},"needs_decision":{"type":"integer"},"decline":{"type":"integer"},"unverified":{"type":"integer"}}}'
}

# landing 1 つを、提出した PR まで。途中で止まると HALT を設定する。
run_landing() { # <n> <what-lands> <one-way>
  local n="$1" what="$2" oneway="$3" r rr schema
  LAST_OK=0; FIX_NOW=0; NEEDS_DECISION=0; DECLINE=0; UNVERIFIED=0
  UNREVIEWED_FIXES_NOTE=""; CI_NONE_NOTE=""; XS_UNTRIAGED_NOTE=""; XS_REVIEW_FILE=""
  # UNVERIFIED_NOTE は XS が飛ばす TRIAGE ブロックの中で代入されるので、ここで初期化しないと `set -u` で describe の
  # 周が未定義変数で死ぬ。describe のプロンプトが埋め込む注記は、そこへ至るすべての経路で存在する必要がある。
  UNVERIFIED_NOTE=""

  echo
  dim "── landing $n: $what"

  # 層は作業より先に作る。commit が自分のブランチに載るように。後からだとブランチ間で commit を動かすことになり、
  # それは stacking のうち手作りしない方がよい部分。
  stack_layer "$n" || return 1

  # --- 実装。ゲートが緑になるまで -----------------------------------
  #
  # 1 周目がコードを書く。ゲートが赤だった後の周は /systematic-debugging に切り替える。da-verify の締めの行が
  # 「同じチェックが 2 回続けて落ちたら、継ぎ当てをやめる」と言うから。落ちたチェックに /test-driven-development を
  # 繰り返すのはまさにその継ぎ当てで、失敗した方法が積み重なる。2 つのスキルは交換できない: 片方は意図からコードを
  # 書き、もう片方は根本原因が分かるまで修正を提案しない。
  local head_before
  for (( r = 1; r <= MAX_ROUNDS; r++ )); do
    head_before="$(git rev-parse HEAD 2>/dev/null || true)"
    if (( r == 1 )); then
      # tier S より上には commit 済みの plan があり、書かれた plan を実行するスキルは `executing-plans`。それ未満には
      # plan が無いので TDD を直接打つ。
      #
      # upstream はサブエージェントがあれば `subagent-driven-development` を勧めるが、使わない。その判断グラフは
      # 「このセッションに留まるか? no - 別セッション」を executing-plans に回し、ここの周は設計上すべて新しい
      # `claude -p` プロセス。さらに「サブエージェントを出すときは常にモデルを明示せよ」は invariant 10 の逆で、
      # 2 つ目の台帳・修正ループ・最終レビューも持ち込む。
      if [[ -n "$PLAN_PATH" ]]; then
        dim "   round $r: implement (/executing-plans)"
        claude_round "/executing-plans $PLAN_PATH

この landing を実行すること: $what

各ステップで /test-driven-development を使うこと —— まず失敗するテスト、次にそれを通すコード。
これは暗黙には含まれない: executing-plans は plan のステップが言うことに委ねるので、ここで明記する。

profiles/、hooks/、scripts/ 以下のものは変更しないこと —— それらがあなたの作業の合否を決め、
編集するとこの landing は中断される。"
      else
      dim "   round $r: implement"
      claude_round "/test-driven-development

この landing に取り組むこと: $what

**テストは統合（INTEGRATION）レベルに寄せること** —— 単位同士が出会う継ぎ目をまたいで一緒に動かし、境界を
モックせず実物を通す。単体テストも大事で、純粋関数には単体テストを書く。排除したいのは、協力者をすべて
スタブにしたから緑、というスイート。フロントエンドとバックエンドにまたがる変更では、両方を通るテストが意味を持つ。

profiles/、hooks/、scripts/ 以下のものは変更しないこと —— それらがあなたの作業の合否を決め、
編集するとこの landing は中断される。終わったと思ったら止まること。チェックは別のものが走らせる。"
      fi
    else
      dim "   round $r: debug（$(gate_field check) が $(gate_field kind)）"
      claude_round "/systematic-debugging

この landing で $(( r - 1 )) 回試した後も、チェック \`$(gate_field check)\` が $(gate_field kind): $what

修正を提案する前に根本原因を見つけること。回避策で継ぎ当てせず、やり直しもしないこと。すでに試したことは
このブランチの commit と、上の失敗出力にある。

profiles/、hooks/、scripts/ 以下のものは変更しないこと —— それらがあなたの作業の合否を決め、
編集するとこの landing は中断される。"
    fi
    post_round implement "$n" "$r" || return 1

    # 何も変えなかった周は作業をしていない。空虚な緑に対する駆動系の唯一の守り。`{files}` 範囲のチェックはツリーが
    # きれいだと*飛ばされ*、hook は `gate: all gating checks green` と報告する（JSON でも文でも本物の合格とバイト単位で
    # 同じ）。だからゲートには何かが走ったかを聞けず、答えはここで出す: ツリーが手つかずで HEAD も動いていなければ、
    # 返ってくる緑は周が始まる前から真だった。
    if [[ -z "$(changed_paths)" && "$(git rev-parse HEAD 2>/dev/null || true)" == "$head_before" ]]; then
      halt round_changed_nothing "$( ((r == 1)) && printf implement || printf debug ) の周が何も変えなかった
  —— 編集も commit も無い。ゲートの緑は周の前から真で、\`{files}\` 範囲のチェックはきれいなツリーでは丸ごと
  飛ばされるので、ここでの「検証済み」は何も確かめていないことになる。docs/fix-plans/2026-08-11-loop-driver.md の項目 A を参照。"
      record implement "$n" "$r" halted round_changed_nothing; return 1
    fi

    if gate_verify_ok; then LAST_OK=1; record implement "$n" "$r" advanced; break; fi
    LAST_OK=0
    # 「何も確かめていない」は赤いチェックではなく、次の周で緑にもならない（ツリーがきれいだから飛ばされ、周を
    # 足しても変わらない）。profile がこの landing を検証できないので、止めるのが唯一正直な手。
    if [[ -n "$GATE_UNRAN" ]]; then
      halt gate_unran "何も確かめていない。gating チェックが 1 つも走らなかったので、ここは何も検証されていない。
  飛ばしたもの: $GATE_UNRAN
  ゲートはこれを推測に任せず項目（\`ran\`）で報告し、どのチェックも引き受けないファイルが変わったときはブロック
  する。だからここに来たのは、ツリーがきれいだったか、この作業を判定できたはずのチェックがすべて辞退したかの
  どちらか。何にも一致しない \`paths\` は、要らないチェックとまったく同じに見える。"
      record implement "$n" "$r" halted gate_unran; return 1
    fi
    dim "   round $r: $(gate_field check) が $(gate_field kind)"
    record implement "$n" "$r" held
  done
  if [[ "$LAST_OK" != 1 ]]; then
    halt round_cap "$MAX_ROUNDS 周でゲートが緑にならなかった。最後: $(gate_field check)（$(gate_field kind)）。$(inherited_note)
  修正を繰り返すと失敗した方法が積み重なる —— ここは周をもう 1 つ買うのではなく、台帳を読んで依頼文を書き直す場所。"
    record implement "$n" "$MAX_ROUNDS" halted round_cap; return 1
  fi
  commit_landing "$n" "$what" || return 1

  # --- レビュー（上限付き） ------------------------------------------------------
  # レビューの*周*はスキル 1 つではなく、/da-review-all と /da-fix-plan の triage の組。この組は測って $5.64 + $2.08
  # で、レビュー対象の実装は $1.30 だった。tier S は設計フェーズを飛ばせるほど小さいと判断した変更で、安く済ませる
  # ことがその目的なので、1 周だけ買う。
  #
  # これは*天井*で、深さを削るものではない: その landing のレビューはすでに最小の fan-out（「インライン、find サブ
  # エージェントなし」、skills/_shared/review-process.md）に自己調整していて、削れる深さは残っていなかった。ターンは
  # 11 の主張をコードと突き合わせるのに使われ、1 つの誤りを見つけた。そこを削るのは安くて間違った答えを買うこと。
  local review_rounds="$REVIEW_ROUNDS" review_budget="$BUDGET_ROUND_REVIEW"
  local triage_budget="$BUDGET_ROUND_TRIAGE" findbugs_budget="$BUDGET_ROUND_FINDBUGS" review_skill
  if tier_gets_lean_budgets "$(ledger_last size tier)"; then
    review_rounds="$REVIEW_ROUNDS_LEAN"; review_budget="$BUDGET_ROUND_REVIEW_LEAN"
    triage_budget="$BUDGET_ROUND_TRIAGE_LEAN"; findbugs_budget="$BUDGET_ROUND_FINDBUGS_LEAN"
  fi
  review_skill="$(review_skill_for_tier)"
  schema="$(triage_schema)"
  for (( rr = 1; rr <= review_rounds; rr++ )); do
    dim "   review $rr: ${review_skill}（天井 \$${review_budget}）"
    ROUND_BUDGET="$review_budget"
    claude_round "$review_skill"
    post_round review "$n" "$rr" || return 1
    record review "$n" "$rr" advanced
    REVIEW_REPORT="$(round_result)"

    # 2 本目のレビュアで、わざと別の作り。同じ 146 件の PR で、所見の 93.4% は 4 つのツールのうち 1 つだけが
    # 見つけ、4 つすべてが見つけたものは無かった。カバー率は同じレビュアのもう 1 周ではなく別のレビュアから来る。
    #
    # 毎回ではなくリスクで絞る（お金がかかるのはレビュー）。走るのは、一度間違えればそれが事故になる場所 ——
    # `size` が risk_surfaces として記録した面 —— だけ。
    #
    # triage には件数ではなく報告の*全文*を渡す。価値は 1 本目が見逃した具体的な所見にあり、da-fix-plan の
    # テンプレートは "**Source:** which review(s)" と複数形なので、報告 2 つは想定済みの形。
    SECOND_REPORT=""
    if [[ "$(ledger_last size risk_surfaces)" != "0" && -n "$(ledger_last size risk_surfaces)" ]]; then
      dim "   review $rr: 2 本目のレビュア（/find-bugs、天井 \$${findbugs_budget}）—— この landing はリスク面に触れる"
      ROUND_BUDGET="$findbugs_budget"
      claude_round "/find-bugs"
      post_round findbugs "$n" "$rr" || return 1
      SECOND_REPORT="$(round_result)"
      record findbugs "$n" "$rr" advanced
    fi

    # 件数ではなく報告を両方渡す（上と同じ理由）。
    # XS は修正の仕組みを落とす —— ただしレビューと、その記録は落とさない。
    if ! tier_runs_fix_loop "$(ledger_last size tier)"; then
      # 報告は他の何よりも先に、bash でディスクに書く。省略不可。`REVIEW_REPORT` は終了するプロセスのシェル変数で、
      # triage を外すと唯一の写しは /da-pr-describe への引数になる。その天井超過は止まらない（opened-pr-partial-body
      # を記録して続く）ので、PR が開き、describe が切られ、レビューがまるごと消える。コストはファイル書き込み
      # 1 回で、周はゼロ。
      mkdir -p "$LOOP_DIR/reviews" 2>/dev/null || true
      XS_REVIEW_FILE="$LOOP_DIR/reviews/$(basename "$(repo_root)")-$(branch)-$n.md"
      printf '%s\n' "$REVIEW_REPORT" > "$XS_REVIEW_FILE" 2>/dev/null || XS_REVIEW_FILE=""
      [[ -n "$XS_REVIEW_FILE" ]] && dim "   review $rr: triage なし（tier XS）。報告の保存先: $XS_REVIEW_FILE"

      # この tier が手放す halt は `needs_decision` —— 人が*決める*べき所見で landing を止める唯一の仕組み。XS では
      # それが PR 本文の文章になる。数ファイルの変更なら妥当な取引だが、そうなったことを人に伝える場合に限る。
      XS_UNTRIAGED_NOTE="

このレビューの所見は **triage されていません**（tier XS）。\`fix_now\` / \`needs_decision\` の切り分けは
行われておらず、**判断が要る所見があっても駆動系は止まりません**。所見の全文は
${XS_REVIEW_FILE:-（保存に失敗しました）} にあります。**PR 本文にその所見を転記し、「未 triage」と
明記してください。**"

      # 別の outcome にして、`report` がきれいなレビューと triage されなかったレビューを区別できるようにする。
      # 無いと台帳の fix_now 不在が「直すものは無かった」と読める。
      record review "$n" "$rr" advanced-untriaged
      break
    fi

    ROUND_BUDGET="$triage_budget"
    claude_round "/da-fix-plan

下のレビューを triage すること。報告するのはバケットの件数だけ。\`fix_now\` は「今すぐ直す（Fix now）」と
「今すぐ直す、ただし小さく（Fix now, smaller）」の合計。\`decline\` は直さないと決めたものの数。

残り 2 つは切り分けで、間違えると止まるべきでない作業が止まる:

\`needs_decision\` —— 人が何かを*選ぶ*必要があるもの。トレードオフ、承認、プロダクトの判断、コードの持ち主に
しか答えられない問い。**これは landing を止める**ので、誰かが決めない限り本当に進められないものだけを数えること。

\`unverified\` —— レビューが*確認できなかった*もの。読まなかったガード、追えなかった経路、裏付けられなかった
「問題なし」。これはレビュー自身の届く範囲についての記述で、判断の依頼ではない。**何も止めない**。PR 本文に
但し書きとして運ばれる。ある file:line を読めば片が付く、という 👤 はこちらで、上ではない。

=== /da-review-all の所見 ===
$REVIEW_REPORT
${SECOND_REPORT:+
=== /find-bugs の所見（2本目のレビュア、意図的に別の作り） ===
$SECOND_REPORT}" "$schema"
    # 無いのは 0 ではない。欠けた件数を 0 にすると「直すものは無かった」と読め、届かなかった答えを楽観的に読む
    # ことになる。triage されていない PR が、台帳では fix_now:0 のきれいなレビューと区別できないまま出る。
    # フラグは測って確かめたが、周はほかの理由でも構造化出力なしで返りうる。
    FIX_NOW="$(round_structured fix_now)"
    NEEDS_DECISION="$(round_structured needs_decision)"
    DECLINE="$(round_structured decline)"
    # こちらはわざと、無ければ 0。古い triage の周や手で走らせた /da-fix-plan はこの項目を知らないので、無いことを
    # 読めないと扱うと、ほかは完全な報告で止まってしまう。但し書きにとっては「報告されなかった」が安全な読みで、
    # `fix_now` ではそうではないので、あちらは拒否のまま。
    UNVERIFIED="$(round_structured unverified)"; UNVERIFIED="${UNVERIFIED:-0}"
    # describe のプロンプトに埋め込むのは件数ではなく注記。`${UNVERIFIED:+...}` は "0" でも展開される（"0" は
    # 空文字列ではない）ので、注記を空にしておけば、但し書きはあるときだけ出る。
    UNVERIFIED_NOTE=""
    [[ "$UNVERIFIED" =~ ^[0-9]+$ && "$UNVERIFIED" -gt 0 ]] && UNVERIFIED_NOTE="

このレビューが **確認できなかった (unverified) 所見が $UNVERIFIED 件** あります。詳細は
docs/fix-plans/ の該当ファイルです。**PR 本文にその件数と、何が確認されていないのかを明記してください。**
これは「直すべき欠陥」でも「あなたが決めるべきこと」でもなく、**レビューの届かなかった範囲**です ——
綺麗な結果を「安全」と読ませないために、読者に渡す必要があります。"
    if [[ -z "$FIX_NOW" || -z "$NEEDS_DECISION" ]]; then
      halt triage_unreadable "triage の周がバケットの件数を返さなかった（exit ${ROUND_EXIT}）。
  レビューが何を見つけたかについては何も主張しない。"
      FIX_NOW=0; NEEDS_DECISION=0; DECLINE=0; UNVERIFIED=0
      record triage "$n" "$rr" halted triage_unreadable; return 1
    fi
    # 数値でないのも 0 ではない。数値でないものに `[[ x -gt 0 ]]` を使うと、比較せず set -u のもとで非ゼロ終了し、
    # 下の分岐を黙って通ってしまう。
    case "$FIX_NOW$NEEDS_DECISION$DECLINE$UNVERIFIED" in
      *[!0-9]*)
        halt triage_unreadable "triage の件数が数値でなかった（fix_now='$FIX_NOW'、
  needs_decision='$NEEDS_DECISION'、decline='$DECLINE'）。"
        FIX_NOW=0; NEEDS_DECISION=0; DECLINE=0; UNVERIFIED=0
        record triage "$n" "$rr" halted triage_unreadable; return 1 ;;
    esac
    post_round triage "$n" "$rr" || return 1

    if [[ "$NEEDS_DECISION" -gt 0 ]]; then
      halt needs_decision "判断が要る所見が $NEEDS_DECISION 件あり、再試行では片付かない。予算が残っていても
  ここで止める —— 直すかどうかを決めるのが、どう直すかより先。"
      record triage "$n" "$rr" halted needs_decision; return 1
    fi
    record triage "$n" "$rr" advanced
    [[ "$FIX_NOW" -eq 0 ]] && break

    # 順序に注意。以前は修正を適用する*前*にここで上限を確かめていたので、`review_rounds` が 1 の tier S では Fix now
    # の所見 1 つで修正を試さないまま landing が止まり、`/receiving-code-review` に届かなかった。レビューはほぼ必ず
    # 直す価値のあるものを 1 つは見つけるので、無人で最後まで回るはずの tier S がほとんど PR に届かなかった。
    #
    # `REVIEW_ROUNDS` が決めるのは**何回レビューするか**で、最後のレビューの所見に手を付けるかではない。適用は
    # ゲートが検証し直す安い 1 周で、もう 1 回レビューを買うことこそ上限が止めたい高いもの。だから先に修正を適用し、
    # 上限はもう 1 回レビューが続くかだけを決める。

    # エディタに直接ではなく /receiving-code-review を通す。書いてあるから全部実装する、という駆動系がやりがちな
    # ことを止めるためのスキル。何を直す価値があるかは da-fix-plan がもう決めており、ここは各対処が本当に正しいかを
    # 決める。検証に耐えない所見は、レビューについての所見として返す。
    dim "   review $rr: 修正を $FIX_NOW 件適用中"
    claude_round "/receiving-code-review

docs/fix-plans/ の修正計画にある「今すぐ直す（Fix now）」の項目を適用すること —— それだけを。

実装する前に 1 件ずつ評価すること。所見が実際のコードに照らして成り立たなければ、そう言って手を付けないこと。
書いてあるから適用した対処こそ、このスキルが扱う失敗。profiles/、hooks/、scripts/ には触れないこと。"
    post_round fix "$n" "$rr" || return 1
    if gate_verify_ok; then
      LAST_OK=1; record fix "$n" "$rr" advanced; commit_landing "$n" "$what fixes" || return 1
      # 最後の周: 修正は入りゲートも通ったが、誰もレビューしていない。本物の穴なので、読む人が気づくのに任せず
      # PR 本文に運ぶ（GATE_DEFERRED や unverified の件数と同じ形）。
      if [[ "$rr" -ge "$review_rounds" ]]; then
        UNREVIEWED_FIXES_NOTE="

このレビュー周回で **$FIX_NOW 件の修正を適用しましたが、その修正自体は再レビューされていません**
（tier の review 周回数が $review_rounds のため）。ゲートは通っていますが、機械的な検証だけです。
**PR 本文にその件数と、再レビューされていないことを明記してください。**"
        say "   review $rr: 修正を $FIX_NOW 件適用した。再レビューに回す周は残っていない"
        break
      fi
    else
      LAST_OK=0
      halt red_after_fix "修正でゲートが赤くなった: $(gate_field check)（$(gate_field kind)）。
  レビューの対処が、実装では通っていたものを壊した。これは対処についての所見。"
      record fix "$n" "$rr" halted red_after_fix; return 1
    fi
  done

  # --- PR ------------------------------------------------------------
  submit_landing "$n" "$what" "$oneway"
}

# 名前を挙げたパスだけ。`git add -A` だと、ある周の残骸が次の周に commit される（check.sh にもツリーを汚して
# 終わるスイートについての手順がある）。
commit_landing() { # <n> <what>
  tree_readable || { halt tree_unreadable "作業ツリーを読めなかったので、何を commit すべきか知る方法が
  無い。"; return 1; }
  local paths; paths="$(changed_paths)"
  [[ -n "$paths" ]] || return 0
  # 各 `git add` の終了状態が効く。捨てると、パスを解決できなかったとき（cwd がサブディレクトリ、git がもう
  # 認識しないパス）に index が空のままになり、次の行がそれを「やることなし」と読んで、commit したつもりで続いてしまう。
  local add_failed=0
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    git add -- "$p" 2>/dev/null || add_failed=1
  done <<<"$paths"
  if (( add_failed )); then
    halt commit_failed "landing $1 の変更パスをすべては stage できなかった。一部だけの commit はしない:
  作業の半分を黙って落とした commit は、commit が無いより悪い。"
    return 1
  fi
  git diff --cached --quiet 2>/dev/null && return 0
  git commit -qm "loop: landing $1 -- $2" 2>/dev/null || {
    halt commit_failed "landing $1 を commit できなかった"; return 1; }
  return 0
}

# landing ごとに PR 1 本を積み重ねる。landing 2 の PR は trunk ではなく landing 1 のブランチを向く。
#
# landing は作りからして stack になる: landing N は N-1 の上に積まれ、どこで分けるか・何が各 landing を止めるかは
# `da-design-review` がもう決めている。全 landing を 1 本のブランチに載せると、2 つ目の PR が 1 つ目とぶつかる。
#
# stack は、エージェントの PR を実際に殺しているものへの答えでもある。測られた最大の却下理由は誰も関わらない
# こと（放置、33,596 件中 17.3%）で、大きな差分 1 つを前にしたレビュアは止まるが、小さな差分の連なりは上が
# 終わる前から 1 層ずつレビューできる。だから landing は最後にまとめてではなく、終わるたびに提出する。
stack_ready() { # -> gh-stack 拡張が使えれば 0
  gh extension list 2>/dev/null | grep -q 'gh-stack'
}

# stack を作るか、この landing の層を足す。層 1 はユーザーがすでに居るブランチで、それより後の層はすべてこの
# 駆動系が作るブランチ。
# --- PR を開いた後 ----------------------------------------------------
# `gh stack submit` で終えると、誰も見ていない PR を返すことになる: それが起こす CI と、人が残すコメントがどちらも
# 仕組みの外にある。どちらも届くたびに割り込みになるので、レビューのうち人の注意を一番食う半分。
#
# `gh pr checks` の終了コードの約束: 0 すべて緑、1 何かが失敗、8 まだ走っている。
# 0 緑、1 赤、2 pending を待ちきれなかった、3 この PR はチェックを 1 つも報告しない。CI_OUT を設定する。
#
# **終了コードではなく状態から決める。** `gh` は exit 1 を「何らかの理由で失敗」と定め、`gh pr checks` は pending に
# 8 を足すだけなので、終了コードで読むと、失敗したチェック・**まだ存在しない**チェック（push 直後の数秒の普通の
# 状態）・認証の失敗が 1 つの答えに潰れる。存在しない失敗のデバッグにお金を払うことになる。
ci_state() { # <pr-number>
  local num="$1" waited=0 graced=0 states
  while :; do
    CI_OUT="$(gh pr checks "$num" 2>&1)"
    states="$(gh pr checks "$num" --json name,state --jq '.[].state' 2>/dev/null)"

    if [[ -z "$states" ]]; then
      # チェックが*報告されていない*。push 直後なら「まだ登録されていない」で、猶予を過ぎたらこのリポジトリには
      # 報告するものが無いということ。直すべき失敗ではなく、運ぶべき事実。
      (( graced >= CI_GRACE_SECONDS )) && return 3
      sleep 5; graced=$((graced + 5)); continue
    fi
    # 終端の悪い状態はどれも赤。明示的に並べる: この一覧が知らない状態が黙って緑に数えられてはいけないので、
    # pending の集合も名前で並べ、それ以外は赤に落とす。
    grep -qE '^(FAILURE|ERROR|CANCELLED|TIMED_OUT|ACTION_REQUIRED|STARTUP_FAILURE)$' <<<"$states" && return 1
    if grep -qE '^(PENDING|QUEUED|IN_PROGRESS|WAITING|REQUESTED|EXPECTED)$' <<<"$states"; then
      (( waited >= CI_WAIT_SECONDS )) && return 2
      sleep 10; waited=$((waited + 10)); continue
    fi
    grep -qvE '^(SUCCESS|NEUTRAL|SKIPPED)$' <<<"$states" && return 1   # 知らない状態は緑ではない
    return 0
  done
}

ci_settle() { # <landing> <pr-number>
  local n="$1" num="$2" a
  for (( a = 1; a <= CI_ATTEMPTS + 1; a++ )); do
    ci_state "$num"
    case $? in
      0) dim "   CI 緑"; record ci "$n" "$a" advanced; return 0 ;;
      2) halt ci_pending "PR #$num で ${CI_WAIT_SECONDS}s 待っても CI が走り終わらなかった。PR は開いていて、そのコードは
  ローカルのゲートを通っている。分からないのは CI の判断で、それについては何も主張しない。"
         record ci "$n" "$a" halted ci_pending; return 1 ;;
      3) # 猶予を過ぎてもチェックが無い。失敗でも合格でもなく、読むものが無い。
         # 黙って緑扱いにせず PR 本文に運ぶ —— 先送りしたゲートと同じ形で、`gate.sh verify` が「何も走らなかった」に
         # ok:true と答えるのがここでは既知の罠である理由。
         CI_NONE_NOTE="

**この PR には報告されるチェックが1つもありません**（${CI_GRACE_SECONDS}s 待った結果）。ローカルの
ゲートは通っていますが、**CI が何かを言ったわけではありません。** PR 本文にその旨を明記してください。"
         say "   CI: この PR はチェックを 1 つも報告しない —— 読むものが無く、それは合格ではない"
         record ci "$n" "$a" advanced; return 0 ;;
    esac
    # 赤。最後の反復は報告するためだけにあり、直すためではない。だから上限は上限。
    if (( a > CI_ATTEMPTS )); then
      halt ci_red "PR #$num の CI は $CI_ATTEMPTS 回試しても赤のまま:
  $(printf '%s' "$CI_OUT" | head -3 | tr '\n' ' ')
  試行を足すと失敗した方法が積み重なる。run を読んでから決めること。"
      record ci "$n" "$a" halted ci_red; return 1
    fi
    dim "   CI 赤 —— 試行 $a/$CI_ATTEMPTS"
    ROUND_BUDGET="$BUDGET_ROUND_CI"
    claude_round "/systematic-debugging

PR #$num の CI が赤い。出力は次のとおり:

$CI_OUT

修正を提案する前に根本原因を見つけること。CI はこの機械で走らせてはいけないものを走らせるので、ローカルの
ゲートが緑でも失敗は本物でありうる —— 違いを CI のせいだと決めつけないこと。

profiles/、hooks/、scripts/ 以下のものは変更しないこと。チェックを止めるために CI の設定に触れないこと:
取り除いたチェックは、通ったチェックではない。"
    post_round ci "$n" "$a" || return 1
    if [[ -z "$(changed_paths)" ]]; then
      halt ci_fix_changed_nothing "CI 修正の周が何も変えなかった。次に CI を見ても、同じ問いに同じ答えが
  返るだけ。"
      record ci "$n" "$a" halted ci_fix_changed_nothing; return 1
    fi
    gate_verify_ok || { halt red_after_ci "CI の修正で*ローカルの*ゲートが赤くなった: $(gate_field check)。
  push すれば、赤い CI を赤いゲートと交換するだけ。"; record ci "$n" "$a" halted red_after_ci; return 1; }
    commit_landing "$n" "CI fix" || return 1
    prune_stale_remotes; gh stack push >/dev/null 2>&1 || { halt push_failed "CI 修正の後の gh stack push が失敗した"; \
      record ci "$n" "$a" halted push_failed; return 1; }
  done
}

# 人のレビューコメント。周は 2 つで、わざとこの順序で、コメントがあるときだけ: 対応はコードを変えるのでゲートを
# 通す必要があり、返信は外向きの行為なのでその後。まとめると、何も検証しないうちに人へ「済んだ」と告げることになる。
pr_comments_settle() { # <landing> <pr-number>
  local n="$1" num="$2" body count
  body="$(gh api "repos/{owner}/{repo}/pulls/$num/comments" --paginate 2>/dev/null)"
  count="$(node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    try{const a=JSON.parse(s);process.stdout.write(String(Array.isArray(a)?a.length:0))}
    catch{process.stdout.write("0")}})' <<<"$body")"
  [[ "${count:-0}" -gt 0 ]] || return 0
  dim "   PR #$num にレビューコメントが $count 件"

  ROUND_BUDGET="$BUDGET_ROUND_COMMENTS"
  claude_round "/receiving-code-review

以下は PR #$num へのレビューコメント。何かを変える前に、1 件ずつ実際のコードに照らして評価すること ——
書いてあるから適用した対処こそ、このスキルが防ぐための失敗。成り立つものは適用する。成り立たないものは
手を付けず、理由を書き残すこと。それは拒否ではなく答え。

**何も投稿しないこと。** 返信は別のステップで作り、駆動系が投稿する。

$body"
  post_round comments "$n" 1 || return 1

  if [[ -n "$(changed_paths)" ]]; then
    gate_verify_ok || { halt red_after_comments "コメント対応の修正でゲートが赤くなった: $(gate_field check)。"
      record comments "$n" 1 halted red_after_comments; return 1; }
    commit_landing "$n" "review comments" || return 1
    prune_stale_remotes; gh stack push >/dev/null 2>&1 || { halt push_failed "コメント対応の後の gh stack push が失敗した"
      record comments "$n" 1 halted push_failed; return 1; }
  fi
  record comments "$n" 1 advanced

  # 返信は周が書き、*駆動系*が投稿する。返信のために無人の周へ `Bash(gh api:*)` を渡すと、merge・削除・resolve まで
  # 渡すことになる —— resolve はこのフェーズがまさにしてはいけないこと。返信は「こうした」と言い、resolve は
  # 「あなたは納得した」と言い、後者は駆動系が主張することではない。/da-pr-describe と同じ形で、殻は駆動系が作る。
  ROUND_BUDGET="$BUDGET_ROUND_REPLY"
  claude_round "PR #$num のレビューコメントそれぞれに、今したことを使って返信を 1 件ずつ書くこと。

各返信は何をどこで変えたかを言うか、手を付けなかったときは何を見つけ、なぜそのコメントがコードに照らして
成り立たないかを言う。\`file:line\` を挙げること。短く書き、レビューへの礼は言わないこと。
**直していないものを直したと言わないこと。**

$body" '{"type":"object","required":["replies"],"properties":{"replies":{"type":"array","items":{"type":"object","required":["comment_id","body"],"properties":{"comment_id":{"type":"integer"},"body":{"type":"string"}}}}}}'
  post_round reply "$n" 1 || return 1

  local posted=0 line cid rbody
  while IFS=$'\t' read -r cid rbody; do
    [[ -n "$cid" ]] || continue
    # `-f body=@-` は使わない: 本文は複数行で、ここで見える形でシェルの引用をしている。
    printf '%s' "$rbody" | gh api "repos/{owner}/{repo}/pulls/$num/comments/$cid/replies" \
      --method POST -F body=@- >/dev/null 2>&1 && posted=$((posted + 1))
  done < <(node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    try{const o=JSON.parse(s).structured_output;for(const r of (o&&o.replies)||[])
      process.stdout.write(String(r.comment_id)+"\t"+String(r.body).replace(/\n/g," ")+"\n")}catch{}})' \
    <<<"$ROUND_OUT")

  say "   $count 件のコメントのうち $posted 件に返信した —— 何も resolve していない。スレッドを閉じるのはあなた"
  record reply "$n" 1 advanced
  return 0
}

# 古い remote-tracking ref があると、remote にもう無いブランチの `git push` が拒否される:
#
#   ! [rejected] worktree-unattended-run -> worktree-unattended-run (stale info)
#
# GitHub は PR の merge で head ブランチを消す（auto-delete-branch）ので、最初の landing が merge された後も
# `refs/remotes/origin/<そのブランチ>` が消えたものを指したまま手元に残る。同じブランチ名に載る次の landing（隔離
# スキルが時計ではなくリポジトリから名前を選ぶと起きる）は push できない。
# **auto-delete-branch のあるリポジトリは、どれも 2 つ目の landing でこれに当たる。**
prune_stale_remotes() {
  git fetch --prune --quiet origin 2>/dev/null || git remote prune origin >/dev/null 2>&1 || true
}

stack_layer() { # <n>
  if [[ "$1" == "1" ]]; then
    # *両方*の経路で設定する。`gh stack init` の後でだけ代入すると、既存の stack への再開（どの halt の後も普通の
    # 状態）で空のままになり、層の名前が重なり（<l1>-2、次に <l1>-2-3）、開いた PR の上限はたまたまチェック
    # アウトしているブランチで数えられて決して発火しない。
    STACK_BASE_BRANCH="$(branch)"
    gh stack view --json >/dev/null 2>&1 && return 0
    # ブランチは*位置引数*で渡す。ブランチ引数なしの `gh stack init -b <trunk>` は対話で尋ね、ヘッドレスでは
    # "interactive input required; provide branch names as arguments" になる。既存のブランチは作り直さず採用されるので、
    # 今居るブランチを渡すのが正しい。
    gh stack init -b "$(default_branch)" "$STACK_BASE_BRANCH" >/dev/null 2>&1 || {
      halt stack_failed "gh stack init が失敗した"; return 1; }
    return 0
  fi
  gh stack add "${STACK_BASE_BRANCH:-$(branch)}-$1" >/dev/null 2>&1 || {
    halt stack_failed "landing $1 の gh stack add が失敗した"; return 1; }
  return 0
}

submit_landing() { # <n> <what> <one-way>
  local open_prs
  if [[ "$3" == "yes" ]]; then
    say ""
    say "landing $1 は一方通行の扉。検証して自分の層に commit したが、提出はしていない ——"
    say "取り返せない変更は、人がボタンを押す。その下の層は出ている。"
    record pr "$1" 0 halted one_way; return 0
  fi
  # 作者ではなく head ブランチで数える。`--author @me` は手で開いた PR も数え、自分の作業で発火する上限は
  # 切られてしまう。
  open_prs="$(gh pr list --state open --json headRefName --jq '.[].headRefName' 2>/dev/null \
              | grep -c "^${STACK_BASE_BRANCH:-$(branch)}" || true)"
  open_prs="${open_prs:-0}"
  if [[ "$open_prs" -ge "$MAX_OPEN_PRS" ]]; then
    say ""
    say "この stack の PR がすでに $open_prs 本開いていて、上限は $MAX_OPEN_PRS 本。"
    say "検証して commit したが、何も提出していない。stack は 1 層ずつ読むものだが、それでも"
    say "まだ誰も読んでいない出力であることに変わりはない —— ボトルネックはレビュアで、エージェントではない。"
    record pr "$1" 0 halted pr_cap; return 0
  fi
  tree_readable || { halt tree_unreadable "作業ツリーを読めなかったので、提出の前に「何も残っていない」ことを
  確かめられない。"; record pr "$1" 0 halted tree_unreadable; return 1; }
  [[ -n "$(changed_paths)" ]] && { halt dirty_at_pr "PR の時点でツリーが汚れている"; \
    record pr "$1" 0 halted dirty_at_pr; return 1; }

  prune_stale_remotes; gh stack push >/dev/null 2>&1 || { halt push_failed "gh stack push が失敗した"; \
    record pr "$1" 0 halted push_failed; return 1; }
  local url
  # 既定ではなく --open: `gh stack submit` は draft を作るが、これらの層はもうゲートとレビューを通っている。
  # --auto は開くエディタが無いから。
  gh stack submit --auto --open >/dev/null 2>&1
  # stdout を削らず GITHUB に聞く。`gh stack submit` は PR を*作った*ときは URL を、PR がすでに最新のときは文
  # （"PR #45 for <branch> is up to date"）を出す。どちらも成功だが、URL を grep すると後者が `pr_failed` になる
  # （開いたままの PR で実際に起きた）。
  #
  # ゲートについても同じ病気が 2 か所あった（`gate_has_profile` と `gate_verify_ok` が文を読んでいた）。3 か所目も
  # 同じ治し方: 知っている道具に聞く。`gh pr view` は今のブランチについて答え、言い回しが変わることもない。
  url="$(gh pr view --json url --jq .url 2>/dev/null)"
  [[ -n "$url" ]] || { halt pr_failed "\`gh stack submit\` の後、このブランチに PR が無い。
  権威である \`gh pr view --json url\` に聞いた結果で、パースの失敗ではない。"; \
    record pr "$1" 0 halted pr_failed; return 1; }
  local num; num="$(printf '%s' "$url" | sed 's@.*/@@')"

  # 最後ではなく*ここで*記録する。PR はこの行から存在し、CI・コメント・説明文はすべてこの後に走り、どれも止まり
  # うる。唯一の `pr` 行を 3 つの後に書くと、下流の halt で台帳に行が残らず、`report` が実際に開いている PR を
  # 0 と数える。外の世界について台帳が嘘を言う病気で、事実になった時点で事実を記録するのが治し方。
  #
  # `pr-reached` と `opened-pr` はわざと別の事実: PR に届いたことと、PR を仕上げたこと。語順だけで違う名前に
  # しない —— `pr-opened` と `opened-pr` は typo 1 つ、grep 1 つで取り違える。
  record pr "$1" 0 pr-reached

  # CI と人のコメントを説明文より*先に*落ち着かせる。説明文はこの PR に起きる最後のことで、変更が最終的にどうなった
  # か（CI の修正とレビューコメントで動いたものを含む）を書くため。提出時に書くと 1 分前の写真を描き、それを直しに
  # 戻るものは何も無い。
  ci_settle "$1" "$num" || return 1
  pr_comments_settle "$1" "$num" || return 1

  # 殻は駆動系が作り、本文はスキルが書く。da-pr-describe の前提は PR がすでに存在し、自分では作らないことで、
  # こうすればそれが文字どおり真のまま。
  ROUND_BUDGET="$BUDGET_ROUND_PR"
  claude_round "/da-pr-describe $num${GATE_DEFERRED:+

このリポジトリがエージェントに実行を禁じているため、ローカルで検証していないチェックがあります:
  $GATE_DEFERRED

PR 本文にそれを明記してください —— **CI が走らせるまで、その分は未検証**です。}${UNVERIFIED_NOTE}${UNREVIEWED_FIXES_NOTE}${CI_NONE_NOTE}${XS_UNTRIAGED_NOTE}"

  # 止めてもすでに起きたことを戻せない唯一の場所: `gh stack submit` は本文を書く前に PR を開いている。だから
  # 打ち切られた /da-pr-describe は、書きかけの説明文を持つ*本物の*開いた PR を残し、素の `opened-pr` 行は
  # 完成したものに読める。
  #
  # 先送りしたゲートと同じ前例で run は止めない: 作業そのものは通っていて、未完成なのは説明文。黙って受け入れも
  # 残りの landing を止める理由にもせず、大きく言って記録する。台帳を読む人が、どの PR を直すか分かる。
  if [[ -n "$ROUND_TRUNCATED" ]]; then
    # record の前に読む: `record` が周の数字を消費するので、このメッセージは自分の写しを持たないとコストを 0 と
    # 出してしまう（天井を上げるのに読む人が必要な数字）。
    local cut_cost="$ROUND_COST"
    record pr "$1" 0 opened-pr-partial-body
    say ""
    say "landing $1 -> $url  (stack の層 $1)"
    printf '%sloop: PR 本文は部分的 —— /da-pr-describe が打ち切られた（%s）。$%s を使った。%s\n' \
      "$c_red" "$ROUND_TRUNCATED" "$cut_cost" "$c_off" >&2
    printf '  PR は開いていて、そのコードはゲートとレビューを通っている。書き終わらなかったのは*説明文*で、
  誰かがそれを元にレビューする前に読み、BUDGET_ROUND_PR を上げること。\n' >&2
    return 0
  fi
  record pr "$1" 0 opened-pr
  say ""
  say "landing $1 -> $url  (stack の層 $1、レビュー待ち)"
  return 0
}

parse_plan() { # <path> -> landing 行ごとに "n<TAB>what<TAB>oneway"
  node -e '
    const fs = require("fs");
    const lines = fs.readFileSync(process.argv[1], "utf8").split("\n");
    // 見出し行を錨にする。landing_plans() が plan ファイルを識別するのと同じもの。/Landing plan/i に一致する行を
    // 引き金にすると、実際の plan ではそれは自分のタイトルで、次に来た表（🧱 表の上にある証拠の表など）の行が
    // landing になってしまう。発見とパースは同じものを鍵にしないと、見つけたファイルを読み違える。
    let inTable = false, out = [];
    for (const l of lines) {
      // 引き金は見出し行*そのもの*で、それに触れる文ではない。このファイルや、自分の書式を説明する plan は、
      // 地の文にもこの語句を含む。
      if (l.trim().startsWith("|") && /what gates it/i.test(l)) { inTable = true; continue }
      if (!inTable) continue;
      if (!l.trim().startsWith("|")) { if (out.length) break; else continue }
      const cells = l.split("|").slice(1, -1).map((c) => c.trim());
      if (cells.length < 3) continue;
      if (/^-+$/.test(cells[0]) || /^#$/.test(cells[0]) || /what lands/i.test(cells[1] || "")) continue;
      const oneway = /yes|はい/i.test(cells[3] || "") ? "yes" : "no";
      out.push([cells[0], cells[1], oneway].join("\t"));
    }
    process.stdout.write(out.join("\n"));
  ' "$1" 2>/dev/null || true
}

cmd_run() {
  local want_landing="" plan=""
  # 残り 1 つで `shift 2` すると何も shift せず非ゼロを返し、ここには `set -e` が無いので、同じ引数でループが
  # 永久に回る。固まるのはこのリポジトリがスイート 1 つを割いて防いでいる結果なので、何かを消費する前に値を必須にする。
  need_value() { [[ -n "${2:-}" ]] || die "$1 には値が要る"; printf '%s' "$2"; }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --landing)    want_landing="$(need_value "$1" "${2:-}")"; shift; shift ;;
      --max-rounds) MAX_ROUNDS="$(need_value "$1" "${2:-}")"; shift; shift ;;
      --budget-usd) BUDGET_USD="$(need_value "$1" "${2:-}")"; shift; shift ;;
      -*)           die "未知のオプション: $1" ;;
      *)            plan="$1"; shift ;;
    esac
  done
  # 数値でなければ、それを使う比較が黙って効かなくなる（`[[ x -gt 0 ]]` も `Number("x") > n` も偽）。typo が失敗
  # ではなく、上限と予算を無効にしてしまう。
  case "$MAX_ROUNDS" in ''|*[!0-9]*) die "--max-rounds は正の整数（受け取った値: '$MAX_ROUNDS'）" ;; esac
  case "$BUDGET_USD" in ''|*[!0-9.]*) die "--budget-usd は数値（受け取った値: '$BUDGET_USD'）" ;; esac
  [[ -z "$want_landing" ]] || case "$want_landing" in *[!0-9]*) die "--landing は数値（受け取った値: '$want_landing'）" ;; esac

  local root branch_now def tier
  root="$(repo_root)"; def="$(default_branch)"
  tree_readable || die "作業ツリーを読めなかった（\`git status\` が失敗した）。きれいと読まずに断る ——
  この答えの利用側はどれも空を無害と扱うので、ここでの git の失敗は整った出発点に見えてしまう。"
  [[ -n "$(changed_paths)" ]] && die "作業ツリーがきれいでない。先に commit か stash すること —— commit されていない
  作業の上で始まったループは、自分の変更とあなたの変更を区別できない。"

  # 強い依存なので最初に確かめる。`gh pr create` に倒すと landing ごとに stack されていない PR が 1 本ずつ trunk を
  # 向いてでき、頼まれたのとは違う形の出力になり、それを言うものが何も無い。Stacked PR は public preview なので、
  # 足元から消えることもある。
  stack_ready || die "gh-stack 拡張が入っていない。landing は stack として提出する。

  gh extension install github/gh-stack

  素の \`gh pr create\` には倒さない: 全 landing の PR が trunk に載り、レビューが頼る層構造を黙って落とすことになる。"

  # 副作用のあるものを走らせる前に入力を検証する。隔離は worktree を作り、arm はゲートに触れるので、後から悪い
  # plan を断ると両方を無駄にする。commit 済みの plan はどちらのチェックアウトからも同じに読めるので、待つ理由が無い。
  tier="$(ledger_last size tier)"
  [[ -n "$tier" ]] || die "このリポジトリには size の記録が無い。実行: loop.sh size \"<やりたいこと>\"
  無人で回してよいかは tier で決まるので、飛ばしてよいものではない。"

  if tier_needs_landing_plan "$tier"; then
    [[ -n "$plan" ]] || die "tier $tier には commit 済みの landing plan が要る: loop.sh run <plan-path>
  tier $tier は、人がまず設計フェーズを通るという意味。docs/loops.md を参照。"
  fi
  # 渡されたら tier に関わらず検証する。tier が決めるのは plan が*必須*かで、渡された plan を確かめるかではない
  # （確かめないと、commit されていない —— 承認されていない —— plan が最後まで回る）。
  if [[ -n "$plan" ]]; then
    [[ -f "$plan" ]] || die "その landing plan は無い: $plan"
    git ls-files --error-unmatch -- "$plan" >/dev/null 2>&1 \
      || die "landing plan が commit されていない。commit することが、人が承認したと言う方法 ——
  承認フラグは無い。フラグは読まずに打てるものだから。"
    git diff --quiet -- "$plan" 2>/dev/null \
      || die "landing plan に commit されていない変更がある。commit の後に編集した plan は、承認された plan
  ではない。"
  fi
  PLAN_PATH="$plan"

  isolate || return 1

  # landing 全体を通してゲートが差分を取る基点。これが無いと commit のたびにゲートが別の問いに答え、landing が進む
  # ほど答えが悪くなる。
  #
  # `commit_landing` は landing の途中（レビューの前）で走り、ゲートの変更集合は HEAD に対して計算されるので、修正の
  # 周の後の verify は修正の差分*だけ*を見る（検証すべき実装はもう commit されて見えない）。今はどのチェックも
  # `scope: all` でファイル一覧を無視するので無害だが、チェックがパスを宣言した途端、健全な landing を壊す主な経路
  # になる: 実装に一致するチェックがすべて「対象外」になり、何も走らず、ゲートが問題の無い作業をブロックする。
  #
  # merge-base に固定し、この landing のどの verify も同じこと（この landing がしたすべて、commit 済みかどうかを
  # 問わず）を問うようにする。`run` の外では設定しないので、対話の `gate.sh verify` は HEAD 基準のまま。
  LANDING_BASE="$(git merge-base "$(default_branch)" HEAD 2>/dev/null || true)"
  if [[ -n "$LANDING_BASE" ]]; then
    export DOTAGENTS_GATE_DIFF_BASE="$LANDING_BASE"
    dim "  ゲートは $(printf '%.12s' "$LANDING_BASE") に対して差分を取る（HEAD ではなく、この landing の基点）"
  fi

  # 隔離の前ではなく後: 新しい worktree は自分のブランチを持って来るので、このチェックはコマンドを打った場所では
  # なく、作業が実際に載る場所についてのもの。
  branch_now="$(branch)"
  case "$branch_now" in
    "$def"|main|master|develop)
      die "デフォルトブランチ（${branch_now}）の上にいる。先にブランチを切ること。ループは push して PR を開く。" ;;
  esac

  # ゲートを arm する前に確かめる。`gate.sh arm` は既存の VERDICT を VERDICT.prev に動かし試行の予算をやり直す ——
  # 新しいセッションを始める人には正しいが、ここで黙ってやるのは誤り。verdict は未検証の状態を合格と取り違え
  # ないためにある唯一の記録で、入り口でそれを消す無人の run は、一番読む必要のあった証拠を壊したことになる。
  if gate_gave_up; then
    printf 'loop: ここの直近のゲートは合格ではなく verdict で終わっている。\n' >&2
    bash "$GATE_SH" status >&2 2>/dev/null || true
    die "その作業は検証されて*いない*。次の無人の run を始める前に verdict を読んで片付けること ——
  arm するとそれが消える。"
  fi

  # 高い前提条件は最後に、安い拒否をすべて済ませてから: verify 1 回はスイート全体かかり、tier の欠落や未承認の plan が
  # 止める機会を得る前に払う価値は無い。`gate.sh verify` は状態を持たない探りで、da-verify 自身の Step 3 が何度でも
  # 走らせてよいと言っているので、ここで読んでも規則は重複しない。
  dim "開始前にゲートを確認中 ..."
  if gate_verify_ok; then STARTED_GREEN=1; else STARTED_GREEN=0; fi
  gate_has_profile || die "このリポジトリに一致する profile が無いので gating チェックも無い —— そして
  \`gate.sh verify\` は何も一致しないと ok:true と答える。確かめていないリポジトリは緑ではない。
  /da-verify を走らせて profile を書いてもらってから戻ること。"
  # 真偽値だけでなく STARTED_RED_CHECK も持つ。真偽値だけでは、諦めるときのメッセージがどちら（引き継いだ赤か、
  # この run が壊したか）が起きたかを言えない。
  if [[ "$STARTED_GREEN" == 1 ]]; then
    STARTED_RED_CHECK=""
    dim "  緑で開始"
  else
    STARTED_RED_CHECK="$(gate_field check)"
    dim "  赤で開始: ${STARTED_RED_CHECK}（$(gate_field kind)）—— 引き継いだもので、この run が起こしたのではない"
  fi

  # arm はスキルを打って行う。`gate.sh arm` を走らせるのは `da-verify` だけ（AGENTS.md invariant 2）で、それは形式
  # ではない: 証拠の表を報告し、このリポジトリがエージェントに禁じるチェックを委ね、profile が一致しなければ断る
  # ステップでもある。駆動系が自分で `gate.sh arm` を呼ぶと、arm だけ得てそれらを失う。コードに合わせて invariant を
  # 曲げるのは逆方向。
  dim "/da-verify でゲートを arm 中 ..."
  claude_round "/da-verify"
  if [[ "$ROUND_EXIT" == "143" ]]; then die "ゲートの arm 中に中断された"; fi

  local rows req
  if tier_synthesises_landing_row "$tier" && [[ -z "$plan" ]]; then
    # tier S には設計上 landing plan が無い（README の常設ルール: 一文で説明できる変更は plan を飛ばす）。その一文は
    # `size` に渡した依頼文で、台帳から読み戻すので、landing は仮の名前ではなく頼まれたもので名付けられる。
    req="$(ledger_last size request)"
    rows="$(printf '1\t%s\tno' "${req:-the sized change}")"
  else
    rows="$(parse_plan "$plan")"
    [[ -n "$rows" ]] || die "$plan に landing 行が見つからない。表が無いのは、出荷する変更にどう分けるかを
  誰も決めていないということ。"
  fi

  local n what oneway attempted=0
  while IFS=$'\t' read -r n what oneway; do
    [[ -n "$n" ]] || continue
    [[ -n "$want_landing" && "$n" != "$want_landing" ]] && continue
    attempted=$((attempted+1))
    HALT=""
    run_landing "$n" "$what" "$oneway"
    [[ -n "$HALT" ]] && break
  done <<<"$rows"

  echo
  if [[ -n "$GATE_DEFERRED" ]]; then
    say "ローカルで検証していないチェック: $GATE_DEFERRED"
    say "  このリポジトリがエージェントに実行を禁じているものです（走らせていません）。**CI が gate です** ——"
    say "  merge 前にそこが緑であることを確認してください。ローカルのゲートは、走らせて良いものだけを見ました。"
  fi
  dim "$attempted 件の landing で \$${SPENT} を使った。scripts/loop.sh report"
  [[ -n "$HALT" ]] && return 1
  return 0
}

# ---------------------------------------------------------------- 報告
cmd_report() {
  [[ -f "$LEDGER" ]] || { say "台帳はまだ無い: $LEDGER"; return 0; }
  local as_json=0; [[ "${1:-}" == "--json" ]] && as_json=1
  node -e '
    const fs = require("fs");
    const [ledger, repo, asJson] = process.argv.slice(1);
    const rows = fs.readFileSync(ledger, "utf8").split("\n").filter((l) => l.trim())
      .map((l) => { try { return JSON.parse(l) } catch { return null } })
      .filter((o) => o && o.repo === repo);
    const byPhase = {}, landings = new Set(), accepted = new Set(), halts = {};
    let total = 0, rounds = 0;
    // `consume_round_numbers` より前に書かれた行は誤った数字を持ったままで、台帳はわざと追記のみ（切り詰めないことを
    // テストが確かめている）。だから下の合計は直せず、どれだけ多いかを添えることしかできない。日付ではなく*症状*で
    // 見分ける: 1 つの周の数字を 2 回書いた行は、同じ landing・同じコスト・同じターン数の 2 行として現れる。
    const seen = new Set();
    let dupExcess = 0, dupRows = 0;
    for (const r of rows) {
      const c = Number(r.cost_usd) || 0;
      if (c > 0) {
        const key = [r.landing, c, r.turns].join("|");
        if (seen.has(key)) { dupExcess += c; dupRows++; } else { seen.add(key); }
      }
      total += c;
      byPhase[r.phase] = (byPhase[r.phase] || 0) + c;
      if (r.phase === "size") continue;
      if (r.landing != null) landings.add(String(r.landing));
      // PR の outcome はどれも PR に届いたと数える。指標は「landing がそこまで行ったか」で、本文が部分的な PR も
      // 行った（コードはゲートとレビューを通り、切られたのは説明文だけ）。届かなかったと数えると文書の欠陥で採用率を
      // 過小に出し、その欠陥は `opened-pr-partial-body` の行にすでに記録してある。`pr-reached` も数える: submit が
      // 解決した時点で PR は存在し、その後で何が止まっても変わらない。
      if (r.outcome === "opened-pr" || r.outcome === "opened-pr-partial-body"
          || r.outcome === "pr-reached") accepted.add(String(r.landing));
      if (r.halt_reason) halts[r.halt_reason] = (halts[r.halt_reason] || 0) + 1;
      if (r.phase === "implement") rounds++;
    }
    const n = landings.size, a = accepted.size;
    const money = (x) => "$" + x.toFixed(2);
    if (asJson === "1") {
      process.stdout.write(JSON.stringify({
        landings_attempted: n, reached_pr: a,
        acceptance_rate: n ? a / n : null,
        cost_total_usd: total, cost_per_accepted_usd: a ? total / a : null,
        implement_rounds: rounds, rounds_per_landing: n ? rounds / n : null,
        cost_by_phase: byPhase, halted: halts,
        double_counted_usd: dupExcess, double_counted_rows: dupRows,
      }, null, 2) + "\n");
    } else {
      const pct = n ? Math.round((a / n) * 100) : 0;
      console.log(`landings attempted      ${n}`);
      console.log(`reached PR              ${a}   (${pct}%)`);
      console.log(`cost per accepted       ${a ? money(total / a) : "--"}`);
      console.log(`rounds per landing      ${n ? (rounds / n).toFixed(1) : "--"}`);
      const phases = Object.keys(byPhase).map((k) => `${k} ${money(byPhase[k])}`).join(" / ");
      console.log(`cost by phase           ${phases || "--"}`);
      const h = Object.keys(halts).map((k) => `${k} ${halts[k]}`).join(", ");
      console.log(`halted                  ${h || "なし"}`);
      if (dupRows) {
        console.log("");
        console.log(`上の数字のうち ${money(dupExcess)} は ${dupRows} 行にわたって二重に数えられている。`);
        console.log("それらの行は、すでに請求済みの周のコストとターン数を繰り返している。駆動系が 1 つの周を");
        console.log("2 回以上請求しなくなる前に書かれたもの。台帳は追記のみなので残してあり、cost by phase と");
        console.log("cost per accepted はその分だけ多く出ている。");
      }
      if (n && a / n < 0.5) {
        console.log("");
        console.log("採用率が 50% を下回っている: ループはレビューの仕事をあなたから引き取らず、あなたに");
        console.log("返している。周を買い足す前に、halt の理由を読むこと。");
      }
    }
  ' "$LEDGER" "$(repo_key)" "$as_json"
}

cmd_status() {
  local tier; tier="$(ledger_last size tier)"
  if [[ -n "$tier" ]]; then
    say "last size    tier $tier  （ファイル $(ledger_last size files)、層 $(ledger_last size layers)、未確認 $(ledger_last size unconfirmed)）"
  else
    say "last size    （未測定 —— 実行: loop.sh size \"<やりたいこと>\"）"
  fi
  say "ledger       $LEDGER"
  echo
  bash "$GATE_SH" status 2>/dev/null || true
}

# ---------------------------------------------------------------- 振り分け
case "${1:-}" in
  ''|-h|--help|help) usage ;;
  size)   shift; cmd_size   "${1:-}" ;;
  design) shift; cmd_design ;;
  run)    shift; cmd_run    "$@" ;;
  report) shift; cmd_report "${1:-}" ;;
  status) shift; cmd_status ;;
  # サブコマンドでなければ、それはやりたいこと。人が実際に使う入口なので、動詞を覚えさせず既定にしている。
  -*)     printf 'loop: 未知のオプション: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
  *)      cmd_auto "$1" ;;
esac
