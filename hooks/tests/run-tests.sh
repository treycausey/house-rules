#!/usr/bin/env bash
# Test harness for the hooks in this directory.
#
# One integrity check (every hook the example settings file wires exists),
# a parse check under both /bin/bash and PATH bash, and per-hook behaviour
# tests. The integrity checks exist because both of these shipped broken and
# stayed broken:
#
#   1. settings.json referenced a hook script that did not exist. Every
#      PreToolUse Bash and Edit/Write call exited 127 into the void.
#   2. A scheduled script parsed under bash 5 but not under /bin/bash (3.2),
#      which is what launchd actually runs. Same class of bug applies to
#      hooks: settings.json invokes them as `bash <script>`, and `bash` there
#      is whatever the agent's PATH resolves, not necessarily the shebang.
#
# Run from anywhere:   bash hooks/tests/run-tests.sh
# Test an install:     HOOKS_DIR=~/.claude/hooks SETTINGS=~/.claude/settings.json bash hooks/tests/run-tests.sh
#
# Needs: bash, jq, python3 (3.9+), git.

set -uo pipefail

HOOKS_DIR="${HOOKS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
SETTINGS="${SETTINGS:-$HOOKS_DIR/settings.example.json}"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"

# Keep fixtures away from the live home directory. This also makes the suite
# usable in restricted workspaces where $HOME is read-only.
mkdir -p "$REPO_ROOT/tmp"
TEST_HOME=$(mktemp -d "$REPO_ROOT/tmp/hook-test-home.XXXXXX") || exit 1
HOME="$TEST_HOME"
export HOME
trap 'rm -rf "$TEST_HOME"' EXIT

pass=0
fail=0

ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }

section() { printf '\n== %s ==\n' "$1"; }

# ---------------------------------------------------------------------------
# 1. Every hook referenced by settings.json exists on disk.
# ---------------------------------------------------------------------------
section "referenced hooks exist"
refs=$(python3 - "$SETTINGS" <<'PY'
import json, re, sys
s = json.load(open(sys.argv[1]))
out = set()
def walk(o):
    if isinstance(o, dict):
        for v in o.values(): walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
    elif isinstance(o, str):
        for m in re.findall(r'\.claude/hooks/([A-Za-z0-9._-]+)', o):
            out.add(m)
walk(s)
print("\n".join(sorted(out)))
PY
)
[ -z "$refs" ] && bad "no hook references found in settings.json"
while IFS= read -r h; do
  [ -z "$h" ] && continue
  if [ -f "$HOOKS_DIR/$h" ]; then ok "referenced: $h"
  else bad "referenced but missing: $h" "settings.json wires it; the call will exit 127"; fi
done <<< "$refs"

if [ -f "$REPO_ROOT/scripts/build-plugins.sh" ]; then
  section "plugin scripts match hooks source"
  if bash "$REPO_ROOT/scripts/build-plugins.sh" --check; then
    ok "generated plugin files are in sync"
  else
    bad "plugin copies are out of sync; run bash scripts/build-plugins.sh"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Missing jq must make ordinary hooks fail open with one concise note.
# ---------------------------------------------------------------------------
section "missing required tool"
NO_JQ=$(mktemp -d "${TMPDIR:-/tmp}/hook-no-jq.XXXXXX")
BASH_BIN=$(command -v bash)
dep_out=$(PATH="$NO_JQ" "$BASH_BIN" -c '. "$1"; house_rules_require jq' _ "$HOOKS_DIR/lib/hook-tools.sh" 2>&1)
dep_rc=$?
dep_lines=$(printf '%s\n' "$dep_out" | wc -l | tr -d ' ')
if [ "$dep_rc" -eq 0 ] && [ "$dep_lines" -eq 1 ] \
   && printf '%s' "$dep_out" | grep -q 'required command not found: jq'; then
  ok "missing jq fails open with one stderr line"
else
  bad "missing jq must fail open with one stderr line" "exit $dep_rc: $dep_out"
fi
rm -rf "$NO_JQ"

