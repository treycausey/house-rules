#!/usr/bin/env bash
# PreToolUse: Bash
# Blocks destructive git commands that require explicit approval from the user:
#   push with -f / --force (incl. --force-with-lease), reset --hard,
#   checkout / restore (incl. restore --staged) with a whole-tree operand
#   (`.`, `./`, `..`, `../`), and clean with -f / --force.
#
# Only the git command a segment actually RUNS counts. This used to grep the
# raw command text, so quoted mentions and heredoc bodies counted as
# invocations: a spot-check script that only passed `git restore` /
# `git checkout` strings as test-case arguments was blocked, as
# were `echo "git reset --hard"` and `notes "git clean -fd blocked"`. The
# raw grep also missed real invocations: `git -C repo reset --hard`, and any
# force push with an `n` before the flag (`git push origin --force`), because
# `[^|&\n]` in a bracket expression excludes the letter n, not a newline.
#
# The command is split into top-level segments (heredoc bodies dropped, quotes
# respected) and each segment is resolved to the command it invokes, with the
# shared command resolver. `bash -c` / `sh -c` / `zsh -c`
# payloads and `eval` arguments are resolved the same way, recursively.
#
# Command substitutions `$(...)` and backticks, process substitutions
# `<(...)` / `>(...)` and subshells `( ... )` are cut out and resolved the
# same way, recursively, and a placeholder word takes their place in the
# outer command. They run unquoted and inside double quotes, never inside
# single quotes. Substitutions in an unquoted-delimiter heredoc body run too,
# so they are resolved; a quoted-delimiter body is plain data.
#
# Fail closed: the hook falls back to the old anchored regex over the raw
# text, so it never allows what the old hook blocked, when git could run
# where this resolver cannot see it or when it cannot parse the command:
#   - unbalanced parens or quotes, a stray `)` (a `case` pattern), a `case`
#     word, or nesting deeper than MAX_DEPTH;
#   - a command name or a `-c` / eval payload computed by a substitution;
#   - an ssh remote command, or anything run through xargs;
#   - a shell with no script operand or with -s (it runs stdin), and a `-c`
#     payload fed by stdin or holding a `{}` / `$@` placeholder;
#   - python -c, node / bun -e / -p, perl -e / -E, ruby -e, deno eval,
#     osascript -e, and any of those interpreters with no script or `-`
#     whose stdin is a pipe or a `<file`;
#   - a parse error, or a missing python3.
# A shell or interpreter WITH a script operand is resolver-decided even when
# stdin is piped to it: its stdin is data for the script (how every hook is
# tested), and neither hook can see a script's contents.
# An interpreter with no script or `-` whose stdin is a HEREDOC in the same
# segment is resolver-decided too: the body is that interpreter's code, and to
# the shell it is data, exactly like a script file. The raw-regex fallback used
# to read the body as shell text, so `python3 - <<'PY'` with a destructive git
# string in a python string literal was blocked. Shells keep
# falling back (`bash <<EOF` really does run its body as shell code), as do a
# piped or `<file` stdin and -c / -e inline code.
#
# Tested by hooks/tests/run-tests.sh

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // empty')
[ -z "$cmd" ] && exit 0

deny() {
  echo "Blocked: destructive git command requires explicit approval from the user." >&2
  exit 2
}

# Prints exactly one line: `allow`, `block <what>`, or `fallback`.
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
GIT_VALUE_OPTIONS = ("-C", "-c", "--git-dir", "--work-tree", "--namespace",
                     "--exec-path", "--super-prefix")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# Shell words that precede the command a segment runs. The sibling resolvers
# do not skip these; a destructive-git guard must see `{ git reset --hard; }`,
# `if git ...; then`, `do git ...` and `exec git ...`.
SHELL_WORDS = ("!", "{", "if", "then", "elif", "else", "do", "while", "until",
               "exec")
