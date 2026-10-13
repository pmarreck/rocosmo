# P6: smallest practical zstd decoder that can apply --patch-from deltas
# (raw-content reference prefix), built per target from upstream sources.

echo "P6 decode-only zstd with reference-prefix deltas"
p6="$SCRATCH/p6"
run_capture "$ROOT/probes/p6_zstd_decoder/build" "$p6"
assert_rc0 "decoder builds for every target"
for t in x86_64-linux-musl aarch64-linux-musl x86_64-macos aarch64-macos x86_64-windows aarch64-windows x86_64-freebsd x86_64-netbsd; do
	f="$p6/unpatch-$t"; case "$t" in *windows) f="$f.exe";; esac
	if [ -s "$f" ]; then pass "built $t ($(wc -c < "$f" | tr -d ' ') bytes)"; else fail "built $t" "missing $f"; fi
done

# Functional: the CLI makes a delta of one P2 payload against another, and the
# native x86_64 decoder rebuilds the exact target bytes from it.
p2_out="${p2_out:-$SCRATCH/p2}"
[ -f "$p2_out/app-x64win.exe" ] || "$ROOT/probes/p2_native_targets/build" "$p2_out" >/dev/null 2>&1
zstd -q -f -19 --patch-from="$p2_out/app-x64win.exe" -o "$p6/d.zst" "$p2_out/app-arm64win.exe"
run_capture "$p6/unpatch-x86_64-linux-musl" "$p2_out/app-x64win.exe" "$p6/d.zst" "$p6/rebuilt"
assert_rc0 "decoder applies a CLI-made delta"
run_capture cmp "$p6/rebuilt" "$p2_out/app-arm64win.exe"
assert_rc0 "rebuilt payload is byte-identical"
zstd -q -f -19 -o "$p6/w.zst" "$p2_out/app-arm64win.exe"
run_capture "$p6/unpatch-x86_64-linux-musl" - "$p6/w.zst" "$p6/rebuilt2"
run_capture cmp "$p6/rebuilt2" "$p2_out/app-arm64win.exe"
assert_rc0 "decoder also handles a whole frame with no reference (-)"
run_capture "$p6/unpatch-x86_64-linux-musl" "$p2_out/app-x64musl" "$p6/d.zst" "$p6/wrong"
case "$rc:$err" in [1-9]*"unpatch: "*) pass "wrong reference is rejected, not silently misdecoded";; *) fail "wrong reference rejection" "rc=$rc err=$err";; esac
