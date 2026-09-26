---
name: house-rules
description: Use when setting up or reviewing agent instructions, scope, secrets, tools, testing, and delivery.
---

# Global agent instructions (starter)

A starter `CLAUDE.md` for a person who runs many repos with coding agents.
Copy it to `~/.claude/CLAUDE.md` (every project) or `<repo>/CLAUDE.md` (one
project), then edit. Replace every `<placeholder>`. Delete rules that do not
fit your setup; a rule the agent cannot follow teaches it to ignore the file.

Most rules here were written after something went wrong. Fifteen of those
incidents are in `rules/INCIDENTS.md` in the house-rules repo. Where a
hook from that repo's `hooks/` directory enforces a rule, the hook name is in
brackets, for example [hook: `block-destructive-git.sh`].

Rules marked *(example, adapt)* describe one setup (zsh on macOS, iCloud,
Tailscale, a synced `~/.ssh`). Keep the idea; rewrite the specifics for yours.

## Communication

- Address me as `<name>`.
- Use plain, direct technical English. Prefer short sentences.
- Lead with the outcome. Include material evidence, caveats, blockers, and the next action.
- End every multi-step or unattended run with three headings, in this order:
  **Blocked on me**, **Changed**, **Found**. Write "nothing" under an empty heading.
- Do not re-propose a suggestion I declined earlier in the same session.
- Say what you mean. Do not replace a literal phrase with a metaphor.

## Scope and autonomy

- For requests to answer, explain, review, diagnose, or plan: inspect and report.
  Do not implement unless the request also asks for it.
- For requests to change, build, or fix: make the in-scope local changes and run
  relevant non-destructive checks without asking first.
- Pause only for a destructive or irreversible action, an external write, a
  material scope change, or input only I can provide.
- When you have enough information to act, act. Recommend one path when judgment
  is required. Do not list options you will not pursue.
- Deliver the requested scope. No unrelated features, refactors, abstractions,
  defensive code, or speculative flexibility.
- Pilot on one item before batching. Before a batch, state any design choice
  that affects cost, sharing, or rollback, and wait for my yes.
- When a sub-feature of a larger task completes, report what is done and what
  remains. Say "complete" only when every top-level item is verified.

## Repository work

- Before editing, inspect the branch, working tree, relevant instructions, and
  recent history. Preserve unrelated changes.
- Read referenced files and scripts before using or discussing them. Verify
  unfamiliar CLI flags with `--help` or the project's docs.
- Files injected into context at session start (this file, memory files) still
  need an explicit Read before an Edit. The injected copy can be stale.
  [hook: `block-edit-without-read.sh`]
- Assume early development with no users unless a repo says otherwise: make
  clean changes, no compatibility shims.
- Preserve existing features and visible UI unless I ask for their removal.
- Update install and run docs when a change affects setup, commands, or behavior.
- Background, scheduled, and pipeline code must fail loud: throw, log, or alert
  on every error path. Never silently skip an item, drop data, or roll back a
  write. A silent failure path in unattended code is a defect even when the
  happy path works.

## Tooling

- One package runner per language, enforced: `<bun | npm | pnpm>` for
  JavaScript/TypeScript, `<uv | pip>` for Python. Run package scripts through
  the runner (`bun run test`), never the runner's built-in test command by
  accident. [hook: `block-wrong-runner.sh`, written for Bun]
- Delete with a recoverable command (`trash`) when one exists.
- The shell's working directory persists between calls. Check `pwd` before a
  relative `cd` or path. Prefer `git -C <dir>` over `cd <dir> && git`.
- Put temporary files in `tmp/` and never commit them. Concurrent sessions share
  a repo's `tmp/`, so put a session or agent id in each file name
  (`tmp/<id>-commit-msg.txt`), never a fixed name.
  [hook: `block-sensitive-git-add.sh` blocks staging `tmp/`]
- Structured-output schemas: some model APIs reject array-length constraints at
  runtime. Enforce caps in post-processing, and smoke-test every schema against
  the live API with a real payload before relying on it.

## Secrets

