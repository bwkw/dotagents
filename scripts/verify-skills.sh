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

  # Same rule as the agents loop below, and it needs stating in both places because a skill can pin a
  # model too. A skill's `model:` switches the model for its whole run -- the user picks one at the top
  # and silently gets another, which is the thing invariant 10 exists to stop. Unlike a subagent's, this
  # field IS Claude-only (Cursor drops it from skill frontmatter), so a pin here also splits behaviour
  # between the two agents. There is no legitimate use: if a skill needs a different model, that is the
  # user's call to make at the top, not the skill's to make on their behalf.
  if has_frontmatter_key "$skill" model; then
    smodel="$(frontmatter_value "$skill" model)"
    [[ "$smodel" == "inherit" ]] \
      || err "$id" "frontmatter pins 'model: $smodel' -- a skill must not switch the model the user chose. Remove the field"
  fi

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

    # And one level further out: a reference file naming a sibling by bare filename. AGENTS.md says a
    # layer's perspectives.md points at a shared lens in one line instead of restating it, which makes
    # that one line load-bearing while nothing checked it -- delete the link and the instruction reads
    # fine and opens nothing. Only non-symlink reference files are checked: a _shared/ file naming
    # another _shared/ file resolves in the skills that link both and dangles in the ones that do not
    # (7 such pairs today), which is a different problem than a layer file pointing at nothing, and
    # closing it would mean linking 16KB of review-process.md into skills that deliberately do not
    # read it.
    local sibling
    for ref in "$dir"/reference/*.md; do
      [[ -f "$ref" && ! -L "$ref" ]] || continue
      for sibling in $(grep -oE '`[a-z0-9_-]+\.md`' "$ref" | tr -d '`' | sort -u); do
        [[ -e "$dir/reference/$sibling" ]] \
          || err "$id" "reference/$(basename "$ref") names $sibling, which is not in this skill's reference/ -- the one-line pointer that replaced a restatement has nothing behind it"
      done
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

# --- the no-subagent rule has to be in the body, not only in reference/ -----
# Cursor has no ${CLAUDE_SKILL_DIR} and no documented equivalent -- its docs say relative paths from the
# skill root. So a rule that lives only in reference/ is a rule Claude Code follows and Cursor may not,
# and the failure is invisible: Cursor just fans out like before, produces a normal report, and nothing
# says the rule was never read. That is invariant 1 (state the constraint in the body; treat the
# Claude-only path as optimization on top) applied to the rule that decides what a review COSTS.
#
# This check used to demand the opposite content -- the 0/3/5 fan-out budget and its "80 lines" inline
# threshold. The budget is gone: the review spawns nothing at all now, so a body still carrying a
# subagent allowance would be the stale half of a half-applied change. **The check was retargeted, not
# deleted**, because the reason for it never depended on which rule was in force: whatever bounds the
# spend has to bind in both agents, and only the body binds in both.
echo
echo "checking the no-subagent rule is stated in the body"
budget_missing=""
for bs in x-review-backend x-review-frontend x-review-infra da-review-all; do
  bf="$REPO/skills/$bs/SKILL.md"
  [[ -f "$bf" ]] || { budget_missing="$budget_missing $bs(absent)"; continue; }
  bbody="$(awk 'NR==1&&$0=="---"{i=1;next} i&&$0=="---"{i=0;next} !i' "$bf")"
  # Both halves: the prohibition, and the phrase the report has to carry. "no subagents" alone could sit
  # in a sentence about something else; "inline" alone is any adverb.
  grep -qiE 'no subagents' <<<"$bbody" && grep -qiE 'inline' <<<"$bbody" \
    || budget_missing="$budget_missing $bs"
done
if [[ -n "$budget_missing" ]]; then
  err "no-subagent-rule" "the no-subagent rule is not in the body of:$budget_missing -- Cursor cannot resolve \${CLAUDE_SKILL_DIR}, so a rule only in reference/ does not bind there"
else
  printf '%s✓%s the fan-out budget and its inline tier are in all 4 review bodies\n' "$c_green" "$c_off"
fi

# --- the diff-size measurement has to be scoped to what is actually reviewed ---
# Every review skill sizes the diff before it reads anything, and the number decides both which process
# gets read and whether the report may call itself a review. But `da-review-all` hands each layer a
# per-layer file list and says "do not re-derive the full diff" -- while the sizing snippet measured
# `"$BASE"...HEAD` with no paths. So a 45-file change split 15/15/15 made every one of the three layers
# measure 45 and declare itself a sample, each while holding 15 files. The failure is silent in the worst
# direction: the report is *more* modest than the work, so nothing looks wrong.
#
# The check is on the snippet, not on prose, because the snippet is what gets run. `SCOPE` must be
# assigned in the file (so it is never unset) and every sizing `git diff` must pass it.
echo
echo "checking the diff-size measurement is scoped to the reviewed paths"
# Derived, not listed. A hardcoded set of five silently exempts the sixth review skill somebody adds;
# `--shortstat` appears only in the sizing snippet, so the files that size a diff ARE the files to check.
scope_bad=""
scope_files="$(grep -rlF -- '--shortstat' "$REPO/skills" 2>/dev/null | sort)"
scope_n="$(printf '%s\n' "$scope_files" | grep -c .)"
if (( scope_n < 5 )); then
  err "diff-size-scope" "only $scope_n file(s) under skills/ size a diff -- there were 5, so one lost its measurement step rather than having it scoped"
fi
for sp in $scope_files; do
  sf="${sp#"$REPO/skills/"}"
  grep -qE '^[[:space:]]*SCOPE=' "$sp" || { scope_bad="$scope_bad $sf(no-SCOPE)"; continue; }
  # `--shortstat` appears only in the sizing one-liner, which also carries the `--name-only | wc -l`
  # half -- so both halves have to take the scope, and requiring two occurrences on the line says that
  # without matching the prose elsewhere that legitimately shows an unscoped `git diff --name-only`
  # (establishing scope in the first place is a whole-diff operation).
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    n_scoped="$(grep -o -- '-- \$SCOPE' <<<"$line" | wc -l | tr -d ' ')"
    (( n_scoped >= 2 )) || scope_bad="$scope_bad $sf(unscoped)"
  done < <(grep -F -- '--shortstat' "$sp")
done
if [[ -n "$scope_bad" ]]; then
  err "diff-size-scope" "the diff-size measurement is not scoped to the reviewed paths in:$scope_bad -- a dispatched layer measures the whole change and reports its own work as a sample"
else
  printf '%s✓%s the diff-size measurement is scoped in all 5 sizing snippets\n' "$c_green" "$c_off"
fi

# --- caps on the review must not disagree with the record, or with themselves ---
# The three-lens verify pass is the review's quality cap: how many of the most serious findings get
# checked from three angles instead of one. Decision 16 set it at "the 3 most irreversible per layer",
# on a cost argument that only held while each lens was a *subagent*. daa6ad9 removed every subagent
# and, in the same commit, cut the cap to one finding -- while its message said only that the three
# lenses survive as three passes. So the number moved 3x in the tightening direction at the exact moment
# its cost basis disappeared, docs/decisions.md kept stating the old one, and nothing failed.
#
# A marker on each live statement, compared. History is left alone: the marker sits on what is in force,
# never on the row recording what used to be.
echo
echo "checking the three-lens cap agrees between the rule and the record"
lens_caps="$(grep -rhoE 'dotagents:lens-cap [0-9]+' \
  "$REPO/skills/_shared/verification.md" "$REPO/docs/decisions.md" 2>/dev/null | grep -oE '[0-9]+')"
lens_n="$(printf '%s\n' "$lens_caps" | grep -c .)"
lens_uniq="$(printf '%s\n' "$lens_caps" | sort -u | grep -c .)"
if (( lens_n < 2 )); then
  err "lens-cap" "the three-lens cap carries fewer than 2 'dotagents:lens-cap <n>' markers -- it must be stated in skills/_shared/verification.md (the rule) and docs/decisions.md (the record), or the next change to it goes unrecorded again"
elif (( lens_uniq != 1 )); then
  err "lens-cap" "the three-lens cap disagrees between the rule and the record ($(printf '%s ' $lens_caps)) -- docs/decisions.md would describe a review the skill does not perform"
else
  printf '%s✓%s the three-lens cap is %s in both the rule and the record\n' "$c_green" "$c_off" "$(printf '%s\n' "$lens_caps" | head -1)"
fi

# --- a phase must not order findings it does not accept -------------------------
# 6a is scoped to critical/irreversible. daa6ad9 then added an anti-anchoring ordering rule naming the
# two severities 6a excludes. A model resolving that either widens the scope -- tripling the cost of the
# cheap half of the report, which the same file forbids two paragraphs later -- or drops the ordering,
# losing the position-effect guard the file justifies with measurement. Either way it silently picks one
# of two rules the file states as both binding.
echo
echo "checking the refutation pass does not order findings it excludes"
# Proved to fail OPEN in its first form: it was `grep -q '<the scope sentence>' && <the real test>`, so
# rewording a sentence it does not own silently disabled it. Verified with a control -- the defect
# present, original sentence -> error; the defect present, sentence reworded -> pass. CONTRIBUTING is
# explicit that a guardrail which opens is worse than none, so the anchor is now asserted rather than
# used as a condition, and the ordering test is scoped to 6a's own section rather than the whole file
# (the phrase "severity order" also appears in the bias notes further down).
vf="$REPO/skills/_shared/verification.md"
if [[ -f "$vf" ]]; then
  if ! grep -q 'Applies only to findings with `severity=critical`' "$vf"; then
    err "verify-scope" "skills/_shared/verification.md no longer states 6a's scope in the form this check anchors on -- reword the check together with the file, or the check passes by not finding its anchor"
  else
    # 6a runs from its own heading to 6b's; the ordering rule must not name a severity 6a excludes.
    sect="$(awk '/^## 6a\./{i=1} /^## 6b\./{i=0} i' "$vf")"
    if grep -A1 'severity order' <<<"$sect" | grep -qE '💡|🟡'; then
      err "verify-scope" "6a accepts only critical/irreversible but its ordering rule names 💡/🟡 -- the pass is told to order findings it was told not to take"
    else
      printf '%s✓%s the refutation pass orders only the severities it accepts\n' "$c_green" "$c_off"
    fi
  fi
fi

# --- a cut nothing counts is the shape the 40-file threshold had ---------------
# The find phase used to cap warning/info at "the top 3 per cluster by severity". The report already
# caps them and *folds the overflow into an aggregate note*, and 🔬 counts what verification refuted and
# what fell below the confidence threshold. A 4th warning in a cluster -- above 80, never refuted -- was
# dropped before any of those, so it appeared in no count at all. Two caps in series where the outer one
# already discloses: the inner one only removes information. Same shape as `> 40 files` -- the cap is
# invisible in the output, so the report reads as complete.
echo
echo "checking the find phase has no undisclosed rank cap"
fd="$REPO/skills/_shared/finding-discipline.md"
if [[ -f "$fd" ]]; then
  # One phrasing was one way to write the cap. These are the shapes it actually comes back as.
  if grep -qiE '(top|highest|first|best) [0-9]+ per cluster|cap [^.]{0,30} (at|to) [0-9]+ per cluster|[0-9]+ per cluster by severity' "$fd"; then
    err "find-rank-cap" "the find phase caps findings by rank again -- nothing counts what a rank cap drops, so use the report's output budget in report-format.md, which folds the overflow into a note the reader can see"
  else
    printf '%s✓%s the find phase drops nothing that no bucket counts\n' "$c_green" "$c_off"
  fi
fi

# --- routing must not live only in a file nothing loads at runtime ----------------
# README.md carried the whole of it: "spec をディスクに（リポジトリが openspec を使うならそちら）". README.md
# is not loaded at runtime -- AGENTS.md has no `@` import for it -- so every invocation ignored the
# parenthetical and wrote a plan file in the upstream skill's default location. Months of that, and
# nothing failed, because a rule written where it cannot bind produces no error, only the old behaviour.
#
# The check is the containment: whatever the docs claim the toolkit routes on, a skill body has to say
# too. `spec_system` is the field, and it is checked in both directions -- declared in the schema, and
# read by a skill -- because a profile field nothing reads is the same failure wearing the other shoe.
echo
echo "checking the spec-system routing binds where it is read"
spec_bad=""
docs_mention="$(grep -rlF 'openspec' "$REPO/README.md" "$REPO/docs" 2>/dev/null | head -1)"
# A SKILL.md **body**, not a reference file: Cursor cannot resolve ${CLAUDE_SKILL_DIR}, so routing that
# lives only under reference/ does not bind there -- which is the same failure as putting it in README,
# one level in. The first version of this check accepted a reference file and passed while the three
# bodies had it stripped out.
#
# And it stopped at the FIRST body that matched, which is invariant 7's failure exactly: it found one,
# reported the routing sound, and never looked at the sibling. A test mutation (spec_system renamed to a
# placeholder) shipped in da-spec's body while da-design-review's copy still had the real name -- 14
# occurrences of a field that does not exist, in the skill the routing is *for*, and this check was green
# for it. So: every body that reaches for the shared file must name the field, and the ones that do are
# counted rather than short-circuited.
skill_mention=""
spec_partial=""
for smf in "$REPO"/skills/*/SKILL.md; do
  [[ -e "$smf" ]] || continue
  sbody="$(awk 'NR==1&&$0=="---"{i=1;next} i&&$0=="---"{i=0;next} !i' "$smf")"
  grep -qF 'spec-system.md' <<<"$sbody" || continue      # not a skill that routes on it
  if grep -qF 'spec_system' <<<"$sbody"; then
    skill_mention="$smf"
  else
    spec_partial="$spec_partial $(basename "$(dirname "$smf")")"
  fi
