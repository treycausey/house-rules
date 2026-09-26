#!/usr/bin/env bash
HOUSE_RULES_HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
. "$HOUSE_RULES_HOOK_DIR/lib/hook-tools.sh"
house_rules_require jq
# PostToolUse: Edit|Write
# When a backend file declares /api/<prefix>/... routes, verify that prefix is
# registered in the project's frontend proxy config (Next.js rewrites or Vite
# proxy). Warns (does not block) on miss. Catches the "new backend route,
# forgot to add to Next.js rewrites" class of bug.

input=$(cat)
file=$(echo "$input" | jq -r '.tool_input.file_path // empty')

if [ -z "$file" ] || [ ! -f "$file" ]; then
  exit 0
fi

# Only inspect backend route files: Python (FastAPI/Flask) and TS/JS (Hono/Express)
is_backend=false
case "$file" in
  *.py)
    if grep -qE '@(app|router)\.(get|post|put|patch|delete)\(' "$file" 2>/dev/null; then
      is_backend=true
    fi
    ;;
  *.ts|*.tsx|*.js|*.mjs|*.mts)
    if grep -qE '(^|[^[:alnum:]_])(app|router)\.(get|post|put|patch|delete)\(' "$file" 2>/dev/null; then
      is_backend=true
    fi
    ;;
esac

[ "$is_backend" = true ] || exit 0

# Walk up to find the project root (package.json or pyproject.toml)
dir=$(dirname "$file")
root=""
while [ "$dir" != "/" ] && [ "$dir" != "." ]; do
  if [ -f "$dir/package.json" ] || [ -f "$dir/pyproject.toml" ]; then
    root="$dir"
    break
  fi
  dir=$(dirname "$dir")
done
[ -n "$root" ] || exit 0

# Find a frontend proxy config (check common locations including a frontend/ subdir)
proxy_config=""
for candidate in \
  "$root/next.config.js" "$root/next.config.ts" "$root/next.config.mjs" \
  "$root/vite.config.js" "$root/vite.config.ts" \
  "$root/frontend/next.config.js" "$root/frontend/next.config.ts" "$root/frontend/next.config.mjs" \
  "$root/frontend/vite.config.js" "$root/frontend/vite.config.ts" \
  "$root/web/next.config.js" "$root/web/next.config.ts" "$root/web/next.config.mjs" \
  "$root/web/vite.config.js" "$root/web/vite.config.ts"; do
  if [ -f "$candidate" ]; then
    proxy_config="$candidate"
    break
  fi
done
[ -n "$proxy_config" ] || exit 0

# Extract /api/<first-segment> prefixes declared in this file
prefixes=$(grep -oE '"/api/[a-zA-Z0-9_-]+' "$file" 2>/dev/null | sort -u)
[ -n "$prefixes" ] || exit 0

missing=""
while IFS= read -r prefix; do
  prefix="${prefix#\"}"  # strip leading quote
  if ! grep -qF "$prefix" "$proxy_config" 2>/dev/null; then
    missing="${missing}${prefix}\n"
  fi
done <<< "$prefixes"

if [ -n "$missing" ]; then
  {
    echo "Warning: backend file $file declares routes not found in proxy config $proxy_config:"
    printf "%b" "$missing" | sed 's/^/  - /'
    echo "Frontend requests to these prefixes will not be proxied. Add the rewrite/proxy entry before shipping."
  } >&2
fi

exit 0
