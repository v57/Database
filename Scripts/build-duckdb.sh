#!/bin/zsh
# Builds Binary/Cduckdb.xcframework: the DuckDB C library from an upstream release, compiled for macOS, iOS and
# the iOS simulator (Apple silicon only), with parquet, json and icu built in. Extensions are never installed or
# loaded at runtime.
#
#   Scripts/build-duckdb.sh [version]      (default below; needs cmake and ninja: brew install cmake ninja)
#
# `Scripts/release-binaries.sh duckdb` publishes the result to GitHub Releases.
set -euo pipefail
cd "${0:A:h}/.."

VERSION=${1:-1.5.6}
ROOT=$PWD
WORK=$ROOT/build/duckdb
SRC=$WORK/duckdb-$VERSION
OUT=$ROOT/Binary/Cduckdb.xcframework
JOBS=$(sysctl -n hw.ncpu)

mkdir -p $WORK
if [[ ! -d $SRC ]]; then
  echo "==> Downloading DuckDB v$VERSION"
  curl -fsSL https://github.com/duckdb/duckdb/archive/refs/tags/v$VERSION.tar.gz | tar xz -C $WORK
fi
# The tarball has no git history; DuckDB reports this as its version and source id.
COMMIT=$(curl -fsSL https://api.github.com/repos/duckdb/duckdb/commits/v$VERSION | awk -F'"' '/"sha"/ {print substr($4, 1, 10); exit}')

# slice  cmake system  sysroot  architectures  deployment target  DuckDB platform name (it can't run a probe
# program when cross-compiling)
SLICES=(
  "macos-arm64 Darwin macosx arm64 14.0 osx_arm64"
  "ios-arm64 iOS iphoneos arm64 17.0 ios_arm64"
  "ios-arm64-simulator iOS iphonesimulator arm64 17.0 ios_simulator"
)

libs=()
for slice in $SLICES; do
  read name system sysroot archs target platform <<< $slice
  build=$WORK/build-$name
  echo "==> Building $name"
  cmake -S $SRC -B $build -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=$system -DCMAKE_OSX_SYSROOT=$sysroot -DCMAKE_OSX_ARCHITECTURES="$archs" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$target -DDUCKDB_EXPLICIT_PLATFORM=$platform \
    -DOVERRIDE_GIT_DESCRIBE=v$VERSION-0-g$COMMIT \
    -DBUILD_EXTENSIONS="parquet;json;icu" \
    -DENABLE_EXTENSION_AUTOLOADING=0 -DENABLE_EXTENSION_AUTOINSTALL=0 \
    -DBUILD_SHELL=0 -DBUILD_UNITTESTS=0 -DENABLE_SANITIZER=0 -DENABLE_UBSAN=0 >/dev/null
  cmake --build $build --parallel $JOBS > $build/build.log 2>&1 || { grep -E "error|FAILED" $build/build.log | head -20; exit 1; }
  # One archive from DuckDB's pieces (core, third-party code, extensions), like its `make bundle-library`.
  libtool -static -no_warning_for_no_symbols -o $build/libduckdb.a \
    $build/src/libduckdb_static.a $build/third_party/*/libduckdb_*.a \
    $build/extension/libduckdb_generated_extension_loader.a $build/extension/*/lib*_extension.a 2>/dev/null
  libs+=(-library $build/libduckdb.a -headers $WORK/headers)
done

rm -rf $WORK/headers && mkdir -p $WORK/headers/Cduckdb
cp $SRC/src/include/duckdb.h $WORK/headers/
cat > $WORK/headers/Cduckdb/module.modulemap <<'MAP'
module Cduckdb [system] {
    header "../duckdb.h"
    link "c++"
    export *
}
MAP

rm -rf $OUT && mkdir -p ${OUT:h}
xcodebuild -create-xcframework $libs -output $OUT >/dev/null
echo "$VERSION" > $OUT/VERSION
echo "==> $OUT (DuckDB $VERSION, $(du -sh $OUT | cut -f1))"
