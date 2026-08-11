# 1台のマシンの持ち物をやめる

このリポジトリは公開されていますが、**実際に動くことが確認されていたのは1台だけ**でした。この文書はその棚卸しです。何が環境に食い込んでいたか、何を直したか、何を直していないか、そして**要らないものは何だったか**を、全部ここに書きます。

前提の変更はこう言えます。**「作者のマシンで動く」から「clone した人のマシンで動く」へ。** この差は機能の差ではなく、既定値と同意の差でした。

---

## どうやって洗い出したか（再現手順）

推測ではなく機械的に探しました。同じことをすれば同じリストが出ます。

```bash
# 1. 追跡されているツリーの中の絶対パス・個人・所属
git grep -I -n -E '/Users/|/home/[a-z]|shota|dresscode|standandforce|DC-[0-9]{3,}' HEAD -- .

# 2. 全履歴の秘密と社内識別子（gitignore は「今」しか守らない）
git rev-list --all | while read -r c; do
  git grep -I -l -E 'standandforce|AKIA[0-9A-Z]{16}|sk-ant-|ghp_[A-Za-z0-9]{20,}|BEGIN [A-Z ]*PRIVATE KEY' "$c" --
done | sort -u

# 3. プラットフォーム依存のコマンド綴り
for p in 'shasum' 'sha256sum' 'readlink -f' 'sed -i' 'stat -' 'grep -P' 'realpath' 'mktemp -t'; do
  printf '%-14s %s\n' "$p" "$(git grep -I -c -F -- "$p" HEAD -- | tr '\n' ' ')"
done

# 4. インストーラが他人の設定に書く鍵
node scripts/lib/merge-settings.mjs --print-keys templates/claude.settings.snippet.json
```

**2 は空でした。** 秘密も社内識別子も全履歴に一度も入っていません。**3 もほぼ空でした** —— BSD と GNU の差は CI が macOS と ubuntu の両方を回しているので既に潰れています。環境依存は「移植性の低いコマンド」ではなく、**既定値と、同意していない設定と、固有名**に集中していました。

---

## 直したもの

### 1. profile が owner に固定されていて、fork では無音でゲートが消えていた（P1）

`profiles/dotagents.json` は `match.remote: "bwkw/dotagents"`。照合は `remote.includes(...)` の部分文字列一致なので、`alice/dotagents` に fork すると**どの profile にも一致せず、ゲートは "no profile matches" で pass** します。ゲートを配っているリポジトリ自身が、fork では無防備になる。

`match.remote` を**文字列またはリスト**にし、このリポジトリの profile は `/dotagents` に変えました。https 形式（`https://host/owner/dotagents.git`）と ssh 形式（`host:owner/dotagents`）の両方に一致し、owner を問いません。

代償は明示的に受け入れています: 名前が `dotagents` で始まる無関係なリポジトリも一致し、そこではコマンドが存在しないので**うるさく失敗**します。**うるさく間違う方が、黙って開くよりよい** —— ゲート全体がその順序で作られています。

照合器は hook と `gate.sh` の2箇所にあるので、両方を同じ形に変えました。テストは3本追加（owner なしで一致する / リストはどれか1つで一致する / リストが何にも一致しないときは profile なしと判定する）。3本目が要るのは、配列をうっかり文字列に連結すると**あらゆるリストがあらゆる remote に一致**してしまうからです。厳しくしたつもりで緩くなる形。

### 2. インストーラが、他人のスキルを黙って抑制していた（P1）

`templates/claude.settings.snippet.json` には2種類の鍵が同居していました。**仕組み**（`hooks` —— これが無ければ何も動かない）と、**意見**（`env.OTEL_LOG_TOOL_DETAILS` と、bundled/plugin スキル8件を `name-only` / `off` にする `skillOverrides`）。`setup.sh install` は両方を無条件にマージしていました。

検証ゲートを入れたことは、**docx や pdf を黙って黙らせることへの同意ではありません。** README に書いてあることは同意ではない。

`$opinionKeys` を template 自身に宣言し、`install` は既定で仕組みだけを入れ、`install --with-opinions` で意見も入れるようにしました。リストの home は template 1箇所です（`setup.sh` に写しを置くと、鍵を足したとき忘れる場所が2つになる）。

実装は「2回マージ」ではなく「フィルタして1回マージ」です。`merge-settings.mjs` は `manifest.settingsHooks` を**渡された snippet の内容で置き換える**ので、hooks を持たない snippet で2回目を回すと**hook の記録が消え、uninstall が hook を戻せなくなる**。順序依存の正しさに賭けるより、経路を1本にしました。

