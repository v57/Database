#!/bin/zsh
# Packs one of the prebuilt libraries in Binary/ for GitHub Releases and points Package.swift at it.
# The binaries aren't in git: a checkout without Binary/ downloads the release assets.
#
#   Scripts/release-binaries.sh libssh2|duckdb
#
# The release is tagged with the library's version (libssh2-1.11.1, duckdb-1.5.6). Publishing stays manual:
# the script prints the `gh release create` command.
set -euo pipefail
cd "${0:A:h}/.."

REPO=v57/DatabasePro
case ${1:-} in
  libssh2)
    NAME=Libssh2 TITLE=libssh2
    VERSION=$(awk -F'"' '/define LIBSSH2_VERSION /{sub(/_DEV$/, "", $2); print $2; exit}' \
      Binary/Libssh2.xcframework/macos-arm64/Headers/libssh2.h)
    NOTES="libssh2 + mbedTLS for DatabasePro (mbedTLS symbols prefixed _dbpro_), made by Scripts/build-libssh2.sh." ;;
  duckdb)
    NAME=Cduckdb TITLE=DuckDB
    VERSION=$(cat Binary/Cduckdb.xcframework/VERSION)
    NOTES="The DuckDB $VERSION C library for macOS, iOS and the iOS simulator (arm64), with parquet, json and icu built in and extension auto-install off, made by Scripts/build-duckdb.sh." ;;
  *) echo "Usage: Scripts/release-binaries.sh libssh2|duckdb"; exit 1 ;;
esac
[[ -d Binary/$NAME.xcframework ]] || { echo "No Binary/$NAME.xcframework: run its Scripts/build-*.sh"; exit 1; }
TAG=$1-$VERSION
OUT=build/release
ZIP=$OUT/$NAME.xcframework.zip

mkdir -p $OUT && rm -f $ZIP
(cd Binary && zip -qry -X ../$ZIP $NAME.xcframework)
CHECKSUM=$(swift package compute-checksum $ZIP)

# The two lines after `let <name> = binary(` in Package.swift.
sed -i '' -E "/^  \"$NAME\", release:/s|release: \"[^\"]*\", checksum: \"[0-9a-f]*\"|release: \"$TAG\", checksum: \"$CHECKSUM\"|" Package.swift
grep -q $CHECKSUM Package.swift || { echo "Package.swift wasn't updated"; exit 1; }

echo "==> $ZIP ($(du -h $ZIP | cut -f1)), checksum $CHECKSUM"
echo "Package.swift now points at release $TAG. Commit it, then publish:"
echo "  gh release create $TAG $ZIP --repo $REPO --title \"$TITLE $VERSION\" --notes \"$NOTES\""
