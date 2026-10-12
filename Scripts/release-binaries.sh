#!/bin/zsh
# Packs Binary/Libssh2.xcframework for GitHub Releases and points Package.swift at it.
# The binaries aren't in git: a checkout without Binary/ downloads the release asset.
#
#   Scripts/release-binaries.sh [tag]      (tag defaults to libssh2-<libssh2 version>)
#
# Publishing stays manual: the script prints the `gh release create` command.
set -euo pipefail
cd "${0:A:h}/.."

REPO=v57/DatabasePro
FRAMEWORK=Binary/Libssh2.xcframework
[[ -d $FRAMEWORK ]] || { echo "No $FRAMEWORK: run Scripts/build-libssh2.sh"; exit 1; }
VERSION=$(awk -F'"' '/define LIBSSH2_VERSION /{sub(/_DEV$/, "", $2); print $2; exit}' $FRAMEWORK/macos-arm64/Headers/libssh2.h)
TAG=${1:-libssh2-$VERSION}
OUT=build/release
ZIP=$OUT/Libssh2.xcframework.zip

rm -rf $OUT && mkdir -p $OUT
(cd Binary && zip -qry -X ../$ZIP Libssh2.xcframework)
CHECKSUM=$(swift package compute-checksum $ZIP)
URL="https://github.com/$REPO/releases/download/$TAG/Libssh2.xcframework.zip"

sed -i '' -E \
  -e "s|url: \"https://github.com/$REPO/releases/download/[^\"]*\"|url: \"$URL\"|" \
  -e "s|checksum: \"[0-9a-f]*\"|checksum: \"$CHECKSUM\"|" Package.swift
grep -q $CHECKSUM Package.swift || { echo "Package.swift wasn't updated"; exit 1; }

echo "==> $ZIP ($(du -h $ZIP | cut -f1)), checksum $CHECKSUM"
echo "Package.swift now points at $URL. Commit it, then publish:"
echo "  gh release create $TAG $ZIP --repo $REPO --title \"libssh2 $VERSION\" --notes \"libssh2 + mbedTLS for DatabasePro (mbedTLS symbols prefixed _dbpro_).\""
