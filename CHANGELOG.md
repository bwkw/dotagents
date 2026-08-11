# Changelog

このリポジトリは**自動実行される hook を配っている**ので、利用者が固定できる点が必要です。タグを打つのはそのためで、変更の宣伝のためではありません。

`hooks/`・`skills/**/SKILL.md`・`templates/` の変更は、入れた人のマシンで走るもの・エージェントが従う命令・他人の `settings.json` に書かれる鍵のいずれかを変えます。**この3つに触る変更は、各リリースで最初に書きます。**

形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に寄せ、版は [SemVer](https://semver.org/lang/ja/) に寄せます。ここでの破壊的変更とは「**インストール済みの環境で、更新後に挙動が変わること**」を指します。

## [Unreleased]

### 自動実行されるものの変更

- **`install` の既定が変わりました。** `env.OTEL_LOG_TOOL_DETAILS` と bundled / plugin スキル8件の
  `skillOverrides` は、`install --with-opinions` を付けたときだけ入ります。既定は仕組み（hook の配線）
  のみ。**既に書かれている値は消えません**（merge は追加と更新だけで、削除はしない）ので、更新して
  そのまま `install` しても環境は退化しませんが、新しいマシンでは入らなくなります
- **レポートの言語が「ユーザが書いている言語」になりました。** 以前は日本語固定。日本語で使っている
  限り挙動は変わりません
- **profile の照合が owner を問わなくなりました。** `match.remote` は文字列とリストの両方を受けます。
  このリポジトリ自身の profile は `/dotagents` に —— fork ではどの profile にも一致せず、ゲートが
  無言で pass していたため

### 追加

- `profiles/_example.node-pnpm.json` —— コピーして使う worked example。`_` 接頭辞の profile は
  hook と `gate.sh` の両方が読み飛ばすので、例が実リポジトリを gate することは原理的にありません
- `setup.sh status` に `profiles` セクション。0件なら「ゲートは全リポジトリで無言に pass する」と警告
- `SECURITY.md`・`CONTRIBUTING.md`・PR テンプレート・`CODEOWNERS`・issue テンプレート
- `docs/portability.md` —— 1台のマシンへの依存の棚卸し。再現手順つき
- CI に `node-floor` ジョブ。README が1年間主張していた node 18 を、初めて実際に走らせます
- Dependabot（github-actions のみ。理由は `.github/dependabot.yml`）

### 修正

- 私物の絶対パスと社内リポジトリ名をコメントから除去（観測の記録は残しました）

### 判明したが直していないもの

- **`CLAUDE_CONFIG_DIR` は公式ドキュメントに存在しません**（環境変数の一覧を通しで確認）。実在するなら
  install は agent が読まない場所に書き、`status` は自分の書き込みを検査するので緑のまま hook が不在に
  なります。`docs/harness-facts.md` の未確認リストに記録
- 残りは `docs/portability.md` の「直していないもの」に全部あります

## それ以前

**タグは1つもありません。** 2026-07-28 の最初のコミットからこの文書を書くまで、固定できる点は存在せず、
`main` を追いかけることだけが利用方法でした。自動実行される hook を配る側として筋が悪い、というのが
この文書が生まれた理由です。

過去に遡ってタグを打つことはしません。どのコミットが「動く版」だったかを事後に判定する根拠が無く、
根拠のない版番号は、無いことより悪いからです。経緯は `docs/decisions.md` と git 履歴にあります。

最初のタグは Unreleased がマージされた時点で打ちます。それまでの版は**この作者のマシンで動くことだけが
確認されていた**もので、その前提を外したのが上の内容です。
