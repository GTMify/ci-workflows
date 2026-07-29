#!/usr/bin/env bash
#
# Tests for scripts/frontmatter_gate.sh.
#
# The dangling-symlink case is the reason this file exists. gtmify-config tracks
# roughly 145 symlinks, most with absolute /Users/... targets that resolve only on the
# machine that created them. In CI they are tracked but unreadable, and the first
# version of the gate died on one with a FileNotFoundError traceback. Failing them
# instead would have turned tier A permanently red over a pre-existing problem, so the
# gate counts and reports them and does not fail.
#
# Usage: tests/frontmatter_gate_test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/../scripts/frontmatter_gate.sh"
[ -f "$GATE" ] || { echo "cannot find $GATE" >&2; exit 2; }

pass_count=0
fail_count=0

new_repo() {
  local d
  d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  printf '%s\n' "$d"
}

# check <name> <expect: fail|pass> <repo> [needle that must appear in output]
check() {
  local name="$1" expect="$2" d="$3" needle="${4:-}" rc=0 out got
  out="$(cd "$d" && bash "$GATE" 2>&1)" || rc=$?
  got="pass"; [ "$rc" -ne 0 ] && got="fail"

  local ok=1
  [ "$got" = "$expect" ] || ok=0
  if [ -n "$needle" ] && ! printf '%s' "$out" | grep -q -- "$needle"; then ok=0; fi

  if [ "$ok" -eq 1 ]; then
    printf '  ok    %-40s expected %-4s got %s\n' "$name" "$expect" "$got"
    pass_count=$((pass_count + 1))
  else
    printf '  FAIL  %-40s expected %-4s got %s' "$name" "$expect" "$got"
    [ -n "$needle" ] && printf ' (needle: %s)' "$needle"
    printf '\n'
    printf '%s\n' "$out" | sed 's/^/          /'
    fail_count=$((fail_count + 1))
  fi
  rm -rf "$d"
}

valid_skill() {
  local d="$1" n="$2"
  mkdir -p "$d/skills/$n"
  printf -- '---\nname: %s\ndescription: does a real thing\n---\nbody\n' "$n" > "$d/skills/$n/SKILL.md"
}

echo "== frontmatter gate =="

d="$(new_repo)"; valid_skill "$d" good
git -C "$d" add -A >/dev/null 2>&1; git -C "$d" commit -qm i >/dev/null 2>&1
check "valid_skill_passes" pass "$d"

d="$(new_repo)"; mkdir -p "$d/skills/nofm"
printf '# just a heading\n' > "$d/skills/nofm/SKILL.md"
git -C "$d" add -A >/dev/null 2>&1; git -C "$d" commit -qm i >/dev/null 2>&1
check "missing_frontmatter_fails" fail "$d" "no YAML frontmatter"

d="$(new_repo)"; mkdir -p "$d/skills/nodesc"
printf -- '---\nname: nodesc\n---\nbody\n' > "$d/skills/nodesc/SKILL.md"
git -C "$d" add -A >/dev/null 2>&1; git -C "$d" commit -qm i >/dev/null 2>&1
check "missing_description_fails" fail "$d" "missing or empty: description"

d="$(new_repo)"; mkdir -p "$d/skills/unclosed"
printf -- '---\nname: x\ndescription: y\nbody with no closing marker\n' > "$d/skills/unclosed/SKILL.md"
git -C "$d" add -A >/dev/null 2>&1; git -C "$d" commit -qm i >/dev/null 2>&1
check "unclosed_frontmatter_fails" fail "$d" "never closed"

# The case that crashed the first implementation.
d="$(new_repo)"; valid_skill "$d" good
mkdir -p "$d/skills/dangling"
ln -s /nonexistent/absolute/target/SKILL.md "$d/skills/dangling/SKILL.md"
git -C "$d" add -A >/dev/null 2>&1; git -C "$d" commit -qm i >/dev/null 2>&1
check "dangling_symlink_is_skipped_not_fatal" pass "$d" "unreachable target"

# A dangling symlink must not mask a genuine violation elsewhere.
d="$(new_repo)"; mkdir -p "$d/skills/nofm" "$d/skills/dangling"
printf '# heading only\n' > "$d/skills/nofm/SKILL.md"
ln -s /nonexistent/x/SKILL.md "$d/skills/dangling/SKILL.md"
git -C "$d" add -A >/dev/null 2>&1; git -C "$d" commit -qm i >/dev/null 2>&1
check "dangling_does_not_mask_real_failure" fail "$d" "no YAML frontmatter"

# Nested paths must not be swept in: git pathspec wildcards cross slashes by default,
# which is what produced 55 false positives against gtmify-config.
d="$(new_repo)"; mkdir -p "$d/agents/instructions"
printf '# prose, no frontmatter by design\n' > "$d/agents/instructions/some_agent.md"
git -C "$d" add -A >/dev/null 2>&1; git -C "$d" commit -qm i >/dev/null 2>&1
check "nested_agent_docs_are_out_of_scope" pass "$d" "nothing to check"

d="$(new_repo)"
git -C "$d" commit -q --allow-empty -m i >/dev/null 2>&1
check "repo_with_no_skills_noops" pass "$d" "nothing to check"

echo
echo "════════════════════════════════════════"
echo "  ${pass_count} passed, ${fail_count} failed"
echo "════════════════════════════════════════"
[ "$fail_count" -eq 0 ] || exit 1
