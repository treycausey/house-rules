#!/usr/bin/env bash
# PreToolUse: Bash. Block zsh/macOS commands that fail with an error pointing
# at the wrong cause, and name the working spelling. Each rule is a trap that
# cost real time; the list is in rules/CLAUDE.md, "Shell and macOS traps".
# Only command-position words are checked, so docs or heredoc bodies that
# mention these commands pass. exit 2 = blocked, exit 0 = allowed.

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // empty')
[ -z "$cmd" ] && exit 0

python3 - "$cmd" <<'PY'
import re
import shlex
import shutil
import sys

cmd = sys.argv[1]


def strip_heredocs(text):
    """Drop heredoc bodies; they are data, not commands."""
    out, pending = [], []
    for line in text.split("\n"):
        if pending:
            strip, delim = pending[0]
            if (line.lstrip("\t") if strip else line) == delim:
                pending.pop(0)
            continue
        out.append(line)
        for m in re.finditer(r"(?<!<)<<(?!<)(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2", line):
            pending.append((m.group(1) == "-", m.group(3)))
    return "\n".join(out)


SEPS = {";", "&&", "||", "|", "&", "(", ")", "{", "}", "!", "do", "then", "else", "elif"}
PREFIXES = {"sudo", "time", "env", "command", "exec", "nohup", "caffeinate"}


def simple_commands(line):
    """Yield (words, raw_tokens) for each simple command on one line."""
    try:
        lex = shlex.shlex(line, posix=False, punctuation_chars=";&|()")
        lex.whitespace_split = True
        toks = list(lex)
    except ValueError:
        return
    cur = []
    for t in toks:
        if t in SEPS:
            if cur:
                yield cur
            cur = []
            continue
        cur.append(t)
    if cur:
        yield cur


def unquote(t):
    for p in ("$(", "`", "("):
        if t.startswith(p):
            t = t[len(p):]
    return t.strip("\"'")


def check(words):
    in_dbl_bracket = "[[" in words
    # `=word` is expanded by zsh EQUALS anywhere in the command.
    for w in words:
        if not in_dbl_bracket and len(w) > 1 and w[0] == "=":
            return ("zsh expands a word starting with '=' as a command path (EQUALS), "
                    "so %s fails and zsh silently skips the rest of this Bash call. "
                    "Quote it ('%s') or use a divider that does not start with '='." % (w, w))
    i = 0
    while i < len(words) and (words[i] in PREFIXES or re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", words[i])):
        if words[i].startswith("status="):
            return ("zsh reserves 'status' as a read-only variable (alias of $?). "
                    "Use another name such as 'state' or 'st'.")
        i += 1
    if i >= len(words):
        return None
    w = unquote(words[i])
    args = [unquote(a) for a in words[i + 1:]]
    if w == "for" and args[:1] == ["status"]:
        return ("zsh reserves 'status' as a read-only variable (alias of $?). "
                "Use another loop variable such as 'state' or 'st'.")
    if w == "log" and args[:1] and args[0] in {"show", "stream", "collect", "config", "erase", "stats"}:
        return ("In zsh, bare 'log' is a builtin (it lists watched users), so this fails with "
                "'too many arguments'. Spell /usr/bin/log %s ..." % args[0])
    if w in {"timeout", "gtimeout"} and not shutil.which(w):
        return ("macOS has no %s(1); the wrapper would exit 127 and read as the wrapped command failing. "
                "Use the tool's own timeout flag (curl --max-time, ssh -o ConnectTimeout=, nc -w) "
                "or a bash-loop watchdog." % w)
    if w == "strings" and not any(re.fullmatch(r"-[A-Za-z]*a[A-Za-z]*|--all", a) for a in args):
        return ("macOS strings(1) skips the (__TEXT,__text) section without -a, so a missing "
                "match reads as 'never baked in'. Spell: strings -a <binary>")
    if w == "ssh-add" and any(a.startswith("--apple") for a in args):
        return ("Homebrew's ssh-add shadows Apple's and has no long options. "
                "Spell /usr/bin/ssh-add %s" % " ".join(a for a in args if a.startswith("--apple")))
    if w == "mdutil" and "-E" in args and args[-1:] == ["/"]:
        return ("On current macOS '/' is the sealed read-only system volume, so this silently no-ops. "
                "Use: mdutil -E /System/Volumes/Data")
    return None


for line in strip_heredocs(cmd).split("\n"):
    for words in simple_commands(line):
        msg = check(words)
        if msg:
            sys.stderr.write("Blocked by block-shell-traps.sh: " + msg + "\n")
            sys.exit(2)
sys.exit(0)
PY
exit $?
