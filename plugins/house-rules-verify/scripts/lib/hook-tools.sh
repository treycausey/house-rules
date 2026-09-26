#!/usr/bin/env bash
# Shared checks for the hook scripts. Keep this file next to the scripts under
# hooks/lib/ and copy it into each plugin's scripts/lib/ directory.

house_rules_require() {
  local missing="" tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing="${missing}${missing:+, }${tool}"
    fi
  done
  if [ -n "$missing" ]; then
    printf 'house-rules: hook skipped; required command not found: %s\n' "$missing" >&2
    exit 0
  fi
}
