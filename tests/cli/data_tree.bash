# --data: a tar of files stored once in a zstd-layout container and installed
# beside the payload on first run, for apps that look for data next to their
# own executable (Zig's lib/). The payload here is a #!/bin/sh script that
# prints a file from lib/ beside its own path, so the same container works on
# any POSIX host; the last case packs the dev shell's real zig with its lib/
# and compiles without ZIG_LIB_DIR.
echo "CLI: --data installs a shared data tree beside the payload"

dt="$SCRATCH/data-tree"; mkdir -p "$dt/src/lib/bin"
pack_bin="${pack_bin:-$SCRATCH/p3/tool/bin/rocosmo-pack}"
if [ ! -x "$pack_bin" ]; then
	run_capture zig build --prefix "$SCRATCH/p3/tool" -Doptimize=ReleaseSafe
	assert_rc0 "build rocosmo-pack for the --data tests"
fi
printf '#!/bin/sh\nd=${0%%/*}\nwhile IFS= read -r l;do echo "$l";done <"$d/lib/hello.txt"\n[ -x "$d/lib/bin/tool" ] && echo tool-is-executable\n[ -x "$d/lib/hello.txt" ] || echo data-is-not-executable\n' > "$dt/app.sh"
printf 'hello from lib v1\n' > "$dt/src/lib/hello.txt"
printf '#!/bin/sh\n' > "$dt/src/lib/bin/tool"; chmod 755 "$dt/src/lib/bin/tool"; chmod 644 "$dt/src/lib/hello.txt"
tar -C "$dt/src" -cf "$dt/lib-v1.tar" lib
c="$dt/app"
run_capture "$pack_bin" --linux-x86_64 "$dt/app.sh" --data "$dt/lib-v1.tar" --app-id dev.rocosmo.datatest --level 3 -o "$c" -v
case "$rc:$err" in 0:"rocosmo-pack: layout zstd"*) pass "pack with --data (the zstd layout is chosen)";; *) fail "pack with --data" "rc=$rc err=$err";; esac
expected="hello from lib v1
tool-is-executable
data-is-not-executable"
tools="$(minimal_path "$dt/bin" uname mkdir dd chmod mv rm gzip)"
cache="$dt/cache"
run_capture env -i PATH="$tools" XDG_CACHE_HOME="$cache" "$(command -v dash)" "$c"
assert_eq "first run installs the payload with its data tree and runs it (PATH: uname mkdir dd chmod mv rm gzip)" "0:$expected:" "$rc:$out:$err"
app_dir="$cache/rocosmo/dev.rocosmo.datatest"
assert_eq "one installed directory, named by its hash" "1" "$(find "$app_dir" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
inst="$(find "$app_dir" -mindepth 1 -maxdepth 1)"
assert_eq "the directory holds the payload (named after the app id) and the tree" "datatest lib/bin/tool lib/hello.txt" "$(cd "$inst" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
run_capture cmp "$inst/datatest" "$dt/app.sh"
assert_rc0 "the installed payload is byte-identical to the input"
run_capture cmp "$inst/lib/hello.txt" "$dt/src/lib/hello.txt"
assert_rc0 "the installed data file is byte-identical to the input"
nogz="$(minimal_path "$dt/bin-nogz" uname mkdir dd chmod mv rm)"
run_capture env -i PATH="$nogz" XDG_CACHE_HOME="$cache" "$(command -v dash)" "$c"
assert_eq "a warm run needs neither gzip nor the runtime" "0:$expected" "$rc:$out"
for shell in bash zsh mksh oksh; do
	run_capture env -i PATH="$tools" XDG_CACHE_HOME="$dt/cache-$shell" "$(command -v "$shell")" "$c"
	assert_eq "cold run under $shell" "0:$expected" "$rc:$out"
done
run_capture env XDG_CACHE_HOME="$cache" sh "$c" --rocosmo-platforms
assert_eq "--rocosmo-platforms still lists the targets" "0:linux-x86_64       Linux-x86_64|Linux-amd64" "$rc:$out"

# A new tree is a new version: it installs anew and the old version is removed.
printf 'hello from lib v2\n' > "$dt/src/lib/hello.txt"
tar -C "$dt/src" -cf "$dt/lib-v2.tar" lib
run_capture "$pack_bin" --linux-x86_64 "$dt/app.sh" --data "$dt/lib-v2.tar" --app-id dev.rocosmo.datatest --level 3 -o "$dt/app-v2"
assert_rc0 "pack the same payload with a changed tree"
run_capture env -i PATH="$tools" XDG_CACHE_HOME="$cache" "$(command -v dash)" "$dt/app-v2"
assert_eq "the changed tree is installed and used" "0:hello from lib v2" "$rc:$(printf %s "$out" | head -1)"
assert_eq "the previous version's directory is cleaned up" "1 absent" "$(find "$app_dir" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ') $([ -e "$inst" ] && echo present || echo absent)"

