#!/usr/bin/env bash
#
# Tests for scripts/secret_scan_gate.sh.
#
# One throwaway git repo per scenario, dirty in exactly one way, asserting the
# gate's exit code and, where the point of the test is the verdict's denominator,
# its summary line too. Same shape as tests/junk_file_gate_test.sh.
#
# THE TWO CASES THAT MATTER MOST are `rename_plus_edit_is_scanned` and
# `vendor_path_is_scanned`. Both were measured passing before GTM-1590, on real
# commits in gtmify-config and gtmify/app, and a credential gate that reports
# success while reading none of the commit is worse than no gate at all: it is a
# green check that people rely on.
#
# THE COUNTERWEIGHT CASES MATTER JUST AS MUCH. A scanner that refuses everything
# gets a permanent --no-verify within a day and then protects nothing, so the
# false-positive classes measured in gtmify/app/vendor when vendor/ was first
# un-skipped are pinned here as MUST PASS: a vendor's published sample key, a
# Stripe object id whose prefix collides with a Resend key, a secret-named
# variable assigned from process.env, and documented placeholder values.
#
# NO REAL CREDENTIAL APPEARS IN THIS FILE. Every value below is a synthetic
# string chosen to match a detector's SHAPE and nothing else.
#
# Usage: tests/secret_scan_gate_test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/../scripts/secret_scan_gate.sh"
[ -f "$GATE" ] || { echo "cannot find $GATE" >&2; exit 2; }

# Shapes only. AKIA plus sixteen uppercase alphanumerics is the AWS access key id
# shape; "SYNTHETIC" is deliberately in the middle so nobody mistakes it for one.
FAKE_AWS="AKIAZZZZSYNTHETIC999"

pass_count=0
fail_count=0

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

# check <name> <expect: fail|pass> <repo-dir> [expected substring of the output]
check() {
  local name="$1" expect="$2" d="$3" want="${4:-}" rc=0 out got
  out="$(cd "$d" && bash "$GATE" --staged 2>&1)" || rc=$?
  got="pass"
  [ "$rc" -ne 0 ] && got="fail"
  if [ "$got" != "$expect" ]; then
    printf '  FAIL  %-42s expected %-4s got %s\n' "$name" "$expect" "$got"
    printf '%s\n' "$out" | sed 's/^/          /'
    fail_count=$((fail_count + 1))
    rm -rf "$d"
    return
  fi
  if [ -n "$want" ] && ! printf '%s' "$out" | grep -qF -- "$want"; then
    printf '  FAIL  %-42s expected output to contain: %s\n' "$name" "$want"
    printf '%s\n' "$out" | sed 's/^/          /'
    fail_count=$((fail_count + 1))
    rm -rf "$d"
    return
  fi
  printf '  ok    %-42s expected %-4s got %s\n' "$name" "$expect" "$got"
  pass_count=$((pass_count + 1))
  rm -rf "$d"
}

# commit_file <repo> <path> <content>: land a file so a later change can modify it
commit_file() {
  local d="$1" p="$2"
  mkdir -p "$d/$(dirname "$p")"
  printf '%s\n' "$3" > "$d/$p"
  git -C "$d" add -Af -- "$p" >/dev/null 2>&1
  git -C "$d" commit -qm "add $p" >/dev/null 2>&1
}

# stage_file <repo> <path> <content>
stage_file() {
  local d="$1" p="$2"
  mkdir -p "$d/$(dirname "$p")"
  printf '%s\n' "$3" > "$d/$p"
  git -C "$d" add -Af -- "$p" >/dev/null 2>&1
}

echo "== GTM-1590 cause 1: a renamed file is content that still ships =="

