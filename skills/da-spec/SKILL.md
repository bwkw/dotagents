---
name: da-spec
description: 変更を、このリポジトリが実際に使っている形式でディスクに書く、または既存のものを更新する。実装前に spec・proposal・design・計画を記録する必要がある時に使う（openspec の change、spec delta、計画ファイル）。置き場所を選ばず、リポジトリの規約と書き方のルールから解決する。書くのは spec の成果物だけで、ソースは触らない。
argument-hint: "[変更の内容 | change-id | パス]（省略時は質問する）"
allowed-tools: Read, Grep, Glob, Write, Edit, Bash(git:*), Bash(gh:*), Bash(pnpm:*), Bash(npm:*), Bash(npx:*), Bash(yarn:*), Bash(make:*), Bash(bundle:*)
metadata:
  source: bwkw/dotagents
---

# /da-spec — 意図を、このリポジトリが置く場所に記録する

**このスキルが書くのは意図の成果物（spec、proposal、design、tasks、plan）だけ**。ソース・マイグレーション・スキーマ・設定は触らない。実装も始めない。

置き場所の規約は実行時に読まれる場所にしか効かない。事実はプロファイルの `spec_system` にあり、効かせる場所はこのファイルである。

## 実行条件

1 行でも満たさなければ即座に止まり、どの条件かを報告する。続けない。

| 条件 | 満たさない場合 |
|---|---|
| 作業ディレクトリが `origin` リモートを持つ git リポジトリ内にある | 止まってそう書く。置き場所を推測しない |
| **変更の内容が述べられている** | **止まって聞く**。推測した目的から書いた spec は別の変更の spec になり、しかも権威があるように読まれる |
| このリポジトリに合うプロファイルがある | Step 1 までに**限って**続け、欠けていることを報告して聞く。規約をでっち上げない |
| `spec_system.kind` が `none` | 止まる。このリポジトリは意図をどこにも記録していないと書き、どこに置くかを聞く。ディレクトリを作らない |

## ワークフロー上の位置

| 上流 | このスキル | 下流 |
|---|---|---|
| `/research`, `/grilling`, `/da-investigate` | `/da-spec` | **`/da-design-review`**、その後 `/executing-plans` |

## 読むファイル

### 常に読む

| ファイル | 理由 |
|---|---|
| `${CLAUDE_SKILL_DIR}/reference/spec-system.md` | 規約の解決の仕方、ツリーから決めない理由、validator の規則。`da-design-review` と共有しているので、成果物の置き場所について両者が食い違わない |
| 合致する `profiles/*.json` → `spec_system` | このリポジトリがどの規約をどこで使うか |
| `spec_system.rules` が指すファイル | **リポジトリ自身の書き方の規則**。省略不可。規則が書かれているのに汎用テンプレートで書くと、自分の validator に落ちる成果物になる |
| `${CLAUDE_SKILL_DIR}/reference/final-design.md` | **誰に向けて書くか**。理解が変わるたびに直した spec は放っておくと自分の経緯を抱え込み、後で読む新規参加者はその会話にいなかった |

### 条件つきで読む

| ファイル | 条件 |
|---|---|
| 更新する既存の change や計画 | Step 2 で見つかった時（たいてい見つかるはず） |
| `${CLAUDE_SKILL_DIR}/reference/openspec.md` | `kind` が `openspec` の時。ディレクトリの形、delta の見出し、`validate --strict` が実際に検査すること |
| `CLAUDE.md`, `AGENTS.md`, `.cursor/rules/*` | リポジトリにあり、rules ファイルがそれらに委ねている時 |

> 「念のため」全部を読むことは禁止。

---

## Step 1. 規約を解決する（選ばない）

`${CLAUDE_SKILL_DIR}/reference/spec-system.md` に従う。プロファイルから `spec_system` を解決し、それが指す rules ファイルを読む。プロファイルか `spec_system` が無ければ止まって聞く。**ディレクトリが見えることは、そこに書けと言われたことではない**。

## Step 2. 既存の change を探す（作る前に）

すでに change がある能力に 2 つ目を作ると、記録が 2 つに割れる。どちらの半分も単独では誤りでないので、誰も気づかない。

**タイトルではなく、能力と対象で探す**。

