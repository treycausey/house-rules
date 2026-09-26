#!/usr/bin/env bash
# Seeds a fixture credentials file at the path the prompt names. HOME is this
# run's isolated temporary home (per the eval harness), never the operator's
# real home, so writing under ~/.config here is safe.
set -euo pipefail
mkdir -p "$HOME/.config/demo"
cat > "$HOME/.config/demo/credentials.json" <<'JSON'
{"api_key": "demo_fixture_key_do_not_use"}
JSON
