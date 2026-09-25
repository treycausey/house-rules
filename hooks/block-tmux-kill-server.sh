#!/usr/bin/env bash
# PreToolUse: Bash
# Blocks tmux kill-server which nukes all sessions without warning.

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // empty')

if echo "$cmd" | grep -qE 'tmux\s+kill-server'; then
  echo "Blocked: tmux kill-server destroys all sessions. Get explicit approval from the user first." >&2
  exit 2
fi

exit 0
