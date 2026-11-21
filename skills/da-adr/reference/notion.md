# Notion の ADR DB に書く

ユーザーが Notion の ADR を指定したとき（既存のページの URL か、Notion に書くという指示）に使う。プロファイルに `adr_system.notion` が無ければ止まり、置き場所を聞く。

## 本文の形とページの作り方を分ける

- **本文の形は `adr-shape.md` に従う。** リポジトリの Notion テンプレートの節（文脈、結論、代替案など）や、テンプレートの要約（画像生成のプロンプト）は使わない
- **ページの作り方は `adr_system.notion.page_rules` に従う。** 題の形、プロパティ（公開、作成日、Collaborator、タグ、採用状況）、テンプレートの当て方、公開の手順。タグは選択肢を挙げて開発者に選んでもらい、推測で付けない。公開は開発者が中身に OK を出してから
- プロパティ（採用状況のボタンなど）は本文ではないので、本文を置き換えても残る

## 本番の後に更新しない

Notion の ADR は本番に出た後に更新しない。だから「状態」と「実装との対応」は置かない。

- 扱わない範囲は `0. 前提` の「業務全体と今回の範囲」に置く
- 仕様（OpenSpec の change）と実装の PR は `関連ドキュメント` に置く
- 本番の結果、「STG は未確認」のような進み具合、照合した commit のように、後で嘘になる文を書かない。判断時点で未確認の前提は、`0. 前提` の「前提にした仮定と未確認事項」に置く

## 手順

1. **新規なら**、`page_rules` の手順で `template_id` のテンプレートからページを作る。テンプレートの適用は非同期なので、`notion-fetch` で本文が入ったことを確かめる。**既存なら**、`notion-fetch` で全文を読み、`SKILL.md` の Step 2（説明を整えるのか、判断を選び直すのか）に従う
2. 本文を `notion-update-page` の `replace_content` で `adr-shape.md` の構成に置き換える。見出しは `##`（節）と `###`（節の中）。却下した代替案の各案は `**案 N-a：〜**` の太字の段落にする
3. `/da-adr-figure` で図を書き出し、Notion に上げる
   - `notion-create-file-upload` でアップロード先を作り、返ってきた `upload_url` に、`upload_headers` を付けて `curl -F "file=@figure.png;type=image/png"` で送る
   - 「先に結論の要約」の先頭に `<image source="file-upload://<file_upload_id>" />` を置き、その後に判断と 1 対 1 の箇条を書く
   - 図を差し替えるときは、`notion-fetch` で見た画像の行（`notion-file-block://...`）をそのまま `old_str` にする。`file-upload://` の形では当たらない
4. `notion-fetch` で読み直し、構成と画像の位置を確かめる
