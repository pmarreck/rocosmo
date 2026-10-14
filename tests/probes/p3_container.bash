# P3: rocosmo-pack combines P2's per-target executables into one polyglot file
# (Windows PE + POSIX shell dispatcher + embedded native payloads).

echo "P3 rocosmo container (one file, Linux/macOS/Windows, x86_64+aarch64)"
p3="$SCRATCH/p3"; mkdir -p "$p3"
run_capture zig build --prefix "$p3/tool" -Doptimize=ReleaseSafe
assert_rc0 "rocosmo-pack builds"
pack_bin="$p3/tool/bin/rocosmo-pack"
p2_out="${p2_out:-$SCRATCH/p2}"
[ -f "$p2_out/app-x64win.exe" ] || "$ROOT/probes/p2_native_targets/build" "$p2_out" >/dev/null 2>&1

run_capture "$pack_bin" --windows-x86_64 "$p2_out/app-x64win.exe" \
	--linux-x86_64 "$p2_out/app-x64musl" --linux-aarch64 "$p2_out/app-arm64musl" \
	--macos-x86_64 "$p2_out/app-x64mac" --macos-arm64 "$p2_out/app-arm64mac" -o "$p3/app"
assert_rc0 "pack all payloads into one file"
app="$p3/app"
appd="rocosmo/dev.rocosmo.probe"  # the probe app declares ROCOSMO_APP_ID=dev.rocosmo.probe;

run_capture file -b "$app"
case "$out" in *PE32+*x86-64*) pass "file(1) identifies a PE32+ x86-64 image";; *) fail "PE identity" "$out";; esac
run_capture llvm-objdump -p "$app"
assert_rc0 "llvm-objdump parses the relocated PE headers"

tools="$(minimal_path "$p3/bin" uname mkdir dd chmod mv rm)"
for shell in dash bash zsh busybox oksh mksh; do  # oksh, mksh: pdksh family (NetBSD and OpenBSD ksh)
	cache="$p3/cache-$shell"
	if [ "$shell" = busybox ]; then cmd=("${ROCOSMO_BUSYBOX:?}" sh "$app" 20); else cmd=("$shell" "$app" 20); fi
	run_capture env -i PATH="$tools" XDG_CACHE_HOME="$cache" "$(command -v "${cmd[0]}")" "${cmd[@]:1}"
	assert_eq "NATIVE linux x86_64 via $shell, PATH limited to uname mkdir dd chmod mv rm" "121" "$out"
	[ -z "$err" ] || fail "$shell run is silent on stderr" "$err"
done

# Direct execution from a shell: the kernel returns ENOEXEC and bash runs it as a script.
run_capture env -i PATH="$tools" XDG_CACHE_HOME="$p3/cache-direct" "$(command -v bash)" -c "'$app' 20"
assert_eq "NATIVE linux x86_64 via direct ./app from bash" "121" "$out"
[ "$rc" -eq 0 ] || fail "direct run status" "rc=$rc err=$err"

# Cache idempotence: a second run reuses the extracted file, unchanged.
f1="$(ls "$p3/cache-dash/$appd")"; ino1="$(stat -c %i "$p3/cache-dash/$appd/$f1")"
env -i PATH="$tools" XDG_CACHE_HOME="$p3/cache-dash" "$(command -v dash)" "$app" 20 >/dev/null
ino2="$(stat -c %i "$p3/cache-dash/$appd/$f1")"
assert_eq "rerun reuses the cached payload (same inode, one entry)" "$ino1 1" "$ino2 $(ls "$p3/cache-dash/$appd" | wc -l)"
run_capture cmp "$p3/cache-dash/$appd/$f1" "$p2_out/app-x64musl"
assert_rc0 "extracted linux x86_64 payload is byte-identical to the Roc output"

# aarch64 branch on this x86_64 host: fake uname, compare bytes, then run under qemu.
# A fresh PATH directory per fake platform: the real launcher tools plus a
# scripted uname reporting the given kernel name and machine.
fake_platform() { # dir sysname machine
	minimal_path "$1" mkdir dd chmod mv rm >/dev/null
	printf '#!%s\ncase "$1" in -s) echo %s;; -m) echo %s;; esac\n' "$(command -v dash)" "$2" "$3" > "$1/uname"
	chmod +x "$1/uname"
	printf '%s' "$1"
}
fake="$(fake_platform "$p3/fakebin-arm" Linux aarch64)"
env -i PATH="$fake" XDG_CACHE_HOME="$p3/cache-arm" "$(command -v dash)" "$app" 20 >/dev/null 2>&1
fa="$p3/cache-arm/$appd/$(ls "$p3/cache-arm/$appd" 2>/dev/null | head -1)"
run_capture cmp "$fa" "$p2_out/app-arm64musl"
assert_rc0 "linux aarch64 branch extracts the byte-identical arm64 payload"
run_capture qemu-aarch64 "$fa" 20
assert_eq "EMULATED linux aarch64 (qemu-user) run of extracted payload" "121" "$out"