# ---------------------------------------------------------------------------
# 3. Every hook parses under the oldest bash it could be run with.
#    macOS /bin/bash is 3.2.57 and has the heredoc-inside-$() parsing bug.
# ---------------------------------------------------------------------------
section "hooks parse under /bin/bash (3.2) and shebang interpreter"
for f in "$HOOKS_DIR"/*.sh; do
  [ -e "$f" ] || continue
  n=$(basename "$f")
  if err=$(/bin/bash -n "$f" 2>&1); then ok "parses under /bin/bash: $n"
  else bad "parse error under /bin/bash: $n" "$err"; fi
  # settings.json runs hooks as `bash <path>`, which is Homebrew bash 5.3 on
  # PATH. 5.3 has its own parse bug: inside $(...), a quoted-heredoc body line
  # that starts with the delimiter text and contains a paren ends the heredoc.
  if err=$(bash -n "$f" 2>&1); then ok "parses under PATH bash: $n"
  else bad "parse error under PATH bash ($(bash -c 'echo $BASH_VERSION')): $n" "$err"; fi
done
for f in "$HOOKS_DIR"/*.py; do
  [ -e "$f" ] || continue
  n=$(basename "$f")
  if err=$(python3 -m py_compile "$f" 2>&1); then ok "compiles: $n"
  else bad "syntax error: $n" "$err"; fi
done

# ---------------------------------------------------------------------------
# 4. Behaviour: protect-ssh-config.sh
#    exit 2 = blocked, exit 0 = allowed.
# ---------------------------------------------------------------------------
section "protect-ssh-config.sh behaviour"
HOOK="$HOOKS_DIR/protect-ssh-config.sh"

run_bash_hook() { printf '{"tool_input":{"command":%s}}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" | bash "$HOOK" 2>/dev/null; }
run_edit_hook() { printf '{"tool_input":{"file_path":%s}}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" | bash "$HOOK" 2>/dev/null; }

expect_block_cmd() { run_bash_hook "$1"; [ $? -eq 2 ] && ok "blocks cmd: $1" || bad "should block cmd: $1"; }
expect_allow_cmd() { run_bash_hook "$1"; [ $? -eq 0 ] && ok "allows cmd: $1" || bad "should allow cmd: $1"; }
expect_block_path() { run_edit_hook "$1"; [ $? -eq 2 ] && ok "blocks path: $1" || bad "should block path: $1"; }
expect_allow_path() { run_edit_hook "$1"; [ $? -eq 0 ] && ok "allows path: $1" || bad "should allow path: $1"; }

if [ ! -f "$HOOK" ]; then
  bad "protect-ssh-config.sh missing; skipping behaviour tests"
else
  # Mutating shell commands against ~/.ssh must be blocked.
  expect_block_cmd 'echo "Host x" >> ~/.ssh/config'
  expect_block_cmd 'echo x > ~/.ssh/config'
  expect_block_cmd '> ~/.ssh/config'
  expect_block_cmd "sed -i '' 's/a/b/' ~/.ssh/config"
  expect_block_cmd 'cat foo | tee ~/.ssh/config'
  expect_block_cmd 'rm ~/.ssh/config'
  expect_block_cmd 'mv /tmp/foo ~/.ssh/config'
  expect_block_cmd 'cp /tmp/foo ~/.ssh/config'
  expect_block_cmd 'echo k >> $HOME/.ssh/authorized_keys'
  LINUX_HOME="/$(printf '%s/%s' home example)"
  expect_block_cmd "rm $LINUX_HOME/.ssh/id_ed25519"
  expect_block_cmd "rm -rf $LINUX_HOME/.ssh"
  expect_block_cmd 'truncate -s 0 ~/.ssh/known_hosts'

  # Reads and unrelated paths must pass through.
  expect_allow_cmd 'cat ~/.ssh/config'
  expect_allow_cmd 'grep -n Host ~/.ssh/config'
  expect_allow_cmd 'ls -la ~/.ssh'
  expect_allow_cmd 'ssh-add -l'
  expect_allow_cmd 'echo hi > /tmp/foo'
  expect_allow_cmd 'ssh myhost uptime'
  expect_allow_cmd 'echo x > ~/dev/proj/ssh/config'
  # Copying *out* of ~/.ssh is a read. Only the destination is protected.
  # Added because a mutation that matched mv/cp anywhere in the command,
  # rather than only as the final argument, passed the whole suite.
  expect_allow_cmd 'cp ~/.ssh/config /tmp/backup-config'
  expect_allow_cmd 'mv ~/.ssh/config.bak /tmp/'

  # The whole command string is not the command. A heredoc BODY is data being
  # written into some other file -- a CI workflow that provisions a deploy key
  # on a GitHub runner names ~/.ssh but touches this machine's not at all --
  # and a quoted argument is an argument's content, not a redirection target.
  # Every one of these was blocked, forcing a fall back to the Write tool.
  expect_allow_cmd $'cat > deploy.yml <<\'YAML\'\n  - run: echo "$KEY" >> ~/.ssh/id_ed25519\nYAML'
  expect_allow_cmd $'cat > deploy.yml <<-EOF\n\techo k >> ~/.ssh/authorized_keys\n\tEOF'
  expect_allow_cmd $'cat > doc.md <<EOF\nrun: echo x > $HOME/.ssh/config\nEOF'
  expect_allow_cmd "echo 'to add a key: echo k >> ~/.ssh/authorized_keys'"
  expect_allow_cmd 'grep -rn "echo x > ~/.ssh/config" docs/'
  expect_allow_cmd "rg 'tee ~/.ssh/config' notes/"
  expect_allow_cmd "papercuts 'hook blocks rm ~/.ssh/config mentions'"
  # A sed -i in one segment said nothing about a path read in another.
  expect_allow_cmd "sed -i '' 's/a/b/' README.md && cat ~/.ssh/config"

  # Closed in the same pass, in the other direction: the rules now match the
  # command each segment resolves to and that segment's own path operands, so
  # a path-qualified name counts and a trailing 2>&1 no longer hides the
  # destination behind it.
  expect_block_cmd '/bin/rm ~/.ssh/id_ed25519'
  expect_block_cmd 'sudo rm ~/.ssh/known_hosts'
  expect_block_cmd 'mv /tmp/foo ~/.ssh/config 2>/dev/null'
  expect_block_cmd 'cat foo | tee -a ~/.ssh/authorized_keys'
  expect_block_cmd 'cat >| ~/.ssh/config'

  # Edit/Write targets.
  expect_block_path "$HOME/.ssh/config"
  expect_block_path '~/.ssh/config'
  expect_block_path "$HOME/.ssh/id_ed25519"
  expect_allow_path "$HOME/dev/someproj/ssh_config"
  expect_allow_path '/tmp/config'
fi

# ---------------------------------------------------------------------------
# 5. Behaviour: block-sensitive-git-add.sh
#    It used to grep the WHOLE command string after gating on a leading
#    `git add`, which was wrong both ways: `git add src/foo.ts && echo
#    "=== .env staged? ==="` was blocked over an echo argument, while
#    `echo x && git add .env` sailed through because the command did not
#    start with `git add`. Only the path operands of a `git add` count.
# ---------------------------------------------------------------------------
section "block-sensitive-git-add.sh behaviour"
GITADD_HOOK="$HOOKS_DIR/block-sensitive-git-add.sh"

run_gitadd_hook() { printf '{"tool_input":{"command":%s}}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" | bash "$GITADD_HOOK" 2>/dev/null; }

expect_gitadd_block() { run_gitadd_hook "$1"; [ $? -eq 2 ] && ok "blocks cmd: $1" || bad "should block cmd: $1"; }
expect_gitadd_allow() { run_gitadd_hook "$1"; [ $? -eq 0 ] && ok "allows cmd: $1" || bad "should allow cmd: $1"; }

if [ ! -f "$GITADD_HOOK" ]; then
  bad "block-sensitive-git-add.sh missing; skipping behaviour tests"
else
  # A sensitive name mentioned outside the path operands is not a staged path.
  expect_gitadd_allow 'git add src/foo.ts && echo "=== .env staged? ==="'
  expect_gitadd_allow 'git add src/a.ts src/b.ts'
  expect_gitadd_allow 'git add docs/environment.md'
  expect_gitadd_allow 'git commit -m "mention .env in the message"'
  # Bare -A / . stage everything; the old hook allowed them and so does this
  # one. The block list is about explicitly named paths.
  expect_gitadd_allow 'git add -A'
  expect_gitadd_allow 'git add .'

  # A broad add can stage a modified .env file if it is already tracked. The
  # hook must inspect the worktree instead of trusting the pathspec alone.
  BROAD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gitadd-broad-tests.XXXXXX")
  git -C "$BROAD_DIR" init -q
  printf 'SECRET=old\n' > "$BROAD_DIR/.env"
  printf 'source\n' > "$BROAD_DIR/source.txt"
  git -C "$BROAD_DIR" add -f .env source.txt
  git -C "$BROAD_DIR" -c user.name=fixture -c user.email=fixture.invalid commit -qm initial
  printf '{"cwd":%s,"tool_input":{"command":"git add -A"}}' \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$BROAD_DIR")" \
    | bash "$GITADD_HOOK" 2>/dev/null
  [ $? -eq 0 ] && ok "allows broad add with no sensitive changes" || bad "should allow a clean broad add"
  printf 'SECRET=new\n' > "$BROAD_DIR/.env"
  printf '{"cwd":%s,"tool_input":{"command":"git add -A"}}' \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$BROAD_DIR")" \
    | bash "$GITADD_HOOK" 2>/dev/null
  [ $? -eq 2 ] && ok "blocks broad add when tracked .env changed" \
                || bad "broad git add must not stage a changed .env"
  rm -rf "$BROAD_DIR" 2>/dev/null || bad "could not remove fixture dir $BROAD_DIR"

  # Actual sensitive path operands, wherever the git add sits in the command.
  expect_gitadd_block 'git add .env'
  expect_gitadd_block 'git add path/to/.env.local'
  expect_gitadd_block 'git add tmp/scratch.txt'
  expect_gitadd_block 'git add src/.DS_Store'
  expect_gitadd_block 'echo "staging" && git add .env'
  # Flags are skipped, not treated as paths.
  expect_gitadd_block 'git add -f -- .env'

  # .DS_Store auto-fix: given a cwd inside a git repo, the block also makes
  # itself unnecessary -- .gitignore gains the entry and indexed copies are
  # untracked. Without a cwd (every test above) the hook must stay pure
  # block, so running this suite from inside a real repo has no side effects.
  DS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gitadd-hook-tests.XXXXXX")
  git -C "$DS_DIR" init -q
  mkdir -p "$DS_DIR/sub"
  : > "$DS_DIR/sub/.DS_Store"
  # -f: the global gitignore already covers .DS_Store, so a plain add is
  # silently skipped and the untracking assertion below would pass vacuously.
  git -C "$DS_DIR" add -f sub/.DS_Store
  printf '{"cwd":%s,"tool_input":{"command":"git add .DS_Store"}}' \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$DS_DIR")" \
    | bash "$GITADD_HOOK" 2>/dev/null
  [ $? -eq 2 ] && ok "blocks .DS_Store with cwd set" || bad "should block .DS_Store with cwd set"
  if grep -qx '.DS_Store' "$DS_DIR/.gitignore" 2>/dev/null; then
    ok "auto-added .DS_Store to .gitignore"
  else bad "did not add .DS_Store to .gitignore"; fi
  if git -C "$DS_DIR" ls-files | grep -q '\.DS_Store'; then
    bad "indexed .DS_Store was not untracked"
  else ok "untracked the indexed .DS_Store"; fi
  # Idempotent: a second block must not duplicate the gitignore entry.
  printf '{"cwd":%s,"tool_input":{"command":"git add .DS_Store"}}' \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$DS_DIR")" \
    | bash "$GITADD_HOOK" 2>/dev/null
  n=$(grep -cx '.DS_Store' "$DS_DIR/.gitignore" 2>/dev/null)
  [ "$n" = "1" ] && ok "gitignore entry not duplicated on re-block" || bad "gitignore has $n .DS_Store entries, expected 1"
  # A non-.DS_Store block in the same repo must not touch anything.
  before=$(cat "$DS_DIR/.gitignore")
  printf '{"cwd":%s,"tool_input":{"command":"git add .env"}}' \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$DS_DIR")" \
    | bash "$GITADD_HOOK" 2>/dev/null
  [ $? -eq 2 ] && [ "$before" = "$(cat "$DS_DIR/.gitignore")" ] \
    && ok ".env block leaves the repo untouched" || bad ".env block modified the repo"
  rm -rf "$DS_DIR" 2>/dev/null || bad "could not remove fixture dir $DS_DIR"
fi

# ---------------------------------------------------------------------------
# Behaviour: block-tmux-kill-server.sh
# ---------------------------------------------------------------------------
section "block-tmux-kill-server.sh behaviour"
TMUX_HOOK="$HOOKS_DIR/block-tmux-kill-server.sh"
run_tmux_hook() { printf '{"tool_input":{"command":%s}}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" | bash "$TMUX_HOOK" 2>/dev/null; }
run_tmux_hook 'tmux kill-server'
[ $? -eq 2 ] && ok "blocks tmux kill-server" || bad "should block tmux kill-server"
run_tmux_hook 'sudo tmux kill-server'
[ $? -eq 2 ] && ok "blocks wrapped tmux kill-server" || bad "should block a wrapped tmux kill-server"
run_tmux_hook '/usr/bin/tmux kill-server'
[ $? -eq 2 ] && ok "blocks a path-qualified tmux kill-server" || bad "should block a path-qualified tmux kill-server"
run_tmux_hook 'tmux list-sessions'
[ $? -eq 0 ] && ok "allows tmux list-sessions" || bad "should allow tmux list-sessions"

# ---------------------------------------------------------------------------
# 6. Behaviour: fix-noclobber-redirect.sh
#    It used to scrape `>` targets out of the raw command with a regex, so a
#    `>` inside a quoted regex counted as a redirection. `rg -o '<h2>.*</h2>'
#    page.html` produced the bogus target `.*`, which the unquoted
#    `for t in $targets` then glob-expanded against the working directory --
#    blocking a read-only grep for clobbering `.env`, a name that appears
#    nowhere in the command. Only a real redirection operator counts.
#    Heredoc bodies were the same bug one layer down (2026-08-24): the body
#    line `<string>/bin/bash</string>` of a plist write parsed as a redirect
#    onto /bin/bash, which exists, so the write was blocked. Bodies are data
#    bound elsewhere and are dropped; the line that opens the heredoc is not.
# ---------------------------------------------------------------------------
section "fix-noclobber-redirect.sh behaviour"
NOCLOBBER_HOOK="$HOOKS_DIR/fix-noclobber-redirect.sh"

run_noclobber_hook() { printf '{"tool_input":{"command":%s}}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" | (cd "$NC_DIR" && bash "$NOCLOBBER_HOOK") 2>/dev/null; }

expect_noclobber_warn() { out=$(run_noclobber_hook "$1"); rc=$?; [ "$rc" -eq 0 ] && [ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null && ok "warns: $1" || bad "should advise without blocking: $1"; }
expect_noclobber_allow() { out=$(run_noclobber_hook "$1"); rc=$?; [ "$rc" -eq 0 ] && [ -z "$out" ] && ok "quiet: $1" || bad "should stay quiet: $1"; }
# Multi-line commands (heredocs) get a label instead, to keep the log readable.
expect_noclobber_warn_as() { expect_noclobber_warn "$2"; }
expect_noclobber_allow_as() { expect_noclobber_allow "$2"; }

if [ ! -f "$NOCLOBBER_HOOK" ]; then
  bad "fix-noclobber-redirect.sh missing; skipping behaviour tests"
else
  # Fixtures live outside $HOME. NC_DIR is also the hook's working directory,
  # and it holds a .env so any target that glob-expands would find one.
  NC_DIR=$(mktemp -d "${TMPDIR:-/tmp}/noclobber-hook-tests.XXXXXX")
  : > "$NC_DIR/exists.txt"
  : > "$NC_DIR/.env"
  : > "$NC_DIR/page.html"

  # A `>` inside quotes is regex syntax, not a redirection.
  expect_noclobber_allow "rg -o '<h2[^>]*>(.*?)</h2>' page.html"
  expect_noclobber_allow "rg -o '<h2>.*</h2>' page.html"
  expect_noclobber_allow 'rg -o "<h2[^>]*>(.*?)</h2>" page.html'
  expect_noclobber_allow 'rg -o "<h2>.*</h2>" page.html'
  # Redirections that noclobber does not break.
  expect_noclobber_allow "echo hi >> $NC_DIR/exists.txt"
  expect_noclobber_allow "echo hi >| $NC_DIR/exists.txt"
  expect_noclobber_allow "echo hi 2> $NC_DIR/exists.txt"
  expect_noclobber_allow "echo hi &> $NC_DIR/exists.txt"
  # A single `>` to a target that does not exist is fine.
  expect_noclobber_allow "echo hi > $NC_DIR/nope.txt"

  # The one real case: single `>` onto an existing file.
  expect_noclobber_warn "echo hi > $NC_DIR/exists.txt"

  # --- Heredoc bodies ------------------------------------------------------
  # A heredoc body is data bound for another file, so a `>` inside one is not
  # a redirection. Bodies are dropped before the scan; the line that OPENS the
  # heredoc is not, because a real redirect can sit on it.

  # The papercut, 2026-08-24: `<string>/bin/bash</string>` in a plist body
  # parsed as `> /bin/bash`, which exists, so a valid plist write was blocked.
  # The destination is a fixture path so the result does not depend on /tmp.
  expect_noclobber_allow_as "plist heredoc body (the 2026-08-24 papercut)" \
    "cat > $NC_DIR/test.plist <<'PLIST'
<key>ProgramArguments</key>
<array>
  <string>/bin/bash</string>
</array>
PLIST"
  # A body line that reads exactly like a redirect onto a real file.
  expect_noclobber_allow_as "bare '> /etc/hosts' inside a heredoc body" \
    "cat > $NC_DIR/notes.txt <<'EOF'
to wreck the box: echo 127.0.0.1 > /etc/hosts
EOF"
  # Delimiter quoting styles: unquoted and double-quoted, and `<< EOF` spaced.
  expect_noclobber_allow_as "unquoted heredoc delimiter" \
    "cat > $NC_DIR/unquoted.txt <<EOF
x > /etc/hosts
EOF"
  expect_noclobber_allow_as "double-quoted heredoc delimiter" \
    "cat > $NC_DIR/dquoted.txt <<\"EOF\"
x > /etc/hosts
EOF"
  expect_noclobber_allow_as "space before the heredoc delimiter" \
    "cat > $NC_DIR/spaced.txt << EOF
x > /etc/hosts
EOF"
  # `<<-` strips leading TABs from both the body and the terminator.
  expect_noclobber_allow_as "<<- with tab-indented body and terminator" \
    "cat > $NC_DIR/tabbed.txt <<-EOF"$'\n\tx > /etc/hosts\n\tEOF'
  # A body line that merely RESEMBLES the terminator does not end the body:
  # if it did, the `>` line below it would be scanned as a command.
  expect_noclobber_allow_as "near-miss terminators do not end the body early" \
    "cat > $NC_DIR/nearmiss.txt <<'EOF'
EOF_NOT
 EOF
echo hi > $NC_DIR/exists.txt
EOF"
  # `cat <<A <<B` opens two bodies, consumed in order. If the second were not
  # tracked, its `> /etc/passwd` line would be scanned as a command.
  expect_noclobber_allow_as "two heredocs opened on one line" \
    "cat <<A <<B > $NC_DIR/nope.txt
x > /etc/hosts
A
y > /etc/passwd
B"
  # A `<<` inside quotes opens nothing: the second line is still a command.
  expect_noclobber_warn_as "quoted '<<EOF' does not open a heredoc" \
    "echo 'use <<EOF for heredocs'
echo hi > $NC_DIR/exists.txt"

  # Only bodies are dropped. These three must still block.
  expect_noclobber_warn_as "redirect before the heredoc operator" \
    "cat > $NC_DIR/exists.txt <<'EOF'
body
EOF"
  expect_noclobber_warn_as "redirect after the heredoc operator" \
    "cat <<'EOF' > $NC_DIR/exists.txt
body
EOF"
  expect_noclobber_warn_as "redirect on a line after the heredoc closes" \
    "cat > $NC_DIR/nope.txt <<'EOF'
clean body
EOF
echo hi > $NC_DIR/exists.txt"
  expect_noclobber_warn_as "two heredocs plus a real redirect" \
    "cat <<A <<B > $NC_DIR/exists.txt
x
A
y
B"
  # `<<<` is a herestring: no body follows, so the `>` after it is real.
  expect_noclobber_warn "cat <<< 'hello' > $NC_DIR/exists.txt"
  expect_noclobber_warn "cat <<<\"hello\" > $NC_DIR/exists.txt"

  # --- Block message -------------------------------------------------------
  nc_msg=$(run_noclobber_hook "echo hi > $NC_DIR/exists.txt" | jq -r '.hookSpecificOutput.additionalContext')
  case "$nc_msg" in
    *"If the execution shell has noclobber"*"Check the command's exit status"*) ok "states uncertainty and requires result verification" ;;
    *) bad "advice must not assert unobserved shell options" "$nc_msg" ;;
  esac
  /bin/bash -c "printf new > '$NC_DIR/exists.txt'"
  [ "$(cat "$NC_DIR/exists.txt")" = new ] && ok "ordinary Bash overwrite succeeds" || bad "Bash overwrite failed"

  rm -rf "$NC_DIR" 2>/dev/null || bad "could not remove fixture dir $NC_DIR"
fi

# ---------------------------------------------------------------------------
# 7. Behaviour: block-wrong-runner.sh
#    The npm/yarn/pnpm check used to grep the raw command string, so the runner
#    name inside a quoted ARGUMENT counted as an invocation. A read-only search
#    whose pattern mentioned a package manager was blocked as if it ran one:
#    `rg "use pnpm instead" README.md`, `echo "=== npm install check ==="`, and
#    -- reported twice in one afternoon -- a `papercuts` message describing
#    this very bug. It was wrong in the other direction too:
#    `/usr/local/bin/npm install` was ALLOWED, because there the name was glued
#    to a path rather than preceded by a separator. Only the command a segment
#    actually invokes counts.
# ---------------------------------------------------------------------------
section "block-wrong-runner.sh behaviour"
RUNNER_HOOK="$HOOKS_DIR/block-wrong-runner.sh"

run_runner_hook() { printf '{"tool_input":{"command":%s}}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" | bash "$RUNNER_HOOK" 2>/dev/null; }
run_runner_hook_in() { printf '{"cwd":%s,"tool_input":{"command":%s}}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$2")" | bash "$RUNNER_HOOK" 2>/dev/null; }

expect_runner_block() { run_runner_hook "$1"; [ $? -eq 2 ] && ok "blocks cmd: $1" || bad "should block cmd: $1"; }
expect_runner_allow() { run_runner_hook "$1"; [ $? -eq 0 ] && ok "allows cmd: $1" || bad "should allow cmd: $1"; }
expect_runner_block_in() { run_runner_hook_in "$1" "$2"; [ $? -eq 2 ] && ok "blocks cmd in $(basename "$1"): $2" || bad "should block cmd in $1: $2"; }
expect_runner_allow_in() { run_runner_hook_in "$1" "$2"; [ $? -eq 0 ] && ok "allows cmd in $(basename "$1"): $2" || bad "should allow cmd in $1: $2"; }

if [ ! -f "$RUNNER_HOOK" ]; then
  bad "block-wrong-runner.sh missing; skipping behaviour tests"
else
  # A runner name inside a quoted argument is text, not an invocation.
  expect_runner_allow 'grep -rn "npm run format" docs/'
  expect_runner_allow 'rg "use pnpm instead" README.md'
  expect_runner_allow 'echo "=== npm install check ==="'
  expect_runner_allow 'papercuts "block-wrong-runner.sh blocks npm mentions"'
  expect_runner_allow "echo 'yarn is banned here'"
  # The sanctioned runner is never blocked.
  expect_runner_allow 'bun run build'
  expect_runner_allow 'bun run test'

  # Actual invocations, however they are dressed up.
  expect_runner_block 'npm install'
  expect_runner_block 'npm run dev'
  expect_runner_block 'yarn add left-pad'
  expect_runner_block 'pnpm i'
  # Wrapper prefixes wrap a real command; the wrapped one is the invocation.
  expect_runner_block 'sudo npm install -g something'
  # Leading environment assignments likewise.
  expect_runner_block 'FOO=bar npm ci'
  # Path-qualified: compare the basename. This one used to slip through.
  expect_runner_block '/usr/local/bin/npm install'
  expect_runner_block './node_modules/.bin/pnpm x'
  # Not only the first segment.
  expect_runner_block 'echo hi && npm install'

  # Same bug, later checks: `bun test` and `bun build` were grepped out of the
  # raw string until 2026-08-23, so merely NAMING them in an argument was
  # blocked -- filing the papercut about it was itself blocked.
  expect_runner_allow 'gh issue create --title x --body "the hook blocks bare bun test mentions"'
  expect_runner_allow 'echo "do not run bun build here"'
  expect_runner_allow "rg 'bun build' ~/.claude/hooks"
  # `bun x`/`bun run` take a subcommand of their own; only the first operand counts.
  expect_runner_allow 'bun run test --coverage'
  expect_runner_allow 'bun run build:prod'

  # The second half of the hook -- bare `bun test` resolved against the
  # nearest package.json -- is separate logic and must keep working. Fixtures
  # live outside $HOME so the upward package.json walk is deterministic.
  BR_DIR=$(mktemp -d "${TMPDIR:-/tmp}/wrong-runner-hook-tests.XXXXXX")
  mkdir -p "$BR_DIR/vitest-proj" "$BR_DIR/bun-proj" "$BR_DIR/no-pkg"
  printf '{"scripts":{"test":"vitest run"}}\n' > "$BR_DIR/vitest-proj/package.json"
  printf '{"scripts":{"test":"bun test ./test"}}\n' > "$BR_DIR/bun-proj/package.json"

  # Vitest project: bare `bun test` runs the wrong runner.
  expect_runner_block_in "$BR_DIR/vitest-proj" 'bun test'
  expect_runner_allow_in "$BR_DIR/vitest-proj" 'bun run test'
  # Project whose own test script IS Bun's native runner: allowed.
  expect_runner_allow_in "$BR_DIR/bun-proj" 'bun test'
  # No package.json anywhere above: cannot tell, so refuse.
  expect_runner_block_in "$BR_DIR/no-pkg" 'bun test'
  # Path-qualified and wrapped invocations are still invocations.
  expect_runner_block_in "$BR_DIR/vitest-proj" '~/.bun/bin/bun test'
  expect_runner_block_in "$BR_DIR/vitest-proj" 'time bun test'
  expect_runner_block_in "$BR_DIR/vitest-proj" 'echo hi && bun test'
  # Options before the subcommand do not hide it.
  expect_runner_block_in "$BR_DIR/vitest-proj" 'bun --silent test'
  # Naming it in an argument, inside a real project, is still just text.
  expect_runner_allow_in "$BR_DIR/vitest-proj" 'gh issue create --body "run bun test instead"'
  # `bun build` is the Bun bundler, never the package.json script.
  expect_runner_block 'bun build'
  expect_runner_block 'time bun build'
  expect_runner_block '~/.bun/bin/bun build ./src/index.ts'

  rm -rf "$BR_DIR" 2>/dev/null || bad "could not remove fixture dir $BR_DIR"
fi

# ---------------------------------------------------------------------------
# 7. Behaviour: block-edit-without-read.sh
#    Rewritten 2026-09-14: the hook reads the real transcript schema
#    (message.content tool_use / tool_result pairs) and blocks with one concise
#    sentence, no file preview. A Read counts only once its successful
#    tool_result is in the transcript. Exit 2 for unread files, 0 otherwise.
# ---------------------------------------------------------------------------
section "block-edit-without-read.sh behaviour"
BEWR_HOOK="$HOOKS_DIR/block-edit-without-read.sh"

run_bewr_hook() {
  # $1 file_path, $2 transcript_path, $3 agent_id (may be empty)
  python3 - "$1" "$2" "$3" <<'PY' | bash "$BEWR_HOOK" 2>"$BEWR_ERR"
import json, sys
d = {"tool_name": "Edit", "tool_input": {"file_path": sys.argv[1]}, "transcript_path": sys.argv[2]}
if sys.argv[3]:
    d["agent_id"] = sys.argv[3]
print(json.dumps(d))
PY
}

if [ ! -f "$BEWR_HOOK" ]; then
  bad "block-edit-without-read.sh missing; skipping behaviour tests"
else
  BEWR_DIR=$(mktemp -d "${TMPDIR:-/tmp}/bewr-hook-tests.XXXXXX")
  BEWR_ERR="$BEWR_DIR/stderr.out"
  printf 'alpha line one\nbeta line two\n' > "$BEWR_DIR/unread.txt"
  printf '\x00\x01\x02\x03binary\x00' > "$BEWR_DIR/unread.bin"
  printf 'seen before\n' > "$BEWR_DIR/read.txt"
  {
    printf '{"message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"%s"}}]}}\n' "$BEWR_DIR/read.txt"
    printf '{"message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"1\\tseen before"}]}}\n'
    # A Read whose result is an error is not evidence.
    printf '{"message":{"content":[{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"%s"}}]}}\n' "$BEWR_DIR/failed-read.txt"
    printf '{"message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"boom"}]}}\n'
  } > "$BEWR_DIR/transcript.jsonl"
  printf 'never read ok\n' > "$BEWR_DIR/failed-read.txt"

  # Unread text file: blocked with the one-sentence message, no file content.
  run_bewr_hook "$BEWR_DIR/unread.txt" "$BEWR_DIR/transcript.jsonl" ""
  rc=$?
  if [ $rc -eq 2 ] && grep -q "Blocked" "$BEWR_ERR" && ! grep -q "alpha line one" "$BEWR_ERR"; then
    ok "blocks unread text file with a concise message"
  else
    bad "unread text file: want exit 2 + concise message, got exit $rc" "$(head -c 200 "$BEWR_ERR")"
  fi

  # A Read that failed is not evidence: still blocked.
  run_bewr_hook "$BEWR_DIR/failed-read.txt" "$BEWR_DIR/transcript.jsonl" ""
  [ $? -eq 2 ] && ok "blocks a file whose only Read failed" || bad "should block when the only Read failed"

  # Unread binary file: still blocked, but no preview dump.
  run_bewr_hook "$BEWR_DIR/unread.bin" "$BEWR_DIR/transcript.jsonl" ""
  rc=$?
  if [ $rc -eq 2 ] && grep -q "Blocked" "$BEWR_ERR" && ! grep -q "First 50 lines" "$BEWR_ERR"; then
    ok "blocks unread binary file without preview"
  else
    bad "unread binary file: want exit 2, no preview, got exit $rc"
  fi

  # File already Read in the transcript: allowed.
  run_bewr_hook "$BEWR_DIR/read.txt" "$BEWR_DIR/transcript.jsonl" ""
  [ $? -eq 0 ] && ok "allows file already Read in transcript" || bad "should allow already-Read file"

  # Brand-new file: allowed.
  run_bewr_hook "$BEWR_DIR/does-not-exist.txt" "$BEWR_DIR/transcript.jsonl" ""
  [ $? -eq 0 ] && ok "allows brand-new file" || bad "should allow brand-new file"

  # Subagent context (agent_id set): allowed — evidence not visible there.
  run_bewr_hook "$BEWR_DIR/unread.txt" "$BEWR_DIR/transcript.jsonl" "agent-123"
  [ $? -eq 0 ] && ok "allows subagent edits (agent_id set)" || bad "should allow subagent edits"

  rm -rf "$BEWR_DIR" 2>/dev/null || bad "could not remove fixture dir $BEWR_DIR"
fi

# ---------------------------------------------------------------------------
# 8. Behaviour: warn-localhost-verify.sh
#    Non-blocking PostToolUse nudge: a curl/wget/nc probe against loopback
#    gets additionalContext reminding that localhost reachability does not
#    prove reachability from another network position. It must never block,
#    never fire on non-probe commands that mention a loopback bind, and stay
#    quiet when the same command also probes an external address.
# ---------------------------------------------------------------------------
section "warn-localhost-verify.sh behaviour"
WLV_HOOK="$HOOKS_DIR/warn-localhost-verify.sh"

run_wlv_hook() { printf '{"tool_input":{"command":%s}}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" | bash "$WLV_HOOK" 2>/dev/null; }

expect_wlv_warn() {
  out=$(run_wlv_hook "$1"); rc=$?
  if [ $rc -eq 0 ] && echo "$out" | grep -q "additionalContext"; then ok "warns: $1"
  else bad "should warn (exit 0 + additionalContext): $1" "exit $rc, out: $(echo "$out" | head -c 120)"; fi
}
expect_wlv_quiet() {
  out=$(run_wlv_hook "$1"); rc=$?
  if [ $rc -eq 0 ] && [ -z "$out" ]; then ok "quiet: $1"
  else bad "should stay quiet: $1" "exit $rc, out: $(echo "$out" | head -c 120)"; fi
}

if [ ! -f "$WLV_HOOK" ]; then
  bad "warn-localhost-verify.sh missing; skipping behaviour tests"
else
  # Loopback probes get the nudge.
  expect_wlv_warn 'curl -s http://127.0.0.1:3000/api/health'
  expect_wlv_warn 'curl http://localhost:3000/'
  expect_wlv_warn 'wget -qO- http://127.0.0.1:8080'
  expect_wlv_warn 'nc -z 127.0.0.1 3000'
  expect_wlv_warn 'echo checking && curl http://localhost:3000'

  # Probes from another network position are the real test.
  expect_wlv_quiet 'curl -s http://192.0.2.10:3000/api/health'
  expect_wlv_quiet 'curl http://127.0.0.1:3000 && curl http://192.0.2.10:3000'
  expect_wlv_quiet 'curl https://service.example/'

  # Non-probe commands that mention loopback are config, not verification.
  expect_wlv_quiet 'server --proxy-target 127.0.0.1:3000'
  expect_wlv_quiet 'uvicorn app:app --host 127.0.0.1 --port 3000'
  expect_wlv_quiet 'git status'
  expect_wlv_quiet 'curl https://example.com/api'
fi

# ---------------------------------------------------------------------------
# 8b. Behaviour: warn-public-bind.sh
#      Advises on public binds and always allows the tool call.
# ---------------------------------------------------------------------------
section "warn-public-bind.sh behaviour"
WPB_HOOK="$HOOKS_DIR/warn-public-bind.sh"
run_wpb_hook() { printf '{"tool_input":{"command":%s}}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" | bash "$WPB_HOOK" 2>/dev/null; }
out=$(run_wpb_hook 'bun run dev --host 0.0.0.0')
rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and (.hookSpecificOutput.additionalContext | contains("all network interfaces"))' >/dev/null; then
  ok "warns on a dev server bound to all interfaces and allows it"
else
  bad "should advise without blocking a public bind"
fi
out=$(run_wpb_hook 'bun run dev --host 127.0.0.1')
[ $? -eq 0 ] && [ -z "$out" ] && ok "stays quiet on a loopback bind" || bad "should stay quiet on a loopback bind"

# ---------------------------------------------------------------------------
# 8c. Behaviour: env-port-sweep.sh
#      Finds stale development ports in shallow .env* files without GNU find
#      extensions or GNU grep word-boundary syntax.
# ---------------------------------------------------------------------------
section "env-port-sweep.sh behaviour"
EPS_HOOK="$HOOKS_DIR/env-port-sweep.sh"
EPS_DIR=$(mktemp -d "$REPO_ROOT/tmp/envport-hook-tests.XXXXXX")
git -C "$EPS_DIR" init -q
printf 'export default { port: 3000 };\n' > "$EPS_DIR/next.config.js"
printf 'APP_PORT=4242\n' > "$EPS_DIR/.env.local"
run_eps_hook() { printf '{"tool_input":{"file_path":%s}}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$EPS_DIR/next.config.js")" | bash "$EPS_HOOK" 2>/dev/null; }
out=$(run_eps_hook)
if echo "$out" | jq -e '.additionalContext | contains("4242")' >/dev/null; then
  ok "warns when an env file has a stale port"
else
  bad "should warn about a stale env-file port"
fi
printf 'APP_PORT=3000\n' > "$EPS_DIR/.env.local"
out=$(run_eps_hook)
[ -z "$out" ] && ok "stays quiet when the env port matches" || bad "should stay quiet when the env port matches"
rm -rf "$EPS_DIR"

# ---------------------------------------------------------------------------
# 9. Behaviour: retry-counter.sh
#    The tracker file used to be keyed by `$$` -- the hook's own PID. Every
#    invocation is a separate process, so every invocation got a brand new,
#    empty tracker and the count never passed 1. The "3+ similar failures"
#    warning it exists to emit could not fire at all. It is keyed by
#    session_id now, so three failures with the same error signature inside
#    one session accumulate and the third one warns.
# ---------------------------------------------------------------------------
section "retry-counter.sh behaviour"
RETRY_HOOK="$HOOKS_DIR/retry-counter.sh"

# One invocation, shaped like a PostToolUseFailure payload.
run_retry_hook() {
  # $1 session_id, $2 command, $3 stderr text
  python3 - "$1" "$2" "$3" <<'PY' | CLAUDE_PLUGIN_DATA="$RETRY_DATA" bash "$RETRY_HOOK" 2>/dev/null
import json, sys
print(json.dumps({
    "session_id": sys.argv[1],
    "tool_name": "Bash",
    "tool_input": {"command": sys.argv[2]},
    "tool_result": {"exit_code": 1, "stderr": sys.argv[3]},
}))
PY
}

if [ ! -f "$RETRY_HOOK" ]; then
  bad "retry-counter.sh missing; skipping behaviour tests"
else
  RETRY_SID="hook-tests-$$-$(date +%s)"
  RETRY_DATA="$REPO_ROOT/tmp/retry-counter-tests-$$"
  mkdir -p "$RETRY_DATA"
  RETRY_TRACKER="$RETRY_DATA/retry-${RETRY_SID}.log"
  rm -f "$RETRY_TRACKER"

  RETRY_ERR="error: cannot find type 'Foo' in scope"
  r1=$(run_retry_hook "$RETRY_SID" 'swift build' "$RETRY_ERR")
  r2=$(run_retry_hook "$RETRY_SID" 'swift build' "$RETRY_ERR")
  r3=$(run_retry_hook "$RETRY_SID" 'swift build' "$RETRY_ERR")

  [ -z "$r1" ] && ok "quiet on the 1st failure" || bad "should stay quiet on the 1st failure" "$r1"
  [ -z "$r2" ] && ok "quiet on the 2nd failure" || bad "should stay quiet on the 2nd failure" "$r2"
  if echo "$r3" | grep -q "additionalContext"; then
    ok "warns on the 3rd failure with the same signature"
  else
    bad "3rd same-signature failure must warn" "got: $(echo "$r3" | head -c 160)"
  fi
  # The counter resets after warning, so the 4th does not warn again.
  r4=$(run_retry_hook "$RETRY_SID" 'swift build' "$RETRY_ERR")
  [ -z "$r4" ] && ok "resets after warning" || bad "should not warn again immediately" "$r4"

  rm -rf "$RETRY_DATA"
fi

# ---------------------------------------------------------------------------
# 10. Behaviour: protect-secrets-files.sh
#     A delegated agent ran `rm wifi_secrets.h` and the credentials were gone:
#     gitignored by design, in no backup, regenerated by nothing. Destruction
#     of a secrets-like file is blocked; reading one is not, and neither is
#     creating one.
# ---------------------------------------------------------------------------
section "protect-secrets-files.sh behaviour"
SECRETS_HOOK="$HOOKS_DIR/protect-secrets-files.sh"

run_secrets_cmd() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" | bash "$SECRETS_HOOK" 2>/dev/null; }
run_secrets_write() { printf '{"tool_name":"Write","tool_input":{"file_path":%s}}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" | bash "$SECRETS_HOOK" 2>/dev/null; }

expect_secrets_block_cmd() { run_secrets_cmd "$1"; [ $? -eq 2 ] && ok "blocks cmd: $1" || bad "should block cmd: $1"; }
expect_secrets_allow_cmd() { run_secrets_cmd "$1"; [ $? -eq 0 ] && ok "allows cmd: $1" || bad "should allow cmd: $1"; }

if [ ! -f "$SECRETS_HOOK" ]; then
  bad "protect-secrets-files.sh missing; skipping behaviour tests"
else
  # Fixtures must live somewhere the hook does NOT exempt, so not under /tmp,
  # a scratchpad, node_modules, the Trash, or ~/.claude/hooks (they lived in
  # hooks/tests/ until the hooks dir itself became exempt).
  mkdir -p "$HOME/.cache"
  SEC_DIR=$(mktemp -d "$HOME/.cache/secrets-hook-tests.XXXXXX")
  : > "$SEC_DIR/wifi_secrets.h"

  # Destruction of a secrets-like file.
  expect_secrets_block_cmd 'rm wifi_secrets.h'
  expect_secrets_block_cmd "rm -f $SEC_DIR/wifi_secrets.h"
  expect_secrets_block_cmd 'shred config/credentials.json'
  expect_secrets_block_cmd 'rm deploy/key.pem'
  expect_secrets_block_cmd 'echo hi && rm src/wifi_secrets.h'
  # A single `>` truncates the file; `>>` appends and is left alone.
  expect_secrets_block_cmd 'echo x > src/wifi_secrets.h'
  expect_secrets_allow_cmd 'echo x >> src/wifi_secrets.h'
  # Overwriting one as a copy/move destination.
  expect_secrets_block_cmd 'mv /other/foo.h src/wifi_secrets.h'
  # Copying one OUT is a read: only the destination is protected.
  expect_secrets_allow_cmd 'cp src/wifi_secrets.h /other/backup.h'

  # Reads never count.
  expect_secrets_allow_cmd 'cat wifi_secrets.h'
  expect_secrets_allow_cmd 'grep -n SSID src/wifi_secrets.h'
  expect_secrets_allow_cmd 'git status'
  # Stand-ins are not the real thing.
  expect_secrets_allow_cmd 'rm secrets.example.h'
  expect_secrets_allow_cmd 'rm config/credentials.template.json'
  # Exempt locations hold copies, not originals.
  expect_secrets_allow_cmd 'rm /tmp/wifi_secrets.h'
  expect_secrets_allow_cmd 'rm node_modules/pkg/secrets.js'

  # Write replaces the whole file, so it clobbers an existing secret...
  run_secrets_write "$SEC_DIR/wifi_secrets.h"
  [ $? -eq 2 ] && ok "blocks Write over an existing secrets file" || bad "should block Write over an existing secrets file"
  # ...but creating one is how they come into being.
  run_secrets_write "$SEC_DIR/new_secrets.h"
  [ $? -eq 0 ] && ok "allows Write to a non-existent secrets path" || bad "should allow Write to a new secrets path"
  # Edit is surgical and already required a Read.
  printf '{"tool_name":"Edit","tool_input":{"file_path":%s}}' \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$SEC_DIR/wifi_secrets.h")" \
    | bash "$SECRETS_HOOK" 2>/dev/null
  [ $? -eq 0 ] && ok "allows Edit of a secrets file" || bad "should allow Edit of a secrets file"
  # An ordinary file is untouched by any of this.
  : > "$SEC_DIR/notes.txt"
  run_secrets_write "$SEC_DIR/notes.txt"
  [ $? -eq 0 ] && ok "allows Write over an ordinary file" || bad "should allow Write over an ordinary file"

  # .env.schema is a committed, non-secret file (Varlock migration): Write
  # over an existing one must be allowed. .env.local stays protected.
  : > "$SEC_DIR/.env.schema"
  run_secrets_write "$SEC_DIR/.env.schema"
  [ $? -eq 0 ] && ok "allows Write over an existing .env.schema" || bad "should allow Write over an existing .env.schema"
  : > "$SEC_DIR/.env.local"
  run_secrets_write "$SEC_DIR/.env.local"
  [ $? -eq 2 ] && ok "blocks Write over an existing .env.local" || bad "should block Write over an existing .env.local"
  : > "$SEC_DIR/other_source.txt"
  expect_secrets_block_cmd "cp $SEC_DIR/other_source.txt $SEC_DIR/.env.local"
  # The exemptions are substring matches; the .env.*.local rule must win over
  # them, or `rm .env.test.local` / `rm .env.schema.local` sail through.
  expect_secrets_block_cmd "rm $SEC_DIR/.env.test.local"
  expect_secrets_block_cmd "rm $SEC_DIR/.env.schema.local"

  # The installed hook directory holds scripts, including this guard's own
  # secrets-like filename. The exemption follows the script location.
  expect_secrets_allow_cmd "cat > $HOOKS_DIR/block-secret-file-reads.sh"
  expect_secrets_allow_cmd "mv x $HOOKS_DIR/block-secret-file-reads.sh"
  run_secrets_write "$HOOKS_DIR/protect-secrets-files.sh"
  [ $? -eq 0 ] && ok "allows Write over this hook's own script directory" \
                || bad "should allow Write over a script in this hook directory"
  # The exemption is by location, not by extension or by nearby directory.
  expect_secrets_block_cmd 'rm ~/dev/foo/secrets.sh'
  expect_secrets_block_cmd '> ~/dev/foo/.env'
  expect_secrets_block_cmd 'rm ~/.claude/secrets.sh'
  expect_secrets_block_cmd 'rm ~/.claude/hooks-old/secrets.sh'

  rm -rf "$SEC_DIR" 2>/dev/null || bad "could not remove fixture dir $SEC_DIR"
fi

# ---------------------------------------------------------------------------
# 12. Behaviour: verify-before-done.sh near-duplicate sibling check.
#     Editing app.py while app_old.py sits beside it risks fixing the copy
#     that never runs. The Stop hook must warn on such siblings and stay
#     quiet when the siblings are unrelated or test files.
# ---------------------------------------------------------------------------
section "verify-before-done.sh near-duplicate siblings"
VBD_HOOK="$HOOKS_DIR/verify-before-done.sh"

if [ ! -f "$VBD_HOOK" ]; then
  bad "verify-before-done.sh missing; skipping behaviour tests"
else
  VBD_FIX=$(mktemp -d)
  (
    cd "$VBD_FIX" || exit 1
    git init -q .
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    printf 'print(1)\n' > app.py
    printf 'print(0)\n' > app_old.py
    printf 'print(9)\n' > report.py
    printf 'x = 1\n' > app.test.py
    git add -A
    git -c user.email=t@t -c user.name=t commit -qm files
    printf 'print(2)\n' > app.py   # modify only app.py
  )
  out=$(cd "$VBD_FIX" && bash "$VBD_HOOK" 2>/dev/null)
  if echo "$out" | grep -q 'app_old.py'; then
    ok "warns on app.py <-> app_old.py"
  else
    bad "must warn about app_old.py sibling" "got: $(printf '%s' "$out" | head -c 200)"
  fi
  if echo "$out" | grep -q 'report.py'; then
    bad "must not flag unrelated sibling report.py"
  else
    ok "quiet on unrelated sibling report.py"
  fi
  if echo "$out" | grep -q 'app.test.py'; then
    bad "must not flag test-file sibling app.test.py"
  else
    ok "quiet on test-file sibling app.test.py"
  fi
  rm -rf "$VBD_FIX"
fi

# ---------------------------------------------------------------------------
# N. Behaviour: pre-commit-lint.sh
#    The trigger used to grep the raw command string for `git\s+commit`
#    preceded by a separator, so the WORDS counted wherever they appeared. On
#    2026-09-05 a `perl -pi -e 's/.../echo "run git commit now"/' sync.sh` --
#    which only WRITES those words into a script -- tripped the hook, which
#    then linted the repo's stale staged files and refused the edit. Same class
#    as the 2026-08-15 whole-command-string fixes to block-wrong-runner.sh and
#    block-sensitive-git-add.sh. Only a segment that actually invokes
#    `git ... commit` counts.
#
#    The fixture is a repo with an 800+ line staged file, so the lint body
#    always blocks once it runs: exit 2 means "the trigger fired", exit 0 means
#    "the trigger correctly skipped". The over-long file is a .txt so no
#    external linter (ruff/eslint/tsc/clippy) has to be installed for the
#    assertion to hold.
# ---------------------------------------------------------------------------
section "pre-commit-lint.sh behaviour"
PCL_HOOK="$HOOKS_DIR/pre-commit-lint.sh"

if [ ! -f "$PCL_HOOK" ]; then
  bad "pre-commit-lint.sh missing; skipping behaviour tests"
else
  PCL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pre-commit-lint-tests.XXXXXX")
  git -C "$PCL_DIR" init -q
  python3 -c 'import sys; open(sys.argv[1],"w").write("".join("line %d\n" % i for i in range(900)))' "$PCL_DIR/big.txt"
  git -C "$PCL_DIR" add big.txt

  json1() { python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1"; }
  run_pcl_hook() {
    printf '{"cwd":%s,"tool_input":{"command":%s}}' "$(json1 "$PCL_DIR")" "$(json1 "$1")" \
      | (cd "$PCL_DIR" && bash "$PCL_HOOK")
  }
  # Exit 2 = the lint body ran and blocked, i.e. the trigger fired.
  expect_pcl_trigger() { run_pcl_hook "$1" >/dev/null 2>&1; [ $? -eq 2 ] && ok "triggers on: $1" || bad "should trigger on: $1"; }
  expect_pcl_skip()    { run_pcl_hook "$1" >/dev/null 2>&1; [ $? -eq 0 ] && ok "skips: $1"       || bad "should skip: $1"; }

  # --- real invocations: the lint gate must still fire ---
  expect_pcl_trigger 'git commit'
  expect_pcl_trigger 'git commit -m "fix the thing"'
  expect_pcl_trigger "git -C $PCL_DIR commit -m msg"
  expect_pcl_trigger 'git -c user.name=x commit --amend --no-edit'
  # Not only the first segment: && ; || and a pipeline all reach a commit.
  expect_pcl_trigger 'git add -A && git commit -m msg'
  expect_pcl_trigger 'git add -A; git commit -m msg'
  expect_pcl_trigger 'git commit -m msg || echo "commit failed"'
  expect_pcl_trigger 'git commit -m msg | tail -1'
  # Wrappers, env assignments and path-qualified invocations are invocations.
  expect_pcl_trigger 'time git commit -m msg'
  expect_pcl_trigger 'GIT_EDITOR=true git commit'
  expect_pcl_trigger '/usr/bin/git commit -m msg'

  # --- the words as data: the gate must not fire ---
  # The exact command from the 2026-09-05 papercut.
  expect_pcl_skip 'perl -pi -e '"'"'s/OLD/echo "run git commit now"/'"'"' bin/sync.sh'
  expect_pcl_skip "sed -i '' 's|MARKER|git commit -m auto|' bin/sync.sh"
  expect_pcl_skip 'echo "git commit"'
  expect_pcl_skip 'printf "%s\n" "git commit -m x"'
  expect_pcl_skip 'rg "git commit" ~/.claude/hooks'
  expect_pcl_skip "grep -rn 'git commit' docs/"
  expect_pcl_skip 'papercuts "pre-commit-lint.sh blocks git commit mentions"'
  expect_pcl_skip 'gh issue create --title x --body "then run git commit -m msg"'
  # A heredoc body is data bound for a file, not a command being run.
  expect_pcl_skip "$(printf 'cat > /tmp/release.sh <<%s\ngit add -A\ngit commit -m release\nEOF\n' "'EOF'")"
  # Near misses: only the exact `commit` subcommand counts.
  expect_pcl_skip 'git committer'
  expect_pcl_skip 'git commit-tree HEAD^{tree}'
  expect_pcl_skip 'git log --format="%h %s"'
  expect_pcl_skip 'git add src/foo.ts'

  rm -rf "$PCL_DIR" 2>/dev/null || bad "could not remove fixture dir $PCL_DIR"

  # --- file-length check: single-file `uv run --script` exemption ---
  # A PEP 723 script declares its deps inline and is run as ONE file, so
  # "refactor before committing" has no answer for it -- splitting it breaks
  # the invocation. a 1006-line standalone deploy script blocked a commit on
  # 2026-09-07; the limit still applies to every ordinary source file.
  PCL_LEN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pre-commit-lint-len.XXXXXX")
  git -C "$PCL_LEN_DIR" init -q
  long_body() { python3 -c 'import sys; sys.stdout.write("".join("# line %d\n" % i for i in range(900)))'; }
  { printf '#!/usr/bin/env -S uv run --script\n'; long_body; } > "$PCL_LEN_DIR/uv_shebang.py"
  chmod +x "$PCL_LEN_DIR/uv_shebang.py"  # a shebang on a non-executable file is ruff EXE001
  { printf '# /// script\n# requires-python = ">=3.11"\n# ///\n'; long_body; } > "$PCL_LEN_DIR/pep723.py"
  long_body > "$PCL_LEN_DIR/plain.py"
  run_pcl_len() {
    git -C "$PCL_LEN_DIR" reset -q
    git -C "$PCL_LEN_DIR" add "$1"
    printf '{"cwd":%s,"tool_input":{"command":"git commit -m x"}}' "$(json1 "$PCL_LEN_DIR")" \
      | (cd "$PCL_LEN_DIR" && bash "$PCL_HOOK")
  }
  run_pcl_len uv_shebang.py >/dev/null 2>&1
  [ $? -eq 0 ] && ok "length check exempts a 900-line uv run --script file" \
                || bad "should exempt a 900-line uv run --script file"
  run_pcl_len pep723.py >/dev/null 2>&1
  [ $? -eq 0 ] && ok "length check exempts a 900-line PEP 723 script (no shebang)" \
                || bad "should exempt a 900-line PEP 723 script"
  run_pcl_len plain.py >/dev/null 2>&1
  [ $? -eq 2 ] && ok "length check still blocks an ordinary 900-line .py" \
                || bad "should still block an ordinary 900-line .py"
  rm -rf "$PCL_LEN_DIR" 2>/dev/null || bad "could not remove fixture dir $PCL_LEN_DIR"

  # --- eslint is judged by its exit code, and a missing bunx/npx is reported --
  # The old check grepped eslint's output for "error", so a warning in a file
  # named errorHandler.ts blocked the commit. A fake bunx stands in for eslint.
  PCL_JS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pre-commit-lint-js.XXXXXX")
  mkdir -p "$PCL_JS_DIR/repo" "$PCL_JS_DIR/warn" "$PCL_JS_DIR/err" "$PCL_JS_DIR/none"
  for d in warn err none; do
    for t in jq git python3; do ln -s "$(command -v "$t")" "$PCL_JS_DIR/$d/$t"; done
  done
  printf '#!/bin/sh\necho "errorHandler.ts: 1 warning"\nexit 0\n' > "$PCL_JS_DIR/warn/bunx"
  printf '#!/bin/sh\necho "errorHandler.ts: 1 problem"\nexit 1\n' > "$PCL_JS_DIR/err/bunx"
  chmod +x "$PCL_JS_DIR/warn/bunx" "$PCL_JS_DIR/err/bunx"
  git -C "$PCL_JS_DIR/repo" init -q
  echo 'export default []' > "$PCL_JS_DIR/repo/eslint.config.js"
  echo 'export const x = 1' > "$PCL_JS_DIR/repo/errorHandler.ts"
  git -C "$PCL_JS_DIR/repo" add -A
  run_pcl_js() { printf '{"tool_input":{"command":"git commit -m x"}}' | (cd "$PCL_JS_DIR/repo" && PATH="$PCL_JS_DIR/$1:/usr/bin:/bin" bash "$PCL_HOOK" 2>/dev/null); }
  run_pcl_js warn >/dev/null; [ $? -eq 0 ] && ok "eslint warning in errorHandler.ts does not block" || bad "eslint warning in a file named *error* should not block"
  run_pcl_js err >/dev/null;  [ $? -eq 2 ] && ok "eslint exit 1 blocks" || bad "eslint exit 1 should block"
  out=$(run_pcl_js none); rc=$?
  [ "$rc" -eq 0 ] && echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("neither bunx nor npx")' >/dev/null \
    && ok "missing bunx/npx is reported, not silent" || bad "missing bunx/npx should be reported" "rc=$rc out=$out"
  rm -rf "$PCL_JS_DIR" 2>/dev/null || bad "could not remove fixture dir $PCL_JS_DIR"
fi

# ---------------------------------------------------------------------------
# 15. Behaviour: block-subagent-git-mutation.sh
#     Subagent calls carry a top-level agent_id; main-agent calls do not.
#     Only a segment that really invokes git stash/checkout/switch/reset/
#     commit counts -- never a quoted mention or a heredoc body.
# ---------------------------------------------------------------------------
section "block-subagent-git-mutation.sh behaviour"
SGM_HOOK="$HOOKS_DIR/block-subagent-git-mutation.sh"
type json1 >/dev/null 2>&1 || json1() { python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1"; }

run_sgm_hook() {
  # $1 = agent_id ("" for the main agent), $2 = command
  if [ -n "$1" ]; then
    printf '{"agent_id":%s,"tool_input":{"command":%s}}' "$(json1 "$1")" "$(json1 "$2")"
  else
    printf '{"tool_input":{"command":%s}}' "$(json1 "$2")"
  fi | bash "$SGM_HOOK" >/dev/null 2>&1
}
expect_sgm_block() { run_sgm_hook "agent-abc" "$1"; [ $? -eq 2 ] && ok "subagent blocked: $1" || bad "subagent should be blocked: $1"; }
expect_sgm_allow() { run_sgm_hook "agent-abc" "$1"; [ $? -eq 0 ] && ok "subagent allowed: $1" || bad "subagent should be allowed: $1"; }
expect_sgm_main()  { run_sgm_hook "" "$1";          [ $? -eq 0 ] && ok "main agent allowed: $1" || bad "main agent should be allowed: $1"; }

if [ ! -f "$SGM_HOOK" ]; then
  bad "block-subagent-git-mutation.sh missing; skipping behaviour tests"
else
  # The four verbs in the CLAUDE.md rule, plus switch (checkout's twin).
  expect_sgm_block 'git stash'
  expect_sgm_block 'git stash push -m wip'
  expect_sgm_block 'git stash pop'
  expect_sgm_block 'git checkout -b feature/x'
  expect_sgm_block 'git checkout main'
  expect_sgm_block 'git checkout -- src/foo.ts'
  expect_sgm_block 'git switch -c feature/x'
  expect_sgm_block 'git reset HEAD src/foo.ts'
  expect_sgm_block 'git commit -m "fix"'
  expect_sgm_block 'git add -A && git commit -m "fix"'
  expect_sgm_block 'git -C ~/dev/proj commit -m "fix"'
  expect_sgm_block 'GIT_EDITOR=true git commit --amend --no-edit'
  expect_sgm_block '/usr/bin/git stash'
  expect_sgm_block 'cd ~/dev/proj; git stash'

  # Read-only git and read-only stash forms are fine.
  expect_sgm_allow 'git status'
  expect_sgm_allow 'git log --oneline -5'
  expect_sgm_allow 'git diff --stat'
  expect_sgm_allow 'git stash list'
  expect_sgm_allow 'git stash show -p stash@{0}'
  expect_sgm_allow 'git add src/foo.ts'
  # Mentions are not invocations.
  expect_sgm_allow 'echo "run git commit when done"'
  expect_sgm_allow "rg 'git stash' docs/"
  expect_sgm_allow "$(printf 'cat > release.sh <<%s\ngit commit -m release\nEOF\n' "'EOF'")"
  # Explicit acknowledgement when git mutation IS the assigned task.
  expect_sgm_allow 'SUBAGENT_GIT_OK=1 git commit -m "release notes"'
  # Never touches the main agent.
  expect_sgm_main 'git stash'
  expect_sgm_main 'git commit -m "fix"'
  expect_sgm_main 'git checkout -b feature/x'
fi

# ---------------------------------------------------------------------------
# 16. Behaviour: block-token-file-reads.sh
#     A bare dump of a token-bearing file is blocked; a redacted read
#     (grep -v, field extraction, a sed that names the secret) passes.
# ---------------------------------------------------------------------------
section "block-token-file-reads.sh behaviour"
TFR_HOOK="$HOOKS_DIR/block-token-file-reads.sh"

run_tfr_bash() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(json1 "$1")" | bash "$TFR_HOOK" >/dev/null 2>&1; }
run_tfr_read() { printf '{"tool_name":"Read","tool_input":{"file_path":%s}}' "$(json1 "$1")" | bash "$TFR_HOOK" >/dev/null 2>&1; }
expect_tfr_block() { run_tfr_bash "$1"; [ $? -eq 2 ] && ok "blocks cmd: $1" || bad "should block cmd: $1"; }
expect_tfr_allow() { run_tfr_bash "$1"; [ $? -eq 0 ] && ok "allows cmd: $1" || bad "should allow cmd: $1"; }
expect_tfr_block_read() { run_tfr_read "$1"; [ $? -eq 2 ] && ok "blocks Read: $1" || bad "should block Read: $1"; }
expect_tfr_allow_read() { run_tfr_read "$1"; [ $? -eq 0 ] && ok "allows Read: $1" || bad "should allow Read: $1"; }

if [ ! -f "$TFR_HOOK" ]; then
  bad "block-token-file-reads.sh missing; skipping behaviour tests"
else
  # The two leaks that motivated the hook, in the shapes they happened.
  expect_tfr_block 'cat ~/.config/gh/hosts.yml'
  expect_tfr_block 'cat /etc/ci-agent/buildkite-agent.cfg'
  # Other dumpers, path spellings, wrappers, and positions in a pipeline.
  expect_tfr_block 'head -20 $HOME/.config/gh/hosts.yml'
  expect_tfr_block 'cat ~/.config/gh/hosts.yml | head -5'
  expect_tfr_block 'ls && cat ~/.config/gh/hosts.yml'
  expect_tfr_block 'sudo cat /etc/ci-agent/buildkite-agent.cfg'
  expect_tfr_block 'cat < ~/.netrc'
  expect_tfr_block 'cat ~/.ssh/id_ed25519'
  expect_tfr_block 'strings -a ~/dev/proj/cert.pem'
  # A filter that SELECTS the secret is a dump with extra steps.
  expect_tfr_block 'grep -i token ~/.config/gh/hosts.yml'
  expect_tfr_block 'rg oauth_token ~/.config/gh/hosts.yml'
  # A script or query that prints everything.
  expect_tfr_block 'sed -n 1,40p ~/.codex/auth.json'
  expect_tfr_block 'jq . ~/.codex/auth.json'
  expect_tfr_block "yq '.' ~/.config/gh/hosts.yml"
  # The Read tool is the same leak through a different door.
  expect_tfr_block_read "$HOME/.config/gh/hosts.yml"
  expect_tfr_block_read "$HOME/.codex/auth.json"
  expect_tfr_block_read '/etc/ci-agent/buildkite-agent.cfg'

  # Redacted reads and metadata pass.
  expect_tfr_allow 'grep -v -i token ~/.config/gh/hosts.yml'
  expect_tfr_allow 'grep -vi token ~/.config/gh/hosts.yml'
  expect_tfr_allow 'grep -viE token /etc/ci-agent/buildkite-agent.cfg'
  expect_tfr_allow 'grep user ~/.config/gh/hosts.yml'
  expect_tfr_allow "yq '.[\"github.com\"].user' ~/.config/gh/hosts.yml"
  expect_tfr_allow "sed -E 's/token.*/token <redacted>/' ~/.config/gh/hosts.yml"
  expect_tfr_allow 'ls -l ~/.config/gh/hosts.yml'
  expect_tfr_allow 'wc -l ~/.config/gh/hosts.yml'
  expect_tfr_allow 'stat ~/.netrc'
  expect_tfr_allow 'gh auth status'
  # Mentions, public keys, and ordinary files.
  expect_tfr_allow 'echo "see ~/.config/gh/hosts.yml"'
  expect_tfr_allow 'cat ~/.ssh/id_ed25519.pub'
  expect_tfr_allow 'cat README.md'
  expect_tfr_allow 'cat ~/dev/proj/config/hosts.yml.example'
  expect_tfr_allow_read "$HOME/.ssh/id_ed25519.pub"
  expect_tfr_allow_read "$HOME/dev/proj/README.md"

  # --- Project .env files: a hit by content, not by name alone -------------
  # 2026-09-1x: a subagent printed a live NEXT_PUBLIC_API_KEY out of a project
  # .env.local into its transcript during a Varlock migration, and the hook
  # matched system paths only. The name cannot decide on its own -- a .env.local
  # of ports and localhost URLs is read all day -- so a named file is a hit only
  # when it holds a credential-looking value. Every value below is invented.
  TFR_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tfr-env-tests.XXXXXX")
  TFR_FAKE='Ab3xQ9ZfakeKEY0123456789abcdEFGH'   # 32 chars, mixed case, not real
  mkdir -p "$TFR_DIR/ports"
  printf '# local overrides\nAPI_KEY=%s\nPORT=3000\n' "$TFR_FAKE" > "$TFR_DIR/.env.local"
  printf 'SECRET_TOKEN=%s\n' "$TFR_FAKE" > "$TFR_DIR/.env.test.local"
  printf 'API_KEY=%s\n' "$TFR_FAKE" > "$TFR_DIR/.env.schema"
  printf 'API_KEY=%s\n' "$TFR_FAKE" > "$TFR_DIR/.env.example"
  printf 'PORT=3000\nURL=http://127.0.0.1:8080\nDB=postgres://localhost/db\nDEBUG=true\n' \
    > "$TFR_DIR/ports/.env.local"

  expect_tfr_block "cat $TFR_DIR/.env.local"
  expect_tfr_block "head -5 $TFR_DIR/.env.local"
  expect_tfr_block "grep KEY $TFR_DIR/.env.local"
  expect_tfr_block "cat $TFR_DIR/.env.test.local"
  expect_tfr_block_read "$TFR_DIR/.env.local"
  # Redacted reads, metadata, and the Varlock path out.
  expect_tfr_allow "grep -v KEY $TFR_DIR/.env.local"
  expect_tfr_allow "sed -E 's/=.*/=<redacted>/' $TFR_DIR/.env.local"
  expect_tfr_allow "grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' $TFR_DIR/.env.local"
  expect_tfr_allow "wc -l $TFR_DIR/.env.local"
  expect_tfr_allow "ls -l $TFR_DIR/.env.local"
  expect_tfr_allow "cd $TFR_DIR && varlock load"
  # --- varlock: an explicit plaintext format is a dump (2026-09-13) --------
  # A scratch `varlock load --format shell` ran in the repo root after its cd
  # failed silently and printed ten live keys. The cwd cannot be trusted, so
  # every explicit --format other than pretty is blocked wherever it runs;
  # the pretty default and --agent redact and pass.
  expect_tfr_block 'varlock load --format shell'
  expect_tfr_block 'varlock load --format=shell'
  expect_tfr_block 'varlock load -f env'
  expect_tfr_block 'varlock load --format json'
  expect_tfr_block 'varlock load --env test --format json-full'
  expect_tfr_block "cd $TFR_DIR && varlock load --format shell"
  expect_tfr_block "varlock load --format shell | grep -oE '^[A-Z_]+='"
  expect_tfr_block 'eval "$(varlock load --format shell)"'
  expect_tfr_block 'varlock run --no-redact-stdout -- sh -c "echo \$KEY"'
  expect_tfr_allow 'varlock load'
  expect_tfr_allow 'varlock load --agent'
  expect_tfr_allow 'varlock load --format pretty'
  expect_tfr_allow "varlock load --env test"
  expect_tfr_allow 'varlock run -- uv run myapp'
  expect_tfr_allow 'varlock run -- python -c "import os; print(sorted(os.environ))"'
  expect_tfr_allow 'varlock load --help'
  # A quoted mention is blocked on purpose: `bash -c "..."` and `eval "$(...)"`
  # are real execution paths and the hook cannot tell them from an echo.
  expect_tfr_block 'bash -c "varlock load --format shell"'
  # Ports and localhost URLs are config, not credentials.
  expect_tfr_allow "cat $TFR_DIR/ports/.env.local"
  expect_tfr_allow_read "$TFR_DIR/ports/.env.local"
  # The committed schema and the checked-in samples are never hits, whatever
  # they hold; neither is a file that does not exist.
  expect_tfr_allow "cat $TFR_DIR/.env.schema"
  expect_tfr_allow "cat $TFR_DIR/.env.example"
  expect_tfr_allow "cat $TFR_DIR/gone/.env.local"
  expect_tfr_allow_read "$TFR_DIR/gone/.env.local"
  # The hook reads the file to decide; it must never quote a byte of it.
  tfr_err=$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
    "$(json1 "cat $TFR_DIR/.env.local")" | bash "$TFR_HOOK" 2>&1 >/dev/null)
  case "$tfr_err" in
    *"$TFR_FAKE"*) bad "deny text repeated a value from the file" ;;
    *) ok "deny text quotes no value from the file" ;;
  esac
  rm -rf "$TFR_DIR" 2>/dev/null || bad "could not remove fixture dir $TFR_DIR"
