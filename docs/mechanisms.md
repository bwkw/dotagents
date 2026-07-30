# どの仕組みを選ぶか、そしてなぜ

Claude Code と Cursor はエージェントの挙動を変える手段を複数持っていて、**互換ではありません**。間違った手段を選ぶと、**ルールが「どこにも強制されていない場所」に書かれた状態**になります。

---

## 判断は1つの表で済む

公式の枠組みは分類ではなく**引き金**です —— カテゴリとして何に属しそうかではなく、**直前に何が起きたか**で選びます。

| 何が起きたか | 何を足すか |
|---|---|
| エージェントが規約を2回間違えた | `AGENTS.md` に書く |
| 同じプロンプトを毎回打っている | **名前で呼ぶスキル** |
| 同じ手順書を3回目貼った | **スキル** |
| エージェントに見えないものからデータをコピーしている | 接続は **MCP サーバ**、使い方は**スキル** |
| 読み返さない出力で会話が溢れる | **サブエージェント** |
| **毎回、確認なしに**起きてほしい | **hook** |
| 2つ目のリポジトリでも同じ構成が必要 | **plugin**、そして marketplace |

公式ドキュメントで最も有用な1行は、hook かそれ以外かを決めるこれです。

> *ガードレールは hook に置け。CLAUDE.md やスキルに書いた「`.env` を絶対に編集するな」は**お願いであって保証ではない**。*

**スキルは読まれて解釈される。hook は実行される。** 調子の悪い日にも成立しなければならないルールなら、それは hook です。

## それぞれのコスト

| 仕組み | いつ読まれる | コスト |
|---|---|---|
| `AGENTS.md` | 毎セッション、自動 | **毎リクエスト、常に** |
| スキルの **description** | 毎セッション | **毎リクエスト、インストール済み全スキル分** |
| スキルの **本文** | 起動時 | **セッション終了まで context に残り、再読み込みされない** |
| サブエージェント | 起動時 | 隔離 —— 読んだ内容はその context に留まる |
| hook | イベント発火時 | **ゼロ**（出力を返さない限り） |
| MCP サーバ | セッション開始 | ツール名のみ。スキーマは要求時 |

ここから来る帰結が2つ、この repo の判断の大半を規定しています。

**インストール済みのスキルは、他の全スキルに課税します。** description は **context window の1%**の予算を共有します。溢れると Claude Code は「**使用頻度の低いスキルから description を落とす**」ので、未使用のスキルはただ座っているのではなく、**使っているスキルの自動起動を無言で劣化させます**。

**そして、その予算を分け合っている大半はこのリポジトリのものではありません。** このマシンでの実測:

| 出所 | 場所 |
|---|---|
| ディスク上 | `~/.agents/skills/` —— 自作10、残りは上流 |
| Anthropic 管理プラグイン | `~/Library/Application Support/Claude/…` |
| **CLI バイナリにコンパイル済み** | **ファイルとして存在しない**。実行ファイル内の文字列定数。**ここが最も多い** |

**数字は書きません。** ここは以前「24 / 11 / 40 で計75」と書き、README も `decisions.md` も
`templates/claude.settings.snippet.json` も同じものについて**それぞれ違う数**を書いていて、実測は23でした。
同じ数を4箇所で手で維持すると4つの数になります。`/doctor` と `/skill-doctor` が実数を見ます。

このリポジトリの監査は2回とも**ファイルシステムを読んだために外しました**。75本のうち40本はファイルシステム上に無いからです。**`~/.agents/skills` から数えた数は合計ではありません。** `/doctor` と `/skill-doctor` が全体を見ます（判断の記録 §8）。

**スキル本文は一度きりではなく継続的なコストです。** 起動するとセッション中残り、再読み込みされないので、**全体に効く指針は「手順」ではなく「常設の指示」として書く**必要があります。auto-compaction 後は各スキルの**先頭 ~5,000 トークンだけ**が復元されます。だから `reference/` があり、詳細は要求時に読まれ、読まれるまでコストはゼロです。

---

## コマンドは、もうスキルです

**使い分けの判断は存在しません。** 公式の原文:

