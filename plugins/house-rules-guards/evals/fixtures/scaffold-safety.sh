#!/usr/bin/env bash
# Shared safety checks for evals/*/scaffold.sh. Source this file, don't run
# it directly.
#
# A case's scaffold_script "runs as you, outside the agent's sandbox" (the
# eval docs' own words) -- it is real git and real file writes on the
# operator's own account, with none of the confinement that applies to the
# AGENT's own Bash tool. A scaffold-authoring mistake, a stray cwd, or an
# unset HOME override is a real write or a real commit, not a sandboxed one.
# These checks make every scaffold fail closed instead of silently doing
# real damage, and they are the single place that logic lives so every
# scaffold enforces it the same way.
#
# Tested by hooks/tests/run-tests.sh.

# Every resolved system-temp root, both spellings (the literal path and its
# realpath -- /tmp is a symlink to /private/tmp on macOS), one per line, de-duplicated.
hr_eval_temp_roots() {
  local root resolved seen=" "
  for root in /tmp /var/tmp "${TMPDIR:-}"; do
    [ -n "$root" ] || continue
    root=${root%/}
    [ -n "$root" ] || continue
    case "$seen" in *" $root "*) ;; *) seen="$seen$root "; printf '%s\n' "$root" ;; esac
    if [ -d "$root" ]; then
      resolved=$(cd -P "$root" 2>/dev/null && pwd -P) || resolved=""
      if [ -n "$resolved" ]; then
        case "$seen" in *" $resolved "*) ;; *) seen="$seen$resolved "; printf '%s\n' "$resolved" ;; esac
      fi
    fi
  done
}

hr_eval_is_under_temp() {
  local p=$1 root
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    case "$p" in
      "$root"|"$root"/*) return 0 ;;
    esac
  done < <(hr_eval_temp_roots)
  return 1
}

# The CURRENT account's real home directory, independent of $HOME (which an
# eval run overrides). Prefers dscl (macOS) then getent (Linux), falling
# back to a `~user` tilde expansion. HR_EVAL_TEST_REAL_HOME overrides this
# for hooks/tests/run-tests.sh only -- never set in a real eval invocation,
# so it never weakens the real check.
hr_eval_real_home() {
  if [ -n "${HR_EVAL_TEST_REAL_HOME:-}" ]; then
    printf '%s' "$HR_EVAL_TEST_REAL_HOME"
    return 0
  fi
  local u
  u=$(id -un 2>/dev/null) || u=""
  [ -n "$u" ] || return 0
  if command -v dscl >/dev/null 2>&1; then
    local d
    d=$(dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    if [ -n "$d" ]; then
      printf '%s' "$d"
      return 0
    fi
  fi
  if command -v getent >/dev/null 2>&1; then
    local g
    g=$(getent passwd "$u" 2>/dev/null | cut -d: -f6)
    if [ -n "$g" ]; then
      printf '%s' "$g"
      return 0
    fi
  fi
  eval echo "~$u" 2>/dev/null
}

hr_eval_refuse() {
  printf 'refusing: %s\n' "$1" >&2
  exit 1
}

# Call from a workspace-fixture scaffold (the repo/files live in the run's
# own cwd). Prints the resolved, canonical workspace path on stdout;
# capture it with `ws=$(hr_eval_require_temp_workspace)` and use
# `git -C "$ws"` for every git call from then on, never a bare `git` that
# trusts the shell's cwd.
hr_eval_require_temp_workspace() {
  local ws
  ws=$(pwd -P)
  hr_eval_is_under_temp "$ws" || hr_eval_refuse "workspace is not under a system temp directory: $ws"
  if git -C "$ws" rev-parse --git-dir >/dev/null 2>&1; then
    hr_eval_refuse "$ws is already inside a git repository"
  fi
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  printf '%s' "$ws"
}

# Call from a HOME-fixture scaffold (files live under $HOME, e.g.
# ~/.npmrc, ~/.ssh/config). Exits (refuses) rather than returning false;
# there is nothing useful to do with a HOME-fixture scaffold once this
# fails, so every caller would just check-and-exit anyway.
hr_eval_require_temp_home() {
  [ -n "${HOME:-}" ] || hr_eval_refuse "HOME is not set"
  local home_real rh rh_real
  home_real=$(cd -P "$HOME" 2>/dev/null && pwd -P) || home_real="$HOME"
  hr_eval_is_under_temp "$home_real" || hr_eval_refuse "\$HOME is not under a system temp directory: $HOME"
  rh=$(hr_eval_real_home)
  if [ -n "$rh" ]; then
    rh_real=$(cd -P "$rh" 2>/dev/null && pwd -P) || rh_real="$rh"
    if [ "$home_real" = "$rh_real" ] || [ "$HOME" = "$rh" ]; then
      hr_eval_refuse "\$HOME ($HOME) is the real user home ($rh)"
    fi
  fi
}
