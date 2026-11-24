#!/usr/bin/env bash
#
# gate_secret_scan_wiring.sh: prove the "Secret scan" step in gate.yml is WIRED.
#
# tests/secret_scan_gate_test.sh proves the script works. This proves the step a
# tier-a caller actually runs: it reads the step's `run:` block out of gate.yml,
# checks its `if:` and its position after the junk gate, substitutes the two
# steps.base outputs the way Actions would, and executes the block verbatim inside
# throwaway fixture repositories. A step that drifted from the script, lost its
# tier guard, or stopped refusing an empty scan turns this red. GTM-8555.
#
# Not named *_test.sh on purpose: self-test.yml runs it as its own caller-shape
# job, so the per-suite loop does not run it a second time.
#
# Fixtures are synthetic. The red case's secret-shaped line is assembled at run
# time, so no literal that the scanner (or GitHub push protection) would flag ever
# sits in this file; this repo audits itself with the same scanner.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
GATE="$ROOT/.github/workflows/gate.yml"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ssg_wiring.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

# ── Extract the step exactly as gate.yml declares it ─────────────────────────
python3 - "$GATE" "$WORK/step.tmpl" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
steps = doc["jobs"]["gate"]["steps"]
names = [s.get("name") for s in steps]
hits = [s for s in steps if s.get("name") == "Secret scan"]
if len(hits) != 1:
    sys.exit("expected exactly one 'Secret scan' step in gate.yml, found {}".format(len(hits)))
step = hits[0]
if step.get("if") != "inputs.tier == 'a'":
    sys.exit("'Secret scan' step guard is {!r}, expected \"inputs.tier == 'a'\"".format(step.get("if")))
if names.index("Secret scan") < names.index("Junk-file gate"):
    sys.exit("'Secret scan' must run after 'Junk-file gate'")
if "secret_scan_gate.sh" not in step["run"]:
    sys.exit("'Secret scan' step does not call secret_scan_gate.sh")
open(sys.argv[2], "w").write(step["run"])
PY
ok "gate.yml has one 'Secret scan' step, tier-a guarded, after the junk gate"

render() {  # render <mode> <ref> <out>
  local mode="$1" ref="$2" out="$3"
  python3 - "$WORK/step.tmpl" "$mode" "$ref" "$out" <<'PY'
import sys
t = open(sys.argv[1]).read()
t = t.replace("${{ steps.base.outputs.mode }}", sys.argv[2])
t = t.replace("${{ steps.base.outputs.ref }}", sys.argv[3])
if "${{" in t:
    sys.exit("unsubstituted expression left in the Secret scan step")
open(sys.argv[4], "w").write(t)
PY
}

# ── Fixture: a base commit every scenario branches from ──────────────────────
FX="$WORK/repo"
mkdir -p "$FX"
git -C "$FX" init -q -b main
git -C "$FX" config user.email fixture@ci.invalid
git -C "$FX" config user.name fixture
git -C "$FX" config commit.gpgsign false
# A developer's global hooks have no business running on a throwaway fixture.
git -C "$FX" config core.hooksPath /dev/null
printf 'fixture\n' > "$FX/README.md"
printf 'to be deleted\n' > "$FX/old.txt"
# The fixture repo's OWN allowlist, read by the unchanged script at run time.
printf 'allowed.txt  # fixture: allowlisted-only case\n' > "$FX/.secret-scan-allow"
git -C "$FX" add README.md old.txt .secret-scan-allow
git -C "$FX" commit -q -m base
# The step calls .ci-workflows/scripts/..., exactly as the caller checkout lays it out.
ln -s "$ROOT" "$FX/.ci-workflows"
printf '.ci-workflows\n' >> "$FX/.git/info/exclude"

secret_line() {
  local name val
  name="DEMO_FIXTURE""_KEY"
  val="Qz7Lm2Vt9Rk4""Wp6Hn8Jc3Bd5Fg"
  printf '%s = "%s"\n' "$name" "$val"
}

scenario() {  # scenario <branch> ; resets the work tree to base on a new branch
  git -C "$FX" checkout -q -B "$1" main
}