# Unknown platform: clear message, exit 127.
fake="$(fake_platform "$p3/fakebin-none" Plan9 mips)"
run_capture env -i PATH="$fake" XDG_CACHE_HOME="$p3/cache-none" "$(command -v dash)" "$app" 20
assert_eq "unsupported platform exits 127" "127" "$rc"
case "$err" in *"no payload for Plan9-mips"*) pass "unsupported platform names itself on stderr";; *) fail "unsupported platform message" "$err";; esac

for how in "./rocosmo-p3 20" "sh ./rocosmo-p3 20" "bash ./rocosmo-p3 20"; do
	host="${ROCOSMO_MACOS_ARM64_HOST-}"
	if [ -z "$host" ]; then fail "NATIVE macOS arm64 ($how)" "ROCOSMO_MACOS_ARM64_HOST not set"; continue; fi
	scp -q "${SSH_OPTS[@]}" "$app" "$host:rocosmo-p3"
	run_capture ssh "${SSH_OPTS[@]}" "$host" "rm -rf \"\${TMPDIR:-/tmp}/rocosmo-p3-cache\"; XDG_CACHE_HOME=\"\${TMPDIR:-/tmp}/rocosmo-p3-cache\" $how"
	assert_eq "NATIVE macOS arm64 real host ($how)" "121" "$out"
done
remote_run ROCOSMO_WINDOWS_X64_HOST rocosmo-p3.exe "$app" 20
assert_eq "NATIVE Windows x86_64 real host (same file, .exe name)" "121" "$(printf %s "$out" | tr -d '\r')"

# Concurrent cold starts sharing one cache: per-process temp names plus an
# atomic rename must leave exactly one complete entry and correct output.
shared="$p3/cache-shared"
for i in $(seq 32); do env -i PATH="$tools" XDG_CACHE_HOME="$shared" "$(command -v dash)" "$app" 20 >"$p3/par.$i" 2>&1 & done
wait
bad=0; for i in $(seq 32); do [ "$(cat "$p3/par.$i")" = 121 ] || bad=$((bad + 1)); done
assert_eq "32 concurrent cold starts: all correct, one cache entry" "0 1" "$bad $(ls "$shared/$appd" | wc -l)"

# The same file inside WSL2 on the Windows host (real Linux kernel in a VM).
wsl_both_ways "raw layout" "$app" rocosmo-p3wsl 1

# macOS x86_64 branch under Rosetta 2 on Apple Silicon: EMULATION evidence only.
host="${ROCOSMO_MACOS_ARM64_HOST-}"
if [ -n "$host" ]; then
	run_capture ssh "${SSH_OPTS[@]}" "$host" 'c="${TMPDIR:-/tmp}/rocosmo-p3-rosetta"; rm -rf "$c"; XDG_CACHE_HOME="$c" arch -x86_64 /bin/sh ./rocosmo-p3 20 && file "$c/rocosmo/dev.rocosmo.probe/$(ls "$c/rocosmo/dev.rocosmo.probe")"'
	assert_eq "EMULATED macOS x86_64 (Rosetta 2) run" "121" "$(printf '%s\n' "$out" | head -1)"
	case "$out" in *Mach-O*x86_64*) pass "Rosetta run selected the x86_64 Mach-O payload";; *) fail "Rosetta payload selection" "$out";; esac
else
	fail "EMULATED macOS x86_64 (Rosetta 2) run" "ROCOSMO_MACOS_ARM64_HOST not set"
fi

