#!/usr/bin/env bash
HOUSE_RULES_HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
. "$HOUSE_RULES_HOOK_DIR/lib/hook-tools.sh"
house_rules_require jq python3
# PreToolUse: Bash. Shell options belong to the execution process, not this
# hook process. Warn about a possible noclobber failure without claiming the
# provider shell enables it. Native shell status remains the source of truth.

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // empty')
[ -z "$cmd" ] && exit 0

python3 - "$cmd" <<'PY'
import json
import os
import sys

cmd = sys.argv[1]

TARGET_END = " \t\n<>|&;()"
DELIM_END = " \t;&|<>"


def strip_heredocs(text):
    """Drop heredoc bodies, keeping the command lines that open them.

    A heredoc body is data bound for another file, so a `>` inside one is not
    a redirection. The opening line is kept: `cat > out.txt <<EOF` redirects
    for real, and the heredoc says nothing about that.
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
        # Collect the delimiters this command line opens: `cat <<A <<B` opens
        # two, and their bodies follow in that order.
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
            # `<<EOF`, `<<'EOF'` and `<<"EOF"` all name the delimiter EOF.
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


def redirect_targets(text):
    """Targets of single `>` redirections, ignoring quoted/escaped `>`."""
    targets = []
    quote = None
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
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
        if c != ">":
            i += 1
            continue

        prev = text[i - 1] if i > 0 else ""
        nxt = text[i + 1] if i + 1 < n else ""
        # `>>` append, `>|` forced overwrite, `>&` fd dup, `&>` both streams,
        # `>(` process substitution: none of these hit the noclobber failure.
        if prev in (">", "&") or nxt in (">", "|", "&", "("):
            i += 1
            continue
        # `2>`, `3>` and friends: an fd-qualified redirect, left alone.
        if prev.isdigit():
            j = i - 1
            while j > 0 and text[j - 1].isdigit():
                j -= 1
            if j == 0 or text[j - 1] in " \t\n;|&(":
                i += 1
                continue

        j = i + 1
        while j < n and text[j] in " \t":
            j += 1
        if j < n and text[j] in "\"'":
            q = text[j]
            j += 1
            buf = []
            while j < n and text[j] != q:
                buf.append(text[j])
                j += 1
            i = j + 1
        else:
            buf = []
            while j < n and text[j] not in TARGET_END:
                if text[j] == "\\" and j + 1 < n:
                    buf.append(text[j + 1])
                    j += 2
                    continue
                buf.append(text[j])
                j += 1
            i = j
        target = "".join(buf)
        if target:
            targets.append(target)
    return targets


for t in redirect_targets(strip_heredocs(cmd)):
    if t.startswith("~/"):
        t = os.path.join(os.path.expanduser("~"), t[2:])
    if os.path.isfile(t):
        msg = (
            "This command redirects onto an existing file: %s. "
            "If the execution shell has noclobber enabled, use '>| %s' for an "
            "intentional overwrite. The hook cannot inspect that shell's options. "
            "Check the command's exit status and the resulting file before reporting success. "
            "In interactive zsh with APPEND_CREATE disabled, append/create needs '>>|'."
            % (t, t)
        )
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": msg,
        }}))
        sys.exit(0)

sys.exit(0)
PY
exit $?
