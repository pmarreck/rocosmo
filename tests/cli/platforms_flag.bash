# --rocosmo-platforms: a universal binary lists the OS/CPU targets it carries,
# without extracting or running any payload. The flag is namespaced so the
# wrapped app keeps every flag of its own.
# The dispatcher prints the list by reading its own case table, so the listing
# costs a fixed few hundred bytes of script however many targets there are.
echo "CLI: --rocosmo-platforms lists the targets a container carries"

pfx="$SCRATCH/platforms"; mkdir -p "$pfx"
pack_bin="${pack_bin:-$SCRATCH/p3/tool/bin/rocosmo-pack}"
if [ ! -x "$pack_bin" ]; then
	run_capture zig build --prefix "$SCRATCH/p3/tool" -Doptimize=ReleaseSafe
	assert_rc0 "build rocosmo-pack for the --rocosmo-platforms tests"
fi

# A runnable Linux x86_64 payload (exit 145) and a real Windows PE; the other
# slots only need bytes, since listing never runs them.
run_capture zig build-exe "$ROOT/examples/hello.zig" -target x86_64-linux-musl -O ReleaseSmall -femit-bin="$pfx/linux"
assert_rc0 "build the exit-145 Linux payload"
run_capture zig build-exe "$ROOT/examples/hello.zig" -target x86_64-windows -O ReleaseSmall -femit-bin="$pfx/win.exe"
assert_rc0 "build the Windows PE"
printf 'not run' > "$pfx/other"
posix_args=(--linux-x86_64 "$pfx/linux" --linux-riscv64 "$pfx/other" --macos-arm64 "$pfx/other" --freebsd-x86_64 "$pfx/other")
listing="linux-x86_64       Linux-x86_64|Linux-amd64
linux-riscv64      Linux-riscv64
macos-arm64        Darwin-arm64|Darwin-aarch64
freebsd-x86_64     FreeBSD-amd64|FreeBSD-x86_64"

for layout in zstd raw; do
	c="$pfx/u-$layout"
	run_capture "$pack_bin" --windows-x86_64 "$pfx/win.exe" "${posix_args[@]}" --layout "$layout" --level 3 --app-id dev.rocosmo.platforms -o "$c"
	assert_rc0 "pack a universal $layout container"
	run_capture env XDG_CACHE_HOME="$pfx/cache-$layout" sh "$c" --rocosmo-platforms
	assert_eq "universal $layout: --rocosmo-platforms lists Windows, then each POSIX target and its uname pattern" "0:windows-x86_64
$listing:" "$rc:$out:$err"
	assert_eq "universal $layout: listing extracts nothing (no cache directory)" "absent" "$([ -e "$pfx/cache-$layout" ] && echo present || echo absent)"
done

# Every supported shell, with only the tools the dispatcher needs on PATH.
tools="$(minimal_path "$pfx/bin" uname mkdir dd chmod mv rm gzip)"
for shell in dash bash zsh busybox oksh mksh; do
	if [ "$shell" = busybox ]; then cmd=("${ROCOSMO_BUSYBOX:?}" sh "$pfx/u-zstd"); else cmd=("$shell" "$pfx/u-zstd"); fi
	run_capture env -i PATH="$tools" XDG_CACHE_HOME="$pfx/cache-sh" "$(command -v "${cmd[0]}")" "${cmd[@]:1}" --rocosmo-platforms
	assert_eq "--rocosmo-platforms under $shell (PATH: uname mkdir dd chmod mv rm gzip)" "0:windows-x86_64
$listing:" "$rc:$out:$err"
done

# POSIX-only format: no Windows line.
run_capture "$pack_bin" "${posix_args[@]}" --layout zstd --level 3 -o "$pfx/posix"
assert_rc0 "pack a POSIX-only container"
run_capture sh "$pfx/posix" --rocosmo-platforms
assert_eq "POSIX-only: --rocosmo-platforms lists only the POSIX targets" "0:$listing" "$rc:$out"

# Launcher layout: the Windows entry lives in the index but is listed once, plainly.
run_capture "$pack_bin" --windows-x86_64 "$pfx/win.exe" "${posix_args[@]}" --windows-launcher --level 3 -o "$pfx/launcher"
assert_rc0 "pack a --windows-launcher container"
run_capture sh "$pfx/launcher" --rocosmo-platforms
assert_eq "launcher layout: Windows listed once, then the POSIX targets" "0:windows-x86_64
$listing" "$rc:$out"

# A custom --payload pattern has no target name.
run_capture "$pack_bin" --linux-x86_64 "$pfx/linux" --payload "Plan9-mips|Plan9-mipsel=$pfx/other" --layout raw -o "$pfx/custom"
assert_rc0 "pack a raw container with a custom pattern"
run_capture sh "$pfx/custom" --rocosmo-platforms
assert_eq "a custom --payload pattern is listed as (custom)" "0:linux-x86_64       Linux-x86_64|Linux-amd64
(custom)           Plan9-mips|Plan9-mipsel" "$rc:$out"

# The flag is ours only as the sole first argument; anything else is the app's.
run_capture sh "$pfx/u-zstd" --rocosmo-platforms extra
assert_eq "--rocosmo-platforms with more arguments is a usage error" "2:usage: $pfx/u-zstd --rocosmo-platforms" "$rc:$err"
run_capture env XDG_CACHE_HOME="$pfx/cache-app" sh "$pfx/u-zstd" build --rocosmo-platforms
assert_eq "--rocosmo-platforms after another argument reaches the app" "145" "$rc"

# Fit: the universal zstd format's script must stay inside the PE header area.
# Every target the table knows, with the listing, still packs.
all=()
for t in $(grep -o '\.name = "[^"]*"' "$ROOT/src/targets.zig" | cut -d'"' -f2); do all+=("--$t" "$pfx/other"); done
run_capture "$pack_bin" --windows-x86_64 "$pfx/win.exe" "${all[@]}" --layout zstd --level 1 -o "$pfx/all"
assert_rc0 "a universal zstd container with every known target and the listing still fits"
# This test's PE is small; the release inputs are stricter. zig.exe has 7
# sections (544 header bytes) and its first section at 0x1000, so the script
# (which ends at e_lfanew) may end no later than 3520.
lfanew=$(od -An -t u4 -j 60 -N 4 "$pfx/all" | tr -d ' ')
assert_eq "every known target plus the listing fits a 7-section PE's header area (script ends by 3520)" "1" "$([ "${lfanew:-99999}" -le 3520 ] && echo 1 || echo "0 ($lfanew)")"

host="${ROCOSMO_MACOS_ARM64_HOST-}"
if [ -z "$host" ]; then
	fail "macOS /bin/sh --rocosmo-platforms" "ROCOSMO_MACOS_ARM64_HOST not set"
else
	scp -q "${SSH_OPTS[@]}" "$pfx/u-zstd" "$host:rocosmo-platforms"
	run_capture ssh "${SSH_OPTS[@]}" "$host" "chmod 755 rocosmo-platforms && ./rocosmo-platforms --rocosmo-platforms"
	assert_eq "NATIVE macOS arm64 (/bin/sh): --rocosmo-platforms lists the targets" "windows-x86_64
$listing" "$out"
fi
