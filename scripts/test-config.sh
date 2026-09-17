#!/bin/bash
# Exercise production settings code with isolated temporary storage, without Safari.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/SafariSelector-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

xcrun swiftc -module-cache-path "$TEST_DIR/ModuleCache" \
  "$REPO/SafariSelector/Core/Config.swift" \
  "$REPO/SafariSelector/Core/SafariTarget.swift" \
  "$REPO/tests/ConfigRegressionTests.swift" \
  -o "$TEST_DIR/config-tests"
"$TEST_DIR/config-tests"