> **Custom commands have been merged into skills.** `.claude/commands/deploy.md` のファイルと
> `.claude/skills/deploy/SKILL.md` のスキルはどちらも `/deploy` を作り、同じように動く。既存の
> `.claude/commands/` ファイルは動き続ける。スキルは任意の機能を追加する —— 付随ファイル用のディレクトリ、
> あなたが呼ぶかモデルが呼ぶかを制御する frontmatter、そして関連するときにモデルが自動で読み込む能力。

**非推奨ではありません** —— 語は「統合された」「動き続ける」「スキルが推奨」です。ただし**素の `commands/*.md` が好ましいケースは1つも文書化されていません**。機能の少ないスキルが互換のために残っているだけです。**Cursor の commands ドキュメントページは現在 404。**

### スキルの2種類

かつてのコマンド対スキルの問いは、いま **frontmatter の1フィールド**です。

| | モデル起動（既定） | 自分で起動（`disable-model-invocation: true`） |
|---|---|---|
| `/name` と打つ | ○ | ○ |
| モデルが選ぶ | ○ | **×** |
| 別のスキルが名前で呼ぶ | ○ | **×** |
| description が context に載る | ○ | **× —— 予算コストゼロ** |

公式の指針:

> **副作用のあるスキルには `disable-model-invocation: true` を使え。** context を節約し、あなただけが起動することを保証する。…… **コードが完成して見えるからといって Claude がデプロイを決めるのは望ましくない。**

つまり **副作用があるもの、あるいは結局いつも自分で打つもの**。**参照用の知識には使いません** —— そこでは自動起動こそが価値です。

罠は3行目です。**自動起動だけでなく、プログラム的な `Skill` 呼び出しとサブエージェントへの preload も止めます**。だから別のスキルが名指しで委譲している相手に付けると、その委譲が**エラーも出さずに壊れます**。この repo で絶対に付けない2箇所は、lint hook とリンタの両方が強制しています。

- **`da-verify`** —— `gate.sh arm` を走らせる唯一のもの。自動起動を切ると Stop ゲートが arm されず毎ターン通る = **ガードレールが開く**。
- **`x-review-backend` / `-frontend` / `-infra`** —— `da-review-all` が名指しで委譲する先。

### `/` メニューから隠すのは別のフィールド

`user-invocable: false` は**メニューから消すがモデルからは呼べる**ままにします。層別レビュー3本がこれで、入口を1つに寄せています。`disable-model-invocation` と併用すると**どの経路からも到達不能**になるため、リンタがエラーにします。

**ただし Cursor はこのフィールドを無視します。** 層別3本は Cursor のメニューに残り、さらに **Cursor は subagent もコマンドピッカーに出します**。これは*表示*の差であって挙動の差ではありませんが、`/da` の件数が Claude で7・Cursor で12 になる原因で、**だから内部用は `x-` 接頭辞で分けています**（判断の記録 §7）。フィールドで隠す方法は両エージェントで成立しません。

---

## Cursor は全部の部分集合しか読まない

両エージェントを一級市民として扱うので、**制約になるのは常に Cursor が理解する範囲**です。

| | Claude Code | Cursor |
|---|---|---|
| スキル | `~/.claude/skills/`、symlink を追う | `~/.agents/skills/` をネイティブに、加えて `.cursor/` `.claude/` `.codex/` |
| スキル frontmatter | 多数 | **`name` `description` `paths` `disable-model-invocation` `metadata` のみ** |
| `name` とディレクトリ名の一致 | 不要 | **必須** |
| サブエージェント | `~/.claude/agents/` | `.claude/agents/` も読む。フィールドは `name` `description` `model` `readonly` `is_background` |
| hook | `settings.json`、PascalCase | `hooks.json`、camelCase、**非互換** |
| 常時ロード | `CLAUDE.md` | `AGENTS.md` か `.cursor/rules` |
| コマンド | レガシー | ドキュメントページ削除 |

`allowed-tools` `argument-hint` `context: fork` `model` `when_to_use` `user-invocable` は **Cursor では単に存在せず、それを報告するものもありません**。だから `AGENTS.md` の規則: **Claude 専用フィールドを全部剥がしても、スキルは同じ挙動をしなければならない**。制約は本文に散文で書き、frontmatter はその上の最適化。サブエージェント定義も同じ理由で、読み取り専用の制約を `tools:` と本文の両方に書いています。

`${CLAUDE_SKILL_DIR}` `$ARGUMENTS` `` !`command` `` は Claude Code の拡張です。依存する場合、その依存が Cursor で生き残る形になっている必要があります。

