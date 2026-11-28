# dotagents

[![CI](https://github.com/bwkw/dotagents/actions/workflows/ci.yml/badge.svg)](https://github.com/bwkw/dotagents/actions/workflows/ci.yml) · [MIT ライセンス](LICENSE)

dotagents は、設計の相談や変更の検証、PR レビューに使う個人用の開発ツールです。スキルと hook をマシンに一度入れると、Claude Code・Cursor・Codex で使えます。検査コマンドはプロジェクトごとに dotagents に登録します。

## インストール

Git、Bash、Node.js 24 以上が必要です。[推奨する Node.js の版](.node-version)を使ってください。CI は macOS と Linux で実行しています。Windows での動作は未確認です。

```bash
git clone https://github.com/bwkw/dotagents ~/private/dotagents
cd ~/private/dotagents
./scripts/setup.sh install --dry-run
./scripts/setup.sh install
./scripts/setup.sh status
```

`install` はスキルへのリンクを作り、セッション開始時・編集時・ターン終了時に動く hook をコピーします。Claude Code のテレメトリや組み込みスキルの設定を残すには、`install` に `--no-opinions` を付けます。更新で hook が変わったら `install` をもう一度実行してください。dotagents を外すには `./scripts/setup.sh uninstall` を使います。[自動実行される処理と設定](SECURITY.md)

## 何をしたいかで選ぶ

Claude Code・Cursor では `/da`、Codex では `$da` と入力すると一覧が出ます。たとえば、変更の検証は `/da-verify` または `$da-verify` です。

| やりたいこと | 入口 | 受け取るもの |
|---|---|---|
| 動作や設計の経緯、障害の原因を調べたい | `da-investigate` | 実装・履歴・実測に基づく説明 |
| 設計を固めたい、仕様や修正計画を書きたい | `da-plan` | 設計案とその理由。未決の点は対話で詰め、担当や処理の順番が案によって変わるときは図で見比べる |
| 機能を作りたい、不具合を直したい | `da-implement` | 変更したコードと、利用者の操作で確かめた結果 |
| 設計案や PR の問題を見つけたい | `da-review` | 設計なら問題が起きる条件や移行順の懸念。PR なら指摘の根拠と差分の該当箇所 |
| 今の変更を出してよいか確かめたい | `da-verify` | 登録済みの検査結果と未確認の項目 |
| 同じ失敗を次の変更でも検出したい | `da-write-checks` | 実操作テスト、モデル検査、定理証明など、守りたい性質に合う検査 |
| 設計判断を ADR に残したい | `da-adr` | 決定・理由・見送った案の記録。既存の ADR は図にもできる |
| PR 本文を書きたい、レビューを依頼したい | `da-pr` | 変更の要点と確認箇所を示す本文、または Greptile への依頼文 |
| どのスキルを追加するか、整理するか決めたい | `da-skills-audit` | 用途の重複、スキル同士の依存関係、説明文の長さ |

「二重送信が起きる設計か見て」は `da-review`、「二重送信を直して」は `da-implement`、「同じ操作順で再発したら検出して」は `da-write-checks` に頼みます。操作動画は「この機能を CS に説明するデモ動画を作って」と依頼できます。[形式検証の例と図](docs/verification.md#作業ツリーごとの試行回数を検査する) · [PR 本文の例](skills/da-pr/reference/pr-template.md) · [旧スキル名との対応](docs/superpowers/plans/2026-11-28-skill-architecture.md)

## 自分のリポジトリで検証する

まず、検証したいリポジトリで `da-verify` を呼びます。そのリポジトリ用の設定がまだなければ、[プロファイルの例](profiles/_example.node-pnpm.json)を参考に、Git リモートと普段の検査コマンドを dotagents の `profiles/<名前>.json` に登録してください。設定があるリポジトリで `da-verify` を呼ぶと、ターン終了時の検証ゲートが有効になり、登録した検査が走ります。[プロファイルの書き方](skills/da-verify/reference/profile-authoring.md)

**Codex では初回に `/hooks` で hook を信頼してください。** 検査に失敗すると、Claude Code と Codex ではゲートがターンの終了を止められます。Cursor では、作業を続けるようメッセージが届きます。導入状態を調べるには `./scripts/setup.sh doctor` を使います。[ホストごとの挙動](docs/harness-facts.md)

## 実装から PR までをループで回す

変更したいリポジトリで、次のように依頼を一文で渡します。小さな変更はそのまま実装・検査・レビューに進みます。大きな変更は先に人が設計を確認します。PR のマージは人が行います。[認証・準備・実行手順](docs/loops.md#打つのは1つ)

```bash
~/private/dotagents/scripts/loop.sh "認証を OIDC に移行したい"
```

| 規模 | 変更の目安 | 人が参加する段階 |
|---|---|---|
| **XS** | 小さく、既知の範囲で完結する | PR とレビュー所見を読む |
| **S** | 小規模で、一部に未確認事項がある | 検査・レビュー・修正の結果を台帳で読む |
| **M** | 複数の層やリスクのある箇所に触れる | `/da-review` で設計を確認し、計画をコミットする |
| **L** | 広い変更や後戻りが難しい判断を含む | `/da-plan` で設計を固め、`/da-review` で確認する |

## 上流のスキル

足りない上流スキルは `setup.sh doctor` で確認できます。次のコマンドは指定したスキルだけを追加します。

```bash
npx skills@1.7.4 add obra/superpowers -g -a claude-code -a cursor \
  -s writing-plans -s executing-plans -s receiving-code-review -s systematic-debugging \
  -s test-driven-development -s using-git-worktrees -s finishing-a-development-branch \
  -s verification-before-completion -s subagent-driven-development -s requesting-code-review
npx skills@1.7.4 add mattpocock/skills -g -a claude-code -a cursor -s grilling -s research
npx skills@1.7.4 add getsentry/skills -g -a claude-code -a cursor -s find-bugs -s skill-scanner
```

### 用途に応じて入れるもの

| 用途 | スキル |
|---|---|
| 返信・進捗報告・PR の説明・ADR を出す前に日本語を推敲する | [ja-writing-humanizer の導入と適用範囲](docs/external-skills.md#日本語の下書きを推敲する) |
| 状態遷移を検査する、繰り返す失敗を防ぐ | `statechart`、`correct`（[pstack の採用記録](docs/pstack.md)） |
| 設計を見直す、用語をそろえる | `improve-codebase-architecture`、`codebase-design`、`domain-modeling` |
| 構成図・画面・試作品を作る | `archify`、`frontend-design`、`prototype` |
| 振り返りを書く、手動作業を案内する | `retro`、`writing-for-agents`、`wizard` |

[用途別の導入コマンド](docs/external-skills.md#用途別の導入コマンド)

## 開発と設計の資料

- スキルを追加・変更するには、[開発手順](CONTRIBUTING.md)と[スキルのひな型](_template/SKILL.md)を使います。全検査は `./scripts/check.sh` で実行できます。
- スキル、hook、サブエージェントの使い分けは[仕組みの選び方](docs/mechanisms.md)に、採用理由や過去の判断は[設計方針](docs/design.md)と[決定の記録](docs/decisions.md)にあります。
- [開発を自動化した事例の比較](docs/evaluations/2026-11-28-software-factory.md)と[環境依存を減らした記録](docs/portability.md)には、参照した資料と実際に試した範囲を載せています。
