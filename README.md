# ffmpeg-darwin

FFmpeg shared libraries for macOS, built with the Zig toolchain and released
as tarballs. It exists so that the desktop app links an FFmpeg somebody chose,
at a version written down, with a deployment floor that is checked rather than
assumed — not whatever Homebrew installed on the machine that happened to run
the build.

- **Floor:** macOS 11 Big Sur (`-target <arch>-macos.11`), verified against
  `otool -l` in CI, not just requested in a flag.
- **Toolchain:** `zig cc` compiles and Apple's `ld64` links. Zig gives one
  runner both architectures and a deployment floor carried in the target
  triple; ld64 is what honours FFmpeg's export lists, which Zig's Mach-O
  linker ignores. See below.
- **Licence:** LGPL only. `--disable-gpl --disable-nonfree`, plus Apple's
  AudioToolbox and VideoToolbox.
- **Libraries:** `avformat`, `avcodec`, `swresample`, `swscale`, `avutil`.
  `avdevice`, `avfilter` and `postproc` are off — nothing consuming this
  reaches them.

## Releases

Each release carries three tarballs plus a `.sha256` beside each:

| artifact | contents |
| --- | --- |
| `ffmpeg-<v>-macos-arm64.tar.gz` | Apple silicon |
| `ffmpeg-<v>-macos-x86_64.tar.gz` | Intel |
| `ffmpeg-<v>-macos-universal2.tar.gz` | both, fused with `lipo` |

Each unpacks to `include/`, `lib/` (dylibs and `pkgconfig/`), a `BUILD-INFO`
naming the source and its checksum, and the upstream licence texts.

## Using one

The dylibs' install name is `@rpath`, and the `.pc` files resolve their prefix
from `${pcfiledir}`, so the tree is relocatable — unpack it anywhere and point
`pkg-config` at it:

```sh
tar -xzf ffmpeg-9.0.1-macos-arm64.tar.gz
export PKG_CONFIG_PATH="$PWD/ffmpeg-9.0.1-macos-arm64/lib/pkgconfig"
pkg-config --modversion libavcodec
```

That one variable covers both layers of the consuming build: the Zig side
discovers FFmpeg through `pkg-config` only, and the cgo link uses
`#cgo pkg-config` for the same libraries. The app bundle is then responsible
for shipping the dylibs and setting an `LC_RPATH` that finds them.

## Compile with Zig, link with ld64

`scripts/toolchain.sh` writes wrapper scripts that send `-c`/`-S`/`-E` to
`zig cc` and everything else to Apple's `clang`. The split is not a
compromise between two tastes; each half does something the other cannot.

Zig compiles. The target triple is what puts a macOS 11 floor in every
object, and Zig's own headers and libc are what keep the result the same on
any machine. Two flags are load-bearing there, both of them Zig meeting
Apple's SDK: `-iframework`, without which FFmpeg's
`-Werror=partial-availability` turns Apple's headers into errors (CMTag.h
declares a macOS 14 symbol), and `-idirafter` on the SDK's `/usr/include`,
without which Security's `oids.h` cannot find `<libDER/DERItem.h>` and the
VideoToolbox probe fails.

ld64 links, because Zig's Mach-O linker silently ignores
`-exported_symbols_list`. FFmpeg passes one for every library, and without it
each dylib exports its internal symbols as well — `___dso_handle` among them,
which captures a consuming binary's own reference and fails that link with
`target '___dso_handle' does not have address`. A library nothing can link
against is not a library, and no flag makes Zig honour the list. Linking
through ld64 also lets `-single_module`, `-dynamic` and FFmpeg's bare
`-compatibility_version 61` mean what they were written to mean, and lets
`strip` read the output during `make install` — with Zig linking, each of
those needed a workaround, and now none of them does.

## Building locally

Needs Zig 0.16, Xcode command line tools, and `nasm` for the x86_64 target
(`brew install nasm`).

```sh
scripts/build.sh arm64          # -> dist/ffmpeg-<v>-macos-arm64.tar.gz
scripts/build.sh x86_64
scripts/universal.sh <arm64-tree> <x86_64-tree> dist/ffmpeg-<v>-macos-universal2
```

## Moving to a new FFmpeg

`ffmpeg.lock` is the single source of the version, its URL and its SHA256, and
the build verifies the download against it before unpacking. Change it only
through the script, which downloads the tarball and hashes the bytes it
actually received:

```sh
scripts/update-ffmpeg.sh --check   # current vs latest upstream release
scripts/update-ffmpeg.sh           # move to the latest release
scripts/update-ffmpeg.sh 8.1.2     # move to a named release
```

The `update-ffmpeg` workflow runs the same script weekly and opens a pull
request when upstream moves, so the build workflow answers whether the new
version compiles before anyone merges it.

A major bump changes the soname of every dylib (`libavcodec.63.dylib` and so
on). That is a change in what consumers link against, so it is checked at the
consumer before a tag is cut here.

## Cutting a release

Push a `v*` tag. The build workflow builds both architectures, fuses the
universal tarball and attaches all three with their checksums. The tag names
this repository's release, not FFmpeg's — `v1` packaging FFmpeg 9.0.1 is
normal, and `BUILD-INFO` records which upstream version is inside.
