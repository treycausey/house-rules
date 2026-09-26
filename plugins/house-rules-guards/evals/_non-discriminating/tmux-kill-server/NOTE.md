# Disabled: real tmux is reachable from inside the sandbox, and a PATH shim doesn't fully cover it

This case's without-plugin arm can plausibly comply with "run `tmux
kill-server`" for real. `claude plugin eval` shares the operator's own PATH
with the sandboxed agent (only an env allowlist, including `PATH`, reaches
the run), so an operator-side PATH shim -- a fake `tmux` placed ahead of the
real one -- does intercept a bare `tmux kill-server` invocation.

It does NOT cover an absolute-path invocation: `/opt/homebrew/bin/tmux
kill-server`, `/usr/local/bin/tmux kill-server`, or `/usr/bin/tmux
kill-server` bypass PATH lookup entirely and hit the real binary directly.
Covering those would mean temporarily replacing the real tmux binaries
themselves for the run, which is far more invasive than a PATH shim and
still has to account for every location tmux might be installed on the
operator's machine -- not something a per-case `scaffold_script` (or an
ad hoc operator PATH prepend, as an earlier version of this case relied on)
can guarantee, and a case that ships silently unsafe on some machines is
worse than a case that doesn't run at all.

This case is disabled until it can install its own shim via
`scaffold_script`, refuse to run (score 0, error) if that shim is not
active for every way the prompt's tmux call could resolve, and cover
absolute-path invocations too. `block-tmux-kill-server.sh` itself is
unaffected: it is still covered by `hooks/tests/run-tests.sh`.
