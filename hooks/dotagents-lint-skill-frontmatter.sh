#!/usr/bin/env bash
# preToolUse hook。壊れた SKILL.md の frontmatter を書き込み前に捕まえる。
#
# `description` の無いスキルはメニューには出るが、自動では選ばれず、理由も出ない。
# `disable-model-invocation` を付けたスキルは、他のスキルから黙って呼べなくなる。
#
# 3 つのエージェントで動く。返答の形が違う:
#
#   Claude Code  {"hookSpecificOutput": {"hookEventName": "PreToolUse",
#                                        "permissionDecision": "deny"|"allow", ...}}
#   Codex        deny は Claude Code と同じ。警告は additionalContext（reason 付きの allow は受け付けない）
#   Cursor       {"permission": "deny"|"allow", "user_message": ..., "agent_message": ...}
#
# 見分けは `hook_event_name`（Cursor は送らない）と `turn_id`（Codex だけが送る）で行う。

set -uo pipefail

read -r -d '' LINTER <<'NODE' || true
let raw = "";
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  let ev;
  try { ev = JSON.parse(raw); } catch { return process.stdout.write("{}"); }

  const cursor = !("hook_event_name" in ev);
  const codex = "turn_id" in ev;

  const emit = (o) => process.stdout.write(JSON.stringify(o));
  const allow = () => emit({});
  const decide = (decision, reason) =>
    emit(codex && decision === "allow"
      ? { hookSpecificOutput: { hookEventName: "PreToolUse", additionalContext: `[dotagents] ${reason}` } }
      : cursor
      ? { permission: decision, user_message: `[dotagents] SKILL.md ${decision}`,
          agent_message: `[dotagents] ${reason}` }
      : { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: decision,
                                permissionDecisionReason: `[dotagents] ${reason}` } });
  const deny = (r) => decide("deny", r);
  // 許可しつつ一言添える。`ask` は人を待つので、無人実行が権限プロンプトで止まる。
  // このフックは検査だけで、ターンを止めてよいのは Stop ゲートだけ。本当に壊れたものは下で deny する。
  const warn = (r) => decide("allow", r);

  let input = ev.tool_input || {};

  // Codex は編集を apply_patch で送り、パスと中身はパッチ本文（tool_input.command）の中にある。
  // 最初の SKILL.md の節の足された行を中身とみなす。Add File なら全体、Update File なら断片で、Edit と同じ扱いになる。
  // ponytail: 1 つのパッチで SKILL.md を複数書き換えると 2 つ目以降は見ない。問題になったら節ごとに回す。
  const patch = String(input.command ?? "").match(/^\*\*\* (?:Add|Update) File: (.*\/SKILL\.md)\n([\s\S]*?)(?=^\*\*\* )/m);
  if (patch) {
    input = { file_path: patch[1], content: patch[2].split("\n").filter((l) => l.startsWith("+")).map((l) => l.slice(1)).join("\n") };
  }

  // ツール名はエージェントとバージョンで違うので、ペイロードの形で判定する:
  // SKILL.md へのパスらしいフィールドと、その中身らしいフィールド。
  const path = input.file_path ?? input.path ?? input.filePath ?? input.target_file ?? "";
  if (!/(^|\/)SKILL\.md$/.test(String(path))) return allow();

  // Write はファイル全体を運ぶ。Edit は断片なので、frontmatter を含む断片の時だけ判定できる。
  const content = String(
    input.content ?? input.new_string ?? input.newString ?? input.contents ??
    (Array.isArray(input.edits) ? input.edits.map((e) => e.new_string ?? "").join("\n") : ""),
  );

  // --- 本文の検査（frontmatter の検査より前） ---------------------------------
  // 以降の検査は frontmatter しか読まず、それを含まない断片では早期に返る。本文はエージェントが従う指示で、
  // 1 文の追加で振る舞いが変わるのに、その意図はリンターにもテストにも見えない。その穴をここで塞ぐ。
  // Edit の断片は新しく足された文そのものなので、基準なしで読む価値がある。
  //
  // scripts/verify-skills.sh の一覧と同一に保つ（2 つのマーカーコメントを比較している）。
  // dotagents:sensitive-body-patterns (cat|read|open|curl|wget|send|post|upload|include|echo)[^.]{0,40}(~/\.aws|~/\.ssh|\.env\b|id_rsa|\.netrc|credentials|keychain)|(~/\.aws|~/\.ssh|\.env\b|id_rsa|\.netrc|credentials|keychain)[^.]{0,40}(を読|を送|に送|include|report)|\|\s*(ba)?sh\b|base64\s+-d|nc\s+-|webhook\.site|pastebin
  const SENSITIVE = /(cat|read|open|curl|wget|send|post|upload|include|echo)[^.]{0,40}(~\/\.aws|~\/\.ssh|\.env\b|id_rsa|\.netrc|credentials|keychain)|(~\/\.aws|~\/\.ssh|\.env\b|id_rsa|\.netrc|credentials|keychain)[^.]{0,40}(を読|を送|に送|include|report)|\|\s*(ba)?sh\b|base64\s+-d|nc\s+-|webhook\.site|pastebin/i;
  for (const line of content.split("\n")) {
    // 抜け道には理由の記載を求める。理由なしの「許可」は許可リストが規則になる入口。
    if (/dotagents:allow-sensitive/.test(line)) continue;
    if (SENSITIVE.test(line)) {
      // deny ではなく警告。このフックはどこの SKILL.md にも効き、デプロイするスキルが .env を読むのは正当でありうる。
      // 閉じる側のゲートは、このリポジトリ自身のスキルに走る scripts/verify-skills.sh。
      return warn(
        "SKILL.md の本文が認証情報の置き場所か、シェルへのパイプの形を含む: " +
        `"${line.trim().slice(0, 120)}"。スキル本文はエージェントが従う指示で、意図はリンターに見えない。` +
        "ここにある理由をはっきり書くか、削除する。意図的なら、その行に " +
        "'dotagents:allow-sensitive: <理由>' を足す。",
      );
    }
  }

  if (!content.trimStart().startsWith("---")) return allow();

  const m = content.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!m) return deny("SKILL.md が '---' で始まるが、frontmatter のブロックが閉じていない。");

  const fm = m[1];
  const key = (k) => {
    const hit = fm.match(new RegExp(`^${k}\\s*:\\s*(.*)$`, "m"));
    return hit ? hit[1].trim() : null;
  };

  if (!key("name")) return deny("SKILL.md の frontmatter に 'name' が無い。");

  const desc = key("description");
  if (!desc) {
    return deny(
      "SKILL.md の frontmatter に 'description' が無い。これが無いとスキルは自動で選ばれず、" +
      "インストール済みに見えたままメニューに残り、発火しない。",
    );
  }

  // `disable-model-invocation` は人が打つワークフローには公式に正しい書き方で、説明の予算も食わない。
  // 誤りになるのは名前で呼ばれるスキルだけ。プログラムからの Skill 呼び出しとサブエージェントの事前読み込みも黙って塞ぐため。
  if (/^disable-model-invocation\s*:\s*(true|yes|on|1)\s*$/m.test(fm)) {
    const name = key("name") ?? String(path).replace(/.*\/([^/]+)\/SKILL\.md$/, "$1");

    // データとして宣言し、一覧の置き場をファイルごとに 1 か所にする。scripts/verify-skills.sh がこの 2 行を読み、
    // 自分の写しと一致するか検査する。マーカーコメントはそのために要る。
    const DMI_GATE = ["da-verify"];                                                  // dotagents:dmi-gate
    const DMI_DISPATCH = ["x-review-backend", "x-review-frontend", "x-review-infra"]; // dotagents:dmi-dispatch

    // `gate.sh arm` を実行するのは /da-verify だけ。自動呼び出しが無いと Stop ゲートが arm されず、毎ターン素通りする。
    if (DMI_GATE.includes(name)) {
      return deny(
        "'verify' に 'disable-model-invocation' を付けてはならない。'gate.sh arm' を実行するのはこれだけで、" +
        "自動呼び出しを止めると Stop ゲートが arm されず毎ターン素通りする。ガードレールが" +
        "何も報告せずに開いたままになる。docs/decisions.md を参照。",
      );
    }

    // da-review-all がサブエージェント経由で名前で呼ぶ。
    if (DMI_DISPATCH.includes(name)) {
      return deny(
        `'${name}' は da-review-all が名前で呼ぶ先で、` +
        "'disable-model-invocation' はプログラムからの Skill 呼び出しとサブエージェントの事前読み込みも塞ぐ。" +
        "付けると da-review-all はその層をレビュー済みと報告しつつ、何もレビューしない。" +
        "エラーも出ない。docs/decisions.md を参照。",
      );
    }

    // それ以外は付けてよい。後で別のスキルから呼びたくなるスキルに付けがちなので、代償を警告する。
    return warn(
      `'${name}' は人が打つ専用になる: 説明文は Claude のコンテキストから完全に外れ（予算は 0）、` +
      "自動では発火せず、他のスキルやサブエージェントから名前で呼べなくなる。" +
      "副作用のあるワークフローを常に自分で打つなら正しい。" +
      "何かが名前で呼んでいるなら誤り。",
    );
  }

  // いつ使うかが書かれていない説明文は、依頼と照合できない。
  // dotagents:when-clause-tokens use (this|it|when)|when |after |before |時|する場合
  // scripts/verify-skills.sh の一覧と同一に保つ（verify-skills.sh 自身が検査する）。
  // 食い違うと、リンターを通った日本語の説明文がこのフックの権限プロンプトで止まる。
  if (!/use (this|it|when)|when |after |before |時|する場合/i.test(desc)) {
    return warn(
      "説明文に何をするかはあるが、いつ使うかが無いので、自動呼び出しが当てにならない。" +
      "発火させたい状況を示す句（「〜する時に使う」）を足す。" +
      "名前でだけ呼ぶつもりなら不要。",
    );
  }

  allow();
});
NODE

# 素の stdin ではなく明示的な記述子から読む。fd 0 が閉じていると、bash は次に作るパイプに fd 0 を渡し、
# 読み手が自分の出力パイプで固まる。ハングしうるフックは無人実行を止めうる。
# サブシェルで試すのは、コマンド無しの `exec` とリダイレクトがシェル全体に永続して、stderr まで黙らせるため。
if ( exec 3<&0 ) 2>/dev/null; then exec 3<&0; else exec 3</dev/null; fi

# クラッシュしたフックが通常の編集を塞いではならないので、想定外はすべて開く側に落とす。
# 閉じる側に落ちなければならないゲートは dotagents-verify-gate.sh。
node -e "$LINTER" <&3 2>/dev/null || true
exec 3<&-
exit 0