# Shells whose -c payload is itself a command line to resolve. Without -c a
# shell runs a script file, or code from stdin when there is no script.
SHELLS = ("bash", "sh", "zsh", "dash", "ksh")
# Shell options that take a separate value argument.
SHELL_VALUE_OPTIONS = ("-o", "+o", "-O", "+O", "--rcfile", "--init-file")
# Interpreters that can run code from an inline string or from stdin.
INTERPRETERS = ("node", "nodejs", "perl", "ruby", "bun", "deno", "osascript")
# Named so that no line of this heredoc starts with its delimiter: inside a
# command substitution, bash 5.3 ends a heredoc at a line that begins with
# the delimiter text and also holds a paren.
IS_PYTHON = re.compile(r"^python[0-9.]*$")
# A redirect token: `<file`, `<<EOF`, `<<<str`, `2>err`, `>out`.
REDIRECT = re.compile(r"^[0-9]*[<>]")
REDIRECT_IN = re.compile(r"^[0-9]*<")
# A heredoc redirect: `<<EOF`, `<<-EOF`, or the bare `<<` / `<<-` operator.
# `<<<` is a herestring, not a heredoc. strip_heredocs drops the BODY and keeps
# the line that opens it, so this token is still here to be seen.
REDIRECT_HEREDOC = re.compile(r"^[0-9]*<<-?(?!<)")
# A bare redirect operator, whose target is the next token: `<`, `2>`, `<<`.
REDIRECT_OP = re.compile(r"^[0-9]*[<>]+[&|]?$")
# A payload filled in at run time: an xargs `{}` or a positional parameter.
PLACEHOLDER = re.compile(r"\{\}|\$[@*0-9]")
# A whole-tree pathspec, as the ENTIRE operand.
TREE = (".", "./", "..", "../")
MAX_DEPTH = 5
# Built with chr: /bin/bash 3.2 parses a heredoc inside a command
# substitution as shell code, so a lone backtick or paren in a string
# literal here breaks the hook.
OPEN = chr(40)
CLOSE = chr(41)
SUBST = "$" + OPEN
BACKTICK = chr(96)
# Stands in for a cut-out substitution in the outer command.
SUBST_WORD = "__cmdsubst__"


def strip_heredocs(text):
    """Drop heredoc bodies, keeping the command lines that open them.

    Ported verbatim from fix-noclobber-redirect.sh so all three hooks that
    need it share one set of semantics (protect-ssh-config.sh has the
    pure-bash twin). A body is the DATA a command writes somewhere else, not
    a command this shell runs. Only the bodies go: the line that OPENS a
    heredoc is still scanned, because a real invocation can sit on it
    (`cat <<EOF && git push`).
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
        # Leading environment assignments: `FOO=bar git reset --hard`.
        if ASSIGNMENT.match(t):
            i += 1
            continue
        # Options belonging to a wrapper already skipped: `sudo -E git x`.
        if t.startswith("-"):
            i += 1
            continue
        # Wrappers around a real command: `time git push`, `env git x`.
        if os.path.basename(t) in WRAPPERS or t in SHELL_WORDS:
            i += 1
            continue
        # Path-qualified invocations count: `/usr/bin/git push -f`.
        return os.path.basename(t), tokens[i + 1:]
    return None, []


def git_parse(rest):
    """(subcommand, every argument after it, options included)."""
    i = 0
    while i < len(rest):
        t = rest[i]
        if t in GIT_VALUE_OPTIONS:
            i += 2
            continue
        if t.startswith("-"):
            i += 1
            continue
        return t, rest[i + 1:]
    return None, []


def short_cluster_has(arg, letter):
    return arg.startswith("-") and not arg.startswith("--") and letter in arg[1:]


def piped_segments(text):
    """split_segments, paired with whether a pipe feeds each segment.

    split_segments keeps every character that is not a top-level separator,
    so walking the segment lengths through the text finds the separator run
    in front of each one.
    """
    out = []
    pos = 0
    prev = ""
    for segment in split_segments(text):
        out.append((segment, prev.startswith("|") and not prev.startswith("||")))
        pos += len(segment)
        end = pos
        while end < len(text) and text[end] in SEPARATORS:
            end += 1
        prev = text[pos:end]
        pos = end
    return out


def split_args(rest, value_options):
    """(options, operands, stdin redirected, stdin is a heredoc).

    For a shell or interpreter. Options are the flags before the first operand;
    `--` ends them. Redirect tokens and their targets are dropped from both
    lists. A heredoc counts as its own kind of stdin, not as `redirected`: its
    body is visible data, a `<file` is not.
    """
    options = []
    operands = []
    redirected = False
    heredoc = False
    ended = False
    i = 0
    while i < len(rest):
        t = rest[i]
        if REDIRECT.match(t):
            if REDIRECT_IN.match(t):
                if REDIRECT_HEREDOC.match(t):
                    heredoc = True
                else:
                    redirected = True
            i += 2 if REDIRECT_OP.match(t) else 1
            continue
        if not ended and not operands and t == "--":
            ended = True
            i += 1
            continue
        if not ended and not operands and len(t) > 1 and t[0] in "-+":
            options.append(t)
            i += 2 if t in value_options else 1
            continue
        operands.append(t)
        i += 1
    return options, operands, redirected, heredoc


def inline_code(name, rest, operands):
    """True when an interpreter's arguments carry code for it to run."""
    if IS_PYTHON.match(name):
        return any(short_cluster_has(t, "c") for t in rest)
    if name in ("node", "nodejs", "bun"):
        return any(t in ("-e", "-p", "--eval", "--print")
                   or t.startswith("--eval=") or t.startswith("--print=")
                   or short_cluster_has(t, "e") or short_cluster_has(t, "p")
                   for t in rest)
    if name == "perl":
        return any(short_cluster_has(t, "e") or short_cluster_has(t, "E") for t in rest)
    if name in ("ruby", "osascript"):
        return any(short_cluster_has(t, "e") for t in rest)
    if name == "deno":
        return bool(operands) and operands[0] == "eval"
    return False


