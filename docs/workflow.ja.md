# ループ

**何をいつ打つか、そしてなぜそうするか** —— コードの大部分をエージェントが書く場合の話。

English: [workflow.md](workflow.md)

語彙は**独自のものを作らず公式に合わせています**。私的な語彙を作ると、後で公式のガイダンスを適用しにくくなるからです。出典は末尾に **official / opinion / research** で区別して載せ、**良い出典どうしが食い違っている箇所は平らに均さず名指し**します。

---

## 段階、そして "review" が実際には何なのか

公式は高さの違う2つのループを与え、両者を突き合わせてはいません。どちらも知っておく価値があります。

- **機構として**は、どのターンも *gather context → take action → verify results* で、段階は互いに溶け合う。
- **ワークフローとして**は4段階: **Explore → Plan → Implement → Commit**。

この一覧に**2つ欠けているのは意図的**で、腹に落としておく価値があります。

**"Verify" は段階ではありません。** どの段階にも必要な**性質**であり、公式のベストプラクティス文書が4段階より前、最初に扱う話題です。理由はこうです —— *エージェントは作業が完了したように見えた時点で止まる。実行できるチェックが無ければ「完了したように見える」が唯一のシグナルであり、**あなたが検証ループそのものになる**。*

**"Review" も段階ではありません。** 公式では**エスカレーション**、つまり見ていなかった作業に対するものです。このリポジトリはレビュー機構に最も投資していますが、それでもエスカレーションです —— **変更のリスクが高いとき、あるいはその場にいなかったとき**に手を伸ばすもので、差分ごとの儀式ではありません。

---

## 段階0 —— そもそも計画が必要か決める

> **差分を1文で説明できるなら計画は飛ばす。** *(official)*

計画が最も効くのは、アプローチが不確かなとき、変更が複数ファイルに跨るとき、対象のコードに不慣れなとき。typo・ログ1行・リネームなら純粋なオーバーヘッドです。**ループ中で最も安い判断であり、高い方向に間違えやすい判断**でもあります。

## 段階1 —— Explore

| 打つもの | 用途 |
|---|---|
| `/grill-me` | 大まかな案があり、要件が固まるまで質問攻めにしてほしいとき |
| `/da-investigate` | 「X はどこ」「何が依存している」「何に触る」 —— `file:line` で、固定予算内で、**確認できなかったことを名指しして**答える |

この段階の目的は、context が埋まる前に**狭めること**です。ここでの名前の付いた失敗は **infinite exploration** —— 徹底した気分になるために読む、というもの。`da-investigate` に予算があるのはまさにこのためで、`x-codebase-explorer` サブエージェントに展開するので**読んだ内容は彼らの context に留まり、あなたの context には戻りません**。

## 段階2 —— Plan、そしてディスクに書く

| 打つもの | 用途 |
|---|---|
| `/writing-plans` | 固まった要件を計画としてディスクに落とす |
| `/da-design-review` | コードが存在しない段階でその計画をレビューする |

**spec はファイルに書きます。** 散文に魔力があるからではなく、**ファイルは `/clear` と compaction を生き延びる**からで、そして後でレビュアが照らし合わせる基準になるからです。公式が挙げる「役に立つ spec」の条件は検査可能です。

1. **触るファイルとインタフェースを名指しする**
2. **対象外を明記する**
3. **末尾に、機能が動くことを証明する end-to-end の検証手順を置く**

> *「spec を精密にすることに使った時間の方が、実装を眺めることに使った時間より報われる」* *(official)*

`/da-design-review` がコストに見合うのはここだけです。**一方通行の扉・移行順序・ロールバックは計画段階で決まり、実装後は書き直しになる**からです。過去形の**プリモーテム**を走らせます —— 「6ヶ月後、これは失敗した。インシデントレビューを書け」 —— 失敗を**すでに起きたこととして**想像すると、何が起こりうるかを問うより**約30%多く原因を特定できる** *(research)*。

### そして clear して、新しいセッションで実装する

> *「spec が完成したら、実行のために新しいセッションを始める」* *(official)*

計画はもうディスクにあります。計画時の会話を実装に持ち込むのは context を食うだけで、何も買えません。

## 段階3 —— Implement

| 打つもの | 用途 |
|---|---|
| `/executing-plans` | 書かれた計画をレビューの節目付きで進める |
| `/test-driven-development` | あらゆる機能追加・バグ修正で、実装の前 |
| `/systematic-debugging` | バグ・テスト失敗・説明できない挙動 —— **修正案を出す前に** |
| `/using-git-worktrees` | 作業を今のワークスペースから隔離する必要があるとき |

## 段階4 —— Verify

| 打つもの | 用途 |
|---|---|
| `/da-verify` | **そのリポジトリ**の設定済みチェックを実行し、証拠付きで報告 |
| `/verify`（バンドル） | テストや typecheck ではなく、ユーザーと同じように end-to-end で動かす |
| `/run`（バンドル） | アプリを起動して目で見る |

