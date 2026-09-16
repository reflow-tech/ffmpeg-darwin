#!/usr/bin/env bash
# The build's shape, in one file, because it is the thing most often argued
# about and least often read in context.
#
# LGPL only: this ships inside a closed-source desktop app, so --disable-gpl
# is a licence boundary, not a size choice, and --disable-nonfree keeps a
# stray --enable-* from quietly making the artifact undistributable.
#
# --disable-autodetect is what makes the release reproducible: without it the
# build absorbs whatever the runner happens to have in /opt/homebrew, and two
# machines produce two different libraries under one version number. Every
# dependency is therefore opted in by name, and the only two are Apple's own
# frameworks.
FFMPEG_CONFIGURE_FLAGS=(
  --enable-shared
  --disable-static
  --disable-programs
  --disable-doc
  --disable-debug
  --disable-gpl
  --disable-nonfree
  --disable-autodetect
  --disable-network

  # The consumer links avformat, avcodec, swresample, swscale and avutil.
  # Nothing reaches avfilter or avdevice, and each one left in would be
  # another dylib to sign, notarize and ship. (postproc is GPL-only and
  # already gone with --disable-gpl; FFmpeg 9 dropped the flag for it.)
  --disable-avdevice
  --disable-avfilter

  # Apple's strip cannot read what Zig's linker writes ("bad n_sect for
  # symbol table entry"), and it runs during `make install`, so a stripped
  # build fails at the last step. The symbols stay; they cost some megabytes
  # on disk and nothing at runtime, and they are what makes a crash report
  # from the shipped app readable.
  --disable-stripping

  --enable-pthreads
  --enable-audiotoolbox
  --enable-videotoolbox

  # @rpath, so the consuming app decides where the dylibs live; an absolute
  # install name would bake this repository's build prefix into a shipped
  # binary and break the moment the bundle moves.
  --install-name-dir=@rpath
)
