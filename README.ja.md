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
/da-investigate       この変更が何に触れ、何が壊れるか — file:line 付きで
/writing-plans     計画をディスクに落とす
/da-design-review     ← 実装される前に、その計画をレビューする
```

`/da-design-review` は、後のコードレビューが**構造上見られないもの**を探します: **一方通行の扉**（何がいつ不可逆になるか）、移行順序、デプロイの中間状態が全て成立するか、そして**計画が一言も触れていないもの** —— ロールバック、既存データ、デプロイ中の in-flight リクエスト、動いたと分かるシグナル。**不在はレビューが最も苦手で、本番の驚きの主因です。**

`/da-investigate` は予算（25ファイル・検索3ラウンド）を固定し、安いはしごから登ります: ripgrep → 構造検索 → LSP → ファイル通読。確信度は **Confirmed / Inferred / Unconfirmed の3語に固定**（「probably」「should be」は、まさに重要な区別を潰すので禁止）、そして**確認しなかったことを名指しします**。

### 2 — コードを書いている間

```bash
~/private/dotagents/scripts/gate.sh arm    # チェックが通るまでこのリポを保留する
```

あとは作業します —— 上流の `/executing-plans`、`/tdd`、`/systematic-debugging`。主張ではなく**証拠**が欲しいときに `/da-verify`。

**ゲートが本題です。** エージェントは作業が**完了したように見えた**時点で止まります。実行できるチェックが無ければそれが唯一のシグナルで、**あなたが検証ループそのものになります**。ゲートはターン終了時にそのリポジトリ自身のコマンドを走らせ、赤い間は終了を拒否します。

```bash
scripts/gate.sh disarm                     # 全部緑になったら
```

### 3 — 書いた後

```
/da-review-all        変更が触れた全ての層＋層をまたぐリスク
/da-review-backend    サーバコード、マイグレーション、契約、キュー、依存
/da-review-frontend   コンポーネント、ルート、hook、store、スタイル、i18n
/da-review-infra      Terraform、CDK、k8s、IAM、ネットワーク、パイプライン
/da-pr-describe       diff を開く前に読める PR 説明
```

**層別レビューはそれぞれ単独で呼べるスキルです。** `/da-review-all` は変更を分類し、該当する層のスキルを走らせたうえで、**どの層のレビューにもできないこと**をやります: 契約変更とその消費側が順序を違えて出る、起動時に都度読まれる config が未デプロイのコードに出会う、共有された既定の正しさが**別の層**の代償処理に依存している。

4本は**同じ姿勢**（*clean は既定値ではなく、証拠で勝ち取る結論*）と**同じ所見の規律**を共有します。だから層別レビューと層をまたぐレビューで重大度の基準がずれません。

**どのレビューも報告の前に敵対的検証を1パス通します。** 上位2つの重大度の所見は、**視点の異なる3つの `da-review-verifier` サブエージェント**（到達可能か / 別の場所で既に守られていないか / 重大度は妥当か）に渡され、**2つが反証に失敗したものだけが生き残ります**。立証できなかった検証者は `uncertain` ではなく **`refuted`** を返します —— 直感の逆であり、レポートが短く保たれる理由です。

24本全部の「これを打つ / いつ」表は[下にあります](#何が入っていて何と言えばいいか)。それとは別に Claude Code の組み込みが近い領域を覆っています: **`/review`** は GitHub PR、**`/code-review`** は作業差分、**`/security-review`** はセキュリティ専門。`/find-bugs` と `/da-review-all` はどちらも「review changes」を主張するので、素の「レビューして」ではどちらが選ばれるか分かりません。**名前で指定すればコイントスが消えます**。

### 4 — 定期的に

```
/da-skills-audit      このツールキット自身の failure mode は蓄積
/skill-scanner     新しく入れた第三者スキルを信用する前に監査する
```

### 上記より効く習慣2つ

**無関係なタスクの間で `/clear`。** 前のタスクの文脈を抱えたセッションは、今のタスクについてより悪い判断をします。

**同じチェックが2回落ちたら、パッチをやめる。** 試したことを書き出し、clear して、それを織り込んで再開する。修正の繰り返しは失敗したアプローチを堆積させ、試行ごとに悪化します。ゲートが2回目でメッセージをエスカレートするのはこの理由です。

---

## 何が入っているか

**自作は9スキル**、残り15本は上流から入れています —— 方法論はそれを本業にしている人たちが維持した方が良いので。自作なのは**意見をエンコードしたもの**だけです: 何を報告に値する所見とするか、何がレビューを信頼できるものにするか、何が真であれば完了と呼べるか。下の表で **●** が付いているものです。

加えて `agents/` に**サブエージェント2本**。グローバルに入るのでどのリポジトリにも存在します: **`da-review-verifier`**（敵対的。既定で反証し、find フェーズには参加していない）と **`da-codebase-explorer`**（読み取り専用、`file:line` 証拠、明示的な予算）。レビュー系が名指しで委譲します。これが存在する前は、5ファイルが「リポジトリが専用エージェントを定義していれば優先」と書いていましたが、**このツールキットはプロダクトリポに1ファイルも置かない**ので、その分岐は永遠に到達しませんでした。[ADR 0005](docs/adr/0005-mechanism-taxonomy-and-pruning.md) 参照。

## 何が入っていて、何と言えばいいか

**`/da` と打てば、このリポジトリのものだけが出ます。** ここで配っているものは全て `da-`（dotagents）を前置しています —— スキル9本とサブエージェント2本。これで2つの問題が同時に解けます: `/` メニューでは自作と第三者製20数本を見分ける手段が他に無いこと、そして**前置なしの名前は組み込みを無言で隠す**こと（`review` という名前のスキルが Claude Code の `/review` を隠す事故が実際に起きました）。

**全24スキル。** 開発ループの順に並べています。**●** が自作、他は上流で、上流のものは元の名前のままです。

| これを打つ | いつ | |
|---|---|---|
| **1. 何を作るか分かる前** | | |
| `/grill-me` | 大まかな案があり、要件が本当に固まるまで質問攻めにしてほしいとき | |
| `/brainstorming` | 何かを作り始める前に、意図と選択肢を発散させたいとき | |
| `/da-investigate` | 「X はどこにある」「何が依存している」「この変更は何に触る」 —— `file:line` で予算内に答える | ● |
| **2. コードを書く前** | | |
| `/writing-plans` | 仕様があり、コードに触る前に計画をディスクに置きたいとき | |
| `/da-design-review` | 計画・設計ドキュメントができたとき。**後のコードレビューでは直せないもの**を捕まえる —— 一方通行の扉、移行順序、ロールバック | ● |
| `/executing-plans` | 書かれた計画を、レビューの節目付きで実行したいとき | |
| `/using-git-worktrees` | 作業を今のワークスペースから隔離したいとき | |
| **3. コードを書いている間** | | |
| `/test-driven-development` | 実装の前。あらゆる機能追加・バグ修正で | |
| `/systematic-debugging` | バグ・テスト失敗・説明できない挙動。**修正案を出す前に** | |
| `/da-verify` | 主張ではなく証拠が欲しいとき。**そのリポジトリ**の設定済みチェックを実行し、**Stop ゲートを arm する**（arm するのはこれだけ） | ● |
| `/verification-before-completion` | 完了を主張しようとしているが、`/da-verify` 用の profile が無いリポジトリのとき | |
| `/resolving-merge-conflicts` | merge / rebase のコンフリクトが進行中のとき | |
| **4. コードを書いた後** | | |
| `/da-review-all` | **既定のレビュー。** 変更を分類し、該当する層別レビューを走らせ、**層と層の間**に落ちるものを見る | ● |
| `/da-review-backend` | backend だと既に分かっているとき —— API、ドメイン、マイグレーション、契約、キュー、依存 | ● |
| `/da-review-frontend` | frontend だと既に分かっているとき —— コンポーネント、ルート、hook、store、スタイル、i18n | ● |
| `/da-review-infra` | インフラだと既に分かっているとき —— Terraform、CDK、k8s、IAM、パイプライン | ● |
| `/find-bugs` | ブランチ差分への素早いバグ・脆弱性スイープ。先に攻撃面をマッピングする | |
| `/requesting-code-review` | レポートではなく**手順**が欲しいとき —— 推論を見ていないフレッシュな文脈のレビュアーを立てる | |
| `/receiving-code-review` | 指摘が来て、反射的に実装せず**評価したい**とき | |
| `/da-pr-describe` | diff を開く前に読める PR 説明が必要なとき。**自分で打つ —— 自動では絶対に起動しません** | ● |
| `/finishing-a-development-branch` | 実装が終わり、どう統合するか決めるとき | |
| `/handoff` | この会話を別のエージェントが引き継げる形に圧縮する | |
| **5. 定期的に** | | |
| `/da-skills-audit` | スキルを追加する前、自動起動しなくなったとき、定期的な掃除 | ● |
| `/skill-scanner` | 新しく入れた第三者スキルを信用する前。**bloat ではなくセキュリティ** | |

トリガの重複は実在します: 素の「レビューして」は `/da-review-all` にも `/find-bugs` にも行きえるし、「終わった？」は `/da-verify` にも `/verification-before-completion` にも行きえます。どちらも妥当なので、**名前で指定すればコイントスが消えます**。

### なぜ「コマンド」ではなく全部スキルなのか

**このリポジトリに commands ディレクトリはありません。**これは抜けているのではなく意図的です。

[公式](https://code.claude.com/docs/en/skills)が明言しています: *「Custom commands have been merged into skills… Skills are recommended」*。素の `commands/*.md` が好ましいケースは公式に1つもありません。Cursor の commands ドキュメントページは現在 404 です。

**スラッシュコマンド**はプロンプトのテンプレートでした。`/name` と打つと展開される、それが機構の全部です。**スキル**はディレクトリ（`SKILL.md` ＋ 必要になった時だけ読む reference 群）で、**3通りで到達できます**: `/name` と打つ、リクエストが `description` に一致してモデルが選ぶ、別のスキルが名前で呼ぶ。1つ目は3つ目までの機能の**部分集合**なので、コマンドとして書いたものは**機能を2つ切ったスキル**にすぎません。

この4本では具体的に効いています。`/da-review-backend` は、**あなたが直接呼んだとき**と **`/da-review-all` が層の1つとして呼んだとき**の両方で動く必要があります。コマンドなら2ファイルに分かれて乖離していく —— このリポジトリの前身が実際にそう腐りました。参照セット（姿勢・プロセス・所見の規律・無音事故パターン）は symlink で共有しているので、**規律を1箇所直せば全層と層をまたぐパスに同時に届きます**。

プロンプトテンプレートの用途が消えたわけではなく、今は `disable-model-invocation: true` という綴りになりました。**description が context から完全に消えるので予算コストがゼロ**になります。`/da-pr-describe` がこれです（GitHub に書き込むので、タイミングはあなたのもの）。逆に **`/da-verify` と層別3本には絶対に付けません** —— 名前で到達されるものなので、付けるとディスパッチが**無言で壊れます**。lint hook とリンタの両方がテスト付きで強制しています。分類の全体像と出典は [`docs/mechanisms.md`](docs/mechanisms.md) にあります。

実際の使い勝手: **`/` を打てば全部ひとつのリストに出ます。** 2つ目の異なる呼び出し方は存在しません。

ここに置くかの判定基準: **「違う意見を持つ人にとっても同じくらい有用か？」** Yes なら上流に属します。残るのは**特定の意見をエンコードしたもの** —— 何を報告に値する所見とするか、何がレビューを信頼できるものにするか、何が真であれば完了と呼べるか。

### 検証ゲート

`hooks/dotagents-verify-gate.sh`、両エージェントで動きます。

**センチネル方式。** `gate.sh arm` するまで何もしません。常時ONのゲートは、質問に答えるだけのセッションの終わりにもテストスイートを走らせるので一日で切られます。それは無いより悪い。`gate.sh arm` は profile が無いとき警告します —— 走らせるものが無いゲートは「有効」と表示しながら全部通すので。

**コマンドは profile から引きます。** git remote で照合するので、プロダクトのリポジトリは無改変です。`agent_may_run: false` のチェックはエージェントが決して実行せず（そう文書で定めているリポジトリがあるため）、**あなた自身の出力**を要求します。profile が無ければ推測せず黙ります —— 見知らぬリポジトリで勝手に `npm test` を叩くのは、検証ツールが信用を失う典型です。

**Cursor でも走りますが、ブロックできません。** Cursor の `stop` フックには拒否の仕組みがなく、代わりに follow-up メッセージを自動投入します（`loop_limit` で打ち切り）。両フックは呼び出し元を判定して適切な方言で応答します。Cursor 側は「強い促し」と考え、重要な場面では `/da-verify` を明示実行してください。対応表は [ADR 0003](docs/adr/0003-cursor-compatible-subset.md)。

**何も起きていないように見えたら** `~/.claude/.dotagents-gate/trace.log` を読んでください。全ての呼び出しと、通した理由が記録されています。「何も起きなかった」には正当な原因が6通りあり、このファイルがそれを区別します —— 一度これが無いまま推測して、**動いているコードを変えて原因を隠しかけた**ので作りました。

### プロファイル

[`profiles/dotagents.json`](profiles/dotagents.json)（このリポジトリ自身のもので、**実際に動いている唯一の例**）か [`profiles/_example.json`](profiles/_example.json) を `profiles/<repo>.json` にコピーします。

**あなたのコピーは gitignore されます。** profile は実在のリポジトリ名・環境名、場合によっては勤務先の社内ルールを含むので、書いたマシンに留まります。`.gitignore` は許可リスト方式なので、新しい profile は**デフォルトで untracked** です（「除外し忘れるまで追跡される」の逆）。`/da-verify` が書き方を案内します。

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
  -s test-driven-development -s using-git-worktrees -s finishing-a-development-branch

# 実務 — mattpocock/skills
npx skills add mattpocock/skills -g -a claude-code -a cursor \
  -s grill-me -s handoff -s resolving-merge-conflicts

# セキュリティ — getsentry/skills
npx skills add getsentry/skills -g -a claude-code -a cursor \
  -s find-bugs -s skill-scanner
```

同じトリガを奪い合わないよう意図的に外したもの: `mattpocock/tdd` と `diagnosing-bugs`（superpowers がカバー）、`addyosmani/code-review-and-quality` と `spec-driven-development`（本リポジトリと上流でカバー）、プラットフォーム固有のもの。

**アンインストールしても Cursor では生き残ります。** `npx skills remove <name> -g -a claude-code -a cursor` はエージェント側のリンクを外して lockfile を更新しますが、**`~/.agents/skills/` の実体を残します** —— Cursor がネイティブに読むパスです。実体も消して、両者が一致することを確認してください:

```bash
diff <(ls -1 ~/.agents/skills) <(ls -1 ~/.claude/skills)
```

**測ってから削除したもの**（勘ではなく）。`/da-skills-audit` が description のトリガ語彙を総当たりで比較し、この2つが最高スコアで落ちました:

- `getsentry/security-review` — `find-bugs` と **33% 重複**。`find-bugs` は同じブランチ差分に対してバグ**と**セキュリティ**と**品質を見ます。しかも Claude Code は自前の `security-review` を同梱していて、同名の個人スキルがそれを隠すので、**外すと組み込みが戻ってきます** —— 何も失いません。
- `obra/subagent-driven-development` — **28KB**、サイズ上限の2倍以上。呼び出すとそれ全部がセッション中コンテキストに居座ります。

**2026-07-28 にさらに11本削除**し、35本 → 24本、resident な description は 6,905字 → 3,559字になりました。先に名指し参照を全数確認しています —— `brainstorming` と `using-git-worktrees` が残っているのは、**残す側のスキルがそれらを名指しで参照しているから**です。

| 削除したもの | 理由 |
|---|---|
| `find-skills` | `npx skills add` を **`-s` 無し**で教えていた。このリポジトリが不変条件で禁じている内容 |
| `using-superpowers` | 「明確化の質問を含むあらゆる応答の前にスキル起動」を強制。**`/da-investigate` と `/da-design-review` の前提条件と矛盾**（両方とも目的が言われていない依頼を拒否する） |
| `observability-and-instrumentation`, `performance-optimization`, `deprecation-and-migration`, `documentation-and-adrs` | 専門的な助言スキル。開発ループの外 |
| `codebase-design`, `domain-modeling`, `improve-codebase-architecture` | 相互参照する3本セット。参照切れが出ないようまとめて削除 |
| `research`, `dispatching-parallel-agents` | ハーネスが WebFetch と並列エージェントをネイティブに持つ |

**この11本の削除に使用実績の裏付けはありません。**これは明記しておく価値があります: 35本のうち34本は同じ日にインストールされたので、「一度も起動されていない」は「数時間前に入れた」の意味しかありませんでした。根拠は**構造**です —— 参照切れ、挙動の衝突、ネイティブ機能との重複 —— 測定ではありません。[ADR 0005](docs/adr/0005-mechanism-taxonomy-and-pruning.md) 参照。

スキルは**エージェントの全権限で動きます**。`/skill-scanner` はプロンプトインジェクションとサプライチェーンリスクを監査します —— 実際にこのリポジトリ自身の frontmatter の不具合を見つけました。そういうためのものです。

## Advisor（オプトイン）

メインモデルに、より強いモデルを**相談役**として組み合わせます。Claude が判断の分岐点で呼びます —— アプローチを決める前、同じエラーが繰り返すとき、完了を宣言する前。**subagent が継承する**ので、`/da-review-all` の層別サブエージェントも同じ advisor を得ます。

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
