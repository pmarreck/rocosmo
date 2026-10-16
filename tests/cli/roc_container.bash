# The Roc compiler as one rocosmo container (scripts/build-roc-container):
# it runs on each OS the Roc nightlies cover and builds apps that pack into
# more containers. Packed at --level 3 to keep the suite fast.

echo "CLI: the Roc compiler as one container"
rcd="$SCRATCH/roc-container"; mkdir -p "$rcd"
run_capture env ROCOSMO_PACK="$pack_bin" "$ROOT/scripts/build-roc-container" "$rcd/roc" --level 3
assert_rc0 "build-roc-container packs the five Roc nightlies"
rocc="$rcd/roc"
assert_eq "the Roc container is universal (MZ)" "MZ" "$(head -c 2 "$rocc" 2>/dev/null)"
native_version="$(roc version)"
run_capture env XDG_CACHE_HOME="$rcd/cache" "$rocc" version
assert_eq "the Roc container runs here and reports the pinned nightly" "$native_version" "$out"

# It builds P2 for every target rocosmo-pack takes, and those join into a container.
p2src="${p2_out:-$SCRATCH/p2}/src"
built=()
for pair in "x64musl linux-x86_64" "arm64musl linux-aarch64" "x64mac macos-x86_64" "arm64mac macos-arm64" "x64win windows-x86_64"; do
	read -r rt slot <<<"$pair"
	exe="$rcd/app-$rt"; [ "$rt" = x64win ] && exe="$exe.exe"
	run_capture env XDG_CACHE_HOME="$rcd/cache" "$rocc" build --target="$rt" --output="$exe" "$p2src/app.roc"
	assert_rc0 "the Roc container builds P2 for $rt"
	built+=("--$slot" "$exe")
done
run_capture "$pack_bin" "${built[@]}" -o "$rcd/app"
assert_rc0 "its builds pack into a container"
run_capture env XDG_CACHE_HOME="$rcd/cache" "$rcd/app" 20
assert_eq "that container runs here" "121" "$out"

# Real hosts. The container is about 440 MB, so each host keeps one copy named
# by content hash and removes older ones.
roc_name="rocosmo-roc-$(sha256sum "$rocc" | cut -c1-16)"
mac="${ROCOSMO_MACOS_ARM64_HOST-}"
if [ -z "$mac" ]; then
	fail "the Roc container on macOS arm64" "ROCOSMO_MACOS_ARM64_HOST not set"
else
	run_capture ssh "${SSH_OPTS[@]}" "$mac" "test -f $roc_name || exit 3"
	[ "$rc" = 3 ] && run_capture scp -q "${SSH_OPTS[@]}" "$rocc" "$mac:$roc_name"
	run_capture bash -c "set -o pipefail; tar -C '$p2src/..' -cf - src | ssh ${SSH_OPTS[*]} '$mac' 'd=rocosmo-roc-p2; rm -rf \$d; mkdir \$d && tar -xf - -C \$d'"
	assert_rc0 "ship P2's sources to the macOS host"
	run_capture ssh "${SSH_OPTS[@]}" "$mac" "for f in rocosmo-roc-????????????????; do [ \"\$f\" = $roc_name ] || rm -f \"\$f\"; done
		c=\$(mktemp -d); ./$roc_name version; arch -x86_64 env XDG_CACHE_HOME=\$c/x ./$roc_name version
		XDG_CACHE_HOME=\$c ./$roc_name build --target=arm64mac --output=rocosmo-roc-p2/app rocosmo-roc-p2/src/app.roc >/dev/null 2>&1 && rocosmo-roc-p2/app 20; rm -rf \$c"
	assert_eq "NATIVE macOS arm64 and Rosetta 2 run the Roc container; it builds an arm64mac app that runs" "$native_version
$native_version
121" "$out"
fi
win="${ROCOSMO_WINDOWS_X64_HOST-}"
if [ -z "$win" ]; then
	fail "the Roc container on Windows x86_64" "ROCOSMO_WINDOWS_X64_HOST not set"
else
	run_capture ssh "${SSH_OPTS[@]}" "$win" "if not exist $roc_name.exe exit 3"
	[ "$rc" = 3 ] && run_capture scp -q "${SSH_OPTS[@]}" "$rocc" "$win:$roc_name.exe"
	run_capture ssh "${SSH_OPTS[@]}" "$win" "for %f in (rocosmo-roc-*.exe) do @if /i not \"%f\"==\"$roc_name.exe\" del \"%f\""
	run_capture ssh "${SSH_OPTS[@]}" "$win" "if exist rocosmo-roc-p2 rmdir /s /q rocosmo-roc-p2"
	run_capture scp -q -r "${SSH_OPTS[@]}" "$p2src" "$win:rocosmo-roc-p2"
	assert_rc0 "ship P2's sources to the Windows host"
	run_capture ssh "${SSH_OPTS[@]}" "$win" "$roc_name.exe version && $roc_name.exe build --target=x64win --output=rocosmo-roc-p2\\app.exe rocosmo-roc-p2\\app.roc >nul 2>&1 && rocosmo-roc-p2\\app.exe 20"
	assert_eq "NATIVE Windows x86_64 runs the Roc container (as .exe); it builds an x64win app that runs" "$native_version
121" "$(printf '%s' "$out" | tr -d '\r')"
fi
