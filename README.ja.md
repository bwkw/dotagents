# dotagents

[![ci](https://github.com/bwkw/dotagents/actions/workflows/ci.yml/badge.svg)](https://github.com/bwkw/dotagents/actions/workflows/ci.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Claude Code と Cursor** のための個人用 AI 開発ツールキット。一度グローバルに入れれば、どのリポジトリでも使えます。プロダクトのリポジトリには一切手を入れません。

English: [README.md](README.md)

ループ（出典付き）: [docs/workflow.ja.md](docs/workflow.ja.md) · なぜこの形なのか・誰の実践から組み立てたか:
[docs/design.ja.md](docs/design.ja.md) · どの仕組みを選ぶか: [docs/mechanisms.ja.md](docs/mechanisms.ja.md) ·
判断の記録: [docs/adr/](docs/adr/)

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

公式のループは **Explore → Plan → Implement → Commit** の4フェーズ。*verify* は「段階」ではなく**どの段階にも必要な性質**、*review* は毎回の儀式ではなく**リスクが高いとき・見ていなかったときのエスカレーション**です。全体像・中断条件・良い出典どうしが食い違う箇所は [`docs/workflow.ja.md`](docs/workflow.ja.md) に。覚える価値があるのは3つ:

- **差分を1文で説明できるなら計画は飛ばす。**
- **計画と実装の間で `/clear` して新セッション。** その時点で計画はディスクにある。
- **同じ問題で2回修正に失敗したらセッションを捨てる。** 学んだことを織り込んで prompt を書き直す。失敗したアプローチを抱えた長いセッションより、良い prompt の綺麗なセッションが勝つ。

### 5つのフェーズと、2つの脇道

実際の作業は1本の線形ループでは来ません。**フローを選んで、その行だけ読んでください。**
**●** はこのリポジトリ製、**○** は上流、**◆** は Claude Code 組み込みです。

| フロー | 順番 |
|---|---|
| **0. 地面を調べる** —— 「世の中は実際どうやっているのか」 | ○ `/research` —— 外部の一次情報を当たり、**リポジトリ内のファイルに書き出す**。**選択肢とトレードオフはここから出てきます**。ファイルなので `/clear` を生き延びる |
| **1. 何を作るかを固める** | 出てきた選択肢に対して ○ `/grill-me` → **この**コードベースで何に触るかは ● `/da-investigate` |
| **2. 書き下す** | 決定は ○ `/documentation-and-adrs`、spec は openspec か ○ `/writing-plans` → 書いたものに **● `/da-design-review`** → そして `/clear` |
| **3. 実装する** | 計画があれば ○ `/executing-plans` —— **いずれにせよテストが先** → **● `/da-verify`** |
| **4. 批判的にレビューして改善を回す** | **● `/da-review-all`** → 2本目: ◆ `/code-review` か ○ `/find-bugs` → **● `/da-fix-plan`** → 修正 → ● `/da-verify` → ● `/da-pr-describe` |
| *他人の PR* | ◆ `/review <PR>`、深さなら ● `/da-review-all <base>` → 取りまとめるなら ● `/da-fix-plan` |
| *エラー* | **○ `/systematic-debugging`** —— 修正より先に root cause、飛躍を拒否 → 疑わしい箇所が決まったら ● `/da-investigate` で影響範囲。修正は自身の Phase 4 が担う → ● `/da-verify` |

この表について、これまで暗黙だったことが4つあります。

**全部が `da-` ではないのは意図的です。** prefix は**このリポジトリが所有し書き換えて良いもの**を示します。上流スキルが元の名前なのは、**その場で編集しても次の `npx skills update` で失われる**からです —— `/grill-me` に `da-` のラッパーを被せれば、乖離していく2つ目のファイルができる。それはこのツールキットが避けるために作られた失敗そのものです。`/da` はメニューを**自作分に絞る**ためのもので、フローは意図的にその外にも手を伸ばします。

**テストが先、が基盤であってステップではありません。** 呼び出しを覚えておく必要のあるスキルではなく、`AGENTS.md` の**常設ルール**にしました —— 呼ばないと効かない既定値は既定値ではないので。詳細な手順が欲しいときは `/test-driven-development`。**バグ修正はバグを再現するテストから始まり**、実装の**後**に書かれたテストは「後から書いた」とラベルされます（検証として提示されません）。

**`gate.sh arm` は実装フローから外しました。`/da-verify` 自身が arm するからです** —— その Step 0 がまさにそれをやります。`/da-verify` を1回走らせれば（打っても自動発火でも）、以降そのセッションでゲートが有効になります。`arm` を直接使うのは**verify では覆えない場合だけ** —— つまり「まだ一度も verify が走っていない段階から、無人セッションを最初のターンから保留したい」とき。`disarm` はそのリポジトリが質問応答に戻り、終了時にテストスイートを走らせたくないとき。

**他人のものをレビューするのは別の姿勢です。** 意図が分からないので、最初のパスは説明・issue・コミット・参照 spec から意図を再構成し、**所見を1つも出す前に言い直します**。アプローチの違いは欠陥ではなく、既存の問題は「既存」とラベルしてブロックしません。そして**エラー調査はレビューではありません** —— バグにレビュースキルを向けると、原因ではなく近所の不完全さの一覧が返ってきます。

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

作業します —— 書かれた計画があれば `/executing-plans`、バグなら `/systematic-debugging`。**どちらの場合もテストが先**です（`AGENTS.md` の常設ルール）。主張ではなく**証拠**が欲しくなったら `/da-verify`。

**ゲートが本題で、それを ON にするのが `/da-verify` です。** エージェントは作業が**完了したように見えた**時点で止まります。実行できるチェックが無ければそれが唯一のシグナルで、**あなたが検証ループそのものになります**。`/da-verify` は最初のステップでゲートを arm し、以降はターン終了ごとにそのリポジトリ自身のコマンドを走らせ、赤い間は終了を拒否します。

つまり通常のフローに**別途 arm するステップはありません**。直接触るのは次の2ケースだけです。

```bash
scripts/gate.sh arm       # まだ verify が走っていない段階から、最初のターンから保留したい
scripts/gate.sh disarm    # 質問応答に戻る。終了時にスイートを走らせたくない
```

> **これは「深夜に無人で回すためのロック」ではありません。** 早めに arm しておくと、見ていないセッションが緑で終わる確率は上がります。それだけです。ゲート側では直せない制限が3つあります。**Claude Code は Stop hook を8回連続ブロックで解除する**ので、本当に詰まった実行は通されて赤のまま終わります。**Cursor ではそもそもブロックできません** —— follow-up メッセージを注入するだけで、3回目でそれも止めるので歩いて通り抜けられます。そして**拒否し続ける hook は前進ではありません** —— 同じチェックが2回落ちたら正しい手はセッションを捨てることで、保留し続けることの逆です。
>
> 本当に寝ている間に回す作業で頼れるのは、**セッションを越えて残るもの**です: ディスクの spec、CI のチェック、復帰点としてのコミット。ゲートは**1セッション内のガードレール**であって、複数セッションを見張る監督者ではありません。

### 3 — 書いた後

```
/da-review-all        レビューの入口 —— 全ての層＋層をまたぐリスク
/code-review          別の作りの2本目（バンドル）
/da-fix-plan          所見を順序付きの修正計画に —— 何を直さないかを決める
/da-pr-describe       diff を開く前に読める PR 説明
```

**入口は1つ、その裏に3層の深さ。** `/da-review-all` が変更を分類し、`da-review-backend` / `-frontend` / `-infra` に委譲します。層別は独自の姿勢・プロセス・観点クラスタを持つ完全なスキルですが、**`/` メニューには出しません** —— 打つものを4つから1つにするためです。層を名指しすれば直接届きます（「backend をレビューして」で分類を経ずに発火）。

**2本目のレビュアを、別の作りのものにしてください。** 同一の146 PR に4種のレビュアを当てた計測で、**指摘の 93.4% は4つのうち1つだけが検出、4つ全部が検出したものは0件**。単体の質より**アプローチの多様性**が効きます。だから自作のレビュー機構があってもバンドルの `/code-review` と Sentry の `/find-bugs` は抑制していません。

ディスパッチャはそのうえで、**どの層のレビューにもできないこと**をやります: 契約変更とその消費側が順序を違えて出る、起動時に都度読まれる config が未デプロイのコードに出会う、共有された既定の正しさが**別の層**の代償処理に依存している、そして**エージェントが書いた変更では**、境界の両側が一緒に書かれて互いに整合しつつ外界に対して誤っている。

4本は**同じ姿勢**（*clean は既定値ではなく、証拠で勝ち取る結論*）と**同じ所見の規律**を共有します。だから層別レビューと層をまたぐレビューで重大度の基準がずれません。

**どのレビューも報告の前に敵対的検証を1パス通します。** 上位2つの重大度の所見は、**視点の異なる3つの `da-review-verifier` サブエージェント**（到達可能か / 別の場所で既に守られていないか / 重大度は妥当か）に渡され、**2つが反証に失敗したものだけが生き残ります**。立証できなかった検証者は `uncertain` ではなく **`refuted`** を返します —— 直感の逆であり、レポートが短く保たれる理由です。

全部の「これを打つ / いつ」表は[下にあります](#何が入っていて何と言えばいいか)。知っておく価値のある組み込み: **`/review`** は GitHub PR、**`/code-review`** は作業差分、**`/security-review`** はセキュリティ専門、**`/simplify`** は品質専用で明示的にバグ探しではない。`/find-bugs` と `/da-review-all` はどちらも「review changes」を主張するので、素の「レビューして」ではどちらが選ばれるか分かりません。**名前で指定すればコイントスが消えます**。

### 4 — 定期的に

```
/skill-doctor      未使用でコンテキストを食っているスキル（バンドル）
/doctor            listing の実コストと最大寄与者（バンドル）
/da-skills-audit   過剰制約、トリガ重複、Cursor 非互換、サイズ
/skill-scanner     新しく入れた第三者スキルを信用する前のセキュリティ検査
```

**`/da-skills-audit` の前に `/skill-doctor`。** 監査はファイルを読みますが、ファイルは面全体の少数派です（下の内訳を参照）。どちらも**スキルが役に立っているか**は測りません。それは `anthropic-skills:skill-creator`（with/without の対照ベンチマーク）で、**既にインストール済み**です。

### 上記より効く習慣2つ

**無関係なタスクの間で `/clear`。** 前のタスクの文脈を抱えたセッションは、今のタスクについてより悪い判断をします。

**同じチェックが2回落ちたら、パッチをやめる。** 試したことを書き出し、clear して、それを織り込んで再開する。修正の繰り返しは失敗したアプローチを堆積させ、試行ごとに悪化します。ゲートが2回目でメッセージをエスカレートするのはこの理由です。

---

## 何が入っているか

**自作は10スキル**、残り17本は上流から入れています —— 方法論はそれを本業にしている人たちが維持した方が良いので。自作なのは**意見をエンコードしたもの**だけです: 何を報告に値する所見とするか、何がレビューを信頼できるものにするか、何が真であれば完了と呼べるか。下の表で **●** が付いているものです。

加えて `agents/` に**サブエージェント2本**。グローバルに入るのでどのリポジトリにも存在します: **`da-review-verifier`**（敵対的。既定で反証し、find フェーズには参加していない）と **`da-codebase-explorer`**（読み取り専用、`file:line` 証拠、明示的な予算）。レビュー系が名指しで委譲します。これが存在する前は、5ファイルが「リポジトリが専用エージェントを定義していれば優先」と書いていましたが、**このツールキットはプロダクトリポに1ファイルも置かない**ので、その分岐は永遠に到達しませんでした。[ADR 0005](docs/adr/0005-mechanism-taxonomy-and-pruning.md) 参照。

## 何が入っていて、何と言えばいいか

**`/da` と打てば、このリポジトリのものだけが出ます。** ここで配っているものは全て `da-`（dotagents）を前置しています —— スキル10本とサブエージェント2本。これで2つの問題が同時に解けます: `/` メニューでは自作と第三者製20数本を見分ける手段が他に無いこと、そして**前置なしの名前は組み込みを無言で隠す**こと（`review` という名前のスキルが Claude Code の `/review` を隠す事故が実際に起きました）。

### 面の実際の大きさ

**到達可能な名前は 27 ではなく 78。** 共有している予算が context window の1%であること、そしてこのリポジトリの監査が2回ともファイルシステムを読んで外したことの両方で重要です:

| 出所 | 数 | 場所 |
|---|---|---|
| ディスク上 | 27 | `~/.agents/skills/` —— 自作10、上流17 |
| Anthropic 管理プラグイン | 11 | `~/Library/Application Support/Claude/…` 配下、サーバ同期 |
| **CLI バイナリにコンパイル済み** | **40** | **ファイルとして存在しない** —— 実行ファイルの中 |

`~/.agents/skills` を数えても全体にはなりません。`/doctor` と `/skill-doctor` が全部を見ます。6件は `skillOverrides` で抑制しています（下記）。

### 表

開発ループの順。**●** が自作、他は上流かバンドルです。

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
| `/verify` | テストや typecheck ではなく、ユーザーと同じように end-to-end で動かす（バンドル） | |
| `/run` | アプリを起動して目で見る（バンドル） | |
| **4. コードを書いた後 —— レビューは儀式ではなくエスカレーション** | | |
| `/da-review-all` | **レビューの入口。** 変更を分類し、該当する層に委譲し、**層と層の間**に落ちるものを見る | ● |
| `/code-review` | **2本目。** 別の作りなので別のものを見つける（バンドル） | |
| `/find-bugs` | 3本目。先に攻撃面を全列挙してからブランチ差分をスイープ | |
| `/simplify` | 品質専用 —— 再利用、単純化、抽象度。明示的にバグ探しではない（バンドル） | |
| `/security-review` | セキュリティ専門。ブランチの保留中の変更に対して（バンドル） | |
| `/review` | 作業差分ではなく GitHub PR に対して（バンドル） | |
| `/requesting-code-review` | レポートではなく**手順**が欲しいとき —— 推論を見ていないフレッシュな文脈のレビュアーを立てる | |
| `/receiving-code-review` | 指摘が来て、反射的に実装せず**評価したい**とき | |
| `/da-fix-plan` | 所見が多すぎて全部やりたくないとき。**何を直さないかを決め**、残りを不可逆性で並べ、計画をディスクに書く | ● |
| `/da-pr-describe` | diff を開く前に読める PR 説明が必要なとき。**自分で打つ —— 自動では絶対に起動しません** | ● |
| `/finishing-a-development-branch` | 実装が終わり、どう統合するか決めるとき | |
| `/handoff` | この会話を別のエージェントが引き継げる形に圧縮する | |
| **5. 定期的に** | | |
| `/skill-doctor` | 未使用でコンテキストを食っているスキル。**最初にこれ**（バンドル） | |
| `/doctor` | listing の実コストと最大寄与者（バンドル） | |
| `/da-skills-audit` | 過剰制約、トリガ重複、Cursor 非互換、サイズ | ● |
| `/skill-scanner` | 第三者スキルを信用する前。**bloat ではなくセキュリティ** | |
| `anthropic-skills:skill-creator` | スキルが**役に立っているか**: with/without の pass rate・トークン・時間 | |

**`da-review-backend` / `-frontend` / `-infra` は意図的にこの表にありません。** `user-invocable: false` を持つので、`/da-review-all` からも層を名指しした依頼（「backend をレビューして」）からも届きますが、**`/` メニューには出ません**。打つのは1つ、その裏に3層の深さ。

### トリガが重なる場所と、どちらが勝つか

| こう頼む | 行き先 | 2本目 |
|---|---|---|
| 「レビューして」 | `/da-review-all` —— `/find-bugs` にも行きえる | `/code-review` |
| 「セキュアか」 | `/find-bugs`（バグ＋セキュリティ＋品質） | `/security-review` |
| 「終わった？」 | profile があれば `/da-verify` | 無ければ `/verification-before-completion` |
| 「整理して」 | `/simplify` —— 設計上、品質専用 | —— |
| 「毎日動かして」 | バンドルの `/schedule` | 単発の繰り返しは `/loop` |

### 抑制しているもの、そしてなぜそれ以上やらないか

`skillOverrides` で6件を `name-only` か `off` に。`setup.sh` がマージし、`uninstall` が正確に戻します: `verification-before-completion` と `claude-api`（どちらもこのリポジトリの作業で常に該当するトリガで自動発火する）、`anthropic-skills:schedule`（**`schedule` という名前のスキルが2本生きている**）、office 系 `docx`/`pptx`/`xlsx`/`pdf`（description が長く開発ループ外）、`morning`/`setup-cowork`。

**レビュア系は意図的に抑制していません。** 使用ログではバンドル `code-review` が42回、`review` が24回 —— 実際に使われています。そしてレビュアの多様性は、手に入る中で最も裏付けのあるレビュー手法です。`disableBundledSkills` なら一撃で全部消え、しかも **CLI 2.1.219 以降にしか存在しない**ので `$PATH` の古い `claude` では黙って無効になります。このマシンには両バージョンが入っています。[ADR 0006](docs/adr/0006-one-review-entry-and-the-real-command-surface.md) 参照。

### なぜ「コマンド」ではなく全部スキルなのか

**このリポジトリに commands ディレクトリはありません。**これは抜けているのではなく意図的です。

[公式](https://code.claude.com/docs/en/skills)が明言しています: *「Custom commands have been merged into skills… Skills are recommended」*。素の `commands/*.md` が好ましいケースは公式に1つもありません。Cursor の commands ドキュメントページは現在 404 です。

**スラッシュコマンド**はプロンプトのテンプレートでした。`/name` と打つと展開される、それが機構の全部です。**スキル**はディレクトリ（`SKILL.md` ＋ 必要になった時だけ読む reference 群）で、**3通りで到達できます**: `/name` と打つ、リクエストが `description` に一致してモデルが選ぶ、別のスキルが名前で呼ぶ。1つ目は3つ目までの機能の**部分集合**なので、コマンドとして書いたものは**機能を2つ切ったスキル**にすぎません。

この4本では具体的に効いています。`/da-review-backend` は、**あなたが直接呼んだとき**と **`/da-review-all` が層の1つとして呼んだとき**の両方で動く必要があります。コマンドなら2ファイルに分かれて乖離していく —— このリポジトリの前身が実際にそう腐りました。参照セット（姿勢・プロセス・所見の規律・無音事故パターン）は symlink で共有しているので、**規律を1箇所直せば全層と層をまたぐパスに同時に届きます**。

プロンプトテンプレートの用途が消えたわけではなく、今は `disable-model-invocation: true` という綴りになりました。**description が context から完全に消えるので予算コストがゼロ**になります。`/da-pr-describe` がこれです（GitHub に書き込むので、タイミングはあなたのもの）。逆に **`/da-verify` と層別3本には絶対に付けません** —— 名前で到達されるものなので、付けるとディスパッチが**無言で壊れます**。lint hook とリンタの両方がテスト付きで強制しています。分類の全体像と出典は [`docs/mechanisms.md`](docs/mechanisms.md) にあります。

実際の使い勝手: **`/da` を打てば自作のものだけが1つのリストに出ます。** 2つ目の異なる呼び出し方は存在しません。

### 上流16本はどこから来たか

**広く使われていて、実際にメンテされている**コレクションから選び、**選択的に**入れています —— リポジトリ丸ごとは絶対に入れません。description は1つの予算を共有するので。上のフローが実際に到達するものだけです。

| 出所 | そこから入れたもの | なぜこのコレクションか |
|---|---|---|
| **[obra/superpowers](https://github.com/obra/superpowers)** — 10本 | `brainstorming` · `writing-plans` · `executing-plans` · `test-driven-development` · `systematic-debugging` · `verification-before-completion` · `requesting-code-review` · `receiving-code-review` · `using-git-worktrees` · `finishing-a-development-branch` | **方法論の背骨**: plan → implement → verify と、デバッグの規律。マルチハーネス対応で、自前の `AGENTS.md` とテストを持つ。**プロセスはここから来ています** |
| **[mattpocock/skills](https://github.com/mattpocock/skills)** — 3本 | `grill-me` · `handoff` · `resolving-merge-conflicts` | **鋭くて単一目的**の道具。`grill-me` は設計フローを始める質問攻め、`handoff` はセッションを次に渡す圧縮。どちらも予算コストゼロ（`disable-model-invocation`） |
| **[getsentry/skills](https://github.com/getsentry/skills)** — 2本 | `find-bugs` · `skill-scanner` | **本番の障害を見つけることが製品の会社**から。`find-bugs` は攻撃面を全列挙してからスイープする —— 層別レビューとは**形が違う**ので、まさに2本目のレビュアに適しています。`skill-scanner` はこのリポジトリ自身の frontmatter の実バグを見つけました |
| **[addyosmani/agent-skills](https://github.com/addyosmani/agent-skills)** — 1本 | `documentation-and-adrs` | **ADR の実践だけ。** このコレクションの他4本は「ループ外」として削除。これも一度削除して、**戻しました** —— ADR を書くことが設計フローの出発点だからです |

**抑制せずに使っている Claude Code 組み込み**: `/code-review` · `/review` · `/security-review` · `/simplify` · `/verify` · `/run` · `/doctor` · `/skill-doctor`。加えて `anthropic-skills:skill-creator` —— **スキルが役に立っているかを測れる唯一のもの**です。

**選定の規則と、なぜ vendoring しないか。** 方法論はそれを本業にしている人たちが維持した方が良いので、コピーせず**並べて入れます** —— `npx skills check` で上流の差分を確認してから `npx skills update` で取り込む。vendored なコピーは**誰もメンテしない fork** です。この選択の代償は、**上流スキルはここで編集できない**こと: その場で直しても次の update で失われるので、レバーは install と remove だけ。**だから `da-` prefix が自作を示し、上流は元の名前のままなのです。**

ここに置くかの判定基準: **「違う意見を持つ人にとっても同じくらい有用か？」** Yes なら上流に属します。残るのは**特定の意見をエンコードしたもの** —— 何を報告に値する所見とするか、何がレビューを信頼できるものにするか、何が真であれば完了と呼べるか。

### frontmatter ガード

`hooks/dotagents-lint-skill-frontmatter.sh`、両エージェントで動きます。**頼まなくても遭遇する唯一の hook** です —— `Write`/`Edit` のたびに走り、パスが `SKILL.md` で終わるときだけ反応します。

スキルを書いていて編集が**拒否された**ら、理由はこれです。

| 拒否する条件 | 理由 |
|---|---|
| `name` か `description` が無い | メニューには出るのに一度も発火しない。他にそれを報告するものが無い |
| `---` で開いて閉じていない | 同じ失敗で、より気づきにくい |
| `da-verify` に `disable-model-invocation` | ゲートを arm する唯一のものなので、ガードレールが開く |
| 層別レビューに `disable-model-invocation` | `da-review-all` がその層を「カバー済み」と報告して何もレビューしなくなる |

「何をするか」は書いてあるが「**いつ使うか**」が無い description は、**拒否ではなく確認**になります —— 打てば動くが、自動では発火しないので。それ以外は通します。この hook は検査だけなので落ちたら**開いて**通します。閉じて止まらなければならないのは下のゲートです。

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
  -s grill-me -s handoff -s resolving-merge-conflicts -s research

# セキュリティ — getsentry/skills
npx skills add getsentry/skills -g -a claude-code -a cursor \
  -s find-bugs -s skill-scanner

# 決定の記録 — addyosmani/agent-skills
npx skills add addyosmani/agent-skills -g -a claude-code -a cursor \
  -s documentation-and-adrs
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
| `observability-and-instrumentation`, `performance-optimization`, `deprecation-and-migration` | 専門的な助言スキル。開発ループの外 |
| ~~`documentation-and-adrs`~~ | **削除して、戻した。** 「専門的な助言」として切ったが、**ADR を書くことが設計フローの最初の一歩**だと知らなかった —— このリポジトリ自体に7本ある。ワークフロー自体ではなく推測から下した誤判断 |
| `codebase-design`, `domain-modeling`, `improve-codebase-architecture` | 相互参照する3本セット。参照切れが出ないようまとめて削除 |
| `dispatching-parallel-agents` | ハーネスが並列エージェントをネイティブに持つ |
| ~~`research`~~ | **削除して戻した** —— この誤りは2度目。「ハーネスに WebFetch がある」を理由に切ったが、それは**道具を持っていること**と**実践を持っていること**の混同。一次情報を当たって `/clear` を生き延びるファイルに書き出すのは設計フローの第0段階で、生の WebFetch 呼び出しはそれではない |

**この11本の削除に使用実績の裏付けはありません。**これは明記しておく価値があります: 35本のうち34本は同じ日にインストールされたので、「一度も起動されていない」は「数時間前に入れた」の意味しかありませんでした。根拠は**構造**です —— 参照切れ、挙動の衝突、ネイティブ機能との重複 —— 測定ではありません。[ADR 0005](docs/adr/0005-mechanism-taxonomy-and-pruning.md) 参照。

スキルは**エージェントの全権限で動きます**。`/skill-scanner` はプロンプトインジェクションとサプライチェーンリスクを監査します —— 実際にこのリポジトリ自身の frontmatter の不具合を見つけました。そういうためのものです。


## スキルの書き方

[`_template/SKILL.md`](_template/SKILL.md) から始めて `./scripts/verify-skills.sh`。

不変則は [`AGENTS.md`](AGENTS.md) にあります —— あれが常時ロードされる層で、**無警告で失敗する**ものだけを置いています。全体を規定する1つ: **Claude 固有の frontmatter を全部剥がしても同じ挙動が成立すること。** Cursor はそれらを何も言わずに無視し、しかも**別のモデルファミリー**で動くので。

### Cursor はもっと大きい別のメニューを見ている —— そしてこれは解決しきっていません

両エージェントを一級市民として扱っていますが、**面の大きさは同じではなく**、差は一方向に出ます。

| | Claude Code | Cursor |
|---|---|---|
| `~/.agents/skills` から | 27 **− 層別3本**（`user-invocable: false` で隠す） | **27全部** —— このフィールドを無視するので**層別レビューがメニューに出る** |
| 組み込み | 約40（CLI にコンパイル済み） | **自前で19本**: `review` `review-bugbot` `review-security` `create-skill` `create-rule` `create-subagent` `loop` `automate` `babysit` `split-to-prs` `onboard` `shell` `sdk` `canvas` `statusline` `migrate-to-skills` `create-hook` `update-cli-config` `update-cursor-settings` |
| `skillOverrides` の抑制 | 9件有効 | **0件** —— `settings.json` を読まない |

はっきり書いておくべき帰結が2つ。

**層別レビューが Cursor のメニューに漏れます。** Claude Code では打つレビュー入口は1つですが、Cursor では自作4本＋`review`＋`review-bugbot`＋`review-security`＋`find-bugs`。Cursor で層別を直接打っても**同じスキルなので正しく動きます** —— 失うのはメニューの見通しであって挙動ではなく、それが [ADR 0003](docs/adr/0003-cursor-compatible-subset.md) の引く線です。ただし**現時点で最大の乖離**であり、**直っていません**。

**9件の抑制は Cursor に効かず、そして大半は効く必要がありません。** 9件のうち6件は**Cursor に存在しないスキル**（バンドルと Anthropic プラグイン）が対象なので、抑制する相手がいません。**Cursor にも存在するのは `verification-before-completion` だけ**で、そちらでは抑制されないまま `/da-verify` とトリガを奪い合います。

**分かっていないこと**: Cursor の19本を無効化できるのか、できるならどこで。Cursor 自身の設定面は読んでいないので、**ここでは剪定できると主張しません**。メニューを圧迫して困るなら、それが次に調べることであって、すでに処理済みのことではありません。

## スクリプト全部と、それを正当化する理由

**スクリプトの増殖はこの種のツールキットの failure mode** なので、1本ごとに「何を防ぐか」を言えなければいけません。9ファイルあり、**2つはこのテストに落ちて削除しました。**

| ファイル | 行数 | なぜ存在するか |
|---|---|---|
| `scripts/setup.sh` | 557 | **配布の機構。** スキルと agent を link、hook をコピー、設定をキー単位でマージ、リポジトリが配らなくなったものを prune、追加したものだけを正確に revert。これが無いと何もインストールされない |
| `scripts/lib/merge-settings.mjs` | 271 | その安全な半分: 宣言したキーだけをマージし、自分が書いていない値は書き換えず、触ったものを記録する。**他人の API キーを含むファイルを編集する**ので |
| `hooks/dotagents-verify-gate.sh` | 407 | **ゲート。** 価値提案の本体 —— エージェントは「完了したように見えた」時点で止まる |
| `hooks/dotagents-lint-skill-frontmatter.sh` | 124 | **壊れた状態でインストールされて何も言わない** `SKILL.md` を拒否する |
| `scripts/gate.sh` | 158 | ゲートの操作面: arm / disarm / 委譲チェックの記録 / 状態表示。通常はあなたではなく `/da-verify` が呼ぶ |
| `scripts/verify-skills.sh` | 360 | `AGENTS.md` の不変条件をチェックに落としたもの。**実際に捕まえた**: どの YAML パーサも受け付けない frontmatter、本文が使うツールを欠いた `allowed-tools`、本文から言及されていない reference、到達不能な `user-invocable: false` |
| `scripts/test-verify-gate.sh` | 405 | 42 assertion。**ゲートは唯一「閉じて落ちる」ことが必須のもの**で、これが無かった時代に2回 fail-open した |
| `scripts/test-lint-hook.sh` | 175 | 33 assertion。**このリポジトリ最悪のバグを捕まえた**: scope チェックが誤った変数を見ていて**一度も発火していなかった** —— インストール済みで、何も強制していない状態 |
| `scripts/test-setup.sh` | 141 | 偽の `$HOME` に対する 18 assertion。インストーラは**資格情報と他ツールの hook を含むファイル**を編集する |
| `scripts/check.sh` | 68 | 上記すべてを1コマンドに。**4つ覚える代わりに1つ** |

**削除したもの（同じテストに落ちた）:**

| 削除 | 理由 |
|---|---|
| `hooks/dotagents-statusline.sh` ＋ template ＋ `--statusline` | **一度もオプトインされなかったオプトイン。** 72行とインストーラの関数を使って、誰も求めていないステータスラインを描画していた。しかも「全 hook はブロックできなければならない」チェックに**例外を強制**していた —— ブロックできない唯一の hook だったので |
| `templates/claude.advisor.snippet.json` ＋ `--advisor` | 同じく**一度も有効化されなかった**。しかも背後の機能は experimental で Anthropic API 専用なので、**大半の環境に存在しない能力**をフラグが説明していた |

両方に共通するパターン: **一度も ON にされなかった、何かのためのオプション。** ツールキットの所有が煩わしくなる原因は**ファイル数ではなく**、「保持するか判断する前に、まず目的を再構成しないといけないファイル」です。ここにあるもので**「何を防ぐか」を1行で答えられないものは、同じように消すべき**です。

## テスト

```bash
./scripts/check.sh              # 全部: 構文、symlink、lint、93 の振る舞い assertion
./scripts/check.sh --fast       # 構文と lint だけ
```

個別に走らせるのは、そのどれかを触っているときだけ: `verify-skills.sh`（lint）、`test-verify-gate.sh`（42）、`test-lint-hook.sh`（33）、`test-setup.sh`（18）。

CI は両スイートを **Linux と macOS の両方**で走らせます。壊れ方が両方向に出たからです —— bash 4 構文は Linux で通り macOS で落ち、`mktemp -t` の綴りは BSD で通り GNU coreutils で落ちる。

実テストを持つのはゲートとインストーラだけで、理由は正反対です。**ゲートはフェイルクローズでなければならない** —— 見つかった全てのフェイルオープンに回帰テストがあります。**インストーラは自分のものでないファイルを編集する** —— 他人の資格情報と他人のフックを含むので、テストは「書いていない秘密が生き残る」「他3ツールのフックが生き残る」「uninstall が何も残さない」を固定しています。

## シークレット

ここには何も秘密を置かず、インストーラは自分が書いていないものに触りません。テンプレートが宣言したキーだけをマージし、`~/.claude/.dotagents-managed.json` に記録し、先にバックアップを取り、自分のものでない既存値は書き換えません。既存フックは置換ではなく追記です。

`uninstall` が戻すのは各キーの**値**であって、ファイルの**バイト列**ではありません。設定は固定の整形で書き直されるので、別の整形をしていたファイルは整形され直します。`test-setup.sh` が検証しているのは値であり、それが正直に約束できることです。

CI では gitleaks を全履歴に対して走らせています。

## ライセンス

[MIT](LICENSE)