# Unwritable cache location: fall back to a private per-user directory under
# TMPDIR, created 0700, and refuse one that is a symlink (possible hijack).
fb_tools="$(minimal_path "$p3/bin-fb" uname mkdir dd chmod mv rm id)"
fb_tmp="$p3/fbtmp"; mkdir -p "$fb_tmp"
run_capture env -i PATH="$fb_tools" HOME=/proc/rocosmo-nonexistent XDG_CACHE_HOME=/proc/rocosmo-nonexistent TMPDIR="$fb_tmp" "$(command -v dash)" "$app" 20
assert_eq "unwritable cache dir falls back to a private TMPDIR cache" "121" "$out"
fb_dir="$fb_tmp/rocosmo-$(id -u)" fb_app="$fb_tmp/rocosmo-$(id -u)/dev.rocosmo.probe"
assert_eq "fallback cache dir is mode 700 and holds one entry" "700 1" "$(stat -c %a "$fb_dir" 2>/dev/null) $(ls "$fb_app" 2>/dev/null | wc -l)"
hij_tmp="$p3/hijtmp"; mkdir -p "$hij_tmp" "$p3/elsewhere"
ln -s "$p3/elsewhere" "$hij_tmp/rocosmo-$(id -u)"
run_capture env -i PATH="$fb_tools" HOME=/proc/rocosmo-nonexistent XDG_CACHE_HOME=/proc/rocosmo-nonexistent TMPDIR="$hij_tmp" "$(command -v dash)" "$app" 20
assert_eq "symlinked fallback cache dir is refused with exit 126" "126" "$rc"
assert_eq "nothing was extracted through the symlink" "0" "$(ls "$p3/elsewhere" | wc -l)"

# --- per-app namespace and self-cleaning cache ---
assert_eq "the cache folder is named by the app's embedded id" "dev.rocosmo.probe" "$(ls "$p3/cache-dash/rocosmo")"
# Version B: same app id, different bytes (a trailing byte after a static ELF is ignored).
cp "$p2_out/app-x64musl" "$p3/b-x64musl"; printf '\0' >> "$p3/b-x64musl"
run_capture "$pack_bin" --windows-x86_64 "$p2_out/app-x64win.exe" --linux-x86_64 "$p3/b-x64musl" -o "$p3/app-b"
assert_rc0 "pack version B of the same app"
clean="$p3/cache-clean"
mkdir -p "$clean/rocosmo/org.other.app" "$clean/$appd"
: > "$clean/rocosmo/org.other.app/0123456789abcdef"
: > "$clean/$appd/0123456789abcdef.4242"  # another run's in-flight temp file
env -i PATH="$tools" XDG_CACHE_HOME="$clean" "$(command -v dash)" "$app" 20 >/dev/null
env -i PATH="$tools" XDG_CACHE_HOME="$clean" "$(command -v dash)" "$p3/app-b" 20 >"$p3/b.out"
assert_eq "version B runs" "121" "$(cat "$p3/b.out")"
hb="$(sha256sum "$p3/b-x64musl" | cut -c1-16)"
assert_eq "B replaced A: only B's payload and the foreign temp file remain" "$(printf '%s\n' "$hb" 0123456789abcdef.4242 | sort | tr '\n' ' ' | sed 's/ $//')" "$(ls "$clean/$appd" | sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "another app's cache folder is untouched" "0123456789abcdef" "$(ls "$clean/rocosmo/org.other.app")"
env -i PATH="$tools" XDG_CACHE_HOME="$clean" "$(command -v dash)" "$app" 20 >"$p3/a.out"
ha="$(sha256sum "$p2_out/app-x64musl" | cut -c1-16)"
assert_eq "switching back to A re-extracts A and removes B" "121 $ha" "$(cat "$p3/a.out") $(ls "$clean/$appd" | rg -v '\.' | tr '\n' ' ' | sed 's/ $//')"

# Default cache home: ~/.cache on Linux when XDG_CACHE_HOME is unset.
env -i PATH="$tools" HOME="$p3/home" "$(command -v dash)" "$app" 20 >/dev/null
assert_eq "Linux default cache is \$HOME/.cache/rocosmo/<app-id>/" "$ha" "$(ls "$p3/home/.cache/$appd" 2>/dev/null)"
host="${ROCOSMO_MACOS_ARM64_HOST-}"
if [ -n "$host" ]; then
	run_capture ssh "${SSH_OPTS[@]}" "$host" 'h="${TMPDIR:-/tmp}/rocosmo-p3-home-$$"; mkdir -p "$h"; env -u XDG_CACHE_HOME HOME="$h" ./rocosmo-p3 20 && ls "$h/Library/Caches/rocosmo/dev.rocosmo.probe" | wc -l | tr -d " "'
	assert_eq "macOS default cache is ~/Library/Caches/rocosmo/<app-id>/" "121 1" "$(printf '%s' "$out" | tr '\n' ' ' | sed 's/ $//')"
else
	fail "macOS default cache location" "ROCOSMO_MACOS_ARM64_HOST not set"
fi
