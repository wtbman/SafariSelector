#!/bin/bash
# Install a verified notarized release, preserving its nested signatures.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DEST="/Applications/SafariSelector.app"
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
REQUIREMENT='=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
DEVELOPMENT=false
stop_installed_app() {
    local pattern='^/Applications/SafariSelector.app/Contents/MacOS/SafariSelector$'
    pkill -TERM -f "$pattern" 2>/dev/null || true
    # LaunchServices can reject a launch with -600 while the old process exits.
    # Wait for termination before replacing or reopening the installed bundle.
    local attempt
    for ((attempt = 0; attempt < 40; attempt++)); do
        if ! pgrep -f "$pattern" >/dev/null; then return 0; fi
        sleep 0.5
    done
    echo 'SafariSelector did not quit; leaving the installed app in place.' >&2
    return 1
}
if [[ "${1:-}" == --development ]]; then
    DEVELOPMENT=true
    if [[ -d "$DEST" ]] && codesign --verify -R "$REQUIREMENT" "$DEST" 2>/dev/null; then
        echo "Refusing to replace an installed Developer ID release with an unsigned build." >&2
        exit 1
    fi
    DD="${DD:-/tmp/SafariSelector-DD}"
    DD="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$DD")"
    case "$DD/" in "$REPO/"*) echo "DerivedData must be outside the repository" >&2; exit 2 ;; esac
    xcodebuild -project "$REPO/SafariSelector.xcodeproj" -scheme SafariSelector \
        -configuration Debug -derivedDataPath "$DD" CODE_SIGN_IDENTITY="-" \
        CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" build
    SOURCE="$DD/Build/Products/Debug/SafariSelector.app"
else
    SOURCE="${1:-}"
    if [[ -z "$SOURCE" || ! -d "$SOURCE" ]]; then
        echo "Usage: $0 /path/to/notarized/SafariSelector.app" >&2
        echo "Build a release with scripts/release.sh. For unsigned local debugging: $0 --development" >&2
        exit 2
    fi
fi

verify() {
    local app="$1"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == cc.wtb.SafariSelector ]]
    codesign --verify --strict "$app"
    codesign --verify --strict "$app/Contents/PlugIns/SafariSelector Extension.appex"
    if [[ "$DEVELOPMENT" == false ]]; then
        codesign --verify --strict -R "$REQUIREMENT" "$app"
        codesign --verify --strict -R "$REQUIREMENT" "$app/Contents/PlugIns/SafariSelector Extension.appex"
        xcrun stapler validate "$app"
        spctl --assess --type execute --verbose=2 "$app"
    fi
}
verify "$SOURCE"
STAGE="$(mktemp -d /Applications/.SafariSelector-install.XXXXXX)"
REPLACED=false
COMMITTED=false
cleanup() {
    local result=$?
    if [[ "$COMMITTED" == false && "$REPLACED" == true ]]; then
        stop_installed_app || exit "$result"
        rm -rf "$DEST"
        if [[ -d "$STAGE/Previous.app" ]]; then
            mv "$STAGE/Previous.app" "$DEST"
            "$LSREG" -f -R -trusted "$DEST" || true
            pluginkit -a "$DEST/Contents/PlugIns/SafariSelector Extension.appex" || true
            open "$DEST" || true
        fi
    fi
    rm -rf "$STAGE"
    exit "$result"
}
trap cleanup EXIT

ditto "$SOURCE" "$STAGE/SafariSelector.app"
verify "$STAGE/SafariSelector.app"
if [[ -d "$DEST" ]]; then
    RECOVERY="${RECOVERY_DIR:-$HOME/Library/Application Support/SafariSelector/Installation Backups}"
    mkdir -p "$RECOVERY"
    chmod 700 "$RECOVERY"
    BACKUP="$(mktemp -d "$RECOVERY/$(date +%Y%m%d-%H%M%S).XXXXXX")"
    ditto -c -k --keepParent "$DEST" "$BACKUP/SafariSelector.zip"
    unzip -tq "$BACKUP/SafariSelector.zip"
    echo "Previous app saved: $BACKUP/SafariSelector.zip"
fi
stop_installed_app
if [[ -d "$DEST" ]]; then mv "$DEST" "$STAGE/Previous.app"; fi
REPLACED=true
mv "$STAGE/SafariSelector.app" "$DEST"
verify "$DEST"
"$LSREG" -f -R -trusted "$DEST"
# Register the installed copy directly. Unregistering another copy of the same
# extension during an update can also disturb Safari's existing enablement.
pluginkit -a "$DEST/Contents/PlugIns/SafariSelector Extension.appex"
pluginkit -e use -i cc.wtb.SafariSelector.Extension
open "$DEST"
COMMITTED=true
if [[ "$DEVELOPMENT" == true ]]; then
    echo 'Unsigned development build installed; Safari requires Allow Unsigned Extensions after each relaunch.'
else
    echo 'Notarized Developer ID release installed. Allow Unsigned Extensions is not required.'
fi
echo 'Enable SafariSelector in Safari > Settings > Extensions for each profile you use.'
