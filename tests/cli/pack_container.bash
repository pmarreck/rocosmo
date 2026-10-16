# rocosmo-pack as one rocosmo container (scripts/build-pack-container): it runs
# on each host and packs containers there, byte-identical to this host's.

echo "CLI: rocosmo-pack as one container"
pcd="$SCRATCH/pack-container"; mkdir -p "$pcd"
run_capture "$ROOT/scripts/build-pack-container" "$pcd/rocosmo-pack"
assert_rc0 "build-pack-container packs rocosmo-pack for eight targets"
packc="$pcd/rocosmo-pack"
assert_eq "the rocosmo-pack container is universal (MZ)" "MZ" "$(head -c 2 "$packc" 2>/dev/null)"
run_capture env XDG_CACHE_HOME="$pcd/cache" "$packc" --about
case "$out" in "rocosmo-pack "*"(linux-x86_64)") pass "it runs here as the linux-x86_64 build";; *) fail "it runs here as the linux-x86_64 build" "$out $err";; esac

p2="${p2_out:-$SCRATCH/p2}"
inputs=(--windows-x86_64 app-x64win.exe --linux-x86_64 app-x64musl --linux-aarch64 app-arm64musl --macos-x86_64 app-x64mac --macos-arm64 app-arm64mac)
run_capture env -C "$p2" "$pack_bin" "${inputs[@]}" -o "$pcd/expected"
expected="$(sha256sum "$pcd/expected" | cut -d' ' -f1)"
run_capture env -C "$p2" XDG_CACHE_HOME="$pcd/cache" "$packc" "${inputs[@]}" -o "$pcd/app"
assert_eq "the container packs P2 byte-identically to the native rocosmo-pack" "$expected" "$(sha256sum "$pcd/app" | cut -d' ' -f1)"

p2files=(app-x64win.exe app-x64musl app-arm64musl app-x64mac app-arm64mac)
mac="${ROCOSMO_MACOS_ARM64_HOST-}"
if [ -z "$mac" ]; then
	fail "the rocosmo-pack container on macOS arm64" "ROCOSMO_MACOS_ARM64_HOST not set"
else
	d="rocosmo-pack-test-$$"
	run_capture bash -c "set -o pipefail; tar -C '$p2' -cf - ${p2files[*]} | ssh ${SSH_OPTS[*]} '$mac' 'mkdir -p $d && tar -xf - -C $d'"
	run_capture scp -q "${SSH_OPTS[@]}" "$packc" "$mac:$d/rocosmo-pack"
	run_capture ssh "${SSH_OPTS[@]}" "$mac" "cd $d && c=\$(mktemp -d) && XDG_CACHE_HOME=\$c ./rocosmo-pack --about && XDG_CACHE_HOME=\$c ./rocosmo-pack ${inputs[*]} -o app && shasum -a 256 app | cut -d' ' -f1 && XDG_CACHE_HOME=\$c ./app 20; cd .. && rm -rf $d \$c"
	assert_eq "NATIVE macOS arm64: the container runs, packs P2 identically, and the result runs" "macos-aarch64) $expected 121" "$(printf '%s' "$out" | sed 's/.*(//' | tr '\n' ' ' | sed 's/ $//')"
fi
win="${ROCOSMO_WINDOWS_X64_HOST-}"
if [ -z "$win" ]; then
	fail "the rocosmo-pack container on Windows x86_64" "ROCOSMO_WINDOWS_X64_HOST not set"
else
	d="rocosmo-pack-test-$$"
	run_capture ssh "${SSH_OPTS[@]}" "$win" "mkdir $d"
	run_capture scp -q "${SSH_OPTS[@]}" "${p2files[@]/#/$p2/}" "$win:$d/"
	run_capture scp -q "${SSH_OPTS[@]}" "$packc" "$win:$d/rocosmo-pack.exe"
	run_capture ssh "${SSH_OPTS[@]}" "$win" "cd $d && rocosmo-pack.exe --about && rocosmo-pack.exe ${inputs[*]} -o app.exe && rocosmo-pack.exe ${inputs[*]} -o - > piped.exe && certutil -hashfile app.exe SHA256 && certutil -hashfile piped.exe SHA256 && app.exe 20 && piped.exe 20"
	got="$(printf '%s' "$out" | tr -d '\r' | grep -v -i -E '^(SHA256 hash of|CertUtil)' | sed 's/.*(//' | tr '\n' ' ' | sed 's/ $//')"
	assert_eq "NATIVE Windows x86_64: the container runs, packs P2 identically (to a file and to stdout), and both results run" "windows-x86_64) $expected $expected 121 121" "$got"
	run_capture ssh "${SSH_OPTS[@]}" "$win" "rmdir /s /q $d"
fi