# The regression. Before the fix this printed "0 path(s) checked" and passed,
# because --diff-filter=ACM excluded R and git classifies an edited-and-moved
# file as R once similarity clears the threshold.
d="$(new_repo)"
commit_file "$d" "notes.md" "$(printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight')"
git -C "$d" mv notes.md notes_renamed.md >/dev/null 2>&1
printf 'SOME_API_TOKEN = %s\n' "$FAKE_AWS" >> "$d/notes_renamed.md"
git -C "$d" add -A >/dev/null 2>&1
check "rename_plus_edit_is_scanned" fail "$d" "aws access key id"

# A pure rename with no edit carries no new content, but is still READ rather
# than skipped, so the denominator does not quietly shrink.
d="$(new_repo)"
commit_file "$d" "notes.md" "nothing secret here"
git -C "$d" mv notes.md moved.md >/dev/null 2>&1
git -C "$d" add -A >/dev/null 2>&1
check "pure_rename_is_still_counted" pass "$d" "1 of 1 path(s) checked"

echo
echo "== GTM-1590 cause 2: vendor/ is first-party content in this estate =="

d="$(new_repo)"
stage_file "$d" "vendor/acme-docs/api.md" "SOME_API_TOKEN = $FAKE_AWS"
check "vendor_path_is_scanned" fail "$d" "aws access key id"

# ...unless a package manager actually marked the tree vendored.
d="$(new_repo)"
stage_file "$d" "vendor/modules.txt" "# github.com/acme/thing v1.0.0"
stage_file "$d" "vendor/acme/thing/client.go" "SOME_API_TOKEN = $FAKE_AWS"
check "go_vendored_deps_are_skipped" pass "$d" "vendored dependencies"

d="$(new_repo)"
stage_file "$d" "vendor/autoload.php" "<?php // composer"
stage_file "$d" "vendor/acme/thing.php" "SOME_API_TOKEN = $FAKE_AWS"
check "composer_vendored_deps_are_skipped" pass "$d" "vendored dependencies"

echo
echo "== the verdict states its denominator and the parts add up =="

d="$(new_repo)"
commit_file "$d" "doomed.md" "goes away"
git -C "$d" rm -q doomed.md >/dev/null 2>&1
stage_file "$d" "src/feature.js" "ordinary work"
stage_file "$d" "node_modules/dep.js" "SOME_API_TOKEN = $FAKE_AWS"
stage_file "$d" "logo.png" "not really a png"
check "summary_counts_every_staged_path" pass "$d" "1 of 4 path(s) checked"

d="$(new_repo)"
commit_file "$d" "doomed.md" "goes away"
git -C "$d" rm -q doomed.md >/dev/null 2>&1
stage_file "$d" "src/feature.js" "ordinary work"
stage_file "$d" "node_modules/dep.js" "SOME_API_TOKEN = $FAKE_AWS"
stage_file "$d" "logo.png" "not really a png"
check "summary_names_every_skip_reason" pass "$d" "skipped: 1 deleted, 1 dependency or build directory, 1 encrypted or binary file type"

# A commit that only deletes reads nothing, and must say so rather than printing
# a bare zero indistinguishable from a clean scan.
d="$(new_repo)"
commit_file "$d" "doomed.md" "goes away"
git -C "$d" rm -q doomed.md >/dev/null 2>&1
check "delete_only_commit_reports_its_zero" pass "$d" "0 of 1 path(s) checked"

# The gate must never report success without stating coverage, even on refusal.
d="$(new_repo)"
stage_file "$d" "src/leak.js" "SOME_API_TOKEN = $FAKE_AWS"
check "refusal_states_coverage" fail "$d" "Coverage: 1 of 1 path(s) in scope were read."

echo
echo "== detectors still fire on ordinary adds and modifications =="

d="$(new_repo)"
stage_file "$d" "src/leak.js" "SOME_API_TOKEN = $FAKE_AWS"
check "added_file_with_secret" fail "$d" "aws access key id"

d="$(new_repo)"
commit_file "$d" "src/cfg.js" "nothing here yet"
printf 'SOME_API_TOKEN = %s\n' "$FAKE_AWS" >> "$d/src/cfg.js"
git -C "$d" add -A >/dev/null 2>&1
check "modified_file_with_secret" fail "$d" "aws access key id"

