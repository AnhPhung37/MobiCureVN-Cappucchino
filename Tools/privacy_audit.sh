#!/usr/bin/env bash
# Evidence for success criterion #1: "100% of data processing must occur locally;
# zero calls to external commercial LLM APIs."
#
# Scans the Swift sources for every outbound-network affordance and classifies it.
# The point is not to print "clean" -- the app DOES reach the network to download
# model weights, and a report that hid that would be worthless. The point is to
# enumerate every egress path so the claim being made is exact:
#
#   patient data never leaves the device; no inference call ever leaves the device;
#   the only egress is a one-time asset download of open-weight models.
#
# Usage: Tools/privacy_audit.sh [--json]

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SRC_DIRS=(App MobiCureVNTests MobiCureVNUITests)
JSON_MODE=0
[[ "${1:-}" == "--json" ]] && JSON_MODE=1

# Hosts that would break the criterion outright: commercial LLM inference endpoints.
PROHIBITED_HOSTS='api\.openai\.com|api\.anthropic\.com|generativelanguage\.googleapis\.com|api\.cohere|api\.mistral\.ai|api\.together|api\.groq\.com|openrouter\.ai|api\.replicate\.com|api\.deepseek\.com|bedrock.*amazonaws|openai\.azure\.com'

# Hosts that are legitimate but must be DECLARED, not hidden.
declare -A EXPECTED_HOSTS=(
  ["huggingface.co"]="one-time download of open-weight model files (MLX). No prompt, query or patient data is sent; the request carries only a repo path."
  ["hf.co"]="Hugging Face short domain, same as above."
  ["cdn-lfs"]="Hugging Face LFS CDN that serves the weight blobs."
  ["kaggle.com"]="medical-anchor dataset fetch used to build the input guardrail's relevance vocabulary. Verify this is a BUILD-time fetch, not a runtime one."
)

hr() { printf '%s\n' "────────────────────────────────────────────────────────────"; }
say() { [[ $JSON_MODE -eq 0 ]] && printf '%s\n' "$*"; }

fail=0

say ""
say "MobiCureVN — privacy / locality audit"
say "repo:   $REPO_ROOT"
say "commit: $(git rev-parse --short HEAD 2>/dev/null || echo 'n/a')$([[ -n "$(git status --porcelain 2>/dev/null)" ]] && echo ' (DIRTY)')"
say "date:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say ""

# ── 1. Prohibited commercial LLM endpoints ──────────────────────────────────
hr
say "1. Commercial LLM inference endpoints (must be ZERO)"
hr
prohibited=$(grep -rEn "$PROHIBITED_HOSTS" "${SRC_DIRS[@]}" 2>/dev/null)
# A host named in a comment ("we deliberately do not call X") is not a call. It is
# still worth showing -- a reviewer should see it -- but failing on it would make
# the audit impossible to keep green while documenting the decision.
prohibited_code=$(printf '%s\n' "$prohibited" | grep -vE ':[0-9]+:[[:space:]]*(//|///|\*)' | grep -v '^$')
prohibited_comment=$(printf '%s\n' "$prohibited" | grep -E ':[0-9]+:[[:space:]]*(//|///|\*)' | grep -v '^$')

if [[ -z "$prohibited_code" ]]; then
  say "  PASS — no code path reaches a commercial LLM API host."
else
  say "  FAIL — criterion #1 is violated by:"
  say "$prohibited_code" | sed 's/^/    /'
  fail=1
fi
if [[ -n "$prohibited_comment" ]]; then
  say ""
  say "  NOTE — mentioned in comments only (not a call, shown for review):"
  say "$prohibited_comment" | sed 's/^/    /'
fi
say ""

# ── 2. Every URL literal in the source ──────────────────────────────────────
hr
say "2. All hardcoded http(s) URLs"
hr
# A URL in a doc comment is not an egress path; only a URL on a code line is.
# Classify by host AND by whether any non-comment line references it.
hits=$(grep -rEn --include='*.swift' 'https?://[A-Za-z0-9._~:/?#@!$&*+,;=%-]+' "${SRC_DIRS[@]}" 2>/dev/null)
urls=$(printf '%s\n' "$hits" | grep -oE 'https?://[^/"[:space:])]+' | sort -u)
if [[ -z "$urls" ]]; then
  say "  (none)"
