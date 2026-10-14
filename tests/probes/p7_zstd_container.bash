# P7: the zstd layout end to end. rocosmo-pack stores targets as zstd frames
# or deltas plus a gzipped runtime per OS/CPU; the shell dispatcher unpacks
# the runtime once, the runtime rebuilds the payload into the cache.

echo "P7 zstd container (frames + deltas + per-OS/CPU runtime)"
p7="$SCRATCH/p7"; mkdir -p "$p7"
pack_bin="$SCRATCH/p3/tool/bin/rocosmo-pack"
[ -x "$pack_bin" ] || { run_capture zig build --prefix "$SCRATCH/p3/tool" -Doptimize=ReleaseSafe; assert_rc0 "rocosmo-pack builds"; }
rt_dir="$SCRATCH/p3/tool/runtime"
p2_out="${p2_out:-$SCRATCH/p2}"
[ -f "$p2_out/app-x64win.exe" ] || "$ROOT/probes/p2_native_targets/build" "$p2_out" >/dev/null 2>&1
targets=(--linux-x86_64 "$p2_out/app-x64musl" --linux-aarch64 "$p2_out/app-arm64musl"
	--macos-x86_64 "$p2_out/app-x64mac" --macos-arm64 "$p2_out/app-arm64mac")

# --- CLI surface ---
run_capture "$pack_bin" --windows-x86_64 "$p2_out/app-x64win.exe" "${targets[@]}" --layout zstd -v -o "$p7/app"
assert_rc0 "pack the P2 payloads with --layout zstd"
case "$err" in *"layout zstd:"*" bytes"*) pass "--verbose reports the chosen layout and size on stderr";; *) fail "verbose summary" "$err";; esac
printf '%s' "$err" > "$p7/zstd.err"
run_capture file -b "$p7/app"
case "$out" in *PE32+*x86-64*) pass "zstd container is still a PE32+ x86-64 image";; *) fail "PE identity" "$out";; esac

run_capture "$pack_bin" --windows-x86_64 "$p2_out/app-x64win.exe" "${targets[@]}" -v -o "$p7/auto-small"
case "$err" in *"layout raw:"*) pass "auto keeps the raw layout when it is smaller (tiny payloads)";; *) fail "auto picks raw for tiny payloads" "$err";; esac
big="$pack_bin"  # a 3 MB executable stands in for a large payload; it is never run here
# A PE whose ROCOSMO_APP_ID declaration is defused, so no input declares an id.
perl -0777 -pe 's/ROCOSMO_APP_ID=/XOCOSMO_APP_ID=/g' "$p2_out/app-x64win.exe" > "$p7/win-noid.exe"
run_capture "$pack_bin" --windows-x86_64 "$p7/win-noid.exe" --linux-x86_64 "$big" --macos-x86_64 "$big" -v -o "$p7/auto-big"
printf '%s' "$err" > "$p7/auto-big.err"
case "$err" in *"layout zstd:"*) pass "auto picks zstd when it is smaller (large payloads)";; *) fail "auto picks zstd for large payloads" "$err";; esac

