# P2: Roc's own cross-compilation plus a Zig host that uses only each OS's
# own interface (raw syscalls, libSystem, KERNEL32, or OpenBSD's libc, the
# only caller its kernel accepts system calls from). One Linux build produces
# per-target executables; assert format, OS dependencies, and runs.

echo "P2 Roc-native per-target executables (no C runtime beyond the OS interface)"
p2_out="$SCRATCH/p2"
run_capture "$ROOT/probes/p2_native_targets/build" "$p2_out"
assert_rc0 "build script produced all target executables"

p2_expect_file() { # target pattern
	local f="$p2_out/app-$1"; [ -f "$f" ] || f="$f.exe"
	run_capture file -b "$f"
	case "$out" in $2) pass "$1 format: $out";; *) fail "$1 format" "$out";; esac
}
p2_expect_file x64musl   '*ELF 64-bit*x86-64*statically linked*'
p2_expect_file arm64musl '*ELF 64-bit*ARM aarch64*statically linked*'
p2_expect_file x64mac    '*Mach-O 64-bit*x86_64*'
p2_expect_file arm64mac  '*Mach-O 64-bit*arm64*'
p2_expect_file x64win    '*PE32+*x86-64*'
p2_expect_file arm64win  '*PE32+*ARM64*'
p2_expect_file x64openbsd '*ELF 64-bit*x86-64*interpreter /usr/libexec/ld.so*for OpenBSD*'

# Dependency classifier over the whole set: every artifact may depend only on
# the OS interface (nothing, libSystem, KERNEL32, or OpenBSD's libc), never on
# another C runtime.
for t in x64musl arm64musl; do
	run_capture readelf -ld "$p2_out/app-$t"
	if printf '%s' "$out" | grep -qE 'INTERP|NEEDED'; then fail "$t has no interpreter or NEEDED" "$out"; else pass "$t has no interpreter or NEEDED libraries"; fi
done
for t in x64mac arm64mac; do
	run_capture llvm-otool -L "$p2_out/app-$t"
	libs="$(printf '%s\n' "$out" | tail -n +2 | awk '{print $1}' | sort -u | tr '\n' ' ')"
	assert_eq "$t links only libSystem" "/usr/lib/libSystem.B.dylib " "$libs"
done
run_capture readelf -d "$p2_out/app-x64openbsd"
libs="$(printf '%s\n' "$out" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | sort -u | tr '\n' ' ')"
assert_eq "x64openbsd links only OpenBSD's libc" "libc.so.103.0 " "$libs"
for t in x64win arm64win; do
	run_capture llvm-objdump -p "$p2_out/app-$t.exe"
	dlls="$(printf '%s\n' "$out" | awk '/DLL Name:/{print toupper($3)}' | sort -u | tr '\n' ' ')"
	assert_eq "$t imports only KERNEL32.DLL" "KERNEL32.DLL " "$dlls"
done

run_capture "$p2_out/app-x64musl" 20
assert_eq "NATIVE linux x86_64 run" "121" "$out"
run_capture qemu-aarch64 "$p2_out/app-arm64musl" 20
assert_eq "EMULATED linux aarch64 (qemu-user) run" "121" "$out"
remote_run ROCOSMO_MACOS_ARM64_HOST rocosmo-p2-arm64mac "$p2_out/app-arm64mac" 20
assert_eq "NATIVE macOS arm64 run (real host)" "121" "$out"
remote_run ROCOSMO_WINDOWS_X64_HOST rocosmo-p2-x64win.exe "$p2_out/app-x64win.exe" 20
assert_eq "NATIVE Windows x86_64 run (real host)" "121" "$(printf %s "$out" | tr -d '\r')"
