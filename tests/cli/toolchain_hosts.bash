# Build hosts without Nix or Zig: on the Windows and macOS hosts, the Roc
# container (roc_container.bash) builds P2 for all five targets and the
# rocosmo-pack container (pack_container.bash) packs them; the result runs on
# the build host and here. Uses $rocc, $roc_name and $packc from those suites,
# and the P2 sources roc_container.bash left on each host.

echo "CLI: Windows and macOS as build hosts, with only the two containers"
tch="$SCRATCH/toolchain-hosts"; mkdir -p "$tch"
p2_inputs="--windows-x86_64 h-x64win.exe --linux-x86_64 h-x64musl --linux-aarch64 h-arm64musl --macos-x86_64 h-x64mac --macos-arm64 h-arm64mac"

win="${ROCOSMO_WINDOWS_X64_HOST-}"
if [ -z "$win" ]; then
	fail "Windows as a build host" "ROCOSMO_WINDOWS_X64_HOST not set"
else
	run_capture scp -q "${SSH_OPTS[@]}" "$packc" "$win:rocosmo-roc-p2/rocosmo-pack.exe"
	run_capture ssh "${SSH_OPTS[@]}" "$win" "cd rocosmo-roc-p2 && (for %t in (x64musl arm64musl x64mac arm64mac x64win) do @..\\$roc_name.exe build --target=%t --output=h-%t app.roc >nul 2>&1 || echo failed %t) && copy /y h-x64win h-x64win.exe >nul && rocosmo-pack.exe $p2_inputs -o built.exe && built.exe 20"
	assert_eq "Windows builds all five P2 targets with the Roc container, packs them with the rocosmo-pack container, and the result runs there" "121" "$(printf '%s' "$out" | tr -d '\r')"
	run_capture scp -q "${SSH_OPTS[@]}" "$win:rocosmo-roc-p2/built.exe" "$tch/win-built"
	run_capture env XDG_CACHE_HOME="$tch/cache" sh "$tch/win-built" 20
	assert_eq "the Windows-built container runs here" "121" "$out"
fi

mac="${ROCOSMO_MACOS_ARM64_HOST-}"
if [ -z "$mac" ]; then
	fail "macOS as a build host" "ROCOSMO_MACOS_ARM64_HOST not set"
else
	run_capture scp -q "${SSH_OPTS[@]}" "$packc" "$mac:rocosmo-roc-p2/rocosmo-pack"
	run_capture ssh "${SSH_OPTS[@]}" "$mac" "cd rocosmo-roc-p2 && c=\$(mktemp -d) && for t in x64musl arm64musl x64mac arm64mac x64win; do o=h-\$t; [ \$t = x64win ] && o=\$o.exe; XDG_CACHE_HOME=\$c ../$roc_name build --target=\$t --output=\$o src/app.roc >/dev/null 2>&1 || echo failed \$t; done; XDG_CACHE_HOME=\$c ./rocosmo-pack $p2_inputs -o built && XDG_CACHE_HOME=\$c ./built 20; rm -rf \$c"
	assert_eq "macOS builds all five P2 targets with the Roc container, packs them with the rocosmo-pack container, and the result runs there" "121" "$out"
	run_capture scp -q "${SSH_OPTS[@]}" "$mac:rocosmo-roc-p2/built" "$tch/mac-built"
	run_capture env XDG_CACHE_HOME="$tch/cache" sh "$tch/mac-built" 20
	assert_eq "the macOS-built container runs here" "121" "$out"
fi
