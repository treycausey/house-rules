#!/usr/bin/env bash
HOUSE_RULES_HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
. "$HOUSE_RULES_HOOK_DIR/lib/hook-tools.sh"
house_rules_require jq python3
# Stop hook: require a screenshot after the final CSS or layout edit.
# Set SCREENSHOT_CMD_RE to the command name(s) your screenshot tool uses, as a
# regex alternation (default: webshot|shot-scraper|playwright).

set -u

input=$(cat)

# A blocking Stop hook is invoked again after Claude responds to the reason.
# Let that second invocation pass so one missed screenshot blocks only once.
if [ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
  exit 0
fi

transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$transcript_path" ] || exit 0
[ -f "$transcript_path" ] || exit 0

SCREENSHOT_CMD_RE="${SCREENSHOT_CMD_RE:-webshot|shot-scraper|playwright}" python3 - "$transcript_path" <<'PY'
import json
import os
import re
import sys

transcript_path = sys.argv[1]
visual_extension = re.compile(r"\.(?:css|tsx|html|svelte)$", re.IGNORECASE)
tools = os.environ.get("SCREENSHOT_CMD_RE", "webshot")
webshot_command = re.compile(r"(?:^|[\s;&|()])(?:[^\s;&|()]*/)?(?:" + tools + r")(?:[\s;&|()]|$)")

last_visual_edit = -1
last_webshot = -1

try:
    transcript = open(transcript_path, encoding="utf-8")
except OSError:
    sys.exit(0)

with transcript:
    for line_number, line in enumerate(transcript):
        try:
            event = json.loads(line)
        except (TypeError, ValueError):
            continue

        message = event.get("message")
        if not isinstance(message, dict):
            continue
        content = message.get("content")
        if not isinstance(content, list):
            continue

        for block in content:
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue

            name = block.get("name")
            tool_input = block.get("input")
            if not isinstance(tool_input, dict):
                continue

            if name in {"Edit", "Write", "MultiEdit"}:
                paths = [tool_input.get("file_path")]
                edits = tool_input.get("edits")
                if isinstance(edits, list):
                    paths.extend(
                        edit.get("file_path")
                        for edit in edits
                        if isinstance(edit, dict)
                    )
                if any(
                    isinstance(path, str) and visual_extension.search(path)
                    for path in paths
                ):
                    last_visual_edit = line_number

            if name == "Bash":
                command = tool_input.get("command")
                if isinstance(command, str) and webshot_command.search(command):
                    last_webshot = line_number

if last_visual_edit >= 0 and last_webshot <= last_visual_edit:
    print(json.dumps({
        "decision": "block",
        "reason": "Screenshot the changed element and compare it to what the user asked for."
    }))
PY

exit 0
