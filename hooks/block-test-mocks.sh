#!/usr/bin/env bash
# PostToolUse: Edit|Write
# Flags test-file edits that introduce mocking primitives — but ONLY in
# projects whose own CLAUDE.md actually declares a no-mocks rule.
#
# SCOPE: this used to fire globally while citing "Per CLAUDE.md: don't use
# mocks", a rule the global CLAUDE.md never contained — so in repos whose
# established suites use unittest.mock heavily (a Python side project) it flagged
# every new test that followed the repo's own convention. Now it walks up
# from the edited file looking for a project CLAUDE.md and enforces only if
# that file matches a no-mock rule pattern. To opt a project in, add a line
# like "Do not use mocks in tests" to its CLAUDE.md.
#
# Note: PostToolUse cannot undo the write — the message asks for a revision
# rather than claiming the edit was prevented.

input=$(cat)
file=$(echo "$input" | jq -r '.tool_input.file_path // empty')

if [ -z "$file" ] || [ ! -f "$file" ]; then
  exit 0
fi

# Only inspect test files
case "$file" in
  */test_*.py|*_test.py|*/tests/*.py)
    ;;
  *.test.ts|*.test.tsx|*.test.js|*.test.jsx|*.spec.ts|*.spec.tsx|*.spec.js|*.spec.jsx)
    ;;
  */__tests__/*)
    ;;
  *)
    exit 0
    ;;
esac

# Find the nearest project CLAUDE.md above the edited file (stop at $HOME or /).
# The user-global ~/.claude/CLAUDE.md deliberately does NOT count: this rule is
# a per-project opt-in.
project_claude=""
dir=$(cd "$(dirname "$file")" 2>/dev/null && pwd)
while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "$HOME" ]; do
  if [ -f "$dir/CLAUDE.md" ]; then
    project_claude="$dir/CLAUDE.md"
    break
  fi
  dir=$(dirname "$dir")
done

# No project CLAUDE.md, or no no-mocks rule in it: out of scope.
if [ -z "$project_claude" ] \
   || ! grep -qiE "(no mocks|don'?t use mocks|do not use mocks|avoid mock|without mocks)" "$project_claude"; then
  exit 0
fi

# Grep for mock primitives the project declared it avoids
hits_file=$(mktemp)
if grep -nE '(MagicMock|mock\.patch|unittest\.mock|vi\.mock|jest\.mock|sinon\.stub|sinon\.mock)' "$file" > "$hits_file"; then
  hits=$(cat "$hits_file")
  rm -f "$hits_file"
  {
    echo "This test file introduces mocking primitives, which this project's CLAUDE.md forbids ($project_claude)."
    echo "The write has already landed — revise it to use real transports (httpx, a running service) or pure function tests instead."
    echo ""
    echo "File: $file"
    echo "Matches:"
    echo "$hits"
  } >&2
  exit 2
fi

rm -f "$hits_file"
exit 0
