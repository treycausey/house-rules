#!/usr/bin/env bash
HOUSE_RULES_HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
. "$HOUSE_RULES_HOOK_DIR/lib/hook-tools.sh"
house_rules_require jq python3
# PreToolUse: Bash
# Non-blocking nudge: `sed -i` / `perl -pi` rewriting a source or doc file.
#
# Why: in one project's session a `perl -pi` pass over source
# files silently duplicated code, and no test caught it. A shell rewrite
# applies to every match, reports nothing about how many it hit, and leaves no
# before/after in the transcript. The Edit tool does the opposite: it shows the
# exact replacement, refuses a non-unique match instead of applying it twice,
# and goes through block-edit-without-read.sh.
#
# This hook never blocks -- `sed -i` on generated files, fixtures and scratch
# copies is legitimate and common. It only attaches the reminder so a silent
# duplication does not go unnoticed. It fires for the main agent too, since
# that incident was a main-session command.
#
# Quoted mentions must not fire, so the command is split with the same
# quote-aware splitter as block-subagent-git-mutation.sh, and only a segment
# that actually invokes sed/perl in-place on a source-extension file counts.
#
# Tested by hooks/tests/run-tests.sh

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // empty')
[ -n "$cmd" ] || exit 0

# Cheap bail before python3: no sed/perl, nothing to say.
case "$cmd" in
  *sed*|*perl*) ;;
  *) exit 0 ;;
esac

hit=$(python3 - "$cmd" <<'PY' 2>/dev/null
import os
import re
import shlex
import sys

cmd = sys.argv[1]

SEPARATORS = ";\n|&"
DELIM_END = " \t;&|<>"
WRAPPERS = ("sudo", "time", "env", "command", "xargs", "nice", "nohup",
            "stdbuf", "timeout")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
SOURCE_EXTS = {
    "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rs", "swift", "go", "rb",
    "sh", "bash", "zsh", "json", "yaml", "yml", "toml", "md", "css", "scss",
    "html", "vue", "svelte", "c", "h", "cpp", "m", "mm", "kt", "java", "sql",
    "plist", "xml",
}
SCRATCH_ROOTS = {"/tmp", "/var/tmp", os.path.realpath("/tmp"), os.path.realpath("/var/tmp")}
if os.environ.get("TMPDIR"):
    SCRATCH_ROOTS.add(os.environ["TMPDIR"].rstrip("/"))
    SCRATCH_ROOTS.add(os.path.realpath(os.environ["TMPDIR"]))
SCRATCH_PREFIXES = tuple(root.rstrip("/").lower() + "/" for root in SCRATCH_ROOTS if root)


def strip_heredocs(text):
    out = []
    pending = []
    quote = None
    for line in text.split("\n"):
        if pending:
            strip, delim = pending[0]
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
        return segment.split()


def lead(tokens):
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if ASSIGNMENT.match(t) or t.startswith("-"):
            i += 1
            continue
        if os.path.basename(t) in WRAPPERS:
            i += 1
            continue
        break
    return i


def inplace(tokens, letters):
    """A short-option cluster carrying an in-place letter, or --in-place*."""
    for t in tokens:
        if t.startswith("--"):
            if t.startswith("--in-place"):
                return True
            continue
        if not t.startswith("-") or t == "-":
            continue
        body = t[1:].split(".", 1)[0]
        if any(ch in body for ch in letters):
            return True
    return False


def source_file(tok):
    if tok.startswith("-") or "." not in os.path.basename(tok):
        return False
    ext = tok.rsplit(".", 1)[1].lower()
    if ext not in SOURCE_EXTS:
        return False
    low = tok.lower()
    if low.startswith(SCRATCH_PREFIXES):
        return False
    if "scratchpad" in low:
        return False
    return True


for segment in split_segments(strip_heredocs(cmd)):
    tokens = tokenize(segment)
    i = lead(tokens)
    if i >= len(tokens):
        continue
    name = os.path.basename(tokens[i])
    rest = tokens[i + 1:]
    if name == "sed":
        letters = "iI"
    elif name == "perl":
        letters = "i"
    else:
        continue
    if not inplace(rest, letters):
        continue
    for tok in rest:
        if source_file(tok):
            sys.stdout.write(tok + "\n")
            raise SystemExit(0)
PY
)

[ -n "$hit" ] || exit 0

python3 - "$hit" <<'PY'
import json
import sys

f = sys.argv[1]
msg = (
    "Nudge: this rewrites %s in place with sed/perl. Prefer the Edit tool for "
    "source files: it shows the exact before/after, fails on a non-unique "
    "match instead of duplicating code, and is covered by the read-before-edit "
    "hook (a perl -pi pass duplicated code and no test caught "
    "it). If the shell rewrite is deliberate, run `git diff -- %s` right after "
    "and check the hunk count." % (f, f)
)
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "additionalContext": msg,
}}))
PY
exit 0
