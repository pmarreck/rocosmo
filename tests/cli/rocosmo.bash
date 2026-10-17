# The `rocosmo` command (src/rocosmo, Roc on basic-cli): pure planning tests,
# CLI surface, and end-to-end containers built from P2's platform, which
# declares every target and cross-links them all from this host.

echo "CLI: rocosmo command"
cmd="$SCRATCH/cmd"; mkdir -p "$cmd"
run_capture roc test "$ROOT/src/rocosmo/Plan.roc"
assert_rc0 "Plan.roc expects pass"
run_capture roc fmt --check "$ROOT/src/rocosmo"
assert_rc0 "src/rocosmo is roc-fmt clean"
run_capture roc build "$ROOT/src/rocosmo/main.roc" --output="$cmd/rocosmo"
assert_rc0 "rocosmo builds"
rocosmo="$cmd/rocosmo"

run_capture "$rocosmo" --help
case "$rc:$out" in "0:Usage: rocosmo "*) pass "--help prints usage";; *) fail "--help prints usage" "rc=$rc $out";; esac
run_capture "$rocosmo" --about
case "$rc:$out" in 0:rocosmo\ *:*) [ "$(printf '%s\n' "$out" | wc -l)" = 1 ] && pass "--about is one line" || fail "--about is one line" "$out";; *) fail "--about is one line" "rc=$rc $out";; esac
run_capture "$rocosmo"
case "$rc:$err" in "2:rocosmo: missing APP.roc"*) pass "no app is usage rc 2";; *) fail "no app is usage rc 2" "rc=$rc $err";; esac
run_capture "$rocosmo" --bogus app.roc
case "$rc:$err" in "2:rocosmo: unknown option --bogus"*) pass "unknown option is usage rc 2";; *) fail "unknown option is usage rc 2" "rc=$rc $err";; esac

# Universal: the P2 platform declares x64win, so the file is also a PE.
export ROCOSMO_PACK="$pack_bin"
p2src="${p2_out:-$SCRATCH/p2}/src"
run_capture "$rocosmo" -o "$cmd/my app" "$p2src/app.roc"
assert_rc0 "rocosmo packs the P2 app (output path with a space)"
case "$err" in *"skipping arm64win"*) pass "reports the target it cannot pack yet";; *) fail "reports the target it cannot pack yet" "$err";; esac
assert_eq "declares Windows: universal MZ container" "MZ" "$(head -c 2 "$cmd/my app" 2>/dev/null)"
run_capture env XDG_CACHE_HOME="$cmd/cache" "$cmd/my app" 20
assert_eq "universal container runs here" "121" "$out"
remote_run ROCOSMO_MACOS_ARM64_HOST rocosmo-cmd-universal "$cmd/my app" 20
assert_eq "NATIVE macOS arm64 runs the command-built container (real host)" "121" "$out"
remote_run ROCOSMO_WINDOWS_X64_HOST rocosmo-cmd-universal.exe "$cmd/my app" 20
assert_eq "NATIVE Windows x86_64 runs the command-built container (real host)" "121" "$(printf %s "$out" | tr -d '\r')"

# POSIX-only: the same platform without its Windows targets.
cp -r -- "$p2src" "$cmd/posix"
sed -i '/win: {/d' "$cmd/posix/platform/main.roc"
run_capture env -C "$cmd/posix" "$rocosmo" app.roc
assert_rc0 "rocosmo packs a platform without Windows targets"
posix_out="$cmd/posix/app"
assert_eq "default output: the app name, in the working directory" "yes" "$([ -f "$posix_out" ] && echo yes)"
assert_eq "no Windows: #!/bin/sh container" "#!/bin/sh" "$(head -n 1 "$posix_out")"
run_capture env XDG_CACHE_HOME="$cmd/cache" "$posix_out" 20
assert_eq "POSIX-only container runs here" "121" "$out"

# Nothing packable: a clear failure, no output.
cp -r -- "$p2src" "$cmd/none"
sed -i -e '/x64musl: {/d' -e '/arm64musl: {/d' -e '/mac: {/d' -e '/x64win: {/d' -e '/x64openbsd: {/d' "$cmd/none/platform/main.roc"
run_capture "$rocosmo" -o "$cmd/none/out" "$cmd/none/app.roc"
case "$rc:$err" in "1:rocosmo: the platform declares no target rocosmo can pack (arm64win)"*) pass "no packable target fails clearly";; *) fail "no packable target fails clearly" "rc=$rc $err";; esac