run_step() {  # run_step <mode> <ref> ; sets RC and OUT
  render "$1" "$2" "$WORK/step.sh"
  RC=0
  OUT=$(cd "$FX" && bash --noprofile --norc -eo pipefail "$WORK/step.sh" 2>&1) || RC=$?
}

expect() {  # expect <label> <want_rc: 0|nonzero> <grep fragment>
  local label="$1" want="$2" frag="$3" rc_ok=1
  if [ "$want" = "0" ] && [ "$RC" -ne 0 ]; then rc_ok=0; fi
  if [ "$want" = "nonzero" ] && [ "$RC" -eq 0 ]; then rc_ok=0; fi
  if [ "$rc_ok" -eq 1 ] && printf '%s\n' "$OUT" | grep -qF -- "$frag"; then
    ok "$label (rc=$RC)"
  else
    bad "$label (rc=$RC, wanted $want and '$frag')"
  fi
  printf '%s\n' "$OUT" | sed 's/^/       | /'
}

# RED: the head adds a line matching the generic secret-shaped assignment detector.
scenario red
secret_line > "$FX/settings.txt"
git -C "$FX" add settings.txt && git -C "$FX" commit -q -m red
run_step diff main
expect "red: secret-shaped line fails the step" nonzero "SECRET SCAN FAILED"

# GREEN: the same fixture without that line.
scenario green
printf 'harmless = "short"\n' > "$FX/settings.txt"
git -C "$FX" add settings.txt && git -C "$FX" commit -q -m green
run_step diff main
expect "green: clean head passes 1 of 1" 0 "1 of 1 path(s) checked"

# Deletion-only head: nothing left to read, so it passes.
scenario deletion
git -C "$FX" rm -q old.txt && git -C "$FX" commit -q -m delete
run_step diff main
expect "deletion-only head passes" 0 "0 of 1 path(s) checked"

# Empty diff: head is the base.
scenario empty
run_step diff main
expect "empty diff passes" 0 "0 of 0 path(s) checked"

# Image-only head: the real script reads 0 but NAMES the skip, so it is
# accounted for and passes (round 2 narrowed this from red).
scenario image
printf 'not really an image\n' > "$FX/pixel.png"
git -C "$FX" add pixel.png && git -C "$FX" commit -q -m image
run_step diff main
expect "image-only head passes, skip named by the script" 0 "0 read plus 1 named skip(s) = 1 accounted for, of 1"

# Allowlisted-only head, allowlisted in the fixture repo's own .secret-scan-allow.
scenario allowlisted
printf 'plain text\n' > "$FX/allowed.txt"
git -C "$FX" add allowed.txt && git -C "$FX" commit -q -m allowlisted
run_step diff main
expect "allowlisted-only head passes, skip named by the script" 0 "0 read plus 1 named skip(s) = 1 accounted for, of 1"

# Both skip reasons on one ">>   skipped: N a, N b" line, plus a read path, so
# the step's comma parse runs against the real script's multi-reason output.
git -C "$FX" checkout -q -B mixed allowlisted
printf 'not really an image\n' > "$FX/pixel.png"
printf 'plain text\n' > "$FX/notes.txt"
git -C "$FX" add pixel.png notes.txt && git -C "$FX" commit -q -m mixed
run_step diff main
expect "mixed head passes, two named reasons parsed" 0 "1 read plus 2 named skip(s) = 3 accounted for, of 3"

# Real script, mixed WITH a deletion: one text file, one image, one deletion.
# Exercises M == in_scope + deleted on the script's own output.
scenario mixeddel
printf 'not really an image\n' > "$FX/pixel.png"
printf 'plain text\n' > "$FX/notes.txt"
git -C "$FX" add pixel.png notes.txt
git -C "$FX" rm -q old.txt && git -C "$FX" commit -q -m mixeddel
run_step diff main
expect "mixed head with a deletion passes, M = in_scope + deleted" 0 "= 2 accounted for, of 2 non-deletion path(s) in scope; M 3 = 2 + 1 deleted"

# Audit mode (workflow_dispatch) on the clean green tree.
git -C "$FX" checkout -q green
run_step audit ""
expect "audit mode passes on a clean tree" 0 "4 of 4 path(s) checked"

