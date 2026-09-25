#!/usr/bin/env bash
# PreToolUse: Bash
# Blocks git add when the staged paths include .env files, .DS_Store, or tmp/.
# For .DS_Store it also auto-fixes the repo (gitignore entry + untracking any
# indexed copies) so the same block does not recur -- flagged as a repeating
# nuisance by two months of weekly reviews.
#
# This used to gate on `^\s*git\s+add` and then grep the WHOLE command string,
# which was wrong in both directions:
#   - false positive: `git add src/foo.ts && echo "=== .env staged? ==="` was
#     blocked, because `.env` appeared in an echo argument.
#   - false negative: `echo x && git add .env` was allowed, because the command
#     did not START with `git add`.
# It now splits the command on shell separators, keeps the segments that are
# themselves `git add` invocations, and matches only their path operands.

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
[ -z "$cmd" ] && exit 0

python3 - "$cmd" "$cwd" <<'PY'
import os
import shlex
import subprocess
import sys

cmd = sys.argv[1]
cwd = sys.argv[2] if len(sys.argv) > 2 else ""

SEPARATORS = ";\n|&"


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


def git_add_paths(tokens):
    """Return the path operands if these tokens are a `git add`, else None."""
    if not tokens or tokens[0] != "git":
        return None
    i = 1
    # Skip git's own global options so `git -C dir add .env` is still seen.
    while i < len(tokens) and tokens[i].startswith("-"):
        if tokens[i] in ("-C", "-c", "--git-dir", "--work-tree", "--namespace"):
            i += 2
        else:
            i += 1
    if i >= len(tokens) or tokens[i] != "add":
        return None
    paths = []
    end_of_options = False
    for t in tokens[i + 1:]:
        if not end_of_options:
            if t == "--":
                end_of_options = True
                continue
            if t.startswith("-"):
                continue
        paths.append(t)
    return paths


def sensitive(path):
    """Match the same three things the old whole-string grep looked for."""
    parts = path.split("/")
    for p in parts:
        if p in (".env", ".env.local"):
            return True
        if p.endswith(".DS_Store"):
            return True
    # Anything under a tmp/ directory (and the tmp/ directory itself).
    if "tmp" in parts:
        return True
    return False


def auto_fix_ds_store(repo_cwd):
    """Convert the recurring .DS_Store block into a one-time fix: ignore the
    name repo-wide and untrack any copies already in the index. Best-effort --
    the block stands regardless of whether this succeeds. Returns a list of
    actions taken, or None when there was nothing to act on (no cwd, not a
    git repo, or git itself failed)."""
    if not repo_cwd or not os.path.isdir(repo_cwd):
        return None
    try:
        top = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=repo_cwd, capture_output=True, text=True, timeout=10,
        )
        if top.returncode != 0:
            return None
        root = top.stdout.strip()
        actions = []

        gitignore = os.path.join(root, ".gitignore")
        content = ""
        if os.path.exists(gitignore):
            with open(gitignore) as f:
                content = f.read()
        if ".DS_Store" not in (line.strip() for line in content.splitlines()):
            with open(gitignore, "a") as f:
                if content and not content.endswith("\n"):
                    f.write("\n")
                f.write(".DS_Store\n")
            actions.append("added .DS_Store to %s" % gitignore)

        ls = subprocess.run(
            ["git", "ls-files", "-z"],
            cwd=root, capture_output=True, text=True, timeout=10,
        )
        tracked = [
            p for p in ls.stdout.split("\0")
            if p and os.path.basename(p) == ".DS_Store"
        ]
        if tracked:
            subprocess.run(
                ["git", "rm", "--cached", "-q", "--"] + tracked,
                cwd=root, capture_output=True, timeout=10,
            )
            actions.append("untracked %d indexed cop%s"
                           % (len(tracked), "y" if len(tracked) == 1 else "ies"))
        return actions
    except Exception:
        return None


for segment in split_segments(cmd):
    paths = git_add_paths(tokenize(segment))
    if not paths:
        continue
    for path in paths:
        if sensitive(path):
            message = (
                "Blocked: refusing to stage secrets or temp files "
                "(.env, .DS_Store, tmp/). Offending path: %s\n" % path
            )
            if os.path.basename(path).endswith(".DS_Store"):
                actions = auto_fix_ds_store(cwd)
                if actions:
                    message += (
                        "Auto-fixed so this stops recurring: %s. "
                        "Re-run your git add without the .DS_Store path.\n"
                        % "; ".join(actions)
                    )
            sys.stderr.write(message)
            sys.exit(2)

sys.exit(0)
PY
exit $?
