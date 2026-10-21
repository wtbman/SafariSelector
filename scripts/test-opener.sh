#!/bin/bash
# Exercise the real readiness path against an isolated slow extension client.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/SafariSelector-opener-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -module-cache-path "$TEST_DIR/ModuleCache" \
  "$REPO/SafariSelector/Core/BridgeProtocol.swift" \
  "$REPO/SafariSelector/Core/BridgeServer.swift" \
  "$REPO/SafariSelector/Core/Opener.swift" \
  "$REPO/tests/OpenerReadinessTests.swift" \
  -o "$TEST_DIR/opener-tests"
"$TEST_DIR/opener-tests"
