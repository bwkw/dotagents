#!/usr/bin/env bash
# preToolUse hook. Catches broken SKILL.md frontmatter before it lands.
#
# A skill with a missing `description` still appears in the menu; it just never gets chosen
# automatically, and nothing says why. A skill with `disable-model-invocation` silently stops
# being callable from other skills. Both are cheap to catch here and expensive to notice later.
#
# Runs on both agents. They disagree on the reply format:
#
#   Claude Code  {"hookSpecificOutput": {"hookEventName": "PreToolUse",
#                                        "permissionDecision": "deny"|"ask", ...}}
#   Cursor       {"permission": "deny"|"ask", "user_message": ..., "agent_message": ...}
#
# Detected by `hook_event_name`, which only Claude Code sends.

set -uo pipefail

read -r -d '' LINTER <<'NODE' || true
let raw = "";
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  let ev;
  try { ev = JSON.parse(raw); } catch { return process.stdout.write("{}"); }

  const cursor = !("hook_event_name" in ev);

  const emit = (o) => process.stdout.write(JSON.stringify(o));
  const allow = () => emit({});
  const decide = (decision, reason) =>
    emit(cursor
      ? { permission: decision, user_message: `[dotagents] SKILL.md ${decision}`,
          agent_message: `[dotagents] ${reason}` }
      : { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: decision,
                                permissionDecisionReason: `[dotagents] ${reason}` } });
  const deny = (r) => decide("deny", r);
  const ask = (r) => decide("ask", r);

  const input = ev.tool_input || {};

  // Tool names differ between agents and across versions, so key off the payload shape instead:
  // any field that looks like a path to a SKILL.md, and any field that looks like its content.
  const path = input.file_path ?? input.path ?? input.filePath ?? input.target_file ?? "";
  if (!/(^|\/)SKILL\.md$/.test(String(path))) return allow();

  // Write carries the whole file. Edit carries a fragment, so we can only judge it when the
  // fragment itself contains the frontmatter block.
  const content = String(
    input.content ?? input.new_string ?? input.newString ?? input.contents ??
    (Array.isArray(input.edits) ? input.edits.map((e) => e.new_string ?? "").join("\n") : ""),
  );
  if (!content.trimStart().startsWith("---")) return allow();

  const m = content.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!m) return deny("SKILL.md starts with '---' but the frontmatter block is never closed.");

  const fm = m[1];
  const key = (k) => {
    const hit = fm.match(new RegExp(`^${k}\\s*:\\s*(.*)$`, "m"));
    return hit ? hit[1].trim() : null;
  };

  if (!key("name")) return deny("SKILL.md frontmatter is missing 'name'.");

  const desc = key("description");
  if (!desc) {
    return deny(
      "SKILL.md frontmatter is missing 'description'. Without it the skill is never selected " +
      "automatically -- it will sit in the menu looking installed and never fire.",
    );
  }

  if (/^disable-model-invocation\s*:\s*(true|yes|on|1)\s*$/m.test(fm)) {
    return deny(
      "Do not set 'disable-model-invocation'. It blocks more than model auto-invocation: " +
      "programmatic Skill calls, subagent preloading, and scheduled-task triggering all stop " +
      "working. Any skill that dispatches to this one breaks with no error. See docs/adr/0003.",
    );
  }

  // A description with no sense of *when* to use the skill cannot be matched against a request.
  if (!/\buse (this|it|when)\b|\bwhen \b|\bafter \b|\bbefore \b/i.test(desc)) {
    return ask(
      "This description says what the skill does but not when to use it, so auto-invocation " +
      "will be unreliable. Add a clause naming the situations that should trigger it " +
      '("use when ..."), or continue if it is meant to be invoked only by name.',
    );
  }

  allow();
});
NODE

# A hook that crashes must not block ordinary edits, so anything unexpected falls through open.
# This one only inspects; the gate that must fail closed is dotagents-verify-gate.sh.
node -e "$LINTER" 2>/dev/null || true
exit 0