run_capture "$pack_bin" --windows-x86_64 "$p2_out/app-x64win.exe" --payload "Linux-x86_64=$p2_out/app-x64musl" --layout zstd -o "$p7/x"
case "$rc:$err" in 2:*"--payload needs --layout raw"*) pass "--payload is refused with --layout zstd";; *) fail "--payload with zstd" "rc=$rc $err";; esac
run_capture "$pack_bin" --windows-x86_64 "$p2_out/app-x64win.exe" "${targets[@]}" --level 23 -o "$p7/x"
case "$rc:$err" in 2:*"--level must be 1-22"*) pass "--level outside 1-22 is refused";; *) fail "--level range" "rc=$rc $err";; esac
run_capture "$pack_bin" --windows-x86_64 "$p2_out/app-x64win.exe" "${targets[@]}" --layout fancy -o "$p7/x"
case "$rc:$err" in 2:*"--layout must be raw, zstd or auto"*) pass "unknown --layout value is refused";; *) fail "--layout value" "rc=$rc $err";; esac
# app id: embedded by the probe app, overridable, defaulted from the output name.
case "$(cat "$p7/zstd.err")" in *"app id dev.rocosmo.probe (embedded)"*) pass "--verbose reports the embedded app id";; *) fail "embedded app id report" "$err";; esac
run_capture "$pack_bin" --windows-x86_64 "$p2_out/app-x64win.exe" "${targets[@]}" --app-id org.example.override -v -o "$p7/x"
case "$err" in *"app id org.example.override (option)"*) pass "--app-id overrides the embedded id";; *) fail "--app-id override" "$err";; esac
run_capture "$pack_bin" --windows-x86_64 "$p2_out/app-x64win.exe" "${targets[@]}" --app-id NotValid -o "$p7/x"
case "$rc:$err" in 2:*"--app-id must be"*) pass "an invalid --app-id is refused";; *) fail "--app-id validation" "rc=$rc $err";; esac
case "$(cat "$p7/auto-big.err" 2>/dev/null)" in *"app id local.auto-big (default)"*) pass "without a declaration the id defaults to local.<output name>";; *) fail "default app id" "$(cat "$p7/auto-big.err" 2>/dev/null)";; esac
printf 'x ROCOSMO_APP_ID=org.example.other; y' > "$p7/other-id"
cat "$p2_out/app-x64mac" "$p7/other-id" > "$p7/conflict-mac"
run_capture "$pack_bin" --windows-x86_64 "$p2_out/app-x64win.exe" --linux-x86_64 "$p2_out/app-x64musl" --macos-x86_64 "$p7/conflict-mac" -o "$p7/x"
case "$rc:$err" in 1:*"conflicting"*) pass "payloads declaring different app ids are refused";; *) fail "conflicting app ids" "rc=$rc $err";; esac
run_capture "$pack_bin" --help
case "$out" in *--freebsd-x86_64*--layout*) pass "--help lists BSD targets and --layout";; *) fail "--help content" "$out";; esac

# --- native Linux x86_64 ---
app="$p7/app"
tools="$(minimal_path "$p7/bin" uname mkdir dd chmod mv rm gzip)"
for shell in dash bash zsh busybox; do
	cache="$p7/cache-$shell"
	if [ "$shell" = busybox ]; then cmd=("${ROCOSMO_BUSYBOX:?}" sh "$app" 20); else cmd=("$shell" "$app" 20); fi
	run_capture env -i PATH="$tools" XDG_CACHE_HOME="$cache" "$(command -v "${cmd[0]}")" "${cmd[@]:1}"
	assert_eq "NATIVE linux x86_64 via $shell (zstd layout, PATH: uname mkdir dd chmod mv rm gzip)" "121" "$out"
	[ -z "$err" ] || fail "$shell run is silent on stderr" "$err"
done
field() { head -c 4096 "$app" | LC_ALL=C awk -F'[ =;]+' -v pat="$1" -v key="$2" 'index($0, pat ")") == 1 || index($0, pat "|") == 1 { for (i = 1; i < NF; i++) if ($i == key) { print $(i+1); exit } }'; }
pid="$(field Linux-x86_64 i)" rid="$(field Linux-x86_64 h)"
# Linux runs the rebuilt payload from a memfd: only the shared runtime is cached.
assert_eq "linux: the payload runs from memory; only the runtime is cached" "runtime/$rid" "$(cd "$p7/cache-dash/rocosmo" && find . -type f | sed 's|^\./||')"
run_capture cmp "$p7/cache-dash/rocosmo/runtime/$rid" "$rt_dir/linux-x86_64"
assert_rc0 "unpacked runtime is byte-identical to the built linux x86_64 runtime"
run_capture env -i PATH="$tools" XDG_CACHE_HOME="$p7/cache-dash" "$(command -v dash)" "$app" 20 a 'b c'
assert_eq "warm memory run passes arguments through" "121" "$out"
# ROCOSMO_NO_MEMFD=1 selects the cache path, as on other systems.
run_capture env -i PATH="$tools" ROCOSMO_NO_MEMFD=1 XDG_CACHE_HOME="$p7/cache-file" "$(command -v dash)" "$app" 20
assert_eq "ROCOSMO_NO_MEMFD=1: payload rebuilt into the cache and run" "121" "$out"
run_capture cmp "$p7/cache-file/rocosmo/dev.rocosmo.probe/$pid" "$p2_out/app-x64musl"
assert_rc0 "rebuilt linux x86_64 payload is byte-identical to the Roc output"
nogz="$(minimal_path "$p7/bin-nogz" uname mkdir dd chmod mv rm)"
run_capture env -i PATH="$nogz" XDG_CACHE_HOME="$p7/cache-file" "$(command -v dash)" "$app" 20
assert_eq "a cached payload is preferred: warm run needs neither gzip nor the runtime" "121" "$out"
# Payloads above the memory limit (64 MiB) fall back to the cache by re-running
# the container with ROCOSMO_NO_MEMFD=1; the same fallback covers memfd failures.
{ cat "$p2_out/app-x64musl"; head -c $((65 * 1024 * 1024)) /dev/zero; } > "$p7/huge-x64musl"
run_capture "$pack_bin" --windows-x86_64 "$p2_out/app-x64win.exe" --linux-x86_64 "$p7/huge-x64musl" --layout zstd --level 3 -o "$p7/huge"
assert_rc0 "pack a 65 MiB payload"
run_capture env -i PATH="$tools" XDG_CACHE_HOME="$p7/cache-huge" "$(command -v dash)" "$p7/huge" 20
assert_eq "a payload above the memory limit falls back to the cache and runs" "121 2" "$out $(find "$p7/cache-huge" -type f | wc -l)"

