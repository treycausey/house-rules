#!/usr/bin/env bash
# Stop hook
# When Claude stops with uncommitted full-stack changes, reminds to verify
# the user-visible flow in the browser before claiming done.
#
# Catches: "tests pass but UI broken" (5-bug batch in stash),
# partial fixes that only hit one callsite, backend-frontend contract drift.

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
    callsites=$(grep -rl --include='*.py' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' "$fn" "$repo_root/src" "$repo_root/app" "$repo_root/apps" "$repo_root/backend" "$repo_root/frontend" 2>/dev/null | wc -l || true)
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
  # Escape for JSON
  json_reminders=$(printf '%b' "$reminders" | sed 's/"/\\"/g' | tr '\n' ' ')
  echo "{\"additionalContext\": \"$json_reminders\"}"
fi

exit 0