fi

# ---------------------------------------------------------------------------
# 17. Behaviour: block-destructive-git.sh
#     The whole-tree pathspec `.` was unanchored, so any path argument that
#     STARTED with a dot matched it. Unstaging `.gitignore` (2026-09-06)
#     was refused as if it were `git restore --staged .`. The dot now counts
#     only as the entire argument. `./`, `..` and `../` keep blocking, as they
#     did before.
#     It also grepped the raw command text, so quoted mentions and heredoc
#     bodies counted as invocations: a spot-check script that only passed
#     `git restore` / `git checkout` strings as arguments was blocked
#     (2026-09-12). Only the git command a segment RUNS counts now, including
#     inside command substitutions, backticks, process substitutions and
#     subshells. Where the resolver cannot see (a shell or interpreter running
#     stdin or inline code, xargs, ssh, unbalanced text, no python3), the old
#     anchored regex still decides, so nothing it blocked is allowed.
# ---------------------------------------------------------------------------
section "block-destructive-git.sh behaviour"
DGIT_HOOK="$HOOKS_DIR/block-destructive-git.sh"

run_dgit_hook() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(json1 "$1")" | bash "$DGIT_HOOK" 2>/dev/null; }
expect_dgit_block() { run_dgit_hook "$1" >/dev/null; [ $? -eq 2 ] && ok "blocks cmd: $1" || bad "should block cmd: $1"; }
expect_dgit_allow() { run_dgit_hook "$1" >/dev/null; [ $? -eq 0 ] && ok "allows cmd: $1" || bad "should allow cmd: $1"; }
# Multi-line commands (heredocs) get a label instead, to keep the log readable.
expect_dgit_block_as() { run_dgit_hook "$2" >/dev/null; [ $? -eq 2 ] && ok "blocks $1" || bad "should block $1"; }
expect_dgit_allow_as() { run_dgit_hook "$2" >/dev/null; [ $? -eq 0 ] && ok "allows $1" || bad "should allow $1"; }

