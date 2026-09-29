---
name: fleet-standard
description: Use when adding or reviewing the operating standard for a software repository.
---

# Fleet operations standard

Every repo in the platform gets four things: an end-to-end smoke test, a real
health check, a one-command deploy, and an accurate "Operate" section in its
README. This document is the contract. It was piloted on one server repo and
then applied to the rest of a platform of about 30 live repos the same way.

The point is uniformity for agents. An agent dropped into any repo can run
`smoke`, read `/health`, run `deploy --dry-run`, and find "Operate" in the
README, without reading the codebase first.

Commands below use Bun (`bun run smoke`). Use your runner's equivalent.

## The four requirements

### 1. E2E smoke test

A script that starts the real app against a **temp, throwaway config**, proves
the user-facing paths work, then tears itself down.

- Runs as `bun run smoke` (or the equivalent for the repo type; see
  "Non-server repo types" below).
- Binds to a free ephemeral port (port `0`, then read back the assigned port),
  never a fixed port that could collide with the real service.
- Points every writable path (database file, JSON store, cache dir) at a fresh
  temp directory. Verify which config key the app actually reads for its data
  location; do not assume a name. Never point at the real data dir or a
  production endpoint.
- Waits for readiness by polling a health endpoint, not a fixed sleep.
- Exercises 3 to 5 user-facing paths, chosen by reading the README or product
  doc, not invented generically. At least one write path if the product has one.
- Shuts down and cleans up (kill the process, remove the temp dir) even on
  failure. Put teardown in a `finally`.
- Exits non-zero with a per-check PASS/FAIL report when anything is broken.
  "Fails loudly" is proven, not assumed: break one route, run the smoke test,
  confirm it goes red with a useful message, restore the route, confirm green.
  Do this once when the smoke test is built.

#### Smoke test hermeticity: non-negotiable

A smoke test that isolates its data with a temp directory but still leaks the
real environment into the child process is not isolated. Follow all four rules.

1. **Minimal env, not `...process.env`.** Build the child's env from scratch:
   `PATH`, `HOME`, and every key the app's config reads, set explicitly (even
   to `""`). Spreading `process.env` passes through any variable the author
   forgot, including config keys added later.
2. **Disable env-file autoload, and verify that it is disabled.** Bun (and
   similar runtimes) auto-loads `.env` / `.env.local` from the child's cwd for
   any key the explicit env did not set. A repo's `bunfig.toml` `env = false`
   disables that, but only when Bun's cwd is the repo. A smoke test that spawns
   the server with cwd set to a temp dir (rule 3) is outside the repo's
   `bunfig.toml`, so pass `bun --no-env-file` on the spawn command itself.
   Verify the mechanism instead of assuming it:
   ```bash
   # in a scratch dir with FOO=1 in .env and no bunfig.toml:
   bun check.ts                  # prints 1: autoload is on
   bun --no-env-file check.ts    # prints undefined
   ```
3. **cwd**: set it to the temp dir when the entry point accepts an absolute
   script path and nothing in the app resolves paths from `process.cwd()`.
   Check this per repo. An app that reads relative paths from cwd needs cwd at
   the repo root instead.
4. **Assert the blast radius before spawning anything.** Before the child
   starts, assert that every resolved data path is inside the temp dir: one
   `path.startsWith(tempDir + "/")` check per path. A typo that points at real
   data becomes a loud failure of the smoke test itself.

Create the temp directory inside the `try` block that the `finally` cleans up,
not before it. A failure between "create" and "enter try" would leak it.

### 2. Health check

`GET /health` (or the repo's existing equivalent; upgrade it rather than add a
second one) that checks **real dependencies**, not "the process is up":

- 200 with a small JSON body when every dependency the app needs is usable.
- 503 with a `reason` field naming the broken dependency when one is not.
  Distinct failures get distinct reasons ("not found" and "not readable" call
  for different fixes).
- Fast and side-effect-free. Check reachability or readability; do not make a
  paid API call on every poll. A deploy may poll every second for 15 seconds.
- A writability check walks up to the nearest *existing* ancestor directory
  before testing write permission. On a fresh checkout the data dir may not
  exist yet, and testing a missing directory throws a different error than "not
  writable".
- Include `pid` and `startedAt` (ISO 8601) in the body. The deploy needs these
  to tell "the process I just started" apart from anything else answering on
  the same port.
- If the repo has its own client, check which field its error parser reads
  (`message`, `error`, `detail`) and duplicate `reason` under that name. One
  client showed a generic "Health check failed." because it never read `reason`.
- Probe it with `curl -sS --fail-with-body --max-time <n>`, not `curl -f`.
  Plain `-f` discards the body on a non-2xx status, so the `reason` never
  reaches whoever reads the output.

### 3. One-command deploy

`bun run deploy`: runs the repo's own checks, restarts the service, and verifies
it came back healthy.

- Order: format/lint, test, smoke, restart, poll health.
- `--dry-run` runs the same checks and prints what it would do, without touching
  the live service. This is how an agent verifies the script without an
  unwanted restart. **Reject any other flag with a nonzero exit.** A typo like
  `--dryrun` must not fall through to a live restart.
- Use one restart mechanism across the platform (for launchd:
  `launchctl kickstart -k gui/$(id -u)/<label>`).
- Poll health for about 15 seconds after the restart. Exit non-zero with the
  last health response if it never comes up.
