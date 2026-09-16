#!/usr/bin/env bash
# Build one architecture's FFmpeg shared libraries with the Zig toolchain and
# leave a packaged tarball in dist/.
#
# Usage: scripts/build.sh <arm64|x86_64>
set -euo pipefail

arch="${1:?usage: build.sh <arm64|x86_64>}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/ffmpeg.lock"
source "$root/scripts/configure-flags.sh"

: "${MACOS_DEPLOYMENT_TARGET:=11.0}"
work="$root/work/$arch"
prefix="$root/build/$arch"
dist="$root/dist"
name="ffmpeg-${FFMPEG_VERSION}-macos-${arch}"

rm -rf "$work" "$prefix"
mkdir -p "$work" "$prefix" "$dist" "$root/work/src"

# --- fetch, verified before it is ever unpacked -----------------------------
tarball="$root/work/src/ffmpeg-${FFMPEG_VERSION}.tar.xz"
if [ ! -f "$tarball" ]; then
  curl -fsSL --retry 3 -o "$tarball.part" "$FFMPEG_URL"
  mv "$tarball.part" "$tarball"
fi
echo "${FFMPEG_SHA256}  ${tarball}" | shasum -a 256 -c -

tar -xf "$tarball" -C "$work" --strip-components=1

# --- toolchain --------------------------------------------------------------
tools="$root/work/toolchain-$arch"
rm -rf "$tools"
MACOS_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET" "$root/scripts/toolchain.sh" "$arch" "$tools"

# Expanded as ${asm[@]+...} below: macOS ships bash 3.2, where an empty
# array under `set -u` is an unbound variable rather than nothing at all,
# and the arm64 build is the one that has no assembler flag to pass.
case "$arch" in
  arm64)  ffmpeg_arch=aarch64; asm=() ;;
  x86_64) ffmpeg_arch=x86_64;  asm=(--x86asmexe=nasm) ;;
esac

# Always cross-compiling, even when the host arch matches: the target triple
# pins a deployment floor the host does not share, so configure must not try
# to run what it just built to answer a question.
cd "$work"
./configure \
  --prefix="$prefix" \
  --enable-cross-compile \
  --target-os=darwin \
  --arch="$ffmpeg_arch" \
  --cc="$tools/cc" \
  --cxx="$tools/c++" \
  --ar="$tools/ar" \
  --ranlib="$tools/ranlib" \
  --extra-cflags="-mmacosx-version-min=${MACOS_DEPLOYMENT_TARGET}" \
  --extra-ldflags="-mmacosx-version-min=${MACOS_DEPLOYMENT_TARGET}" \
  ${asm[@]+"${asm[@]}"} \
  "${FFMPEG_CONFIGURE_FLAGS[@]}"

make -j"$(sysctl -n hw.ncpu)"
make install

"$root/scripts/package.sh" "$prefix" "$arch" "$dist/$name"