if [ ! -f "$DGIT_HOOK" ]; then
  bad "block-destructive-git.sh missing; skipping behaviour tests"
else
  # Whole-tree discards, and the other destructive verbs.
  expect_dgit_block 'git checkout .'
  expect_dgit_block 'git restore .'
  expect_dgit_block 'git restore --staged .'
  expect_dgit_block 'git checkout . && echo x'
  expect_dgit_block 'git checkout .;echo x'
  expect_dgit_block '(git checkout .)'
  expect_dgit_block "bash -c 'git checkout .'"
  expect_dgit_block 'git restore ./'
  expect_dgit_block 'git checkout ..'
  expect_dgit_block 'git reset --hard'
  expect_dgit_block 'git push --force'
  expect_dgit_block 'git push -f origin main'
  expect_dgit_block 'git clean -fd'
  # The papercut: a dotfile path is not the whole tree.
  expect_dgit_allow 'git restore --staged .gitignore'
  expect_dgit_allow 'git restore .eslintrc'
  expect_dgit_allow 'git checkout .github/workflows/ci.yml'
  expect_dgit_allow 'git restore --staged .gitignore && git status'
  expect_dgit_allow 'git restore --staged src/foo.ts'
  # The hook speaks only through stderr and its exit code.
  dgit_out=$(run_dgit_hook 'git checkout .')
  [ -z "$dgit_out" ] && ok "prints nothing on stdout when blocking" || bad "should print nothing on stdout" "$dgit_out"

  # --- Only a real invocation counts ---------------------------------------
  # The papercut, 2026-09-12: mentions in quotes and heredoc bodies.
  expect_dgit_allow 'echo "git reset --hard"'
  expect_dgit_allow "rg 'git checkout \\.' docs/"
  expect_dgit_allow 'papercuts "git clean -fd blocked"'
  expect_dgit_allow "bash probe.sh 'git restore .' 'git checkout .' 'git reset --hard'"
  expect_dgit_allow 'python3 spot.py "git restore --staged ." "git push -f"'
  expect_dgit_allow 'git commit -m "document git reset --hard risk"'
  expect_dgit_allow_as "a heredoc body that says git push --force" \
    "cat > notes.md <<'EOF'