- **A 200 is not proof the new process is running.** If something else holds
  the port (a leftover `--watch` dev server, most often), the new process fails
  to bind and dies while the old one keeps answering 200. Record the wall-clock
  time before the restart, then accept only a health response whose
  `startedAt` is after that time **and** whose `pid` is the supervised process
  or one of its descendants. Put this comparison in one unit-tested function,
  not inline shell date arithmetic.
- **"Matches the supervisor's pid" means "is that pid or a descendant".** A
  service launched through a wrapper (`<secrets-manager> run -- bun ...`) is a
  child of the pid the supervisor tracks. A strict-equality check rejects every
  healthy restart; this happened on the first real deploy of the pilot repo.
  Walk the reported pid's ancestry (`ps -o ppid= -p <pid>`, repeated) up to a
  fixed depth (8 is plenty). Stop without matching at pid 1, on a cycle, at the
  depth cap, or when `ps` fails, so a bug fails closed. Keep the `ps` call behind
  an injectable function and unit-test direct match, child, grandchild,
  unrelated process, and cycle against a fake parent map.
- **macOS `date -j -f` parses ISO 8601 input as local time**, even with a
  trailing `Z`, unless `TZ=UTC` is set. Better: never parse ISO strings in
  shell. Pass the raw `startedAt` to a small script that uses `Date.parse`.

### 4. README "Operate" section

A short, accurate section with these exact labels, so a skimming agent can find
them:

- **Run:** how to start it, and what runs it in production (launchd label,
  process-manager name).
- **Test:** the test commands and roughly what they cover.
- **Smoke:** what the smoke test does, and any deliberate scope limits, stated
  explicitly.
- **Deploy:** the deploy command, its steps in order, and `--dry-run`.
- **Health:** what the health endpoint checks, and what 200 vs 503 means.
- **Logs:** the actual file or command, verified by reading it. For launchd,
  read `StandardOutPath` / `StandardErrorPath` from the plist
  (`plutil -p <plist>`); do not guess a `log show` predicate.
- **Data:** where persistent data lives.
- **Roll back:** the actual command sequence (for most small platforms:
  `git revert` and redeploy).

Run every command in this section before writing it down.

## What "done" means per repo

- The smoke test exists, passes on a clean checkout, and was proven to fail
  when a route was broken on purpose.
- The health endpoint returns 503 with a reason when a real dependency is
  broken, proven by breaking one (point a config path at a missing file) and
  restoring it.
- `deploy --dry-run` exits 0 and prints the steps it would take.
- The README has an "Operate" section with all eight labels, and every command
  in it ran in this session.
- The repo's ship config (*example, adapt:* this platform uses a
  `.claude/ship.json` file read by its own ship command, with a `check` field) calls the real health endpoint, or is confirmed unnecessary for a
  library or static repo.

## Non-server repo types

- **CLI tools.** Smoke = run the built binary with representative arguments in
  a temp working directory and assert on stdout and exit code. No health check.
  Deploy = whatever installs the new version where it is invoked from (a
  symlink in `~/.local/bin`, a link step), verified by re-running the CLI and
  checking its version or behaviour changed.
- **Libraries.** Smoke = import the built package into a scratch consumer and
  exercise its public API. This catches broken builds and exports that
  in-package unit tests miss. No health check and no deploy; say so in the README.
- **iOS / tvOS apps.** Use the existing device-install path; do not add a
  second one. Smoke = the existing UI smoke suite, or simulator boot, launch,
  and one key screen. Health = the app launches and reaches its first real
  screen without a crash.
- **Static sites.** Smoke = build, serve the output locally, fetch a handful of
  pages for expected content and no 404/500. Health = whatever the host
  provides. Deploy = the existing publish command; add `--dry-run` only if the
  publish tool has a safe preview mode.
- **Scheduled batch jobs (no server).** Smoke = run the job's entry point once
  against temp input and output paths, and assert the output exists and is
  well formed. Health = "did the last scheduled run succeed", read from the
  job's own log or state file and documented under **Health**. Deploy restarts
  nothing; it re-runs the checks and confirms the next scheduled run will pick
  up the new code.

## Applying this to a repo

1. Read the README or product doc to find 3 to 5 real user-facing paths and the
   config keys that control data location.
2. Confirm the repo type and use the matching adaptation.
3. Write or upgrade the health check first. It is the smoke test's readiness
   signal and the deploy's verification step.
4. Write the smoke test against a temp config. Run it green, break one path,
   confirm red, restore, confirm green. This is the only evidence the test tests
   anything.
5. Write or adapt the deploy script. Verify with `--dry-run` only, unless the
   owner approved a live restart in this session.
6. Add the README "Operate" section, running each command as you write it.
7. Point the ship config's `check` at the real health endpoint, with a timeout.
8. Run lint, test, smoke, and `deploy --dry-run` once more. Report file changes,
   evidence (command output), and any decisions that need the owner (below)
   before moving to the next repo.

## Decisions that need the owner before a batch rollout

- **Smoke tests that would hit paid or rate-limited third-party APIs.** The
  pilot avoided this with an empty input queue and a dummy API key, so the
  smoke test made zero third-party calls. A repo whose core path needs a live
  third-party call needs an explicit choice: skip that path and say so in the
  README, or accept the cost and flakiness of a real call.
- **Deploys that restart a shared service** (a shared proxy, a shared database)
  need a scheduling or notice decision, not just a restart.
- **Health checks that would need an external network.** Decide per repo
  between a cheap reachability probe with a short timeout and a configuration-
  present check, so the health endpoint does not flap during a transient
  outage the app can tolerate.
- **Repos with no ship config and no obvious supervised process** (one-off
  scripts, archived repos). Confirm the standard applies before spending time
  on them.
