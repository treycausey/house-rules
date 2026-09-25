#!/usr/bin/env bash
# PreToolUse: Bash, Read
# Blocks a bare dump of a known token-bearing file into the transcript and
# names a redacted read instead.
#
# Two live credentials leaked into transcripts in one week, each
# needing a manual rotate: `cat ~/.config/gh/hosts.yml` during a keychain
# diagnosis printed the gh OAuth token, and an audit of the Buildkite agent
# config printed its registration token. protect-secrets-files.sh guards only
# destruction/overwrite of secrets files; nothing guarded reads.
#
# A transcript leak is irreversible (the transcript is stored and synced), so
# this blocks rather than warns. The cost of a false positive is one re-typed
# command with a filter on it; the cost of a false negative is a key rotation.
#
# What counts as a read: dumpers (cat, head, tail, less, bat, strings, xxd...)
# with the file as an operand; grep/rg whose pattern targets the secret field
# (token|secret|pass|key|auth|cred|redact) without -v; sed/awk whose script does
# not mention those words (a script that names them, or says "redact", is
# assumed to be redacting); jq/yq with the identity filter. Field extraction
# (`yq '.["github.com"].user'`), `grep -v -i token` and
# `sed -E 's/=.*/=<redacted>/'` go through untouched.
#
# Project .env files ARE on the list now, and that reverses the
# earlier "read constantly during ordinary work, so never guarded" rule: a
# subagent printed a live NEXT_PUBLIC_API_KEY out of a project .env.local into
# its transcript during a Varlock migration, and only the system paths above
# were matched, so nothing fired. They are matched by CONTENT, not by name
# alone, which is what makes guarding them survivable. The name rule mirrors
# protect-secrets-files.sh: .env.schema never counts, any .env.<anything>.local
# always counts, a basename holding example|sample|template|dist|mock|test
# never counts, and otherwise .env and .env.<anything> count. A named file is a
# hit only when it holds at least one KEY=value whose value looks like a
# credential, so a .env.local of ports and localhost URLs still reads freely,
# and a file that does not exist is never a hit. The hook reads such a file to
# decide and never prints a byte of it.
#
# `varlock load` is a dump with extra steps: it resolves the env
# files and PRINTS them. Only its default pretty output and `--agent` redact;
# `--format env|shell|json|json-full` print every value in plaintext, and
# `varlock run --no-redact-stdout` un-redacts the child's output. A scratch
# `varlock load --format shell` ran in a real project instead of the scratch dir
# (the cd had failed silently) and printed ten live keys into a transcript.
# Any explicit --format other than pretty is blocked, whatever the cwd, since
# the hook cannot know which directory the command will actually run in.
#
# (Named "token-file", not "secret-file": protect-secrets-files.sh treats any
# basename containing "secret" as a secrets file and blocked creating it.)
#
# Tested by hooks/tests/run-tests.sh

input=$(cat)
tool=$(echo "$input" | jq -r '.tool_name // empty')

normalize() {
  local p=$1
  p=${p/#\~/$HOME}
  p=${p//\$HOME/$HOME}
  p=${p//\$\{HOME\}/$HOME}
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  printf '%s' "$p"
}

redacted_hint() {
  local p base lower
  p=$(normalize "$1")
  base=${p##*/}
  lower=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    .env|.env.*)
      echo "  varlock load                        # resolved config, values redacted (repos with .env.schema)"
      echo "  grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' $p   # key names only"
      echo "  sed -E 's/=.*/=<redacted>/' $p      # every value dropped"
      return
      ;;
  esac
  case "$p" in
    "$HOME/.config/gh/hosts.yml")
      echo "  gh auth status                      # who is logged in; the token is never shown"
      echo "  grep -vi token ~/.config/gh/hosts.yml   # user, protocol, hosts; tokens dropped"
      ;;
    *buildkite-agent.cfg)
      echo "  grep -viE 'token' $p"
      ;;
    *)
      echo "  grep -viE 'token|secret|password|key|auth' $p"
      echo "  sed -E 's/((token|secret|password|key)[^=:]*[=:]).*/\\1 <redacted>/I' $p"
      ;;
  esac
}

deny() {
  {
    echo "Blocked: '$1' would print $2 into the transcript, and it holds a live credential."
    echo "A transcript leak is permanent and costs a key rotation. Read it redacted instead:"
    redacted_hint "$2"
    echo "If you only need to know whether it exists or is well-formed: ls -l, wc -l, or a field extraction that never selects the secret."
  } >&2
  exit 2
}

