#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$(mktemp -d "${TMPDIR:-/tmp}/insight-adb-policy.XXXXXX")"
trap 'rm -R "$out"' EXIT
java=/opt/homebrew/opt/openjdk@21/bin
"$java/javac" -d "$out" "$root/Integrations/AndroidAdbKeeper/src/marketing/insight360/adbkeeper/RecoveryPolicy.java" "$root/Tests/AndroidAdbKeeper/RecoveryPolicyTests.java"
"$java/java" -cp "$out" marketing.insight360.adbkeeper.RecoveryPolicyTests
