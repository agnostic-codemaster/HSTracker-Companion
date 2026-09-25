#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STAGE=${DERIVED_FILE_DIR:-/private/tmp}/HSBGSkipBuild
OUT=${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/HSBGSkip

for ARCH in arm64 x86_64; do
    /usr/bin/swift build --package-path "$ROOT" --scratch-path "$STAGE/$ARCH" \
        --triple "$ARCH-apple-macosx14.0" -c release --product hsbgskipd
done

/bin/mkdir -p "$OUT"
/usr/bin/lipo -create \
    "$STAGE/arm64/out/Products/Release/hsbgskipd" \
    "$STAGE/x86_64/out/Products/Release/hsbgskipd" \
    -output "$OUT/hsbgskipd"
/bin/chmod 755 "$OUT/hsbgskipd"
/bin/cp "$ROOT/LICENSE" "$OUT/LICENSE"
/usr/bin/lipo -verify_arch arm64 "$OUT/hsbgskipd"
/usr/bin/lipo -verify_arch x86_64 "$OUT/hsbgskipd"
