# Incidents

Every rule in [`CLAUDE.md`](CLAUDE.md) exists because something went wrong
first. This file keeps the story next to the rule, so a reader can judge
whether the rule applies to them, and so nobody deletes a rule without knowing
what it prevents.

Format: **incident → rule → what enforces it.** "Hook" means a script in
[`../hooks/`](../hooks/) that runs on every matching tool call. "Check" means a
test, script, or step a human or agent runs. "Rule only" means nothing enforces
it yet, which is the weakest state a rule can be in.

The incidents come from one person's estate of about 40 repos, run mostly by
coding agents, in mid-2026. Project names, host names, and exact dates are
removed.

A pattern runs through the list: most of these rules were already written down
when the incident happened. Written rules alone did not hold. Hooks did.

---

### 1. A subagent deleted a file in a repo it was never assigned

**Incident.** During a config migration across many repos, a subagent's shell
working directory drifted into a sibling repo. It ran `rm -f .gitignore` there,
then wrote test content over the file. It was the second cwd-confusion incident
with real file damage in the same week. The rule "keep parallel agents on
disjoint files" was already in CLAUDE.md.

**Rule.** Keep parallel agents on disjoint files. A subagent may only delete or
overwrite inside its assigned scope.

**Enforced by.** Hook `block-subagent-path-escape.sh`: blocks a subagent's
`rm`, `mv`, overwrite, or `sed -i` outside the project root, its scratchpad,
and `/tmp`. The orchestrator widens scope in `<scratchpad>/subagent-scope`.

### 2. A subagent's `git stash` put reverted code into a commit

**Incident.** In one week, in two projects: a subagent ran `git stash` mid-run
and silently reverted fixes that another agent had staged, and those reverts
went into the next commit. Separately, a subagent's `git checkout -b` in a
working tree another process was using caused a real merge conflict. The rule
was already written for both.

**Rule.** Subagents do not mutate shared git state (`stash`, `checkout`,
`switch`, `reset`, `commit`) unless that is their assigned task.

**Enforced by.** Hook `block-subagent-git-mutation.sh`. A subagent whose task
really is git work re-runs with `SUBAGENT_GIT_OK=1`, which leaves a visible
acknowledgement in the transcript.

### 3. The bind policy itself exposed dev servers to the LAN

**Incident.** A hook already governed how dev servers bind, and it enforced the
opposite of today's rule: bind `0.0.0.0`, so other devices could reach dev
servers over a private network. That also put every dev server on the whole
home LAN, with no firewall and usually no auth. A security audit found that a
Python built-in file server in one side project had served the project's
`.env` (a mail token, a shipping API secret, and an LLM API key) to any device
on the network for ten days.