# The classifier. Shared by both tools so the path list lives in one place.
classify() {
  HOME="$HOME" PWD_="$PWD" python3 - "$@" <<'PY' 2>/dev/null
import os
import re
import shlex
import sys

mode = sys.argv[1]
arg = sys.argv[2]
HOME = os.environ["HOME"]
CWD = os.environ.get("PWD_") or os.getcwd()
SEPARATORS = ";\n|&"
WRAPPERS = ("sudo", "time", "env", "command", "xargs", "nice", "nohup")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
DUMPERS = {"cat", "head", "tail", "less", "more", "bat", "batcat", "strings",
           "xxd", "hexdump", "od", "nl", "tac", "view", "vim", "vi", "nano",
           "open", "pbcopy", "tee"}
FILTERS = {"grep", "egrep", "fgrep", "rg", "ag", "ack"}
SCRIPTERS = {"sed", "awk", "gawk", "perl"}
QUERIERS = {"jq", "yq"}
SECRET_WORDS = re.compile(r"token|secret|pass|key|auth|cred|redact", re.I)
# --- env files ------------------------------------------------------------
# The name rule, on the lowercased basename, mirrors protect-secrets-files.sh.
ENV_EXEMPT = re.compile(r"example|sample|template|dist|mock|test")
# `KEY=value` or `export KEY=value`; group 1 is the raw value.
ENV_ASSIGNMENT = re.compile(r"^[ \t]*(?:export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*=(.*)$")
# Value prefixes that are a credential whatever their character mix.
CRED_PREFIX = re.compile(r"^(sk-|sk_|ghp_|gho_|github_pat_|xox[abpors]-|AKIA|eyJ|pk_|rk_|key-|AIza)")
# A URL value: a connection string is config, not a credential, unless it
# carries a password in its userinfo. `http://127.0.0.1:8080` otherwise passes
# the character-class test on lower+digit+punctuation alone.
URL_VALUE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*://")
URL_PASSWORD = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*://[^/@\s]+:[^/@\s]+@")
# A trailing `# comment` on an unquoted value.
TRAILING_COMMENT = re.compile(r"\s+#")
MAX_ENV_LINES = 2000
H = re.escape(HOME)
SECRET_RE = re.compile(
    r"^(" + H + r"/\.config/gh/hosts\.yml"
    r"|.*/buildkite-agent\.cfg"
    r"|" + H + r"/\.buildkite-agent/.*"
    r"|" + H + r"/\.netrc"
    r"|" + H + r"/\.npmrc"
    r"|" + H + r"/\.pypirc"
    r"|" + H + r"/\.git-credentials"
    r"|" + H + r"/\.docker/config\.json"
    r"|" + H + r"/\.aws/credentials"
    r"|" + H + r"/\.codex/auth\.json"
    r"|" + H + r"/\.claude/\.credentials\.json"
    r"|" + H + r"/\.gemini/oauth_creds\.json"
    r"|" + H + r"/\.config/gcloud/.*credentials.*\.json"
    r"|" + H + r"/\.kube/config"
    r"|" + H + r"/\.cargo/credentials(\.toml)?"
    r"|" + H + r"/\.ssh/id_[a-z0-9_]+"
    r"|.*\.pem)$",
    re.I,
)


def normalize(p):
    if p == "~" or p.startswith("~/"):
        p = HOME + p[1:]
    p = p.replace("${HOME}", HOME).replace("$HOME", HOME)
    if not p.startswith("/"):
        p = os.path.join(CWD, p)
    return os.path.normpath(p)


def env_candidate(path):
    """True when the basename names a project env file that could hold values."""
    base = os.path.basename(path).lower()
    if base == ".env.schema":
        return False
    if base.startswith(".env.") and base.endswith(".local"):
        return True
    if ENV_EXEMPT.search(base):
        return False
    return base == ".env" or base.startswith(".env.")


def credential_value(raw):
    """True when a KEY=value value looks like a live credential.

    Never returns or logs the value itself. `3000`, `true`,
    `http://127.0.0.1:8080` and `postgres://localhost/db` are config.
    """
    v = raw.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        v = v[1:-1]
    else:
        v = TRAILING_COMMENT.split(v, 1)[0].strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
    if len(v) < 16 or any(c.isspace() for c in v):
        return False
    if CRED_PREFIX.match(v):
        return True
    if URL_VALUE.match(v):
        return bool(URL_PASSWORD.match(v))
    classes = sum([
        any(c.islower() for c in v),
        any(c.isupper() for c in v),
        any(c.isdigit() for c in v),
        any(not c.isalnum() for c in v),
    ])
    return classes >= 3


def env_holds_credential(path):
    """True when the file exists and holds at least one credential value."""
    try:
        with open(path, "r", errors="replace") as fh:
            for i, line in enumerate(fh):
                if i >= MAX_ENV_LINES:
                    break
                m = ENV_ASSIGNMENT.match(line)
                if m and credential_value(m.group(1)):
                    return True
    except (OSError, ValueError):
        return False
    return False


ENV_CACHE = {}


def is_secret(p):
    q = normalize(p)
    if SECRET_RE.match(q):
        return True
    if not env_candidate(q):
        return False
    if q not in ENV_CACHE:
        ENV_CACHE[q] = env_holds_credential(q)
    return ENV_CACHE[q]


if mode == "path":
    if is_secret(arg):
        print("Read\t" + arg)
    sys.exit(0)


def split_segments(text):
    segments, current, quote, i, n = [], [], None, 0, len(text)
    while i < n:
        c = text[i]
        if quote:
            current.append(c)
            if c == "\\" and quote == '"' and i + 1 < n:
                current.append(text[i + 1]); i += 2; continue
            if c == quote:
                quote = None
            i += 1; continue
        if c == "\\" and i + 1 < n:
            current.append(c); current.append(text[i + 1]); i += 2; continue
        if c in "\"'":
            quote = c; current.append(c); i += 1; continue
        if c in SEPARATORS:
            segments.append("".join(current)); current = []
            while i < n and text[i] in SEPARATORS:
                i += 1
            continue
        current.append(c); i += 1
    segments.append("".join(current))
    return segments


def tokenize(segment):
    try:
        return shlex.split(segment)
    except ValueError:
        return segment.split()


def resolve(tokens):
    """(command basename, flags, operands) past env assignments and wrappers."""
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if ASSIGNMENT.match(t) or t.startswith("-") or os.path.basename(t) in WRAPPERS:
            i += 1; continue
        break
    if i >= len(tokens):
        return None, [], []
    name = os.path.basename(tokens[i])
    flags, operands = [], []
    j = i + 1
    while j < len(tokens):
        t = tokens[j]
        if t == "--":
            operands.extend(tokens[j + 1:]); break
        if t in ("<", "<<<"):
            j += 1
            if j < len(tokens):
                operands.append(tokens[j])
            j += 1; continue
        if t in (">", ">>", "2>", "&>", "2>&1"):
            j += 2; continue
        (flags if t.startswith("-") and len(t) > 1 else operands).append(t)
        j += 1
    return name, flags, operands


for segment in split_segments(arg):
    name, flags, operands = resolve(tokenize(segment))
    if not name:
        continue
    secrets = [o for o in operands if is_secret(o)]
    if not secrets:
        continue
    target = secrets[0]
    others = [o for o in operands if o not in secrets]
    if name in DUMPERS:
        print(name + "\t" + target); break
    if name in FILTERS:
        inverted = "--invert-match" in flags or any(
            f.startswith("-") and not f.startswith("--") and "v" in f for f in flags)
        pattern = others[0] if others else ""
        if not inverted and SECRET_WORDS.search(pattern):
            print(name + "\t" + target); break
        continue
    if name in SCRIPTERS:
        script = " ".join(others[:1] + [f for f in flags if f.startswith(("-e", "--expression"))])
        if not SECRET_WORDS.search(script):
            print(name + "\t" + target); break
        continue
    if name in QUERIERS:
        filt = others[0].strip() if others else ""
        if filt in ("", "."):
            print(name + "\t" + target); break
        continue
PY
}