**`/da-verify` は Stop ゲートを arm する唯一のものです。** これが一度も走らなかったセッションは**ゲートの無いセッション**です。だから**自動起動が、打つことと同じくらい重要**で、`disable-model-invocation` を絶対に付けてはいけません。

公式のはしご、弱い順 —— *各段は「準備の手間」と「注意力」を交換します*。

| 機構 | 強さ |
|---|---|
| プロンプト内の「実装後にテストを走らせて」 | 今日から、何にでも効く |
| `/goal` 条件を毎ターン再チェック | セッションを跨いでゲートする |
| **Stop hook** がターン終了を拒否する | 決定的 —— **ただし連続8回で自動解除される** |
| 結果の反証を試みる検証サブエージェント | **作業した本人が採点しない** |

検証として数えられるのは、**エージェント自身が読めるシグナルを返すもの**です: テストスイート、終了コード、リンタ、fixture との差分、スクリーンショット。数えられないのは「動きました」という主張。**出力を見せること。** 証拠を読むのは自分でチェックを再実行するより安く、しかも見ていなかったセッションにも効きます。

## 段階5 —— Review、エスカレーションとして

| 打つもの | 用途 |
|---|---|
| `/da-review-all` | テックリードのパス。変更を分類し、該当する層に委譲し、**層と層の間**に落ちるものを見る |
| `/code-review`（バンドル） | **2本目。** 別の作りなので別のものを見つける |
| `/find-bugs` | 3本目。先に攻撃面を全列挙してからスイープ |
| `/simplify`（バンドル） | 品質専用 —— 再利用・単純化・抽象度。**明示的にバグ探しではない** |
| `/requesting-code-review` | レポートではなく**手順**が欲しいとき |
| `/receiving-code-review` | 指摘が来て、反射的に実装せず評価したいとき |
| `/da-fix-plan` | **レビュー結果を順序付きの修正計画にする。何を直さないかを決めるのが主な仕事** |

**レビュアは2本、そして別のものを使ってください。** 同一の146 PR に4種の AI レビュアを当てた計測で、**指摘の93.4%は4つのうち1つだけが検出、4つ全部が検出したものは0件** *(opinion、ただし実データ付き)*。**単体の質よりアプローチの多様性**が効きます。自作のレビュー機構があってもバンドルのレビュアを残しているのはこのためです。

出力の扱いに関する制約が2つ、どちらも公式です。

> *ギャップを探せと指示されたレビュアーは、**作業が健全でもたいてい何か報告する**。それが指示された内容だから。**全部追うと過剰設計に至る**: 余計な抽象化層、防御的コード、起こり得ないケースのテスト。*

つまり **spec の外側の所見は「任意」であって「作業」ではありません**。そして**個人的な好みでブロックしない** —— 好みに属するものは `Nit:` で始めるので、11個のコメントのうちどれが実際に効くのか著者が判別できます。`/da-fix-plan` はこの引き算を構造化したものです。

このリポジトリのレビュアは報告の前に反証パスを通し、上位2つの重大度には3レンズのパスを当てます。それは**3つの独立した意見ではありません** —— 同一モデルを3つの角度から確認しただけで、その区別がなぜ重要かは `_shared/finding-discipline.md` にあります。

## 段階6 —— Commit

| 打つもの | 用途 |
|---|---|
| `/da-pr-describe` | diff を開く前に読める PR 説明。**自分で打つ** —— GitHub に書き込むのでタイミングはあなたのもの |
| `/finishing-a-development-branch` | 実装が終わり、統合ルートを決めるとき |
| `/commit`, `/pr`, `/commit-push-pr`（バンドル） | 機械的な手順 |

---

## 中断条件

成功条件は覚えやすい。**飛ばされるのはこちら**です。

**同じ問題で2回修正に失敗したら止める。** *(official)*

> *同じ問題で2回以上修正した場合、context は失敗したアプローチで散らかっている。`/clear` して、学んだことを織り込んだより具体的な prompt で始め直せ。**綺麗なセッション＋良い prompt は、修正を積み上げた長いセッションにほぼ必ず勝つ。***

機構としてはよく裏付けられています —— context が伸びると注意が劣化し、モデルは外部の証拠なしに自分のフィードバックだけで信頼できる自己修正をしません *(research)*。**ただし「2回」という数値自体は測定されていません。** 良い既定値として扱い、発見として扱わないこと。

**無関係なタスクの間で `/clear`。** 名前の付いた失敗は *kitchen sink session*。ただし公式の但し書きも重要です —— **1つの複雑な問題に深く入っていて履歴そのものが価値であるときは、蓄積させるべき**です。

**clear する前に外部化する。** `/clear` が安いのは、**重要だった状態がすでにディスクにある場合だけ**です —— 不変条件は `AGENTS.md`、計画はファイル、チェックポイントは git。compaction はあなたの依頼と主要なコードは保持しますが、**会話の初期にあった詳細な指示は失われることがあります**。だから常設のルールは1時間前に送ったメッセージではなく `AGENTS.md` に置きます。

