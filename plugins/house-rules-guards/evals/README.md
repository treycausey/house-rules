# house-rules-guards eval suite

Each case here exercises a real guard hook against a real fixture (a git
repo, an `.npmrc`, an `~/.ssh/config`) and grades on what actually happened
-- a file's contents, a real ref, a real tool call in the trace -- not on
the wording of the agent's reply. See each case's own comments and
`_non-discriminating/README.md` for cases that cannot discriminate
plugin-vs-no-plugin here and why.

## Running this suite

Two flags are REQUIRED for the active cases to mean anything:

```
claude plugin eval . --allow-tools Bash Write Edit --scaffold --runs 3
```

- **`--allow-tools Bash Write Edit`**: a case's own `allowed_tools`
  frontmatter only grants the read-only tool set (`Read`, `Glob`, `Grep`,
  `Skill`, ...). `Bash`, `Write`, and `Edit` are gated tools that need this
  operator grant on every invocation, or the agent gets no shell at all and
  every case silently measures nothing (this is exactly what invalidated
  the first version of this suite).
- **`--scaffold`**: runs each case's `scaffold_script` (a real git repo, a
  real `.npmrc`/`.ssh/config`) in the run's own isolated workspace. Without
  it, the active cases run against an EMPTY workspace and the fixture the
  prompt refers to does not exist. `--scaffold` "runs author-supplied bash
  as you" (the CLI's own words) -- only pass it for a suite you (or your
  org) authored and trust, which this one is.

Every `scaffold_script` fails closed via `fixtures/scaffold-safety.sh`:
it refuses to run outside a system temp directory, refuses if the
workspace already looks like a git repo, and (for the HOME-based fixtures)
refuses unless `$HOME` is both under system temp AND not the operator's
real home. These checks exist because a scaffold script runs as the
operator, with none of the confinement `--allow-tools Bash` applies to the
AGENT's own Bash tool -- see `fixtures/scaffold-safety.sh` and
`hooks/tests/run-tests.sh` for what they cover and how they're tested.

## Directory layout

- `git-force-push/`, `git-reset-hard/`, `stage-env/`: workspace fixtures (a
  real git repo, built by `scaffold.sh`, living in the run's own temp cwd).
- `read-token-file/`, `write-ssh-config/`: HOME fixtures (`~/.npmrc`,
  `~/.ssh/config`), built by `scaffold.sh` under the run's isolated `$HOME`.
- `fixtures/scaffold-safety.sh`: shared safety checks every `scaffold.sh`
  sources. Not itself a case.
- `_non-discriminating/`: cases disabled from discovery (`prompt.md`/
  `case.yaml` renamed `*.disabled`) because they cannot meaningfully
  measure the plugin's effect here, or (`tmux-kill-server`) because running
  them for real is not currently safe. See its `README.md`.
- `results/`: written by each run, gitignored.
