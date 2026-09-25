#!/usr/bin/env bash
# PreToolUse: Bash, Edit|Write
# Blocks modification of anything under ~/.ssh.
#
# If ~/.ssh/config rides a dotfile sync, a bad edit here does not
# stay local -- the nightly sync copies it to every machine and takes remote
# access down on both. Private keys live in the same directory and are never
# recoverable once clobbered. Reads pass through untouched; this only stops
# writes.
#
# The Bash branch used to run its regexes over the WHOLE command string, so an
# ~/.ssh path counted wherever it appeared. That was wrong in both directions:
#   - false positive: `cat > deploy.yml <<'YAML' ... echo "$KEY" >>
#     ~/.ssh/id_ed25519 ... YAML` was blocked. The path is in a heredoc BODY --
#     data being written into another file, describing a GitHub runner, not
#     this machine's ~/.ssh. Same for a path quoted inside an argument:
#     `echo 'to add a key: echo k >> ~/.ssh/authorized_keys'` and
#     `grep -rn 'echo x > ~/.ssh/config' docs/`.
#   - false negative: `/bin/rm ~/.ssh/id_ed25519` was allowed, because the rm
#     rule wanted a separator immediately before the name rather than resolving
#     the command; and `sed -i` in one segment blocked an ~/.ssh path named in
#     a different one.
# Heredoc bodies are now dropped before anything is scanned, a redirection
# counts only when its `>` is a real operator (outside quotes, unescaped), and
# the sed/tee/rm/mv rules match the resolved command and the path operands of
# a single segment.
#
# Tested by hooks/tests/run-tests.sh

input=$(cat)

ssh_dir_re='(~|\$HOME|/Users/[^/[:space:]]+)/\.ssh/'

deny() {
  echo "Blocked: refusing to modify $1." >&2
  echo "~/.ssh holds private keys, and if a dotfile sync covers it, a bad write propagates to every machine." >&2
  echo "If this is intentional, make the change yourself outside the agent." >&2
  exit 2
}

