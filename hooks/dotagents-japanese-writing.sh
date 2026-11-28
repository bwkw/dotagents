#!/usr/bin/env bash
# 推敲スキルを導入した人にだけ、セッションの最初に使い方を渡す。
if [[ ! -r "$HOME/.agents/skills/ja-writing-humanizer/SKILL.md" ]]; then
  echo '{}'
  exit 0
fi

policy='[dotagents] 人に届ける日本語（返信、進捗、質問、PR の説明、レビュー、ADR など）は、出す前に ja-writing-humanizer で推敲する。一度読んだ手順はその会話で使い続ける。依頼された言語・書式を優先し、見出しと順序、判断とその理由、条件・数値・未確認事項を保つ。コード・ログ・引用・URL は原文のまま扱う。'
if [[ "${1:-}" == cursor ]]; then
  printf '{"additional_context":"%s"}\n' "$policy"
else
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$policy"
fi
