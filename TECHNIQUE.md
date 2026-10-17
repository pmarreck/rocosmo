# How a rocosmo container works

A rocosmo container is one file that runs natively on Linux, macOS, Windows, FreeBSD, NetBSD and OpenBSD, on x86_64 and aarch64. It is assembled from ordinary native executables, one per OS and CPU. For Roc programs those come from Roc's own cross-compiler, but `rocosmo-pack` accepts any executables. Nothing is translated or emulated: each machine ends up running the executable that was built for it.

The idea comes from Justine Tunney's [Actually Portable Executable](https://justine.lol/ape.html) (APE) format in [Cosmopolitan](https://github.com/jart/cosmopolitan), which showed that one file can be both a Windows PE image and a POSIX shell script. rocosmo uses no Cosmopolitan code, and its header differs from APE's (see [The universal format](#the-universal-format)). [APE_DISPATCH.md](APE_DISPATCH.md) compares the two designs in detail, and [RESEARCH.md](RESEARCH.md) holds the measurements and test evidence behind the choices described here.

## Contents

1. [Two formats](#two-formats)
2. [The universal format](#the-universal-format)
3. [The POSIX-only format](#the-posix-only-format)
4. [How each system starts the file](#how-each-system-starts-the-file)
5. [The dispatcher](#the-dispatcher)
6. [Raw layout](#raw-layout)
7. [zstd layout](#zstd-layout)
8. [Running from memory on Linux](#running-from-memory-on-linux)
9. [Choosing a layout](#choosing-a-layout)
10. [What a machine needs](#what-a-machine-needs)
11. [Building containers](#building-containers)
12. [Limits](#limits)

## Two formats

`rocosmo-pack` writes one of two formats, depending on whether a Windows executable is among its inputs.

| | Universal | POSIX-only |
| --- | --- | --- |
| Chosen when | a `--windows-x86_64` input is given | there is no Windows input |
| First bytes | `MZ` (a Windows PE image) | `#!/bin/sh` |
| Shell script region | 0x40 up to the PE header | 0x80 to the end of the script |
| Windows | runs it as a normal `.exe` | cannot run it |
| Raw `execve(2)` on POSIX | fails with `ENOEXEC`; shells retry with `sh` | runs, through the shebang |

Both formats carry the same dispatcher script, and both support the raw and zstd payload layouts described below.

```text
universal, raw layout                   POSIX-only, zstd layout
0x0000  MZ=;eval "$(dd ...)"            0x0000  #!/bin/sh
        ...DOS header, e_lfanew             eval "$(dd ...)"
0x0040  dispatcher script (sh)          0x0080  dispatcher script (sh)
        relocated PE headers                    runtimes, gzipped, one per OS/CPU
        PE sections (the .exe)                  payload index ("RCSMIDX1")
        payloads, 4 KiB aligned                 zstd frames and deltas
```

## The universal format

Windows reads two things from the start of an executable: the `MZ` signature at offset 0 and `e_lfanew`, the 32-bit offset of the PE header, at 0x3C. The rest of the 64-byte DOS header and the DOS stub after it are ignored, so they can hold other bytes.

A POSIX shell reads the same file as text. rocosmo makes line 1 a complete shell command that ends before 0x3C:

```sh
MZ=;eval "$(dd if="$0" bs=64 skip=1 count=29    2>/dev/null)"
```

`MZ=` is an assignment of an empty value, which any shell accepts. The `eval` then reads `count` 64-byte blocks starting at offset 0x40 and runs them as the script. The packer fills in `count`, padded with spaces to a fixed width, once it knows the script's length. The shell never reaches line 2, which matters because line 2 holds `e_lfanew`, and a four-byte offset contains NUL bytes. NetBSD's `sh` and OpenBSD's `ksh` refuse to run any line that contains a NUL. APE instead opens a single-quoted string on line 1 that runs past `e_lfanew`, which those shells reject (RESEARCH.md §13).

The script region runs from 0x40 to `e_lfanew` and contains no NUL bytes. The PE header follows it, so the Windows header produced by the linker (Roc uses `lld-link`) has to move. `rocosmo-pack` copies the PE headers to the new `e_lfanew`, puts `SizeOfHeaders` at the next `FileAlignment` boundary, and shifts every file offset in the headers by the same amount: section `PointerToRawData`, `PointerToRelocations`, `PointerToLinenumbers`, the symbol table pointer, the certificate table and the debug directory entries. Virtual addresses are unchanged, so no code or data inside the image changes. The PE checksum is set to zero, which Windows does not check for ordinary executables.

The headers must still end before the first section's virtual address, normally 0x1000. That bounds the dispatcher at about 3 KB; the script region of a five-target zstd container (Windows plus four POSIX targets) is 1,856 bytes.

## The POSIX-only format

A container with no Windows target has no reason to start with `MZ`, so it starts with a shebang instead:

```sh
#!/bin/sh
eval "$(dd if="$0" bs=64 skip=2 count=29  2>/dev/null)"
```

These two lines need 66 bytes, so the head is 128 bytes and the script region starts at 0x80. The script after that is the same dispatcher the universal format uses. With a shebang, the kernel itself starts `/bin/sh` on a raw `execve(2)`. That makes the file usable from launchers that call `execve` directly, such as a C program, a service manager or another language's process API.

## How each system starts the file

- **Windows** loads the universal format as a PE image. On Windows 11 on Arm, the x86_64 image runs under the system's x64 emulation.
- **POSIX shells** (`sh`, `bash`, `zsh`, `dash`, `ksh`, `busybox sh`) running `./app` call `execve`, which fails with `ENOEXEC` for the universal format because `MZ` is neither ELF, Mach-O nor `#!`. The shell then runs the file as a script, as POSIX requires. glibc's `execvp` does the same. A raw `execve(2)` does not, so callers outside a shell need the POSIX-only format or `sh app`.
- **The kernel** runs the POSIX-only format through its shebang on every system.
- **WSL2** has a binary-format handler for `MZ` files, so running the universal container directly from WSL starts the Windows image. `sh app` inside WSL runs the Linux payload.

## The dispatcher

The script picks this machine's payload, makes sure it is in a cache, and replaces itself with it. This is the raw-layout dispatcher for four targets, as `rocosmo-pack` writes it:

```sh
s=$(command -v "$0")||s=$0
c=${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/rocosmo
[ -n "$XDG_CACHE_HOME" ]||[ "$(uname -s)" != Darwin ]||c=${HOME:-/tmp}/Library/Caches/rocosmo
a=dev.rocosmo.probe
case $(uname -s)-$(uname -m) in
Linux-x86_64|Linux-amd64) i=da6fd1441f46d84c o=8192       n=10096     ;;
Linux-aarch64|Linux-arm64) i=b76369b2de5004b6 o=20480      n=4760      ;;
Darwin-x86_64) i=8fb88861359200d6 o=28672      n=25408     ;;
Darwin-arm64|Darwin-aarch64) i=9f1a1c84c376d931 o=57344      n=50304     ;;
*) echo "$0: no payload for $(uname -s)-$(uname -m)" >&2;exit 127;;
esac
d=$c/$a f=$c/$a/$i
if [ ! -x "$f" ];then
if ! mkdir -p "$d" 2>/dev/null;then
c=${TMPDIR:-/tmp}/rocosmo-$(id -u);d=$c/$a f=$c/$a/$i
mkdir -m 700 "$c" 2>/dev/null
[ -d "$c" ]&&[ ! -L "$c" ]&&[ -O "$c" ]&&mkdir -p "$d"||{ echo "$0: no private writable cache directory" >&2;exit 126;}
fi
fi
z(){ t=$f.$$ b=$((n/4096)) r=$((n%4096))
{ { [ $b = 0 ]||dd if="$s" bs=4096 skip=$((o/4096)) count=$b;}&&{ [ $r = 0 ]||dd if="$s" bs=1 skip=$((o+b*4096)) count=$r;};} 2>/dev/null >"$t"&&chmod 755 "$t"&&mv -f "$t" "$f"||{ rm -f "$t";exit 126;}
for e in "$d"/*;do case ${e##*/} in $i|*.*);;*)rm -f "$e";;esac;done
}
[ -x "$f" ]||z
[ -x "$f" ]||z
exec "$f" "$@"
exit 127
```

Step by step:

1. **Find itself.** `$s` is the container's path, through `command -v` when it was started by name from `PATH`.
2. **Find the cache.** The cache root is `$XDG_CACHE_HOME/rocosmo` if that is set, else `~/Library/Caches/rocosmo` on macOS and `~/.cache/rocosmo` elsewhere.
3. **Name the app.** Each container has an app id, a lowercase reverse-DNS name, and keeps its payloads in `<cache>/<app id>/`. The packer takes it from `--app-id`, or from a `ROCOSMO_APP_ID=<id>;` string embedded in the payloads, or uses `local.<output name>`.
4. **Pick the payload.** One `case` on `uname -s` and `uname -m` selects the entry. `i` is the payload's cache name, the first 64 bits of its SHA-256 in hex, so a rebuilt app never runs a stale copy. `o` and `n` are its offset and length in the container. A machine with no matching entry gets exit status 127 and a message naming its OS and CPU. The packer accepts only `[A-Za-z0-9_.-]` in patterns, so no input can inject shell syntax.
5. **Fall back to a private directory** if the cache folder cannot be created (for example, a read-only home). The fallback is `${TMPDIR:-/tmp}/rocosmo-<uid>`, created with mode 0700. The script refuses it if it is a symlink or is owned by another user, and makes these checks before it trusts any file there.
6. **Extract on a miss.** `z` copies the payload with `dd`: whole 4 KiB blocks first, then the remainder a byte at a time. Each copy is skipped when its count would be zero, because BSD `dd` treats `count=0` as "copy to the end". The copy goes to a temporary name, `<hash>.<pid>`, is made executable and is renamed into place, so concurrent first runs each write their own file and the rename is atomic.
7. **Clean up.** After installing, `z` deletes the app's other finished entries (bare hashes), which are older versions of the same app. Temporary files of runs still in progress (names with a dot) and other apps' folders are left alone.
8. **Run.** `exec` replaces the shell with the payload, passing the arguments unchanged. The check-and-extract is written twice because a concurrent run of a different version of the same app can delete this entry between the rename and the `exec`.

## Raw layout

In the raw layout each payload is stored byte for byte at a 4 KiB-aligned offset after the script (and, in the universal format, after the PE). Extraction needs only `dd`. Nothing is compressed, so the container is the sum of its inputs plus alignment padding.

## zstd layout

The zstd layout stores each payload as a [Zstandard](https://github.com/facebook/zstd) frame, or as a delta against another payload, and adds a small native program per OS and CPU, the runtime, which rebuilds payloads.

**Deltas.** Executables for the same CPU share a lot of code across operating systems. `rocosmo-pack` compresses every target both whole and as a delta (zstd's `--patch-from`) against every other target for the same CPU, and, for x86_64 targets, against the Windows PE sections, which the container holds uncompressed anyway. It then searches every choice of which targets are stored whole and picks the smallest total in which each delta's reference is a whole target or the PE. Deltas never reference other deltas, so a rebuild decodes at most two frames. Deltas across CPUs measured 91-100% of a whole frame and are not tried (RESEARCH.md §10).

**Index.** A binary index locates everything. It starts with `RCSMIDX1` and a count, then has one entry per target: its name, its kind (raw, frame or delta), its reference entry, and its offset, stored length and content length. Entry 0 is the PE body, stored raw. The dispatcher records the index's offset and length as `x` and `y`. The runtime validates the whole index against the container's size before it trusts any offset in it.

**Runtimes.** Each OS/CPU pair present in the container gets its own runtime: a stripped, size-optimized C and Zig program of 16-54 KB, stored gzipped (9.9-11.3 KB). The dispatcher unpacks it with the system's `gzip` into `<cache>/runtime/<hash>`, once per machine; every rocosmo app on that machine shares it. The Linux runtimes link no C library: `src/nolibc_linux.c` supplies the few C functions they use (file I/O, `memfd_create`, `fexecve`, an allocator, string helpers) as direct system calls. The macOS runtimes link libSystem, the only supported system-call interface there; the BSD runtimes also link the system C library, and a libc-free BSD runtime has not been tried.

**Decoding.** The runtimes decode with zstd's single-file educational decoder (`doc/educational_decoder` in the zstd repository), which is about a third the size of libzstd's smallest decoder build and about a third its speed. A delta's reference is handed to it as a raw-content dictionary. That decoder does not check the frame's content checksum, so the runtime computes the XXH64 checksum itself and rejects a mismatch; every frame `rocosmo-pack` writes carries a checksum and its content size. A corrupted container therefore fails with an error instead of producing a damaged executable, and nothing is installed in the cache. RESEARCH.md §15 has the size and speed measurements.

The zstd dispatcher differs from the raw one in its extraction step: `z` unpacks the runtime if needed and asks it to write the payload to the temporary file, which the shell then renames into the cache as before. Each zstd container also carries this comment in its script, pointing at Zstandard's license:

```sh
# Contains Zstandard (BSD license): https://github.com/facebook/zstd/blob/dev/LICENSE
```

## Running from memory on Linux

On Linux the zstd layout does not write the payload to disk at all. The dispatcher runs the runtime with `--exec`. The runtime rebuilds the payload into a `memfd`, an anonymous in-memory file, seals it against further writes and resizing, and starts it with `fexecve`, so the process becomes the payload. Only the shared runtime is ever cached.

Payloads over 64 MiB still go to the cache: every start of a memfd payload rebuilds it into private memory, while a cached file is shared through the page cache. If the kernel refuses the memfd (no `memfd_create`, `vm.memfd_noexec=2`, or a security module), the runtime runs the container again through `/bin/sh` with `ROCOSMO_NO_MEMFD=1` in its environment, and the dispatcher takes the cache path. Users can set that variable themselves; the app's child processes inherit it.

## Choosing a layout

`--layout raw` and `--layout zstd` force a layout. The default, `--layout auto`, builds both and keeps the smaller file. For a single small payload the runtime costs more than compression saves, so raw wins; once payloads add up to a few tens of KB, zstd does. A five-target build of a small probe app is 83,432 bytes as zstd and 107,648 bytes raw.

## What a machine needs

| Layout | Tools the dispatcher calls |
| --- | --- |
| raw | `sh`, `uname`, `mkdir`, `dd`, `chmod`, `mv`, `rm`, plus `id` for the private fallback |
| zstd | the same, plus `gzip` once per machine to unpack the runtime |

All of these are in the base system of every supported OS. No compiler, interpreter or loader is installed, and the container never modifies itself.

## Building containers

`rocosmo-pack` takes one executable per target and writes the container:

```sh
rocosmo-pack --windows-x86_64 app.exe \
	--linux-x86_64 app-x64musl --linux-aarch64 app-arm64musl \
	--macos-x86_64 app-x64mac --macos-arm64 app-arm64mac \
	-o app
```

The `rocosmo` command does the whole job for a Roc app: `rocosmo app.roc` reads the targets the app's platform declares, runs `roc build` once per target and packs the results, choosing the universal format when a Windows target is among them.

## Limits

- Windows on Arm runs the x86_64 image under emulation. A native arm64 Windows path would need a relay inside the x64 image (APE_DISPATCH.md §5).
- A raw `execve(2)` of the universal format fails with `ENOEXEC`; shells, `execvp` and `sh app` work. The POSIX-only format has no such limit, and cannot run on Windows.
- The dispatcher must fit the PE's header space, about 3 KB, which bounds the number of targets in the universal format.
- On Linux, each start of a memfd payload pays its decode time, about 6.7 ms per MB of payload on the machine measured in RESEARCH.md §15.
- OpenBSD payloads must link OpenBSD's libc: since 7.5 the kernel accepts system calls only from call sites registered by libc or by an `openbsd.syscalls` section (pinsyscalls(2)), so the libc-free executables rocosmo builds for Linux have no OpenBSD counterpart. The OpenBSD runtime and the tested payloads link OpenBSD's libc dynamically (RESEARCH.md §17).
