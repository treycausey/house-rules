#!/usr/bin/env bash
# Generate each plugin's hooks.json and script copies from hooks/.
# Run with --check to verify that generated files are current.

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MODE=${1:-build}
case "$MODE" in
  build|--check) ;;
  *) printf 'usage: bash scripts/build-plugins.sh [--check]\n' >&2; exit 2 ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  printf 'house-rules: cannot build plugins; required command not found: python3\n' >&2
  exit 1
fi

python3 - "$ROOT" "$MODE" <<'PY'
import json
import shutil
import sys
from pathlib import Path

root = Path(sys.argv[1])
check = sys.argv[2] == "--check"
settings_path = root / "hooks/settings.example.json"
hooks_root = root / "hooks"
plugins_root = root / "plugins"

def owner(name):
    if name.startswith(("block-", "protect-")):
        return "house-rules-guards"
    if name.startswith("warn-") or name in {"retry-counter", "fix-noclobber-redirect"}:
        return "house-rules-warnings"
    if name.startswith("verify-") or name in {
        "pre-commit-lint", "prettier-on-edit", "xcodegen-stale-check", "env-port-sweep"
    }:
        return "house-rules-verify"
    raise SystemExit("no plugin assignment for hook: " + name)

assignments = {
    "house-rules-guards": [],
    "house-rules-warnings": [],
    "house-rules-verify": [],
}
source_files = sorted(hooks_root.glob("*.sh"))
for path in source_files:
    assignments[owner(path.stem)].append(path)

settings = json.loads(settings_path.read_text())
referenced = set()
for event in settings.get("hooks", {}).values():
    for group in event:
        for hook in group.get("hooks", []):
            command = hook.get("command", "")
            name = Path(command.split()[-1].strip('"')).name if command else ""
            if name.endswith(".sh"):
                referenced.add(name)
missing = sorted(path.name for path in source_files if path.name not in referenced)
unknown = sorted(name for name in referenced if not (hooks_root / name).is_file())
if missing or unknown:
    raise SystemExit("hook settings/source mismatch: unreferenced=%r missing=%r" % (missing, unknown))

def write_or_check(path, content):
    if check:
        if not path.is_file() or path.read_text() != content:
            print("out of date: " + str(path.relative_to(root)))
            return False
        return True
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    return True

ok = True
for plugin, sources in assignments.items():
    plugin_root = plugins_root / plugin
    plugin_hooks = {}
    for event_name, groups in settings.get("hooks", {}).items():
        kept_groups = []
        for group in groups:
            kept_hooks = []
            for hook in group.get("hooks", []):
                command = hook.get("command", "")
                name = Path(command.split()[-1].strip('"')).name if command else ""
                if name and owner(Path(name).stem) == plugin:
                    updated = dict(hook)
                    updated["command"] = 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/%s"' % name
                    kept_hooks.append(updated)
            if kept_hooks:
                updated_group = dict(group)
                updated_group["hooks"] = kept_hooks
                kept_groups.append(updated_group)
        if kept_groups:
            plugin_hooks[event_name] = kept_groups

    if plugin_hooks:
        content = json.dumps({"hooks": plugin_hooks}, indent=2) + "\n"
        ok = write_or_check(plugin_root / "hooks/hooks.json", content) and ok
    elif not check:
        hooks_file = plugin_root / "hooks/hooks.json"
        if hooks_file.exists():
            hooks_file.unlink()

    scripts_dir = plugin_root / "scripts"
    expected = {"lib/hook-tools.sh"}
    for source in sources:
        expected.add(source.name)
        target = scripts_dir / source.name
        if check:
            if not target.is_file() or target.read_bytes() != source.read_bytes():
                print("out of date: " + str(target.relative_to(root)))
                ok = False
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)

    helper = hooks_root / "lib/hook-tools.sh"
    helper_target = scripts_dir / "lib/hook-tools.sh"
    if check:
        if not helper_target.is_file() or helper_target.read_bytes() != helper.read_bytes():
            print("out of date: " + str(helper_target.relative_to(root)))
            ok = False
    else:
        helper_target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(helper, helper_target)

    if scripts_dir.is_dir():
        extra = sorted(p.name for p in scripts_dir.glob("*.sh") if p.name not in expected)
        if extra:
            print("unexpected generated scripts in %s: %s" % (plugin, ", ".join(extra)))
            ok = False

# The kit embeds the small CLI source so its skill can run it through Bun.
kit = plugins_root / "house-rules-kit"
for source, relative in (
    (root / "tools/decide/bin/decide.ts", "tools/decide/bin/decide.ts"),
    (root / "tools/decide/src/decide.ts", "tools/decide/src/decide.ts"),
):
    target = kit / relative
    if check:
        if not target.is_file() or target.read_bytes() != source.read_bytes():
            print("out of date: " + str(target.relative_to(root)))
            ok = False
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)

skills = (
    ("house-rules", root / "rules/CLAUDE.md",
     "Use when setting up or reviewing agent instructions, scope, secrets, tools, testing, and delivery."),
    ("ship-policy", root / "standards/ship-policy.md",
     "Use when deciding whether an agent may ship work or must stop for owner input."),
    ("fleet-standard", root / "standards/fleet-standard.md",
     "Use when adding or reviewing the operating standard for a software repository."),
)
for name, source, description in skills:
    content = "---\nname: %s\ndescription: %s\n---\n\n%s" % (
        name, description, source.read_text()
    )
    ok = write_or_check(kit / "skills" / name / "SKILL.md", content) and ok

decide_skill = '''---
name: decide
description: Use when an agent needs an owner's judgment and must file a decision instead of guessing or stopping.
---

# File a decision

Use the bundled decision queue when an action needs the owner's judgment. First
run `list --open` and reuse the same `--key` if the issue is already open. Add
the evidence, impact, and current branch to the context. Do not resolve a
decision unless the owner has supplied the answer.

Run the bundled CLI through Bun:

```bash
bun "${CLAUDE_PLUGIN_ROOT}/tools/decide/bin/decide.ts" list --open
bun "${CLAUDE_PLUGIN_ROOT}/tools/decide/bin/decide.ts" add \\
  --project "<repo>" --agent "<agent-id>" --title "<question>" \\
  --context "<evidence, impact, branch>" --key "<stable-slug>"
```

Use `--option` more than once and `--recommend` when there are clear choices.
The queue is local to the machine. It uses `DECIDE_HOME` when set, otherwise
`~/.decide/decisions.jsonl`; do not sync that file between machines.
'''
ok = write_or_check(kit / "skills/decide/SKILL.md", decide_skill) and ok

if check and ok:
    print("plugin hook copies are in sync with hooks/ and tools/decide/")
if not ok:
    raise SystemExit(1)
PY