**ツールキットが自分をディスパッチャにしたら、元は取れていません。** *(opinion。この件について誰かが言った中で最も鋭い)* どのエージェントが何をしているかを管理している自分に気づいたら、**その仕組み自体がプロジェクトになっています**。これには指標がありません。それでも気づくこと。

---

## 定期的に

| 打つもの | 用途 |
|---|---|
| `/skill-doctor` | 未使用でコンテキストを食っているスキル。**`/da-skills-audit` より先にこれ** |
| `/doctor` | listing の実コストと最大寄与者 |
| `/da-skills-audit` | 静的: 過剰制約、トリガ重複、Cursor 非互換、サイズ |
| `/skill-scanner` | 第三者スキルを信用する前のセキュリティ検査 |
| `anthropic-skills:skill-creator` | **実際の eval**: with/without の pass rate・トークン・時間 |

**増やした分は剪定で払う。** インストール済みの description はすべて context window の1%の予算を共有し、溢れると description が短縮され、その後**使用頻度の低いものから落とされます** —— モデルが依頼を照合するために必要なキーワードが削られるわけです。つまり**未使用のスキルはただ座っているのではなく、使っているスキルの発見を無言で劣化させます**。「多すぎ」は数値ではなく、**`/doctor` が listing の予算超過を報告している状態**です。

---

## 確定していないこと

主張だけのワークフロー文書は役に立たないので、明記します。

- **正典の5段階ループは存在しません。** 公式は3（機構）か4（ワークフロー）で、review はエスカレーション。実践者は意味のある形で食い違っています: 一方は**ハーネス**がセッションの終わりを本当に終わりと見なすか判定する入れ子ループという捉え方、もう一方は段階を退けて *guides（先に与える）と sensors（作られたものを観測する）* の対比を採り、この分野は guides に過剰投資していると論じます。**5段階という形は便宜であって発見ではありません。**
- **人間がどこに居るべきかは論争中です。** 公式はループの内側（計画を承認し、証拠を読む）。強い実践者の主張は、エージェントが人間の読む速度を超えた時点で行単位のレビューは逆効果になる、というもので、閾値違反時＋定期的な深掘りだけに介入することを提案します。**その定期的な深掘りの目的が「計装がずれていないかの確認」**であるのが良いところです。
- **エージェント開発の生産性の数値は信用できません。** 最も慎重な測定の試みは自らの設計を放棄し、経験者で **−18%（信頼区間 −38% 〜 +9%）** を報告し、自分のデータを *very weak evidence* と呼んでいます。綺麗な数字を引用している人は原典を読んでいません。
- **plan をディスクに書くことの効果量は測られていません。** 機構は明らかで公式も推奨していますが、広く引用される「初回成功率 3〜10倍」はベンダーのブログが匿名の報告を引いたものです。**繰り返さないこと。**

---

## 出典

**Official（Anthropic）** — [Best practices](https://code.claude.com/docs/en/best-practices) ·
[How Claude Code works](https://code.claude.com/docs/en/how-claude-code-works) ·
[Skills](https://code.claude.com/docs/en/skills) ·
[Run agents in parallel](https://code.claude.com/docs/en/agents) ·
[Code Review](https://code.claude.com/docs/en/code-review) ·
[Effective context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) ·
[Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) ·
[When to use multi-agent systems](https://claude.com/blog/building-multi-agent-systems-when-and-how-to-use-them) ·
[Building verification loops](https://claude.com/blog/building-verification-loops-in-claude-code-with-skills)

**Opinion** — [Ronacher, The Coming Loop](https://lucumr.pocoo.org/2026/6/23/the-coming-loop/) ·
[Ronacher, Agent Psychosis](https://lucumr.pocoo.org/2026/1/18/agent-psychosis/) ·
[Böckeler, AI coding sensors](https://www.thoughtworks.com/en-de/insights/blog/generative-ai/harness-engineering-agent-feedback-exploring-ai-coding-sensors) ·
[Böckeler, human-on-the-loop](https://www.thoughtworks.com/en-de/insights/blog/generative-ai/cybernetics-and-human-on-the-loop-in-agentic-coding) ·
[Willison, Agentic Engineering Patterns](https://simonw.substack.com/p/agentic-engineering-patterns) ·
[Osmani, Agentic Code Review](https://addyosmani.com/blog/agentic-code-review/) ·
[Beck, Genie Lessons](https://newsletter.kentbeck.com/p/genie-lessons-nobody-wants-agents) ·
[Cognition, Don't Build Multi-Agents](https://cognition.com/blog/dont-build-multi-agents)

**Research** — [METR, changing the experiment design](https://metr.org/blog/2026-02-24-uplift-update/) ·
[Huang et al., LLMs Cannot Self-Correct Reasoning Yet](https://arxiv.org/abs/2310.01798) ·
[Cross-Context Review](https://arxiv.org/pdf/2603.12123) ·
[Klein, Performing a Project Premortem](https://www.researchgate.net/publication/3229642_Performing_a_Project_Premortem) ·
[Are LLM Evaluators Really Narcissists?](https://arxiv.org/pdf/2601.22548)