def runs_code(name):
    """True for a command this hook resolves: git, a shell, an interpreter."""
    return bool(name) and (name == "git" or name in SHELLS
                           or name in INTERPRETERS or IS_PYTHON.match(name) is not None)


def destructive(sub, args):
    """A short name for the destructive form, or None."""
    if sub == "push":
        if any(a.startswith("--force") or short_cluster_has(a, "f") for a in args):
            return "push --force"
    elif sub == "reset":
        if "--hard" in args:
            return "reset --hard"
    elif sub in ("checkout", "restore"):
        if any(a in TREE for a in args):
            return sub + " <whole tree>"
    elif sub == "clean":
        if any(a == "--force" or short_cluster_has(a, "f") for a in args):
            return "clean -f"
    return None


def backtick_end(text, i):
    """Index of the backtick that closes a backtick substitution.

    i is the first index inside it. A backslash escapes the next character.
    """
    n = len(text)
    while i < n:
        if text[i] == "\\":
            i += 2
            continue
        if text[i] == BACKTICK:
            return i
        i += 1
    raise ValueError("unterminated backtick")


def paren_end(text, i):
    """Index of the paren that closes the open paren at text[i].

    Quotes, backslashes, backticks and nested substitutions inside are
    respected. Unbalanced text raises, so the caller falls back.
    """
    depth = 0
    quote = None
    n = len(text)
    while i < n:
        c = text[i]
        if quote == "'":
            if c == "'":
                quote = None
            i += 1
            continue
        if c == "\\":
            i += 2
            continue
        if c == BACKTICK:
            i = backtick_end(text, i + 1) + 1
            continue
        if quote == '"':
            if c == '"':
                quote = None
                i += 1
            elif text.startswith(SUBST, i):
                i = paren_end(text, i + 1) + 1
            else:
                i += 1
            continue
        if c in "\"'":
            quote = c
        elif c == OPEN:
            depth += 1
        elif c == CLOSE:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ValueError("unbalanced paren")