never run git push --force here
EOF"
  # Real invocations in other dress, including ones the raw grep missed:
  # `git -C`, and a force flag after a word with an `n` in it.
  expect_dgit_block 'git -C repo reset --hard'
  expect_dgit_block 'git --no-pager -c core.x=y reset --hard'
  expect_dgit_block '/usr/bin/git push -f'
  expect_dgit_block 'git push origin main --force'
  expect_dgit_block 'git push --force-with-lease'
  expect_dgit_block 'cd x && git clean -fd'
  expect_dgit_block 'git clean -d -f'
  expect_dgit_block 'time git reset --hard'
  expect_dgit_block 'GIT_DIR=x git reset --hard HEAD~1'
  expect_dgit_block 'sudo -u me git reset --hard'
  expect_dgit_block '{ git reset --hard; }'
  expect_dgit_block 'if git reset --hard; then echo ok; fi'
  expect_dgit_block 'sh -c "git restore ."'
  expect_dgit_block "bash -lc 'cd repo && git reset --hard'"
  expect_dgit_block 'eval "git reset --hard"'
  expect_dgit_block 'git checkout -- .'
  # The line that opens a heredoc is still a command line.
  expect_dgit_block_as "a destructive command on the heredoc's opening line" \
    "cat > notes.md <<'EOF' && git reset --hard
