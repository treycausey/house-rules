# decide

A decision queue for agents. When an agent needs the owner's judgment, it files
a decision instead of stopping, guessing, or pinging. The owner reads one
digest and answers each item once.

It is an append-only JSONL log, one per machine, at
`$DECIDE_HOME/decisions.jsonl` (default `~/.standing/decisions.jsonl`). Writes
take an `mkdir` lock, so concurrent agents on one machine append safely. Reads
fold the whole log; records are never edited in place.

## Install

Needs [Bun](https://bun.sh).

```bash
cd tools/decide
bun install
bun run test
mkdir -p ~/.local/bin
ln -s "$PWD/bin/decide.ts" ~/.local/bin/decide   # or anywhere on your PATH
```

## Use

```bash
decide add --project <p> --agent <id> --title "<question>" \
  [--option "<a>" --option "<b>"] [--recommend "<a>"] \
  [--context "<why, evidence, branch>"] [--key "<stable-slug>"]
decide list [--open|--all] [--json]
decide resolve <id> "<choice or note>"     # or: --resolution "<choice or note>"
decide digest                              # open decisions by project, as markdown
```

`add` prints the decision id.

### `--key`: fold repeats into one decision

An agent that runs every two hours and finds the same problem each time should
not file twelve decisions a day. Pass `--key` with a short stable slug that
names the problem, not the time (`nightly-backup`, not `since-11-20`). While a
decision with that key, project, and agent is open, `decide add` appends a
`seen` event to it and prints the existing id. `list` and `digest` then show
`×N` and the last-seen time. A resolved decision does not absorb new reports: a
recurrence after resolution is a new decision.

This exists because a watcher agent filed a new "nightly backup failed"
decision every two hours while the backup stayed broken.

## Tell your agents about it

Add to the agent's brief or `CLAUDE.md`:

```
Anything that needs the owner's judgment goes through the decision queue:
  decide add --project "<repo>" --agent "<agent-id>" --title "<one-line question>" \
    --context "<why, evidence, branch>" --key "<stable-slug>"
Run `decide list --open` first. If the problem is already open, reuse its key.
```

## Limits

- One queue per machine. It does not sync, and should not: two machines
  appending to one synced file would conflict.
- No notification. Something has to run `decide digest` and show it to the
  owner (a morning job, a shell prompt hook, a status page).
- `resolve` records an answer. It does not act on it; the agent that filed the
  decision, or the owner, does.
