#!/usr/bin/env bash
#
# Tests for scripts/junk_file_gate.sh.
#
# One throwaway git repo per scenario, dirty in exactly one way, asserting the
# gate's exit code. This is the same shape that caught two real defects in
# hooks/auto_commit_on_exit.sh, where a filter that looked obviously correct was
# in fact only ever matching at the repo root.
#
# The two cases that matter most are the last ones. `ignored_but_present` proves
# the gate objects to junk being TRACKED rather than to junk existing, and
# `filename_merely_contains_icon` pins the exact false-positive class that made
# the old hook silently drop real work.
#
# Usage: tests/junk_file_gate_test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/../scripts/junk_file_gate.sh"
[ -f "$GATE" ] || { echo "cannot find $GATE" >&2; exit 2; }

pass_count=0
fail_count=0

# new_repo: prints the path to a fresh git repo with one committed file.
new_repo() {
  local d
  d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  mkdir -p "$d/src"
  echo baseline > "$d/src/keep.js"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -qm baseline >/dev/null 2>&1
  printf '%s\n' "$d"
}

# check <name> <expect: fail|pass> <mode> <repo-dir>
check() {
  local name="$1" expect="$2" mode="$3" d="$4" rc=0 out
  out="$(cd "$d" && bash "$GATE" "$mode" 2>&1)" || rc=$?
  local got="pass"
  [ "$rc" -ne 0 ] && got="fail"
  if [ "$got" = "$expect" ]; then
    printf '  ok    %-38s expected %-4s got %s\n' "$name" "$expect" "$got"
    pass_count=$((pass_count + 1))
  else
    printf '  FAIL  %-38s expected %-4s got %s\n' "$name" "$expect" "$got"
    printf '%s\n' "$out" | sed 's/^/          /'
    fail_count=$((fail_count + 1))
  fi
  rm -rf "$d"
}

# track <repo> <path> [content]
track() {
  local d="$1" p="$2"
  mkdir -p "$d/$(dirname "$p")"
  printf '%s\n' "${3:-x}" > "$d/$p"
  git -C "$d" add -Af -- "$p" >/dev/null 2>&1
  git -C "$d" commit -qm "add $p" >/dev/null 2>&1
}

echo "== audit mode: paths that MUST be caught =="
for spec in \
  "worktree_gitlink:.claude/worktrees/wt-a" \
  "nested_worktree_gitlink:pkg/.claude/worktrees/wt-b" \
  "pos_supervisor_dir:.pos-supervisor/analytics.db" \
  "sqlite_wal:.pos-supervisor/analytics.db-wal" \
  "sqlite_wal_at_root:data.db-wal" \
  "sqlite_shm:cache.db-shm" \
  "supervisor_jsonl:pos-supervisor.jsonl" \
  "pos_token:.pos" \
  "pos_token_variant:.pos-production" \
  "siteglide_token:.siteglide-config" \
  "dotenv:.env" \
  "dotenv_local:.env.local" \
  "credential_token:deploy.token" \
  "credential_secret:api.secret" \
  "nested_node_modules:packages/a/node_modules/x.js" \
  "pycache:__pycache__/m.pyc" \
  "nested_pycache:tools/__pycache__/m.pyc" \
  "nested_dsstore:sub/.DS_Store" \
  "macos_icon:hooks/Icon" \
  "macos_resource_fork:._hidden" \
  ; do
  name="${spec%%:*}"; path="${spec#*:}"
  d="$(new_repo)"; track "$d" "$path"
  check "$name" fail --audit "$d"
done

echo
echo "== audit mode: paths that MUST be allowed =="
for spec in \
  "ordinary_source:src/app.js" \
  "dotenv_template:.env.template" \
  "dotenv_sops:.env.sops" \
  "dotenv_example:.env.example" \
  "readme:README.md" \
  "icon_in_a_longer_name:My Icon Design.txt" \
  "iconography_doc:docs/Iconography.md" \
  "db_file_itself:data.db" \
  ; do
  name="${spec%%:*}"; path="${spec#*:}"
  d="$(new_repo)"; track "$d" "$path"
  check "$name" pass --audit "$d"
done

echo
echo "== tracked versus merely present =="
# Junk on disk but gitignored, so never tracked. Must pass: the gate objects to
# junk being tracked, not to it existing.
d="$(new_repo)"
track "$d" ".gitignore" ".pos-supervisor/"
mkdir -p "$d/.pos-supervisor"
echo churn > "$d/.pos-supervisor/analytics.db-wal"
check "ignored_but_present" pass --audit "$d"

echo
echo "== allowlist escape hatch =="
d="$(new_repo)"
track "$d" ".ci-junk-allowlist" ".claude/worktrees/deliberate"
track "$d" ".claude/worktrees/deliberate"
check "allowlisted_path" pass --audit "$d"

d="$(new_repo)"
track "$d" ".ci-junk-allowlist" ".claude/worktrees/deliberate"
track "$d" ".claude/worktrees/something-else"
check "allowlist_does_not_over_match" fail --audit "$d"

echo
echo "== staged mode, used by the pre-commit hook =="
d="$(new_repo)"
mkdir -p "$d/.pos-supervisor"
echo churn > "$d/.pos-supervisor/analytics.db-wal"
git -C "$d" add -Af -- .pos-supervisor/analytics.db-wal >/dev/null 2>&1
check "staged_junk_is_caught" fail --staged "$d"

d="$(new_repo)"
echo more > "$d/src/keep.js"
git -C "$d" add -A >/dev/null 2>&1
check "staged_real_work_passes" pass --staged "$d"

echo
echo "== diff mode against a base ref =="
d="$(new_repo)"
git -C "$d" branch -q base-ref
track "$d" "data.db-wal"
rc=0
out="$(cd "$d" && bash "$GATE" --base base-ref 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "  ok    diff_mode_catches_new_junk           expected fail got fail"
  pass_count=$((pass_count + 1))
else
  echo "  FAIL  diff_mode_catches_new_junk           expected fail got pass"
  printf '%s\n' "$out" | sed 's/^/          /'
  fail_count=$((fail_count + 1))
fi
rm -rf "$d"

d="$(new_repo)"
git -C "$d" branch -q base-ref
track "$d" "src/feature.js"
rc=0
out="$(cd "$d" && bash "$GATE" --base base-ref 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "  ok    diff_mode_allows_real_work           expected pass got pass"
  pass_count=$((pass_count + 1))
else
  echo "  FAIL  diff_mode_allows_real_work           expected pass got fail"
  printf '%s\n' "$out" | sed 's/^/          /'
  fail_count=$((fail_count + 1))
fi
rm -rf "$d"

echo
echo "════════════════════════════════════════"
echo "  ${pass_count} passed, ${fail_count} failed"
echo "════════════════════════════════════════"
[ "$fail_count" -eq 0 ] || exit 1
