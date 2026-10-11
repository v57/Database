#!/usr/bin/env bash
#
# build-c-drivers.sh — Cross-compile the C client libraries for the Database
# app's engines into one XCFramework per library, each a SwiftPM binaryTarget.
# Libraries built (static-only) for every Apple slice:
#
#   iOS device (arm64), iOS simulator (arm64 + x86_64), macOS (arm64)
#
#   CMongoC.xcframework     -> libmongoc + libbson   (mongo-c-driver, CMake)
#   CPostgreSQL.xcframework -> libpq + support libs  (postgresql, autoconf)
#   CHiredis.xcframework    -> hiredis               (hiredis, raw clang)
#
# HEADER LAYOUT: Xcode and SwiftPM copy every library XCFramework's Headers/
# into ONE shared Build/Products/<config>/include/ folder. Two modulemaps at
# Headers/module.modulemap would land on the same path ("Multiple commands
# produce .../include/module.modulemap"), so each XCFramework keeps its
# modulemap in a folder named after its module (Headers/CMongoC/module.modulemap,
# pointing at "../mongoc/mongoc.h") and its headers in a folder of their own.
# Clang finds a module's map in <include>/<Module>/, and the libraries' own
# <bson/bson.h>-style includes still resolve from <include>.
#
# PREREQUISITES:
#   - Xcode 16+ (xcrun --sdk iphoneos / iphonesimulator / macosx)
#   - cmake, autoconf, libtool, make, perl   (brew install cmake autoconf)
#   - Internet (sources downloaded once; cached in build/.cache)
#
# USAGE:
#   ./build-c-drivers.sh               # build + package all libraries
#   ./build-c-drivers.sh clean         # remove the XCFrameworks + slice outputs
#
# OUTPUT (committed):
#   Binary/C-drivers/C*.xcframework   -> consumed via .binaryTarget in Package.swift
#   Binary/C-drivers/build/           -> scratch (sources, per-slice .a, headers)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PREFIX_DIR="$REPO_ROOT/Binary/C-drivers"
BUILD_DIR="$PREFIX_DIR/build"
SDK_CACHE="$BUILD_DIR/.cache"
mkdir -p "$PREFIX_DIR" "$BUILD_DIR" "$SDK_CACHE"

# macOS Finder drops read-only .DS_Store files that make `rm -rf` on a dir fail
# ("Directory not empty"). Purge them before every destructive rm, and chmod the
# tree writable so read-only .a files (from prior xcodebuild runs) don't block it.
rmds() { find "$1" -name .DS_Store -delete 2>/dev/null || true; }
rmr()  { for p in "$@"; do
           [ -e "$p" ] || continue
           rmds "$p" 2>/dev/null
           chmod -R u+w "$p" 2>/dev/null || true
           rm -rf "$p" 2>/dev/null || true
         done; }

IOS_DEVICE="arm64-apple-ios13.0"
IOS_SIM_ARM64="arm64-apple-ios15.0-simulator"
IOS_SIM_X86="x86_64-apple-ios15.0-simulator"
MACOS_ARM64="arm64-apple-macosx14.0"

IPHONEOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
IPHONESIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --find clang)"
CXX="$(xcrun --find clang++)"
AR="$(xcrun --find ar)"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Pull a source tarball into the cache if not already there.
fetch() { # $1=url $2=destname
  [ -f "$SDK_CACHE/$2" ] || curl -sL -o "$SDK_CACHE/$2" "$1"
  tar xzf "$SDK_CACHE/$2" -C "$BUILD_DIR"
}

# `libtool -static` a list of archives, tolerating the (harmless) 2>/dev/null.
libtool_merge() { # $1=output; rest=archives
  local out="$1"; shift
  rmr "$(dirname "$out")/$(basename "$out")"
  mkdir -p "$(dirname "$out")"
  libtool -static -o "$out" "$@" 2>/dev/null || die "libtool -static -> $out"
}

# lipo two single-arch archives into one fat archive at $out.
lipo_fat() { # $1=out  $2=arm64-in  $3=x86-in
  local out="$1"; mkdir -p "$(dirname "$out")"
  lipo -create -output "$out" "$2" "$3" 2>/dev/null || die "lipo -> $out"
}

