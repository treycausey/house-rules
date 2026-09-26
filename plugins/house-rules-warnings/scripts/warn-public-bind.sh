#!/usr/bin/env bash
HOUSE_RULES_HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
. "$HOUSE_RULES_HOOK_DIR/lib/hook-tools.sh"
house_rules_require jq
# PreToolUse: Bash
# Adds context to dev server commands that bind to 0.0.0.0 (all interfaces).
#
# Binding to all interfaces can expose a development service and local files to
# every network that can reach the machine. This hook advises; it does not block.
#
# SCOPE NOTE: this hook covers the BIND side only. The other half of the
# original proposal -- flagging a reachability claim verified only from
# localhost -- lives in
# warn-localhost-verify.sh (PostToolUse Bash, tested in tests/run-tests.sh).
# Three weekly reviews in a row reported that check as "still unapplied"
# after reading only this file. Look there before re-proposing it.

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // empty')

is_dev_server=false
case "$cmd" in
  *"run dev"*|*"run start"*|*"next dev"*|*"vite"*|*"flask run"*|*"uvicorn "*|*"gunicorn "*|*"python -m http.server"*|*"python3 -m http.server"*|*"live-server"*|*"serve "*|*"dev --"*|*"start --"*)
    is_dev_server=true
    ;;
esac

if [ "$is_dev_server" = false ]; then
  exit 0
fi

message=""
if printf '%s' "$cmd" | grep -qE '(--host[= ]*0\.0\.0\.0)|(--bind[= ]*0\.0\.0\.0)|(-b[= ]*0\.0\.0\.0)|(-H[= ]*0\.0\.0\.0)|hostname["'"'"']?[:= ]+["'"'"']?0\.0\.0\.0'; then
  message="This development server binds to 0.0.0.0, so it accepts connections on all network interfaces. Bind to 127.0.0.1 or the specific interface that needs access. Use an authenticated proxy for remote access."
elif printf '%s' "$cmd" | grep -qE 'python3?(\.[0-9]+)? -m http\.server' && ! printf '%s' "$cmd" | grep -qE '\-\-bind|\-b '; then
  message="Python's http.server binds to all interfaces by default and serves the working directory, including dotfiles. Pass --bind 127.0.0.1 or use a server with an explicit access policy."
fi

if [ -n "$message" ]; then
  jq -n --arg context "$message" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$context}}'
fi

exit 0
