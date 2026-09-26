#!/usr/bin/env bash
HOUSE_RULES_HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
. "$HOUSE_RULES_HOOK_DIR/lib/hook-tools.sh"
house_rules_require jq python3
# PostToolUse: Bash
# Non-blocking nudge: a reachability probe against localhost/127.0.0.1 verifies
# only the local loopback, not whether another device or network can reach it.
# This hook never blocks — curling localhost is legitimate constantly. It only
# attaches a reminder so the false "reachable" claim doesn't get written.

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // empty')

[ -z "$cmd" ] && exit 0

# Only probe-shaped commands: curl / wget / nc. Config commands that merely
# mention 127.0.0.1 (server binds or proxy targets) must not fire.
echo "$cmd" | grep -qE '(^|[|&;[:space:]])(curl|wget|nc)[[:space:]]' || exit 0

# Target must be loopback.
echo "$cmd" | grep -qE '(127\.0\.0\.1|localhost|\[::1\])' || exit 0

if python3 - "$cmd" <<'PY'
import ipaddress
import re
import sys
from urllib.parse import urlsplit

command = sys.argv[1]
hosts = []
for url in re.findall(r"https?://[^\s\"';&|]+", command, re.I):
    host = urlsplit(url.rstrip(").,}" + chr(96))).hostname
    if host:
        hosts.append(host)
hosts.extend(re.findall(r"(?<![A-Za-z0-9_])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![A-Za-z0-9_])", command))
for host in hosts:
    if host.lower() in {"localhost", "::1"}:
        continue
    try:
        if ipaddress.ip_address(host).is_loopback:
            continue
    except ValueError:
        pass
    sys.exit(0)
sys.exit(1)
PY
then
  exit 0
fi

jq -n --arg context "This probe checked only loopback. It does not show that another device or network can reach the service. Test from the client network position before making that claim." \
  '{additionalContext:$context}'
exit 0