# =====================================================================================
# hiredis 1.4.1  (openssl-free core; ssl.c not needed — facade is plaintext)
# =====================================================================================
build_hiredis() {
  local ver="1.4.1"
  local dir="hiredis-$ver"
  info "hiredis: fetch + build"
  fetch "https://github.com/redis/hiredis/archive/refs/tags/v$ver.tar.gz" hiredis.tar.gz
  local src="$BUILD_DIR/$dir"
  local objs="alloc net hiredis sds async read sockcompat"
  local s="libhiredis"; LIBNAME="libhiredis.a"

  compile_slice() { # $1=name $2=target $3=sdk
    local name="$1" target="$2" sdk="$3"
    local od="$BUILD_DIR/slices/$s/$name"
    mkdir -p "$od"
    for f in $objs; do
      "$CC" -x c -std=c99 -fPIC -target "$target" -isysroot "$sdk" \
        -c "$src/$f.c" -o "$od/$f.o" || die "hiredis compile $name/$f"
    done
    "$AR" rcs "$od/$LIBNAME" "$od"/*.o
  }
  compile_slice device "$IOS_DEVICE" "$IPHONEOS_SDK"
  compile_slice sim-arm64 "$IOS_SIM_ARM64" "$IPHONESIM_SDK"
  compile_slice sim-x86 "$IOS_SIM_X86" "$IPHONESIM_SDK"
  compile_slice macos "$MACOS_ARM64" "$MACOS_SDK"

  mkdir -p "$BUILD_DIR/slices/$s/sim"
  lipo -create -output "$BUILD_DIR/slices/$s/sim/$LIBNAME" \
    "$BUILD_DIR/slices/$s/sim-arm64/$LIBNAME" \
    "$BUILD_DIR/slices/$s/sim-x86/$LIBNAME"

  # Public headers in their own folder; hiredis.h includes its siblings with
  # quotes. hiredis_ssl.h is left out: the facade is plaintext.
  local hdr="$BUILD_DIR/headers/CHiredis"
  rmr "$hdr"; mkdir -p "$hdr/hiredis"
  cp "$src"/*.h "$hdr/hiredis/"
  rm -f "$hdr/hiredis/hiredis_ssl.h"
  write_modulemap "$hdr" CHiredis hiredis/hiredis.h
  info "hiredis headers staged"
}

# =====================================================================================
# mongo-c-driver 2.5.1  (libmongoc2 + libbson2; SSL/SASL/compression OFF = plaintext)
# =====================================================================================
build_mongoc() {
  local ver="2.5.1"
  local dir="mongo-c-driver-$ver"
  info "mongoc: fetch + build"
  fetch "https://github.com/mongodb/mongo-c-driver/releases/download/$ver/$dir.tar.gz" mongo-c-driver.tar.gz
  local src="$BUILD_DIR/$dir"
  local s="libmongoc"; LIBNAME="libmongoc_combined.a"

  # iOS device CMake config uses CMAKE_SYSTEM_NAME=iOS, which skips the Darwin-only
  # -D_DARWIN_C_SOURCE define that _SC_NPROCESSORS_ONLN needs. Patch once so "Apple"
  # matches both Darwin and iOS. Idempotent.
  local cl="$src/CMakeLists.txt"
  if ! grep -q 'if (APPLE)' "$cl"; then
    perl -0pi -e 's/if \(CMAKE_SYSTEM_NAME MATCHES "Darwin"\)/if (APPLE)/' "$cl"
  fi

  configure_slice() { # $1=name $2=arch $3=sysroot
    local name="$1" arch="$2" sysroot="$3"
    local bd="$BUILD_DIR/slices/$s/$name"
    rmr "$bd"
    cmake -S "$src" -B "$bd" \
      -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sysroot" \
      -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
      -DENABLE_STATIC=ON -DENABLE_SHARED=OFF \
      -DENABLE_TESTS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_MAN_PAGES=OFF -DENABLE_HTML_DOCS=OFF \
      -DENABLE_SSL=OFF -DENABLE_SASL=OFF -DENABLE_SNAPPY=OFF -DENABLE_ZSTD=OFF -DENABLE_ZLIB=OFF \
      -DENABLE_CLIENT_SIDE_ENCRYPTION=OFF -DENABLE_SRV=OFF -DENABLE_MONGODB_AWS_AUTH=OFF \
      -DENABLE_CRYPTO_SYSTEM_PROFILE=OFF -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER="$CC" >/dev/null 2>&1 || die "mongoc configure $name"
    cmake --build "$bd" -j8 --target mongoc_static >/dev/null 2>&1 || die "mongoc build $name"
    libtool -static -o "$bd/$LIBNAME" \
      "$bd/src/libbson/libbson2.a" "$bd/src/libmongoc/libmongoc2.a" 2>/dev/null \
      || die "mongoc merge $name"
  }
  configure_slice device arm64 "$IPHONEOS_SDK"
  configure_slice sim-arm64 arm64 "$IPHONESIM_SDK"
  configure_slice sim-x86 x86_64 "$IPHONESIM_SDK"

  # macOS slice
  local bdm="$BUILD_DIR/slices/$s/macos"
  rmr "$bdm"
  cmake -S "$src" -B "$bdm" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DENABLE_STATIC=ON -DENABLE_SHARED=OFF \
    -DENABLE_TESTS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_MAN_PAGES=OFF -DENABLE_HTML_DOCS=OFF \
    -DENABLE_SSL=OFF -DENABLE_SASL=OFF -DENABLE_SNAPPY=OFF -DENABLE_ZSTD=OFF -DENABLE_ZLIB=OFF \
    -DENABLE_CLIENT_SIDE_ENCRYPTION=OFF -DENABLE_SRV=OFF -DENABLE_MONGODB_AWS_AUTH=OFF \
    -DENABLE_CRYPTO_SYSTEM_PROFILE=OFF -DCMAKE_C_COMPILER="$CC" >/dev/null 2>&1 || die "mongoc configure macos"
  cmake --build "$bdm" -j8 --target mongoc_static >/dev/null 2>&1 || die "mongoc build macos"
  libtool -static -o "$bdm/$LIBNAME" "$bdm/src/libbson/libbson2.a" "$bdm/src/libmongoc/libmongoc2.a" 2>/dev/null

  mkdir -p "$BUILD_DIR/slices/$s/sim"
  lipo -create -output "$BUILD_DIR/slices/$s/sim/$LIBNAME" \
    "$BUILD_DIR/slices/$s/sim-arm64/$LIBNAME" \
    "$BUILD_DIR/slices/$s/sim-x86/$LIBNAME"

  # headers: cmake install emits the per-build config headers + public headers
  cmake --install "$BUILD_DIR/slices/$s/device" --prefix "$BUILD_DIR/mongoc-install" >/dev/null 2>&1
  local insthdr="$BUILD_DIR/mongoc-install/include"
  local hdr="$BUILD_DIR/headers/CMongoC"
  rmr "$hdr"; mkdir -p "$hdr"/mongoc "$hdr"/bson
  cp "$insthdr"/mongoc-*/mongoc/*.h "$hdr/mongoc/"
  cp "$insthdr"/bson-*/bson/*.h "$hdr/bson/"
  write_modulemap "$hdr" CMongoC mongoc/mongoc.h bson/bson.h
  info "mongoc headers staged"
}

# =====================================================================================
# libpq 18.4  (autoconf; OpenSSL/GSS/ICU/readline OFF = plaintext)
# =====================================================================================
build_libpq() {
  local ver="18.4"
  local dir="postgresql-$ver"
  info "libpq: fetch + build"
  fetch "https://ftp.postgresql.org/pub/source/v$ver/$dir.tar.gz" libpq-18.4.tar.gz
  local src="$BUILD_DIR/$dir"
  local s="libpq"; LIBNAME="libpq.a"

  configure_slice() { # $1=name $2=target $3=sysroot
    local name="$1" target="$2" sysroot="$3"
    local bd="$BUILD_DIR/slices/$s/$name"
    rmr "$bd"; mkdir -p "$bd"
    ( cd "$src"
      make distclean >/dev/null 2>&1 || true
      cross_compiling=yes ./configure \
        --host=aarch64-apple-darwin --build=x86_64-apple-darwin \
        --prefix="$bd" \
        --without-readline --without-zlib --without-openssl --without-gssapi \
        --without-icu --without-ldap --without-pam --without-bonjour \
        --without-tcl --without-perl --without-python \
        CPPFLAGS="-D_DARWIN_C_SOURCE" \
        CFLAGS="-O2 -target $target -isysroot $sysroot" \
        LDFLAGS="-target $target -isysroot $sysroot" CC="$CC" \
        --disable-nls --disable-debug >/dev/null 2>&1 || die "libpq configure $name"
      make -C src/interfaces/libpq -j8 >/dev/null 2>&1 || die "libpq make $name"
      # Capture libpq + its support libs for THIS slice NOW, before the next
      # slice's distclean wipes them. libpq.a alone cannot link: fe-*.o pull
      # pg_b64_*/pg_hmac_*/pg_saslprep/strong_random/explicit_bzero from the
      # FRONTEND variants of libpgcommon + libpgport. Use the *_shlib archives
      # (built with -DFRONTEND, export the PUBLIC symbols); the plain
      # libpgcommon.a/libpgport.a are the BACKEND variants (export *_private).
      libtool -static -o "$bd/$LIBNAME" \
        src/interfaces/libpq/libpq.a \
        src/common/libpgcommon_shlib.a src/port/libpgport_shlib.a 2>/dev/null \
        || die "libpq merge $name" ) || die "libpq slice $name"
  }
  configure_slice device "$IOS_DEVICE" "$IPHONEOS_SDK"
  configure_slice sim-arm64 "$IOS_SIM_ARM64" "$IPHONESIM_SDK"
  configure_slice sim-x86 "$IOS_SIM_X86" "$IPHONESIM_SDK"

  # macOS arm64
  ( cd "$src"
    make distclean >/dev/null 2>&1 || true
    ./configure --prefix="$BUILD_DIR/slices/$s/macos" \
      --without-readline --without-zlib --without-openssl --without-gssapi \
      --without-icu --without-ldap --without-pam --without-bonjour \
      --without-tcl --without-perl --without-python \
      CFLAGS="-O2 -target $MACOS_ARM64 -isysroot $MACOS_SDK" \
      LDFLAGS="-target $MACOS_ARM64 -isysroot $MACOS_SDK" CC="$CC" \
      --disable-nls --disable-debug >/dev/null 2>&1 || die "libpq configure macos"
    make -C src/interfaces/libpq -j8 >/dev/null 2>&1 || die "libpq make macos"
    mkdir -p "$BUILD_DIR/slices/$s/macos"
    libtool -static -o "$BUILD_DIR/slices/$s/macos/$LIBNAME" \
      src/interfaces/libpq/libpq.a \
      src/common/libpgcommon_shlib.a src/port/libpgport_shlib.a 2>/dev/null \
      || die "libpq merge macos" ) \
    || die "libpq macos slice"

  mkdir -p "$BUILD_DIR/slices/$s/sim"
  lipo -create -output "$BUILD_DIR/slices/$s/sim/$LIBNAME" \
    "$BUILD_DIR/slices/$s/sim-arm64/$LIBNAME" \
    "$BUILD_DIR/slices/$s/sim-x86/$LIBNAME"

  # libpq headers: public + per-build generated pg_config*.h, in their own
  # folder (libpq-fe.h includes postgres_ext.h with quotes).
  local hdr="$BUILD_DIR/headers/CPostgreSQL"
  rmr "$hdr"; mkdir -p "$hdr/libpq"
  cp "$src/src/interfaces/libpq/libpq-fe.h" "$hdr/libpq/"
  cp "$src/src/interfaces/libpq/libpq-events.h" "$hdr/libpq/"
  cp "$src/src/include/postgres_ext.h" "$hdr/libpq/"
  cp "$src/src/include/pg_config.h" "$hdr/libpq/" 2>/dev/null || true
  cp "$src/src/include/pg_config_manual.h" "$hdr/libpq/" 2>/dev/null || true
  cp "$src/src/include/pg_config_os.h" "$hdr/libpq/" 2>/dev/null || true
  write_modulemap "$hdr" CPostgreSQL libpq/libpq-fe.h
  info "libpq headers staged"
}