done
if [[ -n "$spec_partial" ]]; then
  spec_bad="these skills read reference/spec-system.md but never name the spec_system field:$spec_partial -- one body carrying a renamed or placeholder field name is a skill pointed at a key no profile has"
elif [[ -n "$docs_mention" && -z "$skill_mention" ]]; then
  spec_bad="the docs route on a spec system that no skill body reads"
elif [[ -n "$skill_mention" ]] && ! grep -qF '"spec_system"' "$REPO/profiles/_schema.json" 2>/dev/null; then
  spec_bad="a skill reads spec_system but the profile schema does not declare it, so additionalProperties:false rejects every profile that sets it"
fi
if [[ -n "$spec_bad" ]]; then
  err "spec-system" "$spec_bad -- README.md is not loaded at runtime, so routing stated only there is not routing"
else
  printf '%s✓%s the spec-system routing is stated in a skill body and declared in the schema\n' "$c_green" "$c_off"
fi

# --- the tier ladder is written twice, so the two copies have to name the same skills ---
# README.md and docs/loops.md both carry the M/L rows, and the design-phase cell of each names the
# skills a human types. They drifted the moment one entry point was renamed: README said /da-spec while
# loops.md still said /writing-plans, and a reader had no way to tell which was current. The prose
# differs deliberately between the two files (one is a tour, one is the manual), so this compares the
# only part that must not differ -- the set of skills named.
echo
echo "checking the tier ladder names the same skills in both copies"
# Presence and content are separate questions: the first form conflated them, so a tier whose design
# phase legitimately became "無し" in BOTH copies -- which is already true of XS and S -- was reported as
# a missing row. And an escaped \| inside any cell shifts every awk column silently, so that is refused
# loudly instead of being read wrong.
tier_line() { grep -m1 "^| \*\*$2\*\* |" "$1" 2>/dev/null; }
tier_cell() { awk -F'|' '{print $4}' <<<"$1" | grep -oE '/[a-z][a-z0-9-]+' | sort -u | tr '\n' ' '; }
tier_bad=""
for tier in M L; do
  l_readme="$(tier_line "$REPO/README.md" "$tier")"
  l_loops="$(tier_line "$REPO/docs/loops.md" "$tier")"
  [[ -n "$l_readme" ]] || { tier_bad="$tier_bad $tier(absent-in-README)"; continue; }
  [[ -n "$l_loops"  ]] || { tier_bad="$tier_bad $tier(absent-in-loops)"; continue; }
  case "$l_readme$l_loops" in
    *'\|'*) tier_bad="$tier_bad $tier(escaped-pipe-in-cell)"; continue ;;
  esac
  r_readme="$(tier_cell "$l_readme")"
  r_loops="$(tier_cell "$l_loops")"
  [[ "$r_readme" == "$r_loops" ]] || tier_bad="$tier_bad $tier(README:${r_readme:-none}vs loops:${r_loops:-none})"
