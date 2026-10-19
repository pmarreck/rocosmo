# --jobs N: rocosmo-pack compresses the zstd frames on N worker threads. Every
# frame is encoded on its own, so the container is the same for any N.
echo "CLI: --jobs compresses frames in parallel with identical output"

jbd="$SCRATCH/jobs"; mkdir -p "$jbd"
pack_bin="${pack_bin:-$SCRATCH/p3/tool/bin/rocosmo-pack}"
if [ ! -x "$pack_bin" ]; then
	run_capture zig build --prefix "$SCRATCH/p3/tool" -Doptimize=ReleaseSafe
	assert_rc0 "build rocosmo-pack for the --jobs tests"
fi

run_capture zig build-exe "$ROOT/examples/hello.zig" -target x86_64-windows -O ReleaseSmall -femit-bin="$jbd/win.exe"
assert_rc0 "build the Windows PE"
# Same-CPU payloads that share most bytes, so the packer also tries deltas.
for t in linux-x86_64 macos-x86_64 freebsd-x86_64 linux-aarch64 macos-arm64; do
	{ head -c 200000 "$jbd/win.exe"; printf '%s' "$t"; } > "$jbd/$t"
done
args=(--windows-x86_64 "$jbd/win.exe" --linux-x86_64 "$jbd/linux-x86_64" --macos-x86_64 "$jbd/macos-x86_64" --freebsd-x86_64 "$jbd/freebsd-x86_64" --linux-aarch64 "$jbd/linux-aarch64" --macos-arm64 "$jbd/macos-arm64" --level 9 --app-id dev.rocosmo.jobs)

# A missing or empty output never matches another one.
jsum() { if [ -s "$1" ]; then sha256sum < "$1"; else echo "no output: $1"; fi; }
run_capture "$pack_bin" "${args[@]}" --jobs 1 -o "$jbd/one"
assert_rc0 "--jobs 1 packs"
for n in 3 64; do
	run_capture "$pack_bin" "${args[@]}" --jobs "$n" -o "$jbd/many-$n"
	assert_rc0 "--jobs $n packs"
	assert_eq "--jobs $n output is byte-identical to --jobs 1" "$(jsum "$jbd/one")" "$(jsum "$jbd/many-$n")"
done
run_capture "$pack_bin" "${args[@]}" -o "$jbd/auto"
assert_eq "without --jobs (one worker per CPU, up to 8) the output is identical too" "$(jsum "$jbd/one")" "$(jsum "$jbd/auto")"
run_capture "$pack_bin" "${args[@]}" --jobs 64 --jobs 1 -o "$jbd/last"
assert_eq "a later --jobs overrides an earlier one" "0 $(jsum "$jbd/one")" "$rc $(jsum "$jbd/last")"

for bad in 0 -1 x 2x 1025; do
	run_capture "$pack_bin" "${args[@]}" --jobs "$bad" -o "$jbd/bad"
	assert_eq "--jobs $bad is refused" "2 rocosmo-pack: --jobs must be 1-1024" "$rc $err"
done
run_capture "$pack_bin" --help
case "$out" in *"--jobs N"*) pass "--help documents --jobs";; *) fail "--help documents --jobs" "$out";; esac
