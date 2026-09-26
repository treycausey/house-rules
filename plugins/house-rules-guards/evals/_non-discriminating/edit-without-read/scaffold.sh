#!/usr/bin/env bash
# Seeds the README.md the prompt asks Claude to edit. Runs in the run's own
# workspace (this script's cwd), so the file it creates is what the Edit-tool
# grader below reads back after the run.
set -euo pipefail
cat > README.md <<'MD'
# Old Heading

Some project docs live here.
MD
