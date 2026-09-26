#!/usr/bin/env bash
HOUSE_RULES_HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
. "$HOUSE_RULES_HOOK_DIR/lib/hook-tools.sh"
house_rules_require jq python3
# PreToolUse: Bash, Edit|Write
# Blocks a SUBAGENT from destroying or overwriting files OUTSIDE the session's
# project root. Enforces the CLAUDE.md rule "Keep parallel agents on disjoint
# files" at the filesystem level instead of on trust.
#
# Why a hook and not just the rule: during a secrets-manager migration, a
# subagent's Bash cwd drifted into a sibling repo -- an off-limits project --
# where it ran `rm -f .gitignore` and then wrote test content
# over the file. That was the second cwd-confusion incident with real file
# damage in the same cycle. The hook input's `cwd` is the Bash tool's CURRENT
# directory (it moves with every `cd`), which is exactly the value the agent
# loses track of, so the guard resolves relative operands against it rather
# than trusting them.
#
# Subagent detection mirrors block-subagent-git-mutation.sh: the harness sets a
# top-level `agent_id` on subagent tool calls and omits it for the main agent.
# Main-agent commands are never touched here.
#
# Scope = the project root + always-allowed scratch zones + any extra roots the
# ORCHESTRATOR listed in "$scratchpad_dir/subagent-scope" (one absolute path
# per line, `~` allowed, `#` comments). That file is the designed way to widen
# a subagent's scope before dispatching it.
#
# Always-allowed scratch zones:
#   - the hook input's own `scratchpad_dir`
#   - its parent session directory (holds this session's tasks/ and
#     tool-results/)
#   - the system temp directory and $TMPDIR when set, EXCEPT per-session
#     Claude scratch trees under them. Those belong to one session each, and a
#     subagent must not overwrite another session's scratchpad or task files.
#     They are excluded from generic temp roots and reachable only through this
#     session's own scratchpad/session roots above.
#   - ~/.Trash, and /dev/null, /dev/stdout, /dev/stderr, /dev/tty
#
# The project root is not in the hook input, so it is decoded from the encoded
# project directory component of `transcript_path`
# (~/.claude/projects/<encoded>/...) or `scratchpad_dir`
# (a per-session temp directory/<encoded>/<session>/scratchpad). `<encoded>` is the
# absolute path with every character outside [A-Za-z0-9-] replaced by `-`, so
# decoding is ambiguous whenever a directory name contains `-`, `.` or a space
# (`-Users-alice--claude`, `-Users-alice-dev-my-plugin-github`,
# `...-Library-Application-Support-...`). It is resolved by walking the real
# filesystem with backtracking instead of by string surgery. If that fails,
# the hook fails OPEN: a guard that cannot locate the root must not block all
# work.
#
# Escape hatch: a leading SUBAGENT_PATH_OK=1 env assignment on that segment
# allows it, mirroring SUBAGENT_GIT_OK in block-subagent-git-mutation.sh. That
# leaves an explicit trace in the transcript instead of a silent bypass.
#
# Guarded: rm/rmdir/unlink/truncate/shred (every operand), mv (sources AND
# destination -- moving a file out is destruction in place), cp/install/rsync
# (destination), tee without -a, truncating redirects (`>` `>|` `&>` `N>`, not
# `>>`), sed -i, perl -i, and git checkout/restore/clean path operands.
# chmod/chown are deliberately NOT guarded.
#
# Tested by hooks/tests/run-tests.sh

input=$(cat)

# Cheapest possible bail: the main agent is never touched.
agent_id=$(echo "$input" | jq -r '.agent_id // empty')
[ -n "$agent_id" ] || exit 0

tool_name=$(echo "$input" | jq -r '.tool_name // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')
scratchpad_dir=$(echo "$input" | jq -r '.scratchpad_dir // empty')

case "$tool_name" in
  Edit|Write|MultiEdit|NotebookEdit)
    mode=path
    payload=$(echo "$input" | jq -r '.tool_input.file_path // empty')
    ;;
  *)
    mode=bash
    payload=$(echo "$input" | jq -r '.tool_input.command // empty')
    ;;
