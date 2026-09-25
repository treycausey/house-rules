#!/usr/bin/env bash
# PreToolUse: Bash
# Blocks git commit if staged files fail lint.
# Catches: unused imports, style issues, pre-existing lint errors in touched files.
# These were repeatedly found by /review instead of being caught before commit.

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // empty')

# Only trigger on an actual `git commit` INVOCATION.
#
# This used to grep the raw command string for `git\s+commit` preceded by a
# separator, which counted the words wherever they appeared -- including inside
# a quoted argument. A `perl -pi -e 's/.../echo "run git commit now"/' file`
# that merely WROTE those words into a script tripped the hook, which then
# linted the repo's stale staged files and refused the edit. The
# same false positive applied to `echo "git commit"`, an `rg 'git commit'`
# search, and a heredoc body containing a commit line.
# The command string is now split into top-level segments (heredoc bodies
# dropped, quotes respected) and each segment is resolved to the command it
# actually invokes; only a real `git ... commit` counts. This is the same
# whole-command-string fix already applied to block-wrong-runner.sh and
# block-sensitive-git-add.sh, and it reuses their splitter.
verdict=$(python3 - "$cmd" <<'PY' 2>/dev/null
import os
import re
import shlex
import sys

cmd = sys.argv[1]

SEPARATORS = ";\n|&"
DELIM_END = " \t;&|<>"
# Prefixes that wrap a real command rather than being the command themselves.
WRAPPERS = ("sudo", "time", "env", "command", "xargs", "nice", "nohup")
# git's own global options that take a separate value argument.
GIT_OPTS_WITH_VALUE = ("-C", "-c", "--git-dir", "--work-tree", "--namespace",
                       "--exec-path", "--super-prefix")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def strip_heredocs(text):
    """Drop heredoc bodies, keeping the command lines that open them.

    A heredoc body is data bound for another file, so a `git commit` inside one
    is text being written, not a commit being run. The opening line is kept.
    """
    out = []
    pending = []  # (strip_tabs, delimiter), in the order the bodies arrive
    quote = None
    for line in text.split("\n"):
        if pending:
            strip, delim = pending[0]
            # `<<-` strips leading TABs from the body and from the terminator.
            body = line.lstrip("\t") if strip else line
            if body == delim:
                pending.pop(0)
            continue
        out.append(line)
        i = 0
        n = len(line)
        while i < n:
            c = line[i]
            if quote:
                if c == "\\" and quote == '"' and i + 1 < n:
                    i += 2
                    continue
                if c == quote:
                    quote = None
                i += 1
                continue
            if c == "\\":
                i += 2
                continue
            if c in "\"'":
                quote = c
                i += 1
                continue
            if c != "<" or line[i + 1:i + 2] != "<":
                i += 1
                continue
            # `<<<` is a herestring: no body follows it.
            if line[i + 2:i + 3] == "<":
                i += 3
                continue
            i += 2
            strip = False
            if line[i:i + 1] == "-":
                strip = True
                i += 1
            while i < n and line[i] in " \t":
                i += 1
            buf = []
            while i < n and line[i] not in DELIM_END:
                if line[i] in "\"'\\":
                    i += 1
                    continue
                buf.append(line[i])
                i += 1
            if buf:
                pending.append((strip, "".join(buf)))
    return "\n".join(out)


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


def is_git_commit(tokens):
    """True when these tokens invoke `git commit` (any global-option dress)."""
    i = 0
    while i < len(tokens):
        t = tokens[i]
        # Leading environment assignments: `GIT_EDITOR=true git commit`.
        if ASSIGNMENT.match(t):
            i += 1
            continue
        # Options belonging to a wrapper already skipped: `sudo -u me git ...`.
        if t.startswith("-"):
            i += 1
            continue
        # Wrappers around a real command: `time git commit`.
        if os.path.basename(t) in WRAPPERS:
            i += 1
            continue
        break
    # Path-qualified invocations count: `/usr/bin/git commit`.
    if i >= len(tokens) or os.path.basename(tokens[i]) != "git":
        return False
    i += 1
    # git's own global options, so `git -C path commit` is still seen.
    while i < len(tokens) and tokens[i].startswith("-"):
        if tokens[i] in GIT_OPTS_WITH_VALUE:
            i += 2
        else:
            i += 1
    # `commit` exactly -- not `committer`, not `commit-tree`.
    return i < len(tokens) and tokens[i] == "commit"


for segment in split_segments(strip_heredocs(cmd)):
    if is_git_commit(tokenize(segment)):
        sys.stdout.write("git-commit\n")
        break
PY
)
[ "$verdict" = "git-commit" ] || exit 0

