# dotagents

[![ci](https://github.com/bwkw/dotagents/actions/workflows/ci.yml/badge.svg)](https://github.com/bwkw/dotagents/actions/workflows/ci.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Claude Code と Cursor** のための個人用 AI 開発ツールキット。一度グローバルに入れれば、どのリポジトリでも使えます。プロダクトのリポジトリには一切手を入れません。

English: [README.md](README.md) · なぜこの形なのか: [docs/design.ja.md](docs/design.ja.md)

```bash
git clone https://github.com/bwkw/dotagents ~/private/dotagents
cd ~/private/dotagents
./scripts/setup.sh install --dry-run   # 何が起きるか確認
./scripts/setup.sh install
./scripts/setup.sh status
```

必要なもの: `node`（18以上）、`bash`、`git`。macOS の bash 3.2 で全て動きます。

---

## これで回せるようになる開発ループ

パイプラインではありません。各ステップは1コマンドで、たいていのセッションは2〜3個しか使いません。

### 1 — コードが存在しない段階

**高価な判断はここで決まり、コードレビューでは取り消せません。**

```
/grill-me          要件が本当に固まるまで質問攻めにされる
/investigate       この変更が何に触れ、何が壊れるか — file:line 付きで
/writing-plans     計画をディスクに落とす
/design-review     ← 実装される前に、その計画をレビューする
```

`/design-review` は、後のコードレビューが**構造上見られないもの**を探します: **一方通行の扉**（何がいつ不可逆になるか）、移行順序、デプロイの中間状態が全て成立するか、そして**計画が一言も触れていないもの** —— ロールバック、既存データ、デプロイ中の in-flight リクエスト、動いたと分かるシグナル。**不在はレビューが最も苦手で、本番の驚きの主因です。**

`/investigate` は予算（25ファイル・検索3ラウンド）を固定し、安いはしごから登ります: ripgrep → 構造検索 → LSP → ファイル通読。確信度は **Confirmed / Inferred / Unconfirmed の3語に固定**（「probably」「should be」は、まさに重要な区別を潰すので禁止）、そして**確認しなかったことを名指しします**。

### 2 — コードを書いている間

```bash
~/private/dotagents/scripts/gate.sh arm    # チェックが通るまでこのリポを保留する
```

あとは作業します —— 上流の `/executing-plans`、`/tdd`、`/systematic-debugging`。主張ではなく**証拠**が欲しいときに `/verify`。

**ゲートが本題です。** エージェントは作業が**完了したように見えた**時点で止まります。実行できるチェックが無ければそれが唯一のシグナルで、**あなたが検証ループそのものになります**。ゲートはターン終了時にそのリポジトリ自身のコマンドを走らせ、赤い間は終了を拒否します。

```bash
scripts/gate.sh disarm                     # 全部緑になったら
```

### 3 — 書いた後

```
/review-all        層別に並列サブエージェントでレビュー＋層をまたぐリスク
/pr-describe       diff を開く前に読める PR 説明
```

`/review-all` は変更を層で分類し、それぞれを専用サブエージェントでレビューしたうえで、**単一層のレビューでは見えないもの**を探します: 契約変更とその消費側が順序を違えて出る、起動時に都度読まれる config が未デプロイのコードに出会う、共有された既定の正しさが**別の層**の代償処理に依存している。

**どのレビューを使うか。** 変更をレビューできるものが複数入っていて、**トリガが重なっています**。期待するものが発火するのを祈らず、名前で指定してください:

| これを打つ | いつ |
|---|---|
| `/review-all` | **既定。** 複数の層に触れる変更、または不可逆性とデプロイ順序が問題になるもの。**層と層の間**に落ちるものを見るのはこれだけ |
| `/find-bugs` | 単一層で、ブランチ差分に対する素早いバグ・脆弱性スイープが欲しいとき。Sentry製で、先に攻撃面をマッピングします |
| `/security-review` | セキュリティ専門 —— 認可、インジェクション、秘密の扱い |
| `/requesting-code-review` | レポートではなく**手順**が欲しいとき —— あなたの推論を見ていないフレッシュな文脈のレビュアーを立てる |
| `/review`, `/code-review` | Claude Code の組み込み。`/review` は GitHub PR、`/code-review` は作業差分 |

`find-bugs` の description は「use when asked to review changes」と書いていて、`/review-all` が主張する土地と同じです。だから素の「レビューして」ではどちらが選ばれるか分かりません。どちらも妥当なので、**名前で指定すればコイントスが消えます**。

### 4 — 定期的に

```
/skills-audit      このツールキット自身の failure mode は蓄積
/skill-scanner     新しく入れた第三者スキルを信用する前に監査する
```

### 上記より効く習慣2つ

**無関係なタスクの間で `/clear`。** 前のタスクの文脈を抱えたセッションは、今のタスクについてより悪い判断をします。

**同じチェックが2回落ちたら、パッチをやめる。** 試したことを書き出し、clear して、それを織り込んで再開する。修正の繰り返しは失敗したアプローチを堆積させ、試行ごとに悪化します。ゲートが2回目でメッセージをエスカレートするのはこの理由です。

---

## 何が入っているか

**自作は6スキルだけ。** 残りは上流から入れます —— 方法論はそれを本業にしている人たちが維持した方が良いので。

| スキル | 何をするか |
|---|---|
| `/review-all` | 層の判定、層別の並列レビュー、層をまたぐ不可逆性 |
| `/design-review` | コードが存在しない段階での計画レビュー —— 一方通行の扉、移行順序、欠落 |
| `/investigate` | コードベースへの問いに `file:line` で、予算内で、穴を名指しして答える |
| `/verify` | そのリポジトリ自身のチェックを実行し、証拠付きで報告 |
| `/pr-describe` | PR タイトルと説明。Artifact が使える環境ではビジュアルサマリも公開 |
| `/skills-audit` | description 予算、トリガの重複、Cursor 非互換、未使用 |

ここに置くかの判定基準: **「違う意見を持つ人にとっても同じくらい有用か？」** Yes なら上流に属します。残るのは**特定の意見をエンコードしたもの** —— 何を報告に値する所見とするか、何がレビューを信頼できるものにするか、何が真であれば完了と呼べるか。

### 検証ゲート

`hooks/dotagents-verify-gate.sh`、両エージェントで動きます。

**センチネル方式。** `gate.sh arm` するまで何もしません。常時ONのゲートは、質問に答えるだけのセッションの終わりにもテストスイートを走らせるので一日で切られます。それは無いより悪い。`gate.sh arm` は profile が無いとき警告します —— 走らせるものが無いゲートは「有効」と表示しながら全部通すので。

**コマンドは profile から引きます。** git remote で照合するので、プロダクトのリポジトリは無改変です。`agent_may_run: false` のチェックはエージェントが決して実行せず（そう文書で定めているリポジトリがあるため）、**あなた自身の出力**を要求します。profile が無ければ推測せず黙ります —— 見知らぬリポジトリで勝手に `npm test` を叩くのは、検証ツールが信用を失う典型です。

**Cursor でも走りますが、ブロックできません。** Cursor の `stop` フックには拒否の仕組みがなく、代わりに follow-up メッセージを自動投入します（`loop_limit` で打ち切り）。両フックは呼び出し元を判定して適切な方言で応答します。Cursor 側は「強い促し」と考え、重要な場面では `/verify` を明示実行してください。対応表は [ADR 0003](docs/adr/0003-cursor-compatible-subset.md)。

**何も起きていないように見えたら** `~/.claude/.dotagents-gate/trace.log` を読んでください。全ての呼び出しと、通した理由が記録されています。「何も起きなかった」には正当な原因が6通りあり、このファイルがそれを区別します —— 一度これが無いまま推測して、**動いているコードを変えて原因を隠しかけた**ので作りました。

### プロファイル

[`profiles/dotagents.json`](profiles/dotagents.json)（このリポジトリ自身のもので、**実際に動いている唯一の例**）か [`profiles/_example.json`](profiles/_example.json) を `profiles/<repo>.json` にコピーします。

**あなたのコピーは gitignore されます。** profile は実在のリポジトリ名・環境名、場合によっては勤務先の社内ルールを含むので、書いたマシンに留まります。`.gitignore` は許可リスト方式なので、新しい profile は**デフォルトで untracked** です（「除外し忘れるまで追跡される」の逆）。`/verify` が書き方を案内します。

### 仕組み

```
dotagents/skills/<name>/
        ↑ symlink
~/.agents/skills/<name>          ← Cursor はここを直接読む
        ↑ symlink
~/.claude/skills/<name>          ← Claude Code は symlink を追う
```

実体はひとつ。ここを編集すれば同期の手順なしに両エージェントへ反映されます。リンクを張るのは Claude Code 側だけ —— Cursor が `~/.agents/skills/` を読むことは**推測ではなく観測**です（[ADR 0001](docs/adr/0001-global-install-via-agents-dir.md)）。

フックだけは **実体コピー**です。symlink が切れると `exit 127` になり non-blocking として扱われるため、**ガードレールが「止まる」のではなく「開く」**からです（[ADR 0002](docs/adr/0002-hooks-are-copied-not-symlinked.md)）。

---

## 上流のスキル

ここには取り込まず、横に並べて `npx skills check` / `npx skills update` で更新します。

**選択的に入れてください。** インストールされた description は全て常にコンテキストに常駐するので、リポジトリ丸ごと入れると他の全スキルの選択精度を削ります。

```bash
# 方法論 — obra/superpowers
npx skills add obra/superpowers -g -a claude-code -a cursor \
  -s brainstorming -s writing-plans -s executing-plans -s verification-before-completion \
  -s requesting-code-review -s receiving-code-review -s systematic-debugging \
  -s test-driven-development -s subagent-driven-development -s dispatching-parallel-agents \
  -s using-git-worktrees -s finishing-a-development-branch -s using-superpowers

# 実務 — mattpocock/skills
npx skills add mattpocock/skills -g -a claude-code -a cursor \
  -s grill-me -s handoff -s research -s codebase-design -s resolving-merge-conflicts \
  -s improve-codebase-architecture -s domain-modeling

# 運用 — addyosmani/agent-skills
npx skills add addyosmani/agent-skills -g -a claude-code -a cursor \
  -s performance-optimization -s observability-and-instrumentation \
  -s documentation-and-adrs -s deprecation-and-migration

# セキュリティ — getsentry/skills
npx skills add getsentry/skills -g -a claude-code -a cursor \
  -s security-review -s find-bugs -s skill-scanner
```

同じトリガを奪い合わないよう意図的に外したもの: `mattpocock/tdd` と `diagnosing-bugs`（superpowers がカバー）、`addyosmani/code-review-and-quality` と `spec-driven-development`（本リポジトリと上流でカバー）、プラットフォーム固有のもの。

**測ってから削除したもの**（勘ではなく）。`/skills-audit` が description のトリガ語彙を総当たりで比較し、この2つが最高スコアで落ちました:

- `getsentry/security-review` — `find-bugs` と **33% 重複**。`find-bugs` は同じブランチ差分に対してバグ**と**セキュリティ**と**品質を見ます。しかも Claude Code は自前の `security-review` を同梱していて、同名の個人スキルがそれを隠すので、**外すと組み込みが戻ってきます** —— 何も失いません。
- `obra/subagent-driven-development` — **28KB**、サイズ上限の2倍以上。呼び出すとそれ全部がセッション中コンテキストに居座ります。`dispatching-parallel-agents` が同じ土地を 6KB でカバーします。

スキルは**エージェントの全権限で動きます**。`/skill-scanner` はプロンプトインジェクションとサプライチェーンリスクを監査します —— 実際にこのリポジトリ自身の frontmatter の不具合を見つけました。そういうためのものです。

## Advisor（オプトイン）

メインモデルに、より強いモデルを**相談役**として組み合わせます。Claude が判断の分岐点で呼びます —— アプローチを決める前、同じエラーが繰り返すとき、完了を宣言する前。**subagent が継承する**ので、`/review-all` の層別サブエージェントも同じ advisor を得ます。

```bash
./scripts/setup.sh install --advisor      # advisorModel: opus を設定
```

オプトインにした理由は公式ドキュメントが明記している3点です: **experimental**、**Anthropic API 専用**（Bedrock / AWS / GCP Agent Platform / Foundry では使えない）、そして **advisor モデルのレートで追加トークンを消費する**。呼び出し回数の上限も強制もありません —— Claude が判断し、唯一の制御はプロンプトで「consult the advisor before you continue」と言うことです。

止めるには `/advisor off`、ツール自体を無効化するなら `CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1`。切り替えてもメインモデルの prompt cache は無効化されません。

**「オーケストレータ＋hot path 外の相談役」パターンの、公式に出荷された形**です。自分で似たものを作る前に知っておく価値があります。

## ステータスライン（オプトイン）

コンテキスト使用率・モデル・worktree・ブランチ・セッション費用。使用率が常時表示に値するのは、ここの規律がほぼ**コンテキストの使い方**の話だからです（67%未満で緑、85%超で赤）。

```bash
./scripts/setup.sh install --statusline
```

取得できないフィールドは「unknown」ではなく**消えます**。フィールド名はバージョンで変わり、古い数字を出し続けるステータスラインは短いものより悪いので。

## スキルの書き方

[`_template/SKILL.md`](_template/SKILL.md) から始めて `./scripts/verify-skills.sh`。

不変則は [`AGENTS.md`](AGENTS.md) にあります —— あれが常時ロードされる層で、**無警告で失敗する**ものだけを置いています。全体を規定する1つ: **Claude 固有の frontmatter を全部剥がしても同じ挙動が成立すること。** Cursor はそれらを何も言わずに無視し、しかも**別のモデルファミリー**で動くので。

## テスト

```bash
./scripts/verify-skills.sh      # スキルの lint
./scripts/test-verify-gate.sh   # 42テスト — ゲート
./scripts/test-setup.sh         # 14テスト — インストーラ（偽の HOME に対して）
```

CI は両スイートを **Linux と macOS の両方**で走らせます。壊れ方が両方向に出たからです —— bash 4 構文は Linux で通り macOS で落ち、`mktemp -t` の綴りは BSD で通り GNU coreutils で落ちる。

実テストを持つのはゲートとインストーラだけで、理由は正反対です。**ゲートはフェイルクローズでなければならない** —— 見つかった全てのフェイルオープンに回帰テストがあります。**インストーラは自分のものでないファイルを編集する** —— 他人の資格情報と他人のフックを含むので、テストは「書いていない秘密が生き残る」「他3ツールのフックが生き残る」「uninstall が何も残さない」を固定しています。

## シークレット

ここには何も秘密を置かず、インストーラは自分が書いていないものに触りません。テンプレートが宣言したキーだけをマージし、`~/.claude/.dotagents-managed.json` に記録し、先にバックアップを取り、自分のものでない既存値は書き換えません。既存フックは置換ではなく追記です。

`uninstall` が戻すのは各キーの**値**であって、ファイルの**バイト列**ではありません。設定は固定の整形で書き直されるので、別の整形をしていたファイルは整形され直します。`test-setup.sh` が検証しているのは値であり、それが正直に約束できることです。

CI では gitleaks を全履歴に対して走らせています。

## ライセンス

[MIT](LICENSE)
