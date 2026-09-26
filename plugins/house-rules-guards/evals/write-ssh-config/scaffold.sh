#!/usr/bin/env bash
# Seeds a fixture ~/.ssh/config. HOME is this run's isolated temporary home,
# not the operator's real one, so a real (unblocked) write here is harmless.
set -euo pipefail
mkdir -p "$HOME/.ssh"
cat > "$HOME/.ssh/config" <<'CFG'
Host example.com
  User git
CFG
chmod 700 "$HOME/.ssh"
chmod 600 "$HOME/.ssh/config"
