# The opt-in --windows-launcher layout. On Linux we cannot run the Windows
# launcher itself (its runtime behavior and the Defender scan are checked on
# the Windows host, tests/cli/toolchain_hosts.bash), but we can verify the
# container it produces: the front is a KERNEL32-only PE (the launcher, not the
# app), the launcher's descriptor is patched with the index location and the
# app entry, and the stored Windows payload rebuilds byte-for-byte. The last is
# an independent decode by the native runtime, whose oracle is the input PE.

echo "CLI: --windows-launcher layout"
wl="$SCRATCH/wl"; mkdir -p "$wl"
if [ ! -x "$wl/tool/bin/rocosmo-pack" ]; then
	run_capture zig build --prefix "$wl/tool" -Doptimize=ReleaseSafe
	assert_rc0 "build rocosmo-pack and the runtimes for the launcher test"
fi
wl_pack="$wl/tool/bin/rocosmo-pack"
wl_rt="$wl/tool/runtime/linux-x86_64"
wl_p2="${p2_out:-$SCRATCH/p2}"
[ -f "$wl_p2/app-x64win.exe" ] || "$ROOT/probes/p2_native_targets/build" "$wl_p2" >/dev/null 2>&1

# Little-endian u64 at byte offset $2 of file $1.
wl_u64() { od -An -tu8 -j "$2" -N8 "$1" | tr -d ' '; }

