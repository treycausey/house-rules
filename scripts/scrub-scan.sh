#!/bin/bash
# Secret and personal-data scan of this repo's tree. Run before every publish.
#
#   bash scripts/scrub-scan.sh
# SCRUB_PRIVATE_PATTERNS can name a private pattern file. By default, the
# scanner reads ~/.config/agent-platform-kit/private-patterns.txt when present.
#
# SCRUB_PRIVATE_PATTERNS names a file OUTSIDE the repo with one extended regex
# per line: your host names, tailnet id, username, project and device names.
# That list is itself private data, which is why it is not in the repo.
#
# Every section prints its hits, or "(none)". Keep private machine, host,
# repository, and person details out of the tracked files.
set -u -o pipefail
cd "$(dirname "$0")/.." || exit 1
g() { /usr/bin/grep -rnIE --exclude=.git --exclude-dir=node_modules --exclude-dir=.git "$@" . ; }

PRIVATE_PATTERNS=${SCRUB_PRIVATE_PATTERNS:-}
if [ -z "$PRIVATE_PATTERNS" ] && [ -f "${HOME:-}/.config/agent-platform-kit/private-patterns.txt" ]; then
  PRIVATE_PATTERNS="${HOME}/.config/agent-platform-kit/private-patterns.txt"
fi

echo "## 1. email addresses"
g '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' || echo "(none)"

echo "## 2. tailnet hostnames"
g -i 'ts\.ne[t]' | cut -c1-170 || echo "(none)"

echo "## 3. IPv4 addresses (distinct values)"
addresses=$(/usr/bin/grep -rohIE --exclude=.git --exclude-dir=node_modules --exclude-dir=.git '([0-9]{1,3}\.){3}[0-9]{1,3}' . | sort | uniq -c | awk '$2 !~ /^(0\.0\.0\.0|127\.0\.0\.1|192\.0\.2\.[0-9][0-9]*|198\.51\.100\.[0-9][0-9]*|203\.0\.113\.[0-9][0-9]*)$/')
[ -n "$addresses" ] && printf '%s\n' "$addresses" || echo "(none: standard example addresses)"

echo "## 4. home-directory paths"
g '/[Uu]sers/[A-Za-z]|/home/[A-Za-z]' | cut -c1-170 || echo "(none)"

echo "## 5. key and token shapes"
g 'sk-ant-[A-Za-z0-9]|ghp_[A-Za-z0-9]{10}|gho_[A-Za-z0-9]{10}|github_pat_[A-Za-z0-9]|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9]|BEGIN [A-Z ]*PRIVATE KEY|AIza[0-9A-Za-z_-]{30}' || echo "(none)"
g -i '(api[_-]?key|token|secret|password)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"' ]{12,}' | cut -c1-170 || echo "(none: assigned secret literals)"

echo "## 6. env and credential files in the tree"
find . -path ./.git -prune -o -path '*/node_modules' -prune -o \( -name '.env' -o -name '.env.*' -o -name '*.pem' -o -name 'id_rsa*' -o -name 'id_ed25519*' -o -name '*.key' -o -name 'hosts.yml' -o -name '.netrc' \) -print | /usr/bin/grep . || echo "(none)"

echo "## 7. private patterns"
if [ -n "$PRIVATE_PATTERNS" ]; then
  [ -f "$PRIVATE_PATTERNS" ] || { echo "SCRUB_PRIVATE_PATTERNS file not found" >&2; exit 1; }
  echo "($(/usr/bin/grep -cvE '^[[:space:]]*(#|$)' "$PRIVATE_PATTERNS") patterns)"
  g -i -f <(/usr/bin/grep -vE '^[[:space:]]*(#|$)' "$PRIVATE_PATTERNS") | cut -c1-170 || echo "(none)"
else
  echo "(skipped: set SCRUB_PRIVATE_PATTERNS)"
fi
