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

rm -rf $OUT && mkdir -p ${OUT:h} && cp -R $SRC $OUT
cd $OUT

nm -g macos-arm64/libssh2_all.a ios-arm64/libssh2_all.a 2>/dev/null | awk '{print $NF}' \
  | grep -E '^_(mbedtls|psa|mbedcrypto|tf_psa)' | sort -u \
  | awk '{n = $1; sub(/^_/, "_dbpro_", n); print $1, n}' > $WORK/map.txt
echo "==> Prefixing $(wc -l < $WORK/map.txt | tr -d ' ') mbedTLS/PSA symbols with _dbpro_"

for f in macos-arm64/libssh2_all.a ios-arm64/libssh2_all.a; do
  $OBJCOPY --redefine-syms=$WORK/map.txt $f $WORK/out.a && mv $WORK/out.a $f
done
# llvm-objcopy rewrites thin archives only: split the simulator's fat archive and join it again.
sim=ios-arm64_x86_64-simulator/libssh2_sim.a
for arch in arm64 x86_64; do
  lipo $sim -thin $arch -output $WORK/sim-$arch.a
  $OBJCOPY --redefine-syms=$WORK/map.txt $WORK/sim-$arch.a $WORK/sim-$arch-out.a
done
lipo -create $WORK/sim-arm64-out.a $WORK/sim-x86_64-out.a -output $sim

find . -path '*/Headers/*' -type d \( -name mbedtls -o -name psa \) -prune -exec rm -rf {} +

left=$(nm -g macos-arm64/libssh2_all.a | awk '$2 != "U" {print $NF}' | grep -c '^_mbedtls' || true)
[[ $left == 0 ]] || { echo "$left mbedTLS symbols are still unprefixed"; exit 1; }
echo "==> $OUT"