def extract_substitutions(text, heredoc=False):
    """Cut out the code that substitutions and subshells run.

    Returns the outer text and the list of bodies. A command substitution,
    backtick or process substitution becomes SUBST_WORD in the outer text;
    a subshell or a function definition's empty parens become a space. They
    run unquoted and inside double quotes, never inside single quotes. With
    heredoc=True the text is an expanding heredoc body: quote characters are
    literal there, and only substitutions and backslashes count. Unbalanced
    or unterminated text raises, so the caller falls back.
    """
    out = []
    bodies = []
    quote = None
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if quote == "'":
            out.append(c)
            if c == "'":
                quote = None
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            out.append(text[i:i + 2])
            i += 2
            continue
        if c == BACKTICK:
            end = backtick_end(text, i + 1)
            body = text[i + 1:end]
            body = body.replace("\\" + BACKTICK, BACKTICK).replace("\\$", "$")
            bodies.append(body.replace("\\\\", "\\"))
            out.append(SUBST_WORD)
            i = end + 1
            continue
        if text.startswith(SUBST, i):
            end = paren_end(text, i + 1)
            bodies.append(text[i + 2:end])
            out.append(SUBST_WORD)
            i = end + 1
            continue
        if heredoc:
            out.append(c)
            i += 1
            continue
        if quote == '"':
            out.append(c)
            if c == '"':
                quote = None
            i += 1
            continue
        # Unquoted from here on.
        if c in "\"'":
            quote = c
            out.append(c)
            i += 1
            continue
        # A comment: a # that starts a word runs to the end of the line. A
        # shebang line would otherwise tokenize as a bare bash invocation.
        if c == "#" and (i == 0 or text[i - 1] in " \t\n;&|"):
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c in "<>" and text[i + 1:i + 2] == OPEN:
            end = paren_end(text, i + 1)
            bodies.append(text[i + 2:end])
            out.append(SUBST_WORD)
            i = end + 1
            continue
        if c == OPEN:
            end = paren_end(text, i)
            if text[i + 1:end].strip():
                bodies.append(text[i + 1:end])
            out.append(" ")
            i = end + 1
            continue
        if c == CLOSE:
            raise ValueError("stray close paren, such as a case pattern")
        out.append(c)
        i += 1
    if quote:
        raise ValueError("unterminated quote")
    return "".join(out), bodies


def expanding_heredoc_bodies(text):
    """Bodies of heredocs whose delimiter is unquoted.

    The shell expands command substitutions in these bodies. Same parsing as
    strip_heredocs, which is kept verbatim; this copy also records whether a
    delimiter was quoted, and returns the bodies instead of dropping them.
    A heredoc that never meets its terminator raises: strip_heredocs would
    drop every later line, commands included, so the caller falls back.
    """
    bodies = []
    pending = []  # [strip_tabs, delimiter, expands, body lines]
    quote = None
    for line in text.split("\n"):
        if pending:
            strip, delim, expands, lines = pending[0]
            body = line.lstrip("\t") if strip else line
            if body == delim:
                pending.pop(0)
                if expands:
                    bodies.append("\n".join(lines))
            else:
                lines.append(line)
            continue
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
            expands = True
            while i < n and line[i] not in DELIM_END:
                if line[i] in "\"'\\":
                    expands = False
                    i += 1
                    continue
                buf.append(line[i])
                i += 1
            if buf:
                pending.append([strip, "".join(buf), expands, []])
    # An unterminated heredoc that swallowed a real line hides commands from
    # strip_heredocs, so the caller falls back. One that swallowed nothing hid
    # nothing: a substitution body is cut out of text the OUTER pass already
    # stripped, so `x=$(python3 - <<PY` arrives here as a lone opener line.
    if any(l.strip() for _, _, _, lines in pending for l in lines):
        raise ValueError("unterminated heredoc")
    return bodies


