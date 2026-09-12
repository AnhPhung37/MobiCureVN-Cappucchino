#!/usr/bin/env bash
# Regression tests for Tools/privacy_audit.sh.
#
# A scanner that always reports PASS is worse than no scanner: it manufactures
# confidence. These tests plant each violation the audit claims to detect and
# assert it actually fails, then assert the things that merely LOOK like
# violations (a host named in a doc comment, a URL inside an error message) do not.
#
# Usage: Tools/tests/test_privacy_audit.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

AUDIT="./Tools/privacy_audit.sh"
PROBE="App/Backend/_privacy_audit_probe.swift"
pass=0
fail=0

cleanup() { rm -f "$PROBE"; }
trap cleanup EXIT

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  \033[32mPASS\033[0m  %-52s exit=%s\n' "$name" "$actual"
    pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m  %-52s exit=%s, expected %s\n' "$name" "$actual" "$expected"
    fail=$((fail + 1))
  fi
}

# Runs the audit with $PROBE containing the given source, returns its exit code.
with_probe() {
  cat > "$PROBE"
  "$AUDIT" >/dev/null 2>&1
  local code=$?
  rm -f "$PROBE"
  return $code
}

echo ""
echo "privacy_audit.sh regression tests"
echo "─────────────────────────────────────────────────────────────────────"

# ── The tree as committed must be clean, or every other result is meaningless.
"$AUDIT" >/dev/null 2>&1
check "committed tree passes" 0 $?

# ── Must FAIL: an actual call to a commercial LLM API.
with_probe <<'SWIFT'
import Foundation
enum Probe {
    static func send(_ prompt: String) async throws {
        var r = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        r.httpBody = prompt.data(using: .utf8)
        _ = try await URLSession.shared.data(for: r)
    }
}
SWIFT
check "openai inference call is caught" 1 $?

with_probe <<'SWIFT'
import Foundation
enum Probe {
    static func send() async throws {
        _ = try await URLSession.shared.data(
            for: URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!))
    }
}
SWIFT
check "anthropic inference call is caught" 1 $?

with_probe <<'SWIFT'
import Foundation
enum Probe {
    static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1/models")!
    static func send() async throws { _ = try await URLSession.shared.data(from: endpoint) }
}
SWIFT
check "gemini inference call is caught" 1 $?

# ── Must FAIL: analytics / crash reporting in a patient-facing app.
with_probe <<'SWIFT'
import Firebase
enum Probe { static let crash = Crashlytics.crashlytics() }
SWIFT
check "firebase/crashlytics is caught" 1 $?

# ── Must FAIL: patient data leaving the device via iCloud.
with_probe <<'SWIFT'
import CloudKit
enum Probe { static let db = CKContainer.default().privateCloudDatabase }
SWIFT
check "cloudkit sync is caught" 1 $?

# ── Must FAIL: an egress host nobody has declared.
with_probe <<'SWIFT'
import Foundation
enum Probe {
    static func upload() async throws {
        _ = try await URLSession.shared.data(
            for: URLRequest(url: URL(string: "https://telemetry.example.com/v1/events")!))
    }
}
SWIFT
check "undeclared egress host is caught" 1 $?

# ── Must PASS: mentions that are not calls. These are the false positives that
#    would otherwise make the audit impossible to keep green.
with_probe <<'SWIFT'
import Foundation
/// See https://api.openai.com/docs — deliberately NOT used; inference is on-device.
enum Probe { static let note = "documented, never called" }
SWIFT
check "prohibited host in a comment does not fail" 0 $?

with_probe <<'SWIFT'
import Foundation
enum Probe {
    static let setupHint =
        "Add the package from https://github.com/example/pkg and rebuild."
}
SWIFT
check "url inside a user-facing message does not fail" 0 $?

with_probe <<'SWIFT'
import Foundation
enum Probe {
    // 'sentry' must not be matched inside an unrelated identifier.
    static func removesEntry() {}
    static func inventoryCount() -> Int { 0 }
}
SWIFT
check "identifiers containing sdk names do not fail" 0 $?

# ── The tree must be exactly as it started.
"$AUDIT" >/dev/null 2>&1
check "tree restored after probes" 0 $?

echo "─────────────────────────────────────────────────────────────────────"
printf "  %d passed, %d failed\n\n" "$pass" "$fail"
[[ $fail -eq 0 ]]
