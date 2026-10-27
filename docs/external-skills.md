# 外部スキルの採否と保守方針

## 結論（2026-10-26）

**既存の上流保守を継続し、不足する用途を補う上流スキル 9 本を選択導入した。** 外部依存をゼロにすること自体は目的にしない。上流のままで必要な動作を満たすなら、その保守を利用する方がよい。

最初の調査では「取り込める」ことから「取り込むべき」へ飛躍し、`retro` を日本語の `da-retro` として追加した。反対側の独立評価と本文の比較実行を受け、自前版の採用と自前化推進を撤回した。その後、ユーザーが依存先や新しい用途も含めた全体の導入を希望したため、保留候補の補助ファイルを調べ、実行できるものを検証し、上流版の構成を整えた。経緯は [決定 42〜44](decisions.md) に残す。

## 選ぶ基準

| 比較する案 | 採る条件 |
|---|---|
| 追加しない | 既存スキルか通常の依頼で足りる。新しい道具を覚える負担に見合う不足が確認できない |
| 上流版を選択導入 | 実際の作業で不足があり、依存先まで読んで既存の配置・権限・検証・並列数と衝突しない。通常の依頼や既存スキルに対する改善が確認できる |
| 自前の規律を持つ | 上流の振る舞いと必要な振る舞いに継続的な差があり、その差が実行比較や実際の失敗で裏付けられる。維持責任も引き受ける。単なる翻訳や依存数の削減だけでは足りない |

上流管理とは、毎回 GitHub に接続して実行することではない。インストール済みのスキルはローカルファイルであり、外部依存は主に導入・更新・他スキル名への参照として現れる。自前化すると、その更新責任と互換性の検証をこちらで持つことになる。

## 確認範囲