body
EOF"
  # Substitutions run their bodies; ssh runs a remote line the resolver
  # cannot see, so the old regex decides there.
  expect_dgit_block 'echo $(git reset --hard)'
  expect_dgit_block 'echo "`git reset --hard`"'
  expect_dgit_block_as "\$(...) in an unquoted-delimiter heredoc body" \
    "cat <<EOF
\$(git reset --hard)
EOF"
  expect_dgit_block "ssh host 'git reset --hard'"
  expect_dgit_allow "ssh host 'git status'"

  # --- Text that a command EXECUTES is not data ------------------------------
  # v2 (2026-09-12) treated these as quoted text and allowed them: a shell or
  # interpreter that runs code from stdin or an inline string. They fall back
  # to the regex, which blocks them as the old hook did.
  expect_dgit_block 'echo "git reset --hard" | bash'
  expect_dgit_block 'echo "git reset --hard" | sh -s'
  expect_dgit_block_as "a heredoc fed to bash" \
    "bash <<'EOF'
git reset --hard
EOF"
  expect_dgit_block_as "an unquoted-delimiter heredoc fed to sh" \
    "sh <<EOF
git checkout .
EOF"
  expect_dgit_block 'python3 -c "import os; os.system(\"git reset --hard\")"'
  expect_dgit_block "node -e \"require('child_process').execSync('git clean -fd')\""
  expect_dgit_block "perl -e 'system(\"git reset --hard\")'"
  expect_dgit_block 'printf "git push -f\n" | xargs -I{} sh -c "{}"'
  expect_dgit_block "uv run python -c \"import os; os.system('git reset --hard')\""
  expect_dgit_block "timeout 5 bash -c 'git reset --hard'"
  expect_dgit_block "bash -c -x 'git reset --hard'"
  # A script operand, not fed by stdin: its arguments are data. Both the old
  # hook and this one are blind to the script's contents.
  expect_dgit_allow 'python3 spot.py "git checkout ."'
  expect_dgit_allow "bash scripts/check.sh 'git reset --hard'"
  # Piping stdin into a script is how every hook is tested: data, not code.
  expect_dgit_allow 'echo "git reset --hard" | bash hook.sh'

  # --- An interpreter's heredoc is its code, and data to the shell -----------
  # 2026-09-13: an interpreter with no script operand or `-` raised
  # "interpreter code not visible" even when a heredoc fed its stdin, so the
  # command went to the raw regex and the regex matched destructive git strings
  # in the heredoc BODY. The body is that interpreter's own code, exactly like a
  # script file the hook cannot read, and the shell never runs a word of it.
  expect_dgit_allow_as "a git string in a python heredoc body" \
    "python3 - <<'PY'
