# house-rules

An operating kit for software repositories that use AI coding agents. It pairs
written rules with hooks that check tool calls and skills that provide policy
and operations guidance.

## Who it is for

- You run more repos than you can watch, and agents do much of the work in them.
- You have written rules for your agents, and noticed the agents do not always
  follow them.
- You want your agents to ship without asking you about every commit, and you
  want a clear line for when they must ask.

It is not a framework or a product. It is a set of files you copy and edit.

## What is inside

### Install as plugins

Add the marketplace once, then install the guard plugin:

```text
/plugin marketplace add treycausey/house-rules
/plugin install house-rules-guards@house-rules
```

| Plugin | What it does | When to turn it off |
|---|---|---|
| `house-rules-guards` | Blocks destructive git operations, unsafe secret-file changes, unsafe token reads, and out-of-scope subagent writes. | When you want none of the blocking hooks enabled. Review the consequences first. |
| `house-rules-warnings` | Adds advice for risky commands and edits. Includes the retry counter and zsh redirection advice. | When you do not want the advice or retry reminders. |
| `house-rules-verify` | Runs formatters and checks, and reminds the agent to verify changed work. | When the project does not use the configured tools or you want to manage these checks yourself. |
| `house-rules-kit` | Provides the house-rules, ship-policy, fleet-standard, and decide skills. It has no hooks. | When you do not want these skills available. |

Claude Code enables or disables each plugin as a whole. Two hooks with `block-`
names run after a tool call and can only add advice: `block-localhost-hardcode`
and `block-test-mocks`. `warn-public-bind` also adds advice and does not block.

### Copy by hand

