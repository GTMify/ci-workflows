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
    -h|--help) sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "secret_scan_gate: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

command -v python3 >/dev/null 2>&1 || { echo ">> secret scan skipped: no python3" >&2; exit 0; }

case "$MODE" in
  staged) PATHS=$(git diff --cached --name-only --diff-filter=ACM) ;;
  audit)  PATHS=$(git ls-files) ;;
  diff)
    if [ -z "$BASE" ]; then
      BASE=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo "origin/main")
    fi
    PATHS=$(git diff --name-only --diff-filter=ACM "$BASE"...HEAD 2>/dev/null || git ls-files)
    ;;
esac

if [ -z "$PATHS" ]; then
  echo ">> secret scan passed. 0 path(s) checked, mode=$MODE."
  exit 0
fi

SSG_LIST=$(mktemp -t ssg_paths)
printf '%s\n' "$PATHS" > "$SSG_LIST"
trap 'rm -f "$SSG_LIST"' EXIT
export SSG_LIST SSG_MODE="$MODE"

python3 - <<'PY'
import os, re, subprocess, sys, pathlib

mode = os.environ.get("SSG_MODE", "staged")
paths = [p for p in pathlib.Path(os.environ["SSG_LIST"]).read_text().split("\n") if p.strip()]

# ── ALLOWLIST ────────────────────────────────────────────────────────────────
# sops-encrypted files hold ciphertext by design; scanning them is pure noise.
SKIP_SUFFIX = (".sops", ".sops.yaml", ".sops.yml", ".age", ".bundle", ".pack",
               ".png", ".jpg", ".jpeg", ".gif", ".pdf", ".zip", ".gz", ".tar",
               ".woff", ".woff2", ".ico", ".mp4", ".mov")
SKIP_DIRS = ("node_modules/", ".git/", "vendor/", "dist/", "build/")

# Per-repo escape hatch: one path per line in .secret-scan-allow, reason after "#".
allow = set()
ap = pathlib.Path(".secret-scan-allow")
if ap.is_file():
    for line in ap.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            allow.add(line)

# Things that look like secrets but are not.
PLACEHOLDER = re.compile(
    r"(REDACTED|EXAMPLE|PLACEHOLDER|CHANGEME|CHANGE_ME|YOUR[_-]|<[^>]{2,}>|xxxx|XXXX|\.\.\.|"
    r"dummy|sample|test[_-]?only|FAKE|NOT[_-]?REAL)", re.I)

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
    ("secret-shaped assignment",
     re.compile(r"""['"]?[A-Z][A-Z0-9_]{2,}_(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|PAT|CREDENTIAL)S?['"]?"""
                r"""\s*[:=]\s*['"]?[A-Za-z0-9_\-.]{20,}""")),
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
for p in paths:
    if p in allow:
        continue
    if p.endswith(SKIP_SUFFIX):
        continue
    if any(p.startswith(d) or ("/" + d) in p for d in SKIP_DIRS):
        continue
    blob = content_of(p)
    if not blob or b"\x00" in blob[:8000]:
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
    sys.exit(1)

extra = "" if env_vals else " (value layer unavailable: no local env file)"
print(">> secret scan passed. {} path(s) checked, mode={}{}.".format(checked, mode, extra))
sys.exit(0)
PY
