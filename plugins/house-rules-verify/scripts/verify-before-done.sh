#!/usr/bin/env bash
HOUSE_RULES_HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
. "$HOUSE_RULES_HOOK_DIR/lib/hook-tools.sh"
house_rules_require jq
# Stop hook
# When Claude stops with uncommitted full-stack changes, reminds to verify
# the user-visible flow in the browser before claiming done.
#
# Catches: "tests pass but UI broken" (5-bug batch in stash),
# partial fixes that only hit one callsite, backend-frontend contract drift.
#
# Reads the Stop event's stdin JSON for two reasons:
#   - `stop_hook_active` is true when this run is a continuation the Stop
#     event's own additionalContext/decision:block caused, not a fresh stop
#     attempt. Without checking it, a still-uncommitted change keeps
#     re-triggering the SAME reminder on every subsequent stop attempt,
#     forcing continuation after continuation until the harness's own
#     8-consecutive-continuation cap cuts it off. Exit 0 immediately then.
#   - `session_id` keys a small per-session state file (a hash of the
#     changed-file list) so the SAME reminder does not repeat once Claude
#     has already seen it and is choosing to stop anyway with the same
#     files still uncommitted; a genuinely different set of changed files
#     resets the hash and reminds again.

input=$(cat)
stop_hook_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false')
[ "$stop_hook_active" = "true" ] && exit 0
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')

hr_hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    cksum | awk '{print $1 "-" $2}'
  fi
}

# Must be in a git repo
repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# Count uncommitted changes by layer (staged + unstaged vs HEAD, deduplicated)
changed=$( (git diff --name-only HEAD 2>/dev/null; git diff --name-only --cached 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null) | sort -u)
[ -z "$changed" ] && exit 0

backend=$(echo "$changed" | grep -cE '\.(py|rs|go)$' || true)
frontend=$(echo "$changed" | grep -cE '\.(tsx?|jsx?|svelte|vue)$' || true)
server_config=$(echo "$changed" | grep -cE '(server|app|main)\.(ts|py|rs)$' || true)

reminders=""

# ── Full-stack change: verify the flow ─────────────────────────────
if [ "$backend" -gt 0 ] && [ "$frontend" -gt 0 ]; then
  reminders="${reminders}VERIFY: You changed both backend ($backend files) and frontend ($frontend files). Before committing, trace the full user-visible flow in the browser via agent-browser or screenshot. Passing unit tests do not prove the user-visible flow works; a backend/frontend contract can drift while both suites pass.\n\n"
fi

# ── Server file changed: check timeout config ─────────────────────
if [ "$server_config" -gt 0 ]; then
  # Check for Bun.serve without idleTimeout (caused the sprite-gen 503)
  for f in $(echo "$changed" | grep -E '(server|app|main)\.(ts|js)$'); do
    full="$repo_root/$f"
    [ -f "$full" ] || continue
    if grep -q 'Bun\.serve\|\.listen\|createServer' "$full" 2>/dev/null; then
      if ! grep -q 'idleTimeout\|timeout\|keepAliveTimeout' "$full" 2>/dev/null; then
        reminders="${reminders}VERIFY: $f creates a server but has no explicit timeout config. Bun defaults to 10s idleTimeout. If any endpoint takes >10s (LLM calls, image generation), requests will 503. Set idleTimeout explicitly.\n\n"
      fi
    fi
  done
fi