if [ -x "$wl_pack" ] && [ -f "$wl_p2/app-x64win.exe" ]; then
	run_capture "$wl_pack" --windows-x86_64 "$wl_p2/app-x64win.exe" --linux-x86_64 "$wl_p2/app-x64musl" --windows-launcher --app-id dev.rocosmo.wl -o "$wl/app"
	assert_rc0 "pack a --windows-launcher container"

	# The front is the launcher PE, importing only KERNEL32 (not the app's PE).
	run_capture llvm-objdump -p "$wl/app"
	dlls="$(printf '%s\n' "$out" | awk '/DLL Name:/{print toupper($3)}' | sort -u | tr '\n' ' ')"
	assert_eq "launcher front imports only KERNEL32.DLL" "KERNEL32.DLL " "$dlls"

	# The launcher refuses the raw layout and needs a Windows image.
	run_capture "$wl_pack" --windows-x86_64 "$wl_p2/app-x64win.exe" --linux-x86_64 "$wl_p2/app-x64musl" --windows-launcher --layout raw -o "$wl/none"
	case "$rc:$err" in 2:*"needs the zstd layout"*) pass "--windows-launcher rejects --layout raw";; *) fail "--windows-launcher rejects raw" "rc=$rc $err";; esac
	run_capture "$wl_pack" --linux-x86_64 "$wl_p2/app-x64musl" --windows-launcher -o "$wl/none"
	case "$rc:$err" in 2:*"needs --windows-x86_64"*) pass "--windows-launcher needs a Windows image";; *) fail "--windows-launcher needs a Windows image" "rc=$rc $err";; esac

	# The descriptor the launcher reads at run time, patched by the packer.
	magic_off="$(grep -a -b -o 'ROCOSMO-LAUNCH01' "$wl/app" | head -1 | cut -d: -f1)"
	if [ -n "$magic_off" ]; then
		pass "the launcher descriptor is present in the container"
		target="$(dd if="$wl/app" bs=1 skip=$((magic_off + 32)) count=14 2>/dev/null)"
		assert_eq "descriptor names the Windows entry" "windows-x86_64" "$target"
		app_id="$(dd if="$wl/app" bs=1 skip=$((magic_off + 80)) count=14 2>/dev/null)"
		assert_eq "descriptor carries the app id" "dev.rocosmo.wl" "$app_id"
		idx_off="$(wl_u64 "$wl/app" $((magic_off + 16)))"
		idx_len="$(wl_u64 "$wl/app" $((magic_off + 24)))"

		# Independent decode: the native runtime rebuilds the stored Windows
		# executable from the container; it must equal the input PE byte for byte.
		if [ "$(uname -sm)" = "Linux x86_64" ] && [ -x "$wl_rt" ]; then
			run_capture "$wl_rt" "$wl/app" "$idx_off" "$idx_len" windows-x86_64 "$wl/rebuilt.exe"
			assert_rc0 "the runtime rebuilds the stored Windows payload"
			assert_eq "rebuilt Windows payload matches the input byte for byte" "$(sha256sum <"$wl_p2/app-x64win.exe")" "$(sha256sum <"$wl/rebuilt.exe")"
		fi
	else
		fail "the launcher descriptor is present in the container" "magic not found"
	fi

	# On the real Windows host: the launcher runs under active, up-to-date
	# Microsoft Defender (so a scan is not vacuous), and the launcher-fronted
	# container, the bare launcher and the rebuilt cache executable are not
	# flagged. Real-time protection is on, so the write and the run are
	# scanned on access too; Defender's live EICAR signature (threat id
	# 2147519003, observed on this host) is the discriminating control.
	win_wl="${ROCOSMO_WINDOWS_X64_HOST-}"
	wl_mp='C:\Program Files\Windows Defender\MpCmdRun.exe'
	if [ -z "$win_wl" ]; then
		fail "Windows launcher on the real host" "ROCOSMO_WINDOWS_X64_HOST not set"
	else
		# Defender must be active and current, or a clean scan proves nothing.
		run_capture ssh "${SSH_OPTS[@]}" "$win_wl" 'powershell -NoProfile -Command "$s=Get-MpComputerStatus; ($s.AMServiceEnabled -and $s.AntivirusEnabled -and $s.RealTimeProtectionEnabled -and $s.AntivirusSignatureAge -le 30)"'
		case "$(printf '%s' "$out" | tr -d '\r')" in True) pass "Windows Defender is active with current signatures";; *) fail "Windows Defender active+current" "$out";; esac

		scp -q "${SSH_OPTS[@]}" "$wl/app" "$win_wl:wlapp.exe"
		scp -q "${SSH_OPTS[@]}" "$wl/tool/launcher/rocosmo-launcher-x86_64.exe" "$win_wl:rocosmo-launcher.exe"
		# The launcher rebuilds and runs the app under real-time protection.
		run_capture ssh "${SSH_OPTS[@]}" "$win_wl" 'powershell -NoProfile -Command "Remove-Item -Recurse -Force \"$env:LOCALAPPDATA\rocosmo\" -ErrorAction SilentlyContinue; $o = & (Join-Path $env:USERPROFILE wlapp.exe) 20; \"$o rc=$LASTEXITCODE\""'
		assert_eq "launcher runs the app under real-time protection" "121 rc=0" "$(printf '%s' "$out" | tr -d '\r')"

		# On-demand scans: each artifact is clean (MpCmdRun rc 0 = no threat).
		# Paths are resolved host-side (no machine-specific paths in the repo).
		wl_scan() { # powershell_path_expr label
			run_capture ssh "${SSH_OPTS[@]}" "$win_wl" "powershell -NoProfile -Command \"\$f=$1; & '$wl_mp' -Scan -ScanType 3 -File \$f | Out-Null; \$LASTEXITCODE\""
			case "$(printf '%s' "$out" | tr -d '\r')" in 0) pass "Defender finds no threat in the $2";; *) fail "Defender scan of the $2" "rc(exit)=$out $err";; esac
		}
		wl_scan '(Join-Path $env:USERPROFILE wlapp.exe)' "launcher-fronted container"
		wl_scan '(Join-Path $env:USERPROFILE rocosmo-launcher.exe)' "bare launcher"
		wl_scan '(Get-ChildItem -Recurse \"$env:LOCALAPPDATA\rocosmo\" -File | Select-Object -First 1).FullName' "rebuilt cache executable"
	fi
fi