# Concurrent cold starts: every run succeeds, one directory is installed and
# no temporary directory is left behind.
shared="$dt/cache-shared"
for i in $(seq 32); do env -i PATH="$tools" XDG_CACHE_HOME="$shared" "$(command -v dash)" "$c" >"$dt/par.$i" 2>&1 & done
wait
bad=0; for i in $(seq 32); do [ "$(cat "$dt/par.$i")" = "$expected" ] || bad=$((bad + 1)); done
assert_eq "32 concurrent cold starts: all correct, one installed directory, no temporaries" "0 1" "$bad $(find "$shared/rocosmo/dev.rocosmo.datatest" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"

# Damage to the stored tree fails the install cleanly and installs nothing.
xy="$(head -c 8192 "$c" | LC_ALL=C awk -F'[ =]+' '/^x=/ { print $2, $4; exit }')"
cp "$c" "$dt/corrupt"
size=$(wc -c < "$dt/corrupt")
printf '\377\377\377\377\377\377\377\377' | dd of="$dt/corrupt" bs=1 seek=$((size - 40)) conv=notrunc 2>/dev/null
run_capture env -i PATH="$tools" XDG_CACHE_HOME="$dt/cache-corrupt" "$(command -v dash)" "$dt/corrupt"
case "$rc:$err" in 126:*rocosmo-runtime:*) pass "a corrupt data tree fails with exit 126 and a runtime error";; *) fail "corrupt data tree" "rc=$rc out=$out err=$err";; esac
assert_eq "nothing is installed after a failed install" "" "$(ls -A "$dt/cache-corrupt/rocosmo/dev.rocosmo.datatest" 2>/dev/null)"

# Refusals at pack time.
mkdir -p "$dt/evil"; printf x > "$dt/evil/x"
tar -C "$dt/evil" -cf "$dt/evil.tar" --transform 's|^x$|../escape|' x
run_capture "$pack_bin" --linux-x86_64 "$dt/app.sh" --data "$dt/evil.tar" -o "$dt/x"
assert_eq "a tar path that climbs out is refused" "1:rocosmo-pack: --data: a path is unsafe or not portable" "$rc:${err%% (*}"
ln -sf hello.txt "$dt/src/lib/link"
tar -C "$dt/src" -cf "$dt/link.tar" lib
run_capture "$pack_bin" --linux-x86_64 "$dt/app.sh" --data "$dt/link.tar" -o "$dt/x"
assert_eq "a tar with a symlink is refused, with the fix in the message" "1:rocosmo-pack: --data: only regular files and directories are supported (no links or special files); create the tar with copies instead of links, e.g. GNU tar -h --hard-dereference" "$rc:$err"
printf 'definitely not a tar archive %.0s' $(seq 40) > "$dt/notar"
run_capture "$pack_bin" --linux-x86_64 "$dt/app.sh" --data "$dt/notar" -o "$dt/x"
assert_eq "a file that is not a tar is refused" "1:rocosmo-pack: --data: not a readable tar archive" "$rc:$err"
run_capture "$pack_bin" --linux-x86_64 "$dt/app.sh" --data "$dt/lib-v1.tar" --layout raw -o "$dt/x"
assert_eq "--data with --layout raw is a usage error" "2:rocosmo-pack: --data needs the zstd layout (the runtime installs it)" "$rc:$err"

# The real thing: Zig with its lib/ in one file compiles with no ZIG_LIB_DIR.
zig_real="$(readlink -f "$(command -v zig)" 2>/dev/null)"
zig_lib="$(zig env 2>/dev/null | sed -n 's/.*\.lib_dir = "\(.*\)",/\1/p')"
if [ -n "$zig_real" ] && [ -d "$zig_lib" ]; then
	# --hard-dereference: the Nix store links identical files together.
	tar -C "$(dirname "$zig_lib")" -cf "$dt/zig-lib.tar" --hard-dereference --transform "s|^$(basename "$zig_lib")|lib|" "$(basename "$zig_lib")"
	run_capture "$pack_bin" --linux-x86_64 "$zig_real" --data "$dt/zig-lib.tar" --app-id dev.rocosmo.zigdata --level 1 -o "$dt/zig"
	assert_rc0 "pack the dev shell's zig with its lib/ as the data tree"
	run_capture env -u ZIG_LIB_DIR XDG_CACHE_HOME="$dt/zc" "$dt/zig" build-exe "$ROOT/examples/hello.zig" -femit-bin="$dt/zhello" --cache-dir "$dt/zig-cache" --global-cache-dir "$dt/zig-gcache"
	assert_rc0 "zig from the container compiles with no ZIG_LIB_DIR"
	run_capture "$dt/zhello"
	assert_eq "the program it built exits 145" "145" "$rc"
