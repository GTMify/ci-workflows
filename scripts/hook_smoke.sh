#!/usr/bin/env bash
#
# hook_smoke.sh: run each hook's own safe self-check so a broken hook is caught
# here rather than on somebody's machine mid-session.
#
# THE SAFETY RULE THAT SHAPES THIS SCRIPT
#
# A hook is arbitrary code with side effects. auto_commit_on_exit.sh commits and
# pushes; log_session_transcript.sh writes to Supabase. Executing hooks blindly in
# CI would be reckless, so this script NEVER runs a hook unless the hook itself
# advertises a no-op flag: it greps for --dry-run handling and only then invokes it
# with --dry-run. A hook without that flag is reported as skipped, not run.
#
# That means coverage here is partial by design, and the report says so rather than
# implying every hook was exercised. A silent partial pass reading as full coverage
# is the exact failure this repo's other checks exist to prevent.
#
# Usage: hook_smoke.sh [--dir <hooks dir>]
set -euo pipefail

HOOK_DIR="hooks"

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) shift; HOOK_DIR="${1:-}" ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "hook_smoke: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

REPO_ROOT="$(git rev-parse --show-toplevel)"
DIR="$REPO_ROOT/$HOOK_DIR"

if [ ! -d "$DIR" ]; then
  echo ">> hook smoke: no $HOOK_DIR/ directory, nothing to check."
  exit 0
fi

ran=0
skipped=0
failures=0

echo ">> hook smoke: scanning $HOOK_DIR/"

while IFS= read -r -d '' h; do
  name="$(basename "$h")"

  # Skip macOS artifacts, which is not hypothetical: every repo in this workspace
  # has an `Icon` file inside .git/hooks, and gtmify-config tracks one in hooks/.
  case "$name" in
    Icon|Icon*|.DS_Store|._*) continue ;;
  esac

  case "$name" in
    *.sh) ;;
    *) continue ;;
  esac

  if ! grep -q -- '--dry-run' "$h"; then
    printf '   skip %-32s no --dry-run flag; not safe to execute in CI\n' "$name"
    skipped=$((skipped + 1))
    continue
  fi

  rc=0
  # `cmd || rc=$?` rather than set +e / set -e around it: re-enabling errexit inside
  # a loop turns it back on for everything after, and a later non-zero status then
  # kills the script before it can print a total.
  timeout 60 bash "$h" --dry-run >/tmp/hooksmoke.out 2>&1 || rc=$?

  if [ "$rc" -eq 0 ]; then
    printf '   ok   %-32s --dry-run exited 0\n' "$name"
    ran=$((ran + 1))
  else
    printf '   FAIL %-32s --dry-run exited %s\n' "$name" "$rc"
    sed 's/^/        /' /tmp/hooksmoke.out | head -20
    failures=$((failures + 1))
  fi
done < <(find "$DIR" -maxdepth 1 -type f -print0)

rm -f /tmp/hooksmoke.out

echo
echo "   ran ${ran}, skipped ${skipped} (no safe flag), failed ${failures}"

if [ "$failures" -ne 0 ]; then
  echo "!! hook smoke FAILED."
  exit 1
fi

if [ "$ran" -eq 0 ]; then
  echo ">> hook smoke: nothing was executable in dry-run mode. Coverage here is zero,"
  echo "   which is a real gap rather than a pass. Add --dry-run support to a hook to"
  echo "   bring it under this check."
  exit 0
fi

echo ">> hook smoke passed."
