#!/bin/zsh
# Packs the prebuilt DuckDB in Binary/ for GitHub Releases and points the code at it. The binary isn't in git: the app
# downloads it at runtime when someone asks for it. libssh2 is ../SSH's (Scripts/build-libssh2.sh, release-libssh2.sh).
#
#   Scripts/release-binaries.sh duckdb
#
# The release is tagged with the library's version (duckdb-1.5.6) on v57/Database. Publishing stays manual: the script
# prints the `gh release create` command.
set -euo pipefail
cd "${0:A:h}/.."

OUT=build/release
mkdir -p $OUT
case ${1:-} in
  duckdb)
    # Signed with the app's Developer ID: the hardened runtime only loads libraries from the same team.
    TITLE=DuckDB REPO=v57/Database
    [[ -f Binary/DuckDB/libduckdb.dylib ]] || { echo "No Binary/DuckDB/libduckdb.dylib: run Scripts/build-duckdb.sh"; exit 1; }
    VERSION=$(cat Binary/DuckDB/VERSION)
    NOTES="The DuckDB $VERSION library for Apple silicon Macs, with parquet, json and icu built in and extension auto-install off, made by Scripts/build-duckdb.sh. Database downloads it when you open a DuckDB file."
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
  *) echo "Usage: Scripts/release-binaries.sh duckdb (libssh2: ../SSH/Scripts/release-libssh2.sh)"; exit 1 ;;
esac
echo "  gh release create $TAG $ZIP --repo $REPO --title \"$TITLE $VERSION\" --notes \"$NOTES\""
