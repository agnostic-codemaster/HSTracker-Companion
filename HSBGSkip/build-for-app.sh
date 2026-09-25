#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STAGE=${DERIVED_FILE_DIR:-/private/tmp}/HSBGSkipBuild
OUT=${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/HSBGSkip

# Ask SwiftPM where it put each binary: the layout under the scratch path differs between
# SwiftPM's native build system and the Swift Build one newer Xcode releases default to.
BINARIES=
for ARCH in arm64 x86_64; do
    set -- --package-path "$ROOT" --scratch-path "$STAGE/$ARCH" \
        --triple "$ARCH-apple-macosx14.0" -c release
    /usr/bin/swift build "$@" --product hsbgskipd
    BINARIES="$BINARIES $(/usr/bin/swift build "$@" --show-bin-path)/hsbgskipd"
done

/bin/mkdir -p "$OUT"
# shellcheck disable=SC2086 # BINARIES is a space-separated list of paths without spaces
/usr/bin/lipo -create $BINARIES -output "$OUT/hsbgskipd"
/bin/chmod 755 "$OUT/hsbgskipd"
/bin/cp "$ROOT/LICENSE" "$OUT/LICENSE"
/usr/bin/lipo -verify_arch arm64 "$OUT/hsbgskipd"
/usr/bin/lipo -verify_arch x86_64 "$OUT/hsbgskipd"
