#!/usr/bin/env bash
# Lint every skill in this repository.
#
#   verify-skills.sh [path ...]     defaults to <repo>/skills
#
# Exits non-zero on any error. Warnings do not fail the run.
#
# The checks encode the invariants in AGENTS.md. Each one exists because breaking it fails
# silently: a skill that still appears in the menu but no longer does what it says.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTS=("$@")
[[ ${#ROOTS[@]} -eq 0 ]] && ROOTS=("$REPO/skills")

# Skill bodies stay in context for the whole session and are not re-read. After auto-compaction
# only the first ~5,000 tokens of each are restored, so anything past that is silently lost.
MAX_BYTES=12288
MAX_LINES=500
# Descriptions of every skill are resident at all times; the more there are, the more each gets
# squeezed. Keep the total small enough that the ones that matter stay legible.
MAX_DESC_TOTAL=8000
MAX_DESC_ONE=500

errors=0
warnings=0
desc_total=0
count=0

c_red=$'\033[31m'; c_yellow=$'\033[33m'; c_green=$'\033[32m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
err()  { printf '%s✗%s %s: %s\n' "$c_red" "$c_off" "$1" "$2"; errors=$((errors+1)); }
warn() { printf '%s!%s %s: %s\n' "$c_yellow" "$c_off" "$1" "$2"; warnings=$((warnings+1)); }

# Extract a top-level `key: value` from the YAML frontmatter block.
frontmatter_value() {
  awk -v key="$2" '
    NR==1 && $0=="---" { inside=1; next }
    inside && $0=="---" { exit }
    inside {
      k=$0; sub(/:.*/,"",k); gsub(/^[ \t]+|[ \t]+$/,"",k)
      if (k==key) { v=$0; sub(/^[^:]*:[ \t]*/,"",v); print v; exit }
    }
  ' "$1"
}

has_frontmatter_key() {
  awk -v key="$2" '
    NR==1 && $0=="---" { inside=1; next }
    inside && $0=="---" { exit }
    inside {
      k=$0; sub(/:.*/,"",k); gsub(/^[ \t]+|[ \t]+$/,"",k)
      if (k==key) { found=1; exit }
    }
    END { exit !found }
  ' "$1"
}

# The awk helpers below read frontmatter permissively -- they take whatever follows the first
# colon. A real YAML parser does not. That gap shipped a skill whose frontmatter failed to parse
# while every check here passed, so validity is checked separately, first.
#
# This is a targeted check, not a YAML parser: it covers the ways a flat frontmatter block
# actually breaks. The CI job runs a real parser over the same files.
frontmatter_problem() {
  awk 'NR==1&&$0=="---"{i=1;next} i&&$0=="---"{exit} i' "$1" | node -e '
    let raw = "";
    process.stdin.on("data", (d) => (raw += d));
    process.stdin.on("end", () => {
      for (const [n, line] of raw.split("\n").entries()) {
        if (!line.trim() || /^\s*#/.test(line)) continue;
        if (/^\s+/.test(line)) continue;                       // continuation or nested block
        const m = line.match(/^([A-Za-z0-9_-]+)\s*:\s?(.*)$/);
        if (!m) { console.log(`line ${n + 1}: not a key: value pair -- ${line.trim().slice(0, 60)}`); return; }
        const v = m[2];
        if (v === "" || /^["'"'"'[{>|]/.test(v)) continue;      // quoted, flow, or block scalar
        // A plain scalar cannot contain ": " -- YAML reads it as a nested mapping and errors.
        if (/:\s/.test(v)) {
          console.log(`line ${n + 1}: '"'"'${m[1]}'"'"' contains ": " unquoted -- YAML reads this as a nested mapping. Quote the value or use an em dash.`);
          return;
        }
        if (/^[@`*&!%]/.test(v)) {
          console.log(`line ${n + 1}: '"'"'${m[1]}'"'"' starts with a YAML indicator character -- quote it.`);
          return;
        }
        if (/\t/.test(line)) { console.log(`line ${n + 1}: tab character -- YAML forbids tabs for indentation.`); return; }
      }
    });
  ' 2>/dev/null
}

check_skill() {
  local dir="$1"
  local name; name="$(basename "$dir")"
  local skill="$dir/SKILL.md"
  local id="skills/$name"

  [[ -f "$skill" ]] || { err "$id" "no SKILL.md"; return; }
  count=$((count+1))

  head -1 "$skill" | grep -qx -- '---' || { err "$id" "SKILL.md does not start with YAML frontmatter"; return; }

  # --- frontmatter must actually parse ---------------------------------------
  local yaml_problem; yaml_problem="$(frontmatter_problem "$skill")"
  if [[ -n "$yaml_problem" ]]; then
    err "$id" "invalid frontmatter -- $yaml_problem"
    return
  fi

  # --- required fields ------------------------------------------------------
  local fm_name desc
  fm_name="$(frontmatter_value "$skill" name)"
  desc="$(frontmatter_value "$skill" description)"

  [[ -n "$fm_name" ]] || err "$id" "frontmatter is missing 'name'"
  [[ -n "$desc"    ]] || err "$id" "frontmatter is missing 'description'"

  # The invoke name comes from the directory, so a mismatched `name` misleads the reader
  # about what to type.
  if [[ -n "$fm_name" && "$fm_name" != "$name" ]]; then
    warn "$id" "frontmatter name '$fm_name' differs from directory name '$name' (invoked as /$name)"
  fi

  # --- description budget ---------------------------------------------------
  local dlen=${#desc}
  desc_total=$((desc_total + dlen))
  if (( dlen > MAX_DESC_ONE )); then
    warn "$id" "description is ${dlen} chars (target <= ${MAX_DESC_ONE})"
  fi
  # Auto-invocation depends on trigger words the model can match against a request.
  # dotagents:when-clause-tokens use (this|it|when)|when |after |before |時|する場合
  # Kept identical to the list in hooks/dotagents-lint-skill-frontmatter.sh; the check below asserts
  # it. They disagreed once, and the hook was the stricter one -- so a Japanese description passed
  # here and then met a permission prompt from the hook, which is a stall, not a lint failure.
  if ! grep -qiE 'use (this|it|when)|when |after |before |時|する場合' <<<"$desc"; then
    warn "$id" "description has no 'when to use' clause -- auto-invocation will be unreliable"
  fi

  # --- size -----------------------------------------------------------------
  local bytes lines
  bytes=$(wc -c <"$skill" | tr -d ' ')
  lines=$(wc -l <"$skill" | tr -d ' ')
  if (( bytes > MAX_BYTES )); then
    if [[ "$dir" == "$REPO/skills/"* ]]; then
      err "$id" "SKILL.md is ${bytes} bytes (max ${MAX_BYTES}) -- move detail into reference/"
    else
      warn "$id" "SKILL.md is ${bytes} bytes (max ${MAX_BYTES}) -- invoking it parks that much in context all session; consider removing it"
    fi
  fi
  (( lines > MAX_LINES )) && warn "$id" "SKILL.md is ${lines} lines (target <= ${MAX_LINES})"

  # --- invariant: disable-model-invocation only where nothing dispatches by name ---
  # Officially this is the correct spelling for a user-invoked workflow, and it costs zero description
  # budget. It is wrong only where something reaches the skill BY NAME, because it also blocks
  # programmatic Skill calls and subagent preloading -- with no error. See docs/decisions.md.
  # Match on $name, not $id -- $id is "skills/<name>" and a bare case pattern never matches it.
  if has_frontmatter_key "$skill" disable-model-invocation; then
    # Declared as data so the list has one home per file, and matched against rather than spelled out
    # in case patterns. The cross-check below reads these two lines out of both this file and the hook.
    # It used to extract case patterns with a regex hardcoded to `da-[a-z-]+`, so it compared exactly
    # one name and reported "both enforcers agree" -- while the x-review-* protections, added because
    # the `x-` rename broke a guardrail once, were not compared at all.
    DMI_GATE="da-verify"                                                  # dotagents:dmi-gate
    DMI_DISPATCH="x-review-backend x-review-frontend x-review-infra"      # dotagents:dmi-dispatch

    # /da-verify is the only thing that runs `gate.sh arm`. Without auto-invocation the Stop gate
    # never arms and passes every turn: the guardrail opens instead of closing.
    if [[ " $DMI_GATE " == *" $name "* ]]; then
      err "$id" "must never set 'disable-model-invocation' -- it is the only thing that runs 'gate.sh arm', so the Stop gate would never arm and would pass every turn (fails OPEN)"
    # da-review-all dispatches to these by name via a subagent.
    elif [[ " $DMI_DISPATCH " == *" $name "* ]]; then
      err "$id" "is a by-name dispatch target of da-review-all -- 'disable-model-invocation' blocks programmatic Skill calls and subagent preload, so da-review-all would report this layer as covered while reviewing nothing"
    fi
    # Anything else is legitimate: user-invocable only, zero budget cost, nothing dispatches to it.
  fi

  # --- invariant: Cursor sees only name/description/paths -------------------
  # Claude-only frontmatter is allowed as optimization, but the body must carry the same
  # constraint or the skill behaves differently in Cursor with no warning.
  local body; body="$(awk 'NR==1&&$0=="---"{i=1;next} i&&$0=="---"{i=0;next} !i' "$skill")"

  if has_frontmatter_key "$skill" allowed-tools; then
    # Match inflections too ("never modifies", "never writes"), or the check rejects prose that
    # states the restriction perfectly well.
    if grep -qiE 'never (modif|writ|edit|chang|touch)|read-only|does not (modify|write|touch)|only reports' <<<"$body"; then
      :
    elif [[ "$dir" == "$REPO/skills/"* ]]; then
      err "$id" "declares 'allowed-tools' but the body never states the restriction -- unenforced in Cursor (see docs/decisions.md)"
    else
      warn "$id" "declares 'allowed-tools' but the body never states the restriction -- that constraint does not exist in Cursor"
    fi
  fi

  # A skill whose body dispatches to subagents but whose allowed-tools omits Task has been
  # forbidden from doing the thing it exists to do -- by an optimization, which decisions.md §3 says must
  # never be the mechanism. Silent in Cursor, and a permission prompt in Claude.
  if has_frontmatter_key "$skill" allowed-tools \
     && grep -qiE 'parallel subagents|dispatch (them|the)|Task tool|launch .*subagent' <<<"$body" \
     && ! grep -qE '^allowed-tools:.*\bTask\b' <<<"$(frontmatter_value "$skill" allowed-tools | sed 's/^/allowed-tools: /')"; then
    err "$id" "the body dispatches to subagents but 'allowed-tools' omits Task -- the skill cannot do what it describes"
  fi

  if has_frontmatter_key "$skill" context; then
    grep -qiE 'subagent|sub-agent|Task tool|separate context|fresh context' <<<"$body" \
      || err "$id" "declares 'context:' but the body never says to run in a subagent -- ignored in Cursor (see docs/decisions.md)"
  fi

  # --- provenance ------------------------------------------------------------
  # Installed globally, ours sit among two dozen third-party skills. Without a marker there is no
  # way to answer "which of these am I responsible for" -- not for a person reading /skills, and
  # not for da-skills-audit deciding what it may propose removing.
  # Only for skills in this repository. Run over an install directory -- which da-skills-audit tells you
  # to do -- every third-party skill would report as missing our marker, which is both wrong and
  # 28 lines of noise in a 35-line report. A report that is mostly noise stops being read, which is
  # the exact failure finding-discipline.md is about.
  if [[ "$dir" == "$REPO/skills/"* ]]; then
    local fm_block; fm_block="$(awk 'NR==1&&$0=="---"{i=1;next} i&&$0=="---"{exit} i' "$skill")"
    grep -q 'source: bwkw/dotagents' <<<"$fm_block" \
      || err "$id" "frontmatter is missing 'metadata.source: bwkw/dotagents' -- ours must be distinguishable from installed third-party skills"
  fi

  # --- symlinks must stay inside the repository -----------------------------
  # A skill's reference/ is read by an agent on instruction. A symlink there pointing outside the
  # tree turns "read my reference file" into "read whatever this points at" -- ~/.ssh/id_rsa, an
  # .env, anything. Ours point into _shared/ and are fine; the check exists so a future one that
  # does not is caught here rather than by a security scanner months later.
  local link target
  while IFS= read -r link; do
    [[ -n "$link" ]] || continue
    if [[ ! -e "$link" ]]; then
      err "$id" "dangling symlink: ${link#"$dir"/} -> $(readlink "$link")"
      continue
    fi
    target="$(cd "$(dirname "$link")" && cd "$(dirname "$(readlink "$link")")" 2>/dev/null && pwd)"
    if [[ -n "$target" && "$target" != "$REPO"/* && "$target" != "$REPO" ]]; then
      err "$id" "symlink escapes the repository: ${link#"$dir"/} -> $target"
    fi
  done < <(find "$dir" -type l 2>/dev/null)

  # --- reference files must be addressed absolutely -------------------------
  # A relative path does not resolve inside a subagent, whose cwd differs.
  if [[ -d "$dir/reference" ]]; then
    # Per path, not per file. The old form also required that CLAUDE_SKILL_DIR appear nowhere in the
    # body -- so a skill that mentioned the right idiom once, in prose, passed while every actual path
    # in its Files-to-read table stayed relative. All three x-review-* skills were in exactly that
    # state: they instructed subagents to use the absolute form and then handed them relative ones.
    # The lint passed because the file talked about the rule, which is a check on state rather than on
    # mechanism -- the thing docs/decisions.md says not to do.
    local bare
    bare="$(grep -oE '(^|[^/${])reference/[a-z0-9_-]+\.md' <<<"$body" | sed 's/^[^r]*//' | sort -u | tr '\n' ' ')"
    if [[ -n "${bare// /}" ]]; then
      err "$id" "addresses reference files by relative path (${bare% }) -- a subagent's cwd is not yours, so use \${CLAUDE_SKILL_DIR}/reference/..."
    fi

    local ref
    for ref in "$dir"/reference/*; do
      [[ -f "$ref" ]] || continue
      grep -qF "$(basename "$ref")" <<<"$body" \
        || warn "$id" "reference/$(basename "$ref") is never mentioned in SKILL.md"
    done

    # And the other direction. The existing check only caught a file nobody mentions; a mention with no
    # file behind it is worse -- da-review-all told the reader to follow report-format.md, which was not
    # in its reference/ at all, so anyone following that sentence had nothing to open.
    local mentioned
    for mentioned in $(grep -oE 'reference/[a-z0-9_-]+\.md' <<<"$body" | sed 's|^reference/||' | sort -u); do
      [[ -e "$dir/reference/$mentioned" ]] \
        || err "$id" "names reference/$mentioned but no such file exists -- anyone following that instruction has nothing to open"
    done
  fi

  # --- invariant: user-invocable: false only on a dispatch target ------------
  # It removes the skill from the / menu but leaves it model-invocable. On something nothing
  # dispatches to, that makes the skill nearly unreachable: it cannot be typed, and only a
  # description match can find it. Combined with disable-model-invocation, unreachable outright.
  if has_frontmatter_key "$skill" user-invocable; then
    local ui
    ui="$(awk 'NR==1&&$0=="---"{i=1;next} i&&$0=="---"{exit} i' "$skill" \
          | sed -n 's/^user-invocable:[[:space:]]*//p' | tr -d '"'"'"' ')"
    if [[ "$ui" == "false" ]]; then
      case "$name" in
        x-review-backend|x-review-frontend|x-review-infra) : ;;  # dispatched by da-review-all
        *)
          err "$id" "sets 'user-invocable: false' but nothing dispatches to it -- gone from the / menu and reachable only by description match. Add it to the dispatch-target list in this check, or drop the field." ;;
      esac
      has_frontmatter_key "$skill" disable-model-invocation \
        && err "$id" "sets both 'user-invocable: false' and 'disable-model-invocation' -- the first blocks typing and the second blocks the model, leaving the skill unreachable by every route"
    fi
  fi

  # --- structure ------------------------------------------------------------
  grep -qiE '^##+ .*(precondition|実行条件)' <<<"$body" \
    || warn "$id" "no Preconditions section -- the skill cannot stop cleanly on bad input"
}

echo "linting skills"
echo
for root in "${ROOTS[@]}"; do
  [[ -d "$root" ]] || { err "$root" "not a directory"; continue; }
  for dir in "$root"/*/; do
    [[ -d "$dir" ]] || continue
    [[ "$(basename "$dir")" == _* ]] && continue   # _shared (and any other _-prefixed helper dir; _template lives at the repo root, not here)
    check_skill "${dir%/}"
  done
done

# --- protected names must still exist, and the two enforcers must agree ----
# The disable-model-invocation scope is a hardcoded list of skill names in two files. Renaming a
# skill without updating both leaves the guardrail installed and enforcing nothing -- which happened
# for real when the `da-` prefix was introduced. So the list is cross-checked against reality here.
if [[ -d "$REPO/skills" ]]; then
  echo
  echo "checking the disable-model-invocation scope"
  hook_file="$REPO/hooks/dotagents-lint-skill-frontmatter.sh"

  # Both files declare the list on a line carrying a marker, and both drive their behaviour from that
  # declaration. Read here by marker rather than by parsing case patterns: the previous version's
  # extraction regex was hardcoded to `da-[a-z-]+` on both sides, so it compared exactly one name --
  # and then printed "both enforcers agree", naming that one name as if it were the whole set. The
  # x-review-* protections, added because the `x-` rename broke a guardrail for real, were never
  # compared. Prefix-agnostic now, so a future prefix is covered without anyone remembering to widen it.
  # ${BASH_SOURCE[0]}, not $0: $0 is the caller when this file is sourced.
  # The marker comment is stripped before names are extracted, so `dmi-gate` and `dmi-dispatch` are not
  # themselves read as skill names. `#` and `//` both accepted: one side is bash, the other is the JS
  # embedded in the hook.
  marked_names() { # <file> <marker>
    grep -E "dotagents:$2([^-a-z0-9]|$)" "$1" 2>/dev/null \
      | sed 's|[#/]*[[:space:]]*dotagents:.*$||' \
      | grep -oE '[a-z][a-z0-9]*(-[a-z0-9]+)+' | sort -u
  }
  linter_names="$( { marked_names "${BASH_SOURCE[0]}" dmi-gate; marked_names "${BASH_SOURCE[0]}" dmi-dispatch; } | sort -u)"
  hook_names="$(   { marked_names "$hook_file"        dmi-gate; marked_names "$hook_file"        dmi-dispatch; } | sort -u)"

  scope_ok=1
  if [[ -z "$linter_names" ]]; then
    err "scope" "no 'dotagents:dmi-gate'/'dotagents:dmi-dispatch' declaration found in verify-skills.sh -- the marker is what makes the two lists comparable, so removing it removes the check"
    scope_ok=0
  fi
  if [[ -z "$hook_names" ]]; then
    err "scope" "no 'dotagents:dmi-gate'/'dotagents:dmi-dispatch' declaration found in the lint hook -- the marker is what makes the two lists comparable, so removing it removes the check"
    scope_ok=0
  fi
  while read -r pn; do
    [[ -n "$pn" ]] || continue
    [[ -f "$REPO/skills/$pn/SKILL.md" ]] \
      || { err "scope" "'$pn' is protected from disable-model-invocation but skills/$pn does not exist -- it was renamed and the list was not updated, so the guardrail now protects nothing"; scope_ok=0; }
  done <<<"$linter_names"

  if [[ -n "$hook_names" && -n "$linter_names" ]] && [[ "$linter_names" != "$hook_names" ]]; then
    err "scope" "verify-skills.sh and the lint hook protect different names -- both must agree or one of them silently stops enforcing"
    printf '%s  linter: %s%s\n' "$c_dim" "$(tr '\n' ' ' <<<"$linter_names")" "$c_off"
    printf '%s  hook:   %s%s\n' "$c_dim" "$(tr '\n' ' ' <<<"$hook_names")" "$c_off"
    scope_ok=0
  fi

  (( scope_ok )) && printf '%s✓%s protected names exist and both enforcers agree: %s\n' \
    "$c_green" "$c_off" "$(tr '\n' ' ' <<<"$linter_names")"
fi

# --- the shared gate block -------------------------------------------------
# scripts/gate.sh and hooks/dotagents-verify-gate.sh both decide which repository a sentinel belongs
# to and where a working tree's counters live. The code is duplicated rather than sourced from a lib
# because invariant 4 says a hook must not depend on a path that can go missing -- and a lib under the
# repository can. Duplication is only safe while the copies are identical: a hook that resolved
# worktrees differently from gate.sh would arm one directory and enforce another, and nothing would
# report it. Checked mechanically, so it fails at commit time rather than at 3am.
gate_sh="$REPO/scripts/gate.sh"
gate_hook="$REPO/hooks/dotagents-verify-gate.sh"
if [[ -f "$gate_sh" && -f "$gate_hook" ]]; then
  echo
  echo "checking the shared gate block"
  extract_identity() {
    sed -n '/^# >>> dotagents:gate-shared/,/^# <<< dotagents:gate-shared/p' "$1"
  }
  ident_a="$(extract_identity "$gate_sh")"
  ident_b="$(extract_identity "$gate_hook")"
  if [[ -z "$ident_a" ]]; then
    err "gate-shared" "scripts/gate.sh has no '# >>> dotagents:gate-shared' block -- the marker is what makes the duplication checkable, so removing it removes the check"
  elif [[ -z "$ident_b" ]]; then
    err "gate-shared" "hooks/dotagents-verify-gate.sh has no '# >>> dotagents:gate-shared' block -- the marker is what makes the duplication checkable, so removing it removes the check"
  elif [[ "$ident_a" != "$ident_b" ]]; then
    err "gate-shared" "the two copies have drifted -- gate.sh would resolve a repository or worktree differently from the hook, so one could arm a directory the other never enforces"
    printf '%s  first difference:%s\n' "$c_dim" "$c_off"
    diff <(printf '%s\n' "$ident_a") <(printf '%s\n' "$ident_b") | head -8 | sed "s/^/$(printf '%s' "$c_dim")    /"
    printf '%s%s\n' "$c_off" ""
  else
    printf '%s✓%s the shared gate block is byte-identical in gate.sh and the hook (%s lines)\n' \
      "$c_green" "$c_off" "$(printf '%s\n' "$ident_a" | wc -l | tr -d ' ')"
  fi
fi

# --- the design review has to emit a landing plan ---------------------------
# Where a body of work divides into separate changes to ship is decided nowhere else: da-fix-plan orders
# fixes into commits inside one change, da-review-all asks whether two layers ship together only as a
# finding. So plans used to reach implementation with the split unmade, and it got made ad hoc by
# whoever was typing. The section is in da-design-review's required output -- checked here, because a
# required section that only prose asks for is a section that quietly stops being produced.
dr="$REPO/skills/da-design-review/SKILL.md"
if [[ -f "$dr" ]]; then
  echo
  echo "checking the design review's landing plan"
  if ! grep -q 'Landing plan' "$dr"; then
    err "landing-plan" "skills/da-design-review no longer emits a 'Landing plan' section -- nothing else in the toolkit decides how work divides into separate changes to ship"
  elif ! grep -q 'What gates it' "$dr"; then
    err "landing-plan" "the landing plan table lost its 'What gates it' column -- a landing nobody can name a gate for cannot be verified, which is the column that makes the table more than a list"
  else
    printf '%s✓%s the design review emits a landing plan, with a gate per landing\n' "$c_green" "$c_off"
  fi
fi

# --- the two 'when to use' enforcers must agree -----------------------------
# This file warns when a description has no when-clause; the lint hook says the same thing to whoever
# is writing the file. They disagreed, and the hook was the stricter one: it did not accept a Japanese
# clause that this file did. So a Japanese description passed the lint and then met a permission prompt
# from the hook -- a stalled write rather than a reported problem, and worse for anything unattended.
# One list, two languages, checked mechanically because prose asking for it is how they drifted.
lint_hook="$REPO/hooks/dotagents-lint-skill-frontmatter.sh"
if [[ -f "$lint_hook" ]]; then
  echo
  echo "checking the 'when to use' token list"
  tok_line() { grep -o 'dotagents:when-clause-tokens.*' "$1" | head -1 | sed 's/^dotagents:when-clause-tokens *//'; }
  tok_a="$(tok_line "$0")"
  tok_b="$(tok_line "$lint_hook")"
  if [[ -z "$tok_a" || -z "$tok_b" ]]; then
    err "when-tokens" "the 'dotagents:when-clause-tokens' marker is missing from $( [[ -z "$tok_a" ]] && echo verify-skills.sh || echo the lint hook ) -- the marker is what makes the two lists comparable"
  elif [[ "$tok_a" != "$tok_b" ]]; then
    err "when-tokens" "the linter and the lint hook accept different 'when to use' tokens, so a description can pass one and be stopped by the other"
    printf '%s  linter: %s%s\n' "$c_dim" "$tok_a" "$c_off"
    printf '%s  hook:   %s%s\n' "$c_dim" "$tok_b" "$c_off"
  else
    printf '%s✓%s both enforcers accept the same trigger tokens: %s\n' "$c_green" "$c_off" "$tok_a"
  fi
fi

# --- agents ----------------------------------------------------------------
# A skill that dispatches to an agent by name fails silently when the agent is missing: the caller
# falls back to general-purpose and the posture the agent definition carried is simply absent.
if [[ -d "$REPO/agents" ]]; then
  echo
  echo "checking agents"
  agent_defs=""
  for af in "$REPO"/agents/*.md; do
    [[ -f "$af" ]] || continue
    aid="$(basename "$af" .md)"
    agent_defs="$agent_defs $aid"
    afm="$(awk 'NR==1&&$0=="---"{i=1;next} i&&$0=="---"{exit} i' "$af")"
    grep -q '^name:' <<<"$afm" || err "agents/$aid" "frontmatter is missing 'name'"
    grep -q '^description:' <<<"$afm" || err "agents/$aid" "frontmatter is missing 'description'"
    [[ "$(grep '^name:' <<<"$afm" | sed 's/^name:[[:space:]]*//')" == "$aid" ]] \
      || err "agents/$aid" "frontmatter 'name' disagrees with the filename -- Cursor requires them to match"
    # No agent may pin a model. A pin silently overrides the model the user chose for the session --
    # they pick Opus, a subagent runs on something else, and nothing in the prompt or the transcript
    # says so. It shipped once as a token optimization, was reverted, and is exactly the kind of thing
    # that comes back the next time someone measures cost. `model:` is also Claude-only, so a pin
    # desyncs Claude Code from Cursor on top of overriding the user. Take cost out of how MANY
    # subagents run (the fan-out budget in review-process.md), never out of what they run on.
    amodel="$(grep '^model:' <<<"$afm" | sed 's/^model:[[:space:]]*//')"
    if [[ -n "$amodel" && "$amodel" != "inherit" ]]; then
      err "agents/$aid" "pins 'model: $amodel' -- this overrides the model the user chose for the session, silently. Use 'model: inherit'"
    fi
    # Cursor reads name/description/model/readonly only, so a tool restriction expressed solely in
    # `tools:` is absent there. The body must state it too.
    if grep -q '^tools:' <<<"$afm"; then
      abody="$(awk 'NR==1&&$0=="---"{i=1;next} i&&$0=="---"{i=0;next} !i' "$af")"
      grep -qiE 'read-only|never modify|do not modify' <<<"$abody" \
        || warn "agents/$aid" "declares 'tools:' but the body never states the restriction -- Cursor ignores 'tools:'"
    fi
  done
  # Template placeholders are the rename trap: `x-review-<layer>` is a real dispatch instruction that
  # no name-based sweep matches, and it broke twice. Assert the prefix any such placeholder uses.
  while read -r ph; do
    [[ -n "$ph" ]] || continue
    err "placeholder" "'$ph' names a dispatch target with the wrong prefix -- internal skills are x-*, so a sweep over real names will never fix it"
  done < <(grep -rhoE '`da-review-<[a-z]+>`' "$REPO"/skills/*/SKILL.md 2>/dev/null | sort -u)

  # Anything with a counterpart in _shared/ must be a symlink to it. These were copies for a long time,
  # and the copies drifted: the four mandatory review requirements and the verifier-bias section were
  # written into _shared/ and reached none of the five review skills. Nothing reported it, because a
  # stale copy is a perfectly valid file. Assert the mechanism, not the content -- copies that happen to
  # match today drift tomorrow.
  for shared in "$REPO"/skills/_shared/*.md; do
    [[ -f "$shared" ]] || continue
    sname="$(basename "$shared")"
    for user in "$REPO"/skills/*/reference/"$sname"; do
      [[ -e "$user" || -L "$user" ]] || continue
      rel="${user#"$REPO"/skills/}"
      if [[ ! -L "$user" ]]; then
        err "_shared" "$rel is a copy of _shared/$sname, not a symlink -- an edit to _shared/ will not reach it, and nothing reports that"
      elif [[ "$(readlink "$user")" != "../../_shared/$sname" ]]; then
        err "_shared" "$rel points at '$(readlink "$user")' instead of ../../_shared/$sname"
      fi
    done
  done

  # Invisible characters. Unicode Tag (U+E0000-E007F) renders as nothing and carries instructions the
  # human reviewer cannot see -- the documented smuggling vector for agent skills, which Claude Code only
  # started refusing in Feb 2026. Bidi overrides can make a line read as the opposite of what it does.
  # This repository is public and takes pull requests, so a diff that looks empty must not be.
  # U+FE0F (emoji variation selector) and U+200B inside a pattern-documentation file are expected.
  while read -r bad; do
    [[ -n "$bad" ]] || continue
    err "unicode" "$bad"
  done < <(python3 - "$REPO" <<'PYEOF'
import pathlib, sys, unicodedata
root = pathlib.Path(sys.argv[1])
BAD = {
    "Unicode Tag": lambda o: 0xE0000 <= o <= 0xE007F,
    "bidi override": lambda o: 0x202A <= o <= 0x202E or 0x2066 <= o <= 0x2069,
    "zero-width": lambda o: o in (0x200B, 0x200C, 0x200D, 0xFEFF),
    "private use": lambda o: 0xE000 <= o <= 0xF8FF,
}
for f in sorted(root.rglob("*.md")):
    if ".git" in f.parts:
        continue
    try:
        text = f.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        continue
    for label, test in BAD.items():
        hits = sorted({ord(c) for c in text if test(ord(c))})
        if not hits:
            continue
        if label == "zero-width" and "injection" in f.name:
            continue
        codes = " ".join(f"U+{h:04X}" for h in hits[:4])
        print(f"{f.relative_to(root)} contains {label} characters ({codes}) -- invisible to a reviewer, readable by the model")
PYEOF
)

  # Every agent named by a skill must exist, or the dispatch degrades with no error.
  while read -r ref; do
    [[ -n "$ref" ]] || continue
    [[ " $agent_defs " == *" $ref "* ]] && continue
    err "agents" "skills dispatch to '$ref' but agents/$ref.md does not exist -- the caller silently falls back to general-purpose"
  done < <(grep -rhoE '\b(x-review-verifier|x-codebase-explorer)\b' "$REPO"/skills/*/SKILL.md "$REPO"/skills/_shared/*.md 2>/dev/null | sort -u)
  printf '%s✓%s %s agent(s) defined:%s\n' "$c_green" "$c_off" "$(printf '%s' "$agent_defs" | wc -w | tr -d ' ')" "$agent_defs"
fi

echo
if (( desc_total > MAX_DESC_TOTAL )); then
  warn "budget" "descriptions total ${desc_total} chars across ${count} skills (target <= ${MAX_DESC_TOTAL})"
else
  printf '%s✓%s budget: %s chars of descriptions across %s skills%s\n' \
    "$c_green" "$c_off" "$desc_total" "$count" "${c_dim}${c_off}"
fi

echo
if (( errors )); then
  printf '%s%d error(s), %d warning(s)%s\n' "$c_red" "$errors" "$warnings" "$c_off"
  exit 1
fi
printf '%s✓ %d skill(s) OK%s%s\n' "$c_green" "$count" \
  "$( (( warnings )) && printf ', %d warning(s)' "$warnings")" "$c_off"
