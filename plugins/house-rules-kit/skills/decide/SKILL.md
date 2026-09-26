---
name: decide
description: Use when an agent needs an owner's judgment and must file a decision instead of guessing or stopping.
---

# File a decision

Use the bundled decision queue when an action needs the owner's judgment. First
run `list --open` and reuse the same `--key` if the issue is already open. Add
the evidence, impact, and current branch to the context. Do not resolve a
decision unless the owner has supplied the answer.

Run the bundled CLI through Bun:

```bash
bun "${CLAUDE_PLUGIN_ROOT}/tools/decide/bin/decide.ts" list --open
bun "${CLAUDE_PLUGIN_ROOT}/tools/decide/bin/decide.ts" add \
  --project "<repo>" --agent "<agent-id>" --title "<question>" \
  --context "<evidence, impact, branch>" --key "<stable-slug>"
```

Use `--option` more than once and `--recommend` when there are clear choices.
The queue is local to the machine. It uses `DECIDE_HOME` when set, otherwise
`~/.standing/decisions.jsonl`; do not sync that file between machines.
