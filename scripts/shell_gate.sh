#!/usr/bin/env bash
#
# shell_gate.sh: parse and lint shell scripts before they can break a session.
#
# WHY THIS EXISTS
#
# `hooks/auto_commit_on_exit.sh` shipped two real defects that no review caught:
# a noise filter that only ever matched at the repo root, and a pattern loose
# enough that a file named "My Icon Design.txt" was classified as noise and its
# changes silently dropped. That second one is data loss inside a safety net.
# The linter flags the class of sloppiness both came from, and it costs seconds.
# (This sentence deliberately avoids opening with the linter's own name: a comment
# line beginning with that word is parsed as a directive, which fails the file.)
#
# Hooks are the highest-blast-radius code in this stack: a syntax error in one
# runs on every session, on every machine, for every repo.
#
# Modes:
#   (default)   check scripts changed against a base ref
#   --audit     check every tracked shell script
#
# Usage:
#   shell_gate.sh [--base <ref>]
#   shell_gate.sh --audit
set -euo pipefail

MODE="diff"
BASE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --audit) MODE="audit" ;;
    --base)  shift; BASE="${1:-}" ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "shell_gate: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

resolve_base() {
  if [ -n "$BASE" ]; then printf '%s\n' "$BASE"; return 0; fi
  local head
  if head="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)"; then
    printf '%s\n' "${head#refs/remotes/}"; return 0
  fi
  echo "shell_gate: cannot determine a base ref; pass --base <ref>" >&2
  return 1
}

collect() {
  if [ "$MODE" = "audit" ]; then
    git ls-files -z
  else
    local base
    base="$(resolve_base)"
    git diff --name-only --diff-filter=AM -z "$base...HEAD"
  fi
}

# A shell script is anything ending .sh or .bash, plus any extensionless file
# whose first line is a shell shebang. The latter matters here because git hooks
# are conventionally extensionless.
is_shell() {
  local p="$1"
  case "$p" in
    *.sh|*.bash) return 0 ;;
  esac
  [ -f "$p" ] || return 1
  case "$p" in
    *.*) return 1 ;;
  esac
  head -n1 -- "$p" 2>/dev/null | grep -qE '^#!.*\b(bash|sh)\b' && return 0
  return 1
}

scripts=()
while IFS= read -r -d '' p; do
  [ -z "$p" ] && continue
  if is_shell "$p"; then scripts+=("$p"); fi
done < <(collect)

if [ "${#scripts[@]}" -eq 0 ]; then
  echo ">> shell gate: no shell scripts in scope, nothing to check."
  exit 0
fi

echo ">> shell gate: checking ${#scripts[@]} script(s)."
failures=0

for s in "${scripts[@]}"; do
  # `cmd || rc=$?` rather than bracketing with `set +e` / `set -e`. Re-enabling
  # errexit inside a loop turns it back on for everything after, and a later
  # non-zero status then kills the script before it can report a total.
  rc=0
  bash -n -- "$s" 2>/tmp/shellgate.err || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '   FAIL (syntax) %s\n' "$s"
    sed 's/^/       /' /tmp/shellgate.err
    failures=$((failures + 1))
    continue
  fi
  printf '   ok   (syntax) %s\n' "$s"
done

if command -v shellcheck >/dev/null 2>&1; then
  for s in "${scripts[@]}"; do
    rc=0
    shellcheck --severity=warning --format=tty -- "$s" >/tmp/shellcheck.out 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      printf '   FAIL (shellcheck) %s\n' "$s"
      sed 's/^/       /' /tmp/shellcheck.out
      failures=$((failures + 1))
    else
      printf '   ok   (shellcheck) %s\n' "$s"
    fi
  done
else
  echo "   NOTE: shellcheck not installed; ran syntax checks only."
fi

rm -f /tmp/shellgate.err /tmp/shellcheck.out

if [ "$failures" -ne 0 ]; then
  echo
  echo "!! shell gate FAILED: ${failures} check(s) did not pass."
  exit 1
fi

echo ">> shell gate passed."
exit 0
