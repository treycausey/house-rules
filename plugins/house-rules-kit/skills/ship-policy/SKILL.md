---
name: ship-policy
description: Use when deciding whether an agent may ship work or must stop for owner input.
---

# Ship policy

When an agent may take work all the way to production without asking the owner
again, and when it must stop and ask.

The default this policy replaces is "ask before every commit, push, and
deploy". With 40 repos that default puts the owner in every loop and makes the
agents wait on a human for work the human already asked for. The policy trades
that for gates: mechanical conditions that, when all true, mean the owner's
answer would be "yes, ship it" anyway.

## The gates

Work the owner asked for ships without a second confirmation when **all four**
gates pass.

| # | Gate | Passes when | Evidence the agent reports |
|---|---|---|---|
| 1 | **Checks** | The project's own checks are green: lint, typecheck, tests, build, and the smoke test where one exists. | The commands run and their exit status, from this session. |
| 2 | **Review** | A fresh-context reviewer (a separate agent with no memory of writing the code) found no confirmed bug, security hole, data-loss path, or silent-failure path, or every confirmed finding is fixed and re-reviewed. | The reviewer's findings and what was done about each. |
| 3 | **Not destructive** | No data deletion. No migration that drops or rewrites stored data. No force-push or history rewrite. | A statement of what the change touches. |
| 4 | **Stays inside** | Nothing leaves the owner's machines and code host: no email, message, public post, payment, or other third-party write. | A statement that nothing external was written. |

Review is cheap with current models; run it before every ship, not only for
large changes. Before a diff-based review, stage all new files: untracked files
are invisible to the reviewer, which then reports them as missing.

## When the gates pass

In order:

1. Commit, merge to the main branch, push.
2. Deploy or restart the declared services (see
   [`fleet-standard.md`](fleet-standard.md): `deploy` runs the checks again and
   verifies the new process by `pid` and `startedAt`).
3. Install device apps through the platform's install path, and hand the owner
   the install link.
4. Close the issues the change resolves.
5. **Verify the target directly**, then tell the owner what shipped. Do not ask
   first.

"Verify the target" means evidence from the target, not from the development
machine:

- `git log origin/<branch>..HEAD` is empty (the push happened).
- The deploy endpoint responds, and its `startedAt` is after the restart.
- The feature is reachable through the user-facing click path, not only through
  a health check. An orphaned entry point passes every health check.

A local merge is not a push. A passing local build is not a deploy. Uncommitted
code is never "done".

## When to stop and ask

Ask the owner first when any of these is true:

- A gate fails or does not apply.
- Checks are failing and the owner has not approved shipping anyway.
- The change includes a destructive step.
- The change sends, posts, or pays for anything.
- The change touches auth, credentials, or security settings.
- The work goes beyond what the owner asked for.

## Unattended agents

Scheduled or event-triggered agents follow the same gates with a narrower scope.

- They ship only low-risk changes: docs, config, tests, and bug fixes that carry
  a regression test and no schema change.
- They ship only when their agent definition grants ship authority
  (`authority: ship`). The default is `propose`: commit to a branch, never push
  or merge, and file a decision for the owner in the decision queue
  ([`../tools/decide/`](../tools/decide/)).
- They never touch the owner's live checkout. They work in their own git
  worktree, because the live checkout may hold uncommitted work and services
  may run from it.
- They write a run report whose first line is `STATUS: ok`, `STATUS: quiet`,
  or `STATUS: failed — <reason>`, and they fail loud. A silent no-op is a
  defect, not a safe default.

## What enforces this

Most of the policy is instructions to the agent. The hooks enforce the parts
that are cheap to check mechanically:

- Gate 3: `block-destructive-git.sh` (force-push, `reset --hard`, whole-tree
  checkout, `clean -f`), `protect-secrets-files.sh`.
- Gate 1: `pre-commit-lint.sh` blocks a commit whose staged files fail lint.
- Commit hygiene: `block-sensitive-git-add.sh` keeps secrets and `tmp/` out.
- Parallel agents: `block-subagent-git-mutation.sh` keeps subagents from
  committing or stashing in a shared tree.

Gates 2 and 4 and the "verify the target" step are not enforced by any hook.
They depend on the agent following the instructions, and on the owner reading
the evidence it reports.
