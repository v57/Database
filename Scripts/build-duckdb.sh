#!/bin/zsh
# Builds Binary/DuckDB/libduckdb.dylib: the DuckDB C library from an upstream release, compiled for Apple silicon
# Macs, with parquet, json and icu built in. Extensions are never installed or loaded at runtime.
#
#   Scripts/build-duckdb.sh [version]      (default below; needs cmake and ninja: brew install cmake ninja)
#
# The app doesn't link it: `Scripts/release-binaries.sh duckdb` signs and publishes it to GitHub Releases, and the app
# downloads it when someone opens a DuckDB file (DuckDBKit/DuckDBLibrary.swift). The C header is checked in at
# Sources/Cduckdb/include/duckdb.h and refreshed here, so a new version updates both at once.
set -euo pipefail
cd "${0:A:h}/.."

VERSION=${1:-1.5.6}
ROOT=$PWD
WORK=$ROOT/build/duckdb
SRC=$WORK/duckdb-$VERSION
OUT=$ROOT/Binary/DuckDB
JOBS=$(sysctl -n hw.ncpu)

mkdir -p $WORK
if [[ ! -d $SRC ]]; then
  echo "==> Downloading DuckDB v$VERSION"
  curl -fsSL https://github.com/duckdb/duckdb/archive/refs/tags/v$VERSION.tar.gz | tar xz -C $WORK
fi
# The tarball has no git history; DuckDB reports this as its version and source id.
COMMIT=$(curl -fsSL https://api.github.com/repos/duckdb/duckdb/commits/v$VERSION | awk -F'"' '/"sha"/ {print substr($4, 1, 10); exit}')

build=$WORK/build-macos-arm64
echo "==> Building macos-arm64"
cmake -S $SRC -B $build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_OSX_SYSROOT=macosx -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DDUCKDB_EXPLICIT_PLATFORM=osx_arm64 \
  -DOVERRIDE_GIT_DESCRIBE=v$VERSION-0-g$COMMIT \
  -DBUILD_EXTENSIONS="parquet;json;icu" \
  -DENABLE_EXTENSION_AUTOLOADING=0 -DENABLE_EXTENSION_AUTOINSTALL=0 \
  -DBUILD_SHELL=0 -DBUILD_UNITTESTS=0 -DENABLE_SANITIZER=0 -DENABLE_UBSAN=0 >/dev/null
cmake --build $build --parallel $JOBS --target duckdb > $build/build.log 2>&1 || { grep -E "error|FAILED" $build/build.log | head -20; exit 1; }

rm -rf $OUT && mkdir -p $OUT
cp $build/src/libduckdb.dylib $OUT/libduckdb.dylib
strip -x $OUT/libduckdb.dylib
echo "$VERSION" > $OUT/VERSION
cp $SRC/src/include/duckdb.h $ROOT/Sources/Cduckdb/include/duckdb.h
echo "==> $OUT/libduckdb.dylib (DuckDB $VERSION, $(du -h $OUT/libduckdb.dylib | cut -f1)); header refreshed in Sources/Cduckdb"
