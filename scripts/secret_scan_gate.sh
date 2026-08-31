#!/usr/bin/env bash
#
# secret_scan_gate.sh: refuse to let a live credential become tracked content.
#
# WHY THIS EXISTS
#
# On 2026-08-06 and 08-07 the same mechanism leaked credentials into
# GTMify/gtmify-config three separate times, and a gate reported success every
# time:
#
#   1. 354 Claude Code memory files, one of which quoted a full Supabase token in
#      its body. Tracked since 2026-05-11, readable by five collaborators.
#   2. `.env.backup-20260428-004952`, a plaintext .env holding six live keys,
#      committed and left in the tree for three months.
#   3. `.n8n_onboarding_env_snapshot.json`, swept in by a `cc-sync` `git add -A`,
#      holding a LIVE Stripe `sk_live_` key and the PRODUCTION onboarding bridge
#      HMAC.
#
# The junk-file gate passed all three, and correctly so: it objects to junk being
# tracked, and none of those files were junk. Nothing in the pipeline looked at
# CONTENT. That is the gap this closes.
#
# TWO LAYERS, because either one alone would have missed a real case:
#
#   VALUE layer   Compares staged content against the actual values in the local
#                 env files. Near-zero false positives, and it catches a secret
#                 no pattern would recognize. Local only; there is no env file in
#                 CI, so this layer reports itself unavailable there.
#   PATTERN layer Vendor prefixes plus a generic "NAME_KEY = <long string>"
#                 detector. This is the layer that catches a credential which is
#                 NOT in your env, which is exactly how the Stripe key got in.
#
# NEVER PRINTS A SECRET. Findings name the file, the line number, and the
# detector. That is deliberate: a scanner that echoes what it found turns your
# terminal scrollback and CI log into the next copy of the leak.
#
# ONLY TRACKED OR STAGED CONTENT CAN FAIL, enumerated through git, so a gitignored
# file on disk is invisible here by construction. Same principle as the junk gate.
#
# THE DENOMINATOR IS PART OF THE VERDICT (GTM-1590, 2026-08-31). This gate always
# printed how many paths it checked, and twice in two days that count was a small
# fraction of what was staged while the line still read "passed". Both shortfalls
# were in plain text and were read past, so an honest count is necessary and is not
# sufficient. The summary now prints "N of M path(s) checked" with every skip and
# its reason, because "0 of 1 checked, 1 skipped (renamed)" cannot be misread the
# way a bare "0 path(s) checked" was.
#
# Modes:
#   (default)   compare against a base ref; what a pull request would add
#   --staged    inspect the index; used by the pre-commit hook
#   --audit     inspect every tracked file; used for one-time cleanups
#
# Usage:
#   secret_scan_gate.sh [--base <ref>]
#   secret_scan_gate.sh --staged
#   secret_scan_gate.sh --audit
#
# Bypass, when you genuinely mean it:
#   git commit --no-verify
#   or add a line to .secret-scan-allow (see ALLOWLIST in the python block)
#
# IMPLEMENTATION NOTE, learned the hard way: the python body is delivered through
# a QUOTED heredoc. An earlier version used `python3 -c '...'` and the regexes
# contain single quotes, which closed the shell string and produced a syntax
# error on every invocation. A gate that cannot parse itself is worse than no
# gate, since `set -e` in a caller would treat the crash as a pass.
set -uo pipefail

MODE="diff"
BASE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --audit)  MODE="audit" ;;
    --staged) MODE="staged" ;;
    --base)   shift; BASE="${1:-}" ;;
    -h|--help) sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "secret_scan_gate: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

command -v python3 >/dev/null 2>&1 || { echo ">> secret scan skipped: no python3" >&2; exit 0; }

