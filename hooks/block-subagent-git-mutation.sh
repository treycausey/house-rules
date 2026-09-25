#!/usr/bin/env bash
# PreToolUse: Bash
# Blocks a SUBAGENT from mutating shared git state: stash, checkout, switch,
# reset, commit. Enforces the CLAUDE.md rule "Subagents must not mutate shared
# git state unless that is their task."
#
# Why a hook and not just the rule: one week had three incidents
# in two projects -- a subagent's mid-run `git stash` silently reverted staged
# fixes into a commit, and a `git checkout -b` in a checkout another process
# was using caused a real merge conflict. The rule was already in CLAUDE.md
# for all of them.
#
# Subagent detection mirrors block-edit-without-read.sh: the harness sets a
# top-level `agent_id` on subagent tool calls and omits it for the main agent
# (verified against the harness). Main-agent commands are never touched here.
#
# Escape hatch: when git mutation IS the subagent's task, the orchestrator
# says so in the prompt and the subagent prefixes the command with
# SUBAGENT_GIT_OK=1 (a leading env assignment on that git segment). That
# leaves an explicit trace in the transcript instead of a silent bypass.
#
# Read-only stash forms (`git stash list`, `git stash show`) are allowed.
# Hard resets and force pushes are also caught by block-destructive-git.sh
# for every agent; this hook is the subagent-only superset.
#
# Tested by hooks/tests/run-tests.sh

input=$(cat)
agent_id=$(echo "$input" | jq -r '.agent_id // empty')
[ -n "$agent_id" ] || exit 0

cmd=$(echo "$input" | jq -r '.tool_input.command // empty')
[ -n "$cmd" ] || exit 0

# Same quote-aware, heredoc-dropping segment splitter as pre-commit-lint.sh:
# only a segment that actually INVOKES git counts, never a quoted mention.
verdict=$(python3 - "$cmd" <<'PY' 2>/dev/null
import os
import re
import shlex
import sys

cmd = sys.argv[1]

SEPARATORS = ";\n|&"
DELIM_END = " \t;&|<>"
WRAPPERS = ("sudo", "time", "env", "command", "xargs", "nice", "nohup")
GIT_OPTS_WITH_VALUE = ("-C", "-c", "--git-dir", "--work-tree", "--namespace",
                       "--exec-path", "--super-prefix")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
BLOCKED = {"stash", "checkout", "switch", "reset", "commit"}
STASH_READ_ONLY = {"list", "show"}
ESCAPE = "SUBAGENT_GIT_OK=1"


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


def git_mutation(tokens):
    """Return the blocked git subcommand this segment runs, or None."""
    i = 0
    escaped = False
    while i < len(tokens):
        t = tokens[i]
        if ASSIGNMENT.match(t):
            if t == ESCAPE:
                escaped = True
            i += 1
            continue
        if t.startswith("-"):
            i += 1
            continue
        if os.path.basename(t) in WRAPPERS:
            i += 1
            continue
        break
    if i >= len(tokens) or os.path.basename(tokens[i]) != "git":
        return None
    i += 1
    while i < len(tokens) and tokens[i].startswith("-"):
        if tokens[i] in GIT_OPTS_WITH_VALUE:
            i += 2
        else:
            i += 1
    if i >= len(tokens):
        return None
    sub = tokens[i]
    if sub not in BLOCKED:
        return None
    if sub == "stash":
        rest = [t for t in tokens[i + 1:] if not t.startswith("-")]
        if rest and rest[0] in STASH_READ_ONLY:
            return None
    if escaped:
        return None
    return sub


for segment in split_segments(strip_heredocs(cmd)):
    sub = git_mutation(tokenize(segment))
    if sub:
        sys.stdout.write(sub + "\n")
        break
PY
)
[ -n "$verdict" ] || exit 0

cat >&2 <<EOF
Blocked: subagents must not run 'git $verdict' -- it mutates git state shared with the main session and other agents (CLAUDE.md, Subagents). This week's incidents: a mid-run stash reverted staged fixes; a checkout -b in a shared worktree caused a merge conflict.
Leave the working tree as it is and report what you changed; the orchestrator commits, stashes, and switches branches.
If git mutation IS your assigned task, the prompt said so -- re-run with an explicit acknowledgement: SUBAGENT_GIT_OK=1 git $verdict ...
EOF
exit 2
