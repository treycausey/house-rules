#!/usr/bin/env bash
# PostToolUse: Bash
# Non-blocking nudge: a reachability probe against localhost/127.0.0.1 verifies
# only the local loopback, but the claim being verified is usually "the tailnet
# device can reach it" (tvOS app, phone, another machine). Two weekly
# reviews in a row flagged reachability claims made from a localhost curl.
# This hook never blocks — curling localhost is legitimate constantly. It only
# attaches a reminder so the false "reachable" claim doesn't get written.

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // empty')

[ -z "$cmd" ] && exit 0

# Only probe-shaped commands: curl / wget / nc. Config commands that merely
# mention 127.0.0.1 (tailscale serve targets, server binds) must not fire.
echo "$cmd" | grep -qE '(^|[|&;[:space:]])(curl|wget|nc)[[:space:]]' || exit 0

# Target must be loopback.
echo "$cmd" | grep -qE '(127\.0\.0\.1|localhost|\[::1\])' || exit 0

# If the same command also probes a tailnet address (100.64.0.0/10 CGNAT range,
# a .ts.net name, or a shelled-out `tailscale ip`), the real test is already
# being run — stay quiet.
if echo "$cmd" | grep -qE '(100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]+\.[0-9]+|\.ts\.net|tailscale ip)'; then
  exit 0
fi

echo '{"additionalContext": "This probe verified localhost only — it proves nothing about LAN or tailnet reachability. Before claiming another device can reach this server, test against the Tailscale IP (`tailscale ip -4`) or from the client'"'"'s network position."}'
exit 0