done
if [[ -n "$tier_bad" ]]; then
  err "tier-ladder" "README.md and docs/loops.md disagree about which skills a tier's design phase runs:$tier_bad -- one of them is telling somebody to type a command the other retired"
else
  printf '%s✓%s the M and L tiers name the same skills in README and docs/loops.md\n' "$c_green" "$c_off"
fi

# --- the change table is written three times, so the three have to be one table -------
# Decision 15 aligned the review report's 変更内容 with da-pr-describe's 変わること on purpose: two
# vocabularies for the same change make the reader reconcile them. That alignment is only real while the
# copies match, and nothing compared them -- narrowing the table from four columns to three touched
# three files, and getting two of them would have looked exactly like getting all three.
#
# The columns are declared on a marker line so the check reads data rather than parsing prose, the same
# shape as dotagents:dmi-gate and dotagents:lens-cap. Removing a marker removes the check, so a missing
# one is an error rather than a silent skip.
echo
echo "checking the change table is the same table in all three copies"
change_tbl_files="$REPO/skills/_shared/report-format.md $REPO/skills/_shared/review-process-brief.md $REPO/skills/da-pr-describe/reference/pr-template.md"
change_cols=""; change_bad=""
for ctf in $change_tbl_files; do
  [[ -f "$ctf" ]] || { change_bad="$change_bad $(basename "$ctf")(absent)"; continue; }
  marker="$(grep -m1 -oE 'dotagents:change-table \|.*\|' "$ctf" | sed 's/dotagents:change-table //')"
  if [[ -z "$marker" ]]; then
    change_bad="$change_bad $(basename "$ctf")(no-marker)"; continue
  fi
  # The marker declares the columns; the table under it has to actually be those columns.
  hdr="$(grep -A1 -F 'dotagents:change-table' "$ctf" | sed -n '2p' | sed 's/[[:space:]]*$//')"
  [[ "$hdr" == "$marker" ]] || change_bad="$change_bad $(basename "$ctf")(header≠marker)"
  change_cols="$change_cols$marker"$'\n'