# =====================================================================================
# Writes <hdr>/<Module>/module.modulemap declaring the given headers (paths
# relative to <hdr>). See HEADER LAYOUT above for why it sits in a subfolder.
write_modulemap() { # $1=headers dir  $2=module  rest=headers
  local hdr="$1" module="$2"; shift 2
  mkdir -p "$hdr/$module"
  {
    echo "module $module [system] {"
    for h in "$@"; do echo "    header \"../$h\""; done
    echo "    export *"
    echo "}"
  } > "$hdr/$module/module.modulemap"
}

# Packages one library's device / simulator / macOS archives with its staged
# headers into <PREFIX_DIR>/<Module>.xcframework.
package_xcframework() { # $1=module  $2=slice dir under slices/  $3=archive name
  local module="$1" s="$2" lib="$3"
  local out="$PREFIX_DIR/$module.xcframework"
  local hdr="$BUILD_DIR/headers/$module"
  info "packaging $module.xcframework"

  # Replace the existing xcframework (move aside first; cannot rm a dir with -f).
  if [ -d "$out" ]; then
    local old="$out.old.$$"
    mv "$out" "$old" 2>/dev/null || die "cannot stage old $module.xcframework"
    rmr "$old"
  fi
  xcodebuild -create-xcframework \
    -library "$BUILD_DIR/slices/$s/device/$lib" -headers "$hdr" \
    -library "$BUILD_DIR/slices/$s/sim/$lib"    -headers "$hdr" \
    -library "$BUILD_DIR/slices/$s/macos/$lib"  -headers "$hdr" \
    -output "$out" 2>&1 | tail -2
}

package_all() {
  package_xcframework CMongoC libmongoc libmongoc_combined.a
  package_xcframework CPostgreSQL libpq libpq.a
  package_xcframework CHiredis libhiredis libhiredis.a
}

# --- main --------------------------------------------------------------------------
main() {
  local want="${1:-all}"
  case "$want" in
    clean) rmr "$PREFIX_DIR"/*.xcframework "$BUILD_DIR"/slices "$BUILD_DIR"/headers; info "cleaned";;
    all)   build_mongoc; build_libpq; build_hiredis; package_all;;
    *)     die "unknown '$want' (all|clean)";;
  esac
  info "done. XCFrameworks: $PREFIX_DIR/C*.xcframework"
}
main "$@"
