#!/bin/bash
# Isolated transport and window parsing checks; never opens or changes Safari tabs.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/SafariSelector-routing-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -module-cache-path "$TEST_DIR/ModuleCache" \
  "$REPO/SafariSelector/Core/BridgeProtocol.swift" \
  "$REPO/SafariSelector/Core/BridgeServer.swift" \
  "$REPO/SafariSelector/Core/AppleScriptProbe.swift" \
  "$REPO/tests/RoutingRegressionTests.swift" \
  -o "$TEST_DIR/routing-tests"
"$TEST_DIR/routing-tests"