done
uniq_cols="$(printf '%s' "$change_cols" | grep -c . )"
distinct="$(printf '%s' "$change_cols" | sort -u | grep -c .)"
if [[ -n "$change_bad" ]]; then
  err "change-table" "the change table is not comparable across its three copies:$change_bad -- decision 15 aligned them so a reader never reconciles two vocabularies for one change"
elif (( uniq_cols != 3 )); then
  err "change-table" "expected 3 declared change tables, found $uniq_cols -- a copy lost its marker, and an unmarked copy drifts without failing"
elif (( distinct != 1 )); then
  err "change-table" "the three change tables declare different columns:$(printf ' %s' $(printf '%s' "$change_cols" | sort -u | tr ' ' '_')) -- narrowing the table in one place and not the others is the drift decision 15 exists to prevent"
else
  printf '%s✓%s the change table is %s in all three copies\n' "$c_green" "$c_off" "$(printf '%s' "$change_cols" | head -1)"
fi

# --- counts written in prose must be the counts on disk ---------------------------
# README and AGENTS.md state how many skills there are, in sentences. Adding da-spec made three of those
# sentences wrong at once -- "自作は10スキル", "da- は打つもの（7）", "the same seven entries" -- and every
# one of them still read perfectly. A number in prose has no way to notice the directory changed.
#
# The counts are declared on a marker beside the sentence and computed here. dotagents:skill-count
echo
echo "checking the skill counts in prose match the directories"
real_mine="$(ls -d "$REPO"/skills/*/ 2>/dev/null | grep -vE '_shared|_template' | wc -l | tr -d ' ')"
real_typed="$(ls -d "$REPO"/skills/da-*/ 2>/dev/null | wc -l | tr -d ' ')"
real_layer="$(ls -d "$REPO"/skills/x-review-*/ 2>/dev/null | wc -l | tr -d ' ')"
real_agents="$(ls -1 "$REPO"/agents/*.md 2>/dev/null | wc -l | tr -d ' ')"
count_bad=""; count_seen=0
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  count_seen=$((count_seen+1))
  for pair in $line; do
    case "$pair" in
      mine=*)   [[ "${pair#mine=}"   == "$real_mine"   ]] || count_bad="$count_bad mine(says ${pair#mine=}, is $real_mine)" ;;
      typed=*)  [[ "${pair#typed=}"  == "$real_typed"  ]] || count_bad="$count_bad typed(says ${pair#typed=}, is $real_typed)" ;;
      layer=*)  [[ "${pair#layer=}"  == "$real_layer"  ]] || count_bad="$count_bad layer(says ${pair#layer=}, is $real_layer)" ;;
      agents=*) [[ "${pair#agents=}" == "$real_agents" ]] || count_bad="$count_bad agents(says ${pair#agents=}, is $real_agents)" ;;
    esac
  done
