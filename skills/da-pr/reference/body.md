# 対象 PR を固定して説明を作る

## 依頼された差分を読む

URL があればそれを使う。現在のブランチなら `gh pr view --json url,title`、番号なら対象リポジトリを指定して `gh pr view <番号> --repo <所有者名/リポジトリ名> --json url,title` で URL を確定する。複数の候補が残る場合は対象を尋ねる。

```bash
gh pr view "$PR_URL" --json url,number,title,body,baseRefName,baseRefOid,headRefName,headRefOid,files,commits
gh pr diff "$PR_URL"
```

積み PR もその PR の差分を使う。ローカルで再現する時は取得した base・head の SHA で `git diff BASE...HEAD` を使う。フォークを含め、ソースのリンクは変更が存在するリポジトリの head SHA に固定する。別リポジトリの issue や PR は完全な URL か `owner/repo#番号` で示す。

リポジトリの PR テンプレ・言語・チケット規約と、既存本文にある担当者の判断や手動確認を引き継ぐ。言語が分からなければ、対象リポジトリのマージ済み PR を確かめる。なお判断できない時は聞く。

```bash
gh pr list --repo "$REPO" --state merged --limit 5 --json title,body
```

## 読み手が判断できる長さにする

`${CLAUDE_SKILL_DIR}/reference/pr-template.md` の短い例と構造が変わる例から、今回の変更に合う形を選ぶ。タイトルはリポジトリの一覧で意味が通る動詞を使う。本文の先頭で結論を伝え、確認が必要な条件だけを続ける。

日本語の下書きに直訳調の表現や重複が残るときは、導入済みなら `ja-writing-humanizer` で推敲する。元の本文と照合し、動作条件・数値・未確認事項・引用・リンクを保つ。

## 図で順序や境界が伝わる場合

読み手が確かめたい問いを一つに絞る。「どこで保存してから応答するか」なら呼び出し順、「誰が再試行するか」なら担当と失敗経路を示す。変わった経路を区別し、各矢印・分岐を該当版の実装と照合する。本文には一図だけを置く。

内部の `x-present` に問い・対象 head・経路の根拠を渡し、読み手が本文で見られる PNG と代替テキストを用意する。リポジトリ内の画像は、画像が存在する head のファイルを指す URL を使う。共有可能な画像がなければ、ローカルのプレビューと、単独でも判断できる本文を返す。追加の公開は指定された宛先だけに行う。

## 下書きと反映

下書き依頼は対象 URL と文面を返して完了する。更新の明示指示がある時だけ、直前の head・本文・タイトルを読み直す。新しい編集を引き継ぎ、承認済みの文面に変更が必要なら新しい案を示す。

本文だけの更新ではリポジトリ外の一時ファイルを使う。

```bash
gh pr edit "$PR_URL" --body-file "$TMPFILE"
gh pr view "$PR_URL" --json url,title,body
```

タイトルだけなら `--title "$TITLE"`、両方なら両フラグを使う。再取得した値を突き合わせ、反映した項目と URL を返す。
