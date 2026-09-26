#!/usr/bin/env bash
HOUSE_RULES_HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
. "$HOUSE_RULES_HOOK_DIR/lib/hook-tools.sh"
house_rules_require jq python3
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
import re
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


REDIRECT = re.compile(r"[0-9]*(?:>>?|<<?|>&|<&|\|&)")


def strip_redirects(tokens):
    """Drop shell redirect operators and their targets, wherever in a token
    they start.

    `git add -A 2>/dev/null` tokenizes to ["git", "add", "-A", "2>/dev/null"]
    -- without this, "2>/dev/null" reads as a pathspec operand, which
    silently scopes the broad-add worktree check to that bogus path and
    misses every real sensitive file. `shlex.split` does not treat `<`/`>`
    as word separators the way a real shell does, so a redirect glued
    directly onto a flag with no space (`-A>/dev/null`, from
    `git add -A>/dev/null`) survives as ONE token too -- this splits at the
    first redirect character found anywhere in a token, not only at its
    start, and keeps whatever real content came before it (`-A`). A bare
    operator with its target as a separate token (`2> /dev/null`) drops
    both.
    """
    out = []
    i = 0
    n = len(tokens)
    while i < n:
        t = tokens[i]
        m = REDIRECT.search(t)
        if m:
            prefix = t[:m.start()]
            if prefix:
                out.append(prefix)
            if m.end() == len(t):
                # The operator ran to the end of this token, so its target
                # (if any) is the NEXT token, space-separated.
                i += 2
                continue
            i += 1
            continue
        out.append(t)
        i += 1
    return out


def tokenize(segment):
    try:
        tokens = shlex.split(segment)
    except ValueError:
        # Unbalanced quotes: fall back to a whitespace split rather than
        # letting a malformed command skip the check entirely.
        tokens = segment.split()
    return strip_redirects(tokens)


def git_add_paths(tokens):
    """Return (path operands, broad add, git -C directories) for a `git add`,
    else None. `-C` directories are collected in order; git applies each
    relative to the previous one, chaining left to right."""
    if not tokens or tokens[0] != "git":
        return None
    i = 1
    git_c_dirs = []
    # Skip git's own global options so `git -C dir add .env` is still seen.
    while i < len(tokens) and tokens[i].startswith("-"):
        if tokens[i] == "-C":
            if i + 1 < len(tokens):
                git_c_dirs.append(tokens[i + 1])
            i += 2
        elif tokens[i] in ("-c", "--git-dir", "--work-tree", "--namespace"):
            i += 2
        else:
            i += 1
    if i >= len(tokens) or tokens[i] != "add":
        return None
    paths = []
    broad = False
    end_of_options = False
    for t in tokens[i + 1:]:
        if not end_of_options:
            if t == "--":
                end_of_options = True
                continue
            if t.startswith("-"):
                if t in ("-A", "--all", "-u", "--update") or has_broad_short_flag(t):
                    broad = True
                continue
        paths.append(t)
    if any(path in (".", "./") or is_broad_pathspec(path) for path in paths):
        broad = True
    return paths, broad, git_c_dirs


def has_broad_short_flag(t):
    """A short-option cluster (never `--long`) bundling -A or -u with other
    letters, e.g. `-Av` or `-vA` -- git reads either as a broad add, but an
    exact match against "-A" alone would miss it."""
    return t.startswith("-") and not t.startswith("--") and t != "-" and any(c in "Au" for c in t[1:])


def is_broad_pathspec(p):
    """A pathspec whose real scope is not "this literal relative path".

    `:/` and `:(top)...` (or any other `:(...)` magic) match from the
    repository root regardless of cwd; a pathspec containing a `..`
    segment climbs above cwd. Either way the literal string cannot be
    trusted to narrow the worktree check the way an ordinary relative path
    does, so a git add carrying one is treated as broad and, in the
    caller, is not used to scope the check at all.
    """
    if p.startswith(":/") or p.startswith(":("):
        return True
    return p == ".." or any(part == ".." for part in p.split("/"))


def resolve_git_c(base_cwd, git_c_dirs):
    """The working directory `git -C <dir> [-C <dir2> ...]` actually runs in."""
    cwd = base_cwd
    for d in git_c_dirs:
        if not d:
            continue
        cwd = d if os.path.isabs(d) else os.path.join(cwd or "", d)
    return cwd


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


def sensitive_changes(repo_cwd, pathspecs):
    """Return sensitive paths a broad git add would stage in this repo.

    With an explicit pathspec (an operand such as `src/`, or the bare `.` /
    `./` that scopes a broad add to the current directory), the check is
    scoped to it, run from repo_cwd so git resolves the pathspec exactly the
    way the real `git add` would. With no pathspec (a bare `-A` / `-u`), `-A`
    and `-u` genuinely operate on the whole working tree regardless of cwd,
    so the check runs from the repo root instead.
    """
    if not repo_cwd or not os.path.isdir(repo_cwd):
        return []
    try:
        top = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], cwd=repo_cwd,
            capture_output=True, text=True, timeout=10,
        )
        if top.returncode != 0:
            return []
        root = top.stdout.strip()
        run_cwd = repo_cwd if pathspecs else root
        cmd = ["git", "ls-files", "--modified", "--deleted", "--others",
               "--exclude-standard", "-z"]
        if pathspecs:
            cmd.append("--")
            cmd.extend(pathspecs)
        changed = subprocess.run(
            cmd, cwd=run_cwd, capture_output=True, text=True, timeout=10,
        )
        if changed.returncode != 0:
            return []
        return [path for path in changed.stdout.split("\0") if path and sensitive(path)]
    except Exception:
        return []


for segment in split_segments(cmd):
    result = git_add_paths(tokenize(segment))
    if result is None:
        continue
    paths, broad, git_c_dirs = result
    work_cwd = resolve_git_c(cwd, git_c_dirs)
    # A pathspec operand (including the bare "." that scopes a broad add to
    # the current directory) narrows a broad add's real footprint; a bare
    # `-A` / `-u` with no operand does not, and is repo-wide. A magic
    # (`:/`, `:(...)`) or `..`-escaping pathspec is not trustworthy as a
    # narrowing scope either way, so it forces the same repo-wide scan as
    # no pathspec at all rather than being handed to git literally.
    if any(is_broad_pathspec(p) for p in paths):
        pathspecs = []
    else:
        pathspecs = paths

    # Broad add forms can stage a changed, already-tracked .env file even when
    # the command does not name it. Inspect the worktree before allowing them.
    # If the event has no cwd (and no git -C), keep the hook pure and leave
    # the verdict to git.
    if broad and work_cwd:
        for path in sensitive_changes(work_cwd, pathspecs):
            message = (
                "Blocked: refusing to stage secrets or temp files "
                "(.env, .DS_Store, tmp/) through a broad git add. "
                "Offending path: %s\n" % path
            )
            if os.path.basename(path) == ".DS_Store":
                actions = auto_fix_ds_store(work_cwd)
                if actions:
                    message += "Auto-fixed: %s.\n" % "; ".join(actions)
            sys.stderr.write(message)
            sys.exit(2)

    for path in paths:
        if sensitive(path):
            message = (
                "Blocked: refusing to stage secrets or temp files "
                "(.env, .DS_Store, tmp/). Offending path: %s\n" % path
            )
            if os.path.basename(path).endswith(".DS_Store"):
                actions = auto_fix_ds_store(work_cwd)
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