else
  while IFS= read -r u; do
    [[ -z "$u" ]] && continue
    host="${u#*://}"
    # Lines mentioning this host that are NOT comments.
    code_hits=$(printf '%s\n' "$hits" | grep -F "$u" | grep -vE ':[0-9]+:[[:space:]]*(//|///|\*)')
    if [[ -z "$code_hits" ]]; then
      say "  $u"
      say "      documentation reference only (appears solely in comments) — not an egress path"
      continue
    fi
    # A URL that never reaches URL(string:)/URLRequest( is text shown to a human
    # (an error message, a setup hint), not a request the app makes. The constructor
    # is often on a neighbouring line -- a long URL gets wrapped -- so inspect a
    # +/-2 line window rather than the matched line alone.
    request_hits=""
    while IFS= read -r hit; do
      [[ -z "$hit" ]] && continue
      hf="${hit%%:*}"; rest="${hit#*:}"; hl="${rest%%:*}"
      [[ "$hl" =~ ^[0-9]+$ ]] || continue
      lo=$(( hl > 2 ? hl - 2 : 1 )); hi=$(( hl + 2 ))
      if sed -n "${lo},${hi}p" "$hf" 2>/dev/null | grep -qE 'URL\(string:|URLRequest\(|URLSession'; then
        request_hits+="$hit"$'\n'
      fi
    done <<< "$code_hits"
    if [[ -z "${request_hits//[$'\n' ]/}" ]]; then
      say "  $u"
      say "      string literal in a user-facing message — no request is constructed from it"
      continue
    fi
    label="UNDECLARED — classify this before presenting"
    for known in "${!EXPECTED_HOSTS[@]}"; do
      if [[ "$host" == *"$known"* ]]; then label="declared: ${EXPECTED_HOSTS[$known]}"; fi
    done
    say "  $u   [reached from code]"
    say "      $label"
    printf '%s\n' "$request_hits" | grep -v '^$' | sed -E 's/^/        /' | while IFS= read -r l; do say "$l"; done
    [[ "$label" == UNDECLARED* ]] && fail=1
  done <<< "$urls"
fi
say ""

# ── 3. Networking API surface ───────────────────────────────────────────────
hr
say "3. Networking API usage (URLSession / sockets / web views)"
hr
net=$(grep -rEn 'URLSession|URLRequest|NWConnection|CFStream|WKWebView|Network\.framework|dataTask|uploadTask|downloadTask' \
        "${SRC_DIRS[@]}" 2>/dev/null | grep -v '^\s*//')
if [[ -z "$net" ]]; then
  say "  none in first-party code — all network I/O is inside the MLX/HF Swift packages."
else
  say "$net" | sed 's/^/  /'
  say ""
  say "  Each line above must be attributable to model/asset download, never to inference"
  say "  or to sending user content off-device."
fi
say ""

# ── 4. Analytics / telemetry / crash reporting ──────────────────────────────
hr
say "4. Analytics, telemetry and crash reporting (must be ZERO)"
hr
tel=$(grep -rEin '\b(firebase|crashlytics|sentry|amplitude|mixpanel|appsflyer|posthog|datadog)\b|segment\.io|google.?analytics' \
        "${SRC_DIRS[@]}" 2>/dev/null | grep -vE '^\S+:[0-9]+:\s*(//|///|\*)')
if [[ -z "$tel" ]]; then
  say "  PASS — no third-party analytics or crash-reporting SDK."
else
  say "  FAIL — patient-adjacent telemetry found:"
  say "$tel" | sed 's/^/    /'
  fail=1
fi
say ""

# ── 5. Where patient data is persisted ──────────────────────────────────────
hr
say "5. Patient-data persistence (must be on-device only)"
hr
say "  SwiftData / SQLite stores:"
grep -rEln 'SwiftData|ModelContainer|sqlite3_open' App/Backend/Store App/Backend/Services/RAG 2>/dev/null | sed 's/^/    /'
say ""
say "  File protection applied to those stores:"
if [[ -f App/Backend/Store/StoreFileProtection.swift ]]; then
  grep -En 'completeUnless|completeFileProtection|FileProtectionType|\.complete' \
    App/Backend/Store/StoreFileProtection.swift 2>/dev/null | sed 's/^/    /'
