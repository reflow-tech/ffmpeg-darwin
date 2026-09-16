# ffmpeg-darwin

FFmpeg shared libraries for macOS, built with the Zig toolchain and released
as tarballs. It exists so that the desktop app links an FFmpeg somebody chose,
at a version written down, with a deployment floor that is checked rather than
assumed — not whatever Homebrew installed on the machine that happened to run
the build.

- **Floor:** macOS 11 Big Sur (`-target <arch>-macos.11`), verified against
  `otool -l` in CI, not just requested in a flag.
- **Toolchain:** `zig cc` / `zig c++` / `zig ar`, so one runner cross-compiles
  both architectures and neither depends on the host's Xcode version beyond
  the SDK's headers and frameworks.
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

## Why the toolchain is a set of wrapper scripts

FFmpeg's darwin build speaks ld64, and Zig's Mach-O linker is stricter in
ways that each fail the build somewhere non-obvious. `scripts/toolchain.sh`
writes wrappers that reconcile the two, and every rewrite is recorded there
with the failure it prevents:

- SDK frameworks are included with `-iframework`, or FFmpeg's
  `-Werror=partial-availability` turns Apple's own headers into errors.
- The SDK's `/usr/include` and `/usr/lib` are added explicitly; `-isysroot`
  alone leaves `<libDER/DERItem.h>` and `libobjc.A.dylib` unfindable.
- `-dynamic` and `-single_module` are dropped, and `-compatibility_version 61`
  is padded to `61.0.0` — Zig rejects all three.
- A repeated `-l` is collapsed. FFmpeg names `-lavutil` twice when linking
  libswresample; ld64 dedupes it, Zig emits two `LC_LOAD_DYLIB` entries, and
  dyld then refuses to load the result.

Stripping is off for the same class of reason: Apple's `strip` cannot read
what Zig's linker writes, and it runs during `make install`.

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
