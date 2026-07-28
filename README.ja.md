# dotagents

[![ci](https://github.com/bwkw/dotagents/actions/workflows/ci.yml/badge.svg)](https://github.com/bwkw/dotagents/actions/workflows/ci.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

個人用の AI 開発ツールキット。**Claude Code と Cursor の両方**で動くスキル・フック・リポジトリプロファイルを、一度グローバルに入れればどのリポジトリでも使える形にしたものです。

プロダクトのリポジトリには一切手を入れません。リポジトリ固有の設定はプロファイルとしてここに置き、そのプロファイルは gitignore されます。

English: [README.md](README.md)

**なぜこの形なのか、どう使う想定かは [docs/design.ja.md](docs/design.ja.md)。**
ADR の一段上の話 —— 何を解こうとしているのか、制約が働く場所と働かない場所、まだ未確定なことを
書いてあります。

```bash
git clone https://github.com/bwkw/dotagents ~/private/dotagents
cd ~/private/dotagents
./scripts/setup.sh install --dry-run   # 何が起きるか確認
./scripts/setup.sh install
./scripts/setup.sh status
```

## スキル

| スキル | 何をするか |
|---|---|
| `/review-all` | 変更が触れている層を判定し、層別レビューを並列サブエージェントで走らせて、**層をまたぐ不可逆リスク**を洗い出す。単一層のレビューでは見えない領域 |
| `/design-review` | コードが1行も存在しない段階で計画をレビューする。一方通行の扉・移行順序・後方互換・ロールバック、そして**計画に書かれていないもの** |
| `/investigate` | コードベースへの問いに `file:line` の根拠付きで答える。探索予算を固定し、確認できなかったことを明示する |
| `/verify` | そのリポジトリ自身の検証コマンドを実行し、証拠付きで報告する。コマンドを推測しない。リポジトリが禁じているものは実行しない |
| `/pr-describe` | diff を開く前に読める PR タイトルと説明を書く |
| `/skills-audit` | インストール済みスキルの description 予算・トリガの重複・Cursor 非互換・未使用を監査する |

## 仕組み

```
dotagents/skills/<name>/
        ↑ symlink
~/.agents/skills/<name>          ← Cursor はここをネイティブに読む
        ↑ symlink
~/.claude/skills/<name>          ← Claude Code は symlink を追う
```

実体はひとつだけ。ここのファイルを編集すれば両方のエージェントに即反映され、同期の手順もドリフトもありません。

フックだけは例外で、symlink ではなく**実体コピー**します。symlink が切れると `exit 127` になり、Claude Code はこれを non-blocking として扱うため、**ガードレールが「止まる」のではなく「開く」**からです。詳細は [ADR 0002](docs/adr/0002-hooks-are-copied-not-symlinked.md)。

## 検証ゲート

エージェントは作業が**完了したように見えた**時点で止まります。実際に実行できるチェックがなければ「完了したように見える」が唯一のシグナルになり、人間が検証ループそのものになってしまいます。

`hooks/dotagents-verify-gate.sh` はターン終了時に走り、そのリポジトリのチェックが落ちている間は終了を拒否します。

**センチネル方式。** スキルが明示的に武装しない限り何もしません。常時ONのゲートは、質問に答えるだけのセッションの終わりにもテストスイートを走らせることになり、一日で無効化されます。それは無いより悪い。

**コマンドはプロファイルから引きます。** git remote で照合するので、プロダクトのリポジトリは無改変のままです。`agent_may_run: false` のチェックはエージェントが決して実行しません（「このコマンドをエージェントに実行させない」と文書で定めているリポジトリがあるため）。その場合ゲートは**ユーザー自身の出力**を要求します。プロファイルが無いリポジトリでは、推測せずに黙ります — 見知らぬリポジトリで勝手に `npm test` を叩くのは、検証ツールが信用を失う典型的なやり方です。

**Cursor でも同じゲートが走りますが、ブロックはできません。** Cursor の `stop` フックには拒否の仕組みがなく、できるのは follow-up メッセージを自動投入してエージェントに作業を続けさせることだけです（Cursor の `loop_limit` で打ち切られます）。両フックは呼び出し元を判定して適切な方言で応答します。Cursor 側は「強い促し」であってゲートではないと考え、重要な場面では `/verify` を明示的に実行してください。対応表は [ADR 0003](docs/adr/0003-cursor-compatible-subset.md)。

### プロファイル

[`profiles/_example.json`](profiles/_example.json) を `profiles/<repo>.json` にコピーして編集します。**あなたのコピーは gitignore されます** — プロファイルは実在のリポジトリ名・環境名、場合によっては勤務先の社内ルールを含むので、書いたマシンの中に留まります。追跡されるのはスキーマと例だけです。`/verify` が書き方を案内します。

## 上流のスキル

サードパーティのスキルはここに取り込まず、横に並べてインストールし、`npx skills check` / `npx skills update` で更新します。**選択的に入れてください** — インストールされたスキルの description は常にコンテキストに常駐するので、リポジトリ丸ごと入れると他の全スキルの選択精度を削ります。

```bash
# 方法論
npx skills add obra/superpowers -g -a claude-code -a cursor \
  -s brainstorming -s writing-plans -s executing-plans -s verification-before-completion \
  -s requesting-code-review -s receiving-code-review -s systematic-debugging \
  -s test-driven-development -s subagent-driven-development -s dispatching-parallel-agents \
  -s using-git-worktrees -s finishing-a-development-branch -s using-superpowers

# 実務
npx skills add mattpocock/skills -g -a claude-code -a cursor \
  -s grill-me -s handoff -s research -s codebase-design -s resolving-merge-conflicts \
  -s improve-codebase-architecture -s domain-modeling

# 運用
npx skills add addyosmani/agent-skills -g -a claude-code -a cursor \
  -s performance-optimization -s observability-and-instrumentation \
  -s documentation-and-adrs -s deprecation-and-migration

# セキュリティ
npx skills add getsentry/skills -g -a claude-code -a cursor \
  -s security-review -s find-bugs -s skill-scanner
```

同じトリガを奪い合わないよう、意図的に入れていないもの: `mattpocock/tdd` と `diagnosing-bugs`（superpowers が両方カバー）、`addyosmani/code-review-and-quality` と `spec-driven-development`（本リポジトリと superpowers でカバー）、および対象外のプラットフォームに固有のもの。

スキルは**エージェントの全権限で動きます**。`/skill-scanner` はプロンプトインジェクションとサプライチェーンリスクを監査するので、新しく入れたものには一度かける価値があります。実際、このリポジトリ自身の frontmatter の不具合を見つけました。そういうためのものです。

## ステータスライン（オプトイン）

`hooks/dotagents-statusline.sh` はコンテキスト使用率・モデル・worktree・ブランチ・セッション費用を表示します。このツールキットの規律はほぼコンテキストの使い方の話なので、使用率は常時表示する価値があります（50%未満で緑、67%超で黄、85%超で赤）。

デフォルトでは配線しません。ステータスラインは見た目に出る個人の好みなので。

```bash
./scripts/setup.sh install --statusline
```

他のキーと同じ方式で `statusLine` を設定にマージするので、`./scripts/setup.sh uninstall` で元に戻ります。

各フィールドは任意で、取得できないものは「unknown」と出さずに消えます。フィールド名はバージョンで変わるため、古い数字を出し続けるステータスラインは短いものより悪いからです。

## スキルの書き方

[`_template/SKILL.md`](_template/SKILL.md) から始めて `./scripts/verify-skills.sh` を走らせてください。

**唯一重要なルール: Claude 固有の frontmatter を全部剥がしても、同じ挙動が成立すること。** Cursor が理解するのは `name` / `description` / `paths` / `disable-model-invocation` の4つだけで、残りは黙って無視されます。`allowed-tools` に書いた制約は Cursor には**存在しない**のに、何の警告も出ません。だから制約は本文に散文で書き、Claude 固有の frontmatter はその上の最適化に留めます。linter がこれを機械的に検査します。

**`disable-model-invocation` は絶対に設定しないこと。** モデルの自動起動だけでなく、プログラムからの `Skill` 呼び出しとサブエージェントへの preload もブロックするので、他のスキルに委譲するスキルが**無警告で壊れます**。

`SKILL.md` は 12KB 以下に保ってください。スキル本文はセッション終了まで context に残り続け、再読み込みされません。auto-compaction 後は各スキルの先頭 5,000 トークン程度しか復元されません。長い内容は `reference/` に置いて必要時に読ませます。

## テスト

```bash
./scripts/verify-skills.sh      # スキルの lint
./scripts/test-verify-gate.sh   # 検証ゲートの 38 テスト
```

ゲートだけは実テストを持っています。**フェイルクローズでなければならない唯一のコンポーネント**だからです。武装していないときに黙ること、失敗時にブロックすること、連続失敗でエスカレートすること、知らないリポジトリで推測しないこと、「ユーザーに実行を依頼した」を結果として受け付けないこと、そして Cursor 経路では follow-up 予算を使い切らないこと、を固定しています。

## シークレット

ここには何も秘密を置きません。インストーラは**自分が書いていないものに触らない**設計です。

`setup.sh` はテンプレートが宣言したキーだけをマージし、書いた内容を `~/.claude/.dotagents-managed.json` に記録し、編集前にバックアップを取り、既存の値は読みも書き換えもしません（エージェント設定に既に入っている資格情報を含む）。既存のフックは置換ではなく追記します。`./scripts/setup.sh uninstall` は追加したぶんだけを正確に取り消し、revert はバイト単位で一致することを検証済みです。

CI では gitleaks を全履歴に対して走らせています。

## ライセンス

[MIT](LICENSE)
