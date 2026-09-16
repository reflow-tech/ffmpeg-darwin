#!/usr/bin/env bash
# Move the mirror to another FFmpeg release.
#
#   scripts/update-ffmpeg.sh            # latest upstream release
#   scripts/update-ffmpeg.sh 8.1.2      # a named release
#   scripts/update-ffmpeg.sh --check    # print the latest, change nothing
#
# The checksum is never copied from upstream's page: the tarball is downloaded
# and hashed here, so what lands in ffmpeg.lock is a hash of bytes this script
# actually saw. A build then verifies against it, which is the only reason the
# lock is worth having.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock="$root/ffmpeg.lock"

latest_release() {
  # Release tarballs are what ffmpeg.org publishes; the git tags are the index
  # of them. Snapshots and -dev tags are deliberately excluded -- a mirror
  # pins releases, and "whatever master is today" is not a version.
  curl -fsSL "https://api.github.com/repos/FFmpeg/FFmpeg/tags?per_page=100" \
    | /usr/bin/grep -oE '"name": "n[0-9]+\.[0-9]+(\.[0-9]+)?"' \
    | /usr/bin/sed -E 's/.*"n(.*)"/\1/' \
    | sort -V | tail -1
}

case "${1:-}" in
  --check)
    echo "current: $(/usr/bin/grep '^FFMPEG_VERSION=' "$lock" | cut -d= -f2)"
    echo "latest:  $(latest_release)"
    exit 0
    ;;
  "") version="$(latest_release)" ;;
  *)  version="${1#n}" ;;
esac

current="$(/usr/bin/grep '^FFMPEG_VERSION=' "$lock" | cut -d= -f2)"
if [ "$version" = "$current" ]; then
  echo "already on ffmpeg $version"
  exit 0
fi

url="https://ffmpeg.org/releases/ffmpeg-${version}.tar.xz"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "fetching $url"
curl -fsSL --retry 3 -o "$tmp/ffmpeg.tar.xz" "$url"
sha="$(shasum -a 256 "$tmp/ffmpeg.tar.xz" | cut -d' ' -f1)"

# Unpack far enough to prove the archive is the release it claims to be; a
# 404 page saved under a .tar.xz name would otherwise hash cleanly and only
# fail hours later inside a CI build.
tar -tf "$tmp/ffmpeg.tar.xz" "ffmpeg-${version}/configure" >/dev/null

/usr/bin/sed -i '' \
  -e "s|^FFMPEG_VERSION=.*|FFMPEG_VERSION=${version}|" \
  -e "s|^FFMPEG_SHA256=.*|FFMPEG_SHA256=${sha}|" \
  -e "s|^FFMPEG_URL=.*|FFMPEG_URL=${url}|" \
  "$lock"

echo "ffmpeg.lock: ${current} -> ${version}"
echo "sha256: ${sha}"
echo
echo "Next: run scripts/build.sh arm64 locally, or push and let the workflow"
echo "build it. A major-version bump changes the soname of every dylib, so"
echo "check the consuming project's pinned library versions before tagging."
