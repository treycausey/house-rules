#!/usr/bin/env bash
HOUSE_RULES_HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
. "$HOUSE_RULES_HOOK_DIR/lib/hook-tools.sh"
house_rules_require jq
# PostToolUse: Edit|Write
# Runs Prettier on the edited file if it's a formattable type AND the project
# opted into Prettier. Without an opt-in check, Prettier's default printWidth
# of 80 reflows whole files in projects that never asked for it.

input=$(cat)
file=$(echo "$input" | jq -r '.tool_input.file_path // empty')

[ -z "$file" ] && exit 0

echo "$file" | grep -qE '\.(ts|tsx|js|jsx|mjs|cjs|css|html|json)$' || exit 0

# A directory declares Prettier via a config file, a "prettier" key in
# package.json, or prettier in dependencies/devDependencies.
prettier_opt_in() {
  local dir=$1 cfg
  for cfg in .prettierrc .prettierrc.json .prettierrc.yml .prettierrc.yaml \
             .prettierrc.js .prettierrc.cjs .prettierrc.mjs \
             prettier.config.js prettier.config.cjs prettier.config.mjs; do
    [ -f "$dir/$cfg" ] && return 0
  done
  if [ -f "$dir/package.json" ]; then
    jq -e '(.prettier != null)
           or ((.dependencies // {}) | has("prettier"))
           or ((.devDependencies // {}) | has("prettier"))' \
      "$dir/package.json" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# Walk up from the edited file to the project root (package.json or .git),
# never above $HOME.
dir=$(cd "$(dirname "$file")" 2>/dev/null && pwd) || exit 0
while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "$HOME" ]; do
  if prettier_opt_in "$dir"; then
    # bunx, falling back to npx. With neither, say so instead of skipping silently.
    if command -v bunx >/dev/null 2>&1; then
      bunx prettier --write "$file" 2>/dev/null
    elif command -v npx >/dev/null 2>&1; then
      npx --no-install prettier --write "$file" 2>/dev/null
    else
      jq -n --arg c "prettier-on-edit: skipped formatting $file because neither bunx nor npx is installed." \
        '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
    fi
    exit 0
  fi
  # Project root reached without an opt-in: leave the file alone.
  { [ -e "$dir/package.json" ] || [ -e "$dir/.git" ]; } && exit 0
  dir=$(dirname "$dir")
done

exit 0