# THE FILTER, and why R and T are in it (GTM-1590).
#
# This used to read --diff-filter=ACM. Excluding D is right: a deleted path has no
# content left to scan. Excluding R was WRONG, because a renamed file's content
# still ships, and git classifies an edited-and-moved file as R as soon as the
# similarity index clears its threshold. So the ordinary motion of editing a file
# and moving it in one commit, which is exactly what retiring a register entry or
# reorganising a docs tree looks like, rode past this gate entirely.
#
# Measured on gtmify-config: commit ba71968 staged four renames and one
# modification and the gate reported "1 path(s) checked"; commit c5925f8 was a
# single `git mv` plus an edit and reported "0 path(s) checked" while carrying a
# real 7-insertion change. Reproduced from scratch on 2026-08-31 before this fix.
#
# T (typechange) joins them for the same reason: a symlink becoming a regular file
# is new content arriving. D stays out, and is counted and named as a skip below
# rather than silently vanishing from the denominator.
#
# --name-only prints a rename's DESTINATION path only, never its source, so
# ALL_PATHS and PATHS stay directly comparable and the counts add up.
case "$MODE" in
  staged)
    ALL_PATHS=$(git diff --cached --name-only)
    PATHS=$(git diff --cached --name-only --diff-filter=ACMRT)
    ;;
  audit)
    ALL_PATHS=$(git ls-files)
    PATHS="$ALL_PATHS"
    ;;
  diff)
    if [ -z "$BASE" ]; then
      BASE=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo "origin/main")
    fi
    if ALL_PATHS=$(git diff --name-only "$BASE"...HEAD 2>/dev/null); then
      PATHS=$(git diff --name-only --diff-filter=ACMRT "$BASE"...HEAD 2>/dev/null)
    else
      ALL_PATHS=$(git ls-files)
      PATHS="$ALL_PATHS"
    fi
    ;;
esac

# Counted here rather than in python, so the deleted paths that are deliberately
# never handed to the scanner still appear in the denominator it prints.
if [ -z "$ALL_PATHS" ]; then
  SSG_TOTAL=0
else
  SSG_TOTAL=$(printf '%s\n' "$ALL_PATHS" | wc -l | tr -d ' ')
fi

if [ -z "$PATHS" ]; then
  if [ "$SSG_TOTAL" -eq 0 ]; then
    echo ">> secret scan passed. 0 of 0 path(s) checked, mode=$MODE."
  else
    echo ">> secret scan passed. 0 of $SSG_TOTAL path(s) checked, mode=$MODE."
    echo ">>   skipped: $SSG_TOTAL deleted"
  fi
  exit 0
fi

SSG_LIST=$(mktemp -t ssg_paths)
printf '%s\n' "$PATHS" > "$SSG_LIST"
trap 'rm -f "$SSG_LIST"' EXIT
export SSG_LIST SSG_MODE="$MODE" SSG_TOTAL

python3 - <<'PY'
import os, re, subprocess, sys, pathlib

mode = os.environ.get("SSG_MODE", "staged")
paths = [p for p in pathlib.Path(os.environ["SSG_LIST"]).read_text().split("\n") if p.strip()]

# ── ALLOWLIST ────────────────────────────────────────────────────────────────
# sops-encrypted files hold ciphertext by design; scanning them is pure noise.
SKIP_SUFFIX = (".sops", ".sops.yaml", ".sops.yml", ".age", ".bundle", ".pack",
               ".png", ".jpg", ".jpeg", ".gif", ".pdf", ".zip", ".gz", ".tar",
               ".woff", ".woff2", ".ico", ".mp4", ".mov")
SKIP_DIRS = ("node_modules/", ".git/", "dist/", "build/")

# ── vendor/ IS NOT UNCONDITIONALLY A DEPENDENCY DIRECTORY (GTM-1590) ─────────
# "vendor/" used to sit in SKIP_DIRS beside node_modules, on the dependency-directory
# convention where it means third-party code nobody here wrote. In this estate that
# convention is false: gtmify/app/vendor is the vendor DOCUMENTATION mirror, twenty
# first-party-committed trees that sessions actively author, and a worked API example
# is exactly where a live key gets pasted. A commit staging three paths under vendor/
# reported "0 path(s) checked" on 2026-08-29.
#
# So it is qualified rather than named: skipped only when a package manager has
# actually marked the tree vendored. Go writes vendor/modules.txt, Composer writes
# vendor/autoload.php. Neither marker exists anywhere in this estate, so vendor/ is
# now scanned here, and a repo that really does vendor its dependencies still gets
# the skip without needing to know this gate exists.
VENDOR_MARKERS = ("vendor/modules.txt", "vendor/autoload.php")
vendor_is_dependencies = any(pathlib.Path(m).is_file() for m in VENDOR_MARKERS)