---

## このリポジトリが公式から外れている場所

**`verify-skills.sh` は 8,000字を固定の予算にしています**が、実際の予算はモデルに応じて変わります。この数値は 200K ウィンドウの1%の逆算近似で、上流には「予算が実ウィンドウではなく固定基準で計算される」既知の issue もあります。**時々厳しすぎる固定目標は、目標が無いよりは有用**という判断で、真実の値は `/doctor` です。

**`skillOverrides` は使いますが、Cursor に存在しないスキルに対してだけです。** 値は `on` / `name-only`（載るが description 無し）/ `user-invocable-only`（モデルから隠すが打てる）/ `off`（両方から隠す）。これは Claude Code の `settings.json` にあり Cursor は読まないので、**自作スキルに使うと両エージェントが「何が有効か」で食い違います**。バンドル・プラグインのスキルは Cursor に存在しないので食い違う相手がいません。6件を `templates/claude.settings.snippet.json` 経由で抑制しており、マニフェストに記録され `uninstall` で正確に戻ります。**規則: Cursor にも存在するスキルには絶対に使わない。**

## このマシン固有の危険が2つ

**Claude Code が2つ入っていて、設定の効き方が同じではありません。** `$PATH` の `claude` は mise shim 経由の **2.1.148**、Claude Desktop は自前でダウンロードした **2.1.219** を動かします。両バイナリの設定スキーマを直接読んで確認した結果:

| 設定 | 2.1.148 | 2.1.219 |
|---|---|---|
| `skillOverrides` | ○ | ○ |
| `skillListingBudgetFraction`（既定 `0.01`） | ○ | ○ |
| `skillListingMaxDescChars`（既定 `1536`） | ○ | ○ |
| **`disableBundledSkills`** | **無い —— 黙って無視される** | ○ |

抑制に `disableBundledSkills` ではなく名前単位の `skillOverrides` を使うのはこれが理由です。**粗い方のスイッチは古いバイナリでは何もせず、その事実を何も知らせません。** 内容としても不適切で、`code-review` と `review`（使用ログで実際に使われている）を含む約40本を一撃で消します。

**バンドルスキルはバイナリと一緒に変わります。** コンパイル済みなので、CLI のアップグレードで名前が追加・改名・削除されても、このリポジトリの何も気づきません。存在しないスキルを指す override は**エラーではなく無効**なので、古い entry は静かに失敗します。**バージョンが変わったら `/doctor` を読み直してください。**

---

## 出典

仕組みの分類そのものの出典（すべて 2026-07-28 に確認）:

