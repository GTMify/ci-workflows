#!/usr/bin/env bash
#
# settings_gate.sh: verify a Claude Code config repo's settings.json is valid and
# every script it points at actually exists and can run.
#
# WHY THIS EXISTS
#
# settings.json wires hooks that fire on every session, on every machine. A typo in
# a path, or a hook that loses its executable bit, does not fail loudly at commit
# time; it fails later, quietly, on somebody's machine, usually as "why did the
# session not log anything". Checking it costs a second.
#
# THE PATH MAPPING THAT MAKES THIS WORK IN CI
#
# Hook commands are written as "$HOME"/.claude/hooks/x.sh because that is where they
# live on a workstation, where ~/.claude/hooks is a symlink into this repo. CI has no
# ~/.claude at all, so every $HOME/.claude/ prefix is rewritten to the repo root
# before the file is looked up. Without that rewrite this check would report every
# hook as missing.
#
# Usage: settings_gate.sh [--settings <path>]
set -euo pipefail

SETTINGS="settings.json"

while [ $# -gt 0 ]; do
  case "$1" in
    --settings) shift; SETTINGS="${1:-}" ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "settings_gate: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

REPO_ROOT="$(git rev-parse --show-toplevel)"

if [ ! -f "$REPO_ROOT/$SETTINGS" ]; then
  echo ">> settings gate: no $SETTINGS in this repo, nothing to check."
  exit 0
fi

echo ">> settings gate: checking $SETTINGS"

REPO_ROOT="$REPO_ROOT" SETTINGS="$SETTINGS" python3 <<'PY'
import json, os, re, stat, sys

root = os.environ["REPO_ROOT"]
rel = os.environ["SETTINGS"]
path = os.path.join(root, rel)

try:
    with open(path) as f:
        cfg = json.load(f)
except json.JSONDecodeError as e:
    print(f"!! {rel} is not valid JSON: {e}")
    sys.exit(1)

print(f"   ok   {rel} parses as JSON")

# Hook commands are authored for a workstation, where ~/.claude/hooks symlinks into
# this repo. Rewrite that prefix to the repo root so the files resolve in CI too.
def resolve(cmd_token):
    t = cmd_token.strip().strip('"').strip("'")
    for prefix in ('"$HOME"/.claude/', '$HOME/.claude/', '~/.claude/'):
        if t.startswith(prefix):
            return os.path.join(root, t[len(prefix):]), t
    if t.startswith("/"):
        return t, t
    return os.path.join(root, t), t

failures = 0
checked = 0

def check_command(where, command):
    global failures, checked
    # Strip quotes BEFORE extracting paths. Commands are authored as
    # "$HOME"/.claude/hooks/x.sh, and a character class that accepts a quote will
    # happily start matching at the closing one, yielding $HOME"/.claude/... which
    # then resolves to nothing. Removing quotes first makes the token unambiguous.
    # (Found by running this against the real settings.json, where an earlier version
    # of this regex reported all 9 hooks as missing.)
    cleaned = command.replace('"', "").replace("'", "")
    tokens = re.findall(r'[\w$./~\-]+\.(?:sh|py|js|mjs)', cleaned)
    if not tokens:
        return
    for tok in tokens:
        resolved, original = resolve(tok)
        checked += 1
        if not os.path.exists(resolved):
            print(f"   FAIL {where}: {original}")
            print(f"        does not exist (looked in {os.path.relpath(resolved, root)})")
            failures += 1
            continue
        mode = os.stat(resolved).st_mode
        if not (mode & stat.S_IXUSR):
            print(f"   FAIL {where}: {original}")
            print(f"        exists but is not executable; fix with: chmod +x {os.path.relpath(resolved, root)}")
            failures += 1
            continue
        print(f"   ok   {where}: {original}")

for event, matchers in (cfg.get("hooks") or {}).items():
    if not isinstance(matchers, list):
        continue
    for m in matchers:
        for h in (m.get("hooks") or []):
            cmd = h.get("command")
            if isinstance(cmd, str):
                check_command(f"hooks.{event}", cmd)

status_line = cfg.get("statusLine")
if isinstance(status_line, dict) and isinstance(status_line.get("command"), str):
    check_command("statusLine", status_line["command"])

if checked == 0:
    print("   NOTE: no script paths found in settings.json; nothing to resolve.")

if failures:
    print(f"\n!! settings gate FAILED: {failures} of {checked} referenced script(s) unusable.")
    sys.exit(1)

print(f"\n>> settings gate passed. {checked} referenced script(s) exist and are executable.")
PY