d="$(new_repo)"
stage_file "$d" "src/key.pem" "-----BEGIN RSA PRIVATE KEY-----"
check "pem_private_key_header" fail "$d" "pem private key"

echo
echo "== existing legitimate skips still skip, asserted by COUNT not by silence =="

d="$(new_repo)"
stage_file "$d" "node_modules/dep.js" "SOME_API_TOKEN = $FAKE_AWS"
check "node_modules_skipped" pass "$d" "0 of 1 path(s) checked"

d="$(new_repo)"
stage_file "$d" "dist/bundle.js" "SOME_API_TOKEN = $FAKE_AWS"
check "dist_skipped" pass "$d" "1 dependency or build directory"

d="$(new_repo)"
stage_file "$d" "secrets.sops" "SOME_API_TOKEN = $FAKE_AWS"
check "sops_file_skipped" pass "$d" "1 encrypted or binary file type"

d="$(new_repo)"
stage_file "$d" ".secret-scan-allow" "config/known.js  # reviewed 2026-08-31"
stage_file "$d" "config/known.js" "SOME_API_TOKEN = $FAKE_AWS"
check "allowlisted_path_skipped" pass "$d" "1 allowlisted in .secret-scan-allow"

echo
echo "== false-positive classes measured in gtmify/app/vendor, all MUST PASS =="

# Stripe has printed this key in its own public API reference for years. It
# appears in eight files of vendor/stripe-docs and is a credential to nothing.
#
# Assembled from parts rather than written as one literal, for the same reason
# the gate assembles it: GitHub push protection refuses a push containing the
# whole string, which is a good rule and not one to click through. The fixture
# written to the throwaway repo below is the exact literal, so the assertion is
# unchanged; only this source file avoids carrying it.
STRIPE_DOC_KEY="sk_""test_""BQokikJOvBiI2HlWgH4olfQ2"
d="$(new_repo)"
stage_file "$d" "vendor/stripe-docs/auth.md" "  -u ${STRIPE_DOC_KEY}:"
check "vendor_published_sample_key" pass "$d" "1 of 1 path(s) checked"

# A Stripe REFUND id, which the Resend re_ detector matches exactly. Five of
# these were measured in vendor/stripe-docs.
d="$(new_repo)"
stage_file "$d" "vendor/stripe-docs/refund.md" '  "id": "re_1Nispe2eZvKYlo2Cd31jOCgZ",'
check "json_object_id_is_not_a_key" pass "$d" "1 of 1 path(s) checked"

# Reading a secret FROM the environment is the correct handling of a secret.
d="$(new_repo)"
stage_file "$d" "vendor/acme-docs/setup.md" "const REVALIDATION_SECRET = process.env.REVALIDATION_SECRET_VALUE"
check "assignment_from_process_env" pass "$d" "1 of 1 path(s) checked"

d="$(new_repo)"
stage_file "$d" "vendor/acme-docs/env.md" "POSTGRES_PASSWORD=replace-with-at-least-32-random-characters"
check "documented_placeholder_value" pass "$d" "1 of 1 path(s) checked"

d="$(new_repo)"
stage_file "$d" "vendor/acme-docs/env2.md" 'TRIGGER_SECRET_KEY="tr_preview_1234567890"'
check "numeric_placeholder_value" pass "$d" "1 of 1 path(s) checked"

echo
echo "== a clean commit passes, which is the whole point of the counterweight =="

d="$(new_repo)"
stage_file "$d" "src/feature.js" "export const add = (a, b) => a + b;"
stage_file "$d" "vendor/acme-docs/README.md" "How to call the Acme API."
check "ordinary_clean_commit" pass "$d" "2 of 2 path(s) checked"

echo
echo "════════════════════════════════════════"
echo "  ${pass_count} passed, ${fail_count} failed"
echo "════════════════════════════════════════"
[ "$fail_count" -eq 0 ] || exit 1
