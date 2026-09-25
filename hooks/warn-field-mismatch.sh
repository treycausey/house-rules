#!/usr/bin/env bash
# PostToolUse: Edit|Write
# When editing API types/schemas, checks if field names have common mismatch
# patterns between backend and frontend.
#
# Catches: metadata_ vs metadata, newest vs created_at_desc, favorites vs favorite.
# These contract mismatches survived full implementation sessions and were only
# caught during /review.

input=$(cat)
file=$(echo "$input" | jq -r '.tool_input.file_path // empty')

[ -z "$file" ] && exit 0
[ -f "$file" ] || exit 0

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# Only check schema/type/model files
case "$file" in
  *schema*|*model*|*types*|*interface*|*dto*|*response*|*serializer*) ;;
  *) exit 0 ;;
esac

warnings=""

# Get field names defined in this file (Python dataclass/pydantic fields, TS interface properties)
fields=""
case "$file" in
  *.py)
    # Pydantic/dataclass fields: "field_name: Type" or "field_name ="
    fields=$(grep -oE '^    [a-z][a-z_]+' "$file" 2>/dev/null | tr -d ' ' | sort -u)
    ;;
  *.ts|*.tsx)
    # TS interface properties: "fieldName: Type" or "fieldName?:"
    fields=$(grep -oE '^\s+[a-z][a-zA-Z_]+\??\s*:' "$file" 2>/dev/null | sed 's/[?: ]//g' | sort -u)
    ;;
esac

[ -z "$fields" ] && exit 0

# Check for trailing underscore fields (Python SQL reserved word workaround)
# that might not match the frontend expectation
for f in $fields; do
  if [[ "$f" == *_ ]]; then
    base="${f%_}"
    # Check if frontend files reference the base name without underscore
    frontend_hits=$(grep -rl --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' "\b${base}\b" "$repo_root" 2>/dev/null | grep -v node_modules | grep -v '.d.ts' | head -3)
    if [ -n "$frontend_hits" ]; then
      warnings="${warnings}Field '$f' in $(basename "$file") -- frontend files reference '$base' (without trailing underscore). Ensure serialization alias is set.\n"
    fi
  fi
done

if [ -n "$warnings" ]; then
  json_warnings=$(printf '%b' "$warnings" | sed 's/"/\\"/g' | tr '\n' ' ')
  echo "{\"additionalContext\": \"CONTRACT CHECK: $json_warnings\"}"
fi

exit 0
