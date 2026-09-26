#!/usr/bin/env bash
HOUSE_RULES_HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
. "$HOUSE_RULES_HOOK_DIR/lib/hook-tools.sh"
house_rules_require jq
# PostToolUse: Edit|Write
# Warns when a file exceeds 500 lines after editing.

input=$(cat)
file=$(echo "$input" | jq -r '.tool_input.file_path // empty')

[ -z "$file" ] && exit 0
[ -f "$file" ] || exit 0

lines=$(wc -l < "$file")

if [ "$lines" -gt 500 ]; then
  echo "{\"additionalContext\": \"$file is now $lines lines, over the ~500-line soft limit. Propose a split before further edits; the pre-commit hook blocks source files over 800 lines.\"}"
elif [ "$lines" -gt 450 ]; then
  echo "{\"additionalContext\": \"$file is now $lines lines, near the ~500-line soft limit. Plan a split now; the pre-commit hook blocks source files over 800 lines.\"}"
fi

exit 0