If you prefer manual setup, copy the hook scripts, merge the settings, and add
the rules yourself. See [Five-minute install](#five-minute-install) below.

The hook sources stay in `hooks/`. `scripts/build-plugins.sh` copies each hook
to one plugin, builds the kit skills from the source docs, and keeps the copies
in sync. `hooks/tests/run-tests.sh` checks that sync.

| Path | What it is |
|---|---|
| [`rules/CLAUDE.md`](rules/CLAUDE.md) | A starter global instructions file for agents: scope, autonomy, secrets, networking, testing, subagents, delivery, debugging. Each rule that a hook enforces names the hook. |
| [`rules/INCIDENTS.md`](rules/INCIDENTS.md) | 15 incidents, each as incident, then rule, then what enforces it. Read this first if you want to know whether a rule applies to you. |
| [`hooks/`](hooks/) | 27 Claude Code hooks that block or warn on the failures in the incident log, a [README table](hooks/README.md) of what each one does and why, an example settings file, and a test runner with about 550 cases. |
| [`standards/fleet-standard.md`](standards/fleet-standard.md) | What every repo must have so any agent can operate it: a hermetic smoke test, a health check that checks real dependencies, a one-command deploy that verifies the new process, and an "Operate" README section. |
| [`standards/ship-policy.md`](standards/ship-policy.md) | The four gates under which an agent ships without asking again, and when it must stop and ask. |
| [`tools/decide/`](tools/decide/) | A decision-queue CLI (Bun). Agents file questions for the owner instead of stopping or guessing; repeats of the same problem fold into one item. |
| [`experimental/standing/`](experimental/standing/) | Design notes for a runner of scheduled, bounded-authority agents. Design only; the code is not released yet. |

## Five-minute install

You need Claude Code, `bash`, `jq`, `python3` 3.9+, and `git`. For `decide`, also
[Bun](https://bun.sh).

**1. Get the kit.** Clone this repository, then change to its directory.

**2. Run the hook tests on your machine.**

```bash
bash hooks/tests/run-tests.sh
```

The last line should read `failed: 0`. If a test fails, the hook it names will
not work on your machine as written; read the failure before installing it.

**3. Install the hooks.** Either for every project (`~/.claude`):

```bash
mkdir -p ~/.claude/hooks/lib
cp -i hooks/*.sh ~/.claude/hooks/     # -i: asks before replacing a hook you already have
cp -i hooks/lib/hook-tools.sh ~/.claude/hooks/lib/
chmod +x ~/.claude/hooks/*.sh
```

or for one repo (`<repo>/.claude/hooks/`, then change `~/.claude/hooks/` to
`"$CLAUDE_PROJECT_DIR"/.claude/hooks/` in the settings).

**4. Wire them.** Merge the `hooks` object from
[`hooks/settings.example.json`](hooks/settings.example.json) into
`~/.claude/settings.json` (or `<repo>/.claude/settings.json`). If you have no
settings file yet, copy the example. If you have one, do not overwrite it:
use the merge command in [`hooks/README.md`](hooks/README.md#install), which
appends the kit's hooks to your existing arrays. Then check the wiring:

```bash
HOOKS_DIR=~/.claude/hooks SETTINGS=~/.claude/settings.json bash hooks/tests/run-tests.sh
```

**5. Add the rules.** Copy [`rules/CLAUDE.md`](rules/CLAUDE.md) to
`~/.claude/CLAUDE.md` (or your repo's `CLAUDE.md`), replace the
`<placeholders>`, and delete the rules that do not fit you.

**6. Optional: the decision queue.**

```bash
cd tools/decide && bun install && bun run test
mkdir -p ~/.local/bin
ln -s "$PWD/bin/decide.ts" ~/.local/bin/decide
```

Start a new Claude Code session so it loads the hooks and rules.

### Hooks you may want to remove

Some hooks encode one platform's choices rather than general safety:

- `block-wrong-runner.sh` blocks `npm`, `yarn`, and `pnpm`, because this platform
  is Bun-only.
- `xcodegen-stale-check.sh` matters only for XcodeGen iOS projects.
- `prettier-on-edit.sh` runs only in projects that already use Prettier.
- `verify-visual-edits.sh` expects a screenshot command after UI edits. Set
  `SCREENSHOT_CMD_RE` to your tool's name.
- `block-shell-traps.sh` checks zsh-specific and macOS-specific traps only on
  those platforms. `fix-noclobber-redirect.sh` warns about existing-file
  redirects in shells that use `noclobber`.

## Limits

Read these before you install anything.

- **Claude Code specific.** The hooks use Claude Code's hook events and JSON
  input (`tool_input`, `agent_id`, `transcript_path`, `scratchpad_dir`). Other
  agent tools will need adapters. The rules file is plain text and works with
  any agent that reads an instructions file.
- **Platform-specific checks remain.** `block-shell-traps.sh` adapts its
  checks to zsh and macOS. `xcodegen-stale-check.sh` applies only to XcodeGen
  projects. Other hooks use Bash, Python, and common GNU or BSD tools.
- **Private networking is up to the project.** The networking rules recommend
  an authenticated proxy or private network for remote access. Choose the
  mechanism that fits your setup.
- **Hooks are guardrails, not a sandbox.** They parse commands to decide what
  runs, and a determined or confused agent can phrase a command they do not
  recognize. Use them with Claude Code's permission settings and sandbox, not
  instead of them.
- **Most hooks fail open.** When input is missing or unparseable, most hooks
  allow the call. This is deliberate (a broken guard must not stop all work),
  and it means a hook that silently stops running looks the same as one that
  never fires. Run the test suite after any change. `block-destructive-git.sh`
  fails closed: if it cannot parse a command, it falls back to a pattern match
  over the raw text and blocks on any hit.
- **JS/TS checks need `bunx` or `npx`.** `pre-commit-lint.sh` (eslint, tsc) and
  `prettier-on-edit.sh` use `bunx`, fall back to `npx --no-install`, and tell
  the agent when neither is installed.
- **`standing` is experimental and not included as code.** See
  [`experimental/standing/`](experimental/standing/).
- **One platform's evidence.** The incidents come from one person's repos over a
  few months. They are real, but they are not a survey.

## Roadmap

Week 2 is about proving `standing`, the scheduled-agent runner, before its code
goes in:

- Run at least three standing agents on a schedule for a week, on more than one
  machine, and publish the run history (success, quiet, failed) with the
  failure reasons.
- Make host names, credential paths, alert channels, and heartbeat targets
  configuration, with no personal defaults, and test a fresh install from this
  repo on a clean machine account.
- Show one full propose loop: an agent files a decision with a branch, the owner
  resolves it, and the branch ships through the ship-policy gates.
- Show one failure loop: a broken credential, a filed and folded failure
  decision, an alert, and recovery.

## License

MIT. See [`LICENSE`](LICENSE).
