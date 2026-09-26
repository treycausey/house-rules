#!/usr/bin/env bash
HOUSE_RULES_HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
. "$HOUSE_RULES_HOOK_DIR/lib/hook-tools.sh"
house_rules_require jq python3
# PreToolUse: Bash
# Blocks bare "bun <script>" (should be "bun run <script>") and npm/yarn/pnpm usage.

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // empty')
[ -z "$cmd" ] && exit 0

# Block npm, yarn, pnpm.
#
# This used to grep the raw command string for the runner name preceded by a
# separator, which counted the name wherever it appeared -- including inside a
# quoted argument. `echo "=== npm install check ==="`, `rg "use pnpm instead"
# README.md`, and `notes "block-wrong-runner.sh blocks npm mentions"` were
# all blocked as if they invoked a package manager. It was also wrong the other
# way: `/usr/local/bin/npm install` was allowed, because the name was glued to
# a path rather than preceded by a separator.
# The command string is now split into top-level segments and each segment is
# resolved to the command it actually invokes; only that token counts.
#
# The bare `bun test` / `bun build` checks below used the same raw grep and had
# the same false positives (a `gh issue create --body "... bun test ..."` was
# blocked), so they share this resolver too: the block prints one line per
# genuinely invoked bun subcommand it cares about, and the bash below keeps
# doing the package.json runner detection.
verdict=$(python3 - "$cmd" <<'PY'
import os
import re
import shlex
import sys

cmd = sys.argv[1]

SEPARATORS = ";\n|&"
RUNNERS = ("npm", "yarn", "pnpm")
# Bun subcommands the bash below decides about; reported, not blocked here.
BUN_SUBCOMMANDS = ("test", "build")
# Prefixes that wrap a real command rather than being the command themselves.
WRAPPERS = ("sudo", "time", "env", "command", "xargs")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def split_segments(text):
    """Split on top-level &&, ||, ;, |, & and newline, respecting quotes."""
    segments = []
    current = []
    quote = None
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if quote:
            current.append(c)
            if c == "\\" and quote == '"' and i + 1 < n:
                current.append(text[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            current.append(c)
            current.append(text[i + 1])
            i += 2
            continue
        if c in "\"'":
            quote = c
            current.append(c)
            i += 1
            continue
        if c in SEPARATORS:
            segments.append("".join(current))
            current = []
            while i < n and text[i] in SEPARATORS:
                i += 1
            continue
        current.append(c)
        i += 1
    segments.append("".join(current))
    return segments


def tokenize(segment):
    try:
        return shlex.split(segment)
    except ValueError:
        # Unbalanced quotes: fall back to a whitespace split rather than
        # letting a malformed command skip the check entirely.
        return segment.split()


def invoked_command(tokens):
    """(basename, remaining tokens) for the command this segment actually runs.

    (None, []) when the segment invokes nothing.
    """
    i = 0
    while i < len(tokens):
        t = tokens[i]
        # Leading environment assignments: `FOO=bar npm install`.
        if ASSIGNMENT.match(t):
            i += 1
            continue
        # Options belonging to a wrapper already skipped: `sudo -u me npm i`.
        if t.startswith("-"):
            i += 1
            continue
        # Wrappers around a real command: `sudo npm i`, `time npm run x`.
        if os.path.basename(t) in WRAPPERS:
            i += 1
            continue
        # Path-qualified invocations count: `./node_modules/.bin/pnpm x`.
        return os.path.basename(t), tokens[i + 1:]
    return None, []


def first_operand(rest):
    """First non-option argument: the subcommand, if there is one."""
    for t in rest:
        if t.startswith("-"):
            continue
        return t
    return None


bun_subcommands = []
for segment in split_segments(cmd):
    name, rest = invoked_command(tokenize(segment))
    if name in RUNNERS:
        sys.stderr.write("Blocked: use bun, not npm/yarn/pnpm.\n")
        sys.exit(2)
    if name == "bun":
        sub = first_operand(rest)
        if sub in BUN_SUBCOMMANDS and sub not in bun_subcommands:
            bun_subcommands.append(sub)

for sub in bun_subcommands:
    sys.stdout.write("bun:%s\n" % sub)
sys.exit(0)
PY
)
status=$?
[ "$status" -ne 0 ] && exit "$status"

invokes_bun() { printf '%s\n' "$verdict" | grep -qx "bun:$1"; }

# Block bare "bun test" only when the project's runner is Vitest. Some projects
# (e.g. a project board app) have "bun test ./test" as their own test script, where
# Bun's native runner is the correct one.
if invokes_bun test; then
  cwd=$(echo "$input" | jq -r '.cwd // empty')
  [ -z "$cwd" ] && cwd=$PWD

  # Nearest package.json at or above cwd, never above $HOME.
  pkg=""
  dir=$cwd
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/package.json" ]; then pkg="$dir/package.json"; break; fi
    [ "$dir" = "$HOME" ] && break
    dir=$(dirname "$dir")
  done

  runner=unknown
  if [ -n "$pkg" ]; then
    if jq -e '((.dependencies // {}) | has("vitest"))
              or ((.devDependencies // {}) | has("vitest"))
              or ((.scripts.test // "") | test("(^|[^a-zA-Z0-9_-])vitest([^a-zA-Z0-9_-]|$)"))' \
         "$pkg" >/dev/null 2>&1; then
      runner=vitest
    elif jq -e '(.scripts.test // "") | test("(^|[^a-zA-Z0-9_-])bun[[:space:]]+test([^a-zA-Z0-9_-]|$)")' \
         "$pkg" >/dev/null 2>&1; then
      runner=bun
    fi
  fi

  case "$runner" in
    bun)
      : # This project's own test script is Bun's native runner. Allow.
      ;;
    vitest)
      echo 'Blocked: use "bun run test" (Vitest), not bare "bun test" (Bun native runner).' >&2
      exit 2
      ;;
    *)
      echo "Blocked: could not determine this project's test runner (no package.json found, or its test script names neither vitest nor bun test). Run the project's own script with \"bun run test\"." >&2
      exit 2
      ;;
  esac
fi

# Block bare "bun build" (has its own meaning in Bun, not package.json script)
if invokes_bun build; then
  echo 'Blocked: "bun build" invokes Bun bundler. Use "bun run build" for the package.json script.' >&2
  exit 2
fi

exit 0
