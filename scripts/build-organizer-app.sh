#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-release}"
if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
    echo "Configuration must be debug or release" >&2; exit 2
fi
bash "$project_root/scripts/swiftpm.sh" build -c "$configuration"
binary_dir="$(bash "$project_root/scripts/swiftpm.sh" build -c "$configuration" --show-bin-path)"
bundle="$project_root/dist/Photo Triage Organizer 0.4.0.app"
mkdir -p "$project_root/dist" "$project_root/.local-data/build-backups"
staging="$(mktemp -d "$project_root/dist/.organizer-build.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Resources/Travel"
cp "$binary_dir/PhotoTriageMac" "$staging/Contents/MacOS/PhotoTriageMac"
cp "$project_root/Resources/OrganizerInfo.plist" "$staging/Contents/Info.plist"
cp "$project_root/Resources/Travel/places.json" "$staging/Contents/Resources/Travel/places.json"
cp "$project_root/Resources/Travel/ATTRIBUTION.txt" "$staging/Contents/Resources/Travel/ATTRIBUTION.txt"
cp "$project_root/Resources/AppIcon.icns" "$staging/Contents/Resources/AppIcon.icns"
plutil -lint "$staging/Contents/Info.plist"
codesign --force --sign - --identifier local.phototriage.mac "$staging"
codesign --verify --strict --verbose=2 "$staging"
# Archive the previous bundle, then swap directories so a running executable is never truncated.
if [[ -d "$bundle" ]]; then
    backup="$(mktemp -d "$project_root/.local-data/build-backups/update.XXXXXX")"
    ditto -c -k --keepParent "$bundle" "$backup/previous-app.zip"
    chmod 600 "$backup/previous-app.zip"
    mv "$bundle" "$staging/previous-bundle"
    if ! mv "$staging" "$bundle"; then
        mv "$staging/previous-bundle" "$bundle"
        exit 1
    fi
    rm -rf "$bundle/previous-bundle"
else
    mv "$staging" "$bundle"
fi
codesign --verify --strict --verbose=2 "$bundle"
echo "$bundle"
