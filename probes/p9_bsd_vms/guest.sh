#!/bin/sh
# P9 guest script, run inside each BSD VM from the unpacked bundle directory.
# Prints one "== NAME" section per case; the host test asserts on them.
c=/tmp/rocosmo-p9
run() { name=$1; shift; echo "== $name"; XDG_CACHE_HOME=$c/$layout "$@"; echo "rc=$?"; }
uname -sm
layout=zstd
run zstd sh ./app-zstd "a b" c
run again sh ./app-zstd x
run direct ./app-zstd d
run status sh ./app-zstd seven
echo "cache files=$(find "$c/zstd" -type f | wc -l | tr -d ' ')"
layout=raw
run raw sh ./app-raw "a b" c
layout=zstd
if command -v ksh >/dev/null; then run ksh ksh ./app-zstd k; fi
layout=posix
run posix ./app-posix p
run posix-sh sh ./app-posix q
if command -v ksh >/dev/null; then run posix-ksh ksh ./app-posix r; fi