else
  say "    WARNING: no StoreFileProtection.swift — on-device does not mean encrypted at rest."
  fail=1
fi
say ""
say "  iCloud / CloudKit sync (would take patient data off-device):"
icloud=$(grep -rEn 'CloudKit|NSUbiquitous|cloudKitDatabase|iCloud' "${SRC_DIRS[@]}" 2>/dev/null)
if [[ -z "$icloud" ]]; then
  say "    PASS — none. Stores are local-only."
else
  say "$icloud" | sed 's/^/    /'
  fail=1
fi
say ""

# ── 6. Entitlements and ATS ─────────────────────────────────────────────────
hr
say "6. Entitlements / App Transport Security"
hr
plists=$(find App MobiCureVN.xcodeproj -name '*.entitlements' -o -name 'Info.plist' 2>/dev/null)
if [[ -z "$plists" ]]; then
  say "  (no entitlements or Info.plist found in-tree — settings live in project.pbxproj)"
else
  for p in $plists; do
    say "  $p"
    grep -En 'NSAllowsArbitraryLoads|NSAppTransportSecurity|com.apple.security.network|iCloud' "$p" 2>/dev/null | sed 's/^/      /'
  done
fi
say ""

# ── 7. Speech recognition stays on-device ───────────────────────────────────
hr
say "7. Speech recognition (patient voice must not leave the device)"
hr
# SFSpeechRecognizer sends audio to Apple's servers unless the request sets
# requiresOnDeviceRecognition = true. Setting it from supportsOnDeviceRecognition, or not
# setting it, silently falls back to the server whenever the locale has no on-device
# model -- which is patient voice leaving the device. Checked per file that uses the API
# in code (a mention in a comment is not a use).
speech_files=$(grep -rEn --include='*.swift' 'SFSpeechRecognizer' App 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*(//|///|\*)' | cut -d: -f1 | sort -u)
if [[ -z "$speech_files" ]]; then
  say "  PASS — no SFSpeechRecognizer usage."
else
  for f in $speech_files; do
    lines=$(grep -En 'requiresOnDeviceRecognition[[:space:]]*=' "$f" | grep -vE '^[0-9]+:[[:space:]]*(//|///|\*)')
    if [[ -z "$lines" ]]; then
      say "  FAIL — $f uses SFSpeechRecognizer without requiring on-device recognition"
      fail=1
      continue
    fi
    not_forced=$(printf '%s\n' "$lines" | grep -vE 'requiresOnDeviceRecognition[[:space:]]*=[[:space:]]*true[[:space:]]*(//.*)?$')
    if [[ -n "$not_forced" ]]; then
      say "  FAIL — $f does not force on-device recognition (audio can reach Apple's servers):"
      printf '%s\n' "$not_forced" | sed "s|^|    $f:|" | while IFS= read -r l; do say "$l"; done
      fail=1
    else
      say "  PASS — $f requires on-device recognition:"
      printf '%s\n' "$lines" | sed "s|^|    $f:|" | while IFS= read -r l; do say "$l"; done
    fi
  done
fi
say ""

# ── Verdict ─────────────────────────────────────────────────────────────────
hr
if [[ $fail -eq 0 ]]; then
  say "VERDICT: consistent with criterion #1."
  say ""
  say "  Claim this exactly: inference, retrieval, speech recognition, translation and"
  say "  storage all run on-device; no patient text, voice, photo or profile field is ever"
  say "  transmitted; the only network egress is a one-time download of open-weight model"
  say "  files (and the declared anchor dataset fetch, if still present)."
  say ""
  say "  A static scan is necessary but not sufficient. Pair it with the runtime"
  say "  proof: Airplane Mode demo (Docs/BE/Privacy-Audit.md §Runtime proof)."
else
  say "VERDICT: FINDINGS ABOVE MUST BE RESOLVED before claiming criterion #1."
fi
hr
say ""

[[ $JSON_MODE -eq 1 ]] && printf '{"pass": %s, "commit": "%s", "generated_at": "%s"}\n' \
  "$([[ $fail -eq 0 ]] && echo true || echo false)" \
  "$(git rev-parse --short HEAD 2>/dev/null || echo n/a)" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

exit $fail