# Find the repo root from the working directory
repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# Get staged files
staged=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null) || exit 0
[ -z "$staged" ] && exit 0

errors=""
skips=""

# JS/TS tools run through bunx, falling back to npx. With neither installed the
# JS/TS checks are skipped, and the skip is reported to the agent (see the end
# of this file) instead of passing silently.
js_exec() {
  if command -v bunx >/dev/null 2>&1; then bunx "$@"
  elif command -v npx >/dev/null 2>&1; then npx --no-install "$@"
  else return 127
  fi
}
have_js_exec() { command -v bunx >/dev/null 2>&1 || command -v npx >/dev/null 2>&1; }

# ── Python: ruff ────────────────────────────────────────────────────
py_files=$(echo "$staged" | grep -E '\.py$' || true)
if [ -n "$py_files" ]; then
  if command -v ruff &>/dev/null; then
    # Gate on the EXIT CODE, not on whether ruff said anything. ruff 0.16
    # prints "All checks passed!" on success (0.15 printed nothing), and a
    # non-empty test read that as a lint failure -- blocking every commit
    # with a staged .py file, in every repo, with the bewildering message
    # "ruff errors in staged Python files: All checks passed!".
    # shellcheck disable=SC2086
    if ! lint_out=$(cd "$repo_root" && ruff check --no-fix $py_files 2>&1); then
      errors="${errors}ruff errors in staged Python files:\n${lint_out}\n\n"
    fi
  fi
fi

# ── JS/TS: eslint via bunx ─────────────────────────────────────────
ts_files=$(echo "$staged" | grep -E '\.(ts|tsx|js|jsx)$' || true)
if [ -n "$ts_files" ]; then
  # Check if eslint config exists in repo
  if [ -f "$repo_root/eslint.config.js" ] || [ -f "$repo_root/eslint.config.mjs" ] || [ -f "$repo_root/.eslintrc.json" ] || [ -f "$repo_root/.eslintrc.js" ]; then
    if ! have_js_exec; then
      skips="${skips}eslint skipped: neither bunx nor npx is installed. "
    else
      # Gate on eslint's exit code: 1 means lint errors, 0 means clean or
      # warnings only. Matching "error" in the output also matched warnings in
      # files whose NAME contains "error" (errorHandler.ts).
      # shellcheck disable=SC2086
      lint_out=$(cd "$repo_root" && js_exec eslint --no-warn-ignored $ts_files 2>&1)
      lint_rc=$?
      if [ "$lint_rc" -eq 1 ]; then
        errors="${errors}eslint errors in staged JS/TS files:\n${lint_out}\n\n"
      elif [ "$lint_rc" -ne 0 ]; then
        skips="${skips}eslint could not run (exit ${lint_rc}); lint was not checked. "
      fi
    fi
  fi
fi

# ── GDScript: gdlint ─────────────────────────────────────────────
gd_files=$(echo "$staged" | grep -E '\.gd$' | grep -v '^addons/' || true)
if [ -n "$gd_files" ]; then
  if command -v gdlint &>/dev/null; then
    # shellcheck disable=SC2086
    lint_out=$(cd "$repo_root" && gdlint $gd_files 2>&1) || true
    if echo "$lint_out" | grep -q "Error:"; then
      errors="${errors}gdlint errors in staged GDScript files:\n${lint_out}\n\n"
    fi
  fi