# --- the runtime's own CLI surface (linux x86_64 build) ---
rt="$rt_dir/linux-x86_64"
xy="$(head -c 4096 "$app" | LC_ALL=C awk -F'[ =]+' '/^x=/ { print $2, $4; exit }')"
run_capture "$rt" --about
case "$rc:$out" in "0:rocosmo-runtime "*": rebuilds a target executable from a rocosmo container (linux-x86_64)") pass "runtime --about: one line with version and platform";; *) fail "runtime --about" "rc=$rc $out";; esac
run_capture "$rt" -h
case "$rc:$out" in "0:Usage: rocosmo-runtime CONTAINER INDEX_OFFSET INDEX_LEN TARGET OUT"*"--exec"*) pass "runtime -h prints usage for both modes";; *) fail "runtime -h" "rc=$rc $out";; esac
run_capture "$rt"
case "$rc:$err" in "2:rocosmo-runtime: usage: "*) pass "runtime without arguments: usage on stderr, exit 2";; *) fail "runtime no args" "rc=$rc $err";; esac
run_capture "$rt" "$app" 12x 5 linux-x86_64 "$p7/rt-out"
assert_eq "runtime rejects a non-numeric index offset (exit 2)" "2:rocosmo-runtime: index offset and length must be decimal integers" "$rc:$err"
run_capture "$rt" "$p7/no such file" 0 1 linux-x86_64 "$p7/rt-out"
assert_eq "runtime reports a missing container with its errno text" "1:rocosmo-runtime: $p7/no such file: No such file or directory" "$rc:$err"
run_capture "$rt" "$app" 999999999 1 linux-x86_64 "$p7/rt-out"
assert_eq "runtime refuses an index outside the container" "1:rocosmo-runtime: $app: index lies outside the container" "$rc:$err"
run_capture "$rt" "$app" ${xy% *} ${xy#* } plan9-mips "$p7/rt-out"
case "$rc:$err" in "1:rocosmo-runtime: plan9-mips: "?*) pass "runtime refuses a target the index lacks";; *) fail "runtime unknown target" "rc=$rc $err";; esac
: > "$p7/rt-exists"
run_capture "$rt" "$app" ${xy% *} ${xy#* } linux-x86_64 "$p7/rt-exists"
assert_eq "runtime never overwrites an existing OUT" "1:rocosmo-runtime: $p7/rt-exists: File exists" "$rc:$err"
# Size gate: without musl the Linux runtimes should cost about what the
# macOS ones (libSystem, dynamically linked) do.
for t in linux-x86_64 linux-aarch64; do
	gz=$(gzip -9 -n -c "$rt_dir/$t" | wc -c)
	[ "$gz" -le 28000 ] && pass "$t runtime is at most 28000 bytes gzipped ($gz)" || fail "$t runtime gzipped size" "$gz > 28000"
done

# --- linux aarch64: runtime and payload under qemu-user (emulation) ---
o="$(field Linux-aarch64 o)" n="$(field Linux-aarch64 n)"
dd if="$app" bs=1 skip="$o" count="$n" 2>/dev/null | gzip -dc > "$p7/rt-aarch64" && chmod 755 "$p7/rt-aarch64"
run_capture qemu-aarch64 "$p7/rt-aarch64" "$app" ${xy% *} ${xy#* } linux-aarch64 "$p7/arm-payload"
assert_rc0 "EMULATED linux aarch64 runtime (qemu-user) rebuilds its payload"
run_capture cmp "$p7/arm-payload" "$p2_out/app-arm64musl"
assert_rc0 "aarch64 rebuild is byte-identical"
chmod 755 "$p7/arm-payload"; run_capture qemu-aarch64 "$p7/arm-payload" 20
assert_eq "EMULATED linux aarch64 rebuilt payload runs" "121" "$out"

# --- failure handling: a corrupt frame must not poison the cache ---
cp "$app" "$p7/corrupt"
frames_start=$(( ${xy% *} + ${xy#* } ))
size=$(wc -c < "$p7/corrupt")
# Hit every frame (they start after the index): 4 bytes every 128.
for ((at = frames_start + 64; at < size; at += 128)); do printf '\377\377\377\377' | dd of="$p7/corrupt" bs=1 seek=$at conv=notrunc 2>/dev/null; done
run_capture env -i PATH="$tools" XDG_CACHE_HOME="$p7/cache-corrupt" "$(command -v dash)" "$p7/corrupt" 20
case "$rc:$err" in 126:*rocosmo-runtime:*) pass "corrupt payload data fails with exit 126 and a runtime error";; *) fail "corrupt payload handling" "rc=$rc err=$err";; esac
assert_eq "no payload is cached after a failed rebuild" "" "$(ls "$p7/cache-corrupt/rocosmo/dev.rocosmo.probe" 2>/dev/null)"

# --- concurrent cold starts ---
shared="$p7/cache-shared"
for i in $(seq 32); do env -i PATH="$tools" XDG_CACHE_HOME="$shared" "$(command -v dash)" "$app" 20 >"$p7/par.$i" 2>&1 & done
wait
bad=0; for i in $(seq 32); do [ "$(cat "$p7/par.$i")" = 121 ] || bad=$((bad + 1)); done
assert_eq "32 concurrent cold starts: all correct; one runtime cached, payload from memory" "0 1" "$bad $(find "$shared" -type f | wc -l)"

# --- real hosts ---
for how in "./rocosmo-p7 20" "sh ./rocosmo-p7 20"; do
	host="${ROCOSMO_MACOS_ARM64_HOST-}"
	if [ -z "$host" ]; then fail "NATIVE macOS arm64 zstd ($how)" "ROCOSMO_MACOS_ARM64_HOST not set"; continue; fi
	scp -q "${SSH_OPTS[@]}" "$app" "$host:rocosmo-p7"
	run_capture ssh "${SSH_OPTS[@]}" "$host" "rm -rf \"\${TMPDIR:-/tmp}/rocosmo-p7-cache\"; XDG_CACHE_HOME=\"\${TMPDIR:-/tmp}/rocosmo-p7-cache\" $how"
	assert_eq "NATIVE macOS arm64 real host, zstd layout ($how)" "121" "$out"
done
host="${ROCOSMO_MACOS_ARM64_HOST-}"
if [ -n "$host" ]; then
	run_capture ssh "${SSH_OPTS[@]}" "$host" 'c="${TMPDIR:-/tmp}/rocosmo-p7-rosetta"; rm -rf "$c"; XDG_CACHE_HOME="$c" arch -x86_64 /bin/sh ./rocosmo-p7 20'
	assert_eq "EMULATED macOS x86_64 (Rosetta 2), zstd layout: x86_64 runtime and payload" "121" "$out"
fi
remote_run ROCOSMO_WINDOWS_X64_HOST rocosmo-p7.exe "$app" 20
assert_eq "NATIVE Windows x86_64 real host, zstd layout (PE runs in place)" "121" "$(printf %s "$out" | tr -d '\r')"
wsl_both_ways "zstd layout" "$app" rocosmo-p7wsl 1  # the runtime; the payload runs from memory
