#!/bin/zsh
# Rebuilds Binary/Libssh2.xcframework from Shell's libssh2 + mbedTLS build
# (Shell/Binary/SSH-libssh2/build-ssh.sh).
#
# DuckDB bundles its own mbedTLS, so this copy's mbedTLS and PSA symbols get a
# _dbpro_ prefix, and its mbedtls/psa headers are dropped: Xcode merges every
# xcframework's headers into one include folder, where they'd shadow DuckDB's.
#
#   Scripts/build-libssh2.sh            (needs llvm-objcopy: brew install llvm)
set -euo pipefail
cd "${0:A:h}/.."

SRC=${SHELL_REPO:-../Shell}/Binary/SSH-libssh2/Libssh2.xcframework
OBJCOPY=${OBJCOPY:-$(command -v llvm-objcopy || echo /opt/homebrew/opt/llvm/bin/llvm-objcopy)}
OUT=$PWD/Binary/Libssh2.xcframework
WORK=$(mktemp -d)
trap 'rm -rf $WORK' EXIT

[[ -d $SRC ]] || { echo "No $SRC: build it with Shell/Binary/SSH-libssh2/build-ssh.sh"; exit 1; }
[[ -x $OBJCOPY ]] || { echo "No llvm-objcopy: brew install llvm"; exit 1; }

# Work on a copy; the simulator slice keeps arm64 only (Apple silicon), like DuckDB's.
cp -R $SRC $WORK/src
cd $WORK/src
lipo ios-arm64_x86_64-simulator/libssh2_sim.a -thin arm64 -output ios-arm64_x86_64-simulator/libssh2_sim.a

nm -g macos-arm64/libssh2_all.a ios-arm64/libssh2_all.a 2>/dev/null | awk '{print $NF}' \
  | grep -E '^_(mbedtls|psa|mbedcrypto|tf_psa)' | sort -u \
  | awk '{n = $1; sub(/^_/, "_dbpro_", n); print $1, n}' > $WORK/map.txt
echo "==> Prefixing $(wc -l < $WORK/map.txt | tr -d ' ') mbedTLS/PSA symbols with _dbpro_"

for f in macos-arm64/libssh2_all.a ios-arm64/libssh2_all.a ios-arm64_x86_64-simulator/libssh2_sim.a; do
  $OBJCOPY --redefine-syms=$WORK/map.txt $f $WORK/out.a && mv $WORK/out.a $f
done

find . -path '*/Headers/*' -type d \( -name mbedtls -o -name psa \) -prune -exec rm -rf {} +

left=$(nm -g macos-arm64/libssh2_all.a | awk '$2 != "U" {print $NF}' | grep -c '^_mbedtls' || true)
[[ $left == 0 ]] || { echo "$left mbedTLS symbols are still unprefixed"; exit 1; }

rm -rf $OUT && mkdir -p ${OUT:h}
xcodebuild -create-xcframework \
  -library macos-arm64/libssh2_all.a -headers macos-arm64/Headers \
  -library ios-arm64/libssh2_all.a -headers ios-arm64/Headers \
  -library ios-arm64_x86_64-simulator/libssh2_sim.a -headers ios-arm64_x86_64-simulator/Headers \
  -output $OUT >/dev/null
echo "==> $OUT"
