#!/bin/bash
# Secret and personal-data scan of this repo's tree. Run before every publish.
#
#   bash scripts/scrub-scan.sh
#   SCRUB_PRIVATE_PATTERNS=~/private/scrub-patterns.txt bash scripts/scrub-scan.sh
#
# SCRUB_PRIVATE_PATTERNS names a file OUTSIDE the repo with one extended regex
# per line: your host names, tailnet id, username, project and device names.
# That list is itself private data, which is why it is not in the repo.
#
# Every section prints its hits, or "(none)". Expected hits in this repo:
# the generic .ts.net domain in a hook comment and a test placeholder,
# loopback/bind-all/documentation IPs, the author's name in LICENSE and README,
# and a placeholder home path in a test. Patterns use a [x] character class
# where needed so this script never matches itself.
set -u -o pipefail
cd "$(dirname "$0")/.." || exit 1
g() { /usr/bin/grep -rnIE --exclude-dir=node_modules --exclude-dir=.git "$@" . ; }

echo "## 1. email addresses"
g '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' || echo "(none)"

echo "## 2. tailnet names (*.ts.net)"
g -i 'ts\.ne[t]' | cut -c1-170 || echo "(none)"

echo "## 3. IPv4 addresses (distinct values)"
/usr/bin/grep -rohIE --exclude-dir=node_modules --exclude-dir=.git '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' . | sort | uniq -c || echo "(none)"

echo "## 4. the author's first name (expected: author lines only)"
g -i 'tre[y]' | cut -c1-170 || echo "(none)"

echo "## 5. home-directory paths"
g '/Users/[A-Za-z]|/home/[A-Za-z]' | cut -c1-170 || echo "(none)"

echo "## 6. key and token shapes"
g 'sk-ant-[A-Za-z0-9]|ghp_[A-Za-z0-9]{10}|gho_[A-Za-z0-9]{10}|github_pat_[A-Za-z0-9]|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9]|BEGIN [A-Z ]*PRIVATE KEY|AIza[0-9A-Za-z_-]{30}' || echo "(none)"
g -i '(api[_-]?key|token|secret|password)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"' ]{12,}' | cut -c1-170 || echo "(none: assigned secret literals)"

echo "## 7. env and credential files in the tree"
find . -path ./.git -prune -o -path '*/node_modules' -prune -o \( -name '.env' -o -name '.env.*' -o -name '*.pem' -o -name 'id_rsa*' -o -name 'id_ed25519*' -o -name '*.key' -o -name 'hosts.yml' -o -name '.netrc' \) -print | /usr/bin/grep . || echo "(none)"

echo "## 8. private patterns"
if [ -n "${SCRUB_PRIVATE_PATTERNS:-}" ]; then
  [ -f "$SCRUB_PRIVATE_PATTERNS" ] || { echo "SCRUB_PRIVATE_PATTERNS file not found: $SCRUB_PRIVATE_PATTERNS" >&2; exit 1; }
  echo "($(/usr/bin/grep -cvE '^[[:space:]]*(#|$)' "$SCRUB_PRIVATE_PATTERNS") patterns)"
  g -i -f <(/usr/bin/grep -vE '^[[:space:]]*(#|$)' "$SCRUB_PRIVATE_PATTERNS") | cut -c1-170 || echo "(none)"
else
  echo "(skipped: set SCRUB_PRIVATE_PATTERNS)"
fi
