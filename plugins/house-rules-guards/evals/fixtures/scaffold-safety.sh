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

# GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE / GIT_OBJECT_DIRECTORY /
# GIT_COMMON_DIR / GIT_ALTERNATE_OBJECT_DIRECTORIES can each redirect where
# git actually reads or writes, independent of `-C <dir>` or cwd -- if this
# scaffold process inherited any of them from its caller, "git -C $ws ..."
# would operate on, or write into, a repository outside $ws entirely.
# GIT_CEILING_DIRECTORIES only limits upward repo discovery, not a write
# target, so it is left alone.
#
# This unset MUST run at file scope, from a plain `. fixtures/scaffold-safety.sh`
# in the scaffold script's own shell. A previous version put it inside a
# function whose result the caller captured with `ws=$(that_function)` --
# command substitution forks a subshell, so the unset landed in that
# subshell and vanished the instant it exited, leaving every GIT_* variable
# untouched in the scaffold's real environment. A reviewer reproduced this
# by rewriting a repo's index through an inherited GIT_INDEX_FILE and
# creating a repo outside the workspace through an inherited GIT_DIR.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_ALTERNATE_OBJECT_DIRECTORIES
for _hr_git_var in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_ALTERNATE_OBJECT_DIRECTORIES; do
  if eval "[ -n \"\${$_hr_git_var:-}\" ]"; then
    printf 'refusing: %s is still set after unset (readonly in this shell?)\n' "$_hr_git_var" >&2
    exit 1
  fi
done
unset _hr_git_var

# Every resolved system-temp root, both spellings (the literal path and its
# realpath -- /tmp is a symlink to /private/tmp on macOS), one per line, de-duplicated.
# $TMPDIR is trusted only when its OWN realpath resolves under one of the
# known OS-volatile temp locations (/tmp, /private/tmp, /var/folders,
# /private/var/folders on macOS) -- otherwise a $TMPDIR pointing at an
# arbitrary directory (a misconfigured environment, or a hostile one) would
# make every "is this under temp" check pass for wherever it points.
hr_eval_temp_roots() {
  local root resolved seen=" "
  for root in /tmp /var/tmp; do
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
  if [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ]; then
    resolved=$(cd -P "$TMPDIR" 2>/dev/null && pwd -P) || resolved=""
    if [ -n "$resolved" ]; then
      case "$resolved" in
        /tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/folders|/var/folders/*|/private/var/folders|/private/var/folders/*)
          case "$seen" in *" $resolved "*) ;; *) seen="$seen$resolved "; printf '%s\n' "$resolved" ;; esac
          ;;
      esac
    fi
  fi
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
#
# This function itself runs inside the caller's `ws=$(...)` command
# substitution -- a subshell -- so it cannot usefully `unset` anything for
# the caller (see the file-scope unset above, which is what actually does
# that). What it CAN do, and does, is re-check that the unset already took:
# if a GIT_* variable is set here, sourcing didn't happen, or something
# re-exported it since, and this refuses rather than handing back a $ws a
# later git call might not actually be confined to.
hr_eval_require_temp_workspace() {
  local ws v
  for v in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_ALTERNATE_OBJECT_DIRECTORIES; do
    eval "[ -z \"\${$v:-}\" ]" || hr_eval_refuse "$v is set; source fixtures/scaffold-safety.sh before calling this, not after"
  done
  ws=$(pwd -P)
  hr_eval_is_under_temp "$ws" || hr_eval_refuse "workspace is not under a system temp directory: $ws"
  if git -C "$ws" rev-parse --git-dir >/dev/null 2>&1; then
    hr_eval_refuse "$ws is already inside a git repository"
  fi
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