def scan(text, depth):
    """The first destructive git form this command line runs, or None."""
    if depth > MAX_DEPTH:
        raise ValueError("nesting too deep")
    # Substitutions in an expanding heredoc body run when the body is read.
    for body in expanding_heredoc_bodies(text):
        for sub in extract_substitutions(body, heredoc=True)[1]:
            hit = scan(sub, depth + 1)
            if hit:
                return hit
    outer, subs = extract_substitutions(strip_heredocs(text))
    for sub in subs:
        hit = scan(sub, depth + 1)
        if hit:
            return hit
    for segment, piped in piped_segments(outer):
        tokens = tokenize(segment)
        # A case pattern ends in a stray close paren; the form with a
        # leading open paren balances, so the word itself falls back.
        if "case" in tokens:
            raise ValueError("case statement")
        name, rest = invoked_command(tokens)
        # A command name computed by a substitution: not visible here.
        if name and SUBST_WORD in name:
            raise ValueError("command name computed at run time")
        # A wrapper the resolver does not know (`uv run python -c`, `timeout
        # 5 bash -c`) or a wrapper option that takes a value (`sudo -u me
        # git`) stops the resolver on the wrong token. So when the resolved
        # command is not git, a shell or an interpreter, the first later
        # standalone token that is one counts. A token with whitespace in it
        # is quoted text, not a command word.
        if not runs_code(name):
            for k, t in enumerate(tokens):
                if runs_code(os.path.basename(t)) and not any(c.isspace() for c in t):
                    name, rest = os.path.basename(t), tokens[k + 1:]
                    break
        # xargs builds the commands it runs from stdin: fail closed.
        prefix = tokens[:len(tokens) - len(rest) - 1] if name else tokens
        if any(os.path.basename(t) == "xargs" for t in prefix):
            raise ValueError("xargs")
        if name == "git":
            hit = destructive(*git_parse(rest))
            if hit:
                return hit
        elif name in SHELLS:
            options, operands, redirected, heredoc = split_args(rest, SHELL_VALUE_OPTIONS)
            if any(short_cluster_has(o, "c") for o in options):
                # `bash -c 'payload'`, `bash -lc 'payload'`: the payload is the
                # first operand. Fail closed when stdin feeds it, or when a
                # placeholder or a substitution fills it in at run time. A
                # shell's heredoc is shell code, so it fails closed as well.
                if (piped or redirected or heredoc or not operands
                        or PLACEHOLDER.search(operands[0]) or SUBST_WORD in operands[0]):
                    raise ValueError("shell payload not fixed")
                hit = scan(operands[0], depth + 1)
                if hit:
                    return hit
            elif not operands or any(short_cluster_has(o, "s") for o in options):
                # No script file, or -s: the shell runs code from stdin.
                raise ValueError("shell reads stdin")
        elif runs_code(name):
            # An interpreter runs inline code, or code from stdin when it has
            # no script operand or `-` as its script. With a script, stdin is
            # data for that script.
            options, operands, redirected, heredoc = split_args(rest, ())
            if inline_code(name, rest, operands):
                raise ValueError("interpreter code not visible")
            if not operands or operands[0] == "-":
                # A heredoc in this same segment IS that code, and the shell
                # never runs a word of it -- the same standing as a script
                # file, which this hook is also blind to. A pipe or a `<file`
                # carries code from somewhere this hook cannot see, so both
                # still fail closed; a pipe also wins over the heredoc here.
                if piped or redirected or not heredoc:
                    raise ValueError("interpreter code not visible")
        elif name == "eval":
            hit = scan(" ".join(rest), depth + 1)
            if hit:
                return hit
        elif name == "ssh":
            # A remote command line is not resolved here: fail closed.
            raise ValueError("ssh payload")
    return None


try:
    hit = scan(cmd, 0)
    print("block " + hit if hit else "allow")
except Exception:
    print("fallback")
PY
)

case "$verdict" in
  allow) exit 0 ;;
  block\ *) deny ;;
esac

# Fallback: the resolver gave no verdict or cannot see everything this command
# runs. Use the old anchored regex over the raw text. A whole-tree pathspec is
# `.`, `./`, `..` or `../` as the ENTIRE argument, followed by whitespace, end
# of line, a shell separator, or a closing quote; unanchored, `\.` also
# matched a dotfile path such as `.gitignore`.
tree='\.{1,2}/?(\s|$|[;&|)"'\''`])'

if echo "$cmd" | grep -qE "git\s+(push\s+[^|&\n]*(-f\b|--force)|reset\s+--hard|checkout\s+${tree}|restore\s+(${tree}|--staged\s+${tree})|clean\s+-[a-zA-Z]*f)"; then
  deny
fi

exit 0
