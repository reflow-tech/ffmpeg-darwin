#!/usr/bin/env bash
# Writes the toolchain FFmpeg is built with into a directory.
#
#   scripts/toolchain.sh <arm64|x86_64> <outdir>
#
# FFmpeg's configure wants plain executables it can invoke, not a `zig cc`
# word pair, so every tool here is a wrapper script.
#
# The wrappers compile with Zig and link with Apple's linker, and that split
# is the whole design:
#
#   Compiling is Zig's. The target triple is what puts a macOS 11 floor in
#   every object -- `-macos.11` is what makes these dylibs load on Big Sur --
#   and Zig's headers and libc are what keep the build the same on any
#   machine. The SDK is named explicitly rather than detected, so a runner
#   with several Xcodes cannot pick a different one between the configure
#   probes and the build.
#
#   Linking is ld64's, because Zig's Mach-O linker silently ignores
#   -exported_symbols_list. FFmpeg passes one for every library, and without
#   it each dylib exports its internal symbols as well -- ___dso_handle among
#   them, which then captures a consuming binary's own reference and fails
#   its link outright ("target '___dso_handle' does not have address"). A
#   library nothing can link against is not a library, and no flag makes Zig
#   honour the list. Linking through ld64 also lets -single_module, -dynamic
#   and FFmpeg's bare -compatibility_version mean what they were written to
#   mean, so none of them needs rewriting on the way past.
#
# Link mode is anything that is not -c/-S/-E, which is how a compiler driver
# has always decided it. The objects Zig produced are ordinary Mach-O, so
# ld64 takes them as they are.
#
# Two compile flags are load-bearing, and both are Zig meeting Apple's SDK:
#
#   -iframework marks the SDK's frameworks as system headers. Without it,
#   FFmpeg's -Werror=partial-availability turns Apple's own headers into
#   build errors -- CMTag.h declaring a macOS 14 symbol is enough to fail a
#   macOS 11 build. -F stays beside it for framework search.
#
#   -idirafter adds the SDK's /usr/include. Zig ships its own libc headers
#   and puts them first, which is fine until a framework header reaches for
#   an SDK-only header beside them -- Security's oids.h including
#   <libDER/DERItem.h> is the one that breaks the VideoToolbox probe.
#   Appending it leaves Zig's headers winning every name they define.
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
clang="$(xcrun --find clang)"
clangxx="$(xcrun --find clang++)"
triple="${zig_arch}-macos.${MACOS_DEPLOYMENT_TARGET}-none"
frameworks="$sdk/System/Library/Frameworks"

compile_flags="-target $triple -isysroot \"$sdk\" -iframework \"$frameworks\" -F\"$frameworks\" -idirafter \"$sdk/usr/include\" -L\"$sdk/usr/lib\""
# ld64 is reached through Apple's clang driver, which needs the two facts the
# triple carried on the Zig side: which architecture, and which macOS the
# result has to keep running on.
link_flags="-arch $arch -mmacosx-version-min=$MACOS_DEPLOYMENT_TARGET -isysroot \"$sdk\""

mkdir -p "$outdir"

emit_driver() { # emit_driver <wrapper name> <zig subcommand> <linker driver>
  local name="$1" sub="$2" driver="$3"
  cat > "$outdir/$name" <<WRAPPER
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    -c|-S|-E) exec "$ZIG" $sub $compile_flags "\$@" ;;
  esac
done
exec "$driver" $link_flags "\$@"
WRAPPER
  chmod +x "$outdir/$name"
}

emit_zig() { # emit_zig <wrapper name> <zig subcommand>
  printf '#!/bin/sh\nexec "%s" %s "$@"\n' "$ZIG" "$2" > "$outdir/$1"
  chmod +x "$outdir/$1"
}

emit_driver cc cc "$clang"
emit_driver c++ c++ "$clangxx"
emit_zig ar ar
emit_zig ranlib ranlib
