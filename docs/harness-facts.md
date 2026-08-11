# ハーネスの実挙動 —— 一次情報で確認したこと

このツールキットは hook の exit code と timeout の意味の上に建っています。**それらを推測で設計していた期間が
あった**ので、公式ドキュメントに突き合わせた結果をここに置きます。

**このファイルの目的は、前提を再び推測に戻さないことです。** 「たぶんこうだろう」で設計した箇所は、
外れていたときに無言で fail-open します。実際に1件外していました（下の timeout の項）。

出典: [Claude Code Hooks reference](https://code.claude.com/docs/en/hooks) ·
[Cursor Subagents](https://cursor.com/docs/subagents)

---

## exit code —— 2 以外は全部「通す」

| exit | 意味 |
|---|---|
| `0` | 成功。stdout の JSON が解釈される（**exit 0 のときだけ**） |
| `2` | **ブロック。** stdout と JSON は無視され、**stderr がフィードバックとしてモデルに渡る** |
| それ以外（`1` を含む） | **non-blocking エラー。** transcript に注意が出て、**実行はそのまま続く** |

公式の警告をそのまま引くと: *"Claude Code treats exit code 1 as a non-blocking error and proceeds,
even though 1 is the conventional Unix failure code."*

**このツールキットへの帰結**: gate は `set -uo pipefail` で走るので、**未定義変数1つで exit 1 = 通過**に
なります。過去に一度これで刺されています（cwd に空白が含まれると算術比較が exit 127 になり、ゲートが開いた）。
個別に直すのではなく、**armed だと分かった時点で trap を張り、0 と 2 以外を 2 に変換**します。

イベントごとにブロックできるかは違います。`Stop` / `SubagentStop` / `PreToolUse` などは exit 2 でブロック、
`PostToolUse` / `Notification` / `SessionStart` などは**ブロックできません**。

## timeout —— 既定は 600 秒、そして timeout は non-blocking

*"When a hook exceeds its timeout, it is treated as a non-blocking error for most events."*

| 種別 | 既定 |
|---|---|
| `command` / `http` / `mcp_tool` | **600 秒** |
| `prompt` | 30 秒 |
| `agent` | 60 秒 |
| `UserPromptSubmit` の command 系 | 30 秒に短縮 |
| `MessageDisplay` の command 系 | 10 秒に短縮 |
| `SessionEnd` | 全 hook で 1.5 秒の予算（per-hook timeout を長くすれば最大60秒まで引き上げ） |

`timeout` は settings.json の hook エントリで**秒単位**で設定できます。

**設計の土台は正しかった**: 「ハーネスの timeout で殺された hook は non-blocking」—— つまり遅いスイートは
ゲートを無言で無効化する。ここは推測が当たっていました。

**外していたのはこちら**: 既定が 600 秒だと知らずに **420 秒を宣言**していました。420 は
① 既定より短い（ハーネスの時計を自分で締めた）② gate 自身の最悪ケース（`timeout_total` 300 ＋ 1チェックの
超過 120 ＝ 420）と**同値**。テンプレートのコメントは "strictly larger" と書いていたのに、そうなっていません。
**600 に直しました** —— 既定と同じ値で、自分の最悪ケースより 180 秒大きい。

## `stop_hook_active` —— 公式リファレンスに説明がなく、実践側で確立している

Stop の payload に存在することは確認できましたが、**意味の説明が公式リファレンスに見つかりません。**
実践側の記述は一貫しています: 直前のブロックによる強制継続中に `true` になり、**そのときは exit 0 で
止まらせる**。そうしないと無限にブロックし続ける。

このリポジトリの `block()` はまさにそれをしています（再入で1回引き渡す）。**つまり偶然ではなく、
広く共有されている作法と一致していました。**

**訂正: 「8回連続ブロックで解除」は公式に書いてあります。** 以前ここには「裏付けは見つからなかった」と
書いていました。[Claude Code best practices](https://code.claude.com/docs/en/best-practices) の
停止ゲートの段階表に、Stop hook は **8回連続ブロックで上書きされる**（つまり hook がセッションを
永久に閉じ込めることはできない）と明記されています。**探した場所が悪かっただけです** ——
hooks reference には無く、best practices にありました。

**結論は変わりません**: この hook は1回目の再入で自分から解放するので、8には到達しません。
変わったのは「未確認」から「確認済み」になったことだけで、**それが変わったこと自体は記録に値します**
—— このファイルの目的は前提を推測に戻さないことなので、「確認できなかった」を残したままにするのも
一種の推測です。

## `SubagentStop` —— 登録した `Stop` hook が自動的に変換される

*"For subagents, `Stop` hooks are automatically converted to `SubagentStop` since that is the event
that fires when a subagent completes."*

**これが今回いちばん大きい発見です。** settings.json に `Stop` を登録すると、**サブエージェント完了時にも
同じ hook が走ります。** つまりゲートは:

- `da-review-all` が3層に委譲するたびに、gating スイートを**余分に3回**走らせていた
- exit 2 は **サブエージェントの終了をブロック**する。リポジトリのテストが赤いことを理由にレビュー
  サブエージェントを止めるのは意味をなさない
- attempt 予算を、ユーザのターンではない作業で消費していた

payload には subagent 内であることを示す `agent_id` と `agent_type` が入ります。
**ゲートは「ユーザのターンが終わって良いか」を判定するものなので、subagent 完了時は即 pass**します
（trace には理由を書くので、きれいな pass と区別できます）。

`SubagentStop` の matcher は**エージェント種別**で絞れます（`general-purpose`、`Explore`、独自名など）。

## payload の共通フィールド

`session_id` · `prompt_id` · `transcript_path` · `cwd` · `permission_mode` · `effort` ·
`hook_event_name`、そして subagent 内では `agent_id` · `agent_type`。
Stop / SubagentStop は `last_assistant_message` を持ち、**transcript を読むより先にこれを使うべき**と
書かれています。

**`session_id` の存在は確認できました。** attempt を session 単位で持つのは本来こちらの方が正しい設計です
（attempt はリポジトリではなくセッションに属する）。**ただし Cursor が同等のものを送るかは未確認**なので、
片方のエージェントしか供給しないフィールドで設計するのは避けています —— それは、ゲートが全 Cursor ターンを
無言で通していたバグとまったく同じクラスです。

## Cursor のサブエージェント —— `~/.cursor/agents/` が正しい置き場

Cursor 2.4 以降、サブエージェントは frontmatter 付き Markdown で、
**プロジェクト用が `.cursor/agents/`、グローバル用が `~/.cursor/agents/`**。
frontmatter は `name` / `description`（Agent が委譲判断に読む）＋ 任意の `model` / `readonly` /
`is_background`。

**`setup.sh` は「Cursor は `~/.claude/agents/` も読むので1本のリンクで両方カバーできる」と書いていました。**
Cursor のドキュメントにその記述はなく、実際に `~/.cursor/agents/` は空でした ——
**つまり `x-review-verifier` と `x-codebase-explorer` は Cursor に1本も届いていなかった**のに、
README は「どのリポジトリにも存在します」と書いていました。都合の良い未検証の主張です。

両方にリンクするように直し、install / uninstall / status / prune のすべてが両ディレクトリを見ます。

**なお `tools:` は Claude 専用**で、Cursor の対応物は `readonly` です。不変条件1のとおり、
**読み取り専用は本文の宣言で担保**されていて frontmatter には依存していません。

---

## headless（`claude -p`）—— ループの駆動系が乗っている面

出典: [Claude Code headless](https://code.claude.com/docs/en/headless)

| 事実 | ループへの帰結 |
|---|---|
| `--output-format json` は `total_cost_usd` を**モデル別内訳付き**で返す。クライアント側の見積りと明記されている | **計器の一次データはこれ。** `docs/design.md` が「コストの可観測性が半分」と書いていた側が、ここで埋まる |
| `--json-schema` ＋ `--output-format json` で、スキーマ準拠の出力が `structured_output` に入る | 所見の件数を prose から grep しなくて済む。`loop.sh` の `SCHEMA_FLAG` が1箇所だけこの名前を持つ |
| **`--bare` は hooks・skills・plugins・MCP・auto-memory・CLAUDE.md の自動発見を全部切る。** 公式は「スクリプトと SDK 呼び出しの推奨モード」と書いている | **このリポジトリでは推奨に従うと fail-open になります。** ゲートも skill も profile も切れるので、駆動系は `--bare` を使いません。`test-loop.sh` がそれを assert します —— 公式の推奨が自分の設計と逆を向く数少ない箇所なので、書いておくだけでは足りない |
| exit **143** = SIGTERM（ターン中断、Bash のプロセスツリーを kill、`SessionEnd` hook は走る） | 143 は「失敗」ではなく `interrupted`。作業について何も主張しない |
| `--permission-mode auto` は `-p` の下で、分類器が繰り返しブロックすると**中断する**（人間に落とせないので） | 予測可能な方を採って `acceptEdits`。封じ込めは profile の `forbidden` と採点器の指紋検査 |

## まだ未確認のもの

正直に残しておきます。**未確認を「たぶん大丈夫」に書き換えたのが今回の反省点**なので。

- ~~`claude -p` のターン終了で `Stop` hook が発火するか~~ · ~~`-p` でスラッシュコマンドが届くか~~ ·
  ~~`da-review-all` は headless で完走するか~~ · ~~`--json-schema` のフラグ名~~
  → **すべて 2026-08-11 に実測しました。** 結果は下の節に移しました

- **`CLAUDE_CONFIG_DIR` が存在するか。** 公式の settings ドキュメントに**記載がありません**（2026-08-11 確認）。
  実装の根拠にできないので `setup.sh` は `~/.claude` に固定したままです。**もし実在するなら**、install は
  agent が読まない場所に書き、`status` は自分の書き込みを検査するので**緑のまま hook が不在**になります
  —— このリポジトリが何度も潰してきた形そのもの。優先度が高いのは「対応」ではなく「確認」の方です
- **Cursor の stop payload に session 相当の識別子があるか。** 無いと仮定して設計しています
- **Cursor が `readonly` 以外にどのフィールドを実際に読むか。** ドキュメントに列挙はあるが実機未確認
- **`stop_hook_active` の正確な意味。** **挙動は実測しました**（下の節。ブロック → 再入で解放が
  trace に出ます）が、**公式の定義文は今も見つかっていません。** 観測と定義は別物なので、
  ここは残します —— 実測した1ケースが仕様のすべてだとは言えません
- **`max_attempts: 3` / TTL 12h / timeout 120·300·900 秒。** 全部**選んだ数字**で、測定値ではありません。
  ここが `docs/design.md` の「一度も測っていない」というギャップに、私が足した4つです
- **`attempts.json` にロックを足していない理由。** temp+rename で切り詰めは防いでいますが、競合する
  2つの増分は共に同じ値を読んで同じ値を書くので**過小カウント**になります。上限に「遅く到達する」だけで
  「到達しない」わけではないので、**fail-closed の性質ではない**と判断して足していません。
  ここに書いてあるのは、次に読む人が「抜け」と読まないためです

## headless の実測（2026-08-11）

**駆動系が乗っている前提を、公式ドキュメントではなく実機で確かめました。** 使い捨てのクローンと
`DOTAGENTS_GATE_DIR` / `DOTAGENTS_PROFILES` で隔離し、`--max-budget-usd` で上限を掛けています。

| 前提 | 結果 |
|---|---|
| **`Stop` hook は `claude -p` のターン終了で発火する** | ✅ armed かつ**赤い**ゲートで実測: trace に `BLOCKED (probe-red)` → `RELEASED while probe-red red -- handed control back with checks failing`、`attempts.json` は `{"probe-red": 2}` |
| **`stop_hook_active` の再入解放** | ✅ 上の2行目がそれです。**「実践側の一致は強いが公式の定義文が見つかっていない」と書いていた挙動が、このハーネスで実際にそう動く**ことを観測しました |
| **`attempts` は1ターンで 2 進む** | ブロックで1、再入の解放で1。つまり `max_attempts: 3` は**2ターンで到達**します —— 「3回落ちたら」より早い |
| **スラッシュコマンドは `-p` で届く** | ✅ `/da-verify` が profile を名指しして `## Verification` を出した。**`disable-model-invocation` 付き（`grill-me`）も本文が読まれた** |
| **`da-review-all` は headless で完走する** | ✅ 18ターン、Canvas に言及、`report-format.md` 準拠 |
| **`--json-schema` は存在し、スキーマを文字列で取る** | ✅ ただし**ファイルパスを渡すとエラーにならず永久にハングする**（stdin を閉じても）。駆動系はパスを渡していたので初回使用でハングするところでした |
| `--output-format json` の返り | `result` / `num_turns` / `total_cost_usd` / `is_error` / `api_error_status` / `usage` / `modelUsage`。エラー時 exit 1 |
| `--max-turns` | **`--help` に出てきません。** 代わりに `--max-budget-usd`（`--print` 専用）があります |

**コストの実測**（このリポジトリで初めての数字）:
`/da-review-all` **$1.99**（18ターン）· `/da-verify` $0.59（15）· `/grilling` $0.76（11）·
自明な1ターン $0.09。**レビュー1回で約$2。**

**測れなかった期間の理由も残しておきます。** 最初はグローバル `claude` のプラットフォームバイナリが
中断された npm の staging に取り残されていて exec できず、次は **Keychain の
`Claude Code-credentials` が2か月更新されていなくて 401** でした。後者は
「ログインしたのに変わらない」という形で現れます —— **`security find-generic-password -s
"Claude Code-credentials" | grep mdat` が更新されたかどうかの唯一の客観的な確認**です。

## チェックの実行はプロセスグループで

以前の監視サブシェルは `eval` を走らせているサブシェルだけを kill していて、**その下は残っていました**。
`pnpm test` が生んだ node、dev サーバ、コンテナ —— ゲートが諦めた後もポートと CPU を掴んだままになる。

node の `spawn(..., { detached: true })` で自分のプロセスグループを持たせ、`process.kill(-pid)` で
グループごと落とします。**変えていないのは引用の境界**です: コマンドは `eval` が受け取っていたのと同じ
まま `bash -c` に渡り、`{files}` は今もファイル名ごとにシェル引用してから置換されます。
**動いたのは「何が kill されるか」だけ。** それでも、境界に触る前にインジェクションのテストを
7パターンに広げました —— 守っているものがそれだけだったので。
