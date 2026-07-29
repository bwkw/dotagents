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

**「8回連続ブロックで解除」という数字の裏付けは見つかりませんでした。** 公式は連続ブロックの上限について
何も書いていません。README にあったその記述は削除しました —— そして**この hook では到達しません**、
1回目の再入で自分から解放するので。

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

## まだ未確認のもの

正直に残しておきます。**未確認を「たぶん大丈夫」に書き換えたのが今回の反省点**なので。

- **Cursor の stop payload に session 相当の識別子があるか。** 無いと仮定して設計しています
- **Cursor が `readonly` 以外にどのフィールドを実際に読むか。** ドキュメントに列挙はあるが実機未確認
- **`stop_hook_active` の正確な意味。** 実践側の一致は強いが、公式の定義文は見つかっていない
- **連続ブロックの上限。** 公式に記述なし。この hook は1回目の再入で解放するので到達しないが、
  「到達しない」こと自体は実測していない
- **`max_attempts: 3` / TTL 12h / timeout 120·300 秒。** 全部**選んだ数字**で、測定値ではありません。
  ここが `docs/design.md` の「一度も測っていない」というギャップに、私が足した3つです
