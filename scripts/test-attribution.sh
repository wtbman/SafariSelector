#!/bin/bash
# Exercise real window matching, Settings lists and persistence without contacting Safari.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/SafariSelector-attribution-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -module-cache-path "$TEST_DIR/ModuleCache" \
  "$REPO/SafariSelector/Core/BridgeProtocol.swift" \
  "$REPO/SafariSelector/Core/AppleScriptProbe.swift" \
  "$REPO/SafariSelector/Core/Config.swift" \
  "$REPO/SafariSelector/Core/SafariTarget.swift" \
  "$REPO/SafariSelector/Core/TargetStore.swift" \
  "$REPO/tests/WindowAttributionTests.swift" \
  -o "$TEST_DIR/attribution-tests"
"$TEST_DIR/attribution-tests"
