#!/usr/bin/env bash
# PreToolUse: Bash, Edit|Write
# Blocks unrecoverable deletion or overwrite of secrets-like files.
#
# A secrets file is usually the ONLY copy: it is gitignored by design, it is
# not in any backup that a repo clone would restore, and nothing regenerates
# it. Last week a delegated agent ran `rm wifi_secrets.h` and the credentials
# were simply gone. Reads pass through untouched; this only stops destruction.
#
# Deliberately much simpler than protect-ssh-config.sh: no quote-aware
# tokenizer, no heredoc handling. For this file class a false positive costs
# one manual command; a false negative costs the secret. Slightly conservative
# is the right trade.
#
# ~/.claude/hooks/ is exempt: a hook that guards secrets gets a secrets-like
# name, but it is a script, not a secret. The exemption is by location only;
# a `secrets.sh` anywhere else can hold real exported keys and stays guarded.
#
# Tested by hooks/tests/run-tests.sh

input=$(cat)

# Basename patterns that mark a file as secrets-like (matched lowercased).
secrets_re='(secret|credential|\.pem$|^id_rsa|^id_ed25519|^\.env$|^\.env\.)'
# Basename patterns that mark it as a stand-in, not the real thing.
exempt_re='(example|sample|template|mock|test)'

deny() {
  echo "Blocked: $1" >&2
  echo "Matched the secrets-file guard: $2" >&2
  echo "Secrets files are usually the only copy -- no git, no backup, nothing regenerates them." >&2
  echo "If this is intentional, run it yourself outside the agent, or rename the file / adjust the patterns in ~/.claude/hooks/protect-secrets-files.sh." >&2
  exit 2
}

# Is this path a secrets-like file that must not be destroyed?
is_secret_path() {
  local p=$1 base lower
  [ -n "$p" ] || return 1

  # Normalise ~ and $HOME so the exemption prefixes see one shape.
  p=${p/#\~/$HOME}
  p=${p//\$HOME/$HOME}

  # Leading slash so the exemption prefixes below match a relative path
  # (`node_modules/foo/secrets.js`) the same way as an absolute one.
  case "$p" in /*) ;; *) p="/$p" ;; esac

  # Scratch and vendored locations hold copies, not originals. The hooks dir
  # holds hook scripts; one that guards secrets is named for them but holds
  # none (creating block-secret-file-reads.sh there was blocked).
  case "$p" in
    */tmp/*|*/scratchpad/*|*/node_modules/*|*/.Trash/*|*/Trash/*) return 1 ;;
    "$HOME"/.claude/hooks/*) return 1 ;;
  esac

  base=${p##*/}
  lower=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
  # Anchored decisions first. .env.schema is the committed Varlock schema
  # (never a secret); any .env.<anything>.local (.env.test.local,
  # .env.schema.local, ...) holds real values, so the substring exemptions
  # below must never see it.
  case "$lower" in
    .env.schema) return 1 ;;
    .env.*.local) return 0 ;;
  esac
  case "$lower" in
    *example*|*sample*|*template*|*mock*|*test*) return 1 ;;
  esac

  printf '%s' "$lower" | grep -qE "$secrets_re"
}

# --- Edit / Write -----------------------------------------------------------
# A Write replaces the whole file, so it clobbers an existing secret. An Edit
# is surgical and already required a prior Read, so it is left alone. Writing
# a secrets file that does not exist yet is how they get created.
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')
if [ -n "$file_path" ]; then
  tool_name=$(echo "$input" | jq -r '.tool_name // empty')
  [ "$tool_name" = "Edit" ] && exit 0
  resolved=${file_path/#\~/$HOME}
  resolved=${resolved//\$HOME/$HOME}
  if [ -f "$resolved" ] && is_secret_path "$file_path"; then
    deny "refusing to overwrite $file_path with a whole-file Write." \
         "the existing file's name looks like a secrets file"
  fi
  exit 0
fi

# --- Bash -------------------------------------------------------------------
cmd=$(echo "$input" | jq -r '.tool_input.command // empty')
[ -n "$cmd" ] || exit 0

# Truncating redirection onto a secrets file. `>>` appends and is left alone,
# so it is masked out before the scan.
masked=$(printf '%s' "$cmd" | sed 's/>>/@@APPEND@@/g')
while IFS= read -r target; do
  [ -n "$target" ] || continue
  is_secret_path "$target" && deny "refusing to truncate $target via shell redirection." \
                                   "a single '>' redirect onto a secrets-file name"
done <<EOF
$(printf '%s' "$masked" | grep -oE '>[[:space:]]*[^[:space:];|&<>]+' | sed 's/^>[[:space:]]*//' | tr -d "\"'")
EOF

# Destructive commands acting on a secrets file. Segments are split on the
# shell's sequencing operators; each segment is judged on its own.
while IFS= read -r segment; do
  [ -n "$segment" ] || continue

  # Whitespace tokens, with surrounding quotes stripped.
  tokens=()
  for raw in $segment; do
    raw=${raw%\"}; raw=${raw#\"}
    raw=${raw%\'}; raw=${raw#\'}
    [ -n "$raw" ] && tokens+=("$raw")
  done
  [ ${#tokens[@]} -gt 0 ] || continue

  # The command this segment actually runs, past env assignments and wrappers.
  segcmd=
  i=0
  while [ $i -lt ${#tokens[@]} ]; do
    t=${tokens[$i]}
    case "$t" in
      [A-Za-z_]*=*) i=$((i+1)); continue ;;
      -*) i=$((i+1)); continue ;;
    esac
    case "${t##*/}" in
      sudo|env|command|xargs) i=$((i+1)); continue ;;
    esac
    segcmd=${t##*/}
    break
  done
  [ -n "$segcmd" ] || continue

  # Its operands, options dropped.
  operands=()
  j=$((i+1))
  while [ $j -lt ${#tokens[@]} ]; do
    t=${tokens[$j]}
    case "$t" in
      --) j=$((j+1)); continue ;;
      -?*) j=$((j+1)); continue ;;
    esac
    operands+=("$t")
    j=$((j+1))
  done

  case "$segcmd" in
    rm|shred|truncate|unlink)
      for t in "${operands[@]}"; do
        is_secret_path "$t" && deny "refusing to run '$segcmd' on $t." \
                                    "a secrets-file name as an operand of $segcmd"
      done
      ;;
    mv|cp)
      # Only the destination: copying a secret OUT is a read.
      if [ ${#operands[@]} -gt 1 ]; then
        t=${operands[$(( ${#operands[@]} - 1 ))]}
        is_secret_path "$t" && deny "refusing to overwrite $t via '$segcmd'." \
                                    "a secrets-file name as the destination of $segcmd"
      fi
      ;;
  esac
done <<EOF
$(printf '%s' "$cmd" | tr ';|&' '\n\n\n')
EOF

exit 0
