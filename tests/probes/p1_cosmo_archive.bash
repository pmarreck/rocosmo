# P1: Roc `output: Archive` objects linked by the official cosmocc toolchain
# into one fat APE (x86_64 + aarch64). Each assertion names how it executed.

echo "P1 Roc archive -> cosmocc APE"
p1_out="$SCRATCH/p1"
run_capture "$ROOT/probes/p1_cosmo_archive/build" "$p1_out"
assert_rc0 "build script produced artifacts"

if [ -f "$p1_out/app.com" ]; then
	run_capture file -b "$p1_out/app.com"
	case "$out" in
		*"DOS/MBR"*|*"PE32"*|*"MS-DOS"*) pass "APE starts with an MZ/PE-compatible header ($out)";;
		*) fail "APE header type" "$out";;
	esac

	# Native: Linux x86_64 host, run through the APE shell/loader path with a
	# clean environment (see printable_binary's documented Exec format quirk).
	ape_tools="$(minimal_path "$SCRATCH/ape-tools" sh uname mkdir dd gzip chmod mv)"
	run_capture env -i PATH="$ape_tools" HOME="$SCRATCH" TMPDIR="$SCRATCH" sh "$p1_out/app.com" 20
	assert_eq "NATIVE linux x86_64 run, PATH limited to sh uname mkdir dd gzip chmod mv" "121" "$out"

	# Emulation: the embedded aarch64 ELF under qemu-user. NOT native evidence.
	if command -v qemu-aarch64 >/dev/null 2>&1; then
		run_capture qemu-aarch64 "$p1_out/app.aarch64.elf" 20
		assert_eq "EMULATED linux aarch64 (qemu-user) run" "121" "$out"
	else
		fail "EMULATED linux aarch64 run" "qemu-aarch64 unavailable"
	fi

	remote_run ROCOSMO_MACOS_ARM64_HOST rocosmo-p1.com "$p1_out/app.com" 20
	assert_eq "NATIVE macOS arm64 run (real host)" "121" "$out"
	[ "$rc" -eq 0 ] || fail "macOS arm64 run status" "$err"

	remote_run ROCOSMO_WINDOWS_X64_HOST rocosmo-p1.exe "$p1_out/app.com" 20
	assert_eq "NATIVE Windows x86_64 run (real host)" "121" "$(printf %s "$out" | tr -d "\r")"
	[ "$rc" -eq 0 ] || fail "Windows x86_64 run status" "$err"
else
	fail "APE artifact exists" "$p1_out/app.com missing"
fi
