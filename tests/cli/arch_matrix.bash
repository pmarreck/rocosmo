# Architecture matrix: rocosmo's headline capability is one compressed container
# that runs native code on many CPU architectures. Roc's own nightly ships only
# five targets, so this proof is Roc-independent: it cross-compiles a tiny
# exit-145 program (examples/hello.zig) for every Linux architecture rocosmo
# supports, packs them into ONE zstd-layout container, and then, for each
# architecture, (1) checks the runtime the container carries is byte-identical
# to the one we built and (2) runs the full rebuild+exec path under qemu-user,
# asserting the payload exits 145 (= 12*12 + 1). Native x86_64 goes through the
# real shell dispatcher. This is the mechanical, falsifiable, per-architecture
# control behind the "runs on N architectures" claim; qemu-user runs the real
# foreign binary, so a wrong decoder, runtime or dispatch value fails here.
echo "CLI: architecture matrix (one zstd container, many CPUs, via qemu-user)"

amx="$SCRATCH/arch-matrix"; mkdir -p "$amx/hw"
pack_bin="${pack_bin:-$SCRATCH/p3/tool/bin/rocosmo-pack}"
rt_dir="${rt_dir:-$SCRATCH/p3/tool/runtime}"
if [ ! -x "$pack_bin" ]; then
	run_capture zig build --prefix "$SCRATCH/p3/tool" -Doptimize=ReleaseSafe
	assert_rc0 "build rocosmo-pack for the architecture matrix"
fi

# slot -> (Zig musl triple, qemu-user emulator). x86_64 runs natively.
am_triple() { case "$1" in
	linux-x86_64) echo x86_64-linux-musl;;      linux-aarch64) echo aarch64-linux-musl;;
	linux-arm) echo arm-linux-musleabihf;;      linux-riscv64) echo riscv64-linux-musl;;
	linux-powerpc64le) echo powerpc64le-linux-musl;; linux-x86) echo x86-linux-musl;;
	linux-loongarch64) echo loongarch64-linux-musl;; linux-s390x) echo s390x-linux-musl;;
esac; }
am_qemu() { case "$1" in
	linux-aarch64) echo qemu-aarch64;; linux-arm) echo qemu-arm;;
	linux-riscv64) echo qemu-riscv64;; linux-powerpc64le) echo qemu-ppc64le;;
	linux-s390x) echo qemu-s390x;; linux-loongarch64) echo qemu-loongarch64;;
	linux-x86) echo qemu-i386;;
esac; }
# uname-m case value in the container for each slot (first alternative suffices).
am_pattern() { case "$1" in
	linux-x86_64) echo Linux-x86_64;; linux-aarch64) echo Linux-aarch64;;
	linux-arm) echo Linux-armv7l;; linux-riscv64) echo Linux-riscv64;;
	linux-powerpc64le) echo Linux-ppc64le;; linux-x86) echo Linux-i686;;
	linux-loongarch64) echo Linux-loongarch64;; linux-s390x) echo Linux-s390x;;
esac; }

slots="linux-x86_64 linux-aarch64 linux-arm linux-riscv64 linux-powerpc64le linux-x86 linux-loongarch64 linux-s390x"

# Cross-compile the exit-145 proof program for every slot, then pack one container.
pack_args=(--layout zstd --level 6 --app-id dev.rocosmo.archmatrix)
ok=1
for s in $slots; do
	run_capture zig build-exe "$ROOT/examples/hello.zig" -target "$(am_triple "$s")" -O ReleaseSmall -femit-bin="$amx/hw/$s"
	assert_rc0 "cross-compile the exit-145 payload for $s"
	[ -s "$amx/hw/$s" ] || ok=0
	pack_args+=("--$s" "$amx/hw/$s")
done
container="$amx/container"
run_capture "$pack_bin" "${pack_args[@]}" -o "$container"
assert_rc0 "pack one zstd container with every Linux architecture"

# Index offsets for the runtime's CLI (x=offset y=len), from the script region.
xy="$(head -c 8192 "$container" | LC_ALL=C awk -F'[ =]+' '/(^|[^a-z])x=/ { for (i = 1; i < NF; i++) { if ($i == "x") xo = $(i+1); if ($i == "y") yo = $(i+1) } if (xo != "" && yo != "") { print xo, yo; exit } }')"
X="${xy% *}" Y="${xy#* }"
assert_eq "the container exposes a numeric index offset/length" "1" "$([ -n "$X" ] && [ -n "$Y" ] && echo 1)"

# Field value for a case pattern (o=runtime offset, n=runtime gzipped length).
# A case line starts with the pattern, which may be '|'-joined alternatives
# (Linux-x86_64|Linux-amd64), so match the first alternative at line start
# followed by ')' or '|', exactly as the dispatcher's shell `case` does.
am_field() { head -c 8192 "$container" | LC_ALL=C awk -F'[ =;]+' -v pat="$1" -v key="$2" 'index($0, pat ")") == 1 || index($0, pat "|") == 1 { for (i = 1; i < NF; i++) if ($i == key) { print $(i+1); exit } }'; }

matrix_pass=0 matrix_total=0
for s in $slots; do
	# The container carries this architecture's runtime: extract and compare to
	# the one the build produced (dd the gzip slice out, decompress).
	o="$(am_field "$(am_pattern "$s")" o)" n="$(am_field "$(am_pattern "$s")" n)"
	ex="$amx/rt-$s"
	dd if="$container" bs=1 skip="$o" count="$n" 2>/dev/null | gzip -dc > "$ex" 2>/dev/null && chmod 755 "$ex"
	run_capture cmp "$ex" "$rt_dir/$s"
	assert_rc0 "$s: the container's embedded runtime is byte-identical to the built runtime"

	q="$(am_qemu "$s")"
	if [ -z "$q" ]; then
		# Native x86_64: run the container itself through the shell dispatcher.
		run_capture env XDG_CACHE_HOME="$amx/cache-native" sh "$container"
		assert_eq "NATIVE $s runs the container through the shell dispatcher (exit 145)" "145" "$rc"
		matrix_total=$((matrix_total + 1)); [ "$rc" = 145 ] && matrix_pass=$((matrix_pass + 1))
		continue
	fi
	if ! command -v "$q" >/dev/null 2>&1; then
		fail "$s emulator available" "$q not found (nixpkgs#qemu)"; continue
	fi
	# Memory path: the runtime rebuilds into a memfd and execs it (Linux fast path).
	run_capture "$q" "$rt_dir/$s" --exec "$container" "$X" "$Y" "$s" "$s"
	assert_eq "EMULATED $s: runtime rebuilds the payload into memory and runs it (exit 145)" "145" "$rc"
	matrix_total=$((matrix_total + 1)); [ "$rc" = 145 ] && matrix_pass=$((matrix_pass + 1))
	# Cache path: the runtime writes the payload to a file, which then runs.
	out_bin="$amx/out-$s"
	run_capture "$q" "$rt_dir/$s" "$container" "$X" "$Y" "$s" "$out_bin"
	assert_rc0 "$s: runtime rebuilds the payload to a file (cache path)"
	chmod 755 "$out_bin" 2>/dev/null
	run_capture "$q" "$out_bin"
	assert_eq "EMULATED $s: the rebuilt payload file runs (exit 145)" "145" "$rc"
	matrix_total=$((matrix_total + 1)); [ "$rc" = 145 ] && matrix_pass=$((matrix_pass + 1))
done
assert_eq "every architecture in the matrix ran correctly" "$matrix_total $matrix_total" "$matrix_total $matrix_pass"
