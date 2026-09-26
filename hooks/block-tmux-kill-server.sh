#!/usr/bin/env bash
HOUSE_RULES_HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
. "$HOUSE_RULES_HOOK_DIR/lib/hook-tools.sh"
house_rules_require jq
# PreToolUse: Bash
# Blocks tmux kill-server which nukes all sessions without warning.

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // empty')

if echo "$cmd" | grep -qE '(^|[^[:alnum:]_-])tmux[[:space:]]+kill-server([^[:alnum:]_-]|$)'; then
  echo "Blocked: tmux kill-server destroys all sessions. Get explicit approval from the user first." >&2
  exit 2
fi

exit 0
