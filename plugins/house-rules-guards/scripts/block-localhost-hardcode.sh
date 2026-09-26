#!/usr/bin/env bash
HOUSE_RULES_HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
. "$HOUSE_RULES_HOOK_DIR/lib/hook-tools.sh"
house_rules_require jq
# PostToolUse: Edit|Write
# Warns when localhost URLs are hardcoded in source files (not .env, config, or test files).
# A browser on another device resolves localhost to itself, not the server.

input=$(cat)
file=$(echo "$input" | jq -r '.tool_input.file_path // empty')

# Skip files where localhost is expected
case "$file" in
  *.env|*.env.*|*.example|*conftest*|*test*|*spec*|*README*|*setup.py|*.md)
    exit 0
    ;;
esac

# Only check source files (skip config, build output, node_modules, etc.)
case "$file" in
  */node_modules/*|*/dist/*|*/build/*|*/.next/*|*/__pycache__/*|*/venv/*|*/.venv/*)
    exit 0
    ;;
  *.ts|*.tsx|*.js|*.jsx|*.py|*.swift|*.svelte|*.vue|*.html)
    ;;
  *)
    exit 0
    ;;
esac

# Check if the file now contains a hardcoded localhost URL
if grep -qE 'https?://localhost[:/]' "$file" 2>/dev/null; then
  echo "Warning: $file contains a hardcoded localhost URL. A browser on another device resolves it to that device. Use a relative path or a configured server URL." >&2
fi

exit 0
