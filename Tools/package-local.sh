#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_app=${1:-/private/tmp/hsbg-xcode-derived/Build/Products/Release/HSTracker.app}
archive=${2:-"$root/build/HSTracker-CHS-macOS14-universal-local.zip"}

if [ ! -d "$source_app" ]; then
    echo "App not found: $source_app" >&2
    exit 1
fi

staging=$(mktemp -d "${TMPDIR:-/tmp}/hstracker-package.XXXXXX")
trap 'rm -rf "$staging"' EXIT HUP INT TERM
ditto "$source_app" "$staging/HSTracker.app"

# CODE_SIGNING_ALLOWED=NO leaves only linker signatures on individual binaries.
# Seal the complete local app, including its embedded frameworks, so macOS can
# identify one fixed build when storing privacy permissions. A new build still
# needs reauthorization because this is an ad hoc signature, not a developer ID.
codesign --force --deep --sign - \
    --entitlements "$root/HSTracker/HSTracker.entitlements" \
    "$staging/HSTracker.app"
codesign --verify --deep --strict "$staging/HSTracker.app"

mkdir -p "$(dirname -- "$archive")"
ditto -c -k --sequesterRsrc --keepParent "$staging/HSTracker.app" "$archive"
unzip -t "$archive" >/dev/null
echo "$archive"