done < <(grep -rhoE 'dotagents:skill-count [a-z0-9= ]+' "$REPO/README.md" "$REPO/AGENTS.md" 2>/dev/null \
         | sed 's/dotagents:skill-count //')
if (( count_seen < 2 )); then
  err "skill-count" "fewer than 2 'dotagents:skill-count' markers -- README.md and AGENTS.md both state these numbers in prose, and an unmarked sentence goes stale without failing"
elif [[ -n "$count_bad" ]]; then
  err "skill-count" "the counts written in prose no longer match the directories:$count_bad -- adding or removing a skill changes sentences in two files, and both still read correctly when wrong"
else
  printf '%s✓%s the prose counts match: %s skills, %s typed, %s layer, %s agents\n' \
    "$c_green" "$c_off" "$real_mine" "$real_typed" "$real_layer" "$real_agents"
fi

# --- skill bodies must not instruct reading credentials or piping to a shell ---
# The frontmatter has been gated since the beginning; the body never was. And the body is not data --
# it is the instructions an agent follows, in the user's own repositories, with the user's own
# permissions. One sentence of prose is a behaviour change whose intent no linter, type check or test
# can see. The lint hook says the same thing at write time and only warns; this is the half that fails
# closed, and it runs over this repository's own skills, where we do get to decide.
#
# Two shapes, chosen by measurement rather than imagination: a credential surface named on the same
# line as a read/send verb, and the pipe-to-shell / base64 / paste-site shapes. Both were run against
# every existing skill body and reference file first and matched ZERO lines, which is why this can be
# an error with no baseline, no diff and no allowlist to maintain. A check keyed on a merge-base would
# also need a full clone, and the CI jobs that run this one are shallow.
#
# The escape hatch names a reason on the line itself. "Allow this" with no reason is how an allowlist
# becomes the rule.
#
# Kept identical to the list in hooks/dotagents-lint-skill-frontmatter.sh. The pattern is read out of
# the marker comment below rather than written twice here, so the thing being compared is the thing
# being used.
# dotagents:sensitive-body-patterns (cat|read|open|curl|wget|send|post|upload|include|echo)[^.]{0,40}(~/\.aws|~/\.ssh|\.env\b|id_rsa|\.netrc|credentials|keychain)|(~/\.aws|~/\.ssh|\.env\b|id_rsa|\.netrc|credentials|keychain)[^.]{0,40}(を読|を送|に送|include|report)|\|\s*(ba)?sh\b|base64\s+-d|nc\s+-|webhook\.site|pastebin
echo
echo "checking skill bodies for credential surfaces and pipe-to-shell shapes"
sens_line() { grep -o 'dotagents:sensitive-body-patterns.*' "$1" | head -1 | sed 's/^dotagents:sensitive-body-patterns *//'; }
sens_pat="$(sens_line "$0")"
if [[ -z "$sens_pat" ]]; then
  err "sensitive-body" "the 'dotagents:sensitive-body-patterns' marker is missing from verify-skills.sh -- the marker IS the pattern, so removing it removes the check"