テストは、既定インストールが意見の鍵を1つも書かないこと**と**同じ息で Stop gate は配線されることを両方見ます。片方だけだと、仕組みごと入れ忘れた install も「意見が無い」で緑になる。

### 3. 例になる profile が1つも無く、新しいマシンではゲートが空だった（P2）

ゲートは profile が一致しないと pass します（推測しない設計として正しい）。しかし配布物には**このリポジトリ自身の profile しか無い**ので、clone した人のゲートはどのリポジトリでも空です。しかも `setup.sh status` は profile を一言も報告しないので、**全部緑のまま何も検査していない**状態になれました。

- `profiles/_example.node-pnpm.json` を追加。`_` 接頭辞は飾りではなく、hook と `gate.sh` の両方が `_` で始まる profile を読み飛ばすので、**例が誤って実リポジトリを gate することが原理的にない**。だから安全に配れます。
- `.gitignore` の allowlist に `!profiles/_example.*.json` を追加（denylist ではなく allowlist なのは元の設計どおり）。
- `status` に `profiles` セクションを追加。0件なら **「ゲートは全リポジトリで無言に pass する」と警告**します。

### 4. レポートの言語が日本語で固定されていた（P2）

`_shared/report-format.md` と4つの SKILL.md が「**Write the report in Japanese**」と書いていました。作者のマシンでは正しく、それ以外では誤りです。英語話者が入れると、**自分に読めない言語のレポート**が、自分に読める言語で書かれた指示から出てくる。

「ユーザが書いている言語で書く。判別できないときは日本語」に変更しました。日本語話者の挙動は変わりません。

### 5. 私物の痕跡（P2）

- `/Users/shota/.cursor` → `$HOME/.cursor`（hook のコメント1箇所）
- 社内リポジトリ名 `dresscode-backend` / `dresscode-frontend` の参照6箇所（hook 2 / テスト 4）を、一般的な記述に。**観測の記録は残しました** —— あれは実際に踏んだ事実で、消すと理由が消えます。名前だけを外しました。

なお `profiles/dresscode-*.json` 本体は最初から一度もコミットされていません（履歴走査で `standandforce` が0件なので断定できます）。

---

## 直していないもの

やらなかったことを書いておかないと、次に読む人が「見た上で不要と判断した」のか「見落とした」のかを区別できません。

| # | 足りないもの | 状態 |
|---|---|---|
| 1 | **スキル本文の完全性ゲート** | **完了。** 内容の善悪ではなく形を検査し、書き込み時は警告・commit/CI ではエラー。3つの分岐の答えと、実装前の測定で設計が単純になった経緯は [判断の記録 §19](decisions.md)。他人のスキルの監視だけは、受け入れ経路を設計してから入れます |
| 2 | **`main` のブランチ保護** | **完了。** ruleset で PR 必須・CI **5本**必須・force push 禁止・削除禁止（下記「GitHub 側の状態」） |
| 3 | **`CLAUDE_CONFIG_DIR` 対応** | **対応しないと決めた。** 公式ドキュメントの環境変数一覧を通しで確認し、**存在しません**（2026-08-11）。確証なしに分岐を足すのは、このリポジトリが最も嫌う「推測を仕様として書く」行為。`docs/harness-facts.md` の未確認リストに記録。**もし実在するなら**、install は agent が読まない場所に書き、`status` は自分の書き込みを見るので緑になる —— 典型的な silent pass |
| 4 | **`README.en.md` が 57 行、`README.md` が 385 行** | **未着手。** 英語話者は内容の15%しか読めない。翻訳は独立した作業量で、他の変更に混ぜると差分がレビュー不能になる |
| 5 | **node の下限 18 が未検証** | **完了。** CI に `node-floor` ジョブを追加し、18 で `check.sh` 全体を回します。1年間主張していた下限を初めて実行しました。matrix の次元にせず別ジョブにしたのは、ジョブ名が ruleset の必須コンテキストで、改名すると**黙って必須でなくなる**から |
| 6 | **Windows/WSL の明記なし** | **明記した（未確認と書いた）。** bash 前提なので WSL のみのはず、と README に書いています。「はず」を「対応」と書かないのがここの作法 |
| 7 | **上流スキルの存在確認が無い** | **完了。** `setup.sh status` が、README の導線が使う上流スキル10本の不在を報告します。インストールはしません（`npx skills add` は利用者の判断）。リストは `setup.sh` に1箇所で宣言し、`verify-skills.sh` が **README に記載があること**を照合 —— 上流の改名で、誰も文書化していない名前を探し続けるのを防ぐため |
| 8 | **`docs/mechanisms.md` の機種依存の記述** | **完了。** 「このマシン固有の危険」→「あなたのマシンで確認すべき危険」に。数字は例として残し、`which -a claude` で自分のマシンを確認する手順を追加 |
| 9 | **リリースとバージョニングが無い** | **半分完了。** `CHANGELOG.md` を追加。**タグはまだありません** —— 過去に遡って打つことはしません（どのコミットが「動く版」だったかを事後に判定する根拠が無く、根拠のない版番号は無いことより悪い）。最初のタグはこの一連の変更がマージされた時点で打ちます |
| 10 | **CONTRIBUTING.md が無い** | **完了。** 失敗の向き（fail open / fail closed）をどちらを選んだか書くこと、`check.sh` の出力を貼ること、固有名を入れないこと |

