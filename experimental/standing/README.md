# standing (experimental, design only)

**Status: not included as code.** This directory describes the design of
`standing`, a runner for unattended agents. The code exists in the author's
private platform but is one day old and has not yet run long enough to prove it
works. It will be added here once it has. Only its decision queue,
[`decide`](../../tools/decide/), is included now, because it runs standalone
and has its own tests.

Why the code is held back:

- It has about one day of real runs. Several of the incidents in
  [`../../rules/INCIDENTS.md`](../../rules/INCIDENTS.md) are about unattended
  jobs that were declared fixed without being re-run. Publishing a scheduler
  before it has run for a few weeks would repeat that mistake.
- Its host matching, credential paths, alert channel, and health-probe targets
  are tied to one person's machines. Making them configurable is a real change,
  not a find-and-replace, and it should be tested before release.
- It is macOS-only (launchd plists).

## What it is

A standing agent is a markdown file with YAML frontmatter and a brief:

```yaml
---
name: inbox              # unique within the repo; matches the file name
trigger:                 # exactly one of:
  schedule: {hour: 7, minute: 0, weekday: 0}   # launchd StartCalendarInterval
  # interval: 1800                             # seconds, StartInterval
  # watch: [inbox]                             # paths; launchd WatchPaths
host: <host-alias>       # which machine runs it: a configured alias, or "any"
authority: propose       # propose (default) | ship
model: <model>           # passed to the agent CLI
budget_minutes: 30       # wall-clock budget for the whole run, across retries
---
What the agent does each run, in plain markdown.
```

Files live at `<repo>/.standing/<name>.md` (project agents) or
`~/.standing/agents/<name>.md` (global agents). One CLI discovers them,
installs each as a launchd job on the machine its `host` names, runs it, and
records what happened.

## The contract

Every run gets a fixed preamble prepended to its brief. This preamble is the
only thing that bounds an unattended agent's authority, because the agent runs
without permission prompts. It says:

- **propose** authority: work on a local branch
  `standing/<name>/<timestamp>` in your own git worktree, commit there, never
  push or merge. File a decision naming the branch.
- **ship** authority: merge and push only docs, config, tests, or bug fixes
  with a regression test, with no schema or data migration, only after the
  repo's checks pass and a fresh-context review finds no confirmed defect.
  Otherwise fall back to propose. (This is the unattended scope of
  [`../../standards/ship-policy.md`](../../standards/ship-policy.md).)
- Never edit the live checkout; it may hold the owner's uncommitted work.
  Never `stash`, `checkout`, `switch`, `reset`, or `clean` there. Update it
  afterwards only with `pull --ff-only`, and only if it is clean.
- Never send messages, post publicly, delete data, or force-push.
- Anything needing the owner goes through `decide add ... --key <slug>`.
- Write a run report whose first line is `STATUS: ok`, `STATUS: quiet`, or
  `STATUS: failed — <reason>`. The runner reads that line, not the exit code.
- Fail loud. A silent no-op is a defect.

## Runner behaviour

- A per-agent lock so overlapping triggers never double-run one agent.
- For `watch` triggers, a ledger of seen files that updates only after a
  successful run, so a failed run retries the same input.
- A fallback chain of agent CLIs and credentials that shares one wall-clock
  budget, so a dead credential cannot burn the budget once per fallback.
- Every attempt's output, prompt, and a `status.json` saved per run.
- On total failure: a decision is filed (keyed per agent, so repeats fold), an
  alert is sent, and if no alert channel is configured, a line is appended to
  an `ALERTS.md` file rather than failing silently.
- Generated launchd plists set `PATH` explicitly, because launchd jobs start
  with a bare one.

## Heartbeat

A separate plain script (not an agent), run every 60 seconds by launchd, probes
a list of targets (`tcp` connect or `http` status) and alerts once when one
fails three times in a row, once a day while it stays down, and once when it
recovers. It must not depend on anything it watches.

## What week 2 needs to prove

See the root [README](../../README.md#roadmap).
