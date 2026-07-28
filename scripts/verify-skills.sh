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
  # programmatic Skill calls and subagent preloading -- with no error. See docs/adr/0005.
  # Match on $name, not $id -- $id is "skills/<name>" and a bare case pattern never matches it.
  if has_frontmatter_key "$skill" disable-model-invocation; then
    case "$name" in
      # /verify is the only thing that runs `gate.sh arm`. Without auto-invocation the Stop gate
      # never arms and passes every turn: the guardrail opens instead of closing.
      verify)
        err "$id" "must never set 'disable-model-invocation' -- it is the only thing that runs 'gate.sh arm', so the Stop gate would never arm and would pass every turn (fails OPEN)" ;;
      # review-all dispatches to these three by name via a subagent.
      review-backend|review-frontend|review-infra)
        err "$id" "is a by-name dispatch target of review-all -- 'disable-model-invocation' blocks programmatic Skill calls and subagent preload, so review-all would report this layer as covered while reviewing nothing" ;;
      *)
        : ;;  # legitimate: user-invocable only, zero budget cost, nothing dispatches to it
    esac
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
      err "$id" "declares 'allowed-tools' but the body never states the restriction -- unenforced in Cursor (see docs/adr/0003)"
    else
      warn "$id" "declares 'allowed-tools' but the body never states the restriction -- that constraint does not exist in Cursor"
    fi
  fi

  # A skill whose body dispatches to subagents but whose allowed-tools omits Task has been
  # forbidden from doing the thing it exists to do -- by an optimization, which ADR 0003 says must
  # never be the mechanism. Silent in Cursor, and a permission prompt in Claude.
  if has_frontmatter_key "$skill" allowed-tools \
     && grep -qiE 'parallel subagents|dispatch (them|the)|Task tool|launch .*subagent' <<<"$body" \
     && ! grep -qE '^allowed-tools:.*\bTask\b' <<<"$(frontmatter_value "$skill" allowed-tools | sed 's/^/allowed-tools: /')"; then
    err "$id" "the body dispatches to subagents but 'allowed-tools' omits Task -- the skill cannot do what it describes"
  fi

  if has_frontmatter_key "$skill" context; then
    grep -qiE 'subagent|sub-agent|Task tool|separate context|fresh context' <<<"$body" \
      || err "$id" "declares 'context:' but the body never says to run in a subagent -- ignored in Cursor (see docs/adr/0003)"
  fi

  # --- provenance ------------------------------------------------------------
  # Installed globally, ours sit among two dozen third-party skills. Without a marker there is no
  # way to answer "which of these am I responsible for" -- not for a person reading /skills, and
  # not for skills-audit deciding what it may propose removing.
  # Only for skills in this repository. Run over an install directory -- which skills-audit tells you
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
    if grep -qE '(^|[^/${])reference/[a-z0-9_-]+\.md' <<<"$body" \
       && ! grep -q 'CLAUDE_SKILL_DIR' <<<"$body"; then
      err "$id" "references reference/*.md by relative path -- use \${CLAUDE_SKILL_DIR}/reference/... so subagents can resolve it"
    fi
    local ref
    for ref in "$dir"/reference/*; do
      [[ -f "$ref" ]] || continue
      grep -qF "$(basename "$ref")" <<<"$body" \
        || warn "$id" "reference/$(basename "$ref") is never mentioned in SKILL.md"
    done
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
    [[ "$(basename "$dir")" == _* ]] && continue   # _template, _shared
    check_skill "${dir%/}"
  done
done

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
    # Cursor reads name/description/model/readonly only, so a tool restriction expressed solely in
    # `tools:` is absent there. The body must state it too.
    if grep -q '^tools:' <<<"$afm"; then
      abody="$(awk 'NR==1&&$0=="---"{i=1;next} i&&$0=="---"{i=0;next} !i' "$af")"
      grep -qiE 'read-only|never modify|do not modify' <<<"$abody" \
        || warn "agents/$aid" "declares 'tools:' but the body never states the restriction -- Cursor ignores 'tools:'"
    fi
  done
  # Every agent named by a skill must exist, or the dispatch degrades with no error.
  while read -r ref; do
    [[ -n "$ref" ]] || continue
    [[ " $agent_defs " == *" $ref "* ]] && continue
    err "agents" "skills dispatch to '$ref' but agents/$ref.md does not exist -- the caller silently falls back to general-purpose"
  done < <(grep -rhoE '\b(review-verifier|codebase-explorer)\b' "$REPO"/skills/*/SKILL.md "$REPO"/skills/_shared/*.md 2>/dev/null | sort -u)
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
