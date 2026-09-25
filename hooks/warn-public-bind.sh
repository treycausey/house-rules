#!/usr/bin/env bash
# PreToolUse: Bash
# Blocks dev server commands that bind to 0.0.0.0 (all interfaces).
#
# Policy changed after a security audit. Previously this hook enforced the
# opposite: bind 0.0.0.0 so other devices could reach dev servers over Tailscale.
# That also exposed every dev server to the whole home LAN with no firewall and,
# in most cases, no auth. A `python -m http.server` in one side project served that
# project's .env -- a mail token, a shipping API secret, an LLM API key -- to any
# device on the network for ten days before it was found.
#
# The replacement gives the same cross-device access without the LAN exposure:
# bind 127.0.0.1, then publish to the tailnet only via `tailscale serve`.
# Tailnet clients keep using the same host:port they used before.
#
# SCOPE NOTE: this hook covers the BIND side only. The other half of the
# original proposal -- flagging a reachability claim that was verified
# from localhost when the claim is about LAN/tailnet access -- lives in
# warn-localhost-verify.sh (PostToolUse Bash, tested in tests/run-tests.sh).
# Three weekly reviews in a row reported that check as "still unapplied"
# after reading only this file. Look there before re-proposing it.

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // empty')

# `tailscale serve` targets are written as tcp://127.0.0.1:PORT and must not trip
# this hook, nor should anything that is merely inspecting the serve config.
case "$cmd" in
  *"tailscale serve"*|*"tailscale funnel"*) exit 0 ;;
esac

is_dev_server=false
case "$cmd" in
  *"run dev"*|*"run start"*|*"next dev"*|*"vite"*|*"flask run"*|*"uvicorn "*|*"gunicorn "*|*"python -m http.server"*|*"python3 -m http.server"*|*"live-server"*|*"serve "*|*"dev --"*|*"start --"*)
    is_dev_server=true
    ;;
esac

if [ "$is_dev_server" = false ]; then
  exit 0
fi

if echo "$cmd" | grep -qE '(--host[= ]*0\.0\.0\.0)|(--bind[= ]*0\.0\.0\.0)|(-b[= ]*0\.0\.0\.0)|(-H[= ]*0\.0\.0\.0)|hostname["'"'"']?[:= ]+["'"'"']?0\.0\.0\.0'; then
  echo "Blocked: dev server is binding to 0.0.0.0, which exposes it to the entire home LAN (the firewall is not a backstop here). Bind to 127.0.0.1 instead, then publish to the tailnet with: tailscale serve --bg --tcp=<port> tcp://127.0.0.1:<port>" >&2
  exit 2
fi

# `python -m http.server` binds all interfaces by default, with no flag to see.
if echo "$cmd" | grep -qE 'python3?(\.[0-9]+)? -m http\.server' && ! echo "$cmd" | grep -qE '\-\-bind|\-b '; then
  echo "Blocked: 'python -m http.server' binds 0.0.0.0 by default and serves the whole working directory, including dotfiles such as .env and .git. Pass --bind 127.0.0.1 explicitly." >&2
  exit 2
fi

exit 0
