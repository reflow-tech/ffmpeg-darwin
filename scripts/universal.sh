#!/usr/bin/env bash
# Fuse the two per-arch trees into one universal2 tarball.
#
# Only the Mach-O files differ between them: the headers are the same text,
# and the .pc files are the same after the prefix rewrite -- so arm64 supplies
# the tree and lipo replaces every binary in it. A header that genuinely
# differed would be a build bug, and the comparison below is what catches it.
#
# Usage: scripts/universal.sh <arm64-dir> <x86_64-dir> <dist/name>
set -euo pipefail

a="${1:?arm64 tree}"
b="${2:?x86_64 tree}"
out="${3:?output path without .tar.gz}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/ffmpeg.lock"

if ! diff -r "$a/include" "$b/include" >/dev/null; then
  echo "error: the two architectures produced different headers" >&2
  diff -r "$a/include" "$b/include" | head -40 >&2
  exit 1
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
name="$(basename "$out")"
dir="$stage/$name"
mkdir -p "$dir"
cp -R "$a/include" "$dir/include"
cp -R "$a/lib" "$dir/lib"

find "$a/lib" -name '*.dylib' -type f | while read -r lib; do
  rel="${lib#"$a"/}"
  lipo -create "$a/$rel" "$b/$rel" -output "$dir/$rel"
done

cp "$a/BUILD-INFO" "$dir/BUILD-INFO"
/usr/bin/sed -i '' 's|^arch: .*|arch: universal2 (arm64, x86_64)|' "$dir/BUILD-INFO"
for f in "$a"/COPYING.* "$a"/LICENSE.md; do [ -f "$f" ] && cp "$f" "$dir/"; done

mkdir -p "$(dirname "$out")"
tar -czf "$out.tar.gz" -C "$stage" "$name"
shasum -a 256 "$out.tar.gz" | /usr/bin/sed "s|$(dirname "$out")/||" > "$out.tar.gz.sha256"
echo "packaged $out.tar.gz"