- Never read, print, or copy secret values into the transcript. Use a redacted
  view (key names only, or your secrets manager's redacted output).
  [hook: `block-token-file-reads.sh`]
- Never delete or overwrite a secrets file; it is usually the only copy.
  [hook: `protect-secrets-files.sh`]
- To give an app an API key, hand me a command that prompts for it with hidden
  input and writes it to a gitignored, mode-600 file. I run it. The key never
  enters the transcript.
- A secrets manager that redacts non-TTY output will write the redaction mask,
  not the value, when you pipe or redirect it. Never move a secret between
  machines through an agent shell. Hand me the command, ending with a hash
  comparison (`shasum -a 256`) on both sides.

## Networking and UI

- Frontend code uses relative API paths and server-side proxies. No hardcoded
  `localhost` in browser-resolved URLs. [hook: `block-localhost-hardcode.sh`]
- Bind development servers to `127.0.0.1`. Never bind `0.0.0.0`: it exposes the
  server to the whole LAN. Publish to other devices through an authenticated
  tunnel or private network instead (*example, adapt:* `tailscale serve`).
  [hook: `warn-public-bind.sh`]
- When a server starts, report its bound address, its private-network URL, and
  one reachability result from the network position the claim is about.
  [hook: `warn-localhost-verify.sh`]
- A scheduled job (launchd, cron, systemd) runs with a bare PATH. Any job that
  shells out to user-installed tools must set PATH explicitly or use absolute
  tool paths. Same for non-login SSH commands.
- For UI changes, verify the changed element in the running app with a
  screenshot from a headless browser. [hook: `verify-visual-edits.sh`]
- A feature verified by a deploy or health check must also be verified through
  the user-facing click path that reaches it. An orphaned entry point passes
  every health check.
- Before wiring up a notification channel, send one test message through it.
- Show user-facing failures as readable error text, not serialized objects.

## Tests and evidence

- Unit tests written while developing are scaffolding. Delete them before
  commit unless they cover a fixed bug, a tricky pure function, or a public contract.
- The permanent suite is small: integration tests at real seams, end-to-end
  smoke tests, and regression tests. Mock only external or nondeterministic
  dependencies. [hook: `block-test-mocks.sh`, opt-in per repo]
- Test suites target a local or test-only backend, never production. Check which
  endpoint the config resolves to before running a suite that talks to a service.
- Add a regression test for every bug fix. Watch it fail without the fix and
  pass with it.
- Verify service and UI changes in the running application, not only in the
  suite. Report evidence: HTTP responses, log lines, screenshots.
  [hook: `verify-before-done.sh`]
- Ground completion claims in tool results from the current session. If a check
  failed or was skipped, say so.
- Before declaring a fix, clear any flags, mocks, or debug state your own
  diagnostics set, then reproduce through the real user-facing action.
- After a change to an unattended job's auth or environment, re-run the job on
  every machine it runs on and confirm the real output landed. Code that "should
  work now" is not evidence.
- After an env-loader or PATH change, restart every long-lived service (scheduled
  jobs, process-manager apps) that has not restarted since, and check each one
  through its public path, not only a health endpoint.
- Before shipping a feature built on existing user data, sample the real data's
  shape (counts, duplicates, cardinality), not just a demo record.

## Friction log

- When you hit tooling friction (a dead-end call, stale docs, a misleading
  error, a script that does not work as documented), append one line to a
  friction log (for example `PAPERCUTS.md` in your projects folder) and move on. Do not fix it unless it
  blocks the current task. A weekly session triages the log.

## Issue tracking

- File out-of-scope or follow-up work as an issue (`gh issue create --label
  agent-filed`), not a TODO comment or a chat-only mention.
- At the end of a task, reconcile open issues: close what the session resolved,
  fix what is small and in scope, label the rest.

## Subagents

- State the model-routing plan at the start of delegated work: which model
  plans, which writes code from a written spec, which reviews with fresh
  context. Pass the model explicitly on every agent call.
- Delegate only independent, sizeable work. Do not spawn agents to double-check
  your own work.
- Keep parallel agents on disjoint files. No hook checks disjointness inside a
  repo; `block-subagent-path-escape.sh` only keeps subagents from deleting or
  overwriting outside the project root.
- After delegated implementation, inspect the changed files and verify the seams
  between independently produced parts.
- A delegated bug-fix agent verifies its own fix red to green before reporting
  done. The orchestrator spot-checks that claim.
- Subagents do not mutate shared git state (`stash`, `checkout`, `reset`,
  `commit`) unless that is their task. Compare `git status` before and after a
  multi-agent dispatch. [hook: `block-subagent-git-mutation.sh`]
- In long or unattended runs, keep the checklist in a file
  (`tmp/<id>-TASKS.md`) and update it after each step. A context summary drops
  scrollback, not files.
- To let a subagent edit outside the project root, the orchestrator lists the
  directory in `<scratchpad>/subagent-scope` before dispatch.
- Before a diff-based review, `git add` all new files. Untracked files are
  invisible to the reviewer, which then reports them as missing.

## Delivery and safety

- Ship policy: see `standards/ship-policy.md` in the house-rules repo.
  Work I asked for ships without asking again once every gate passes.
- Before saying "shipped", "deployed", or "done", check the target directly:
  `git log origin/<branch>..HEAD` is empty, the deploy endpoint responds with
  the new version. A local merge is not a push. Uncommitted code is never done.
- Before handing me a command to run, verify its paths, URLs, and preconditions
  yourself. If a part cannot be verified, say which part.
- No destructive git commands or force-push without explicit approval.
  [hook: `block-destructive-git.sh`]
- Never commit secrets, `.env*`, `.DS_Store`, `tmp/`, or other nuisance files.
  [hook: `block-sensitive-git-add.sh`]
- Inspect the diff and pass the project's checks before any commit.
  [hook: `pre-commit-lint.sh`]

## Debugging

- Before proposing a fix, state the failure mechanism in one falsifiable
  sentence. No sentence means no diagnosis. Retries, bounds, and caches are
  mitigations, not diagnoses.
- If the same symptom is reported twice, stop patching. Write a root-cause brief
  (evidence, hypotheses, discriminating checks) before editing again.
  [hook: `retry-counter.sh`]
- Read logs and screenshots before forming hypotheses. Verify third-party APIs
  and CLI flags against current docs or `--help`, and state where the fact came from.
- Change one variable at a time. Separate "I verified this" from "this seems
  true". "Presumably" and "should be" mean go run the check.
- Verify the real signal, not a proxy. An exit code or a wrapper's "success"
  line records the last thing that happened. Check that the artifact changed on
  the target (timestamp, hash, served version).

## Shell and macOS traps *(example, adapt)*

For zsh on macOS. Each of these fails with an error that points at the wrong
cause. Replace the list with your own shell's traps.
[hook: `block-shell-traps.sh` blocks most of them]

- Spell `/usr/bin/log`. Bare `log` is a zsh builtin.
- macOS has no `timeout`. Use the tool's own timeout flag.
- Never name a zsh variable `status`. It is read-only.
- Do not start a word with `=` (`echo =====`). zsh fails it and skips the rest
  of the command.
- zsh sends output to every redirect target (MULTIOS). To split streams, use
  `cmd >out 2>err`.
- In commands handed to a human whose shell sets `noclobber`, overwrite with
  `>|`. [hook: `fix-noclobber-redirect.sh`]
- `/bin/bash` on macOS is 3.2. Scripts that launchd runs must parse under it.
- *(example, adapt)* A file under an iCloud-synced folder with "Optimize Storage" can be evicted.
  A background job then fails on read with `EDEADLK` ("Resource deadlock
  avoided"). Set `MaterializeDatalessFiles` in the job's plist, or keep the
  file outside iCloud.
- *(example, adapt)* A synced `~/.ssh/config` can reference keys that are not
  synced. When SSH auth fails on a second machine, check that every referenced
  file exists there first. (No hook checks this. `protect-ssh-config.sh` only
  blocks writes under `~/.ssh`.)
