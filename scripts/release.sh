#!/bin/bash
# Archive, submit through the existing Xcode account, then export Apple's
# notarized Developer ID app. No passwords or private keys are exported.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PHASE="${1:-all}"
case "$PHASE" in all|archive|submit|export) ;; *) echo "Usage: $0 [all|archive|submit|export]" >&2; exit 2 ;; esac
: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your existing paid Apple team ID}"
RELEASE_DIR="${RELEASE_DIR:-$(mktemp -d /tmp/SafariSelector-release.XXXXXX)}"
RELEASE_DIR="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$RELEASE_DIR")"
case "$RELEASE_DIR/" in "$REPO/"*) echo "Release output must be outside the repository" >&2; exit 2 ;; esac
mkdir -p "$RELEASE_DIR"
DD="${DD:-$RELEASE_DIR/DerivedData}"
DD="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$DD")"
case "$DD/" in "$REPO/"*) echo "DerivedData must be outside the repository" >&2; exit 2 ;; esac
ARCHIVE="$RELEASE_DIR/SafariSelector.xcarchive"
echo "Release output: $RELEASE_DIR"

if [[ "$PHASE" == all || "$PHASE" == archive ]]; then
    [[ ! -e "$ARCHIVE" ]] || { echo "Archive already exists; use a fresh RELEASE_DIR" >&2; exit 2; }
    xcodebuild -project "$REPO/SafariSelector.xcodeproj" -scheme SafariSelector \
        -configuration Release -destination 'generic/platform=macOS' \
        -derivedDataPath "$DD" -archivePath "$ARCHIVE" \
        -allowProvisioningUpdates DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
        CURRENT_PROJECT_VERSION="${BUILD_NUMBER:-$(date +%Y.%m%d.%H%M)}" archive
fi

if [[ "$PHASE" == all || "$PHASE" == submit ]]; then
    python3 - "$RELEASE_DIR/ExportOptions.plist" "$DEVELOPMENT_TEAM" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump(dict(method='developer-id', destination='upload',
                       signingStyle='automatic', teamID=sys.argv[2]), output)
PY
    # Xcode can create a Developer ID identity if none exists. Upload goes only to
    # Apple's notary service, using the account already configured in Xcode.
    xcodebuild -exportArchive -archivePath "$ARCHIVE" \
        -exportOptionsPlist "$RELEASE_DIR/ExportOptions.plist" \
        -exportPath "$RELEASE_DIR/Submission" -allowProvisioningUpdates
fi

if [[ "$PHASE" == all || "$PHASE" == export ]]; then
    # If Apple is still processing, this fails safely. Resume with 'export' after
    # acceptance; do not rebuild or submit another copy to wait for the first.
    xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$RELEASE_DIR/Export"
    APP="$RELEASE_DIR/Export/SafariSelector.app"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
    echo "Ready to install: $REPO/scripts/install.sh '$APP'"
fi
