#!/usr/bin/env bash
# PreToolUse: Edit|Write
#
# Give the model an early, concise read-before-edit error when this main-agent
# transcript proves the target is not current. Claude Code remains the authority:
# this hook fails open when evidence is unavailable or cannot be parsed.

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
agent_id=$(printf '%s' "$input" | jq -r '.agent_id // empty')
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')

case "$tool" in
  Edit|Write) ;;
  *) exit 0 ;;
esac

# A subagent's Reads live in its own transcript, while the hook receives the
# parent transcript path. There is no reliable evidence to enforce here.
[ -n "$agent_id" ] && exit 0
[ -z "$file" ] && exit 0

# Claude Code does not require a prior Read when creating a new file.
[ -f "$file" ] || exit 0

# Keep the native provider as the permission boundary when transcript evidence
# is missing. This hook only prevents calls that it can prove will be rejected.
if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then
  exit 0
fi

python3 - "$file" "$transcript" "$cwd" <<'PY'
import json
import os
import sys

target_raw, transcript_path, hook_cwd = sys.argv[1:4]


def normalized_path(value, cwd):
    if not isinstance(value, str) or not value:
        return None
    value = os.path.expanduser(value)
    if not os.path.isabs(value):
        value = os.path.join(cwd or hook_cwd or os.getcwd(), value)
    return os.path.normpath(value)


target = normalized_path(target_raw, hook_cwd)
pending = {}
current = False
parse_error = False


def result_failed(block, entry):
    if block.get("is_error") is True:
        return True
    content = block.get("content")
    if isinstance(content, str) and "<tool_use_error>" in content:
        return True
    outer = entry.get("toolUseResult")
    return isinstance(outer, str) and outer.startswith("Error:")


def stale_failure(block, entry):
    text_parts = []
    content = block.get("content")
    if isinstance(content, str):
        text_parts.append(content)
    outer = entry.get("toolUseResult")
    if isinstance(outer, str):
        text_parts.append(outer)
    text = " ".join(text_parts).lower()
    return (
        "file has not been read yet" in text
        or ("read" in text and ("modified since" in text or "changed since" in text))
    )


try:
    with open(transcript_path, encoding="utf-8") as transcript:
        for line in transcript:
            try:
                entry = json.loads(line)
            except (json.JSONDecodeError, UnicodeDecodeError):
                # This can be a concurrently appended partial final line or a
                # schema problem. Either way, evidence is not complete enough
                # for this advisory hook to deny the operation.
                parse_error = True
                continue

            message = entry.get("message")
            if not isinstance(message, dict):
                continue
            content = message.get("content")
            if not isinstance(content, list):
                continue

            entry_cwd = entry.get("cwd") if isinstance(entry.get("cwd"), str) else hook_cwd
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "tool_use":
                    name = block.get("name")
                    tool_input = block.get("input")
                    tool_id = block.get("id")
                    if name in {"Read", "Edit", "Write"} and isinstance(tool_input, dict) and isinstance(tool_id, str):
                        path = normalized_path(tool_input.get("file_path"), entry_cwd)
                        if path is not None:
                            pending[tool_id] = (name, path)
                    continue

                if block.get("type") != "tool_result":
                    continue
                tool_id = block.get("tool_use_id")
                evidence = pending.pop(tool_id, None)
                if evidence is None:
                    continue
                name, path = evidence
                if path != target:
                    continue
                if not result_failed(block, entry):
                    # Native Read, Edit, and Write success messages all state
                    # that the file state is current in the model's context.
                    current = True
                elif name in {"Edit", "Write"} and stale_failure(block, entry):
                    # A native revision failure invalidates any older success.
                    current = False
except (OSError, UnicodeError):
    sys.exit(2)

if parse_error:
    sys.exit(2)
sys.exit(0 if current else 1)
PY
evidence_status=$?

case "$evidence_status" in
  0) exit 0 ;;
  1)
    echo "Blocked: Read $file successfully in this session, then retry $tool." >&2
    exit 2
    ;;
  *) exit 0 ;;
esac