# Same-PR allowlist smuggle, real script: the head adds a secret-shaped file AND
# the allowlist line that exempts it. Every count balances, so only the
# allowlist refusal can catch it.
scenario allowsmuggle
secret_line > "$FX/settings.txt"
printf 'settings.txt  # fixture: smuggled exemption\n' >> "$FX/.secret-scan-allow"
git -C "$FX" add settings.txt .secret-scan-allow && git -C "$FX" commit -q -m allowsmuggle
run_step diff main
expect "allowlist change that exempts a path in the same diff is refused" nonzero "this PR changes .secret-scan-allow and the scan skipped 1 path(s) as allowlisted"

# Allowlist-only change, real script: a line for a path NOT in the diff, so
# nothing in the diff is skipped as allowlisted.
scenario allowonly
printf 'unrelated.txt  # fixture: path not in this diff\n' >> "$FX/.secret-scan-allow"
git -C "$FX" add .secret-scan-allow && git -C "$FX" commit -q -m allowonly
run_step diff main
expect "allowlist-only change with no allowlisted skip passes" 0 "1 read plus 0 named skip(s) = 1 accounted for, of 1"

# ── Stubbed script: output that under-counts, without touching the real one ──
STUB="$WORK/stub"
mkdir -p "$STUB/scripts"
use_stub() {  # use_stub <stdout of the stubbed secret_scan_gate.sh>
  printf '#!/usr/bin/env bash\ncat <<'"'"'OUT'"'"'\n%s\nOUT\n' "$1" > "$STUB/scripts/secret_scan_gate.sh"
  ln -sfn "$STUB" "$FX/.ci-workflows"
}
use_real() { ln -sfn "$ROOT" "$FX/.ci-workflows"; }

# A text path the script neither read nor named a reason for.
scenario unaccounted
printf 'plain text\n' > "$FX/notes.txt"
git -C "$FX" add notes.txt && git -C "$FX" commit -q -m unaccounted
use_stub ">> secret scan passed. 0 of 1 path(s) checked, mode=diff."
run_step diff main
expect "stub: an unaccounted text path is refused" nonzero "accounted for 0 (0 read, 0 skipped with a reason) of 1"

# A deletion must not cover for an unread changed path.
git -C "$FX" rm -q old.txt && git -C "$FX" commit -q -m "plus a deletion"
use_stub ">> secret scan passed. 0 of 2 path(s) checked, mode=diff.
>>   skipped: 1 deleted"
run_step diff main
expect "stub: a deletion skip does not cover an unread path" nonzero "accounted for 0 (0 read, 0 skipped with a reason) of 1"

# No summary line at all.
use_stub ">> secret scan skipped: no python3"
run_step diff main
expect "stub: a missing summary line is refused" nonzero "coverage is unknown"

# Over-count: two changed paths, a summary claiming more skips than exist.
# M is consistent (2 = 2 + 0), so only the equality check can catch it.
scenario overcount
printf 'one\n' > "$FX/a.txt"
printf 'two\n' > "$FX/b.txt"
git -C "$FX" add a.txt b.txt && git -C "$FX" commit -q -m overcount
use_stub ">> secret scan passed. 0 of 2 path(s) checked, mode=diff.
>>   skipped: 3 encrypted or binary file type"
run_step diff main
expect "stub: skips above in_scope (over-count) are refused" nonzero "over-count: accounted for 3 (0 read, 3 skipped with a reason) but only 2"

# M mismatch: coverage matches (1 read of 1), but the script's M does not.
scenario mmismatch
printf 'plain text\n' > "$FX/notes.txt"
git -C "$FX" add notes.txt && git -C "$FX" commit -q -m mmismatch
use_stub ">> secret scan passed. 1 of 5 path(s) checked, mode=diff."
run_step diff main
expect "stub: an M that is not in_scope + deleted is refused" nonzero "M mismatch: the script says 5 path(s) in scope, but this step counts 1 non-deletion plus 0 deleted = 1"
use_real

echo ""
echo "gate secret-scan wiring: ${pass} passed, ${fail} failed, of $((pass + fail))."
[ "$fail" -eq 0 ]
