#!/usr/bin/env bash
HOUSE_RULES_HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
. "$HOUSE_RULES_HOOK_DIR/lib/hook-tools.sh"
house_rules_require jq
# PostToolUse: Edit|Write
# After creating/changing a .swift file in an XcodeGen project, remind to run
# `xcodegen generate` before the next build. The build-fail -> regen -> rebuild
# loop has been the single most repeated iOS time sink (40-65 regens/session).

input=$(cat)
file=$(echo "$input" | jq -r '.tool_input.file_path // empty')

[ -z "$file" ] && exit 0
case "$file" in *.swift) ;; *) exit 0 ;; esac

repo=$(cd "$(dirname "$file")" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || exit 0

if [ -f "$repo/project.yml" ]; then
  echo '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"Swift file changed in an XcodeGen project. If this file was newly created, deleted, or moved, run `xcodegen generate` before the next build. Do not diagnose `cannot find ... in scope` as a code bug until xcodegen has been re-run."}}'
fi

exit 0
