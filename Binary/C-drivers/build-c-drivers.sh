#!/usr/bin/env bash
#
# build-c-drivers.sh — Cross-compile the C/C++ client libraries for the Database
# app's engines into a SINGLE Cdrivers.xcframework that a SwiftPM binaryTarget
# can consume. Libraries built (static-only) for every Apple slice:
#
#   iOS device (arm64), iOS simulator (arm64 + x86_64), macOS (arm64)
#
#   MongoDB   -> libmongoc + libbson      (mongo-c-driver, CMake)
#   PostgreSQL-> libpq + support libs      (postgresql, autoconf)
#   Redis     -> hiredis                   (hiredis, raw clang)
#   SSH       -> libssh2                   (from the sibling Shell repo's XCFramework)
#
# WHY ONE MERGED XCFRAMEWORK: SwiftPM 6.4 cannot host two or more raw C-module
# binaryTargets in one build graph — each ships a Headers/module.modulemap that
# SwiftPM flattens into the SAME Build/Products/<arch>/include/module.modulemap,
# colliding ("Multiple commands produce .../include/module.modulemap"). Merging
# all libraries into ONE XCFramework with ONE modulemap (declaring modules
# CMongoC / CPostgreSQL / CHiredis / CLibssh2)
# sidesteps the collision entirely while the Swift sources keep importing those
# exact module names.
#
# PREREQUISITES:
#   - Xcode 16+ (xcrun --sdk iphoneos / iphonesimulator / macosx)
#   - cmake, autoconf, libtool, make, perl   (brew install cmake autoconf)
#   - Internet (sources downloaded once; cached in build/.cache)
#   - The sibling Shell repo's libssh2 XCFramework (override $LIBSSH2_DIR)
#
# USAGE:
#   ./build-c-drivers.sh               # build + merge all libraries
#   ./build-c-drivers.sh clean         # remove Cdrivers.xcframework + slice outputs
#
# OUTPUT (committed):
#   Binary/C-drivers/Cdrivers.xcframework   -> consumed via .binaryTarget in Package.swift
#   Binary/C-drivers/build/                  -> scratch (sources, per-slice .a, headers)
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
  local hdr="$BUILD_DIR/headers"
  rmr "$hdr"; mkdir -p "$hdr"/mongoc "$hdr"/bson
  cp "$insthdr"/mongoc-*/mongoc/*.h "$hdr/mongoc/"
  cp "$insthdr"/bson-*/bson/*.h "$hdr/bson/"
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

  # libpq headers: public + per-build generated pg_config*.h
  mkdir -p "$BUILD_DIR/headers"
  cp "$src/src/interfaces/libpq/libpq-fe.h" "$BUILD_DIR/headers/"
  cp "$src/src/interfaces/libpq/libpq-events.h" "$BUILD_DIR/headers/"
  cp "$src/src/include/postgres_ext.h" "$BUILD_DIR/headers/"
  cp "$src/src/include/pg_config.h" "$BUILD_DIR/headers/" 2>/dev/null || true
  cp "$src/src/include/pg_config_manual.h" "$BUILD_DIR/headers/" 2>/dev/null || true
  cp "$src/src/include/pg_config_os.h" "$BUILD_DIR/headers/" 2>/dev/null || true
  info "libpq headers staged"
}

# =====================================================================================
package_cdrivers() {
  local out="$PREFIX_DIR/Cdrivers.xcframework"
  local merge="$BUILD_DIR/merge"
  rmr "$merge"; mkdir -p "$merge"/{device,sim,macos}
  local hdr="$BUILD_DIR/headers"

  # libssh2 slice archives (from the Shell repo's Binary/SSH-libssh2 build-ssh.sh).
  local libssh2_dir="${LIBSSH2_DIR:-/Users/v57/Projects/Shell/Binary/SSH-libssh2/Libssh2.xcframework}"
  local ls_dev="$libssh2_dir/ios-arm64/libssh2_all.a"
  local ls_sim="$libssh2_dir/ios-arm64_x86_64-simulator/libssh2_sim.a"
  local ls_mac="$libssh2_dir/macos-arm64/libssh2_all.a"
  [ -f "$ls_dev" ] && [ -f "$ls_sim" ] && [ -f "$ls_mac" ] \
    || die "libssh2 slice archives missing under $libssh2_dir (build with the Shell repo's build-ssh.sh)"

  info "merging archives + packaging Cdrivers.xcframework"
  libtool -static -o "$merge/device/libcdrivers_all.a" \
    "$BUILD_DIR/slices/libmongoc/device/libmongoc_combined.a" \
    "$BUILD_DIR/slices/libpq/device/libpq.a" \
    "$BUILD_DIR/slices/libhiredis/device/libhiredis.a" \
    "$ls_dev" \

  libtool -static -o "$merge/sim/libcdrivers_all.a" \
    "$BUILD_DIR/slices/libmongoc/sim/libmongoc_combined.a" \
    "$BUILD_DIR/slices/libpq/sim/libpq.a" \
    "$BUILD_DIR/slices/libhiredis/sim/libhiredis.a" \
    "$ls_sim" \

  libtool -static -o "$merge/macos/libcdrivers_all.a" \
    "$BUILD_DIR/slices/libmongoc/macos/libmongoc_combined.a" \
    "$BUILD_DIR/slices/libpq/macos/libpq.a" \
    "$BUILD_DIR/slices/libhiredis/macos/libhiredis.a" \
    "$ls_mac" \

  # hiredis core headers live in the extracted source; stage them (already staged
  # by build_mongoc into headers/ too) + write ONE modulemap declaring all modules.
  local hsrc="$BUILD_DIR/hiredis-1.4.1"
  cp "$hsrc"/*.h "$hdr/" 2>/dev/null
  rm -f "$hdr/hiredis_ssl.h"
  # libssh2 public headers (self-contained: only stddef/string/sys/stdint).
  cp "$libssh2_dir/macos-arm64/Headers/libssh2.h" \
     "$libssh2_dir/macos-arm64/Headers/libssh2_publickey.h" \
     "$libssh2_dir/macos-arm64/Headers/libssh2_sftp.h" "$hdr/" 2>/dev/null
  cat > "$hdr/module.modulemap" <<'EOF'
module CMongoC [system] {
    header "mongoc/mongoc.h"
    header "bson/bson.h"
    export *
}
module CPostgreSQL [system] {
    header "libpq-fe.h"
    export *
}
module CHiredis [system] {
    header "hiredis.h"
    export *
}
module CLibssh2 [system] {
    header "libssh2.h"
    export *
}
EOF

  # Replace the existing xcframework (move aside first; cannot rm a dir with -f).
  if [ -d "$out" ]; then
    local old="$out.old.$$"
    mv "$out" "$old" 2>/dev/null || die "cannot stage old xcframework"
    rmr "$old"
  fi
  xcodebuild -create-xcframework \
    -library "$merge/device/libcdrivers_all.a" -headers "$hdr" \
    -library "$merge/sim/libcdrivers_all.a"     -headers "$hdr" \
    -library "$merge/macos/libcdrivers_all.a"   -headers "$hdr" \
    -output "$out" 2>&1 | tail -2
  info "Cdrivers.xcframework written"
}

# --- main --------------------------------------------------------------------------
main() {
  local want="${1:-all}"
  case "$want" in
    clean) rmr "$PREFIX_DIR"/*.xcframework "$BUILD_DIR"/slices "$BUILD_DIR"/merge "$BUILD_DIR"/headers; info "cleaned";;
    all)   build_mongoc; build_libpq; build_hiredis; package_cdrivers;;
    *)     die "unknown '$want' (all|clean)";;
  esac
  info "done. XCFramework: $PREFIX_DIR/Cdrivers.xcframework"
}
main "$@"