ローカルの調査開始点は `4c1879e`。上流の比較対象は [mattpocock/skills@5beb35b](https://github.com/mattpocock/skills/tree/5beb35b040e3de97e54fa9e386d7e42d15c295c2/skills/engineering)。最初の調査で全 20 本の `SKILL.md` を読んだ。反対側の評価者は先行の採否表を読まず、20 本の description と有望・衝突候補の本文から独立に評価した。

追加で `prototype/LOGIC.md`・`UI.md`、`codebase-design/DEEPENING.md`・`DESIGN-IT-TWICE.md`、`writing-for-agents/SKILL.md`・`SKILL-MECHANICS.md`、`wizard/template.sh`、設計改善の HTML 補助ファイルと用語集・ADR の形式を読んだ。採用しない tracker 一式は未確認。新しい対象として Archify の安定版と Anthropic 公式の frontend-design も確認した。

`da-skills-audit` のファイル監査は実施した。ハーネス固有の `skill-doctor`・`doctor` と Anthropic のベンチマークは利用できず、未実行。利用頻度、全体の発火精度、3 ハーネスでの動作確認はできていない。

## engineering の採否

| 対象 | 今回の判断 | 反対側から確認した理由 |
|---|---|---|
| `retro` | **上流版を導入。自前版は撤回のまま** | 環境改善の焦点に価値がある。依存の執筆方針も含めて導入する。自前版との比較は 1 ケースだけで、一般の性能差は未測定 |
| `prototype` | **上流版を導入** | 状態モデルや UI の選択肢を動かして確かめる用途を補う。使い捨ての試作に限り、本実装へ移す時は既存の TDD・検証規約に従う |
| `wizard` | **上流版を導入** | 人が行う設定の案内を補う。テンプレートの構文・値の更新・重複防止・入力 EOF を一時環境で検証した。実際の秘密情報の入力や外部設定は実行していない |
| `codebase-design`、`improve-codebase-architecture` | **上流版を導入** | 現状の設計改善を候補から比較する用途は、実装前の spec レビューと異なる。語彙・複数役・HTML 報告まで含む手法として導入。本体は人が明示して使う設定を維持 |
| `domain-modeling` | **設計改善の依存として導入** | 用語をシナリオとコードで検証する。用語集・ADR はプロジェクトの既存配置・profile の規則を優先する |
| `grill-with-docs` | 追加しない | 既存の `grilling` と今回入れた `domain-modeling` を呼ぶ包み紙なので、入口をもう一つ増やさない |
| `tdd`、`diagnosing-bugs`、`research` | 新規追加しない | 既存の TDD・デバッグ・調査と重複。`research` は既に上流版を利用している。役割を重ねたり自前版へ移したりする根拠はない |
| `code-review`、`pr` | 新規追加しない | `da-review-all`・`da-pr-describe` と重複。上流レビューは常に 2 軸の並列役を起動し、小さい差分を inline で扱う決定 41 と異なる |
| `implement`、`implement-spec`、`to-spec`、`to-tickets` | 新規追加しない | 既存の spec・実装ループと重複し、別の tracker や呼び出し先を導入する。縦に検証できる分割などの観点は、新しい入口を増やさず検討できる |
| `setup-matt-pocock-skills`、`triage`、`wayfinder`、`ask-matt` | 新規追加しない | 上流一式の tracker・状態管理・案内を導入する面が大きい。複数セッションにまたがる意思決定などで困った実例が出るまで追加しない |

これは各スキルの一般的な品質の順位ではなく、この構成に足す必要があるかの判断である。出典は [上流の一覧](https://github.com/mattpocock/skills/blob/5beb35b040e3de97e54fa9e386d7e42d15c295c2/skills/engineering/README.md) と各本文。

## retro を比較した結果

`retro` は、作業記録からエージェントの環境の改善案を出す振り返り。コードの欠陥だけでなく、情報の探しにくさ、検査の未配線、効かない指示、ツールの手間を対象にする。

架空の作業記録 1 件を、独立した同じ継承モデルの 3 セッションで実行した。評価前に定めた 6 項目を満たした結果は、通常の依頼 5、自前版 6、上流版と必須依存 6。通常の依頼では出なかった CI の lint 未配線を、両方のスキルが提案した。自前版でしか得られない改善は出なかった。入力・評価項目・観測内容・限界は [比較記録](evaluations/2026-10-26-retro.md) に記載する。

この 1 回から一般の性能差や採用率は言えない。本文を明示して読ませた比較であり、自動発火や実際の名前解決も測っていない。

反対側からもう一度確認した時点では、上流 2 本の即時導入も保留した。その際の指摘は、導入後も次の制約として残る。

- [retro](https://github.com/mattpocock/skills/blob/5beb35b040e3de97e54fa9e386d7e42d15c295c2/skills/engineering/retro/SKILL.md) 自体は人が明示して呼ぶが、必須の [writing-for-agents](https://github.com/mattpocock/skills/blob/5beb35b040e3de97e54fa9e386d7e42d15c295c2/skills/productivity/writing-for-agents/SKILL.md) はスキル作成や `AGENTS.md` の編集時にも発火する。導入の影響は振り返りだけに閉じない。
- 依存側にも `disable-model-invocation` を付けると呼び出せなくなるため、両方を人専用にして影響を限定する解決にはならない。
- 追加の執筆方針と、3 ハーネスでの依存解決、実案件で改善案が採用されるかは未評価。

今回の導入後、実際の改善案の採用率や費用を見て継続を判断する。導入したことや静的検査の成功を効果の実証とは扱わない。

## 今回追加した上流セット

| 取得元 | 固定した版 | 導入した名前 |
|---|---|---|
| [mattpocock/skills](https://github.com/mattpocock/skills/tree/5beb35b040e3de97e54fa9e386d7e42d15c295c2/skills) | `5beb35b040e3de97e54fa9e386d7e42d15c295c2` | `retro`、`writing-for-agents`、`prototype`、`wizard`、`codebase-design`、`improve-codebase-architecture`、`domain-modeling` |
| [tt-a1i/archify](https://github.com/tt-a1i/archify/tree/v3.2.0/archify) | 安定版 `v3.2.0` | `archify` |
| [anthropics/skills](https://github.com/anthropics/skills/tree/dbd4588f9e1033efb41dad4bef2f7947c8993d44/skills/frontend-design) | `dbd4588f9e1033efb41dad4bef2f7947c8993d44` | `frontend-design` |

`artify` という名前は確定できなかったため、コードや設計を図にする文脈で近い Archify と仮定し、その公式リポジトリを調査・選択した。検索結果の人気や第三者の安全バッジを採用根拠にはしていない。

スキル本文は書き換えず、`npx skills@1.7.4 add ... -s <名前>` で選択導入した。9 本・228 ファイルについて、監査用に取得した版と導入先の全ファイルの SHA-256 が一致した。Claude 側のリンク、共有スキルの実体、lockfile の出所も確認した。Cursor と Codex は共有の `~/.agents/skills` を読む。実際に各ハーネス内から全スキルを呼ぶ検証は未実施で、次のターン以降の一覧に反映される。

`retro`・`improve-codebase-architecture` は上流の明示呼び出し設定を維持した。依存の `writing-for-agents`・`codebase-design`・`domain-modeling` 等は自動適用される。`prototype` のテスト省略は使い捨ての試作に限り、本実装にはリポジトリの TDD 規約を優先する。ADR の配置にも既存の規則を優先する。

Archify は既存の ADR 専用の PNG 図解や、このアプリの会話内可視化と役割を分け、ソースの根拠と検査証跡を伴う持ち運べる HTML 図に使う。frontend-design は正しさのレビューではなく視覚設計を補う。設計改善の上流 HTML 報告は Tailwind・Mermaid の CDN に依存するため、Archify の単体 HTML と同じオフライン性は保証しない。

### 実施した検査と、しなかった検査

| 検査 | 結果と限界 |
|---|---|
| `skill-scanner` による 9 本の静的検査 | いずれも機械検出 0。ただし通常の scanner は `.mjs` やスキル直下の `.sh` を読まないため、これだけで可否を判断していない |
| scanner の既存関数を使う追加の再帰検査 | Matt の 7 本と Archify の 143 ファイルを対象に `.mjs`・`.js`・`.sh`・本文も検査。15 件を検出し、すべて周辺のコードを確認。14 件は正規表現の `.exec()`、1 件は結果表示の `composition.profile` を設定変更と読む誤検出だった |
| 通信・実行・設定の確認 | Archify の更新確認は固定した URL への GET、リダイレクト拒否・時間と応答サイズの上限を持つ。更新コードをダウンロード・実行しない。今回の実行検証ではこの通信を環境変数で無効にした。説明を常にページ化するグローバル設定は追加していない |
| `wizard/template.sh` | `bash -n` が成功。実際の外部サービスや秘密情報を使わず、一時ファイルで値の更新・重複防止・EOF での停止が成功。生成する各 wizard の実動作はその案件で別途検証する |
| Archify `doctor` | 終了コード 0。レンダラー・スキーマ・検証・配布のランタイムを確認 |
| Archify `finalize architecture` | 同梱サンプルで validate・deliver・check・実際の Chrome による browser-check がすべて成功。sandbox 内は Chrome のパイプが閉じたため、一時コピーの同じ入力を sandbox 外で再実行して確認。目視による品質評価はしていない |
| Archify 不正入力 | 存在しない接続先を持つ入力は validate で失敗し、終了コード 1。直前の正常な HTML のハッシュが変わらないことを確認 |
| モデルが行う設計・試作・文言の品質 | 9 本を横断する効果のベンチマークは未実施。retro の 1 ケース比較以外の品質向上・費用削減・採用率は主張しない |

これは限定した静的監査と実行確認であり、同梱する全ランタイムを逐語的にレビューしたセキュリティ認定ではない。

### Archify の外部監査警告

インストーラーが表示した Socket の警告 1 件についても [監査本文](https://www.skills.sh/tt-a1i/archify/archify/security/socket) を確認した。`delta/architecture-delta.mjs` の低水準 API は SVG/CSS を組み込み、任意の `baseHtml`・`headHtml` を sandbox 属性のない `srcdoc` iframe に入れるため、入力が信頼できない場合に XSS になりうるという指摘だった。安定版の同ファイル `renderArchitectureDeltaHtml()` でも、この組み込み方を確認した。

通常の CLI の compare は JSON を検証・再描画してからこの API を呼ぶ（`bin/archify.mjs` の `renderValidatedArchitecture()` から `renderArchitectureDeltaHtml()` への経路）。このため「通常の CLI が任意の外部 HTML をそのまま受け付ける」とは結論していない。外部の SVG/HTML を直接低水準 API へ渡す用途まで安全とは扱わず、通常の JSON 生成経路で使う。追加の説明ページ・差分 API・全ブラウザに対する網羅テストは実施していない。

### 予算と既存 lint の限界

導入と `grill-me` の整理後は、ディスク上で 39 本（自作 15・外部 24）、リンター計測の description は 6,286 文字。目安の 8,000 文字以内だが、組み込み・プラグインを含む総数ではない。これ以上は用途の重複を再点検してから増やす。

Archify の本文は約 18.4 KB で 12 KB の目安を超える。検査・配布を含む道具として上流のまま使う代償として明示し、勝手な短縮や fork はしない。既存の subagent-driven-development の約 28 KB も残る。呼んだ時の負担を実利用で確認する。

インストール直後の全体への dotagents lint は終了コード 1、21 エラー・39 警告だった。既存 6 件の危険例・診断例の検出と、新規 15 件のサンプル・独自 URI・出力パスの誤認である。特に出力先の `review-2`・`review-3`・`visual-check`・`architecture-review` を未導入スキルと誤認する 4 件は、通常のリポジトリの検証ゲートも止めたため、リンターの抽出境界を修正した。

先に実物のリンターを通す回帰テストを追加し、出力パスで落ちることと、本物の未導入呼び出しでは失敗することを確認した。修正後の lint hook・linter テストは 66 件成功。上流の本文や保護対象の許可リストは変更していない。修正後のインストール全体への lint は 17 エラー・39 警告で終了コード 1。残りのサンプルの絶対パス・プロジェクト用リンク・独自 URI 等は別に残り、全体が lint 成功したとは報告しない。

## 既存の外部依存の扱い

調査開始時のディスク上の対象は自前 14 本・外部 16 本、リンター計測の description は合計 4,076 文字。組み込みやプラグインを含む総数ではない。初回の `install` で既存の `da-adr-figure` も配布されたため、その後の自前の本数とは異なる。

既存の `research`・`grilling`、obra の計画・実装の規律、Sentry の別系統のレビュー・監査、文書のスキルは維持する。廃止済みの `grill-me` 以外は削除せず、既存スキルの上流更新も行っていない。外部だからという理由では置き換えない。

変更が必要になった時に守る契約として、`skills/da-spec/SKILL.md:87` は `writing-plans` を呼び、`scripts/loop.sh:745` は計画のパスと英語の見出しを解析する。自前化する必要が生じても、翻訳や改名だけでは済まず、利用側と結合テストを一緒に移す必要がある。

`grill-me` は、本文が `grilling` を呼ぶだけの廃止済みラッパーであることと利用側が名指ししていないことを確認し、リンク・実体・古い lock エントリを整理した。既存の `subagent-driven-development` は 28,077 バイトのまま。呼び出し先の契約があるため、利用実態を見ずに削除していない。

## 検証の範囲

初回の全検査では、生成物を含まない一時コピーで lint・ループ・ゲート・インストーラー・非対話検査が成功した。動画テストだけは sandbox 内で Node.js が異常終了し、同じテストの sandbox 外再実行では 5 件とも成功した。これはスキルの有用性の検証とは別である。

自作スキルに残す変更は、`da-skills-audit` でハーネス固有の補助ツールが利用できなければ未実行を明示してファイル監査を続ける修正。`da-retro` は配布元・配布先から外したままで、上流の `retro` を使う。

自前版の撤回時点では、生成物のない一時コピーで次を検査した。

| 検査 | 結果 |
|---|---|
| `./scripts/check.sh --fast` | 終了コード 0。lint、概要出力、動画・図の検査、停止理由の一致を確認。振る舞いの全スイートはこの実行では省略 |
| `./scripts/test-setup.sh` | 終了コード 0、55 件成功。削除したスキルのリンクと孤児が残らない検査も含む |
| 実環境の `./scripts/setup.sh install` | 終了コード 0。`da-retro` の 2 本の配布リンクを刈り取り、設定と hook は変更なし |
| `git diff --check` | 終了コード 0 |

文書とスキルの差分は未コミット。既存の `.venv` 等の生成物には手を入れていない。

9 本の導入とリンター修正後も、追跡元のコミットに今回の差分・新規文書だけを適用した一時コピーで検証した。元のチェックアウトには既存の `.venv` と `node_modules` を読む lint の失敗が残るため、これらを変更せずにソースの検証を分けている。

| 最後の検査 | 結果 |
|---|---|
| `./scripts/gate.sh verify --json` | 終了コード 0、`ok: true`、`ran: 10`。対象外のチェックは profile の paths 判定で省略され、全スイートを実行したという意味ではない |
| `./scripts/check.sh --fast` | 終了コード 0。動画テストも含めて成功 |
| `./scripts/test-lint-hook.sh` | 終了コード 0、66 件成功。先に回帰ケースが失敗することを確認してから修正 |
| 導入した 9 本の配布内容 | 228 ファイルすべてが監査した固定版と一致。Claude のリンクと lock の出所も確認 |
| インストール済み全体への lint | 終了コード 1、17 エラー・39 警告。上記の機械的な誤認を含む別スコープの結果として明示 |
| `git diff --check` | 終了コード 0 |