esac
[ -n "$payload" ] || exit 0

# Second bail, still pure bash: a command with none of the guarded words and no
# redirect character cannot possibly trip this hook, so it never pays for
# python3. This is the overwhelming majority of Bash calls.
if [ "$mode" = bash ]; then
  case "$payload" in
    *rm*|*mv*|*cp*|*install*|*rsync*|*tee*|*sed*|*perl*|*truncate*|*shred*|*unlink*|*git*|*'>'*) ;;
    *) exit 0 ;;
  esac
fi

verdict=$(python3 - "$mode" "$payload" "$cwd" "$transcript_path" "$scratchpad_dir" <<'PY'
import os
import re
import shlex
import sys

mode, payload, cwd, transcript_path, scratchpad_dir = sys.argv[1:6]

HOME = os.path.expanduser("~")
cwd = cwd or os.getcwd()

SEPARATORS = ";\n|&"
DELIM_END = " \t;&|<>"
WRAPPERS = ("sudo", "time", "env", "command", "xargs", "nice", "nohup",
            "stdbuf", "timeout")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
ESCAPE = "SUBAGENT_PATH_OK=1"

RM_FAMILY = {"rm", "rmdir", "unlink", "truncate", "shred"}
VALUE_FLAGS = {"truncate": {"-s", "-r", "--size", "--reference"},
               "shred": {"-n", "-s", "--iterations", "--size"}}
DEST_ONLY = {"cp", "install", "rsync"}
GIT_OPTS_WITH_VALUE = ("-C", "-c", "--git-dir", "--work-tree", "--namespace",
                       "--exec-path", "--super-prefix")
GIT_PATH_SUBS = {"checkout", "restore", "clean"}
UNRESOLVABLE = re.compile("[$\\x60*?\\[]")
ALWAYS_ALLOWED_FILES = {"/dev/null", "/dev/stdout", "/dev/stderr", "/dev/tty"}

# Per-session Claude scratch trees. Generic temp directories are allowed, but
# each claude-<uid> subdirectory belongs to one session. Those trees are not
# covered by generic temp roots; only this session's scratchpad and session
# directory are added as explicit roots.
#
# Both spellings of each temp root are tracked -- the literal path (e.g.
# /tmp, or whatever $TMPDIR names) and its realpath (e.g. /private/tmp on
# macOS, where /tmp is a symlink). A subagent command can name a temp path
# either way, and the per-session exclusion must catch a scratch tree spelled
# either way too, or one spelling falls through as a generic-temp bypass.
def temp_root_spellings(root):
    if not root:
        return []
    root = os.path.normpath(root)
    out = [root]
    try:
        real = os.path.realpath(root)
    except OSError:
        real = root
    if real != root:
        out.append(real)
    return out


CLAUDE_TREE = "claude-%d" % os.getuid()
TEMP_ROOTS = []
for _root in ("/tmp", os.environ.get("TMPDIR")):
    for _spelling in temp_root_spellings(_root):
        if _spelling not in TEMP_ROOTS:
            TEMP_ROOTS.append(_spelling)
CLAUDE_SESSION_TREES = tuple(
    os.path.join(root.rstrip("/"), CLAUDE_TREE) + "/"
    for root in TEMP_ROOTS if root
)


# --- project-root decoding --------------------------------------------------

def encode_name(name):
    return re.sub(r"[^A-Za-z0-9-]", "-", name)


def decode_project_dir(encoded, budget=None):
    """Walk the real filesystem to undo the '/'->'-' project-dir encoding.

    Shortest matching real directory name first, backtracking when a later
    step has no match, so '-Users-alice-dev-my-plugin-github' lands on
    the real ~/dev/my-plugin-github and not on a ~/dev/my that happens to
    exist. Returns None when nothing on disk matches.
    """
    if budget is None:
        budget = [20000]
    encoded = (encoded or "").strip()
    if not encoded.startswith("-"):
        return None

    def walk(base, rest):
        if not rest:
            return base
        if budget[0] <= 0:
            return None
        budget[0] -= 1
        try:
            entries = os.listdir(base)
        except OSError:
            return None
        cands = []
        for e in entries:
            ee = encode_name(e)
            if rest == ee:
                cands.append((len(ee), e, ""))
            elif rest.startswith(ee + "-"):
                cands.append((len(ee), e, rest[len(ee) + 1:]))
        cands.sort(key=lambda t: (t[0], t[1]))
        for _, e, nxt in cands:
            p = os.path.join(base, e)
            if not os.path.isdir(p) or os.path.islink(p):
                continue
            got = walk(p, nxt)
            if got:
                return got
        return None

    return walk("/", encoded[1:])


def encoded_component():
    """The <encoded> project-dir component, from transcript_path or scratchpad."""
    for path, marker in ((transcript_path, "projects"),
                         (scratchpad_dir, CLAUDE_TREE)):
        if not path:
            continue
        parts = [p for p in path.split("/") if p]
        for i, p in enumerate(parts):
            if p == marker and i + 1 < len(parts):
                return parts[i + 1]
    return None


def read_scope_file():
    if not scratchpad_dir:
        return []
    out = []
    try:
        with open(os.path.join(scratchpad_dir, "subagent-scope")) as fh:
            for line in fh:
                line = line.split("#", 1)[0].strip()
                if not line:
                    continue
                if line.startswith("~"):
                    line = os.path.expanduser(line)
                if line.startswith("/"):
                    out.append(os.path.normpath(line))
    except OSError:
        pass
    return out


# --- path normalisation -----------------------------------------------------

def expand(raw):
    """Return an absolute normalised path, or None when it is not literal."""
    s = raw
    if s == "~" or s.startswith("~/"):
        s = HOME + s[1:]
    s = s.replace("${HOME}", HOME).replace("$HOME", HOME)
    if UNRESOLVABLE.search(s):
        return None
    if not s.startswith("/"):
        s = os.path.join(cwd, s)
    return os.path.normpath(s)


def variants(p):
    """The path plus its symlink-resolved form."""
    out = [p]
    d = os.path.dirname(p) or "/"
    try:
        r = os.path.normpath(os.path.join(os.path.realpath(d),
                                          os.path.basename(p)))
    except OSError:
        r = p
    if r != p:
        out.append(r)
    return out


def session_dir_root():
    """The session directory holding this session's scratchpad/tasks/tool-results.

    Returns None when it cannot be trusted: a scratchpad_dir one level too
    shallow (e.g. a per-session temp path with no encoded project component)
    would make its parent the whole
    claude-<uid> tree, which is exactly the blanket allowance this guard drops.
    """
    if not scratchpad_dir or not scratchpad_dir.startswith("/"):
        return None
    parent = os.path.dirname(os.path.normpath(scratchpad_dir))
    if parent in ("", "/"):
        return None
    for tree in CLAUDE_SESSION_TREES:
        if parent == tree.rstrip("/"):
            return None
    return parent


def build_roots():
    roots = []
    seen = set()

    def add(p, generic=False):
        if not p:
            return
        for v in variants(os.path.normpath(p)):
            if v not in seen:
                seen.add(v)
                roots.append((v, generic))

    add(project_root)
    add(scratchpad_dir)
    add(session_dir_root())
    for _t in TEMP_ROOTS:
        add(_t, generic=True)
    add(os.path.join(HOME, ".Trash"))
    for extra in read_scope_file():
        add(extra)
    return roots


def in_claude_session_tree(p):
    return any(p.startswith(tree) for tree in CLAUDE_SESSION_TREES)


def in_scope(p):
    if p in ALWAYS_ALLOWED_FILES:
        return True
    for v in variants(p):
        session_tree = in_claude_session_tree(v)
        for root, generic in ROOTS:
            # Generic temp does not cover another session's scratch tree.
            if generic and session_tree:
                continue
            if v == root or v.startswith(root.rstrip("/") + "/"):
                return True
    return False


# --- command splitting (same shape as block-subagent-git-mutation.sh) --------

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


def read_word(text, j):
    """Read one shell word starting at j; returns (word, next_index)."""
    n = len(text)
    while j < n and text[j] in " \t":
        j += 1
    buf = []
    quote = None
    while j < n:
        ch = text[j]
        if quote:
            if ch == quote:
                quote = None
            else:
                buf.append(ch)
            j += 1
            continue
        if ch in "\"'":
            quote = ch
            j += 1
            continue
        if ch == "\\" and j + 1 < n:
            buf.append(text[j + 1])
            j += 2
            continue
        if ch in " \t\n;|&<>":
            break
        buf.append(ch)
        j += 1
    return "".join(buf), j


def skip_substitution(text, j):
    """Skip a '>(...)' / '<(...)' body; j points at the opening paren."""
    depth = 0
    n = len(text)
    while j < n:
        if text[j] == "(":
            depth += 1
        elif text[j] == ")":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return n


def scan_redirects(segment):
    """Split a segment into (command text, truncating redirect targets).

    Redirect operators and their targets are removed from the command text so
    they never look like operands, and only truncating forms are reported --
    '>>' and '&>>' append, '2>&1' duplicates a descriptor.
    """
    keep = []
    targets = []
    quote = None
    i = 0
    n = len(segment)
    while i < n:
        c = segment[i]
        if quote:
            keep.append(c)
            if c == "\\" and quote == '"' and i + 1 < n:
                keep.append(segment[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            keep.append(c)
            keep.append(segment[i + 1])
            i += 2
            continue
        if c in "\"'":
            quote = c
            keep.append(c)
            i += 1
            continue
        if c not in "<>":
            keep.append(c)
            i += 1
            continue
        # A leading descriptor number belongs to the operator, not the command.
        while keep and keep[-1].isdigit():
            keep.pop()
        j = i + 1
        truncating = c == ">"
        if j < n and segment[j] == c:            # >> or <<
            truncating = False
            j += 1
        elif j < n and segment[j] == "&":        # 2>&1, >&2
            truncating = False
            j += 1
        elif j < n and segment[j] == "|":        # >|
            j += 1
        if j < n and segment[j] == "(":          # >(cmd) / <(cmd)
            i = skip_substitution(segment, j)
            continue
        word, j = read_word(segment, j)
        if truncating and word:
            targets.append(word)
        i = j
    return "".join(keep), targets


def tokenize(segment):
    try:
        return shlex.split(segment)
    except ValueError:
        return segment.split()


# --- operand extraction -----------------------------------------------------

def lead(tokens):
    """Skip env assignments and wrappers; returns (index, escaped)."""
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
    return i, escaped


def operands(tokens, skip_values=frozenset()):
    out = []
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if t in skip_values:
            i += 2
            continue
        if t.startswith("-") and t != "-":
            i += 1
            continue
        if t not in ("", "-"):
            out.append(t)
        i += 1
    return out


def has_inplace_flag(tokens, letters):
    """True when a short-option cluster or long option requests in-place edit."""
    for t in tokens:
        if not t.startswith("-") or t.startswith("--"):
            continue
        body = t[1:].split(".", 1)[0]
        if any(ch in body for ch in letters):
            return True
    return False


def guarded_paths(segment):
    """Return (list of (path, op), unresolvable_destructive_operand or None)."""
    text, redirects = scan_redirects(segment)
    tokens = tokenize(text)
    i, escaped = lead(tokens)
    if escaped:
        return [], None

    checks = []          # (raw operand, operation label)
    for t in redirects:
        checks.append((t, "truncating redirect (>)"))

    if i < len(tokens):
        name = os.path.basename(tokens[i])
        rest = tokens[i + 1:]

        if name in RM_FAMILY:
            for op in operands(rest, VALUE_FLAGS.get(name, frozenset())):
                checks.append((op, name))
        elif name == "mv":
            for op in operands(rest):
                checks.append((op, "mv"))
        elif name in DEST_ONLY:
            ops = operands(rest)
            if ops:
                checks.append((ops[-1], name + " destination"))
        elif name == "tee":
            if not any(t in ("-a", "--append") or
                       (t.startswith("-") and not t.startswith("--") and "a" in t[1:])
                       for t in rest):
                for op in operands(rest):
                    checks.append((op, "tee"))
        elif name == "sed":
            if has_inplace_flag(rest, "iI") or any(
                    t.startswith("--in-place") for t in rest):
                files = operands(rest)
                if not any(t in ("-e", "-f", "--expression", "--file") or
                           t.startswith("--expression=") or t.startswith("--file=")
                           for t in rest) and files:
                    files = files[1:]          # the first operand is the script
                for op in files:
                    checks.append((op, "sed -i"))
        elif name == "perl":
            if has_inplace_flag(rest, "i"):
                for op in operands(rest, {"-e", "-E", "-M", "-I"}):
                    checks.append((op, "perl -i"))
        elif name == "git":
            j = 0
            while j < len(rest) and rest[j].startswith("-"):
                j += 2 if rest[j] in GIT_OPTS_WITH_VALUE else 1
            if j < len(rest) and rest[j] in GIT_PATH_SUBS:
                sub = rest[j]
                tail = rest[j + 1:]
                paths = tail[tail.index("--") + 1:] if "--" in tail else operands(tail)
                for op in paths:
                    checks.append((op, "git " + sub))

    resolved = []
    for raw, op in checks:
        p = expand(raw)
        if p is None:
            if op in RM_FAMILY:
                return [], (raw, op)
            continue
        resolved.append((p, op))
    return resolved, None


# --- main -------------------------------------------------------------------

encoded = encoded_component()
project_root = decode_project_dir(encoded) if encoded else None
if not project_root:
    sys.stderr.write(
        "block-subagent-path-escape.sh: could not resolve the project root "
        "from transcript_path/scratchpad_dir (encoded: %r) -- failing open.\n"
        % (encoded,))
    raise SystemExit(0)

ROOTS = build_roots()
roots_line = ", ".join(root for root, _ in ROOTS[:4])


def deny(kind, subject, op):
    sys.stdout.write("%s\t%s\t%s\t%s\n" % (kind, subject, op, roots_line))
    raise SystemExit(0)


if mode == "path":
    p = expand(payload)
    if p is not None and not in_scope(p):
        deny("OUT", p, "write")
    raise SystemExit(0)

for segment in split_segments(strip_heredocs(payload)):
    paths, unresolvable = guarded_paths(segment)
    if unresolvable:
        deny("UNRESOLVED", unresolvable[0], unresolvable[1])
    for p, op in paths:
        if not in_scope(p):
            deny("OUT", p, op)
PY
)

[ -n "$verdict" ] || exit 0

kind=$(printf '%s' "$verdict" | cut -f1)
subject=$(printf '%s' "$verdict" | cut -f2)
op=$(printf '%s' "$verdict" | cut -f3)
roots=$(printf '%s' "$verdict" | cut -f4)
scope_file="${scratchpad_dir:-<scratchpad_dir>}/subagent-scope"

if [ "$kind" = UNRESOLVED ]; then
  cat >&2 <<EOF
Blocked: '$op' here has an operand this guard cannot resolve to a literal path: $subject
A subagent may only delete inside its assigned scope, and a variable, command substitution, or glob hides what would actually be removed. Incident: during a config migration, a subagent's Bash cwd drifted into an off-limits sibling project, and 'rm -f .gitignore' destroyed a file there (CLAUDE.md: "Keep parallel agents on disjoint files").
Re-run with a literal absolute path so the scope check can see the target, or print the expansion first and delete each path by name.
In-scope roots: $roots
EOF
  exit 2
fi

cat >&2 <<EOF
Blocked: '$op' targets $subject, which is outside this subagent's assigned scope.
In-scope roots: $roots
Your Bash cwd is currently ${cwd:-unknown} -- run 'pwd' before using a relative path. Incident: during a config migration, a subagent's cwd drifted into an off-limits sibling project, where it ran 'rm -f .gitignore' and then overwrote the file -- the second cwd-confusion incident with real file damage that cycle (CLAUDE.md: "Keep parallel agents on disjoint files").
Two ways forward:
  1. Report the path to the orchestrator. If the work genuinely belongs there, the orchestrator appends the directory to $scope_file (one absolute path per line) and re-dispatches you.
  2. For a deliberate one-off in Bash, prefix that segment with an explicit acknowledgement: SUBAGENT_PATH_OK=1 <your command>
EOF
exit 2