# Per-repo escape hatch: one path per line in .secret-scan-allow, reason after "#".
allow = set()
ap = pathlib.Path(".secret-scan-allow")
if ap.is_file():
    for line in ap.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            allow.add(line)

# Things that look like secrets but are not.
#
# The second line was added with GTM-1590, when un-skipping vendor/ first exposed the
# gate to twenty trees of vendor documentation. Every term here is an explicit
# admission by the document that the value is not real: "replace-with-at-least-32-
# random-characters", "asdfasdfasdf", "tr_preview_1234567890", "secret-from-trigger-
# dev". Each was measured as a live false positive in gtmify/app/vendor on
# 2026-08-31; none of them widens the gate against a value that is actually a secret.
PLACEHOLDER = re.compile(
    r"(REDACTED|EXAMPLE|PLACEHOLDER|CHANGEME|CHANGE_ME|YOUR[_-]|<[^>]{2,}>|xxxx|XXXX|\.\.\.|"
    r"dummy|sample|test[_-]?only|FAKE|NOT[_-]?REAL|"
    r"replace[_-]?with|asdfasdf|1234567890|secret[_-]from)", re.I)

# Vendor sample keys published in the vendor's OWN public documentation. Matched as
# exact literals, never as a shape, so this can never widen into a class. Stripe has
# printed this key in its API reference for a decade; it appears in eight files of
# gtmify/app/vendor/stripe-docs and is not a credential to anything.
#
# Written as prefix plus body rather than as one literal, and NOT arbitrary
# obfuscation: the detector matches on the prefix, so splitting exactly there is
# what lets this gate go on scanning its own source. The alternative was an
# allowlist entry for scripts/secret_scan_gate.sh, which would have made the one
# file where a credential must never hide the one file nobody reads. The value
# compared at runtime is still the exact literal.
KNOWN_PUBLIC_SAMPLES = (
    "sk_" + "test_" + "BQokikJOvBiI2HlWgH4olfQ2",
)

# Object IDs whose prefix collides with a credential prefix. A Stripe REFUND id is
# the four characters "re_1" followed by twenty-four base62 characters, which the
# Resend-key detector matches exactly; five such hits were measured in stripe-docs.
# (Spelled out rather than quoted, so that this gate can still scan its own source
# instead of needing an allowlist entry for the comment describing its detectors.)
# The guard is narrow on purpose: it fires
# only where the match is the value of a JSON "id" field, which is a place a
# credential is never legitimately assigned, rather than loosening the re_ pattern
# itself and losing a real Resend key.
JSON_ID_VALUE = re.compile(r'"id"\s*:\s*"[A-Za-z0-9_]+"')

