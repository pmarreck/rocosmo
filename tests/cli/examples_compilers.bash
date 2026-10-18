# Examples: the rocosmo technique is not specific to Roc. These are the fast,
# offline mechanism checks using the dev shell's own zig and rustc on one local
# slot: pack a third-party compiler (zig) and a compiler's output (a rust
# program) into a container, then dispatch, run and (for zig) compile from it.
# The full multi-OS containers are built on demand by examples/build-zig-container
# and examples/build-rust-container; their measured sizes and host runs are
# recorded in examples/README.md.

echo "CLI: examples (other compilers as rocosmo containers)"
exc="$SCRATCH/examples"; mkdir -p "$exc"
pack_bin="${pack_bin:-$SCRATCH/p3/tool/bin/rocosmo-pack}"
if [ ! -x "$pack_bin" ]; then
	run_capture zig build --prefix "$SCRATCH/p3/tool" -Doptimize=ReleaseSafe
	assert_rc0 "build rocosmo-pack for the examples"
fi

# --- Zig: pack the zig executable itself, then run and compile from it. ---
zig_real="$(readlink -f "$(command -v zig)" 2>/dev/null)"
zig_lib="$(zig env 2>/dev/null | sed -n 's/.*\.lib_dir = "\(.*\)",/\1/p')"
if [ -x "$pack_bin" ] && [ -n "$zig_real" ] && [ -n "$zig_lib" ]; then
	run_capture "$pack_bin" --layout zstd --level 3 --app-id dev.rocosmo.zigx --linux-x86_64 "$zig_real" -o "$exc/zig"
	assert_rc0 "pack the zig compiler into a container"
	run_capture env XDG_CACHE_HOME="$exc/zc" "$exc/zig" version
	assert_eq "the zig container reports zig's own version" "$(zig version)" "$out"
	# Zig finds its std lib next to its executable; from the container that copy
	# is not on disk, so point ZIG_LIB_DIR at a matching lib/ (Zig's own rule).
	run_capture env ZIG_LIB_DIR="$zig_lib" XDG_CACHE_HOME="$exc/zc" "$exc/zig" build-exe "$ROOT/examples/hello.zig" -femit-bin="$exc/zhello" -O ReleaseSmall --cache-dir "$exc/zig-cache" --global-cache-dir "$exc/zig-gcache"
	assert_rc0 "the zig container compiles examples/hello.zig"
	run_capture "$exc/zhello"
	assert_eq "the zig-compiled program exits 145 (= 12*12+1)" "145" "$rc"
else
	fail "zig and rocosmo-pack available for the examples" "zig=[$zig_real] lib=[$zig_lib] pack=[$pack_bin]"
fi

# --- Rust: compile the example program, pack it, run it from the container. ---
if [ -x "$pack_bin" ] && command -v rustc >/dev/null 2>&1; then
	run_capture rustc -O --edition 2021 -o "$exc/rhello" "$ROOT/examples/rust_hello/src/main.rs"
	assert_rc0 "compile examples/rust_hello with the host rustc"
	run_capture "$pack_bin" --layout zstd --level 3 --app-id dev.rocosmo.rustx --linux-x86_64 "$exc/rhello" -o "$exc/rust"
	assert_rc0 "pack the rust program into a container"
	run_capture env XDG_CACHE_HOME="$exc/rc" "$exc/rust"
	assert_eq "the rust container prints 145 (= 12*12+1)" "145" "$out"
else
	fail "rustc and rocosmo-pack available for the examples" "rustc=[$(command -v rustc 2>/dev/null)] pack=[$pack_bin]"
fi