# ── Cross-cutting fix check ────────────────────────────────────────
# If only 1-2 files changed but they modify a utility/helper function,
# warn about sibling callsites. (Catches the timezone partial-fix pattern.)
if [ "$backend" -le 2 ] && [ "$backend" -gt 0 ]; then
  # Get function names that were modified (added/removed lines containing def/function)
  funcs=$(git diff HEAD 2>/dev/null | grep -E '^\+.*(def |function |const .* = )' | sed -E 's/.*def ([a-zA-Z_]+).*/\1/; s/.*function ([a-zA-Z_]+).*/\1/; s/.*const ([a-zA-Z_]+).*/\1/' | sort -u | head -5)
  for fn in $funcs; do
    # Skip common/generic names
    case "$fn" in
      main|app|test|setup|config|init|run|start|stop|get|set|put|post|delete|patch|handle|create|update|remove|list) continue ;;
    esac
    search_roots=()
    for candidate in "$repo_root/src" "$repo_root/app" "$repo_root/apps" "$repo_root/backend" "$repo_root/frontend"; do
      [ -d "$candidate" ] && search_roots+=("$candidate")
    done
    if [ ${#search_roots[@]} -gt 0 ]; then
      callsites=$(find "${search_roots[@]}" -type f \( -name '*.py' -o -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \) -exec grep -lF "$fn" {} + 2>/dev/null | wc -l || true)
    else
      callsites=0
    fi
    if [ "$callsites" -gt 2 ]; then
      reminders="${reminders}VERIFY: You modified '$fn' which appears in $callsites files. If this is a behavior change (formatting, timezone, validation), check all callsites so the fix lands everywhere the function is used.\n\n"
    fi
  done
fi

# ── Near-duplicate sibling scripts ─────────────────────────────────
# Editing foo.sh while foo-old.sh / foo2.py sits beside it risks fixing the
# copy that never runs. Warn when a changed script has a sibling whose name
# is the same stem plus a version-ish suffix (or vice versa).
dupes=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    *.test.*|*.spec.*|*.d.ts|*.stories.*|*.min.*) continue ;;
    *.sh|*.py|*.ts|*.js) ;;
    *) continue ;;
  esac
  base=${f##*/}
  if [ "$f" = "$base" ]; then dir="$repo_root"; else dir="$repo_root/${f%/*}"; fi
  [ -d "$dir" ] || continue
  stem=${base%.*}
  for sib in "$dir"/*; do
    [ -f "$sib" ] || continue
    sbase=${sib##*/}
    [ "$sbase" = "$base" ] && continue
    case "$sbase" in
      *.test.*|*.spec.*|*.d.ts|*.stories.*|*.min.*) continue ;;
      *.sh|*.py|*.ts|*.js) ;;
      *) continue ;;
    esac
    sstem=${sbase%.*}
    match=0
    case "$sstem" in "$stem"[-_.0-9]*) match=1 ;; esac
    case "$stem" in "$sstem"[-_.0-9]*) match=1 ;; esac
    [ "$match" -eq 1 ] && dupes="${dupes}${base} <-> ${sbase}; "
  done
done <<EOF
$changed
EOF
if [ -n "$dupes" ]; then
  reminders="${reminders}VERIFY: changed scripts have near-duplicate siblings: ${dupes}confirm the file you edited is the one that actually runs, not a stale copy.\n\n"
fi

if [ -n "$reminders" ]; then
  # Emit at most once per state: a hash of the changed-file list, stored
  # per session, so the same reminder does not repeat while the same files
  # stay uncommitted, but a genuinely different change set reminds again.
  #
  # The state directory is never a bare /tmp fallback: /tmp is shared by
  # every user and session on the machine, so a bare-/tmp state dir is a
  # symlink-planting / predictable-path target for another user or process.
  # $HOME/.cache is the fallback instead, created with mode 700 (set via
  # umask BEFORE mkdir -- setting it after, as a previous version did,
  # leaves the directory created under the inherited umask first).
  state_hash=$(printf '%s' "$changed" | hr_hash)
  data_dir="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-$HOME/.cache}}/house-rules-verify"
  emit=1
  if (umask 077 && mkdir -p "$data_dir") 2>/dev/null && chmod 700 "$data_dir" 2>/dev/null; then
    sid=$(printf '%s' "$session_id" | tr -cd 'A-Za-z0-9._-')
    [ -n "$sid" ] || sid=unknown
    state_file="$data_dir/verify-before-done-${sid}.state"
    prev=""
    # Only trust a REGULAR file at this path as prior state. A symlink here
    # (pre-planted by another user sharing $data_dir's parent, or left over
    # from an attack) is never followed for reading; the write below
    # replaces it with a real file via mktemp + mv rather than truncating
    # through it.
    if [ -f "$state_file" ] && [ ! -L "$state_file" ]; then
      prev=$(cat "$state_file" 2>/dev/null || true)
    fi
    if [ "$prev" = "$state_hash" ]; then
      emit=0
    else
      tmp_state=$(mktemp "$data_dir/.verify-before-done-${sid}.XXXXXX" 2>/dev/null) || tmp_state=""
      if [ -n "$tmp_state" ]; then
        printf '%s' "$state_hash" > "$tmp_state" 2>/dev/null
        mv -f "$tmp_state" "$state_file" 2>/dev/null || rm -f "$tmp_state" 2>/dev/null
      fi
    fi
  fi
  # emit=1 by default (including when the state directory could not be
  # created at all): fail toward reminding rather than silently dropping a
  # warning we cannot dedupe.
  if [ "$emit" = "1" ]; then
    json_reminders=$(printf '%b' "$reminders" | tr '\n' ' ')
    jq -n --arg c "$json_reminders" \
      '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $c}}'
  fi
fi

exit 0
