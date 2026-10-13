# P4: the full pipeline (pinned Roc + Zig host + rocosmo-pack) on another
# build host must reproduce the local container byte-for-byte. Byte identity
# is a differential oracle: every run proven for the local file then holds.

echo "P4 build on a macOS arm64 host reproduces the container"
host="${ROCOSMO_MACOS_ARM64_HOST-}"
local_app="$SCRATCH/p3/app"
if [ -z "$host" ]; then
	fail "macOS arm64 build host" "ROCOSMO_MACOS_ARM64_HOST not set"
elif [ ! -f "$local_app" ]; then
	fail "macOS arm64 build host" "local P3 container missing"
else
	rev="$(git -C "$ROOT" rev-parse --short HEAD)"
	dir="/tmp/rocosmo-p4-$rev-$$"
	inputs='--windows-x86_64 out/p2/app-x64win.exe --linux-x86_64 out/p2/app-x64musl --linux-aarch64 out/p2/app-arm64musl --macos-x86_64 out/p2/app-x64mac --macos-arm64 out/p2/app-arm64mac'
	pack_args="$inputs -o out/app"
	p2="${p2_out:-$SCRATCH/p2}"
	inputs_local=(--windows-x86_64 "$p2/app-x64win.exe" --linux-x86_64 "$p2/app-x64musl" --linux-aarch64 "$p2/app-arm64musl" --macos-x86_64 "$p2/app-x64mac" --macos-arm64 "$p2/app-arm64mac")
	run_capture bash -c "set -o pipefail; cd '$ROOT' && git ls-files -z | tar --null -T - -cf - | ssh ${SSH_OPTS[*]} '$host' 'mkdir -p $dir && tar -x -C $dir'"
	assert_rc0 "ship the tracked working tree (based on $rev) to the macOS host"
	run_capture ssh "${SSH_OPTS[@]}" "$host" "cd $dir && nix develop -c bash -c 'probes/p2_native_targets/build out/p2 && zig build --prefix out/tool && out/tool/bin/rocosmo-pack $pack_args && XDG_CACHE_HOME=out/cache ./out/app 20 && shasum -a 256 out/app && out/tool/bin/rocosmo-pack $inputs --layout zstd -o out/app-zstd && XDG_CACHE_HOME=out/cache-zstd ./out/app-zstd 20 && shasum -a 256 out/app-zstd' 2>/dev/null"
	assert_eq "macOS-built container runs natively on its build host" "121" "$(printf '%s\n' "$out" | grep -x '[0-9]*' | tail -1)"
	remote_hash="$(printf '%s\n' "$out" | awk '/out\/app$/{print $1}')"
	local_hash="$(sha256sum "$local_app" | awk '{print $1}')"
	assert_eq "macOS-built container is byte-identical to the Linux-built one" "$local_hash" "$remote_hash"
	# zstd layout: also covers the seven runtimes cross-built on macOS and zstd
	# encoding in a ReleaseFast vs ReleaseSafe packer.
	assert_eq "macOS-built zstd container runs natively on its build host" "121 121" "$(printf '%s\n' "$out" | grep -x '[0-9]*' | tr '\n' ' ' | sed 's/ $//')"
	remote_zstd_hash="$(printf '%s\n' "$out" | awk '/out\/app-zstd$/{print $1}')"
	run_capture "$SCRATCH/p3/tool/bin/rocosmo-pack" "${inputs_local[@]}" --layout zstd -o "$SCRATCH/p4-app-zstd"
	assert_eq "macOS-built zstd container is byte-identical to the Linux-built one" "$(sha256sum "$SCRATCH/p4-app-zstd" | awk '{print $1}')" "$remote_zstd_hash"
fi