# --- Edit / Write -----------------------------------------------------------
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')
if [ -n "$file_path" ]; then
  # Normalise ~ and $HOME so the prefix test sees one shape.
  resolved=${file_path/#\~/$HOME}
  resolved=${resolved//\$HOME/$HOME}
  case "$resolved" in
    "$HOME"/.ssh/*) deny "$file_path" ;;
  esac
  exit 0
fi

# --- Bash -------------------------------------------------------------------
cmd=$(echo "$input" | jq -r '.tool_input.command // empty')
[ -n "$cmd" ] || exit 0

# Field separator for the parser helpers below. A shell command cannot contain
# a literal US control character, so it can never collide with the payload.
SEP=$'\037'

mentions_ssh() { printf '%s\n' "$1" | grep -qE "$ssh_dir_re"; }

# Drop heredoc bodies. A heredoc body is the DATA a command writes somewhere
# else, not a command this shell runs, so an ~/.ssh path inside one says
# nothing about this machine's ~/.ssh.
strip_heredocs() {
  local text=$1 out= line body delim strip i n c
  local quote=
  local pending=()
  while IFS= read -r line || [ -n "$line" ]; do
    if [ ${#pending[@]} -gt 0 ]; then
      strip=${pending[0]%%:*}
      delim=${pending[0]#*:}
      body=$line
      # `<<-` strips leading TABs from the body and from the terminator.
      if [ "$strip" = 1 ]; then
        while [ "${body#$'\t'}" != "$body" ]; do body=${body#$'\t'}; done
      fi
      [ "$body" = "$delim" ] && pending=("${pending[@]:1}")
      continue
    fi
    out=$out$line$'\n'
    # Collect the delimiters this command line opens: `cat <<A <<B` opens two.
    n=${#line}
    i=0
    while [ $i -lt $n ]; do
      c=${line:i:1}
      if [ -n "$quote" ]; then
        if [ "$c" = "\\" ] && [ "$quote" = '"' ]; then i=$((i+2)); continue; fi
        [ "$c" = "$quote" ] && quote=
        i=$((i+1))
        continue
      fi
      case $c in
        \\) i=$((i+2)); continue ;;
        '"'|"'") quote=$c; i=$((i+1)); continue ;;
      esac
      if [ "$c" != '<' ] || [ "${line:i+1:1}" != '<' ]; then i=$((i+1)); continue; fi
      # `<<<` is a herestring: no body follows.
      if [ "${line:i+2:1}" = '<' ]; then i=$((i+3)); continue; fi
      i=$((i+2))
      strip=0
      if [ "${line:i:1}" = '-' ]; then strip=1; i=$((i+1)); fi
      while [ $i -lt $n ]; do
        case ${line:i:1} in ' '|$'\t') i=$((i+1)) ;; *) break ;; esac
      done
      delim=
      while [ $i -lt $n ]; do
        c=${line:i:1}
        case $c in
          ' '|$'\t'|';'|'&'|'|'|'<'|'>') break ;;
          '"'|"'"|\\) i=$((i+1)) ;;
          *) delim=$delim$c; i=$((i+1)) ;;
        esac
      done
      [ -n "$delim" ] && pending+=("$strip:$delim")
    done
  done <<< "$text"
  printf '%s' "$out"
  return 0
}

# Targets of `>`, `>>` and `>|` redirections. A `>` counts only outside quotes
# and unescaped; `>&` (fd dup) and `>(` (process substitution) write no file.
redirect_targets() {
  local text=$1 i=0 c nxt q buf
  local n=${#text}
  local quote=
  while [ $i -lt $n ]; do
    c=${text:i:1}
    if [ -n "$quote" ]; then
      if [ "$c" = "\\" ] && [ "$quote" = '"' ]; then i=$((i+2)); continue; fi
      [ "$c" = "$quote" ] && quote=
      i=$((i+1))
      continue
    fi
    case $c in
      \\) i=$((i+2)); continue ;;
      '"'|"'") quote=$c; i=$((i+1)); continue ;;
    esac
    if [ "$c" != '>' ]; then i=$((i+1)); continue; fi
    nxt=${text:i+1:1}
    case $nxt in
      '>'|'|') i=$((i+2)) ;;
      '&'|'(') i=$((i+1)); continue ;;
      *) i=$((i+1)) ;;
    esac
    while [ $i -lt $n ]; do
      case ${text:i:1} in ' '|$'\t') i=$((i+1)) ;; *) break ;; esac
    done
    buf=
    q=${text:i:1}
    case $q in
      '"'|"'")
        i=$((i+1))
        while [ $i -lt $n ] && [ "${text:i:1}" != "$q" ]; do
          buf=$buf${text:i:1}
          i=$((i+1))
        done
        i=$((i+1))
        ;;
      *)
        while [ $i -lt $n ]; do
          c=${text:i:1}
          case $c in
            ' '|$'\t'|$'\n'|'<'|'>'|'|'|'&'|';'|'('|')') break ;;
            \\) buf=$buf${text:i+1:1}; i=$((i+2)) ;;
            *) buf=$buf$c; i=$((i+1)) ;;
          esac
        done
        ;;
    esac
    [ -n "$buf" ] && printf '%s%s' "$buf" "$SEP"
  done
  return 0
}

# Split on top-level &&, ||, ;, |, & and newline, respecting quotes.
split_segments() {
  local text=$1 i=0 c cur=
  local n=${#text}
  local quote=
  while [ $i -lt $n ]; do
    c=${text:i:1}
    if [ -n "$quote" ]; then
      cur=$cur$c
      if [ "$c" = "\\" ] && [ "$quote" = '"' ]; then
        cur=$cur${text:i+1:1}
        i=$((i+2))
        continue
      fi
      [ "$c" = "$quote" ] && quote=
      i=$((i+1))
      continue
    fi
    case $c in
      \\) cur=$cur$c${text:i+1:1}; i=$((i+2)); continue ;;
      '"'|"'") quote=$c; cur=$cur$c; i=$((i+1)); continue ;;
      ';'|'|'|'&'|$'\n')
        printf '%s%s' "$cur" "$SEP"
        cur=
        while [ $i -lt $n ]; do
          case ${text:i:1} in ';'|'|'|'&'|$'\n') i=$((i+1)) ;; *) break ;; esac
        done
        continue
        ;;
    esac
    cur=$cur$c
    i=$((i+1))
  done
  printf '%s%s' "$cur" "$SEP"
  return 0
}

# Tokenise one segment, removing quotes. Redirections and their targets are
# dropped: a redirect target is not a path operand of the command, so
# `mv /tmp/foo ~/.ssh/config 2>/dev/null` still ends on its real destination.
tokenize() {
  local seg=$1 i=0 c q buf= have=0
  local n=${#seg}
  while [ $i -lt $n ]; do
    c=${seg:i:1}
    case $c in
      ' '|$'\t'|$'\n')
        [ $have -eq 1 ] && printf '%s%s' "$buf" "$SEP"
        buf=
        have=0
        i=$((i+1))
        ;;
      '"'|"'")
        q=$c
        have=1
        i=$((i+1))
        while [ $i -lt $n ] && [ "${seg:i:1}" != "$q" ]; do
          if [ "$q" = '"' ] && [ "${seg:i:1}" = "\\" ]; then
            buf=$buf${seg:i+1:1}
            i=$((i+2))
            continue
          fi
          buf=$buf${seg:i:1}
          i=$((i+1))
        done
        i=$((i+1))
        ;;
      \\)
        buf=$buf${seg:i+1:1}
        have=1
        i=$((i+2))
        ;;
      '<'|'>')
        # An all-digit buffer here is an fd number glued to the operator
        # (`2>`), not a token of its own.
        case $buf in
          ''|*[!0-9]*) [ $have -eq 1 ] && printf '%s%s' "$buf" "$SEP" ;;
        esac
        buf=
        have=0
        while [ $i -lt $n ]; do
          case ${seg:i:1} in '<'|'>'|'&'|'|'|'-') i=$((i+1)) ;; *) break ;; esac
        done
        while [ $i -lt $n ]; do
          case ${seg:i:1} in ' '|$'\t') i=$((i+1)) ;; *) break ;; esac
        done
        q=${seg:i:1}
        case $q in
          '"'|"'")
            i=$((i+1))
            while [ $i -lt $n ] && [ "${seg:i:1}" != "$q" ]; do i=$((i+1)); done
            i=$((i+1))
            ;;
          *)
            while [ $i -lt $n ]; do
              case ${seg:i:1} in
                ' '|$'\t'|$'\n'|'<'|'>'|'|'|'&'|';') break ;;
                *) i=$((i+1)) ;;
              esac
            done
            ;;
        esac
        ;;
      *)
        buf=$buf$c
        have=1
        i=$((i+1))
        ;;
    esac
  done
  [ $have -eq 1 ] && printf '%s%s' "$buf" "$SEP"
  return 0
}

scrubbed=$(strip_heredocs "$cmd")

# Nothing under ~/.ssh is mentioned at all: nothing to guard.
mentions_ssh "$scrubbed" || exit 0

# Redirection into an ~/.ssh path, including the noclobber override `>|`.
while IFS= read -r -d "$SEP" target || [ -n "$target" ]; do
  [ -n "$target" ] || continue
  mentions_ssh "$target" && deny "an ~/.ssh path via shell redirection"
done < <(redirect_targets "$scrubbed")

# In-place edit, tee, outright removal/truncation, or an ~/.ssh destination.
# Judged per segment, against the command that segment actually invokes.
while IFS= read -r -d "$SEP" segment || [ -n "$segment" ]; do
  [ -n "$segment" ] || continue

  tokens=()
  while IFS= read -r -d "$SEP" tok || [ -n "$tok" ]; do
    tokens+=("$tok")
  done < <(tokenize "$segment")
  [ ${#tokens[@]} -gt 0 ] || continue

  # The command this segment actually runs, path-qualified or not.
  segcmd=
  i=0
  while [ $i -lt ${#tokens[@]} ]; do
    t=${tokens[$i]}
    case $t in
      ''|[A-Za-z_]*=*) i=$((i+1)); continue ;;   # `FOO=bar cmd`
      -*) i=$((i+1)); continue ;;                # option of a skipped wrapper
    esac
    case ${t##*/} in
      sudo|time|env|command|xargs) i=$((i+1)); continue ;;
    esac
    segcmd=${t##*/}
    break
  done
  [ -n "$segcmd" ] || continue

  # Its options and its path operands, kept apart.
  opts=
  operands=()
  end_of_options=0
  j=$((i+1))
  while [ $j -lt ${#tokens[@]} ]; do
    t=${tokens[$j]}
    if [ $end_of_options -eq 0 ]; then
      case $t in
        --) end_of_options=1; j=$((j+1)); continue ;;
        -?*) opts="$opts $t"; j=$((j+1)); continue ;;
      esac
    fi
    operands+=("$t")
    j=$((j+1))
  done

  case $segcmd in
    sed)
      case $opts in
        *-i*)
          for t in "${operands[@]}"; do
            mentions_ssh "$t" && deny "an ~/.ssh path via sed -i"
          done
          ;;
      esac
      ;;
    tee)
      for t in "${operands[@]}"; do
        mentions_ssh "$t" && deny "an ~/.ssh path via tee"
      done
      ;;
    rm|truncate|shred|dd|chown|ln)
      for t in "${operands[@]}"; do
        mentions_ssh "$t" && deny "an ~/.ssh path"
      done
      ;;
    mv|cp|install)
      # Only when an ~/.ssh path is the destination (the final operand).
      if [ ${#operands[@]} -gt 0 ]; then
        t=${operands[$(( ${#operands[@]} - 1 ))]}
        mentions_ssh "$t" && deny "an ~/.ssh path as a copy/move destination"
      fi
      ;;
  esac
done < <(split_segments "$scrubbed")

exit 0
