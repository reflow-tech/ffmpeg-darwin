#!/usr/bin/env bash
# Writes a Zig-backed compiler toolchain into a directory.
#
#   scripts/toolchain.sh <arm64|x86_64> <outdir>
#
# FFmpeg's configure wants plain executables it can invoke, not a `zig cc`
# word pair, so every tool here is a wrapper script. The macOS deployment
# floor lives in the target triple -- `-macos.11` is what makes the resulting
# dylibs load on Big Sur -- and the SDK is passed explicitly rather than left
# to detection, so a runner with several Xcodes installed cannot pick a
# different one between the configure probes and the build.
#
# Two of the flags are load-bearing, and both are Zig meeting Apple's SDK:
#
#   -iframework marks the SDK's frameworks as system headers. Without it,
#   FFmpeg's -Werror=partial-availability turns Apple's own headers into
#   build errors -- CMTag.h declaring a macOS 14 symbol is enough to fail a
#   macOS 11 build. -F stays beside it for the linker's framework search.
#
#   -idirafter adds the SDK's /usr/include. Zig ships its own libc headers
#   and puts them first, which is fine until a framework header reaches for
#   an SDK-only header beside them -- Security's oids.h including
#   <libDER/DERItem.h> is the one that breaks the VideoToolbox probe.
#   Appending it leaves Zig's headers winning every name they define.
#
# -L on the SDK's /usr/lib is the link-time half of the same gap: -isysroot
# does not become a library search root for Zig's linker, so a dylib that
# links CoreFoundation fails on CoreFoundation.tbd's own dependency --
# libobjc.A.dylib, which the linker looks for everywhere except the SDK.
set -euo pipefail

arch="${1:?usage: toolchain.sh <arm64|x86_64> <outdir>}"
outdir="${2:?usage: toolchain.sh <arm64|x86_64> <outdir>}"

case "$arch" in
  arm64)  zig_arch=aarch64 ;;
  x86_64) zig_arch=x86_64 ;;
  *) echo "unknown arch: $arch" >&2; exit 2 ;;
esac

: "${MACOS_DEPLOYMENT_TARGET:=11.0}"
: "${ZIG:=zig}"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
triple="${zig_arch}-macos.${MACOS_DEPLOYMENT_TARGET}-none"
frameworks="$sdk/System/Library/Frameworks"
sdkflags="-target $triple -isysroot \"$sdk\" -iframework \"$frameworks\" -F\"$frameworks\" -idirafter \"$sdk/usr/include\" -L\"$sdk/usr/lib\""

mkdir -p "$outdir"

# Every compiler wrapper rewrites its own argument list before handing it to
# Zig, because FFmpeg's darwin link lines speak ld64 and Zig's Mach-O linker
# is stricter in three places. None of the rewrites change what gets built:
#
#   -dynamic and -single_module are ld64 defaults that Zig rejects outright
#   ("unsupported linker arg"). -dynamic rides on every configure probe that
#   links, so leaving it in fails checks (videotoolbox among them) that have
#   nothing to do with linking; -single_module rides on every dylib.
#
#   -compatibility_version 61 is a version Zig will not parse: it wants
#   major.minor.patch, and FFmpeg passes a library's bare major. Padding it
#   to 61.0.0 records the same version ld64 would have.
#
#   A repeated -l is harmless to ld64, which dedupes it, and produces a
#   broken dylib with Zig, which does not: FFmpeg names -lavutil twice when
#   linking libswresample, and the result carries two LC_LOAD_DYLIB entries
#   for it. dyld refuses to load that ("duplicate linked dylib"), so the
#   library builds and then aborts the first process that opens it. Keeping
#   only the first occurrence is what ld64 does. Mach-O has no archive
#   ordering to preserve, so nothing else depends on the repeat.
#
# Flags arrive both bare and inside a -Wl, list, so both spellings are
# handled, and anything sharing that list passes through untouched.
wrapper_body() {
  cat <<'BODY'
pad_version() {
  case "$1" in
    *.*.*) printf '%s' "$1" ;;
    *.*)   printf '%s.0' "$1" ;;
    *)     printf '%s.0.0' "$1" ;;
  esac
}

n=$#
i=0
pad_next=0
seen_libs=" "
while [ $i -lt $n ]; do
  a="$1"; shift
  i=$((i + 1))
  if [ "$pad_next" = 1 ]; then
    pad_next=0
    set -- "$@" "$(pad_version "$a")"
    continue
  fi
  case "$a" in
    -dynamic|-single_module) ;;
    -compatibility_version|-current_version)
      pad_next=1
      set -- "$@" "$a"
      ;;
    -l*)
      case "$seen_libs" in
        *" $a "*) ;;
        *) seen_libs="$seen_libs$a "; set -- "$@" "$a" ;;
      esac
      ;;
    -Wl,*)
      a=$(printf '%s' "$a" \
        | sed -E 's/(^|,)-(dynamic|single_module)(,|$)/\1/g; s/,$//' \
        | awk -F, 'BEGIN{OFS=","} {
            for (j = 1; j <= NF; j++)
              if ($j == "-compatibility_version" || $j == "-current_version") {
                if ($(j+1) !~ /\./) $(j+1) = $(j+1) ".0.0"
                else if ($(j+1) !~ /\..*\./) $(j+1) = $(j+1) ".0"
              }
            print
          }')
      [ "$a" = "-Wl" ] || set -- "$@" "$a"
      ;;
    *) set -- "$@" "$a" ;;
  esac
done
BODY
}

emit() { # emit <wrapper name> <zig subcommand> [flags baked into the wrapper]
  local name="$1" sub="$2" flags="${3:-}"
  {
    echo '#!/bin/sh'
    wrapper_body
    echo "exec \"$ZIG\" $sub $flags \"\$@\""
  } > "$outdir/$name"
  chmod +x "$outdir/$name"
}

emit cc cc "$sdkflags"
emit c++ c++ "$sdkflags"
emit ar ar
emit ranlib ranlib
