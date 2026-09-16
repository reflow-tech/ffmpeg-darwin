#!/usr/bin/env bash
# Turn an install prefix into a relocatable tarball.
#
# Usage: scripts/package.sh <prefix> <arch-label> <dist/name-without-extension>
set -euo pipefail

prefix="${1:?prefix}"
label="${2:?arch label}"
out="${3:?output path without .tar.gz}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/ffmpeg.lock"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
name="$(basename "$out")"
dir="$stage/$name"
mkdir -p "$dir"

cp -R "$prefix/include" "$dir/include"
cp -R "$prefix/lib" "$dir/lib"
rm -rf "$dir/lib"/*.a "$dir/share" 2>/dev/null || true

# A .pc file records the prefix it was configured with, which is a path on the
# machine that built it and exists nowhere else. Rewriting it to pcfiledir is
# what lets a consumer unpack the tarball anywhere, point PKG_CONFIG_PATH at
# lib/pkgconfig, and have both the Zig and the cgo link find these headers.
#
# FFmpeg writes libdir and includedir out in full rather than deriving them
# from the prefix, so rewriting prefix alone would leave a .pc that resolves
# to the build machine and fails silently on anyone else's -- which is why
# all three lines are rewritten and the result is asserted below.
for pc in "$dir"/lib/pkgconfig/*.pc; do
  [ -f "$pc" ] || continue
  /usr/bin/sed -i '' \
    -e 's|^prefix=.*|prefix=${pcfiledir}/../..|' \
    -e 's|^libdir=.*|libdir=${prefix}/lib|' \
    -e 's|^includedir=.*|includedir=${prefix}/include|' \
    "$pc"
  if /usr/bin/grep -q "$prefix" "$pc"; then
    echo "error: $(basename "$pc") still names the build prefix" >&2
    exit 1
  fi
done

cat > "$dir/BUILD-INFO" <<INFO
ffmpeg $FFMPEG_VERSION
arch: $label
macos-min: ${MACOS_DEPLOYMENT_TARGET:-11.0}
source: $FFMPEG_URL
source-sha256: $FFMPEG_SHA256
built: $(date -u +%Y-%m-%dT%H:%M:%SZ)
toolchain: zig $("${ZIG:-zig}" version)
INFO

for f in LICENSE.md COPYING.LGPLv2.1 COPYING.LGPLv3; do
  [ -f "$root/work/${label}/$f" ] && cp "$root/work/${label}/$f" "$dir/" || true
done

mkdir -p "$(dirname "$out")"
tar -czf "$out.tar.gz" -C "$stage" "$name"
shasum -a 256 "$out.tar.gz" | /usr/bin/sed "s|$(dirname "$out")/||" > "$out.tar.gz.sha256"
echo "packaged $out.tar.gz"