### GitHub 側の状態

コードだけ移植可能にしても、**リポジトリの設定が作者のワークフローに合わせたままなら、公開物としては未完成**です。以下は適用済みです。

| 設定 | 状態 | なぜ |
|---|---|---|
| `main` の ruleset | **有効**（bypass なし） | PR 必須・必須ステータスチェック4本・force push 禁止・削除禁止。hook は全ツール呼び出しで自動実行されるコードなので、赤いものが `main` に載ることの危険が通常のリポジトリより大きい |
| Secret scanning + push protection | 有効（元から） | |
| Dependabot alerts / security updates | **有効にした** | |
| Dependabot 設定 | **追加**（github-actions のみ） | ここに package manifest は無く、腐りうる依存は workflow の action だけ。`npx skills` は README で手動 pin —— 唯一マシン上で実行される外部コードなので |
| CODEOWNERS | **追加** | `hooks/` `skills/` `templates/` `setup.sh` を明示的に列挙。catch-all に混ぜない |
| issue テンプレート | **追加** | 脆弱性は公開 issue ではなく Security Advisory へ誘導 |

**bypass actor を置いていません。** つまり作者自身も `main` に直接 push できません。ソロのリポジトリとしては摩擦がありますが、**自動実行されるコードを配っている**なら正しい姿勢だと判断しました。摩擦が実害になったら、admin を bypass に足すのは1コマンドです（その判断も記録に残すこと）。

**適用できなかったものが2つあります。** `delete_branch_on_merge` と、secret scanning の拡張（non-provider patterns / validity checks）。手元のツール制約で弾かれたので、所有者が実行する必要があります。コマンドは PR 説明にあります。

---

## 要らなかったもの

「足りない」の裏側です。**環境依存は、機能の不足ではなく余りとして現れます。**

| 要らなかったもの | 何だったか | どうしたか |
|---|---|---|
| `env.OTEL_LOG_TOOL_DETAILS` と `skillOverrides` 8件の**無条件適用** | 作者のスキル選好。他人のマシンでは、頼まれていない変更 | 削除せず `--with-opinions` に移した。作者は今後フラグを付ける |
| `match.remote` の `bwkw/` | owner の固定。fork を無防備にしていた | `/dotagents` に |
| 社内リポジトリ名6箇所、`/Users/shota` 1箇所 | 観測の記録に混ざった固有名 | 固有名だけ外し、観測は残した |
| レポート言語の日本語固定（5箇所） | 作者の言語 | ユーザの言語に。判別できないときの既定は日本語のまま |
| `profiles/` に例が無いこと | 「自分は書けるから要らない」 | `_example.node-pnpm.json`（`_` 接頭辞で不活性） |

---

## 判断の記録

**削除ではなく同意の付け替えを選びました。** 意見の鍵は消せば移植性は上がりますが、作者の環境は退化し、`uninstall` が正確に戻す仕組みも無駄になります。opt-in はどちらも保ちます。

**observation は残し、固有名だけ外しました。** コメントの価値は「なぜこの形なのか」にあって、それは実際に踏んだ事実から来ています。`dresscode-backend.json` という名前は消せますが、「`cwd: v2` の profile が root 相対のパスを受け取って空虚に pass した」という事実は消してはいけない。

**署名（GPG / sigstore）は採りませんでした。** 不変条件4（hook は消えうるパスに依存してはならない）に反し、macOS の bash 3.2 で完結するという制約も壊れます。そして脅威モデルに対して過剰です —— 守りたいのは「気づかずに変わっていること」で、「誰が変えたか」の否認防止ではない。
