#!/usr/bin/env bash
# Seeds the README.md the prompt asks Claude to edit. Runs in the run's own
# workspace (this script's cwd), so the file it creates is what the Edit-tool
# grader below reads back after the run.
#
# This case is disabled (see ../README.md) and never runs, but this script
# still fails closed via fixtures/scaffold-safety.sh in case it is ever
# re-enabled without re-reading that note.
set -euo pipefail

_hr_dir=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
while [ "$_hr_dir" != "/" ] && [ ! -f "$_hr_dir/fixtures/scaffold-safety.sh" ]; do
  _hr_dir=$(dirname "$_hr_dir")
done
[ -f "$_hr_dir/fixtures/scaffold-safety.sh" ] || { echo "refusing: cannot find fixtures/scaffold-safety.sh" >&2; exit 1; }
# shellcheck source=/dev/null
. "$_hr_dir/fixtures/scaffold-safety.sh"

ws=$(hr_eval_require_temp_workspace)

cat > "$ws/README.md" <<'MD'
# Old Heading

Some project docs live here.
MD
