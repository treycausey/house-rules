#!/usr/bin/env bash
HOUSE_RULES_HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
. "$HOUSE_RULES_HOOK_DIR/lib/hook-tools.sh"
house_rules_require jq
# PostToolUseFailure: Bash
# PostToolUse fires only when a tool call SUCCEEDS, so a failure counter wired
# there never saw a single failure. PostToolUseFailure is the event that fires
# on a failed call, with the same input shape.
# Tracks failed commands and warns after 3+ similar failures.
# Enforces the CLAUDE.md Debugging rule (state the failure mechanism before
# another attempt) mechanically.

input=$(cat)
exit_code=$(echo "$input" | jq -r '.tool_result.exit_code // .tool_response.exit_code // 0')

# Only track failures
[ "$exit_code" = "0" ] && exit 0

cmd=$(echo "$input" | jq -r '.tool_input.command // empty')
stderr=$(echo "$input" | jq -r '.tool_result.stderr // .tool_response.stderr // empty')

# Extract an error signature: first non-empty stderr line, or "exit $code"
sig=$(echo "$stderr" | grep -v '^$' | head -1 | cut -c1-120)
[ -z "$sig" ] && sig="exit-code-$exit_code"

# Normalize: strip paths, line numbers, PIDs to group similar errors
sig=$(echo "$sig" | sed -E 's|/[^ ]+/||g; s/[0-9]{3,}/#/g; s/line [0-9]+/line #/g')

# Key the tracker by SESSION, not by $$. Each hook invocation is its own
# process, so a `$$`-keyed path was a brand new file every time and the count
# never reached 2, let alone 3 -- the warning could not fire at all.
sid=$(echo "$input" | jq -r '.session_id // empty')
data_dir="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}/house-rules-retry}"
if ! mkdir -p "$data_dir" 2>/dev/null; then
  printf 'house-rules: retry counter skipped; cannot create its state directory\n' >&2
  exit 0
fi
umask 077
sid=$(printf '%s' "$sid" | tr -cd 'A-Za-z0-9._-')
[ -n "$sid" ] || sid=unknown
if [ -n "$sid" ]; then
  tracker="$data_dir/retry-${sid}.log"
else
  tracker="$data_dir/retry-unknown.log"
fi

# Clean entries older than 10 minutes
if [ -f "$tracker" ]; then
  now=$(date +%s)
  tmpf="${tracker}.tmp.$$"
  : > "$tmpf" || {
    printf 'house-rules: retry counter skipped; cannot refresh its state file\n' >&2
    exit 0
  }
  while IFS='|' read -r ts s; do
    age=$((now - ts))
    [ "$age" -lt 600 ] && echo "${ts}|${s}" >> "$tmpf"
  done < "$tracker"
  if ! mv "$tmpf" "$tracker" 2>/dev/null; then
    rm -f "$tmpf"
    printf 'house-rules: retry counter skipped; cannot update its state file\n' >&2
    exit 0
  fi
fi

# Append current failure
echo "$(date +%s)|${sig}" >> "$tracker"

# Count matching signatures in the last 10 minutes
count=$(grep -cF "|${sig}" "$tracker" 2>/dev/null || echo 0)

if [ "$count" -ge 3 ]; then
  echo '{"hookSpecificOutput": {"hookEventName": "PostToolUseFailure", "additionalContext": "Three or more failures with a similar error pattern in the last 10 minutes. Stop retrying: state the failure mechanism in one falsifiable sentence, then check the docs, installed source, or --help before the next attempt."}}'
  # Reset counter so the warning doesn't fire on every subsequent command.
  # `;` not `&&`: when EVERY line matches the signature -- the normal case
  # right after warning -- grep -v prints nothing and exits 1, so an `&& mv`
  # never ran. The tracker kept its 3 entries, the warning fired again on the
  # next failure, and a stray .tmp file was left behind each time. Unreachable
  # until the tracker started accumulating at all.
  if ! grep -vF "|${sig}" "$tracker" > "${tracker}.tmp" 2>/dev/null; then
    # No remaining matches is the normal reset case. The redirection still
    # creates the empty tracker file.
    :
  fi
  if ! mv "${tracker}.tmp" "$tracker" 2>/dev/null; then
    rm -f "${tracker}.tmp"
    printf 'house-rules: retry counter warning was sent, but its state could not be reset\n' >&2
  fi
fi

exit 0
