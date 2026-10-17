# P9: the BSD runtimes on real kernels. Pinned FreeBSD, NetBSD and OpenBSD
# releases boot under QEMU (KVM for x86_64, emulation for aarch64; OpenBSD is
# installed once from its miniroot, see run-in-vm); one packed
# container runs inside each, checking payload selection, arguments, exit
# status, the zstd runtime and the cache. VM disks are throwaway overlays in
# $SCRATCH; only the verified base images are cached between runs.

echo "P9 BSD containers in QEMU VMs"
p9="$SCRATCH/p9"; mkdir -p "$p9/bundle"
vm="$ROOT/probes/p9_bsd_vms"
pack_bin="$SCRATCH/p3/tool/bin/rocosmo-pack"
[ -x "$pack_bin" ] || { run_capture zig build --prefix "$SCRATCH/p3/tool" -Doptimize=ReleaseSafe; assert_rc0 "rocosmo-pack builds"; }
p2_out="${p2_out:-$SCRATCH/p2}"
[ -f "$p2_out/app-x64win.exe" ] || "$ROOT/probes/p2_native_targets/build" "$p2_out" >/dev/null 2>&1

# One C payload per target, each reporting which target it was built for.
# Zig ships no OpenBSD libc, so those payloads link against the flake's
# sysroot for their architecture.
p9_targets="freebsd-x86_64:x86_64-freebsd netbsd-x86_64:x86_64-netbsd openbsd-x86_64:x86_64-openbsd freebsd-aarch64:aarch64-freebsd openbsd-aarch64:aarch64-openbsd linux-x86_64:x86_64-linux-musl"
for a in x86_64 aarch64; do
	o="$ROCOSMO_OPENBSD_SYSROOT/$a"
	printf 'include_dir=%s/usr/include\nsys_include_dir=%s/usr/include\ncrt_dir=%s/usr/lib\nmsvc_lib_dir=\nkernel32_lib_dir=\ngcc_dir=\n' "$o" "$o" "$o" >"$p9/openbsd-libc-$a.txt"
done
pack_args=()
for pair in $p9_targets; do
	name="${pair%%:*}"
	libc=""; case "$name" in openbsd-*) libc="$p9/openbsd-libc-${name#*-}.txt" ;; esac
	run_capture env ${libc:+"ZIG_LIBC=$libc"} zig cc -target "${pair#*:}" -O2 -DTARGET="\"$name\"" "$vm/hello.c" -o "$p9/hello-$name"
	assert_rc0 "hello payload cross-compiles for $name"
	pack_args+=("--$name" "$p9/hello-$name")
done
for layout in zstd raw; do
	run_capture "$pack_bin" --windows-x86_64 "$p2_out/app-x64win.exe" "${pack_args[@]}" --layout "$layout" --app-id dev.rocosmo.p9 -o "$p9/bundle/app-$layout"
	assert_rc0 "pack the BSD payloads with --layout $layout"
done
run_capture "$pack_bin" "${pack_args[@]}" --layout zstd --app-id dev.rocosmo.p9 -o "$p9/bundle/app-posix"
assert_rc0 "pack the BSD payloads as a POSIX-only container"
run_capture "$ROOT/scripts/build-pack-container" "$p9/bundle/rocosmo-pack"
assert_rc0 "build rocosmo-pack as a container for the guests"
# Roc's own x64openbsd output (P2's app, on a platform that links OpenBSD's
# libc), packed with the Linux build of the same app.
run_capture "$pack_bin" --openbsd-x86_64 "$p2_out/app-x64openbsd" --linux-x86_64 "$p2_out/app-x64musl" --app-id dev.rocosmo.p9roc -o "$p9/bundle/roc-app"
assert_rc0 "pack Roc's x64openbsd and x64musl builds"
cp "$vm/guest.sh" "$p9/bundle/"

# Boot the guests concurrently; each prints the guest script's output.
p9_vms="freebsd-x86_64 netbsd-x86_64 openbsd-x86_64 freebsd-aarch64 openbsd-aarch64"
for os in $p9_vms; do
	"$vm/run-in-vm" "$os" "$p9/bundle" >"$p9/$os.out" 2>"$p9/$os.err" &
	eval "p9_pid_$(echo "$os" | tr - _)=$!"
done

p9_check() { # OS
	local os="$1" pid_var out
	pid_var="p9_pid_$(echo "$os" | tr - _)"
	wait "${!pid_var}"; rc=$?
	out="$(cat "$p9/$os.out")"
	[ "$rc" -eq 0 ] && pass "$os VM boots and runs the guest script" || { fail "$os VM run (rc=$rc)" "$(tail -n 20 "$p9/$os.err")"; return; }
	case "$out" in *"== zstd"*"hello $os [a b] [c]"*"rc=0"*) pass "$os: zstd container selects the $os payload and passes arguments";; *) fail "$os zstd run" "$out";; esac
	case "$out" in *"== again"*"hello $os [x]"*"rc=0"*) pass "$os: second run reuses the cached payload";; *) fail "$os cached run" "$out";; esac
	case "$out" in *"== direct"*"hello $os [d]"*"rc=0"*) pass "$os: running the file directly falls back to the shell dispatcher";; *) fail "$os direct exec" "$out";; esac
	case "$out" in *"== raw"*"hello $os [a b] [c]"*"rc=0"*) pass "$os: raw container selects the $os payload";; *) fail "$os raw run" "$out";; esac
	case "$out" in *"== status"*"rc=7"*) pass "$os: the payload's exit status comes back";; *) fail "$os exit status" "$out";; esac
	case "$out" in *"cache files=2"*) pass "$os: the zstd cache holds the runtime and one payload";; *) fail "$os cache contents" "$out";; esac
	case "$out" in *"== posix"*"hello $os [p]"*"rc=0"*) pass "$os: the POSIX-only container runs directly through its #!/bin/sh line";; *) fail "$os POSIX-only direct run" "$out";; esac
	case "$out" in *"== posix-sh"*"hello $os [q]"*"rc=0"*) pass "$os: the base sh runs the POSIX-only container";; *) fail "$os POSIX-only sh run" "$out";; esac
	case "$out" in *"== pack"*"rocosmo-pack "*"($os)"*"rc=0"*) pass "$os: the rocosmo-pack container runs its $os build";; *) fail "$os rocosmo-pack container" "$out";; esac
}
for os in $p9_vms; do p9_check "$os"; done
case "$(cat "$p9/openbsd-x86_64.out")" in *"== roc"*"121"*"rc=0"*) pass "openbsd-x86_64: Roc's x64openbsd build runs from a container";; *) fail "openbsd-x86_64 Roc app" "$(cat "$p9/openbsd-x86_64.out")";; esac
for os in netbsd-x86_64 openbsd-x86_64 openbsd-aarch64; do
	case "$(cat "$p9/$os.out")" in *"== ksh"*"hello $os [k]"*"rc=0"*) pass "$os: base ksh runs the container too";; *) fail "$os ksh run" "$(cat "$p9/$os.out")";; esac
	case "$(cat "$p9/$os.out")" in *"== posix-ksh"*"hello $os [r]"*"rc=0"*) pass "$os: base ksh runs the POSIX-only container";; *) fail "$os ksh POSIX-only run" "$(cat "$p9/$os.out")";; esac
done