**Rule.** Bind dev servers to `127.0.0.1`. Reach them from other devices by
publishing the loopback port through an authenticated private network (the
kit's wording assumes Tailscale: `tailscale serve`), never by binding `0.0.0.0`.
Verify reachability from the device the claim is about, not from localhost.

**Enforced by.** Hook `warn-public-bind.sh`, reversed after the audit, now
blocks `0.0.0.0` binds and the default-bind file server. The second half of the
rule, flagging a "reachable" claim tested only against localhost, lives in a
separate hook, `warn-localhost-verify.sh`. Three weekly reviews in a row
reported that check as unapplied because they read only the bind hook; the
bind hook's header now points to the other file.

### 4. Live tokens printed into agent transcripts

**Incident.** Two live credentials leaked into transcripts in one week, each
needing a manual rotation. During a keychain diagnosis an agent ran `cat` on the
GitHub CLI's config file and printed the OAuth token. During an audit of a CI
agent, it printed the agent's registration token. Later, a scratch command
asked the secrets manager for plaintext output; its `cd` had failed, so it ran
inside a real project and printed ten keys.

**Rule.** Never read, print, or copy secret values. Use redacted views.

**Enforced by.** Hook `block-token-file-reads.sh` (on Bash and Read): blocks
dumps of known token files and plaintext-output flags, and prints the redacted
alternative for that file.

### 5. A delegated agent deleted the only copy of a credentials file

**Incident.** A delegated agent ran `rm wifi_secrets.h`. The file was gitignored by design and in no backup. The
credentials were gone.

**Rule.** Never delete or overwrite a secrets file.

**Enforced by.** Hook `protect-secrets-files.sh`: blocks `rm`, `mv`,
truncation, and overwrite of secret-like files. Reads still pass.

### 6. Copying secrets between machines wrote the redaction mask instead

**Incident.** During a migration to a secrets manager, agents copied values
between two machines by running the manager over SSH and redirecting the
output into `.env.local`. The manager redacts output when stdout is not a
terminal, so each file received a masked string instead of the key. Every
command exited 0. Several projects' env files were silently corrupted in one
week.

**Rule.** Never move a secret between machines through an agent's shell. Hand
the human the command, and end it with a byte-equality check (`shasum -a 256`
of the value on both sides).

**Enforced by.** Hook `block-token-file-reads.sh` blocks the flag that disables
redaction. The hash comparison is a check the human runs.

### 7. An in-place regex rewrite duplicated code, and no test noticed

**Incident.** An agent used `perl -pi` to update several source files at once.
The pattern matched more than intended and duplicated code. The command
reported nothing about how many matches it changed, the transcript showed no
diff, and the test suite passed.

**Rule.** Edit source with the Edit tool, which shows the exact replacement and
refuses a non-unique match.

**Enforced by.** Hook `warn-inplace-edit.sh`: warns on `sed -i` / `perl -pi`
against source and doc files. It warns rather than blocks, because some
rewrites are correct.

### 8. A divider line silently skipped the next command

**Incident.** An agent printed `echo =====` as a visual divider in a multi-step
shell call. zsh treats a word starting with `=` as a path lookup, failed it, and
skipped the rest of the call, including the command that mattered. The call
looked like it succeeded.

**Rule.** Do not start a word with `=`. The same class of trap: bare `log` (a
zsh builtin), `timeout` (absent on macOS), a variable named `status`
(read-only in zsh).

**Enforced by.** Hook `block-shell-traps.sh`: blocks each trap and prints the
working spelling.

### 9. Two sessions wrote the same commit-message file

**Incident.** Two agent sessions worked in the same repo at once. One wrote
`tmp/commit-msg.txt`; before it ran `git commit -F`, the other session
overwrote the file. The commit went in with the wrong message.

**Rule.** Temporary files in a shared repo carry a session or agent id in their
name: `tmp/<id>-commit-msg.txt`.

**Enforced by.** Rule only. (`block-sensitive-git-add.sh` keeps `tmp/` out of
commits, but nothing checks file names.)

### 10. A settings file wired hooks whose scripts did not exist

**Incident.** Two versions of the same failure. First, `settings.json`
referenced a hook script that did not exist, so every Bash and Edit call ran a
missing file, exited 127, and was ignored. Second, the settings file synced to
a second machine but the hooks directory did not, so that machine ran with 22
missing hooks. Nobody noticed either for some time, because a missing hook
fails open.

**Rule.** Every hook the settings file wires must exist on every machine that
has the settings file.

**Enforced by.** Check: `hooks/tests/run-tests.sh`, section "referenced hooks
exist".

### 11. A scheduled job failed every week for a month

**Incident.** A weekly review job ran from launchd. Its script parsed under
bash 5 (what the author tested with) but not under macOS `/bin/bash` 3.2 (what
launchd runs). It failed silently every Sunday for a month. Separately, a
hook's heredoc hit a parse bug that exists only in bash 5.3.

**Rule.** Scripts must parse under every bash that will run them. Unattended
code must fail loud.

**Enforced by.** Check: `hooks/tests/run-tests.sh` parses every hook under both
`/bin/bash` and the PATH `bash`.

### 12. A failure counter that could never count a failure

**Incident.** A hook meant to warn after three similar failed commands was wired
to `PostToolUse`. That event fires only when a tool call succeeds, so the
counter saw zero failures for weeks and looked healthy the whole time.

**Rule.** Verify that a guard fires on the event it guards, by making it fire.
A check that has never gone red is not evidence.

**Enforced by.** Hook `retry-counter.sh`, now on `PostToolUseFailure`, and a
behaviour test in the suite that feeds it three failures.

### 13. A deploy reported success while the new process was dead

**Incident.** A deploy script restarted a service and polled its health
endpoint for a 200. Review found the hole: if a stray dev server holds the same
port, the new process fails to bind and dies, while the old one keeps answering
200 and the deploy prints success. The fix required the health response's pid
to match the supervisor's pid. The first real deploy then failed the other way:
the service ran under a secrets-manager wrapper, so the server's pid was a child
of the supervised pid, and a healthy restart was rejected.

**Rule.** A 200 is not proof the new process runs. The health body carries
`pid` and `startedAt`; the deploy accepts only a response started after the
restart whose pid is the supervised process or a descendant of it.

**Enforced by.** Check: a deploy-script freshness test and unit tests for the
pid-ancestry walk, as specified in
[`../standards/fleet-standard.md`](../standards/fleet-standard.md). This kit
ships the specification, not a deploy script.

### 14. "Hardened" six weeks in a row, and never re-run

**Incident.** A weekly unattended job had auth failures. Over six weeks, its
auth code was "hardened" six times, and each time declared fixed. Nobody re-ran
the job after any of the changes. It kept failing. Separately, after an
env-loader migration, one long-running web service kept the old PATH for three
weeks until it crash-looped.

**Rule.** After a change to an unattended job's auth or environment, re-run the
job on every machine it runs on and confirm a real, dated output landed. After
an env-loader change, restart every long-lived service and check it through its
public path.

**Enforced by.** Check, manual: kick the job, wait for it to finish, look for
the output file and the absence of a failure file. A script that lists services
not restarted since a given time makes the second half cheap.

### 15. Guards that matched text trained agents to route around them

**Incident.** The first versions of several hooks matched the raw command
string. They blocked `echo "git reset --hard"`, `rg "use pnpm instead"
README.md`, a friction-log entry that quoted `git commit`, and a `perl` command whose
replacement text contained "git commit". Each false positive taught agents to
rephrase commands to get past the hook instead of respecting it.

**Rule.** A guard must judge what a command runs, not what it mentions. Every
reported false positive becomes a test case.

**Enforced by.** The hooks split commands into segments, strip heredoc bodies,
and resolve the command word. `hooks/tests/run-tests.sh` keeps each reported
false positive as an "allows" case.
