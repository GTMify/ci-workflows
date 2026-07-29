#!/usr/bin/env bash
#
# junk_file_gate.sh: refuse to let ephemeral, generated, or credential files
# become tracked content.
#
# WHY THIS EXISTS
#
# Nothing stopped 33 `.claude/worktrees/*` gitlinks and 40 `.pos-supervisor/*`
# files, including a SQLite `analytics.db-wal`, from becoming tracked in
# GTMify/GTMify. A write-ahead log is rewritten on nearly every run, so the repo
# was permanently dirty, the session-end auto-commit hook turned that into a
# commit every time, and local `master` ended up 19 commits off origin with no
# app code in any of them. Unwinding it cost a session. `gtmify-config` has a
# committed `hooks/Icon` for the same reason: no gate.
#
# This is cheap to run and it is the one check that pays for itself immediately,
# so it runs on every tier.
#
# ONLY TRACKED PATHS CAN FAIL. Every mode below enumerates paths through git, so
# a file that exists on disk but is gitignored is invisible here by construction.
# That is deliberate: the gate objects to junk being *tracked*, not to junk
# existing.
#
# Modes:
#   (default)   compare against a base ref; what a pull request would add
#   --staged    inspect the index; used by the pre-commit hook
#   --audit     inspect every tracked file; used for one-time cleanups
#
# Usage:
#   junk_file_gate.sh [--base <ref>]
#   junk_file_gate.sh --staged
#   junk_file_gate.sh --audit
set -euo pipefail

MODE="diff"
BASE=""
CR=$'\r'

while [ $# -gt 0 ]; do
  case "$1" in
    --audit)  MODE="audit" ;;
    --staged) MODE="staged" ;;
    --base)   shift; BASE="${1:-}" ;;
    -h|--help)
      sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "junk_file_gate: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

git rev-parse --show-toplevel >/dev/null 2>&1 || {
  echo "junk_file_gate: not inside a git repository" >&2
  exit 2
}
REPO_ROOT="$(git rev-parse --show-toplevel)"
ALLOWLIST="$REPO_ROOT/.ci-junk-allowlist"

# Returns 0 and prints a reason when the path is junk; returns 1 when it is fine.
#
# Directory prefixes are matched with a leading-or-nested pair so that both
# `node_modules/x` and `packages/a/node_modules/x` are caught. Everything else is
# matched on the basename, so nested copies are caught too. An earlier version of
# this idea in auto_commit_on_exit.sh matched "space followed by the name" against
# raw porcelain output, which silently only ever caught noise at the repo root.
junk_reason() {
  local p="$1" base
  base="${p##*/}"

  case "$p" in
    .claude/worktrees/*|*/.claude/worktrees/*)
      echo "tool-managed git worktree gitlink; changes whenever any session commits in its own worktree"; return 0 ;;
    .pos-supervisor/*|*/.pos-supervisor/*)
      echo "platformOS session telemetry; regenerated every run"; return 0 ;;
    node_modules/*|*/node_modules/*)
      echo "installed dependencies; restore with the lockfile instead"; return 0 ;;
    __pycache__/*|*/__pycache__/*)
      echo "Python bytecode cache"; return 0 ;;
  esac

  # Anything named .env is treated as secret-bearing unless it is explicitly a
  # template or a sops-encrypted file, which are safe and are meant to be shared.
  case "$base" in
    .env*)
      case "$base" in
        *.sops|*.template|*.example|*.sample) ;;
        *) echo "environment file; may carry secrets, commit a .template or .sops instead"; return 0 ;;
      esac ;;
  esac

  case "$base" in
    pos-supervisor.jsonl)
      echo "platformOS session telemetry; regenerated every run"; return 0 ;;
    .pos|.pos-*)
      echo "platformOS admin token file; NEVER commit"; return 0 ;;
    .siteglide-config)
      echo "SiteGlide admin token file; NEVER commit"; return 0 ;;
    *.token|*.secret)
      echo "credential file; NEVER commit"; return 0 ;;
    *.db-wal|*.db-shm|*.db-journal)
      echo "SQLite sidecar; rewritten on nearly every run"; return 0 ;;
    *.pyc)
      echo "Python bytecode"; return 0 ;;
    .DS_Store)
      echo "macOS directory metadata"; return 0 ;;
    "Icon"|"Icon${CR}")
      echo "macOS custom-icon artifact"; return 0 ;;
    ._*)
      echo "macOS resource fork"; return 0 ;;
  esac

  return 1
}

# A gate with no legitimate override gets switched off the first time it is
# wrong, so `.ci-junk-allowlist` holds one glob per line, with # comments.
is_allowlisted() {
  local p="$1" pat trimmed
  [ -f "$ALLOWLIST" ] || return 1
  while IFS= read -r pat || [ -n "$pat" ]; do
    pat="${pat%%#*}"
    trimmed="${pat#"${pat%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ -z "$trimmed" ] && continue
    # shellcheck disable=SC2254
    case "$p" in
      $trimmed) return 0 ;;
    esac
  done < "$ALLOWLIST"
  return 1
}

resolve_base() {
  if [ -n "$BASE" ]; then
    printf '%s\n' "$BASE"
    return 0
  fi
  local head
  if head="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)"; then
    printf '%s\n' "${head#refs/remotes/}"
    return 0
  fi
  echo "junk_file_gate: cannot determine a base ref; pass --base <ref>" >&2
  return 1
}

collect() {
  case "$MODE" in
    audit)
      git ls-files -z ;;
    staged)
      git diff --cached --name-only --diff-filter=AM -z ;;
    diff)
      local base
      base="$(resolve_base)"
      git diff --name-only --diff-filter=AM -z "$base...HEAD" ;;
  esac
}

offenders=()
reasons=()
checked=0

while IFS= read -r -d '' path; do
  [ -z "$path" ] && continue
  checked=$((checked + 1))
  if is_allowlisted "$path"; then
    continue
  fi
  if reason="$(junk_reason "$path")"; then
    offenders+=("$path")
    reasons+=("$reason")
  fi
done < <(collect)

if [ "${#offenders[@]}" -eq 0 ]; then
  echo ">> junk-file gate passed. ${checked} path(s) checked, mode=${MODE}."
  exit 0
fi

echo "!! junk-file gate FAILED: ${#offenders[@]} of ${checked} tracked path(s) should not be in git."
echo
for i in "${!offenders[@]}"; do
  printf '   %s\n' "${offenders[$i]}"
  printf '       %s\n' "${reasons[$i]}"
done
echo
echo "   To fix, untrack them and add the pattern to .gitignore:"
echo
for o in "${offenders[@]}"; do
  printf '       git rm --cached -- %q\n' "$o"
done
echo
echo "   Untracking does NOT delete your local copy."
echo "   If one of these is genuinely intended content, add its path to"
echo "   .ci-junk-allowlist with a comment explaining why."
exit 1
