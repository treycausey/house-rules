#!/usr/bin/env bash
HOUSE_RULES_HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
. "$HOUSE_RULES_HOOK_DIR/lib/hook-tools.sh"
house_rules_require jq python3
# PostToolUse: Edit|Write
# After editing config files that contain port numbers, sweep .env* files
# for stale port values. Catches gitignored .env.local files that survive
# source code changes.
#
# Ports checked: DEV_PORT_MIN..DEV_PORT_MAX (default 3000..9999).

input=$(cat)
file=$(echo "$input" | jq -r '.tool_input.file_path // empty')

[ -n "$file" ] && [ -f "$file" ] || exit 0

case "$file" in
  *next.config*|*vite.config*|*docker-compose*|*Dockerfile|*.toml|*wrangler*|*project.yml)
    ;;
  *) exit 0 ;;
esac

project_root=$(cd "$(dirname "$file")" && git rev-parse --show-toplevel 2>/dev/null)
[ -n "$project_root" ] || project_root=$(dirname "$file")

python3 - "$project_root" "$file" "${DEV_PORT_MIN:-3000}" "${DEV_PORT_MAX:-9999}" <<'PY'
import json
import os
import re
import sys

root, config_path = sys.argv[1:3]
minimum, maximum = int(sys.argv[3]), int(sys.argv[4])
port_re = re.compile(r"(?<![0-9])[0-9]{4,5}(?![0-9])")

try:
    with open(config_path, encoding="utf-8", errors="replace") as stream:
        config_ports = set(port_re.findall(stream.read()))
except OSError:
    sys.exit(0)

warnings = []
for current, directories, files in os.walk(root):
    relative = os.path.relpath(current, root)
    depth = 0 if relative == "." else relative.count(os.sep) + 1
    directories[:] = [
        name for name in directories
        if name not in {".git", "node_modules", ".venv"} and depth < 2
    ]
    for name in files:
        if not name.startswith(".env"):
            continue
        path = os.path.join(current, name)
        try:
            with open(path, encoding="utf-8", errors="replace") as stream:
                env_ports = set(port_re.findall(stream.read()))
        except OSError:
            continue
        for port in sorted(env_ports):
            value = int(port)
            if minimum <= value <= maximum and port not in config_ports:
                warnings.append("  %s: contains port %s which is not in the updated config" % (path, port))

if warnings:
    message = (
        "WARNING: .env files may have stale port references after this config change:\n"
        + "\n".join(warnings)
        + "\nCheck these files and update if needed (they are gitignored so grep/search may miss them)."
    )
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": message}}))
PY

exit $?