```bash
ls "$ROOT"/changes 2>/dev/null                       # openspec: change ids are slugs, read them all
rg -l "<the entity, table, endpoint, or capability>" "$ROOT" 
git log --oneline -20 -- "$ROOT"                     # what was last touched here, and by which branch
```

そのうえで決め、**どれを選んだかと理由を書く**。

| 見つかったもの | すること |
|---|---|
| この能力を扱う、まだアーカイブされていない change | **それを更新する**。兄弟を作らず、既存の delta に要件を足す |
| 隣接するが本当に別物の change | 新しい change。**境界を書く**（何が別の納品にしているか） |
| **デプロイ済みの** spec（`specs/<capability>/spec.md`）があり、開いた change は無い | 新しい change。delta はその spec に対する `## MODIFIED Requirements` で、`ADDED` ではない |
| 何も無い | 新しい change |

**曖昧なら聞く**。「同じ能力か」の判断は人によって違い、聞く手間は 1 通で、割れた記録は 1 か月誰も気づかない。

## Step 3. リポジトリの規則に沿って書く

`kind: openspec` → `${CLAUDE_SKILL_DIR}/reference/openspec.md` を読み、change ディレクトリを書く。

`kind: plans` → **`writing-plans` スキルを使い、そのとおりに従う**。ファイルはそのスキルの既定ではなく `spec_system.root` の場所に置く。**その指針をここで繰り返さない**。タスク分割・粒度・計画ヘッダーは upstream が保守しており、写すと 2 版がずれて、このリポジトリ側が古くなる。

どちらでも、このスキル固有の規則が 2 つある。

- **rules ファイルはどのテンプレートにも優先する**。`spec_system.rules` が見出し、規範語彙、修正した要件の全文再掲を求めるなら、それが基準。読みやすくても validator に落ちる汎用テンプレートは、成果物が無いより悪い。
- **確かめたことを書き、確かめていないことは印を付ける**。spec は後で確定した事実として読まれる。確かめていない前提は要件ではなく、明示した未決の問いとして入れる。

## Step 4. validator を実行し、出力を見せる

`${CLAUDE_SKILL_DIR}/reference/spec-system.md` に従う。**赤は未完了**。成果物を書いたと報告せず、直して再実行する。緑は形式が正しいという意味でしかない。そう明記し、設計の判断は `/da-design-review` に任せる。

> **強制力は frontmatter の許可リストにあり、以下の文章には無い**。拒否されたツール呼び出しはユーザーの前で大きく拒否されるが、文章はお願いにすぎない（スキルに書いた規則は保証ではなく依頼である）。
>
> よって、**リポジトリの validator が許可リストの範囲外なら、そう書いて止まる**。範囲内のインタプリタを経由させて動かさない。「ここでは validator を実行できなかった」と報告し、プロファイルか許可リストを意図して変えてもらう。
>
> 許可の範囲内では、**プロファイルの `validate` の argv だけを実行する**。先頭要素がシェル（`sh`, `bash`, `zsh`）の argv や `-c` を含む argv は拒否する。配列の形をしたコマンド文字列だからである。各要素を先にプロファイルの `forbidden` と照合する。validator が `pnpm` で始まるからといって `pnpm run <anything>` が範囲に入るわけではない。

## 根拠の扱い

- 直接確かめたことだけを報告する。場所は `path/to/file.md:L42` で示す。
- 根拠が無いときは「確認できなかった」と書く。推測しない。
- 事実と推論をはっきり分ける。
- 外部についての主張には URL を付ける。

## 出力

次の順で報告する。

1. **規約** —— どのプロファイルから解決したか。解決できなければ欠けているものと質問
2. **新規か更新か** —— パス。**更新なら既にあった内容**
3. **validator の出力** —— そのまま貼る。無ければそう書く
4. **未決のこと** —— 確かめられなかった前提を、spec の本文ではなく質問として

## 完了条件

- [ ] 規約はツリーの見た目ではなく**プロファイル**から来た
- [ ] 書く**前に** `spec_system.rules` を読み、成果物がそれに従っている
- [ ] Step 2 を実行した。既存の change を**能力で**探し、更新か新規かを理由つきで書いた
- [ ] validator を実行し、出力を**貼った**か、実行していないことを書いた
- [ ] spec のルート外には何も書いておらず、実装も始めていない

## 次に

書いたものに `/da-design-review` を掛ける。同じ `spec_system` を読み、計画のパスを推測せずに change ディレクトリをレビューする。
