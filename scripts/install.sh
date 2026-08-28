#!/bin/bash
# Builds SafariSelector and installs it to /Applications.
#
# /Applications, not ~/Applications: this is where a default browser is expected
# to live, and it keeps one canonical registration for LaunchServices.
#
# DerivedData deliberately lives outside the repo: extended attributes from synced
# or network volumes break codesigning.
#
# Do not re-sign the installed bundle with `codesign --deep` — that strips the
# appex entitlements and pluginkit then silently refuses to register the extension.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DD="${DD:-/tmp/SafariSelector-DD}"
DEST="/Applications/SafariSelector.app"
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister

echo "==> Building"
xcodebuild -project "$REPO/SafariSelector.xcodeproj" -scheme SafariSelector \
  -configuration Debug -derivedDataPath "$DD" \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" build >/dev/null

echo "==> Installing to $DEST"
pkill -f 'SafariSelector.app/Contents/MacOS' 2>/dev/null || true
sleep 1
rm -rf "$DEST"
ditto "$DD/Build/Products/Debug/SafariSelector.app" "$DEST"
codesign -v --strict "$DEST"

echo "==> Registering with LaunchServices"
"$LSREG" -u "$DEST" 2>/dev/null || true
"$LSREG" -f -R -trusted "$DEST"
open "$DEST"

cat <<'EOF'

Installed. Remaining manual steps:

  1. Safari > Develop > Allow Unsigned Extensions
     (required while the build is ad-hoc signed; resets when Safari relaunches)
  2. Safari > Settings > Extensions > enable "SafariSelector"
  3. System Settings > Apps > Default web browser > SafariSelector

EOF
