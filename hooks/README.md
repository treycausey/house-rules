# hooks

Claude Code hooks that turn written rules into checks. Each one exists because
an agent broke the rule it enforces at least once, usually more than once, while
the rule was already written down.

A hook reads the tool call as JSON on stdin. Exit code `2` blocks the call and
shows stderr to the agent. Exit `0` with JSON on stdout attaches advice
(`additionalContext`) or, for a Stop hook, a `{"decision":"block"}` that sends
the agent back to finish. Most hooks here fail open when their own input is
missing or unparseable: a broken guard must not stop all work. `block-destructive-git.sh` is the
exception: when it cannot parse a command (or `python3` is missing), it falls
back to a pattern match over the raw command text and blocks when that
matches, even if the match is only a quoted mention.

## Install

```bash
mkdir -p ~/.claude/hooks
cp hooks/*.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/*.sh
```

Then merge the `hooks` object from [`settings.example.json`](settings.example.json)
into `~/.claude/settings.json`. If you have no settings file, copy the example.
If you have one, do not overwrite it; merge:

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.bak
jq -s '.[0] as $mine | .[1].hooks as $kit
  | $mine + {hooks: (reduce ($kit | keys[]) as $e
      (($mine.hooks // {}); .[$e] = ((.[$e] // []) + $kit[$e])))}' \
  ~/.claude/settings.json.bak hooks/settings.example.json > /tmp/settings.merged.json
# read /tmp/settings.merged.json, then:
mv /tmp/settings.merged.json ~/.claude/settings.json
```

This appends the kit's entries to each event's array and keeps your own hooks
and every other setting. Do not use `jq -s '.[0] * .[1]'`: it replaces whole
arrays, so your existing `PreToolUse` and `PostToolUse` hooks would be dropped.
Running the merge twice adds the kit's entries twice.

Delete any hook you do not want from both the directory and the settings.

For a single repo instead of your whole machine, copy the hooks into
`<repo>/.claude/hooks/` and change `~/.claude/hooks/` to
`"$CLAUDE_PROJECT_DIR"/.claude/hooks/` in the commands.

Requirements: `bash` (3.2 or later), `jq`, `python3` (3.9 or later), `git`.

## Test

```bash
bash hooks/tests/run-tests.sh
# test what you installed, against your real settings file:
HOOKS_DIR=~/.claude/hooks SETTINGS=~/.claude/settings.json bash hooks/tests/run-tests.sh
```

The suite checks three things: every hook the settings file wires exists (a
missing script exits 127 on every tool call, silently); every hook parses under
both `/bin/bash` 3.2 and the `bash` on your PATH (each has a different heredoc
parse bug); and each hook blocks what it should and allows what it should,
including the false positives that were reported against earlier versions.

## What each hook does

"Blocks" means exit 2. "Warns" means it adds context and lets the call run.

### PreToolUse: Bash

| Hook | Blocks or warns | Why | Incident |
|---|---|---|---|
| `block-destructive-git.sh` | Blocks `push --force` (incl. `--force-with-lease`), `reset --hard`, `checkout`/`restore` of a whole tree (`.`), `clean -f`. Only counts git commands a segment actually runs, not quoted mentions. | These destroy work with no undo, and an agent will reach for them to "clean up". | Earlier versions matched raw text and blocked `echo "git reset --hard"` and heredoc bodies, so agents learned to route around the hook. The rewrite parses segments. |
| `protect-secrets-files.sh` | Blocks `rm`, `mv`, truncation, or overwrite of secret-like files (`.env` and `.env.*` except `.env.schema`, names containing `secret` or `credential`, `.pem`, SSH private keys). Example, sample, and template files are exempt. Reads pass. | A secrets file is usually the only copy: gitignored, not in any backup, not regenerable. | A delegated agent ran `rm wifi_secrets.h`; the credentials were gone. |
| `block-sensitive-git-add.sh` | Blocks `git add` that stages `.env*`, `.DS_Store`, or `tmp/`. For `.DS_Store` it also adds the gitignore entry. | Staging is where secrets enter history. | Weekly reviews flagged `.DS_Store` staging as a repeat nuisance for two months. An earlier version blocked `git add x && echo ".env staged?"`. |
| `block-wrong-runner.sh` | Blocks `npm`, `yarn`, `pnpm`, and bare `bun <script>` / `bun test` in a repo whose `package.json` defines that script. **Opinionated:** it enforces a Bun-only estate. Delete it if you use npm. | Mixed package managers produce mixed lockfiles; bare `bun test` runs Bun's runner instead of the repo's `test` script. | Earlier text matching blocked `echo "npm install check"`. |
| `warn-public-bind.sh` | Blocks dev servers that bind `0.0.0.0` (including the Python stdlib file server, which does so by default). | A server bound to all interfaces is on the whole LAN, usually with no auth. | A throwaway file server in a side project served that project's `.env` (mail, shipping, and LLM API keys) to the home network for ten days. |
| `block-tmux-kill-server.sh` | Blocks `tmux kill-server`. | It ends every tmux session, including the one the agent may be running in, with no prompt. | |
| `pre-commit-lint.sh` | Blocks `git commit` when staged files fail the repo's linter, or a staged file is very long. Triggers only on a real `git commit` invocation. | Lint errors were found by review after commit, again and again. | A `perl -pi` command whose replacement text contained "git commit" once triggered it. The trigger now parses commands. |
| `fix-noclobber-redirect.sh` | Warns when `>` targets an existing file. | Under zsh `noclobber`, `>` fails on an existing file with an error that does not say why. | Matters for commands you hand to a human's shell; the agent's own shell usually has `noclobber` off. |
| `protect-ssh-config.sh` | Blocks writes under `~/.ssh`. Reads pass. | Private keys are unrecoverable; a synced `~/.ssh/config` spreads a bad edit to every machine. | |
| `block-subagent-git-mutation.sh` | Blocks a **subagent** from `git stash`, `checkout`, `switch`, `reset`, `commit`. The main agent is not affected. | Parallel agents share one working tree. | Three incidents in one week: a subagent's mid-run `git stash` silently reverted staged fixes into a commit; a `git checkout -b` collided with another process. The rule was already in CLAUDE.md for all three. |
| `block-token-file-reads.sh` (also on `Read`) | Blocks dumping known token files (`gh` `hosts.yml`, `.netrc`, `.npmrc`, cloud credential files, CI agent configs) into the transcript, and Varlock commands that print unredacted values. Suggests a redacted read instead. | A transcript is a log. A token in it has to be rotated. | Two live tokens leaked in one week: a `cat` of the GitHub CLI config during a keychain diagnosis, and a CI agent config during an audit. A later scratch command with a plaintext output format ran in a real project and printed ten keys. |
| `block-subagent-path-escape.sh` (also on `Edit`/`Write`) | Blocks a **subagent** from deleting or overwriting files outside the session's project root, its scratchpad, and `/tmp`. The orchestrator can widen scope by listing directories in `<scratchpad>/subagent-scope`; a one-off is allowed with `SUBAGENT_PATH_OK=1 <cmd>`. | A subagent's shell `cwd` persists and drifts. | During a config migration, a subagent's `cwd` drifted into an off-limits sibling repo, where it ran `rm -f .gitignore` and then wrote test content over it. It was the second cwd incident with real damage that week. |
| `warn-inplace-edit.sh` | Warns on `sed -i` / `perl -pi` against source or doc files. | A shell rewrite reports nothing about how many matches it changed. The Edit tool shows the diff and refuses a non-unique match. | A `perl -pi` pass silently duplicated code, and no test caught it. |
| `block-shell-traps.sh` | Blocks zsh/macOS commands that fail with a misleading error, and names the working spelling: bare `log` (a zsh builtin), `timeout` (absent on macOS), a variable named `status` (read-only in zsh), a word starting with `=` (zsh expands it and skips the rest of the call), and others. | Each trap cost real debugging time because the error pointed at the wrong cause. | `echo =====` as a divider silently skipped the next command in an agent call. |

### PreToolUse: Edit / Write

| Hook | Blocks or warns | Why | Incident |
|---|---|---|---|
| `block-edit-without-read.sh` | Blocks an Edit when the transcript proves the file was not read, or changed since the read. | Claude Code rejects these edits anyway; the hook gives a short, early error instead of a wasted round trip. | Files injected into context at session start (CLAUDE.md, memory) look read but are not. |
| `protect-ssh-config.sh`, `protect-secrets-files.sh`, `block-subagent-path-escape.sh` | Same as above, for the file tools. | | |

### PostToolUse

| Hook | Blocks or warns | Why | Incident |
|---|---|---|---|
| `prettier-on-edit.sh` | Runs Prettier on the edited file, only if the project opted into Prettier. | Formatting drift in review. | Without the opt-in check, Prettier's default 80-column width reflowed whole files in projects that never used it. |
| `warn-long-file.sh` | Warns when an edited file passes 500 lines. | Long files are where agents lose track of what already exists. | |
| `block-localhost-hardcode.sh` | Warns on `localhost` URLs hardcoded in browser-side source. | A browser on another device resolves `localhost` to itself. Use relative paths and a server-side proxy. | |
| `warn-field-mismatch.sh` | Warns on common backend/frontend field-name mismatches in API types (`metadata_` vs `metadata`, singular vs plural). | These contract bugs survived full implementation sessions and surfaced only in review. | |
| `env-port-sweep.sh` | After a config file's port changes, warns about stale ports left in `.env*` files. | Gitignored `.env.local` files survive source changes. | |
| `block-test-mocks.sh` | Warns on new mocks in test files, only in projects whose CLAUDE.md declares a no-mocks rule. | Mock-heavy tests pass while the app is broken. | It once fired globally, citing a rule the global CLAUDE.md did not contain, in a repo whose suite correctly used mocks. |
| `verify-proxy-routes.sh` | Warns when a backend adds `/api/<prefix>` routes the frontend dev proxy does not forward. | "New route, forgot the proxy" is a bug class that passes every backend test. | |
| `xcodegen-stale-check.sh` | Reminds to run `xcodegen generate` after adding a Swift file in an XcodeGen project. Apple projects only. | A stale `.xcodeproj` builds without the new file and reports zero tests found, with no error. | 40 to 65 regenerate-and-rebuild loops per session before the reminder existed. |
| `warn-localhost-verify.sh` (Bash) | Warns when a reachability probe hits only `localhost`. | "It responds on localhost" proves nothing about another device. | Two weekly reviews in a row found "reachable" claims backed only by a localhost curl. |

### PostToolUseFailure

| Hook | Blocks or warns | Why | Incident |
|---|---|---|---|
| `retry-counter.sh` | Warns after 3 similar failed Bash commands in one session. | Enforces "state the failure mechanism before another attempt". | It was first wired to `PostToolUse`, which fires only on success, so it counted zero failures for weeks. |

### Stop

| Hook | Blocks or warns | Why | Incident |
|---|---|---|---|
| `verify-before-done.sh` | Reminds to verify the user-visible flow when the session stops with uncommitted full-stack changes, and warns on edited files with near-duplicate siblings (`app.py` next to `app_old.py`). | "Tests pass but the UI is broken." | A batch of five bug fixes that each passed tests and did not work in the browser. |
| `verify-visual-edits.sh` | Sends the agent back once if the last CSS/TSX/HTML edit has no screenshot command after it. Set `SCREENSHOT_CMD_RE` to your screenshot tool's command name (default `webshot\|shot-scraper\|playwright`). | Visual changes need visual evidence. | |

## Hooks not included, and why

Hooks tied to one person's devices, keychain layout, notification accounts,
or private tools were dropped when this kit was assembled.