else
	fail "dev shell zig and its lib/ for the --data zig test" "zig=[$zig_real] lib=[$zig_lib]"
fi

host="${ROCOSMO_MACOS_ARM64_HOST-}"
if [ -z "$host" ]; then
	fail "macOS --data install" "ROCOSMO_MACOS_ARM64_HOST not set"
else
	run_capture "$pack_bin" --macos-arm64 "$dt/app.sh" --linux-x86_64 "$dt/app.sh" --data "$dt/lib-v1.tar" --app-id dev.rocosmo.datatest --level 3 -o "$dt/app-mac"
	assert_rc0 "pack the script payload for macOS with the data tree"
	scp -q "${SSH_OPTS[@]}" "$dt/app-mac" "$host:rocosmo-datatree"
	run_capture ssh "${SSH_OPTS[@]}" "$host" 'chmod 755 rocosmo-datatree; c=$(mktemp -d); XDG_CACHE_HOME=$c ./rocosmo-datatree; echo "rc=$?"; XDG_CACHE_HOME=$c ./rocosmo-datatree | head -1; mv "$c" ~/.Trash/rocosmo-datatree-cache-$$'
	assert_eq "NATIVE macOS arm64: the data tree installs beside the payload, cold and warm" "hello from lib v1
tool-is-executable
data-is-not-executable
rc=0
hello from lib v1" "$out"
fi

# Windows: the launcher layout installs the app as <hash>\<name>.exe with the
# tree beside it. LOCALAPPDATA points at a fresh folder so each run is cold.
run_capture zig cc -target x86_64-windows-gnu -O2 "$ROOT/probes/data_tree/showlib.c" -o "$dt/showlib.exe"
assert_rc0 "build the Windows test payload"
run_capture "$pack_bin" --windows-x86_64 "$dt/showlib.exe" --windows-launcher --linux-x86_64 "$dt/app.sh" --data "$dt/lib-v1.tar" --app-id dev.rocosmo.datatest --level 3 -o "$dt/app-win"
assert_rc0 "pack a launcher-layout container with the data tree"
run_capture env -i PATH="$tools" XDG_CACHE_HOME="$dt/cache-launcher" "$(command -v dash)" "$dt/app-win"
assert_eq "the launcher-layout container runs its Linux payload with the tree" "0:$expected" "$rc:$out"
win="${ROCOSMO_WINDOWS_X64_HOST-}"
if [ -z "$win" ]; then
	fail "Windows --data install" "ROCOSMO_WINDOWS_X64_HOST not set"
else
	scp -q "${SSH_OPTS[@]}" "$dt/app-win" "$win:rocosmo-datatree.exe"
	ps1='$ErrorActionPreference = "Stop"; $env:LOCALAPPDATA = Join-Path $env:TEMP ("rocosmo-dt-" + [guid]::NewGuid()); New-Item -ItemType Directory $env:LOCALAPPDATA | Out-Null; $exe = Join-Path $HOME "rocosmo-datatree.exe"; & $exe; "rc=$LASTEXITCODE"; & $exe; $d = Get-ChildItem (Join-Path $env:LOCALAPPDATA "rocosmo\dev.rocosmo.datatest") -Directory; "dirs=" + @($d).Count; "files=" + ((Get-ChildItem $d[0].FullName -Recurse -File | ForEach-Object { $_.FullName.Substring($d[0].FullName.Length + 1) } | Sort-Object) -join ",")'
	run_capture ssh "${SSH_OPTS[@]}" "$win" "powershell -NoProfile -EncodedCommand $(printf '%s' "$ps1" | iconv -t UTF-16LE | base64 -w0)"
	assert_eq "NATIVE Windows x86_64: the launcher installs <name>.exe with the tree beside it, cold and warm" "hello from lib v1
rc=0
hello from lib v1
dirs=1
files=datatest.exe,lib\bin\tool,lib\hello.txt" "$(printf '%s' "$out" | tr -d '\r' | grep -vE '^#< CLIXML|^<Objs')"
fi
