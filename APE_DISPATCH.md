# How APE routes each OS and CPU to its code, and how rocosmo reuses it

Sources: Cosmopolitan `master` at
[`c7c9916eb8ceaa5062c917d1fea5efb0ee6b49b4`](https://github.com/jart/cosmopolitan/tree/c7c9916eb8ceaa5062c917d1fea5efb0ee6b49b4)
(2026-10-13), files `ape/ape.S`, `tool/build/apelink.c`, `ape/ape-m1.c` and
`tool/cosmocc/bin/cosmocc`, plus the stub text of a real `cosmocc` 4.0.2 output
inspected in probe P1. Line numbers refer to that revision. Statements marked
*observed* come from our own artifacts; everything else is read from source.

## 1. One file, several parsers

An executable file is interpreted by whichever program the OS hands it to.
APE arranges the first bytes so that each of those programs sees something
valid:

| Reader | What it requires | What APE puts there |
| --- | --- | --- |
| Windows PE loader | `MZ` at offset 0, `e_lfanew` (u32 at 0x3C) pointing to `PE\0\0` | `MZqFpD='` and a real `e_lfanew` |
| POSIX `sh` (after the kernel returns `ENOEXEC`) | Text it can parse up to an `exec` or `exit` | The same bytes read as the assignment `MZqFpD='...'` followed by a script |
| Linux/BSD kernel via binfmt or the APE loader | An ELF image | ELF program headers placed inside the file and mapped by a small loader |
| x86_64 macOS (XNU) | Mach-O load commands | `LC_SEGMENT_64` commands (`__PAGEZERO`, `__APE1..3`) embedded in the file (`ape.S` ~893–920) |

`ape.S:120` emits `"MZqFpD='\n"`. Read as x86 machine code those bytes are
harmless jumps (comments at `ape.S:121–136`); read by a shell they open a
single-quoted string. `ape.S:157` closes the quote with `' <<'@'`, which starts
a here-document delimited by `@`. Everything between that line and a line
containing only `@` is swallowed as here-document text, including binary DOS
header fields and `e_lfanew` (`ape.S:158–161`). The shell never interprets the
binary.

Two details make this survive real shells:

- **Newline early.** Bash refuses to run a file as a script if a NUL appears
  before the first newline in its first bytes. `MZqFpD='\n` puts the newline at
  offset 8.
- **No stray quote bytes.** Any `0x27` inside the quoted/binary region would end
  the string early, so header values must avoid it.

When a file without `#!` fails `execve` with `ENOEXEC`, POSIX shells, glibc
`execvp` and Cosmopolitan's own `execve` re-run it with `/bin/sh`. A raw
`execve(2)` from a non-shell parent does not, so APE offers `--assimilate`,
which rewrites the header in place into the native format (`ape.S:604–692`).

## 2. The stub's decision tree (observed in a 4.0.2 output)

The script that follows the header does, in order:

1. `o=$(command -v "$0")` to find its own path.
2. If an `ape` loader is on `PATH`, `exec ape "$o" "$@"`.
3. If `${TMPDIR:-${HOME:-.}}/.ape-1.10` is executable, exec it.
4. Branch on `uname -m` and on `[ -d /Applications ]` (a macOS heuristic):
   - **Linux/BSD x86_64 or aarch64:** `dd` a gzip-compressed ELF loader out of
     the file at a fixed offset, `gzip -dc` it to `$t.$$`, `chmod 755`, `mv`
     into place, then `exec "$t" "$o" "$@"`. The loader maps the matching ELF
     image from the APE file itself.
   - **macOS x86_64:** extract the same gzip-compressed x86_64 loader as on
     Linux, then `dd if="$t.$$" of="$t.$$" skip=5 count=8 bs=64 conv=notrunc`
     copies 512 bytes inside that *extracted copy* to its front, turning it
     into a Mach-O. It is cached at `$t` and exec'd. The program file itself
     is not modified.
   - **macOS arm64:** require `cc` (prints `please run: xcode-select --install`
     otherwise), extract `ape-m1.c` via `dd | gzip -dc`, compile it with
     `cc -w -O`, cache the binary, exec it.
5. Otherwise print `this ape program lacks $m support` and exit 127.

Only `--assimilate` writes to the program file: on Linux/BSD,
`exec 7<> "$o"` plus a `printf` overwrites the first 64 bytes with an ELF
header; on x86_64 macOS, `dd if="$o" of="$o" ... conv=notrunc` copies the
Mach-O header to offset 0. The result is a plain native executable for that
one platform.

The original APE design ([justine.lol/ape.html](https://justine.lol/ape.html),
2020) did this on every first run instead: the stub opened its own file
read-write, `printf`'d an ELF header over `MZqFpD`, and re-`exec`'d itself
(falling back to `qemu-x86_64`). That copy then stopped running on Windows,
and the scheme needed write access to the program file. Later releases moved
to the separate cached loader described above.

External tools the stub needs: `sh`, `uname`, `mkdir`, `dd`, `gzip`, `chmod`,
`mv`, plus `cc` on Apple Silicon. Probe P1 runs a Roc-built APE on Linux with
`PATH` limited to exactly the first seven.

## 3. Where architecture sharing comes from

Cosmopolitan shares code *across operating systems*, not across CPUs:

- `apelink` (`apelink.c:62–140`) takes one ELF per architecture and joins them
  into one file. x86_64 and aarch64 code are both present in full.
- Within one architecture a single image serves every OS. The code is compiled
  with the System V ABI everywhere. Cosmopolitan libc detects the OS at run time
  and talks to Linux and BSD kernels directly, to Windows through `__msabi`
  thunks into kernel32/ntdll, and on Apple Silicon through a table of libSystem
  function pointers that `ape-m1.c` passes in (`ape-m1.c:60–110`, `958–1001`).
- To keep that one image valid everywhere, `cosmocc` compiles x86_64 code with
  `-mno-red-zone -mno-tls-direct-seg-refs` and aarch64 code with
  `-ffixed-x18 -ffixed-x28` (`cosmocc:123–124`, `428`). Thread-local storage
  and Windows signal delivery depend on these reservations.
- `ape-m1.c` maps the aarch64 ELF segments from the APE file `PROT_EXEC` with
  plain `mmap` (`ape-m1.c:713`). The loader itself is the only signed Mach-O
  involved; the mapped ELF code is not code-signed.

## 4. What rocosmo reuses, changes and adds

rocosmo keeps the polyglot header and shell dispatch, and replaces "one image
per architecture plus a runtime OS layer" with "one native executable per
OS/arch pair, produced by Roc's own cross-compiler".

Reused:

- `MZ` + shell assignment at offset 0 with the newline at offset 8, and a real
  `e_lfanew`.
- Dispatch by `uname -s`/`uname -m`, `dd` extraction, temp file plus `mv`,
  then `exec`.

Changed:

- **Quoting.** The single-quoted string runs from offset 7 to offset 0x40, so
  `e_lfanew` is inside it. No here-document is needed. The packer guarantees
  exactly two quote bytes before the PE header, and nudges `e_lfanew` if a byte
  would be `0x27`.
- **Windows.** The x64 PE produced by Roc's `lld-link` is relocated rather than
  generated. Its headers move after the script's `exit`. Section, symbol-table,
  certificate and debug-directory file offsets shift by the same multiple of
  `FileAlignment`; virtual addresses stay put, so no code changes. The headers
  must still end before the first section's virtual address (0x1000), which
  bounds the script at roughly 3 KB.
- **Payloads are complete native executables:** static ELF for Linux, ad-hoc
  signed Mach-O for macOS, PE for Windows. No loader, no `cc`, no `gzip`, no
  libc.
- **Cache.** The cache is content-addressed and namespaced per app:
  `<cache>/rocosmo/<app-id>/<first 64 bits of SHA-256>`, with `<cache>` being
  `$XDG_CACHE_HOME`, else `~/Library/Caches` on macOS, else `~/.cache`. A new
  build never reuses a stale extraction; installing it removes that app's older
  entries (never in-flight temp files or other apps). Concurrent first runs race
  safely through per-process temp names and an atomic rename, and a run
  re-extracts once if another version of the same app cleaned its entry
  between install and exec.
- **Linux runs from memory.** With the zstd layout the Linux runtime decodes the
  payload into a sealed memfd and `fexecve`s it, so nothing but the shared
  runtime touches the disk. APE has no equivalent: its loader maps the ELF
  image from the program file itself, which requires an uncompressed image.

Added:

- **Private fallback.** If the cache home cannot be created, the dispatcher
  uses `${TMPDIR:-/tmp}/rocosmo-<uid>`. It creates the directory with mode 0700
  and refuses it if it is a symlink or owned by someone else. These checks run
  before any cached file there is trusted.
- **BSD `dd` guard.** BSD `dd` treats `count=0` as "copy until end of input", so
  the dispatcher never calls `dd` with a zero count (`src/pack.zig`, comment in
  `script_tail`).
- **Injection guard.** Patterns become shell `case` alternatives, so the packer
  accepts only `[A-Za-z0-9_.-]` separated by `|`.

## 5. Enhancements not yet built

- **Windows ARM64 native.** A PE file has one machine type, and ARM64X images
  (arm64 + arm64EC) do not run on x64 Windows. The x64 PE runs on Windows 11 on
  Arm through Prism emulation; Windows 10 on Arm emulates x86 only
  ([Microsoft, 2025-11-06](https://learn.microsoft.com/en-us/windows/arm/apps-on-arm-x86-emulation)).
  A native path would mirror the shell dispatcher inside the Windows host:
  check `IsWow64Process2` for an Arm64 native machine, extract an embedded
  arm64 PE to `%LOCALAPPDATA%\rocosmo\<hash>.exe`, run it with the same command
  line and inherited handles, and return its exit code.
- **Compression.** The macOS payloads are mostly 16 KiB page padding. Optional
  `gzip -dc` extraction, as APE does, would shrink them at the cost of one more
  required tool.
- **`--assimilate`.** Rewriting the file into the native executable for the
  current platform would allow direct `execve` from non-shell parents.
- **Shared per-architecture code.** See RESEARCH.md §7.