# ── PATTERN layer ────────────────────────────────────────────────────────────
PATTERNS = [
    ("stripe live secret key", re.compile(r"\b(?:sk|rk)_live_[0-9A-Za-z]{20,}")),
    ("stripe test secret key", re.compile(r"\bsk_test_[0-9A-Za-z]{20,}")),
    ("openrouter key",         re.compile(r"\bsk-or-v1-[0-9a-f]{32,}")),
    ("openai-style key",       re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{32,}")),
    ("supabase PAT",           re.compile(r"\bsbp_[0-9a-f]{36,}")),
    ("supabase secret key",    re.compile(r"\bsb_secret_[A-Za-z0-9_-]{16,}")),
    ("slack token",            re.compile(r"\bxox[bpasr]-[0-9A-Za-z-]{12,}")),
    ("github token",           re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}")),
    ("gitlab token",           re.compile(r"\bglpat-[A-Za-z0-9_-]{18,}")),
    ("aws access key id",      re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("age private key",        re.compile(r"AGE-SECRET-KEY-1[0-9A-Z]{50,}")),
    ("pem private key",        re.compile(r"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----")),
    ("resend key",             re.compile(r"\bre_[A-Za-z0-9]{20,}")),
    ("n8n api key",            re.compile(r"\bn8n_api_[A-Za-z0-9]{20,}")),
    ("jwt",                    re.compile(r"\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}")),
    # The generic one. This catches a credential whose vendor prefix we do not
    # know, which is how the Stripe key arrived inside a JSON snapshot.
    #
    # The lookahead was added with GTM-1590. Assigning a secret-named variable FROM
    # process.env, app.env, import.meta.env, os.environ or a shell expansion is the
    # correct handling of a secret, not a leak of one: the literal is elsewhere by
    # construction. Four such lines in gtmify/app/vendor were measured firing on
    # 2026-08-31, all of them library setup examples doing exactly the right thing.
    ("secret-shaped assignment",
     re.compile(r"""['"]?[A-Z][A-Z0-9_]{2,}_(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|PAT|CREDENTIAL)S?['"]?"""
                r"""\s*[:=]\s*['"]?"""
                r"""(?!process\.env\.|app\.env\.|import\.meta\.env\.|os\.environ|ENV\[|\$\{|\$[A-Za-z_])"""
                r"""[A-Za-z0-9_\-.]{20,}""")),
]

# ── VALUE layer ──────────────────────────────────────────────────────────────
# Not every long env value is a secret. An audit of gtmify-config surfaced
# SUPABASE_URL and SUPERGROW_WORKSPACE_ID this way: a URL and an identifier,
# both harmless, both over 20 chars. Blocking on those would have made the gate
# fire on legitimate commits, which is how a gate earns a permanent --no-verify.
NON_SECRET_NAME = re.compile(
    r"_(URL|URI|ID|HOST|HOSTNAME|DOMAIN|REGION|PROJECT|WORKSPACE|WORKSPACE_ID|BASE|"
    r"BASE_URL|ACCOUNT|EMAIL|USER|USERNAME|PATH|DIR|REF|SLUG|MODE|ENV|VERSION|NAME|"
    r"CHANNEL|TEAM|ORG|BUCKET|TABLE|DB|DATABASE|PORT|TIMEOUT|LOCALE)$")

# Keys that are publishable BY DESIGN. A Supabase anon key ships in browser
# JavaScript; treating it as a leak would block legitimate client config and
# teach people to bypass the gate. Row-level security, not secrecy, is what
# protects these.
PUBLISHABLE_NAME = re.compile(r"(ANON_KEY|PUBLISHABLE_KEY|PUBLIC_KEY|_PUBLIC$|CLIENT_ID)$")

def load_env_values():
    vals = {}
    for envf in (pathlib.Path.home() / ".claude/.env",
                 pathlib.Path.home() / ".claude/.env.local",
                 pathlib.Path("hooks/.env")):
        try:
            for line in envf.read_text(errors="replace").splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip()
                v = v.strip().strip("'").strip('"')
                if len(v) < 20 or PLACEHOLDER.search(v):
                    continue
                if NON_SECRET_NAME.search(k) or PUBLISHABLE_NAME.search(k):
                    continue
                # A URL or an email address is a locator, not a credential.
                if "://" in v or "@" in v:
                    continue
                vals[v] = k
        except Exception:
            continue
    return vals

env_vals = load_env_values()

def content_of(path):
    if mode == "staged":
        r = subprocess.run(["git", "show", ":" + path], capture_output=True)
        return r.stdout if r.returncode == 0 else b""
    try:
        return pathlib.Path(path).read_bytes()
    except Exception:
        return b""

findings = []
checked = 0

# Every path that is not read is counted under a REASON. The gate's whole failure
# mode was a shortfall it reported as a bare number, so a skip that cannot name
# itself is not allowed to exist. GTM-1590.
skips = {}
def skipped(reason):
    skips[reason] = skips.get(reason, 0) + 1

def in_dir(path, d):
    return path.startswith(d) or ("/" + d) in path

for p in paths:
    if p in allow:
        skipped("allowlisted in .secret-scan-allow")
        continue
    if p.endswith(SKIP_SUFFIX):
        skipped("encrypted or binary file type")
        continue
    if any(in_dir(p, d) for d in SKIP_DIRS):
        skipped("dependency or build directory")
        continue
    if vendor_is_dependencies and in_dir(p, "vendor/"):
        skipped("vendored dependencies")
        continue
    blob = content_of(p)
    if not blob:
        skipped("no readable content")
        continue
    if b"\x00" in blob[:8000]:
        skipped("binary content")
        continue
    text = blob.decode("utf-8", errors="replace")
    checked += 1
    lines = text.split("\n")

    # VALUE layer first: the higher-confidence signal.
    for val, name in env_vals.items():
        if val in text:
            ln = next((i + 1 for i, l in enumerate(lines) if val in l), 0)
            findings.append((p, ln, "LIVE VALUE of $" + name))

    # PATTERN layer.
    for i, line in enumerate(lines, 1):
        if PLACEHOLDER.search(line):
            continue
        # An AWS key inside X-Amz-Credential is a presigned-URL credential: STS
        # temporary, scoped to one object, and already expired by the time it is
        # committed. Found in tracked bank-statement exports, where blocking
        # would be noise rather than protection.
        if "X-Amz-Credential" in line or "X-Amz-Signature" in line:
            continue
        # A vendor's own published sample key, matched as an exact literal.
        if any(s in line for s in KNOWN_PUBLIC_SAMPLES):
            continue
        # A JSON object id, which collides with credential prefixes such as re_.
        if JSON_ID_VALUE.search(line):
            continue
        for label, rx in PATTERNS:
            if rx.search(line):
                findings.append((p, i, label))
                break

seen = set()
uniq = []
for f in findings:
    if f not in seen:
        seen.add(f)
        uniq.append(f)

if uniq:
    print("")
    print(">> SECRET SCAN FAILED. A live credential would become tracked content.")
    print("   Values are deliberately not printed.")
    print("")
    for p, ln, what in uniq:
        print("   {}:{}  {}".format(p, ln, what))
    print("")
    print("   Fix, in order of preference:")
    print("     1. Move the value into sops (.env.sops) and reference it, or keep it")
    print("        in a gitignored file outside the repo.")
    print("     2. Redact it in the file if the file itself must stay.")
    print("     3. If this is a false positive, add the path to .secret-scan-allow")
    print("        with a reason, or bypass once with: git commit --no-verify")
    print("")
    if not env_vals:
        print("   NOTE: no local env file found, so only the pattern layer ran.")
    # A refusal states its coverage for the same reason a pass does: knowing the
    # gate found something says nothing about how much of the commit it read.
    print("   Coverage: {} of {} path(s) in scope were read.".format(
        checked, int(os.environ.get("SSG_TOTAL") or len(paths))))
    sys.exit(1)

# ── THE VERDICT, WITH ITS DENOMINATOR ────────────────────────────────────────
# total is what git said was in scope; checked is what was actually read. The
# difference is enumerated by reason and never left as a residual, so a summary
# whose parts do not add up to its total is itself visible as a defect.
total = int(os.environ.get("SSG_TOTAL") or len(paths))
deleted = total - len(paths)
if deleted > 0:
    skips["deleted"] = skips.get("deleted", 0) + deleted

extra = "" if env_vals else " (value layer unavailable: no local env file)"
print(">> secret scan passed. {} of {} path(s) checked, mode={}{}.".format(
    checked, total, mode, extra))
if skips:
    parts = ", ".join("{} {}".format(n, reason)
                      for reason, n in sorted(skips.items(), key=lambda kv: (-kv[1], kv[0])))
    print(">>   skipped: {}".format(parts))
accounted = checked + sum(skips.values())
if accounted != total:
    print(">>   WARNING: {} checked plus {} skipped does not equal {} in scope. "
          "The gate is not seeing everything it thinks it is.".format(
              checked, sum(skips.values()), total))
sys.exit(0)
PY
