#!/usr/bin/env bash
#
# frontmatter_gate.sh: every skill and agent must declare a name and a description.
#
# WHY THIS EXISTS
#
# A skill's description is the only thing the model sees when deciding whether the
# skill applies. A skill with no description, or with frontmatter that failed to
# parse, does not error: it simply never triggers. It looks installed and does
# nothing, which is the most expensive kind of broken because nobody investigates a
# feature they believe is working.
#
# Frontmatter is parsed by hand rather than with PyYAML, which is not guaranteed to
# be present on a runner. Checking that two keys exist and are non-empty does not
# need a YAML parser, and adding a dependency to a gate makes the gate fragile.
#
# SCOPE, AND WHY IT IS NARROW
#
# Only files that MUST carry frontmatter are checked. An earlier version also swept
# `agents/*.md`, which produced 55 failures against gtmify-config, every one of them
# a false positive: git pathspec wildcards match across slashes by default, so that
# glob reached `agents/instructions/*.md`, which are Paperclip instruction files and
# prose documentation with no frontmatter by design. `:(glob)` magic is used below
# precisely so `*` stops at a slash.
#
# Pass --glob to add targets, for example a repo that keeps real Claude Code agent
# definitions in .claude/agents/.
#
# Usage: frontmatter_gate.sh [--glob <pathspec>]...
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

globs=(':(glob)skills/*/SKILL.md' ':(glob).claude/agents/*.md')

while [ $# -gt 0 ]; do
  case "$1" in
    --glob) shift; globs+=(":(glob)${1:-}") ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "frontmatter_gate: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

targets=()
while IFS= read -r -d '' f; do targets+=("$f"); done < <(
  { git ls-files -z -- "${globs[@]}" 2>/dev/null || true; }
)

if [ "${#targets[@]}" -eq 0 ]; then
  echo ">> frontmatter gate: no skills or agents in this repo, nothing to check."
  exit 0
fi

echo ">> frontmatter gate: checking ${#targets[@]} file(s)"

failures=0
unreadable=0

for f in "${targets[@]}"; do
  # Tracked but not readable in this checkout. Overwhelmingly this means a committed
  # symlink with an absolute target that exists only on the authoring machine, and
  # gtmify-config has roughly 145 tracked symlinks of which most are absolute. That is
  # a real and separate problem, but failing a hundred files here would make this gate
  # permanently red and therefore ignored, so these are counted and reported rather
  # than treated as frontmatter violations. An earlier version simply crashed with a
  # FileNotFoundError traceback.
  if [ ! -r "$f" ]; then
    if [ -L "$f" ]; then
      printf '   skip %s\n        tracked symlink with an unreachable target: %s\n' "$f" "$(readlink "$f")"
    else
      printf '   skip %s\n        tracked but not readable in this checkout\n' "$f"
    fi
    unreadable=$((unreadable + 1))
    continue
  fi

  problem="$(F="$f" python3 <<'PY'
import os, sys

path = os.environ["F"]
try:
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().split("\n")
except OSError as e:
    sys.stdout.write(f"could not be read: {e.strerror}")
    sys.exit(0)

if not lines or lines[0].strip() != "---":
    sys.stdout.write("no YAML frontmatter; file must open with ---")
    sys.exit(0)

body = []
closed = False
for line in lines[1:]:
    if line.strip() == "---":
        closed = True
        break
    body.append(line)

if not closed:
    sys.stdout.write("frontmatter is never closed with a second ---")
    sys.exit(0)

found = {}
for line in body:
    if line[:1].isspace() or not line.strip() or line.lstrip().startswith("#"):
        continue
    if ":" not in line:
        continue
    key, _, value = line.partition(":")
    found[key.strip()] = value.strip().strip('"').strip("'")

missing = [k for k in ("name", "description") if not found.get(k)]
if missing:
    sys.stdout.write("missing or empty: " + ", ".join(missing))
PY
)"

  if [ -n "$problem" ]; then
    printf '   FAIL %s\n        %s\n' "$f" "$problem"
    failures=$((failures + 1))
  else
    printf '   ok   %s\n' "$f"
  fi
done

if [ "$failures" -ne 0 ]; then
  echo
  echo "!! frontmatter gate FAILED: ${failures} file(s) would never trigger."
  [ "$unreadable" -gt 0 ] && echo "   (${unreadable} further file(s) were unreadable and not assessed; see above)"
  exit 1
fi

# Say plainly what was not checked. A gate that quietly skips work reads as full
# coverage and is worse than one that admits a gap.
if [ "$unreadable" -gt 0 ]; then
  echo
  echo ">> frontmatter gate passed on $(( ${#targets[@]} - unreadable )) file(s)."
  echo "   ${unreadable} were NOT assessed because they are tracked but unreadable here,"
  echo "   almost certainly committed symlinks with absolute targets. Those are broken for"
  echo "   any machine other than the one that created them; worth fixing separately."
  exit 0
fi

echo ">> frontmatter gate passed."
