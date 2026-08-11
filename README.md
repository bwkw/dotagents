# dotagents

[![ci](https://github.com/bwkw/dotagents/actions/workflows/ci.yml/badge.svg)](https://github.com/bwkw/dotagents/actions/workflows/ci.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Claude Code と Cursor** のための個人用 AI 開発ツールキット。一度グローバルに入れれば、どのリポジトリでも使えます。プロダクトのリポジトリには一切手を入れません。

English: [README.en.md](README.en.md)

なぜこの形なのか（出典付き）: [docs/design.md](docs/design.md) · どの仕組みを選ぶか:
[docs/mechanisms.md](docs/mechanisms.md) · 判断の記録: [docs/decisions.md](docs/decisions.md) ·
ハーネスの実挙動（一次情報で確認）: [docs/harness-facts.md](docs/harness-facts.md) ·
他人のマシンで動かすために何を変えたか: [docs/portability.md](docs/portability.md)

何を配っているのかの正直な説明: [SECURITY.md](SECURITY.md) · 変更履歴: [CHANGELOG.md](CHANGELOG.md) ·
直す前に読むもの: [CONTRIBUTING.md](CONTRIBUTING.md)

```bash
# 自分の fork を指してください。理由は SECURITY.md -- ここに入っているのは
# 全ツール呼び出しと全ターン終了で自動実行されるコードです
git clone https://github.com/<you>/dotagents ~/private/dotagents
cd ~/private/dotagents
./scripts/setup.sh install --dry-run   # 何が起きるか確認
./scripts/setup.sh install             # 仕組みだけ（hook の配線）
./scripts/setup.sh status
```

`install` は**仕組みだけ**を入れます。作者のスキル選好（bundled / plugin スキルの抑制と verbose な
テレメトリ）まで入れたい場合は `install --with-opinions`。既定から外してあるのは、検証ゲートを入れた
ことが、**あなたが一度も言及していないスキルを黙って黙らせることへの同意ではない**からです。

必要なもの: `node`、`bash`、`git`。**macOS と Linux で CI が回っています**（bash 3.2 を含む）。Windows は
bash 前提なので WSL のみのはずですが、未確認です。node は CI で 22 を検証しています。18 でも動く想定ですが
**検証していません**（[docs/portability.md](docs/portability.md) の「直していないもの」）。

> **`profiles/` を1つ書くまで、検証ゲートは何も検査しません。** これは推測しない設計の帰結です
> （一致する profile が無ければ pass）。`profiles/_example.node-pnpm.json` をコピーするか、`/da-verify`
> に書かせてください。`setup.sh status` は profile が0件のとき警告します。

---

## 何をしたいかで選ぶ

**5つのユースケース。** それぞれ独立に入ります —— 分岐のある1本のパイプラインではありません。
**●** はこのリポジトリ製、**○** は上流、**◆** は Claude Code 組み込み。

### 1. 機能を作る

| 段階 | 打つもの | 何のためか |
|---|---|---|
| **0. 地面を調べる** | ○ `/research` | 「世の中は実際どうやっているか」。外部の一次情報を、**リポジトリ内のファイル**に書き出す。**選択肢とトレードオフはここから出てくる**し、ファイルは `/clear` を越えて残る |
| **1. 何を作るか固める** | ○ `/grill-me` | 選んだ選択肢を、要件が本当に固まるまで質問攻めにする |
| | ● `/da-investigate` | **この**コードベースで何に触るか。`file:line`、予算内、**確認できなかったことを名指し** |
| **2. 書き下す** | ○ `/documentation-and-adrs` | 決定を ADR として |
| | ○ `/writing-plans` | spec をディスクに（リポジトリが openspec を使うならそちら） |
| | **● `/da-design-review`** | 書いたものを**コードが存在しない段階で**レビュー —— 一方通行の扉、移行順序、ロールバック、過去形のプリモーテム |
| | `/clear` | 計画はディスクにある。実装は新セッションで |
| **3. 実装する** | ○ `/executing-plans` | 書かれた計画を節目付きで進める |
| | ○ `/using-git-worktrees` | 作業を今のワークスペースから隔離する必要があるとき |
| | **● `/da-verify`** | **この**リポジトリの設定済みチェックを実行し、証拠を報告。**ゲートも arm する** |
| **4. レビューして改善** | ユースケース4へ | |

**テストが先はここの段階ではありません** —— `AGENTS.md` の常設ルールです（呼ばないと効かない既定値は既定値ではない）。詳細な手順が要るときは ○ `/test-driven-development`。

**landing の分割は `/da-design-review` が決めます。** 実装に入ってから「これは別 PR にすべきか」を毎回考え直すのをやめるためです。一方通行の扉と移行順序を判断しているのは既にそのスキルなので、**どこで landing が分かれるかはその結論**です。出力の `🧱 Landing plan` が、各 landing に入るもの・**それを通す gate**・一方通行かどうかを表にします。

そこから先は landing ごとに同じ3手を回すだけで、**新しいコマンドは1つも増えません**:

```
/da-design-review        → 一方通行の扉と landing 計画
  ↓ ここが人間のゲート（承認）
landing ごとに:
  /test-driven-development → 落ちるテスト → 実装
  scripts/gate.sh verify   → ターンを終わらせずに自己検証（何度でも。状態を触りません）
  /da-review-all           → 層別＋層をまたぐレビュー
  /da-fix-plan             → 何を直さないか決める＝レビュー反復の停止条件
  ↓ 全 landing 緑
/da-pr-describe          → 自分で打つ
```

**PR の作成とマージは自動化しません。** `da-pr-describe` は「頼まれずに PR を作るな」、`da-fix-plan` は「push も issue もコメントもするな」と明記しています。外向きで不可逆な操作は人間のものです —— 自動化するのは**判断の反復**の方です。

### 2. 調査する

**問いが2種類あり、道具も2つ。** 間違った方に手を伸ばすのがよくある失敗です。

| 問い | 打つもの | 補足 |
|---|---|---|
| 「世の中はこれをどうやっているか」 | ○ `/research` | **外部**の情報源。所見をファイルに書き、背景エージェントでも走れる |
| 「X はどこ / 何が依存 / 何が壊れる」 | ● `/da-investigate` | **この**コードベース。25ファイル・検索3ラウンドで**止まり、確認しなかったことを言う**。Confirmed / Inferred / Unconfirmed を別物として報告し、**負の結論は語彙を変えて再探索してから**主張する |

`/da-investigate` は ● `x-codebase-explorer` サブエージェントに展開するので、**読んだ内容は彼らの context に留まります**。

### 3. バグを直す

| 段階 | 打つもの | 補足 |
|---|---|---|
| **調査** | **○ `/systematic-debugging`** | **修正より先に root cause**、飛躍を拒否する。**これはレビューではありません** —— バグにレビュースキルを向けると、原因ではなく近所の不完全さの一覧が返る |
| | ● `/da-investigate` | 疑わしい箇所が決まってから、その影響範囲だけ |
| **修正** | ○ `/systematic-debugging` | 自身の Phase 4 が修正まで担う |
| **証明** | **● `/da-verify`** | そしてバグ修正は**バグを再現するテストから**始まる（でないと「直った」に意味がない） |

### 4. レビューする

| | 打つもの | 補足 |
|---|---|---|
| **自分の実装** | **● `/da-review-all`** | **打つレビュー入口はこれだけ。** 変更を分類し、該当する層に委譲し、**層と層の間**に落ちるものを見る |
| | ◆ `/code-review` か ○ `/find-bugs` | **2本目、意図的に別の作りのもの。** 同一146 PR に4種を当てて、指摘の93.4%は4つのうち1つだけが検出 |
| | **● `/da-fix-plan`** | 所見 → 順序付きの計画。**主な仕事は「何を直さないか」を決めること** |
| | ○ `/receiving-code-review` | 指摘が来て、反射的に実装せず評価したいとき |
| | ● `/da-pr-describe` | PR 説明。**自分で打つ** —— 自動では起動しない |
| **他人の PR** | ◆ `/review <PR>` | GitHub の見え方 |
| | ● `/da-review-all <base>` | 深さが欲しいとき。**説明・issue・コミットから意図を再構成してから、所見を1つも出さずに言い直す** —— アプローチの違いは欠陥ではなく、既存の問題は「既存」とラベルしてブロックしない |
| **狭いパス** | ◆ `/security-review`・◆ `/simplify` | セキュリティ専用 / 品質専用で明示的にバグ探しではない |

`x-review-backend` / `-frontend` / `-infra` は完全なスキルですが **`/` メニューには出しません** —— ディスパッチャが届き、層を名指しした依頼（「backend をレビューして」）も届きます。**打つのは1つ、その裏に3層の深さ。**

### 5. ツールキットを保守する

| 打つもの | いつ |
|---|---|
| ◆ `/skill-doctor` | **最初にこれ。** 未使用でコンテキストを食っているスキル |
| ◆ `/doctor` | listing の実コストと最大寄与者 |
| ● `/da-skills-audit` | 過剰制約、トリガ重複、Cursor 非互換、サイズ |
| ○ `/skill-scanner` | 第三者スキルを信用する前。**bloat ではなくセキュリティ** |
| ○ `anthropic-skills:skill-creator` | スキルが**役に立っているか**を測れる唯一のもの: with/without の pass rate・トークン・時間 |

### どのコマンドより効く3つの規則

- **差分を1文で説明できるなら計画は飛ばす。**
- **計画と実装の間で `/clear`**、そして無関係なタスクの間でも。
- **同じ問題で2回修正に失敗したらセッションを捨てる。** 学んだことを織り込んで prompt を書き直す。失敗したアプローチを抱えた長いセッションより、良い prompt の綺麗なセッションが勝つ。

理由・出典・良い出典どうしが食い違う箇所は [`docs/design.md`](docs/design.md) に。**正典と呼べる段階数は存在しない**という事実も含めて —— 上の5ユースケースは便宜であって、発見ではありません。

### ゲートと、直接触る場合

`/da-verify` が最初のステップでゲートを arm するので、**上のどのユースケースにも別途 arm するステップはありません。** arm 後はターン終了ごとにこのリポジトリのチェックが走り、赤い間は終了を拒否します。

```bash
scripts/gate.sh arm            # まだ verify が走っていない段階から、最初のターンから保留したい
scripts/gate.sh disarm         # 質問応答に戻る。終了時にスイートを走らせたくない
scripts/gate.sh status         # armed か、どれだけ idle か、諦めた記録があるか
scripts/gate.sh status --json   # 同じ内容を、人間ではなくドライバ向けに
scripts/gate.sh gc             # 終了したセッションが残した armed 状態を回収する
```

> **無人で回しても壊れない形にしてあります。** 以前ここには「深夜に無人で回すためのロックではありません」と書いてありました。**その立場が誤りだったのではなく、立場の話をしている間に状態機械が壊れていた**のが問題でした —— `arm` に期限が無く、ブロックに上限が無く、諦めたことが記録されない。[判断の記録](docs/decisions.md) に反転として記録しています。
>
> **gate が armed でなくなるのは2通り**: `disarm` と、**12時間ターンが終わらなかったときの自動回収**（idle 基準。arm からの経過ではないので、長時間の無人実行は途中で切れません）。**ブロックをやめるのは3つ目の出来事** —— 同じチェックが3回落ちると `VERDICT` を書いて解放します。**解放は緑ではありません**: `status` と `verdicts.log` と次の `arm` が「諦めた」と言い、作業は未検証だと明言します。
>
> **worktree は継承します。** `using-git-worktrees` がこのツールキット自身の推奨する分離手段なので、main で arm すれば linked worktree にも掛かります。attempt 数は worktree ごとに別です。
>
> **Cursor ではブロックできず**、nudge するだけで3回目に止めます。そして**拒否し続ける hook は前進ではない** —— だから上限があります。セッションを越えて残るのは**ディスクの spec、CI のチェック、復帰点としてのコミット、そして `VERDICT`** です。

## 何が入っているか

**自作は10スキル**、残り11本は上流から入れています —— 方法論はそれを本業にしている人たちが維持した方が良いので。自作なのは**意見をエンコードしたもの**だけです: 何を報告に値する所見とするか、何がレビューを信頼できるものにするか、何が真であれば完了と呼べるか。**●** が付いているものです。

加えて `agents/` に**サブエージェント2本**。`~/.claude/agents/` と `~/.cursor/agents/` の**両方**に入るので、どちらのエージェントのどのリポジトリからも届きます —— 以前は Claude 側だけにリンクしていて、「Cursor は `~/.claude/agents/` も読む」という**公式ドキュメントに裏付けのない主張**でそれを正当化していました。実際 `~/.cursor/agents/` は空で、Cursor には1本も届いていませんでした（[ハーネスの実挙動](docs/harness-facts.md)）: **`x-review-verifier`**（敵対的。既定で反証し、find フェーズには参加していない）と **`x-codebase-explorer`**（読み取り専用、`file:line` 証拠、明示的な予算）。レビュー系が名指しで委譲します。これが存在する前は、5ファイルが「リポジトリが専用エージェントを定義していれば優先」と書いていましたが、**このツールキットはプロダクトリポに1ファイルも置かない**ので、その分岐は永遠に到達しませんでした。[判断の記録 §4](docs/decisions.md) 参照。

## 面の全体と、何を抑制しているか

**`/da` と打てば、打つべき7つが出ます —— Claude Code と Cursor で同じ7つ。**

**前置は2つあり、その分割が本質**です。**`da-` は打つもの**（7）。**`x-` は内部**（層別レビュー3＋サブエージェント2）—— ディスパッチャか層の名指しで届き、**打つものではありません**。

分割が必要なのは、**フィールドで隠す方法が両エージェントで通用しない**からです: `user-invocable: false` は Claude 専用、そして **Cursor はサブエージェントをコマンドピッカーに載せる**。結果 `/da` は Cursor で12件、Claude で7件を返していて、**差の5件は誰も打つべきでないディスパッチ先**でした。前置を共有しないことで、**どちらかのエージェントが無視しうるフィールドに頼らずに**両方で直ります。これで2つの問題が同時に解けます: `/` メニューでは自作と第三者製20数本を見分ける手段が他に無いこと、そして**前置なしの名前は組み込みを無言で隠す**こと（`review` という名前のスキルが Claude Code の `/review` を隠す事故が実際に起きました）。

### 面の実際の大きさ

**到達可能な名前はディスク上の数の3倍以上あります。** 共有している予算が context window の1%であること、そしてこのリポジトリの監査が2回ともファイルシステムを読んで外したことの両方で重要です。

**数はここに書きません。** 以前は「21 ではなく 72」と書いてあり、`templates/claude.settings.snippet.json` は同じものを「24 / 75」と書いていて、実測は23でした ——
**3箇所が3つの違う数を主張していた。** stale な記述を欠陥として扱うリポジトリで手書きの数を持つのは、欠陥の常設発生装置です。数が要るときは `/doctor` と `/skill-doctor` が全部を見ます:

| 出所 | 場所 |
|---|---|
| ディスク上 | `~/.agents/skills/` —— 自作10、残りは上流 |
| Anthropic 管理プラグイン | `~/Library/Application Support/Claude/…` 配下、サーバ同期 |
| **CLI バイナリにコンパイル済み** | **ファイルとして存在しない** —— 実行ファイルの中。ここが最も多い |

`~/.agents/skills` を数えても全体にはなりません。`/doctor` と `/skill-doctor` が全部を見ます。一部は `skillOverrides` で抑制しています（下記）。

### トリガが重なる場所と、どちらが勝つか

| こう頼む | 行き先 | 2本目 |
|---|---|---|
| 「レビューして」 | `/da-review-all` —— `/find-bugs` にも行きえる | `/code-review` |
| 「セキュアか」 | `/find-bugs`（バグ＋セキュリティ＋品質） | `/security-review` |
| 「終わった？」 | `/da-verify`。profile が無ければ**埋めるだけの profile を返して止まる** —— 代替スキルはもう無く、保存するまでゲートも無い |
| 「整理して」 | `/simplify` —— 設計上、品質専用 | —— |
| 「毎日動かして」 | バンドルの `/schedule` | 単発の繰り返しは `/loop` |

### 抑制しているもの、そしてなぜそれ以上やらないか

`skillOverrides` で8件を `name-only` か `off` に。**`install --with-opinions` を付けたときだけ**マージされ、`uninstall` が正確に戻します（既定から外した理由は [判断の記録 §18](docs/decisions.md)）: `claude-api`（このリポジトリの作業で常に該当するトリガで自動発火する）、`anthropic-skills:schedule`（**`schedule` という名前のスキルが2本生きている**）、office 系 `docx`/`pptx`/`xlsx`/`pdf`（description が長く開発ループ外）、`morning`/`setup-cowork`。

**レビュア系は意図的に抑制していません。** 使用ログではバンドル `code-review` が42回、`review` が24回 —— 実際に使われています。そしてレビュアの多様性は、手に入る中で最も裏付けのあるレビュー手法です。`disableBundledSkills` なら一撃で全部消え、しかも **CLI 2.1.219 以降にしか存在しない**ので `$PATH` の古い `claude` では黙って無効になります。このマシンには両バージョンが入っています。[判断の記録 §8](docs/decisions.md) 参照。

### なぜ「コマンド」ではなく全部スキルなのか

公式がコマンドをスキルに統合し、素の `commands/*.md` が好ましいケースは公式に1つもない —— なのでここに `commands/` ディレクトリはありません。分類の全体像と出典は [`docs/mechanisms.md`](docs/mechanisms.md) にあります。

そこから出てくる運用上の帰結:

- **`/da` を打てば自作のものだけが1つのリストに出ます。** 2つ目の異なる呼び出し方は存在しません。
- プロンプトテンプレートの用途は今 `disable-model-invocation: true` という綴りで、**description が context から完全に消えるので予算コストがゼロ**です。`/da-pr-describe` がこれ（GitHub に書き込むので、タイミングはあなたのもの）。
- 逆に **`/da-verify` と層別3本には絶対に付けません** —— **名前で**到達されるものなので、付けるとディスパッチが**無言で壊れます**。lint hook とリンタの両方がテスト付きで強制しています。
- 直接呼び出しと `/da-review-all` からのディスパッチを1本で兼ねられることが、層別をスキルにしている理由です。コマンドなら2ファイルに分かれて乖離していく —— このリポジトリの前身が実際にそう腐りました。参照セットは symlink で共有しているので、**規律を1箇所直せば全層と層をまたぐパスに同時に届きます**。

### 上流11本はどこから来たか

**広く使われていて、実際にメンテされている**コレクションから選び、**選択的に**入れています —— リポジトリ丸ごとは絶対に入れません。description は1つの予算を共有するので。上のフローが実際に到達するものだけです。

| 出所 | そこから入れたもの | なぜこのコレクションか |
|---|---|---|
| **[obra/superpowers](https://github.com/obra/superpowers)** — 6本 | `writing-plans` · `executing-plans` · `test-driven-development` · `systematic-debugging` · `receiving-code-review` · `using-git-worktrees` | **方法論の背骨**: plan → implement → verify と、デバッグの規律。マルチハーネス対応で、自前の `AGENTS.md` とテストを持つ。**プロセスはここから来ています** |
| **[mattpocock/skills](https://github.com/mattpocock/skills)** — 2本 | `grill-me` · `research` | **鋭くて単一目的**の道具。`grill-me` は選択肢を固まった要件に変える質問攻めで予算コストゼロ（`disable-model-invocation`）、`research` は設計フローの出発点となる外部調査 |
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

**Cursor でも走りますが、ブロックできません。** Cursor の `stop` フックには拒否の仕組みがなく、代わりに follow-up メッセージを自動投入します（`loop_limit` で打ち切り）。両フックは呼び出し元を判定して適切な方言で応答します。Cursor 側は「強い促し」と考え、重要な場面では `/da-verify` を明示実行してください。対応表は [判断の記録 §3](docs/decisions.md)。

**何も起きていないように見えたら** `~/.claude/.dotagents-gate/trace.log` を読んでください。全ての呼び出しと、通した理由が記録されています。「何も起きなかった」には正当な原因が6通りあり、このファイルがそれを区別します —— 一度これが無いまま推測して、**動いているコードを変えて原因を隠しかけた**ので作りました。

### プロファイル

[`profiles/dotagents.json`](profiles/dotagents.json) を `profiles/<repo>.json` にコピーして書き換えます。**注釈だけの `_example.json` は削除しました** —— `docs/design.md`「未確定なこと」自身が「example は書き始めを助ける以上に書き方を狭めているかもしれない」と挙げていたもので、しかも**何も実行しない例**でした。残したのは schema と、**このリポジトリ自身のゲートが毎ターン実行している唯一の実例**だけです。

**あなたのコピーは gitignore されます。** profile は実在のリポジトリ名・環境名、場合によっては勤務先の社内ルールを含むので、書いたマシンに留まります。`.gitignore` は許可リスト方式なので、新しい profile は**デフォルトで untracked** です（「除外し忘れるまで追跡される」の逆）。`/da-verify` が書き方を案内します。

### 仕組み

```
dotagents/skills/<name>/
        ↑ symlink
~/.agents/skills/<name>          ← Cursor はここを直接読む
        ↑ symlink
~/.claude/skills/<name>          ← Claude Code は symlink を追う
```

実体はひとつ。ここを編集すれば同期の手順なしに両エージェントへ反映されます。リンクを張るのは Claude Code 側だけ —— Cursor が `~/.agents/skills/` を読むことは**推測ではなく観測**です（[判断の記録 §1](docs/decisions.md)）。

フックだけは **実体コピー**です。symlink が切れると `exit 127` になり non-blocking として扱われるため、**ガードレールが「止まる」のではなく「開く」**からです（[判断の記録 §2](docs/decisions.md)）。

---

## 上流のスキル

ここには取り込まず、横に並べて `npx skills check` / `npx skills update` で更新します。

**2つの規則があり、どちらも安全側の理由で入っています。**

- **名指しした既知の保守者のリポジトリからだけ入れる。レジストリの索引から探して入れない。** 2026年に報告されたスキルのサプライチェーン攻撃は公開レジストリの母集団で起きています（ClawHub 経由のマルウェア30本超、Snyk が ClawHub と skills.sh の3,984本を走査してマルウェア76本を確認）。ClawHub の公開障壁は「SKILL.md と1週間前の GitHub アカウント」で、署名もレビューもサンドボックスもありません。`npx skills add <owner>/<repo>` は**索引を引かずに名指しのリポジトリを直接 clone** するので、この母集団に触れません（[判断の記録 §10](docs/decisions.md)）。
- **`npx skills` のバージョンを固定する。** 下のコマンドが `skills@1.5.20` と書いてあるのはそのためです。スキル本体はテキストにすぎませんが、**この CLI はこのエコシステムからこのマシンで実際に実行される唯一のコード**で、`npx` は既定で毎回最新を取ってきてファイルシステム権限付きで走ります。
- **`npx skills update` の直後に `/skill-scanner` を回す。** `skillFolderHash` はインストール時の記録で、バージョン固定ではありません。update は既定ブランチの最新を持ってきます。監査は一度で終わりません。

**選択的に入れてください。** インストールされた description は全て常にコンテキストに常駐するので、リポジトリ丸ごと入れると他の全スキルの選択精度を削ります。

```bash
# 方法論 — obra/superpowers
npx skills@1.5.20 add obra/superpowers -g -a claude-code -a cursor \
  -s writing-plans -s executing-plans -s receiving-code-review \
  -s systematic-debugging -s test-driven-development -s using-git-worktrees

# 実務 — mattpocock/skills
npx skills@1.5.20 add mattpocock/skills -g -a claude-code -a cursor \
  -s grill-me -s research

# セキュリティ — getsentry/skills
npx skills@1.5.20 add getsentry/skills -g -a claude-code -a cursor \
  -s find-bugs -s skill-scanner

# 決定の記録 — addyosmani/agent-skills
npx skills@1.5.20 add addyosmani/agent-skills -g -a claude-code -a cursor \
  -s documentation-and-adrs
```

同じトリガを奪い合わないよう意図的に外したもの: `mattpocock/tdd` と `diagnosing-bugs`（superpowers がカバー）、`addyosmani/code-review-and-quality` と `spec-driven-development`（本リポジトリと上流でカバー）、プラットフォーム固有のもの。

**アンインストールしても Cursor では生き残ります。** `npx skills remove <name> -g -a claude-code -a cursor` はエージェント側のリンクを外して lockfile を更新しますが、**`~/.agents/skills/` の実体を残します** —— Cursor がネイティブに読むパスです。実体も消して、両者が一致することを確認してください:

```bash
diff <(ls -1 ~/.agents/skills) <(ls -1 ~/.claude/skills)
```

**測ってから削除しています**（勘ではなく）。`/da-skills-audit` が description のトリガ語彙を総当たりで比較し、トリガの語彙が重なっていた**13本を3ラウンドで削除**しました —— 35本 → 21本、resident な description は 6,905字 → 約3,500字になりました。1本ごとの理由と代償は [判断の記録 §4](docs/decisions.md) と [判断の記録 §8](docs/decisions.md) にあります。**うち2本は誤りで、戻しました** —— どちらも開発フロー自体ではなく、それについての推測に対して切ったものです。

歴史ではなく**今も生きている影響**が2つ:

- **上流3本が、もう入っていないスキルを名指ししています** —— `writing-plans`・`executing-plans`・`systematic-debugging`。受容しています: 上流ファイルをその場で編集しても次の `npx skills update` で、無言で失われるので。
- **`/da-verify` に代替がありません。** profile が無いリポジトリを覆っていたスキルを外したので、コマンドを推測せず、**停止して埋める用の profile を返します**。

スキルは**エージェントの全権限で動きます**。`/skill-scanner` はプロンプトインジェクションとサプライチェーンリスクを監査します —— 実際にこのリポジトリ自身の frontmatter の不具合を見つけました。そういうためのものです。


## スキルの書き方

[`_template/SKILL.md`](_template/SKILL.md) から始めて `./scripts/verify-skills.sh`。

不変則は [`AGENTS.md`](AGENTS.md) にあります —— あれが常時ロードされる層で、**無警告で失敗する**ものだけを置いています。全体を規定する1つ: **Claude 固有の frontmatter を全部剥がしても同じ挙動が成立すること。** Cursor はそれらを何も言わずに無視し、しかも**別のモデルファミリー**で動くので。

### Cursor はもっと大きい別のメニューを見ている —— そしてこれは解決しきっていません

両エージェントを一級市民として扱っていますが、**面の大きさは同じではなく**、差は一方向に出ます。

| | Claude Code | Cursor |
|---|---|---|
| `~/.agents/skills` から | 21 **− 層別3本**（`user-invocable: false` で隠す） | **21全部** —— このフィールドを無視するので**層別レビューがメニューに出る** |
| 組み込み | 約40（CLI にコンパイル済み） | **自前で19本**: `review` `review-bugbot` `review-security` `create-skill` `create-rule` `create-subagent` `loop` `automate` `babysit` `split-to-prs` `onboard` `shell` `sdk` `canvas` `statusline` `migrate-to-skills` `create-hook` `update-cli-config` `update-cursor-settings` |
| `skillOverrides` の抑制 | 8件有効 | **0件** —— `settings.json` を読まない |

はっきり書いておくべき帰結が2つ。

**層別レビューが Cursor のメニューに漏れます。** Claude Code では打つレビュー入口は1つですが、Cursor では自作4本＋`review`＋`review-bugbot`＋`review-security`＋`find-bugs`。Cursor で層別を直接打っても**同じスキルなので正しく動きます** —— 失うのはメニューの見通しであって挙動ではなく、それが [判断の記録 §3](docs/decisions.md) の引く線です。ただし**現時点で最大の乖離**であり、**直っていません**。

**抑制は Cursor に効かず、そして効く必要もありません。** 対象は**すべて Cursor に存在しないスキル**（バンドルと Anthropic プラグイン）なので、あちらには抑制する相手がいません。実際の件数は `templates/claude.settings.snippet.json` の `skillOverrides` が唯一の出典です —— この段落は以前「9件のうち6件」と書き、別の段落は「6件」、さらに別の段落は「8件」と書いていました。**同じ数を3箇所で手で維持すると3つの数になる。**

**分かっていないこと**: Cursor の19本を無効化できるのか、できるならどこで。Cursor 自身の設定面は読んでいないので、**ここでは剪定できると主張しません**。メニューを圧迫して困るなら、それが次に調べることであって、すでに処理済みのことではありません。

## スクリプト全部と、それを正当化する理由

**スクリプトの増殖はこの種のツールキットの failure mode** なので、1本ごとに「何を防ぐか」を言えなければいけません。9ファイルあり、**2つはこのテストに落ちて削除しました。**

| ファイル | なぜ存在するか |
|---|---|
| `scripts/setup.sh` | **配布の機構。** スキルと agent を link、hook をコピー、設定をキー単位でマージ、リポジトリが配らなくなったものを prune、追加したものだけを正確に revert。これが無いと何もインストールされない |
| `scripts/lib/merge-settings.mjs` | その安全な半分: 宣言したキーだけをマージし、自分が書いていない値は書き換えず、触ったものを記録する。**他人の API キーを含むファイルを編集する**ので |
| `hooks/dotagents-verify-gate.sh` | **ゲート。** 価値提案の本体 —— エージェントは「完了したように見えた」時点で止まる |
| `hooks/dotagents-lint-skill-frontmatter.sh` | **壊れた状態でインストールされて何も言わない** `SKILL.md` を拒否する |
| `scripts/gate.sh` | ゲートの操作面: arm / disarm / 委譲チェックの記録 / 状態表示。通常はあなたではなく `/da-verify` が呼ぶ |
| `scripts/verify-skills.sh` | `AGENTS.md` の不変条件をチェックに落としたもの。**実際に捕まえた**: どの YAML パーサも受け付けない frontmatter、本文が使うツールを欠いた `allowed-tools`、本文から言及されていない reference、到達不能な `user-invocable: false` |
| `scripts/test-verify-gate.sh` | **ゲートは唯一「閉じて落ちる」ことが必須のもの**で、これが無かった時代に2回 fail-open した |
| `scripts/test-lint-hook.sh` | **このリポジトリ最悪のバグを捕まえた**: scope チェックが誤った変数を見ていて**一度も発火していなかった** —— インストール済みで、何も強制していない状態 |
| `scripts/test-setup.sh` | 偽の `$HOME` に対して。インストーラは**資格情報と他ツールの hook を含むファイル**を編集する |
| `scripts/check.sh` | 上記すべてを1コマンドに。**5つ覚える代わりに1つ** |
| `scripts/test-non-interactive.sh` | **人間を待つものが1つも無いことを主張する。** `--non-interactive` フラグは作りません —— 設定時にだけ通る第2の経路ができ、既定の経路がプロンプトへ退行してもフラグ付きテストは緑のままになる。実際に**stdin を閉じるとゲートがハングする**バグを見つけた（ハングすればハーネスに殺され、それは non-blocking = fail-open） |

**削除したもの（同じテストに落ちた）:**

| 削除 | 理由 |
|---|---|
| `hooks/dotagents-statusline.sh` ＋ template ＋ `--statusline` | **一度もオプトインされなかったオプトイン。** 72行とインストーラの関数を使って、誰も求めていないステータスラインを描画していた。しかも「全 hook はブロックできなければならない」チェックに**例外を強制**していた —— ブロックできない唯一の hook だったので |
| `templates/claude.advisor.snippet.json` ＋ `--advisor` | 同じく**一度も有効化されなかった**。しかも背後の機能は experimental で Anthropic API 専用なので、**大半の環境に存在しない能力**をフラグが説明していた |

両方に共通するパターン: **一度も ON にされなかった、何かのためのオプション。** ツールキットの所有が煩わしくなる原因は**ファイル数ではなく**、「保持するか判断する前に、まず目的を再構成しないといけないファイル」です。ここにあるもので**「何を防ぐか」を1行で答えられないものは、同じように消すべき**です。

## テスト

```bash
./scripts/check.sh              # 全部: 構文、symlink、lint、振る舞いスイート4本、作業ツリーの汚れ
./scripts/check.sh --fast       # 構文と lint だけ
```

個別に走らせるのは、そのどれかを触っているときだけ: `verify-skills.sh`（lint）、`test-verify-gate.sh`、`test-lint-hook.sh`、`test-setup.sh`、`test-non-interactive.sh`。**assertion 数は書きません** —— 手で維持する数はコミットごとに古くなり、stale な記述を欠陥として扱うリポジトリではそれ自体が欠陥です。

CI は両スイートを **Linux と macOS の両方**で走らせます。壊れ方が両方向に出たからです —— bash 4 構文は Linux で通り macOS で落ち、`mktemp -t` の綴りは BSD で通り GNU coreutils で落ちる。

実テストを持つのはゲートとインストーラだけで、理由は正反対です。**ゲートはフェイルクローズでなければならない** —— 見つかった全てのフェイルオープンに回帰テストがあります。**インストーラは自分のものでないファイルを編集する** —— 他人の資格情報と他人のフックを含むので、テストは「書いていない秘密が生き残る」「他3ツールのフックが生き残る」「uninstall が何も残さない」を固定しています。

## シークレット

ここには何も秘密を置かず、インストーラは自分が書いていないものに触りません。テンプレートが宣言したキーだけをマージし、`~/.claude/.dotagents-managed.json` に記録し、先にバックアップを取り、自分のものでない既存値は書き換えません。既存フックは置換ではなく追記です。

`uninstall` が戻すのは各キーの**値**であって、ファイルの**バイト列**ではありません。設定は固定の整形で書き直されるので、別の整形をしていたファイルは整形され直します。`test-setup.sh` が検証しているのは値であり、それが正直に約束できることです。

CI では gitleaks を全履歴に対して走らせています。

## ライセンス

[MIT](LICENSE)
