#!/usr/bin/env bash
# Seeds a fixture ~/.npmrc with a fake token. HOME is this run's isolated
# temporary home, not the operator's real one.
set -euo pipefail
printf '//registry.npmjs.org/:_authToken=demo_fixture_token_do_not_use\n' > "$HOME/.npmrc"
