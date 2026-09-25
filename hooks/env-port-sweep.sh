#!/usr/bin/env bash
# PostToolUse: Edit|Write
# After editing config files that contain port numbers, sweep .env* files
# for stale port values. Catches gitignored .env.local files that survive
# source code changes.
#
# Ports checked: DEV_PORT_MIN..DEV_PORT_MAX (default 3000..9999).

input=$(cat)
file=$(echo "$input" | jq -r '.tool_input.file_path // empty')

[ -z "$file" ] && exit 0
[ -f "$file" ] || exit 0

# Only trigger on config files that typically contain port numbers
case "$file" in
  *next.config*|*vite.config*|*docker-compose*|*Dockerfile|*.toml|*wrangler*|*project.yml)
    ;;
  *)
    exit 0
    ;;
esac

# Find the project root (git root or parent of the file)
project_root=$(cd "$(dirname "$file")" && git rev-parse --show-toplevel 2>/dev/null)
[ -z "$project_root" ] && project_root=$(dirname "$file")

# Find .env* files (including gitignored ones)
env_files=$(find "$project_root" -maxdepth 3 -name '.env*' -not -path '*/node_modules/*' -not -path '*/.venv/*' 2>/dev/null)
[ -z "$env_files" ] && exit 0

# Extract port numbers from the edited file's diff (new content)
ports=$(grep -oE '\b[0-9]{4,5}\b' "$file" 2>/dev/null | sort -u)
[ -z "$ports" ] && exit 0

# Check .env files for port numbers that are NOT in the current config
# This catches stale ports that reference old values
warnings=""
while IFS= read -r envf; do
  [ -f "$envf" ] || continue
  env_ports=$(grep -oE '\b[0-9]{4,5}\b' "$envf" 2>/dev/null | sort -u)
  for ep in $env_ports; do
    # Only ports in the dev-server range, and only ones the config no longer names
    if [ "$ep" -ge "${DEV_PORT_MIN:-3000}" ] 2>/dev/null && [ "$ep" -le "${DEV_PORT_MAX:-9999}" ] 2>/dev/null; then
      if ! grep -qF "$ep" "$file" 2>/dev/null; then
        warnings="${warnings}  ${envf}: contains port ${ep} which is not in the updated config\n"
      fi
    fi
  done
done <<< "$env_files"

if [ -n "$warnings" ]; then
  echo "{\"additionalContext\": \"WARNING: .env files may have stale port references after this config change:\\n${warnings}Check these files and update if needed (they are gitignored so grep/search may miss them).\"}"
fi

exit 0
