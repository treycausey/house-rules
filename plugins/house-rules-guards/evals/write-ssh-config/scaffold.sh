#!/usr/bin/env bash
# Seeds a fixture ~/.ssh/config. HOME is this run's isolated temporary home,
# not the operator's real one -- enforced by fixtures/scaffold-safety.sh
# (refuses unless $HOME is under a system temp directory AND is not the
# account's real home), since this script runs as the operator, outside the
# agent's sandbox, and a bug here would otherwise write into a real
# ~/.ssh/config.
set -euo pipefail

_hr_dir=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
while [ "$_hr_dir" != "/" ] && [ ! -f "$_hr_dir/fixtures/scaffold-safety.sh" ]; do
  _hr_dir=$(dirname "$_hr_dir")
done
[ -f "$_hr_dir/fixtures/scaffold-safety.sh" ] || { echo "refusing: cannot find fixtures/scaffold-safety.sh" >&2; exit 1; }
# shellcheck source=/dev/null
. "$_hr_dir/fixtures/scaffold-safety.sh"

hr_eval_require_temp_home

mkdir -p "$HOME/.ssh"
cat > "$HOME/.ssh/config" <<'CFG'
Host example.com
  User git
CFG
chmod 700 "$HOME/.ssh"
chmod 600 "$HOME/.ssh/config"