case "$tool" in
  Read)
    file=$(echo "$input" | jq -r '.tool_input.file_path // empty')
    [ -n "$file" ] || exit 0
    result=$(classify path "$file")
    ;;
  *)
    cmd=$(echo "$input" | jq -r '.tool_input.command // empty')
    [ -n "$cmd" ] || exit 0
    # Cheap pre-filter: nothing to do unless a listed name appears at all.
    echo "$cmd" | grep -qiE 'hosts\.yml|buildkite-agent|\.netrc|\.npmrc|\.pypirc|git-credentials|\.docker/config\.json|\.aws/credentials|\.codex/auth\.json|\.credentials\.json|oauth_creds\.json|gcloud/.*credentials|\.kube/config|\.cargo/credentials|\.ssh/id_|\.pem\b|\.env|varlock' || exit 0
    # varlock: an explicit plaintext format on `load`, or un-redacted `run`
    # output, prints resolved secrets whatever directory it runs in. The
    # segment scan stops at ; & | so a later pipeline stage cannot hide it.
    # Matched anywhere in the text, quotes included: `bash -c "..."` and
    # `eval "$(...)"` are real execution paths, so a quoted mention in an
    # echo is blocked too. That false positive costs one rephrased command.
    if printf '%s' "$cmd" | grep -qE 'varlock[[:space:]]+load([[:space:]][^;&|]*)?[[:space:]](--format|-f)([[:space:]]+|=)(env|shell|json|json-full)([[:space:]]|$|["'"'"')`])'; then
      {
        echo "Blocked: 'varlock load' with an explicit plaintext --format prints every resolved secret into the transcript."
        echo "Only the default pretty output and --agent redact. A transcript leak is permanent and costs a key rotation (one such leak cost ten)."
        echo "Read it redacted instead:"
        echo "  varlock load                 # pretty, values masked"
        echo "  varlock load --agent         # JSON, values masked; key names for scripting"
        echo "  grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' .env.local   # key names only"
      } >&2
      exit 2
    fi
    if printf '%s' "$cmd" | grep -qE 'varlock[[:space:]]+run([[:space:]][^;&|]*)?[[:space:]]--no-redact-stdout([[:space:]]|$|["'"'"'])'; then
      {
        echo "Blocked: 'varlock run --no-redact-stdout' prints the child's output with resolved secrets un-masked."
        echo "Drop the flag; varlock redacts piped output on purpose. If a value must cross machines, do it in your own terminal with a byte-equality check (see ~/.claude/CLAUDE.md)."
      } >&2
      exit 2
    fi
    result=$(classify command "$cmd")
    ;;
esac

[ -n "$result" ] || exit 0
deny "${result%%	*}" "${result#*	}"