fi

# ── TypeScript: tsc --noEmit ───────────────────────────────────────
if [ -n "$ts_files" ]; then
  if [ -f "$repo_root/tsconfig.json" ]; then
    if ! have_js_exec; then
      skips="${skips}tsc skipped: neither bunx nor npx is installed. "
    else
      tsc_out=$(cd "$repo_root" && js_exec tsc --noEmit 2>&1) || true
      if echo "$tsc_out" | grep -qE '^.+\.[tj]sx?\([0-9]+,[0-9]+\): error TS'; then
        errors="${errors}TypeScript type errors (tsc --noEmit):\n${tsc_out}\n\n"
      fi
    fi
  fi
fi

# ── Rust: clippy ──────────────────────────────────────────────────
rs_files=$(echo "$staged" | grep -E '\.rs$' || true)
if [ -n "$rs_files" ]; then
  if [ -f "$repo_root/Cargo.toml" ] && command -v cargo &>/dev/null; then
    clippy_out=$(cd "$repo_root" && cargo clippy --lib -- -D warnings 2>&1) || true
    if echo "$clippy_out" | grep -qE '^error'; then
      errors="${errors}Clippy errors in staged Rust files:\n${clippy_out}\n\n"
    fi
  fi
fi

# ── File length check on staged files ──────────────────────────────
# Hard block at 800 lines. Rationale: agent context management favors a token
# budget over raw line counts — ~15k tokens is a sane single-file code-context
# ceiling, and ~800 lines of source is roughly half that, leaving room for the
# rest of a task. ~500 lines stays the SOFT "consider a refactor" signal (in
# CLAUDE.md); this is the harder "must refactor" stop. Markdown/docs are prose,
# not code-context, so they are skipped.
MAX_FILE_LINES=800
while IFS= read -r f; do
  [ -f "$repo_root/$f" ] || continue
  # Skip auto-generated lock files, bundled CSS/HTML deliverables, markdown docs/prose, binary/image files, and third-party addons.
  # *.html covers single-file bundled artifacts (e.g. a build that inlines all
  # CSS/JS into one self-contained page): those are generated output, not
  # hand-authored source, and their source already lives in split modules --
  # the same rationale that already exempts bundled *.css here.
  case "$f" in *.lock|*-lock.json|*.css|*.html|*.md|*.toml|*.pbxproj) continue ;; esac
  case "$f" in addons/*) continue ;; esac
  case "$f" in *.png|*.jpg|*.jpeg|*.gif|*.ico|*.webp|*.svg|*.woff|*.woff2|*.ttf|*.eot|*.mp4|*.mp3|*.pdf) continue ;; esac
  # A single-file script that declares its own dependencies inline (PEP 723,
  # run by `uv run --script`) cannot obey this limit: being ONE file IS its
  # invocation contract, so splitting it into modules breaks how it is run and
  # "refactor before committing" has no answer. Recognised two ways, either of
  # which means the file is such a script: a shebang that execs
  # `uv run --script`, or the `# /// script` metadata block, which has meaning
  # only in a standalone script. a 1000-line standalone deploy script is the case that
  # surfaced this (1006 lines; it blocked a commit).
  if head -1 "$repo_root/$f" | grep -q 'uv run --script' \
    || head -20 "$repo_root/$f" | grep -qE '^# /// script[[:space:]]*$'; then
    continue
  fi
  lines=$(wc -l < "$repo_root/$f")
  if [ "$lines" -gt "$MAX_FILE_LINES" ]; then
    errors="${errors}$f is $lines lines (hard limit $MAX_FILE_LINES; ~500 is the soft refactor signal). Refactor before committing.\n"
  fi
done <<< "$staged"

if [ -n "$errors" ]; then
  printf "Blocked: fix lint/size issues before committing.\n\n%b" "$errors" >&2
  exit 2
fi

if [ -n "$skips" ]; then
  jq -n --arg c "pre-commit-lint: ${skips}" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $c}}'
fi

exit 0
