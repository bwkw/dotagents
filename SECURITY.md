# Security

## 何を配っているのかの正直な説明

`scripts/setup.sh install` は、あなたのマシンに2つの hook を**コピー**し、`~/.claude/settings.json` に配線します。

- `dotagents-lint-skill-frontmatter.sh` —— **すべての `Write` / `Edit` で実行されます**
- `dotagents-verify-gate.sh` —— **すべてのターン終了時に実行されます**（armed のときだけ働きますが、呼び出しは毎回)

スキルは symlink なので、**この checkout の中身がそのまま、あなたのエージェントが従う命令です。** `git pull` した内容は、次にエージェントがスキルを読んだ瞬間から有効になります。インストール操作は挟まりません。

つまりこのリポジトリは、テキストの詰め合わせではなく**あなたのマシンで自動実行されるコードの供給元**です。それを前提に扱ってください。

## 入れる人へ

- **`./scripts/setup.sh install --dry-run` で何が起きるか先に見てください。** 書き込む先と鍵を全部列挙します。
- **`install` は `skillOverrides` と verbose なテレメトリも入れます。** bundled/plugin スキルを触らせたくないマシンでは `install --no-opinions`。何が「意見」に当たるかは `templates/claude.settings.snippet.json` の `$opinionKeys` が唯一の定義です。
- **`scripts/check.sh` を通してから使ってください。** hook の挙動テストが全部ここに入っています。

## 脅威モデル —— このリポジトリ固有のもの

**スキルはコードではなく命令なので、通常のレビューをすり抜けます。** `SKILL.md` の本文に散文で一行足すだけで、エージェントの振る舞いは変わります。linter も型検査も CI も何も言いません。そして実行されるのは、あなたの業務リポジトリの中です。

したがって、この2つは通常のコードより厳しく見る必要があります。

1. **`hooks/` の変更** —— 全ツール呼び出しで走るコード
2. **`skills/**/SKILL.md` と `skills/_shared/` の本文の変更** —— エージェントが従う命令

PR テンプレートがこの2点を明示的に聞くのは、そのためです。

## 本文に対して、いま何が働いているか

**内容の善悪は判定しません。形だけを見ます。** 2つの形が、スキル本文と `reference/` の全行で禁止されています —— 資格情報の置き場（`~/.aws`・`~/.ssh`・`.env`・`id_rsa`・`.netrc`・keychain）が read/send 系の動詞と**同じ行に**現れること、そして pipe-to-shell・`base64 -d`・paste サイトの形。

| どこ | いつ | 失敗の向き |
|---|---|---|
| `hooks/dotagents-lint-skill-frontmatter.sh` | `SKILL.md` を書いた瞬間（Edit の断片も） | **警告のみ**（fail open）。どこの `SKILL.md` にも発火するので、本当に deploy するスキルが `.env` を読むのは正当でありうる |
| `scripts/verify-skills.sh` → `check.sh` → CI | commit / PR | **エラー**（fail closed）。このリポジトリ自身のスキルに対してだけ |

正当な理由があるときは、その行に `dotagents:allow-sensitive: <理由>` を書いてください。理由なしの「許可」は受け付けません。

`setup.sh status` は、スキル本文が**最後のコミットと違うか**も報告します。skills は symlink なので、未コミットの編集は既に有効です。

## まだ塞げていないもの

- **`Bash` 経由の書き込み**（`sed -i`、`cat > SKILL.md`）は `PreToolUse` の matcher に当たらないので、書き込み時点では検出されません。**書き込み時のゲートは原理的に不完全**で、だから load-bearing な層は commit / CI 側に置いてあります
- **他人のスキル**（`npx skills` などで入れたもの）の本文は監視していません。TOFU ハッシュには受け入れ経路が必要で、それが無いと update のたびに解決できない警告が出て、警告を無視する訓練になります。判断の記録は [docs/decisions.md](docs/decisions.md) §19
- **パターンは形しか見ません。** 巧妙に言い換えられた指示は通ります。最終審は CI で、その限界も §19 に書いてあります

## 報告

脆弱性を見つけた場合は、公開 issue ではなく [GitHub の Security Advisory](https://github.com/bwkw/dotagents/security/advisories/new) で報告してください。これは個人のリポジトリなので SLA はありません。返答が遅れることは想定してください。

**秘密情報を含む報告はしないでください。** このリポジトリはあなたのプロファイル（`profiles/*.json`）を追跡しません。それらは `.gitignore` の allowlist で除外されていて、実リポジトリ名や社内の規則を含みうるからです。