else
  sens_hits=0
  for sroot in "${ROOTS[@]}"; do
    [[ -d "$sroot" ]] || continue
    while IFS= read -r sf; do
      while IFS= read -r hit; do
        [[ -n "$hit" ]] || continue
        case "$hit" in *dotagents:allow-sensitive*) continue ;; esac
        err "${sf#"$REPO/"}:${hit%%:*}" "skill body names a credential surface or a pipe-to-shell shape -- $(printf '%s' "${hit#*:}" | sed 's/^[[:space:]]*//' | cut -c1-100)"
        sens_hits=$((sens_hits+1))
      done < <(grep -niE "$sens_pat" "$sf" 2>/dev/null)
    done < <(find "$sroot" -type f -name '*.md' 2>/dev/null | sort)
  done
  (( sens_hits == 0 )) \
    && printf '%s✓%s no skill body instructs reading credentials or piping to a shell\n' "$c_green" "$c_off"
fi

# --- the two sensitive-body enforcers must agree ----------------------------
# Same reasoning as the when-clause lists below: two copies of a rule that can disagree is a rule that
# will. The hook is the one users meet while writing; this file is the one that blocks a commit.
lint_hook_sens="$REPO/hooks/dotagents-lint-skill-frontmatter.sh"
if [[ -f "$lint_hook_sens" ]]; then
  echo
  echo "checking the sensitive-body pattern list"
  sens_b="$(sens_line "$lint_hook_sens")"
  if [[ -z "$sens_b" ]]; then
    err "sensitive-body" "the 'dotagents:sensitive-body-patterns' marker is missing from the lint hook -- the marker is what makes the two lists comparable, so removing it removes the check"
  elif [[ "$sens_pat" != "$sens_b" ]]; then
    err "sensitive-body" "the linter and the lint hook look for different things in a skill body, so a body can pass one and be stopped by the other"
    printf '%s  linter: %s%s\n' "$c_dim" "$sens_pat" "$c_off"
    printf '%s  hook:   %s%s\n' "$c_dim" "$sens_b" "$c_off"
  else
    printf '%s✓%s both enforcers look for the same shapes in a skill body\n' "$c_green" "$c_off"
  fi
fi

# --- every relative link inside a skill has to resolve ----------------------
# reference/ files are read on instruction, so a link that does not resolve is not a 404 the user
# sees -- it is an instruction the agent was told to follow and could not. The skill still loads,
# still produces a normal-looking report, and the part it lost is exactly the part someone thought
# was worth writing down separately.
#
# Found by running this: `_shared/finding-discipline.md` links to a sibling `verification.md`, and it
# is symlinked into six skills of which only four had that sibling. da-fix-plan and da-review-all
# followed a dead link. CI already checks that SYMLINKS resolve, which is why this went unseen for so
# long -- the broken thing was a markdown link, and nothing read those.
#
# Anchors, http(s) and mailto are skipped. Everything else is resolved from the linking file's own
# directory, because that is how both agents resolve a reference path (Cursor has no
# ${CLAUDE_SKILL_DIR}, so relative-from-the-file is the only spelling that works in both).
echo
echo "checking relative links inside skills resolve"
link_bad=0
for lroot in "${ROOTS[@]}"; do
  [[ -d "$lroot" ]] || continue
  while IFS= read -r lf; do
    ldir="$(dirname "$lf")"
    while IFS= read -r target; do
      [[ -n "$target" ]] || continue
      case "$target" in http://*|https://*|mailto:*|"#"*) continue ;; esac
      target="${target%%#*}"            # strip an anchor
      target="${target%% *}"            # strip a link title
      [[ -n "$target" ]] || continue
      [[ -e "$ldir/$target" ]] || {
        err "${lf#"$REPO/"}" "link does not resolve: $target -- reference/ is read on instruction, so this is an instruction the agent cannot follow"
        link_bad=$((link_bad+1))
      }
    done < <(grep -o ']([^)]*)' "$lf" 2>/dev/null | sed 's/^](//;s/)$//')
    # `-type l` as well as `-type f`, and this is load-bearing: `find -type f` tests the LINK, not its
    # target, so it skips every symlink -- which is every file under a skill's reference/. Written with
    # `-type f` alone, this check reported a green tick while examining only `_shared/` (where the
    # sibling does exist) and never looking at the six skills that read it through a link. The first
    # version of the check had the exact bug it was written to catch.
  done < <(find "$lroot" \( -type f -o -type l \) -name '*.md' 2>/dev/null | sort)
done
(( link_bad == 0 )) \
  && printf '%s✓%s every relative link inside a skill resolves\n' "$c_green" "$c_off"

# --- and the other direction: every doc has to be reachable ------------------
# The check above asks whether a link finds its file. This asks whether a file has a link, which is the
# failure the other one cannot see: a document nobody references is not broken, it is invisible. Same
# both-directions shape already applied to reference/ files above, where mention-without-file and
# file-without-mention are both errors.
#
# README.md and AGENTS.md are the two entry points, and between them they are the only pair that
# reaches both agents: Claude Code reads AGENTS.md through the CLAUDE.md symlink, Cursor reads it
# natively, and README is where a human starts. A doc linked from neither is one that exists only for
# whoever already knew the path.
echo
echo "checking every doc is reachable from README or AGENTS.md"
doc_bad=0
if [[ -d "$REPO/docs" ]]; then
  index="$(cat "$REPO/README.md" "$REPO/AGENTS.md" 2>/dev/null)"
  for df in "$REPO"/docs/*.md; do
    [[ -e "$df" ]] || continue
    rel="docs/$(basename "$df")"
    grep -qF "$rel" <<<"$index" || {
      err "$rel" "not linked from README.md or AGENTS.md -- a doc nobody references is a doc nobody finds, and neither the link check nor CI can see it"
      doc_bad=$((doc_bad+1))
    }
  done
fi
(( doc_bad == 0 )) \
  && printf '%s✓%s every docs/*.md is linked from README.md or AGENTS.md\n' "$c_green" "$c_off"

# --- a skill that names another skill must be able to reach it ---------------
# Three of these were live on this machine at once, and all three failed the same silent way: the
# referring skill loads, its description shows in the menu, it runs, and the instruction it was built
# around points at nothing.
#
#   grill-me             -> /grilling                                    (body is ONLY that line)
#   executing-plans      -> superpowers:finishing-a-development-branch   (declared REQUIRED SUB-SKILL)
#   systematic-debugging -> superpowers:verification-before-completion
#
# The first one is the reason this check exists rather than being a nice idea: `/grill-me` is the FIRST
# ENTRY in README's use-case 1, so the documented way to start a feature pointed at a skill that was
# never installed. A recommendation that cannot run is the same shape as a guardrail that does not
# guard -- worse than an absent one, because nobody goes looking.
#
# Scans the INSTALLED set, not this repository: the dangling references were all in upstream bodies,
# which never appear under skills/ here. Skipped with a printed reason when that directory is absent,
# because CI has no installed skills and a check that silently does nothing is the thing being fixed.
#
# dotagents:builtin-slash-commands clear login logout help doctor config hooks permissions review security-review simplify code-review run init loop goal schedule skill-doctor compact resume model agents mcp memory export bug cost status context usage sandbox privacy-settings rewind todos output-style statusline feedback plugin workflows fast effort tasks add-dir ide vim terminal-setup install-github-app pr-comments upgrade release-notes migrate-installer
#
# That allowlist is built-in commands, which are NOT skills and never resolve to a directory. It will
# need an entry when a new one ships, and the failure direction is deliberate: a missing entry is one
# loud false error, not a silent hole. The list is data on a marker line for the same reason the
# disable-model-invocation scope is -- so the behaviour is driven by something greppable.
echo
echo "checking every skill a skill names can be reached"
INSTALLED="${DOTAGENTS_INSTALLED_SKILLS:-$HOME/.agents/skills}"
if [[ ! -d "$INSTALLED" ]]; then
  printf '%s—%s no installed skills at %s -- skipped (this runs on a machine, not in CI)\n' \
    "$c_dim" "$c_off" "$INSTALLED"
else
  builtins="$(grep -m1 'dotagents:builtin-slash-commands' "${BASH_SOURCE[0]}" \
              | sed 's/.*dotagents:builtin-slash-commands //')"
  ref_bad=0
  for sf in "$INSTALLED"/*/SKILL.md; do
    [[ -e "$sf" ]] || continue
    from="$(basename "$(dirname "$sf")")"
    body="$(awk 'NR==1&&$0=="---"{i=1;next} i&&$0=="---"{i=0;next} !i' "$sf")"
    # `superpowers:skill-name` and `/skill-name`. Both forms appeared in the three real cases.
    # `anthropic-skills:` is deliberately NOT followed: that is a plugin namespace, and plugin skills
    # are not directories under the installed set -- da-skills-audit names anthropic-skills:skill-creator,
    # which is reachable and was reported as missing by the first version of this check.
    while read -r ref; do
      [[ -n "$ref" ]] || continue
      [[ "$ref" == "$from" ]] && continue                      # a skill naming itself
      printf '%s\n' $builtins | grep -qx "$ref" && continue    # a built-in command, not a skill
      [[ -d "$INSTALLED/$ref" ]] && continue
      err "$from" "names the skill '$ref', which is not installed -- the instruction built around it points at nothing. Install it: npx skills@1.5.20 add <owner>/<repo> -g -a claude-code -a cursor -s $ref"
      ref_bad=$((ref_bad+1))
    done < <( {
      printf '%s\n' "$body" \
        | grep -oE '(^|[^a-zA-Z0-9_./-])superpowers:[a-z][a-z0-9]*(-[a-z0-9]+)+' \
        | sed 's/.*://'
      printf '%s\n' "$body" \
        | grep -oE '(^|[^a-zA-Z0-9_./`-])/[a-z][a-z0-9]*(-[a-z0-9]+)+' \
        | sed 's|.*/||'
      printf '%s\n' "$body" \
        | grep -oE '`/[a-z][a-z0-9]*(-[a-z0-9]+)+`' | tr -d '`' | sed 's|^/||'
    } | sort -u )
  done
  (( ref_bad == 0 )) \
    && printf '%s✓%s every skill named by an installed skill resolves\n' "$c_green" "$c_off"
fi

# --- the upstream skills status reports on must still be documented ---------
# `setup.sh status` reports which upstream skills the documented flows need and do not have. That list
# is only useful while it names the skills README.md actually tells you to install: an upstream rename
# would leave status checking for a name nobody documents, reporting a missing skill that no longer
# exists under that name and staying quiet about the one that replaced it. Same failure shape as the
# when-clause lists -- an enforcer that has drifted from what it enforces, printing a green tick.
setup_sh="$REPO/scripts/setup.sh"
if [[ -f "$setup_sh" ]]; then
  echo
  echo "checking the upstream flow skills are documented"
  up_line="$(grep -o 'dotagents:upstream-flow-skills.*' "$setup_sh" | head -1 | sed 's/^dotagents:upstream-flow-skills *//')"
  if [[ -z "$up_line" ]]; then
    err "upstream-flow" "the 'dotagents:upstream-flow-skills' marker is missing from scripts/setup.sh -- the marker is what makes the list checkable, so removing it removes the check"
  else
    up_undocumented=""
    for up in $up_line; do
      grep -q -- "$up" "$REPO/README.md" || up_undocumented="$up_undocumented $up"
    done
    if [[ -n "$up_undocumented" ]]; then
      err "upstream-flow" "status reports on skills README.md never mentions:$up_undocumented -- either document how to install them, or stop reporting them"
    else
      printf '%s✓%s every upstream skill status reports on is named in README.md\n' "$c_green" "$c_off"
    fi
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
    # that comes back the next time someone measures cost. Note this is NOT a Claude-only field the way
    # skill `model:` is: Cursor reads name/description/model/readonly/is_background on a subagent and
    # defaults to `inherit` too, so a pin overrides the user in both agents. Take cost out of how MANY
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