- [Extend Claude Code — features overview](https://code.claude.com/docs/en/features-overview)
- [Extend Claude with skills](https://code.claude.com/docs/en/skills)
- [Skill authoring best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices)
- [Steering Claude Code: when to use CLAUDE.md, skills, hooks, and subagents](https://claude.com/blog/steering-claude-code-skills-hooks-rules-subagents-and-more)
- [Agent Skills — Cursor](https://cursor.com/docs/skills) · [Subagents](https://cursor.com/docs/subagents) · [Hooks](https://cursor.com/docs/hooks)

### レビュー観点の裏にある出典

レビュースキルのチェックリストはここで発明したものではありません。**数値や固有の技法を含む観点は、どこから来たかを記録しています** —— 将来の読者が「信じる」のではなく「まだ成立するか確かめられる」ようにするためです。

| スキル内で使っている主張 | 出典 |
|---|---|
| LLM を判定者に使うと偏りが出る。ただし**自己優遇の数値には依拠しない** —— 反証論文があり、別の解析では偏りは検証者ごとの一律の傾向（最厳格〜最寛容で 2.8 ポイント差）とされる。`refuted` 既定の根拠は**アンカリング除去・検証者分散・内在的自己修正の不成立**に置いてある | [Self-Preference Bias in LLM-as-a-Judge](https://arxiv.org/pdf/2410.21819) · [Justice or Prejudice?](https://arxiv.org/pdf/2410.02736) · [Are LLM Evaluators Really Narcissists?](https://arxiv.org/pdf/2601.22548) · [LLMs Cannot Self-Correct Reasoning Yet](https://arxiv.org/abs/2310.01798) |
| 冗長性バイアスは長い回答への選好を 15〜30 ポイント押し上げる。位置バイアスも存在する（どちらも独立に測定済み） | 上と同じ |
| エージェント生成コードの約20%が**存在しないパッケージ**を参照する。slopsquatting はその幻覚名を実際に登録する。yank 済み・CVE 持ちのバージョンが再現される。happy-path バイアスは catch-all ハンドラとタイムアウト無しの呼び出しとして現れる | [AI Hallucinations in Production Code (2026)](https://www.devx.com/uncategorized/ai-hallucinations-production-code-risks-mitigations-2026/) |
| **prospective hindsight**（失敗が既に起きたものとして想像する）は原因の正しい特定を約30%増やす | Mitchell, Russo & Pennington 1989 —— [Performing a Project Premortem](https://www.researchgate.net/publication/3229642_Performing_a_Project_Premortem) (Klein, HBR 2007) · [Ness Labs](https://nesslabs.com/pre-mortem-anticipate-failure-with-prospective-hindsight) |
| Core Web Vitals の閾値 LCP ≤ 2.5s / INP ≤ 200ms / CLS ≤ 0.1。INP が FID を置き換え、最も落ちやすい。原因は操作中のメインスレッド JavaScript | [Core Web Vitals 2026 guide](https://www.digitalapplied.com/blog/core-web-vitals-2026-inp-lcp-cls-optimization-guide) · [Ultimate checklist](https://www.corewebvitals.io/core-web-vitals/ultimate-checklist) |
| WCAG 2.2 が 2.1 を置き換え、新基準9件。コントラストが最頻の失敗。Accessible Authentication (3.3.8) はペーストと autofill が動くことを要求する | [WCAG 2.2 checklist](https://www.levelaccess.com/blog/wcag-2-2-aa-summary-and-checklist-for-website-owners/) · [What frontend developers need to fix](https://danholloran.me/posts/wcag-2-2-what-frontend-developers-need-to-fix) |
| CSP: `unsafe-inline` / `unsafe-eval` を避け nonce か hash を使う。許可ドメインを最小化し、依存が増えたら再点検する | [OWASP WSTG: Test for CSP](https://owasp.org/www-project-web-security-testing-guide/latest/4-Web_Application_Security_Testing/02-Configuration_and_Deployment_Management_Testing/12-Test_for_Content_Security_Policy) |
| Terraform の state は属性を**平文で**持つ。backend を暗号化・バージョニング・ロックし、読める人を制限する。機械的な検査はスキャナが覆う | [Terraform Architecture Review Checklist (CIS-mapped)](https://archguard.io/blog/terraform-architecture-review-checklist) · [IaC Security Review](https://www.propelcode.ai/blog/infrastructure-as-code-security-review-terraform-cloudformation) |
| production-readiness の観点、そして**依存の readiness が最も飛ばされやすい**こと | [Google SRE: Production Readiness Review](https://sre.google/sre-book/evolving-sre-engagement-model/) · [Launch checklist](https://sre.google/sre-book/launch-checklist/) · [Production readiness checklist](https://getdx.com/blog/production-readiness-checklist/) |
| **レビューを生き延びるバグの分類と分布** —— 28プロジェクト・173 PR から見つかった見逃しバグ187件: semantic 51.3% / build 15.5% / analysis checks 9.1% / compatibility 7.5% / concurrency 4.3% / configuration 4.3% / GUI 2.1% / API 2.1% / security 2.1% / memory 1.6%。semantic の内訳では例外処理が 36.5%、analysis checks では null チェック漏れが 47.1%。**観点クラスタの構成をこれに突き合わせて決めている** | [Which bugs are missed in code reviews (MSR 2022, SmartSHARK)](https://arxiv.org/pdf/2205.09428) |
| 個人的な好みの問題でブロックしない。任意の指摘は `Nit:` と明示する | [Google: What to look for in a code review](https://google.github.io/eng-practices/review/reviewer/looking-for.html) |
| 4種の AI レビュアを同一146 PR に当てると、**指摘の 93.4% は4つのうち1つだけが検出**し、4つ全部が検出したものは0件 —— 効くのはレビュアの質より**多様性** | [Osmani, Agentic Code Review](https://addyosmani.com/blog/agentic-code-review/) · [Cross-Context Review](https://arxiv.org/pdf/2603.12123) |
