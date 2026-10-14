#!/bin/zsh
# Packs one of the prebuilt libraries in Binary/ for GitHub Releases and points the code at it.
# The binaries aren't in git: a checkout without Binary/ downloads the libssh2 release asset, and the app downloads
# DuckDB at runtime when someone asks for it.
#
#   Scripts/release-binaries.sh libssh2|duckdb
#
# The release is tagged with the library's version (libssh2-1.11.1, duckdb-1.5.6). Publishing stays manual:
# the script prints the `gh release create` command.
set -euo pipefail
cd "${0:A:h}/.."

# The binaries stay on Database Pro's public repository, where they were first published.
REPO=v57/DatabasePro
OUT=build/release
mkdir -p $OUT
case ${1:-} in
  libssh2)
    NAME=Libssh2 TITLE=libssh2
    VERSION=$(awk -F'"' '/define LIBSSH2_VERSION /{sub(/_DEV$/, "", $2); print $2; exit}' \
      Binary/Libssh2.xcframework/macos-arm64/Headers/libssh2.h)
    NOTES="libssh2 + mbedTLS for Database (mbedTLS symbols prefixed _dbpro_), made by Scripts/build-libssh2.sh."
    [[ -d Binary/$NAME.xcframework ]] || { echo "No Binary/$NAME.xcframework: run Scripts/build-libssh2.sh"; exit 1; }
    TAG=$1-$VERSION
    ZIP=$OUT/$NAME.xcframework.zip
    rm -f $ZIP
    (cd Binary && zip -qry -X ../$ZIP $NAME.xcframework)
    CHECKSUM=$(swift package compute-checksum $ZIP)
    # The two lines after `let <name> = binary(` in Package.swift.
    sed -i '' -E "/^  \"$NAME\", release:/s|release: \"[^\"]*\", checksum: \"[0-9a-f]*\"|release: \"$TAG\", checksum: \"$CHECKSUM\"|" Package.swift
    grep -q $CHECKSUM Package.swift || { echo "Package.swift wasn't updated"; exit 1; }
    echo "==> $ZIP ($(du -h $ZIP | cut -f1)), checksum $CHECKSUM"
    echo "Package.swift now points at release $TAG. Commit it, then publish:" ;;
  duckdb)
    # Signed with the app's Developer ID: the hardened runtime only loads libraries from the same team.
    TITLE=DuckDB
    [[ -f Binary/DuckDB/libduckdb.dylib ]] || { echo "No Binary/DuckDB/libduckdb.dylib: run Scripts/build-duckdb.sh"; exit 1; }
    VERSION=$(cat Binary/DuckDB/VERSION)
    NOTES="The DuckDB $VERSION library for Apple silicon Macs, with parquet, json and icu built in and extension auto-install off, made by Scripts/build-duckdb.sh. Database Pro downloads it when you open a DuckDB file."
    TAG=$1-$VERSION
    ZIP=$OUT/libduckdb-macos-arm64.zip
    WORK=$OUT/duckdb-signed
    rm -rf $WORK $ZIP && mkdir -p $WORK
    cp Binary/DuckDB/libduckdb.dylib $WORK/
    codesign --force --timestamp --sign "Developer ID Application" $WORK/libduckdb.dylib
    (cd $WORK && zip -q -X ../${ZIP:t} libduckdb.dylib)
    CHECKSUM=$(shasum -a 256 $ZIP | cut -d' ' -f1)
    SIZE=$(stat -f%z $ZIP)
    URL="https://github.com/$REPO/releases/download/$TAG/${ZIP:t}"
    # The `release` pin in DuckDBLibrary.swift.
    PIN=Sources/DuckDBKit/DuckDBLibrary.swift
    sed -i '' -E \
      -e "s|^    version: \"[^\"]*\",|    version: \"$VERSION\",|" \
      -e "s|^    url: URL\(string: \"[^\"]*\"\)!,|    url: URL(string: \"$URL\")!,|" \
      -e "s|^    sha256: \"[0-9a-f]*\",|    sha256: \"$CHECKSUM\",|" \
      -e "s|^    size: [0-9_]*\)|    size: $SIZE)|" $PIN
    grep -q $CHECKSUM $PIN || { echo "$PIN wasn't updated"; exit 1; }
    echo "==> $ZIP ($(du -h $ZIP | cut -f1)), sha256 $CHECKSUM, $SIZE bytes"
    echo "$PIN now points at release $TAG. Commit it, then publish:" ;;
  *) echo "Usage: Scripts/release-binaries.sh libssh2|duckdb"; exit 1 ;;
esac
echo "  gh release create $TAG $ZIP --repo $REPO --title \"$TITLE $VERSION\" --notes \"$NOTES\""