x = \"git reset --hard\"
PY"
  expect_dgit_allow_as "a python heredoc body inside a substitution" \
    "echo \"\$(python3 - <<'PY'
x = \"git reset --hard\"
PY
)\""
  expect_dgit_allow_as "a python heredoc that shells out" \
    "python3 - <<'PY'
import subprocess
subprocess.run('git reset --hard', shell=True)
PY"
  expect_dgit_allow_as "a python heredoc that runs git through a list" \
    "python3 - <<'PY'
import subprocess; subprocess.run([\"git\",\"reset\",\"--hard\"])
PY"
  # Every other way of feeding an interpreter still fails closed: a pipe and a
  # `<file` carry code from outside the command, and a shell heredoc really is
  # shell code. An unquoted delimiter expands, so substitutions in it run.
  expect_dgit_block_as "a pipe into python3 - with a mention in a later segment" \
    'cat s.py | python3 -; echo "git reset --hard"'
  expect_dgit_block 'python3 - < s.py; git reset --hard'
  expect_dgit_block_as "a substitution in an unquoted-delimiter python heredoc" \
    "python3 - <<PY
\$(git reset --hard)
PY"

  # --- Substitutions are resolved, not fallen back on ------------------------
  # v3 sent any command containing a command substitution to the raw regex, so
  # the complaint's own spot-check script stayed blocked. Its text, verbatim:
  read -r -d '' DGIT_SPOT <<'SPOT' || true
#!/bin/bash
t() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$2" '$c')" | bash ~/.claude/hooks/$1 >/dev/null 2>&1; printf '%-28s rc=%s  %s\n' "$1" "$?" "$2"; }
t block-destructive-git.sh 'git restore --staged .gitignore'
t block-destructive-git.sh 'git checkout .github/workflows/ci.yml'
t block-destructive-git.sh 'git restore --staged .'
t block-destructive-git.sh 'git checkout . && ls'
t block-destructive-git.sh 'git reset --hard'
t protect-secrets-files.sh 'cat > ~/.claude/hooks/block-secret-file-reads.sh <<EOF'
t protect-secrets-files.sh 'rm ~/dev/foo/secrets.sh'
t protect-secrets-files.sh 'rm wifi_secrets.h'
SPOT
  expect_dgit_allow_as "the 2026-09-12 spot-check script as a command" "$DGIT_SPOT"
  expect_dgit_allow 'echo "$(date) git reset --hard"'
  expect_dgit_block 'x=$(git reset --hard)'
  expect_dgit_block 'echo "$(git checkout .)"'
  expect_dgit_block 'echo `git clean -fd`'
  expect_dgit_block 'echo $(echo $(git reset --hard))'
  expect_dgit_block '(cd repo && git reset --hard)'
  expect_dgit_allow 'diff <(git show HEAD:a) b'
  expect_dgit_block 'cat <(git reset --hard)'
  # Single quotes: the substitution never runs.
  expect_dgit_allow 'echo '\''$(git reset --hard)'\'''
  # A quoted-delimiter heredoc body is data; an unquoted one expands.
  expect_dgit_allow_as "a substitution in a quoted-delimiter heredoc body" \
    "cat > x.sh <<'EOF'
echo \$(git reset --hard)
EOF"
  expect_dgit_block_as "a backtick in an unquoted-delimiter heredoc body" \
    "cat <<EOF
\`git clean -fd\`
EOF"
  # Comments are not commands, but a shebang is not a bash invocation either.
  expect_dgit_allow 'echo hi # git reset --hard'
  # Fail closed on what does not parse cleanly.
  expect_dgit_block 'case $x in a) git reset --hard;; esac'
  expect_dgit_block 'echo "$(git reset --hard"'
  expect_dgit_block_as "a heredoc opener in a comment that never terminates" \
    "# see <<EOF for usage
git reset --hard"
  # No python3 verdict at all: the regex still blocks and still allows.
  DGIT_NOPY=$(mktemp -d "${TMPDIR:-/tmp}/dgit-nopy.XXXXXX")
  printf '#!/bin/sh\nexit 1\n' > "$DGIT_NOPY/python3"
  chmod +x "$DGIT_NOPY/python3"
  printf '{"tool_input":{"command":"git checkout ."}}' | PATH="$DGIT_NOPY:$PATH" bash "$DGIT_HOOK" 2>/dev/null
  [ $? -eq 2 ] && ok "blocks git checkout . with no python3 verdict" || bad "should block git checkout . with no python3 verdict"
  printf '{"tool_input":{"command":"git restore --staged .gitignore"}}' | PATH="$DGIT_NOPY:$PATH" bash "$DGIT_HOOK" 2>/dev/null
  [ $? -eq 0 ] && ok "allows a dotfile unstage with no python3 verdict" || bad "should allow a dotfile unstage with no python3 verdict"
  rm -rf "$DGIT_NOPY" 2>/dev/null || bad "could not remove fixture dir $DGIT_NOPY"
fi

# ---------------------------------------------------------------------------
# 18. Behaviour: block-subagent-path-escape.sh
#     Subagent calls carry a top-level agent_id; main-agent calls do not.
#
#     The project root is NOT in the hook input -- it is decoded from the
#     encoded project directory in transcript_path (or scratchpad_dir) by
#     walking the real filesystem, because the encoding replaces every `/`,
#     `.` and space with `-` and is therefore ambiguous. The decoder is
#     exercised against real directories whose names carry those characters.
#
#     The fixture project root lives under $HOME/.cache inside the repository's
#     ignored tmp/ folder. It is not under the system temp directory or
#     $TMPDIR, which are always-allowed zones, so these cases exercise the
#     project boundary instead of passing for the wrong reason.
# ---------------------------------------------------------------------------
section "block-subagent-path-escape.sh behaviour"
SPE_HOOK="$HOOKS_DIR/block-subagent-path-escape.sh"
type json1 >/dev/null 2>&1 || json1() { python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1"; }
spe_enc() { python3 -c 'import re,sys;print(re.sub(r"[^A-Za-z0-9-]","-",sys.argv[1]))' "$1"; }

if [ ! -f "$SPE_HOOK" ]; then
  bad "block-subagent-path-escape.sh missing; skipping behaviour tests"
else
  SPE_BASE=$(mktemp -d "$HOME/.cache/hooktest-XXXXXX")
  SPE_ROOT="$SPE_BASE/proj"
  SPE_SIB="$SPE_BASE/sib"
  mkdir -p "$SPE_ROOT" "$SPE_SIB"
  SPE_SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/spe-scratch.XXXXXX")
  SPE_TP="$HOME/.claude/projects/$(spe_enc "$SPE_ROOT")/sess/subagents/agent-x.jsonl"

  run_spe_bash() {
    # $1 agent_id ("" for the main agent), $2 cwd, $3 command
    if [ -n "$1" ]; then
      printf '{"agent_id":%s,"cwd":%s,"transcript_path":%s,"scratchpad_dir":%s,"tool_name":"Bash","tool_input":{"command":%s}}' \
        "$(json1 "$1")" "$(json1 "$2")" "$(json1 "$SPE_TP")" "$(json1 "$SPE_SCRATCH")" "$(json1 "$3")"
    else
      printf '{"cwd":%s,"transcript_path":%s,"scratchpad_dir":%s,"tool_name":"Bash","tool_input":{"command":%s}}' \
        "$(json1 "$2")" "$(json1 "$SPE_TP")" "$(json1 "$SPE_SCRATCH")" "$(json1 "$3")"
    fi | bash "$SPE_HOOK" >/dev/null 2>&1
  }
  run_spe_tool() {
    # $1 tool_name, $2 file_path
    printf '{"agent_id":"agent-abc","cwd":%s,"transcript_path":%s,"scratchpad_dir":%s,"tool_name":%s,"tool_input":{"file_path":%s}}' \
      "$(json1 "$SPE_ROOT")" "$(json1 "$SPE_TP")" "$(json1 "$SPE_SCRATCH")" "$(json1 "$1")" "$(json1 "$2")" \
      | bash "$SPE_HOOK" >/dev/null 2>&1
  }
  run_spe_root() {
    # Project root from an arbitrary transcript_path. $1 transcript_path,
    # $2 file_path. Used to exercise the decoder against real directories.
    printf '{"agent_id":"agent-abc","cwd":%s,"transcript_path":%s,"tool_name":"Write","tool_input":{"file_path":%s}}' \
      "$(json1 "$HOME")" "$(json1 "$1")" "$(json1 "$2")" | bash "$SPE_HOOK" >/dev/null 2>&1
  }

  expect_spe_block() { run_spe_bash "agent-abc" "$SPE_ROOT" "$1"; [ $? -eq 2 ] && ok "subagent blocked: $1" || bad "subagent should be blocked: $1"; }
  expect_spe_allow() { run_spe_bash "agent-abc" "$SPE_ROOT" "$1"; [ $? -eq 0 ] && ok "subagent allowed: $1" || bad "subagent should be allowed: $1"; }
  expect_spe_block_in() { run_spe_bash "agent-abc" "$1" "$2"; [ $? -eq 2 ] && ok "blocked from $(basename "$1"): $2" || bad "should block from $1: $2"; }
  expect_spe_main() { run_spe_bash "" "$1" "$2"; [ $? -eq 0 ] && ok "main agent allowed from $(basename "$1"): $2" || bad "main agent should be allowed: $2"; }

  # --- the incident, in the shape it happened -------------------------------
  # A subagent's Bash cwd drifted into an off-limits sibling project and
  # `rm -f .gitignore` ran there. Same command, same text, different cwd.
  expect_spe_allow 'rm -f .gitignore'
  expect_spe_block_in "$SPE_SIB" 'rm -f .gitignore'
  # The main agent is never touched, even pointing straight out of the root.
  expect_spe_main "$SPE_SIB" 'rm -f ../other/.gitignore'

  # --- destructive verbs ----------------------------------------------------
  expect_spe_block 'rm -f ../sib/.gitignore'
  expect_spe_block 'rm -rf ../sib'
  expect_spe_block 'mv file ../sib/'
  expect_spe_block "sed -i '' s/a/b/ ../sib/x.ts"
  expect_spe_block 'git checkout -- ../sib/.gitignore'
  expect_spe_allow 'rm -rf ./build'
  expect_spe_allow 'rm -rf ./build 2>/dev/null'
  expect_spe_allow 'cp ../sib/a ./b'
  expect_spe_allow 'git restore .'
  expect_spe_allow 'ls -la && echo done'

  # --- an operand that cannot be resolved ------------------------------------
  # A variable, substitution or glob hides what rm would actually delete, so
  # the delete family fails closed. Everything else is too common for that.
  expect_spe_block 'rm -rf "$TMP"'
  expect_spe_allow 'cp "$SRC" ./b'

  # --- truncating redirects, but not appends ---------------------------------
  expect_spe_block 'echo x > ../sib/file'
  expect_spe_allow 'echo x >> ../sib/file'
  expect_spe_allow 'cat > /tmp/x'
  expect_spe_allow 'echo hi > /dev/null'

  # --- a quoted mention is not an invocation ---------------------------------
  expect_spe_allow 'echo "rm -rf ../sib"'

  # --- the escape hatch, mirroring SUBAGENT_GIT_OK ---------------------------
  expect_spe_allow 'SUBAGENT_PATH_OK=1 rm -f ../sib/.gitignore'

  # --- the orchestrator's scope file is the designed way to widen scope ------
  printf '# widened by the orchestrator\n%s\n' "$SPE_SIB" > "$SPE_SCRATCH/subagent-scope"
  expect_spe_allow 'rm -f ../sib/.gitignore'
  rm -f "$SPE_SCRATCH/subagent-scope"
  expect_spe_block 'rm -f ../sib/.gitignore'

  # --- Edit and Write ---------------------------------------------------------
  run_spe_tool Write "$SPE_SIB/new.txt"
  [ $? -eq 2 ] && ok "blocks Write outside the root" || bad "should block Write outside the root"
  run_spe_tool Edit "$SPE_SIB/x.txt"
  [ $? -eq 2 ] && ok "blocks Edit outside the root" || bad "should block Edit outside the root"
  run_spe_tool Edit "$SPE_ROOT/x.txt"
  [ $? -eq 0 ] && ok "allows Edit inside the root" || bad "should allow Edit inside the root"
  run_spe_tool Write "$SPE_SCRATCH/notes.md"
  [ $? -eq 0 ] && ok "allows Write inside the scratchpad" || bad "should allow Write inside the scratchpad"

  # --- another session's scratch tree is NOT this session's scratch -----------
  # Each encoded project/session lives below the canonical system temp root.
  # Generic temp stays allowed, but it must not re-include another session's
  # scratch tree by prefix.
  SPE_TMP_ROOT=$(python3 -c 'import os; print(os.path.realpath(os.environ.get("TMPDIR", "/tmp")))')
  SPE_C501="$SPE_TMP_ROOT/claude-$(id -u)"
  SPE_OWN_ENC="$SPE_C501/$(spe_enc "$SPE_ROOT")"
  SPE_OWN_SESS="$SPE_OWN_ENC/6d1b9a70-own-session"
  SPE_OWN_SCRATCH="$SPE_OWN_SESS/scratchpad"
  SPE_OTHER_ENC="$SPE_C501/-home-example-other-proj"
  SPE_OTHER_SCRATCH="$SPE_OTHER_ENC/1f0c2a44-other-session/scratchpad"
  mkdir -p "$SPE_OWN_SCRATCH" "$SPE_OWN_SESS/tasks" "$SPE_OTHER_SCRATCH"

  run_spe_sess_bash() {
    # A subagent whose scratchpad_dir is its OWN claude-<uid> session dir.
    printf '{"agent_id":"agent-abc","cwd":%s,"transcript_path":%s,"scratchpad_dir":%s,"tool_name":"Bash","tool_input":{"command":%s}}' \
      "$(json1 "$SPE_ROOT")" "$(json1 "$SPE_TP")" "$(json1 "$SPE_OWN_SCRATCH")" "$(json1 "$1")" \
      | bash "$SPE_HOOK" >/dev/null 2>&1
  }
  expect_sess_block() { run_spe_sess_bash "$1"; [ $? -eq 2 ] && ok "cross-session blocked: $1" || bad "cross-session should be blocked: $1"; }
  expect_sess_allow() { run_spe_sess_bash "$1"; [ $? -eq 0 ] && ok "own-session allowed: $1" || bad "own session should be allowed: $1"; }

  expect_sess_block "rm -f $SPE_OTHER_SCRATCH/x"
  expect_sess_allow "rm -f $SPE_OWN_SCRATCH/x"
  expect_sess_allow "echo x > $SPE_OWN_SESS/tasks/out.txt"
  expect_sess_allow 'rm -f /tmp/x'

  printf '{"agent_id":"agent-abc","cwd":%s,"transcript_path":%s,"scratchpad_dir":%s,"tool_name":"Write","tool_input":{"file_path":%s}}' \
    "$(json1 "$SPE_ROOT")" "$(json1 "$SPE_TP")" "$(json1 "$SPE_OWN_SCRATCH")" "$(json1 "$SPE_OTHER_SCRATCH/notes.md")" \
    | bash "$SPE_HOOK" >/dev/null 2>&1
  [ $? -eq 2 ] && ok "blocks Write into another session's scratchpad" || bad "should block Write into another session's scratchpad"

  rm -rf "$SPE_OWN_ENC" 2>/dev/null || bad "could not remove fixture dir $SPE_OWN_ENC"
  rm -rf "$SPE_OTHER_ENC" 2>/dev/null || bad "could not remove fixture dir $SPE_OTHER_ENC"

  # --- the root also decodes from scratchpad_dir ------------------------------
  printf '{"agent_id":"agent-abc","cwd":%s,"scratchpad_dir":%s,"tool_name":"Write","tool_input":{"file_path":%s}}' \
    "$(json1 "$SPE_ROOT")" "$(json1 "$SPE_C501/$(spe_enc "$SPE_ROOT")/sess/scratchpad")" "$(json1 "$SPE_SIB/x.txt")" \
    | bash "$SPE_HOOK" >/dev/null 2>&1
  [ $? -eq 2 ] && ok "derives the root from scratchpad_dir when transcript_path is absent" \
    || bad "should derive the root from scratchpad_dir"

  # --- a guard that cannot find the root must not block all work --------------
  printf '{"agent_id":"agent-abc","cwd":%s,"transcript_path":"%s","tool_name":"Bash","tool_input":{"command":"rm -f ../sib/.gitignore"}}' \
    "$(json1 "$SPE_ROOT")" "$HOME/.claude/projects/-no-such-dir-anywhere-xyz/s/t.jsonl" \
    | bash "$SPE_HOOK" >/dev/null 2>&1
  [ $? -eq 0 ] && ok "fails open on an undecodable transcript_path" || bad "should fail open on an undecodable transcript_path"

  # --- the decoder, against real directory names ------------------------------
  # `-` in a directory name makes the encoding ambiguous: the decoder must walk
  # the filesystem and backtrack, not split on hyphens.
  SPE_HYPH="$SPE_BASE/my-plugin-github"
  mkdir -p "$SPE_HYPH" "$SPE_BASE/my"
  SPE_HYTP="$HOME/.claude/projects/$(spe_enc "$SPE_HYPH")/s/subagents/a.jsonl"
  run_spe_root "$SPE_HYTP" "$SPE_HYPH/x.ts"
  [ $? -eq 0 ] && ok "decodes a hyphenated root: my-plugin-github" || bad "should decode a hyphenated root"
  run_spe_root "$SPE_HYTP" "$SPE_BASE/my/x.ts"
  [ $? -eq 2 ] && ok "a hyphenated root does not widen to its prefix sibling 'my'" || bad "a hyphenated root should not widen to a prefix sibling"
  run_spe_root "$SPE_HYTP" "$HOME/dev/no-such-sibling/x.ts"
  [ $? -eq 2 ] && ok "a hyphenated root does not widen to a sibling" || bad "a hyphenated root should not widen to a sibling"
  # A space in a directory name encodes to `-` too -- this is the shape of every
  # scratch-workspace project root under ~/Library/Application Support/Claude.
  SPE_SPACED="$HOME/Library/Application Support/Claude"
  if [ -d "$SPE_SPACED" ]; then
    SPE_SPTP="$HOME/.claude/projects/$(spe_enc "$SPE_SPACED")/s/subagents/a.jsonl"
    run_spe_root "$SPE_SPTP" "$SPE_SPACED/x.json"
    [ $? -eq 0 ] && ok "decodes a root whose name contains a space" || bad "should decode a root containing a space"
    run_spe_root "$SPE_SPTP" "$HOME/dev/no-such-sibling/x.ts"
    [ $? -eq 2 ] && ok "a spaced root does not widen to a sibling" || bad "a spaced root should not widen to a sibling"
  else
    printf '  skip ~/Library/Application Support/Claude absent; spaced-root decode untested\n'
  fi

  rm -rf "$SPE_BASE" 2>/dev/null || bad "could not remove fixture dir $SPE_BASE"
  rm -rf "$SPE_SCRATCH" 2>/dev/null || bad "could not remove fixture dir $SPE_SCRATCH"
fi

# ---------------------------------------------------------------------------
# 19. Behaviour: warn-inplace-edit.sh
#     A nudge, never a block: exit 0 always, and the allow JSON only when a
#     sed/perl in-place rewrite really targets a source or doc file outside
#     the scratch directories.
# ---------------------------------------------------------------------------
section "warn-inplace-edit.sh behaviour"
WIE_HOOK="$HOOKS_DIR/warn-inplace-edit.sh"

run_wie_hook() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(json1 "$1")" | bash "$WIE_HOOK" 2>/dev/null; }
expect_wie_nudge() {
  out=$(run_wie_hook "$1"); rc=$?
  if [ $rc -eq 0 ] && echo "$out" | grep -q "additionalContext"; then ok "nudges: $1"
  else bad "should nudge (exit 0 + additionalContext): $1" "exit $rc, out: $(echo "$out" | head -c 120)"; fi
}
expect_wie_quiet() {
  out=$(run_wie_hook "$1"); rc=$?
  if [ $rc -eq 0 ] && [ -z "$out" ]; then ok "quiet: $1"
  else bad "should stay quiet: $1" "exit $rc, out: $(echo "$out" | head -c 120)"; fi
}

if [ ! -f "$WIE_HOOK" ]; then
  bad "warn-inplace-edit.sh missing; skipping behaviour tests"
else
  # The incident shape (2026-09): perl -pi over source files, silently doubling code.
  expect_wie_nudge "perl -pi -e 's/a/b/' lib/x.py"
  expect_wie_nudge "perl -0pi -e 's/a/b/' lib/x.py"
  expect_wie_nudge "perl -pi.bak -e 's/a/b/' lib/x.py"
  # sed -i in every spelling that actually edits in place.
  expect_wie_nudge "sed -i '' 's/a/b/' src/app.ts"
  expect_wie_nudge "sed -i.bak s/a/b/ README.md"
  expect_wie_nudge "sed -Ei 's/a/b/' src/app.tsx"
  expect_wie_nudge "sed --in-place 's/a/b/' src/app.js"
  expect_wie_nudge "cd src && sed -i '' 's/a/b/' app.swift"

  # Reading, not rewriting.
  expect_wie_quiet "sed -n '1p' src/app.ts"
  expect_wie_quiet "sed 's/a/b/' src/app.ts > /tmp/out"
  expect_wie_quiet "perl -e 'print 1' lib/x.py"
  # Scratch copies and generated data are exactly what shell rewrites are for.
  expect_wie_quiet "sed -i '' 's/a/b/' /tmp/x.ts"
  expect_wie_quiet "sed -i '' 's/a/b/' /tmp/x.ts"
  expect_wie_quiet "sed -i '' 's/a/b/' data.csv"
  # A quoted mention is not an invocation.
  expect_wie_quiet 'echo "sed -i"'
  expect_wie_quiet "rg 'perl -pi' docs/"
fi

# ---------------------------------------------------------------------------
section "block-shell-traps.sh behaviour"
HOOK="$HOOKS_DIR/block-shell-traps.sh"
if [ ! -f "$HOOK" ]; then
  bad "block-shell-traps.sh missing; skipping behaviour tests"
else
  SHELL=/bin/zsh
  export SHELL
  # Traps: each fails in the agent's zsh (or silently misleads) and must block.
  expect_block_cmd 'log show --last 5m --predicate "process == \"x\""'
  expect_block_cmd 'sudo log stream --level debug'
  expect_block_cmd 'x=$(log show --last 1m)'
  # `timeout` is a trap only where it is missing (macOS). On Linux coreutils
  # ships it, and the hook correctly lets it through.
  if command -v timeout >/dev/null 2>&1; then
    expect_allow_cmd 'timeout 5 curl http://x'
  else
    expect_block_cmd 'timeout 5 curl http://x'
  fi
  if [ "$(uname -s)" = "Darwin" ]; then
    expect_block_cmd 'strings MyApp | grep key'
    expect_block_cmd 'ssh-add --apple-use-keychain ~/.ssh/id_ed25519'
    expect_block_cmd 'sudo mdutil -E /'
  else
    expect_allow_cmd 'strings MyApp | grep key'
    expect_allow_cmd 'ssh-add --apple-use-keychain ~/.ssh/id_ed25519'
    expect_allow_cmd 'sudo mdutil -E /'
  fi
  expect_block_cmd 'echo =====; ls'
  expect_block_cmd 'for status in a b; do echo $status; done'
  expect_block_cmd 'status=$(curl -s -o /dev/null -w "%{http_code}" x)'
  expect_block_cmd '[ "$a" == "b" ] && echo y'
  # Correct spellings and mentions in data must pass.
  system_log=$(type -P log 2>/dev/null || true)
  [ -n "$system_log" ] || system_log=./log
  expect_allow_cmd "$system_log show --last 5m"
  system_ssh_add=$(type -P ssh-add 2>/dev/null || true)
  [ -n "$system_ssh_add" ] || system_ssh_add=./ssh-add
  expect_allow_cmd "$system_ssh_add --apple-use-keychain ~/.ssh/id_ed25519"
  expect_allow_cmd 'git log --oneline -5'
  expect_allow_cmd 'strings -a MyApp | grep key'
  expect_allow_cmd 'sudo mdutil -E /System/Volumes/Data'
  expect_allow_cmd "echo '====='"
  expect_allow_cmd '[[ "$a" == "b" ]] && echo y'
  expect_allow_cmd 'st=$(curl -s x); echo $st'
  expect_allow_cmd 'rg -n "log show" docs/'
  expect_allow_cmd 'jq ".a == 1" f.json'
  expect_allow_cmd 'curl --max-time 5 http://x'
  expect_allow_cmd $'cat > notes.md <<\'EOF\'\nlog show --last 5m\necho =====\nEOF'
  expect_allow_cmd $'cat <<<"x"\ngit status'
fi

# ---------------------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
