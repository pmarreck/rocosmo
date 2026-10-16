# rocosmo feasibility report

Date: 2026-10-13. All results come from the pinned inputs below and the probes
in `probes/`; `./test` re-runs every claim marked *tested*. The BDFN (Benevolent
Dictator For Now) set the prototype goal: one Roc-built file that runs on
Linux, macOS and Windows, contains x86_64 and aarch64 code, and can be built
on Linux or macOS of either architecture. Only current OS versions matter for
now.

## 1. Answer in brief

- **It works without Cosmopolitan.** One file built by Roc's own
  cross-compiler, a libc-free Zig host and `rocosmo-pack` runs *natively* on
  Linux x86_64, macOS arm64 and Windows x86_64. It contains x86_64 and aarch64
  code for Linux and macOS (tested, see §5).
- **Every target builds from either Linux or macOS.** A Linux x86_64 host and a
  macOS arm64 host each build all six targets, and the macOS-built container is
  byte-identical to the Linux-built one (tested).
- **No compiler change is needed.** Platform `targets:` link specs, prebuilt
  per-target host objects and a post-link packer are enough.
- **The Cosmopolitan route also works**, through Roc's `output: Archive` plus
  `cosmocc`/`apelink`, but it requires cosmo-libc and adds a `cc` dependency on
  Apple Silicon (tested; §5 P1). That probe is retired: rocosmo keeps no
  Cosmopolitan dependency.
- **Remaining gaps.** Windows ARM64 runs only the x64 PE under Prism
  emulation; a native ARM64 relay is designed but not built. Linux aarch64 is
  tested only under qemu-user. An aarch64 Linux build host and an x86_64 macOS
  build host are untested.

## 2. Pinned inputs

| Input | Version / revision | Provenance |
| --- | --- | --- |
| Roc compiler | `nightly-2026-10-12-2664a27` | [roc-lang/nightlies release](https://github.com/roc-lang/nightlies/releases/tag/nightly-2026-10-12-2664a27), per-system tarballs hashed in `flake.nix` from the release's SHA-256 digests |
| Roc source read | `main` at `c79847aa738cfb849b27e52354474d536a073da8` (2026-10-13) | <https://github.com/roc-lang/roc/tree/c79847aa738cfb849b27e52354474d536a073da8> |
| Cosmopolitan toolchain (P1 only; removed 2026-10-14) | `cosmocc-4.0.2.zip` | <https://cosmo.zip/pub/cosmocc/cosmocc-4.0.2.zip>; GitHub release 4.0.2 published 2025-01-06. |
| Cosmopolitan source read | `master` at `c7c9916eb8ceaa5062c917d1fea5efb0ee6b49b4` (2026-10-13) | <https://github.com/jart/cosmopolitan/tree/c7c9916eb8ceaa5062c917d1fea5efb0ee6b49b4> |
| Zig (hosts, packer) | 0.16.0 from nixpkgs (`flake.lock`) | nixpkgs |

The flake no longer carries `cosmocc`: rocosmo has no Cosmopolitan dependency.
P1, the comparison probe that used it, is retired; its code is in git history
up to commit 760d3bd, and its findings remain in §5.

### Updating pins

- **Roc:** pick a tag from the nightlies releases page. Set `rocNightly`, then
  copy each asset's `sha256:` digest into `rocAssets` (convert with
  `nix hash convert --hash-algo sha256 --to sri HEX`). Run `./test`.
- **nixpkgs:** `nix flake update`, then `./test`.

## 3. Terms kept separate

- **Build host:** where `roc build` and the packer run.
- **Target:** a Roc target name (`x64musl`, `arm64mac`, ...), meaning an object
  format, OS ABI and CPU.
- **Runtime platform:** the Roc *platform* (Roc API plus host) that supplies I/O
  and allocation; distinct from a compiler target.
- **Native:** the CPU executes the payload's own instructions under that OS.
- **Emulated:** qemu-user, Rosetta 2 or Prism translates the instructions.
- **WSL2:** a real Linux kernel in a VM on Windows. WSL registers a binfmt_misc handler (`WSLInterop`, magic `MZ` at offset 0), so running the file directly inside WSL starts the *Windows* PE through interop; only `sh ./app` takes the Linux path. Tests check both and tell them apart by whether the Linux cache was used.

The current compiler is the Zig-based rewrite. The Rust compiler and its
surgical linker are historical; claims made about them do not carry over.

## 4. Findings about Roc (current compiler)

- **Targets.** `src/target/mod.zig` defines `x64{mac,win,mingw,musl,glibc,
  linux,elf,freebsd,openbsd,netbsd}`, `arm64{mac,win,mingw,linux,musl,glibc}`,
  baseline-CPU `v1` twins, `arm32` and `wasm32`.
- **Linking is embedded LLD, driven by the platform header.** Each target
  entry lists its `inputs` in order, with `app` marking where the compiled Roc
  object goes, plus an `output: Exe | Archive | Shared` kind
  (`src/compile/targets_config.zig`).
  - ELF musl links with `-static` and the default `_start`.
  - Windows links with `lld-link /nodefaultlib /subsystem:console`.
  - Mach-O links with `ld64.lld -lSystem -platform_version macos 11.0` against
    a `libSystem.tbd` stub (`src/cli/linker.zig`).
  - Roc ad-hoc signs Mach-O output itself (`src/cli/macho/AdHocResign.zig`), so
    a non-Mac host can produce runnable Apple Silicon binaries.
- **Host ABI ("symbol ABI").** The Roc app object defines the `provides`
  symbols and imports `roc_alloc(len, align)`, `roc_dealloc(ptr, align)`,
  `roc_realloc(ptr, new_len, align)`, `roc_dbg`, `roc_expect_failed`,
  `roc_crashed` and the hosted functions. *Observed:* the probe app's object
  needs only `roc_alloc`, `roc_dealloc`, `roc_crashed` and `roc_host_double`,
  with no libc symbols. `roc_dealloc` and `roc_realloc` do not pass the old
  length, so a host allocator must record sizes itself.
- **macOS sysroot on non-Mac hosts.** The Linux nightly tarball contains no
  `darwin/` sysroot. Without one, `-lSystem` fails (*observed*). A platform can
  ship `<inputs_dir>/macos-sysroot/usr/lib/libSystem.tbd`; P2 uses a
  four-symbol stub.
- **Historical Apple Silicon claim.** The old install docs said macOS builds
  were slower because Roc did not yet "do our own linking like we do on those
  targets" ([roc-lang.org/install](https://roc-lang.org/install), via search on
  2026-10-13). That described the Rust compiler. Current CI
  (`.github/workflows/ci_cross_compile.yml` at `c79847a`) cross-compiles to
  `x64musl` and `arm64musl` from Linux x64, macOS x64, **macOS ARM64** and
  Windows x64 hosts, and runs the results natively on Linux x64 and ARM64.
  Probe P4 adds a macOS ARM64 host building every target, Mach-O and PE
  included.

## 5. Experiment receipts

`./test` runs P1–P7 plus the core unit tests; 125 checks passed on
2026-10-13. Real-hardware checks need SSH aliases in the ignored
`local/hosts.env` (`ROCOSMO_MACOS_ARM64_HOST`, `ROCOSMO_WINDOWS_X64_HOST`,
`ROCOSMO_WSL_X64_HOST`). An unset alias fails the suite rather than skipping.

Test hosts used: a Linux x86_64 NixOS build host; an Apple M4 Max on macOS
26.7.1 with Xcode; a Windows 10 22H2 (build 19045) x86_64 PC; and WSL2
(kernel 6.18.33.2-microsoft-standard-WSL2) on that PC.

### P1: Roc archive linked by cosmocc (retired 2026-10-14; `probes/p1_cosmo_archive` up to commit 760d3bd)

`roc build --target={x64musl,arm64musl}` with `output: Archive` produces 2.3 KB
archives. The per-architecture `cosmocc` drivers link them with a C host, and
`apelink` joins the results into a 679 KB APE.

| Run | Result |
| --- | --- |
| Linux x86_64 native, `PATH` limited to `sh uname mkdir dd gzip chmod mv` | passes |
| aarch64 ELF under qemu-user (emulated) | passes |
| macOS arm64 real host (first run compiles `ape-m1.c` with Xcode's `cc`) | passes |
| Windows x86_64 real host | passes |

Caveat: Roc's LLVM codegen does not apply `cosmocc`'s `-mno-red-zone` or
`-ffixed-x18 -ffixed-x28`. The trivial probe passes. Larger Roc code could
clobber x28 (Cosmopolitan's aarch64 TLS register), or lose red-zone data when
Cosmopolitan delivers a signal on Windows. Making this path safe needs a
Roc-side target variant that reserves those registers. That is a compiler
change.

### P2: libc-free per-target executables (`probes/p2_native_targets`)

One Zig host source, compiled with `zig build-obj` per target:

- **Linux:** raw syscalls and its own `_start`.
- **macOS:** `mmap`/`write`/`exit` from libSystem.
- **Windows:** five kernel32 functions through an import library generated
  from `kernel32.def`.

Roc links one executable per target from a Linux x86_64 host:

| Target | Size (bytes) | Dependencies (tested) | Run |
| --- | --- | --- | --- |
| x64musl | 9,576 | none (no `INTERP`, no `NEEDED`) | native Linux x86_64 |
| arm64musl | 3,904 | none | qemu-user (emulated) |
| x64mac | 25,240 | `/usr/lib/libSystem.B.dylib` only | Rosetta 2 (emulated, via P3) |
| arm64mac | 50,128 | `/usr/lib/libSystem.B.dylib` only | native macOS arm64 |
| x64win | 7,168 | `KERNEL32.dll` only | native Windows x86_64 |
| arm64win | 7,168 | `KERNEL32.dll` only | **untested** (no hardware) |

### P3: the container (`src/`, `rocosmo-pack`)

`rocosmo-pack` makes one 103,376-byte file from the x64 PE plus the four
Linux/macOS payloads. APE_DISPATCH.md describes the layout. Tested:

- Linux x86_64 native under dash, bash, zsh and busybox `sh`, and by direct
  `./app` from bash, with `PATH` limited to `uname mkdir dd chmod mv rm`.
- Extracted payloads are byte-identical to the Roc outputs. The aarch64 branch
  is exercised with a scripted `uname` and its output run under qemu-user.
- A cached rerun is a no-op (same inode). 32 concurrent cold starts all
  succeed and leave one cache entry. Unknown platforms exit 127 with a message.
- An unwritable cache home falls back to a private 0700 `TMPDIR` directory; a
  symlinked fallback is refused with exit 126.
- macOS arm64 real host, native, launched via zsh `./app`, `sh` and `bash`.
- macOS x86_64 branch under Rosetta 2 (emulated); the x86_64 Mach-O was
  selected.
- Windows x86_64 real host, native, the same bytes renamed `.exe`.
- WSL2 Linux x86_64 via `sh ./app` (Linux path). Direct `./app` inside WSL runs the Windows PE through WSLInterop; an earlier revision of this report counted that as a Linux result by mistake.

### P4: second build host

The tracked tree is copied to the macOS arm64 host, and the full pinned
pipeline runs there: Roc nightly for aarch64-darwin, Zig hosts, packer. The
resulting container is byte-identical (SHA-256) to the Linux-built one. That
makes every run proven for one file hold for the other.

### Failures and anomalies kept on record

- APE stub under NixOS: `/usr/bin` has no `mkdir`/`gzip`. Runs need those tools
  on `PATH`. A harness issue, not an APE defect.
- Wine 120 s timeout while creating a prefix; replaced by the real Windows host.
- One intermittent direct-exec failure, traced to bash sourcing `~/.bashrc`
  because the harness's stdin was a socket. That rewrote `XDG_CACHE_HOME` to
  `/.cache`. Fixed by `exec </dev/null` in `./test` and the dispatcher's
  private fallback.
- Busybox on the dev-shell `PATH` shadowed GNU `tar` and coreutils. Busybox is
  now exposed only as `ROCOSMO_BUSYBOX`.
- Two remote failures during an early run whose details were lost. The macOS
  host was later found on a cellular hotspot, which also explains slow SSH.
  `./test` now repeats all failure labels in its summary.

## 6. Host × target matrix

Build host rows, execution target columns. "builds" means that host produced
the target. "N" = native run, "E" = emulated run, "—" = not tried.

| Build host ↓ / run on → | Linux x86_64 | Linux aarch64 | macOS arm64 | macOS x86_64 | Windows x86_64 | Windows ARM64 |
| --- | --- | --- | --- | --- | --- | --- |
| Linux x86_64 | builds; N | builds; E (qemu) | builds; N | builds; E (Rosetta) | builds; N | builds (arm64 PE); not run |
| macOS arm64 | builds; identical bytes | builds; identical bytes | builds; N on build host | builds; identical bytes | builds; identical bytes | builds; not run |
| Linux aarch64 | — | — | — | — | — | — |
| macOS x86_64 | — | — | — | — | — | — |
| Windows x86_64 (native) | — | — | — | — | — | — |
| WSL2 on Windows | — (a Linux host; expected to match Linux x86_64) | | | | | |

Unfilled rows are untested. A Roc nightly exists for linux_arm64 and
macos_x86_64, and Roc's own CI builds musl targets from macOS x64 and Windows
x64. Two Windows-host gaps remain: rocosmo's build scripts are Bash, and
`zig dlltool` invocations are untested there.

## 7. Architecture options

| Option | What changes | Pros | Cons |
| --- | --- | --- | --- |
| A. Roc `output: Archive` + `cosmocc`/`apelink` (P1) | Platform only | Mature APE loader; BSDs; one image per arch shared across OSes | Requires cosmo-libc; GNU ld + `ape.lds`; `cc` needed on Apple Silicon first run; register reservations unmet without a compiler change; 679 KB for the probe |
| B. Per-target native payloads + polyglot packer (P2+P3, **built**) | Platform hosts + post-link packer | No libc; uses Roc's tested cross-linking; tiny payloads; every OS loads its own native format; deterministic across build hosts | One copy of app code per OS/arch pair; extraction to a cache on Unix; non-shell `execve` gets `ENOEXEC`; no BSD payloads yet |
| C. Shared per-arch code with OS shims (BDFN point 5) | Compiler target variant + loader per OS | Smallest file for many OSes | x86_64 Windows uses the Microsoft x64 calling convention while Linux/macOS use System V, so a shared image needs a single ABI plus thunks, as Cosmopolitan does. Apple arm64 differs from AAPCS64 in stack argument packing and variadics. macOS needs a signed loader that maps unsigned code (possible only without the hardened runtime, as `ape-m1.c` does). A large project. |

Sharing is worth little at today's sizes. App code was 2.3 KB per
architecture in P1. P3's file is dominated by Mach-O page padding, which
compression would recover more cheaply than option C.

### Does cosmo-libc remain necessary?

Not for option B. Linux needs only syscalls. macOS requires libSystem
regardless, since Apple does not support a stable raw syscall ABI; libSystem
ships with every Mac. Windows needs kernel32 only. A real platform will need
more OS surface (files, environment, time, threads). That surface has to be
written per OS in the host, the work Cosmopolitan does for C programs.

## 8. Distribution constraints

- **Licensing.** The probe hosts and the packer are this project's code.
  `libSystem.tbd` is a four-symbol stub written here, and `kernel32.def` lists
  five exported names. The Roc compiler is UPL-1.0 (`LICENSE` in the nightly).
  Option A embeds Cosmopolitan libc, which is ISC-style with notices embedded
  via `.ident` and must be distributed (`tool/cosmocc/README.md`, "Legal").
  Option B embeds no third-party runtime.
- **macOS signing and quarantine.**
  - The arm64 payload is ad-hoc signed by Roc. Apple Silicon requires a valid
    signature to run; notarization is not required for a file launched from a
    shell.
  - The extracted file is written by `dd`, so it carries no quarantine
    attribute. Gatekeeper assessment of the downloaded polyglot itself, when
    launched from Finder or other GUI paths, is untested.
  - Distributing through a hardened-runtime, notarized app bundle would be a
    different packaging path.
- **Windows.** The PE is unsigned. SmartScreen and antivirus reputation for an
  unsigned PE with appended data is untested. Authenticode signing would have
  to come after packing, because the certificate covers the overlay.
- **Execution.**
  - Shells run the file through the `ENOEXEC` script fallback.
  - Raw `execve` from Python `subprocess` without a shell, or from similar
    parents, fails on Unix. Fixes: binfmt_misc on Linux, an `--assimilate`
    mode (declined: the container never rewrites itself), or shipping the extracted native file.
- **Cache location.** `$XDG_CACHE_HOME` or `$HOME/.cache`, with the private
  `TMPDIR` fallback. Cache entries are never garbage-collected yet.
- **ABI and threads.** The libc-free host is single-threaded with a bump
  allocator. Roc's generated code needs no TLS. Threads would require
  per-OS thread creation and TLS setup in the host.
- **Windows command line.** The probe host takes the last command-line token.
  A real host must implement Windows argument parsing (`CommandLineToArgvW`
  rules) and UTF-16 conversion.

## 9. Recommendation and smallest next step

Adopt option B. Next, in order:

1. **Turn `probes/p2_native_targets` into a real platform package.** Write a
   per-OS Zig host behind a small internal interface (`write`, `read`, `exit`,
   args, environment, page allocation and a size-recording allocator), with
   argument and UTF-8 handling tested per OS. Keep it libc-free.
2. **Build `rocosmo` as a wrapper command** that runs `roc build` for each
   target and then `rocosmo-pack`. Port the build scripts from Bash so they
   also run on a Windows build host.
3. **Implement the Windows ARM64 relay in the x64 host**
   (`IsWow64Process2`, extract, `CreateProcessW`) and test it on Windows 11 on
   Arm hardware.
4. **Add optional gzip payload compression and `--assimilate`.** (Compression
   shipped as zstd in section 11; `--assimilate` was declined.)

Open questions for the BDFN:

- Do the BSDs matter? Adding them is one more payload each, and Roc already has
  FreeBSD/OpenBSD/NetBSD x64 targets.
- Is unsigned distribution acceptable, or should macOS Developer ID and
  Authenticode signing be in scope?
- Should cache cleanup be the program's job or the user's?

## 10. Study: a shared zstd runtime with delta payloads

Date: 2026-10-13. The BDFN proposed a successor layout:
- the same MZ/sh header picks the OS and CPU;
- a small native runtime, cached once per machine, rebuilds the payload from zstd frames and runs it;
- per CPU, one target is stored whole and the others as zstd `--patch-from` deltas against it.

Large Zig, Rust and Roc binaries (validate is ~100 MB) are in scope, not only small Roc apps. Probes P5 (`probes/p5_payload_layout`) and P6 (`probes/p6_zstd_decoder`) measure the idea; `./test` covers their tools, and the large-dataset runs below are receipts, not part of `./test`.

**Method.** zstd 1.5.7 at `-19 --long=30`, gzip `-9`. `measure` computes every pairwise delta, and `layout.awk` exhaustively picks the cheapest set of whole frames ("roots") so that every other payload is one delta from a root or from the Windows x64 PE, which is stored raw anyway and so is a free reference (depth 1: no delta of a delta). Every frame of the chosen plan is decoded and compared byte for byte (`verified N/N`). Measured on an AMD Threadripper 3990X running NixOS.

**Datasets.**

| Set | Language | Targets | Source |
| --- | --- | --- | --- |
| Roc compiler `nightly-2026-10-12-2664a27` | Zig + LLVM (C++) | linux x64/arm64, macOS x64/arm64 | official release tarballs, flake-pinned hashes |
| ripgrep 14.1.1 | Rust | linux x64 (musl) / arm64 (gnu), macOS x64/arm64, Windows x64 | official GitHub release, checksums verified |
| z7z `cc626ef` | Zig + libc | linux x64/arm64 (musl), macOS x64/arm64, Windows x64/arm64, FreeBSD x64/arm64, NetBSD x64 | cross-built here with Zig 0.16.0 `ReleaseFast`, ELF debug info stripped; OpenBSD failed (no Zig cross libc) |
| synthetic Roc app (600 generated functions) | Roc | the six P2 targets | `probes/p5_payload_layout/gen-roc-app 600` built with the P2 platform; prints 237 for input 20 on Linux x64 |
| P2 probe app | Roc | the six P2 targets | `probes/p2_native_targets` |

**Container bytes, excluding the free raw Windows x64 PE.**

| Set | Raw | gzip -9 each | zstd each | Best delta layout | Solid zstd stream |
| --- | ---: | ---: | ---: | ---: | ---: |
| Roc compiler (4 × ~250 MB) | 1,001,618,796 | 292,449,402 | 176,808,558 | 133,941,998 | 133,761,875 |
| ripgrep (5) | 21,369,128 | 8,049,765 | 6,348,142 | 5,367,808 | 5,337,430 |
| z7z (9) | 9,742,406 | 4,021,959 | 3,252,821 | 2,010,381 | 1,952,862 |
| synthetic Roc app (6) | 2,385,352 | 521,202 | 367,933 | 253,067 | 254,020 |
| P2 probe app (6) | 96,016 | 10,654 | 9,840 | 7,893 | 7,249 |

**Delta patterns.** Values are delta size as a share of that target's whole zstd frame.
- **z7z (Zig): same CPU, Unix ELF to ELF.** Deltas are small: FreeBSD→NetBSD 17%, Linux→FreeBSD 27%, arm64 Linux→FreeBSD 27%.
- **z7z: macOS and Windows on the same CPU.** Weaker: 63–87%.
- **z7z: across CPUs.** Almost useless: 91–96%.
- **Synthetic Roc app (Roc-generated code dominates).** Linux x64 and macOS x64 diff to 18.6% of each other: same System V calling convention, so the same machine code. Windows x64 is 93% because Windows uses a different calling convention. On arm64, Linux↔Windows is 53% and macOS 76–80%. Across CPUs, 99–100%.
- **Roc compiler (LLVM-heavy).** Every pair lands at 57–75%. Same-CPU pairs are barely better than cross-CPU ones; the best is Linux x64→macOS x64 at 57%.
- **ripgrep (Rust, built by different CI toolchains per OS).** 72–89%. The free Windows x64 PE was the chosen reference for all four other targets, both arm64 ones included.

**Choosing roots by measurement wins.** The optimum is never "the smallest payload". For z7z it picked FreeBSD x64 and Linux arm64 as roots. A solid stream is at most 3% smaller than the depth-1 layout on the large sets (8% on the 8 KB probe), but decoding it means decompressing every earlier payload.

**Branch filter (BCJ).** `bcj.c` is an exactly invertible x86 CALL/JMP and arm64 BL/ADRP filter in the style of xz's. Round trips are tested in both directions on seeded random bytes and on real binaries. Applied before zstd, it shrank the best layout by only 1.6% (z7z) and 6.2% (ripgrep). It is not worth its complexity yet.

**Decoder cost per target.** Upstream libzstd decode-only, space-optimized (`HUF_FORCE_DECOMPRESS_X1`, `ZSTD_FORCE_DECOMPRESS_SEQUENCES_SHORT`, `ZSTD_NO_INLINE`, `ZSTD_STRIP_ERROR_STRINGS`, no legacy), built with `zig cc -Os`. Sizes are the executable minus an identical no-decoder baseline:

| Target | linux x64 | linux arm64 | macOS x64 | macOS arm64 | Windows x64 | Windows arm64 | FreeBSD x64 | NetBSD x64 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Decoder bytes | 34,792 | 30,264 | 38,139 | 37,360 | 33,792 | 27,648 | 35,208 | 35,208 |

- **Correctness.** It applies CLI-made `--patch-from` deltas through `ZSTD_DCtx_refPrefix`, and rejects a wrong reference through the frame checksum (tested in P6).
- **The educational decoder** (`doc/educational_decoder`, `-DZDEC_NO_MESSAGE`) is 15,294 bytes on x86_64 and 13,316 on arm64 macOS. It supports raw-content references but verifies no checksum, and decoded about half as fast (44 ms vs 21 ms to rebuild the 4.4 MB macOS arm64 ripgrep from its 1.1 MB delta).

**Decode time and memory (size-optimized libzstd, single thread).** Rebuilding the 250 MB macOS arm64 Roc compiler from its Linux x64 root:
- decoding the 45 MB root frame took 650 ms and 287 MB peak;
- applying the 31 MB delta took 875 ms and 520 MB peak (zstd CLI: 620 ms, 494 MB).

A secondary target of that size therefore costs about 1.5 s and about 0.5 GB on its first run.

**Platform facts (sources fetched 2026-10-13).**
- **Running a payload from memory.**
  - *Linux:* `memfd_create` plus `execveat`, as validate_gui's shim already does.
  - *FreeBSD:* `memfd_create` since 13.0 ([shm_open(2)](https://man.freebsd.org/cgi/man.cgi?query=shm_open&sektion=2)) and `fexecve` since 8.0 ([fexecve(2)](https://man.freebsd.org/cgi/man.cgi?query=fexecve&sektion=2)).
  - *NetBSD:* `memfd_create` since 11.0 ([memfd_create(2)](https://man.netbsd.org/memfd_create.2)).
  - *Not checked:* OpenBSD in-memory execution.
  - *Not possible:* macOS and Windows have no equivalent, so they need a cache file.
- **OpenBSD.** Since 7.5, each system call number is pinned to registered entry sites. For static executables the kernel takes them from the binary's `openbsd.syscalls` section, and a violation raises SIGABRT ([pinsyscalls(2)](https://man.openbsd.org/pinsyscalls.2); [LWN](https://lwn.net/Articles/959562); [example](https://nullprogram.com/blog/2025/03/06/)). A libc-free runtime must emit that section itself, and OpenBSD binaries need an OpenBSD sysroot (Zig 0.16 has no OpenBSD cross libc). Untested.
- **Base-system decompressors.** gzip ships with OpenBSD ([gzip(1)](https://man.openbsd.org/gzip.1)) and NetBSD ([gzip(1)](https://man.netbsd.org/gzip.1)). FreeBSD ships both gzip and an older zstd 1.5.2 ([bug 278099](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=278099)). Stock macOS 26.7.1 has gzip and bzip2 but not zstd or xz (checked on the test Mac).
- **Notarizing a bare command-line Mach-O.** It works, but a ticket cannot be stapled to a standalone executable; Gatekeeper checks online instead ([Apple DTS](https://developer.apple.com/forums/thread/689337), [forum](https://developer.apple.com/forums/thread/736973)). Rebuilding a payload from a delta is byte-exact, so a payload signed before diffing keeps a valid signature.
- **Language coverage.** The container format is indifferent to the source language: it carries finished executables. Rust's [platform support](https://doc.rust-lang.org/nightly/rustc/platform-support.html) lists all of these targets with full `std`:
  - tier 1: aarch64 macOS, x64 and arm64 Windows (MSVC), x64 Windows (GNU);
  - tier 2 with host tools: x64/arm64 Linux musl, x64 macOS, x64/arm64 FreeBSD, x64 NetBSD;
  - tier 3 (not built or tested by Rust's CI): arm64 NetBSD, x64/arm64 OpenBSD.

  Zig 0.16 cross-built nine of z7z's ten requested targets here; only OpenBSD failed. Roc's targets are listed in §4.

**Break-even.** The runtime has not been built, so its size is an estimate: the libzstd decoder above plus I/O and exec logic, gzipped for the shell to unpack with base `gzip`. That is roughly 20–35 KB per Unix OS/CPU (the P6 test executables gzip to 22–33 KB), or about 100–150 KB for Linux and macOS on both CPUs. Container totals against gzip alone:

| Set | gzip -9 each | Delta layout + ~130 KB runtimes | Saving |
| --- | ---: | ---: | ---: |
| P2 probe app | 10.7 KB | ~138 KB | none; gzip wins 13× |
| synthetic Roc app | 521 KB | ~383 KB | ~27% |
| ripgrep | 8.05 MB | ~5.50 MB | ~32% |
| z7z | 4.02 MB | ~2.14 MB | ~47% |
| Roc compiler | 292 MB | ~134 MB | ~54% |

Break-even falls somewhere between the probe and the synthetic app, roughly 0.5–1 MB of raw payloads (estimated). The packer should build both and keep the smaller one.

**Conclusions.**
1. **The idea holds for every language tested.** Zig, Rust and Roc all benefit, and the container never needs to know which language produced a payload.
2. **Group references by calling convention and CPU, not by OS.** Same-CPU, same-convention deltas are strong; cross-CPU deltas never pay. The Windows x64 PE is the right free reference only when the code shares its convention (ripgrep yes, Roc no). Pick roots by measurement, as `layout.awk` does.
3. **Store the runtime gzipped so base `gzip` can unpack it**, one per Unix OS/CPU, cached once per machine under its content hash and shared by every rocosmo app. The Windows x64 PE carries the same decoder, for the ARM64 relay and for any payload it must rebuild.
4. **Run from memory only for small payloads.** Linux, FreeBSD and NetBSD can execute from memory, but then the payload is rebuilt on every run (about 1.5 s for a 250 MB secondary). Large payloads belong in a content-addressed disk cache with self-cleaning; macOS and Windows always need the cache.
5. **Not yet known:**
   - OpenBSD support;
   - the real runtime size;
   - decode speed on slow CPUs such as a Raspberry Pi;
   - whether a smaller, checksum-free decoder (the educational one, plus our own content hash) is worth its 2× slowdown.

**Reuse.**
- **Payload index:** mini_blar (BLIP-based, optional zstd), read by the runtime. The shell keeps fixed offsets written by the packer.
- **Runtime pattern:** validate_gui's shim, which already does self-describing tails, memfd execution and an atomic Windows cache.
- **Deltas:** difz uses the same zstd primitive. Its full-libzstd and BLAKE3 engine is larger than a runtime should be, so reuse its format ideas and tests rather than link it.

## 11. Built: the zstd layout (2026-10-13)

The design from §10 is implemented and tested (`./test`, P7 and P4).

- **Core** (Zig, no I/O):
  - `src/index.zig`: payload index; `encode` emits only what `decode` accepts, and `decode` validates bounds, references and names.
  - `src/layout.zig`: exhaustive depth-1 root/delta choice.
  - `src/zstd_encode.zig`, `src/zstd_decode.zig`: frames carry content size and checksum.
  - `src/targets.zig`: the single OS/CPU table.
  - `src/pack.zig` `packZstd`: delta candidates are same-CPU targets plus the Windows PE body.
- **Runtime**: `src/runtime.c` (all I/O) over the core's C API (`src/rocosmo_rt.h`). It is cross-built for seven targets (ReleaseSmall, stripped, decode-only space-optimized zstd), gzipped with `gzip -9 -n` and embedded in `rocosmo-pack`. A container carries only the runtimes for its own targets. The shell unpacks the runtime once per machine into the content-addressed cache; the runtime writes the rebuilt payload to a temp path that the shell renames into the cache, so the existing cache, fallback and symlink checks still apply.
- **CLI**:
  - `--layout raw|zstd|auto` (auto keeps the smaller);
  - `--level 1-22`;
  - `--freebsd-x86_64`, `--freebsd-aarch64`, `--netbsd-x86_64`;
  - `-v` reports the choice.
- **Dependencies**: zstd 1.6.0 sources come from the `zstdz` flake input (pinned commit), compiled by `build.zig`.

**Runtime sizes** (uncompressed / gzipped, bytes):

| Target | Uncompressed | gzipped |
| --- | ---: | ---: |
| linux-x86_64 | 77,040 | 42,407 |
| linux-aarch64 | 79,000 | 46,587 |
| macos-x86_64 | 56,095 | 24,486 |
| macos-arm64 | 89,040 | 24,915 |
| freebsd-x86_64 | 58,656 | 30,458 |
| freebsd-aarch64 | 52,984 | 29,802 |
| netbsd-x86_64 | 60,088 | 31,258 |

The Linux runtimes are statically linked with musl; its stdio accounts for part of their size, so a libc-free Linux runtime is the obvious next trim.

**Results:**

| App | Targets | Raw layout | zstd layout | Verified on |
| --- | --- | ---: | ---: | --- |
| z7z (Zig) | Windows x64 PE + Linux, macOS, FreeBSD x64/arm64, NetBSD x64 | 9,885,200 | 3,682,559 | Linux x64, macOS arm64, Rosetta, Windows x64, WSL2 (`sh`) |
| synthetic Roc app | Windows x64 PE + Linux/macOS x64/arm64 | 2,516,816 | 911,866 | Linux x64, macOS arm64 |
| P2 probe app | same | raw kept by `auto` (runtimes outweigh 8 KB of frames) | | |

**Tested in P7 and P4:**
- **Native runs.** Linux x64 under dash, bash, zsh and busybox with `PATH` limited to `uname mkdir dd chmod mv rm gzip`; macOS arm64 run as `./app` and as `sh ./app`; Windows x64 (the PE runs in place).
- **Emulated runs.** Rosetta 2. Linux aarch64: the extracted aarch64 runtime rebuilds the payload under qemu-user, and the payload then runs there too.
- **Correctness of extraction.** The rebuilt payload is byte-identical to the original, and the unpacked runtime is byte-identical to the built one. A warm run needs neither `gzip` nor the runtime.
- **Corrupted frames** fail with exit 126 and leave no cached payload.
- **32 concurrent cold starts** leave exactly one runtime and one payload in the cache.
- **Reproducibility.** The macOS-built zstd container is byte-identical to the Linux-built one, so the seven runtimes cross-build reproducibly on both hosts.

**Not yet:**
- No FreeBSD or NetBSD host has run its runtime.
- Windows ARM64 is still emulated.
- Payloads are cached on disk on every OS; running them from memory on Linux and the BSDs is not built.
- *(Done since: per-app cache namespace and self-cleaning; see below.)*

**App id and self-cleaning cache (built 2026-10-13).**
- **Layout.** Payloads are cached under `<cache>/rocosmo/<app-id>/<hash>` and runtimes under `<cache>/rocosmo/runtime/<hash>`. `<cache>` is `$XDG_CACHE_HOME`, else `~/Library/Caches` on macOS, else `~/.cache`. The private TMPDIR fallback keeps the same subpaths.
- **Resolution** (`src/app_id.zig`):
  - `--app-id` first;
  - else the id the payloads declare as the literal `ROCOSMO_APP_ID=<id>;` (all declaring payloads must agree);
  - else `local.<output name>`, sanitized.

  Text that starts with the marker but does not form a whole declaration is ignored. That covers the packer's own copy of the prefix, and Roc strings, which carry no NUL terminator; hence the `;`.
- **Roc** (tested). An app that provides `app_id : Str`, exposed by the platform as `roc_app_id` and referenced by the host, carries the literal in all six P2 binaries: Linux, macOS and Windows on x64 and arm64.
- **Self-cleaning.** After installing a payload, the dispatcher deletes that app's other finished entries (bare hashes). It never touches in-flight temp files (`hash.pid`) or other apps' folders. If a concurrent run of another version removes the fresh entry between install and `exec`, the dispatcher re-extracts once. Tests cover:
  - version A→B→A switching;
  - a planted foreign temp file and a foreign app folder;
  - the default cache homes on Linux and on a real Mac.

  A mutation that stops sparing temp files fails both the cleaning test and the 32-way concurrency test.

## 12. A real app: pinterm (2026-10-13)

pinterm is a terminal pinball game: a Roc core (physics, scoring, rendering) behind a C terminal/audio host. `probes/p8_real_app/build-pinterm PINTERM_DIR OUT` cross-compiles it from Linux x86_64 with pinterm's own pinned Roc compiler, without modifying the pinterm checkout, and `pack-pinterm` packs the results.

| Target | Binary | Run | Result |
| --- | --- | --- | --- |
| linux-x86_64 | static ELF, 3.2 MB | native, from a memfd | 300-frame headless run, exit 0; only the runtime cached |
| linux-aarch64 | static ELF | qemu-user (emulated) | runtime rebuilds the payload byte-identically; `--about` runs |
| macos-arm64 | Mach-O | native real Mac | headless run exit 0 |
| macos-x86_64 | Mach-O | Rosetta 2 (emulated) | headless run exit 0 |
| Windows x86_64 | 3 KB stub PE | native real host | prints the WSL hint, exit 1 (pinterm's host is POSIX-only) |
| WSL2 | `sh ./pinterm` | Linux path | headless run exit 0, one cache file (the runtime) |

The container is 2,428,955 bytes; the raw layout would be 9,064,433. Each Roc compile with `--opt=speed` took about 10 minutes and used one core, so the four targets build in parallel.

Problems found, all in pinterm rather than rocosmo:

- Its host called `pipe2`, `F_SETPIPE_SZ` and `clock_nanosleep`, which macOS lacks; its platform header declared only Linux Roc targets; and `--about` reported "linux" on every OS. pinterm fixed all three in 3078199; the probe first used a forced-include shim and a patched header copy, and now uses neither. Rebuilt from 3078199: 2,384,499 bytes, and `--about` reports macos aarch64 and macos x86_64 on the Mac.
- Still open in pinterm: its Linux binaries carry debug info and are not stripped, and there is no Windows host. macOS sound arrived in pinterm 45e5ad7 (AudioToolbox loaded with `dlopen`); rebuilt 2026-10-14 with the dd/eval header of §13, the container is 2,393,481 bytes and `--about` is correct on Linux (`sh`, `oksh`), macOS native and Rosetta 2, and WSL2; the Windows stub still prints its WSL hint. Nobody has listened to the macOS audio yet.

The game was run headless only; nobody has yet played it interactively from the container on macOS.

### 11.x Trimmed runtimes (2026-10-13)

Measured with `gzip -9 -n`, as embedded. Three changes:
- runtime.c stopped using stdio, `strtoull`, `fstat` and `setenv`;
- the Linux runtimes link no C library at all, using `src/nolibc_linux.c` (raw syscalls on x86_64/aarch64, an mmap-per-block `malloc`, a short `strerror` table) compiled against musl's headers;
- unwind tables are off for every runtime.

| Runtime | Before (bytes, gzipped) | After |
| --- | --- | --- |
| linux-x86_64 | 43,992 | 27,479 |
| linux-aarch64 | 48,158 | 27,502 |
| freebsd-x86_64 | 30,793 | 27,703 |
| freebsd-aarch64 | 30,037 | 27,541 |
| netbsd-x86_64 | 31,567 | 28,429 |
| macos-x86_64 | 24,811 | 24,571 |
| macos-arm64 | 25,240 | 23,640 |

Dropping stdio alone took Linux to about 35 KB, removing musl to about 31 KB, and dropping unwind tables to 27.5 KB. Decode-only zstd is now most of each runtime. P7 gates both Linux runtimes at 28,000 bytes.

## 13. BSD on real kernels (2026-10-14)

`tests/probes/p9_bsd_vms.bash` boots official release images under QEMU and
runs one container inside each: FreeBSD 15.1 x86_64 (KVM), NetBSD 11.0 x86_64
(KVM) and FreeBSD 15.1 aarch64 (QEMU TCG emulation of a Cortex-A72; the
aarch64 runtime and payload run as aarch64 code inside an emulated machine, so
this is EMULATED, not native hardware). `probes/p9_bsd_vms/run-in-vm` verifies
each image against its published checksum, caches it in
`${XDG_CACHE_HOME:-~/.cache}/rocosmo-vm`, boots a throwaway qcow2 overlay and
passes the bundle in as a raw tar disk. FreeBSD runs the guest script from a
NoCloud seed disk (its `nuageinit` executes a `#!` user-data script);
NetBSD's live image has no such hook, so `netbsd.exp` drives its boot menu
over SeaBIOS's serial console (`etc/sercon-port`) into a single-user shell.
P9 takes about a minute; the emulated aarch64 guest dominates.

All three pass: zstd and raw layouts select the right payload, arguments with
spaces and exit statuses pass through, a rerun uses the cache, a direct
`./app` falls back to the shell, and the zstd cache holds exactly the runtime
and one payload. FreeBSD and NetBSD use the cache path, and must: a one-off
probe in the same VMs copied `/bin/echo` into a `memfd_create` descriptor and
tried to run it. FreeBSD 15.1 `fexecve` fails with `EBADF` and NetBSD 11.0
with `EINVAL`; `execve("/dev/fd/N")` fails with `ENOENT` (FreeBSD, no fdescfs
mounted) and `EACCES` (NetBSD). Both kernels execute only vnode-backed files,
so memfd execution stays Linux-only. Zig 0.16's NetBSD libc headers also lack
`memfd_create` (NetBSD 11 added it as system call 500).

Two shell findings changed the container header:

- **NUL bytes.** NetBSD's `/bin/sh` is built with `REJECT_NULS`
  (`bin/sh/Makefile`) and fails with `nul ('\0') in shell input` on any line
  holding a NUL; OpenBSD's ksh (tested as `oksh` 7.9 on Linux) fails with
  `NUL byte unexpected`. Both read and check one line at a time. The PE field
  `e_lfanew` at 0x3C always holds NUL bytes for a header below 16 MiB, so the
  APE-style header (`MZqFpD='` opening a quoted string that swallows the DOS
  header) cannot run there. APE files use that same header, so this probably
  affects them too; that is inferred from the bytes, not tested. The header is
  now line 1 `MZ=;eval "$(dd if="$0" bs=64 skip=1 count=N 2>/dev/null)"`,
  which fits in the DOS header bytes the Windows loader ignores (0x02-0x3B).
  It reads the NUL-free script region [0x40, e_lfanew) and evals it, so no
  shell reaches line 2. `e_lfanew` is now 64-byte aligned to match.
- **ksh aliases.** pdksh and mksh predefine `r='fc -e -'`, so a dispatcher
  function named `r` was rewritten before it was defined. It is now `rt`; a
  unit test rejects function names from ksh's default alias list.

The local shell matrix (P3, P7) now includes `oksh` and `mksh`. Linux,
macOS (native and Rosetta 2), Windows and WSL2 still pass with the new header.
OpenBSD itself remains untested: its runtime needs the `openbsd.syscalls`
section or an OpenBSD sysroot, and OpenBSD publishes no cloud-init image.

## 14. Two formats: universal and POSIX-only (2026-10-14)

The PE at offset 0 is needed only for Windows. A container whose project
declares no Windows target now uses a second format, chosen by `rocosmo-pack`
when no `--windows-x86_64` input is given:

| | Universal | POSIX-only |
| --- | --- | --- |
| Bytes 0-1 | `MZ` (Windows PE) | `#!` |
| Trampoline | line 1: `MZ=;eval "$(dd … bs=64 skip=1 count=N …)"` | line 1: `#!/bin/sh`; line 2: `eval "$(dd … bs=64 skip=2 count=N …)"` |
| Evaluated script region | [0x40, e_lfanew) | [0x80, end) |
| After the script | relocated PE headers and body, then payloads | payloads |
| Windows | runs the PE in place | not runnable (Windows reports an unsupported app) |
| Raw `execve(2)` on POSIX | fails with `ENOEXEC` | runs, through the shebang |

Both formats evaluate the same dispatcher script; only the first bytes and
the offsets differ. The POSIX-only head is 128 bytes because the two lines need
66, more than the 64 the universal head has. In the zstd layout the index keeps
its entry 0 for the PE body, empty, and no target references it.

The shebang matters for direct execution. Without one, a file runs only when
the caller falls back to `sh` after `ENOEXEC`, as shells and glibc's `execvp`
do. A raw `execve` from a C launcher, a service manager or another language's
process API gets `ENOEXEC` instead. P3 shows both sides with a raw-`execve`
launcher (`probes/p3_container/execve.c`): the universal container fails with
`Exec format error` and the POSIX-only container runs. The universal format
cannot have a shebang, because Windows requires `MZ` at offset 0.

Verified: the six-shell matrix (P3), Linux memory execution and the cache
fallback (P7), direct `./app` on macOS arm64 (P3), and direct runs plus base
`sh` on FreeBSD x86_64/aarch64 and NetBSD x86_64, plus NetBSD `ksh` (P9).

## 15. Smaller runtimes: zstd's educational decoder (2026-10-16)

The runtimes now decode with Meta's single-file educational decoder (`doc/educational_decoder/zstd_decompress.c` in the zstd repository, same BSD license) instead of space-optimized libzstd. `src/zdec_small.c` compiles it as one translation unit, prefixes its public names, passes a `--patch-from` reference to it in place as a raw-content dictionary (no copy), and redirects its `exit(1)` on corruption to `rocosmo_zdec_fail()`, which the runtime defines to report and exit with its usual status (126 under `--exec`, else 1). The decoder skips the content checksum, so `src/zstd_small.zig` checks it with `std.hash.XxHash64` and requires it to be present; a wrong delta reference is still rejected. Unit tests decode libzstd-encoded frames and deltas at levels 1, 3 and 19 and compare bytes.

| Runtime | Before (bytes, gzipped) | After |
| --- | --- | --- |
| linux-x86_64 | 27,479 | 14,475 |
| linux-aarch64 | 27,502 | 14,756 |
| freebsd-x86_64 | 27,703 | 14,531 |
| freebsd-aarch64 | 27,541 | 14,599 |
| netbsd-x86_64 | 28,429 | 15,309 |
| macos-x86_64 | 24,571 | 14,399 |
| macos-arm64 | 23,640 | 14,400 |

P7 gated all seven at 16,000 bytes (14,500 after the second pass below).

**Cost: decoding is about three times slower.** Rebuilding the 250 MB Roc compiler (x86_64 Linux, AMD Threadripper 3990X, `--level 3` frame, `/usr/bin/time`, three runs each, identical output): libzstd runtime 0.27-0.31 s user, 0.29-0.31 s system, 0.59-0.61 s wall; small decoder 1.10-1.11 s user, 0.28 s system, 1.39-1.40 s wall. The first small-decoder build spent 0.8 s in system time: the decoder allocates and frees a few tables per 128 KB block, and `nolibc_linux.c` mapped each block separately (61,188 mmap/munmap pairs, counted with `strace -c`). Keeping up to eight freed mappings of at most 1 MiB for reuse removed that for about 150 gzipped bytes. In the same profile, `perf` attributes 45% of samples to `decode_frame` (sequence decoding, inlined) and 26% to `HUF_decompress_1stream`; compiling the decoder at `-O2` or `-O3` instead of `-Os` changed user time by under 10% and added about 2 KB gzipped, so it stays at `-Os`.

Linux runs payloads up to 64 MiB from a memfd and decodes them on every start, so each start there costs about 3 ms more per MB of payload (wall time per MB rebuilt went from 2.4 ms to 5.6 ms in the run above); a 3 MB app starts about 10 ms later. Other systems and larger payloads decode once into the cache. A decoder written for both size and speed (table-driven bit reading, word-sized match copies) is the way to recover the time; it is recorded in PLAN.md. Zig 0.16's `std.compress.zstd` was also tried: it decodes `--patch-from` deltas when the reference is placed in its output buffer ahead of the write position, but a ReleaseSmall test program is 203 KB and took 0.41 s of CPU for 30 MB, against 0.10 s for the educational decoder.

Smaller runtimes also move `--layout auto`'s break-even: the five-target P2 probe set is now smaller as zstd (83,432 bytes against 107,648 raw), so P3 and P4, which test the raw layout, pass `--layout raw`.

**Second pass (2026-10-16).** Two cuts found with `nm --size-sort` on an unstripped build: `std.hash.XxHash64` compiled to 3,675 bytes, so `src/xxh64.zig` replaces it with a plain-loop XXH64 (differential-tested against the standard library over lengths 0-300 and up to 70,000 bytes, two seeds); and the decoder's unused public functions (dictionary parsing, the plain decompress entry points) stayed linked until the runtime's C files were compiled with `-ffunction-sections -fdata-sections`. Rebuild time for the 250 MB payload is unchanged (1.43-1.45 s wall).

| Runtime | First pass (bytes, gzipped) | Second pass |
| --- | --- | --- |
| linux-x86_64 | 14,475 | 12,891 |
| linux-aarch64 | 14,756 | 12,747 |
| freebsd-x86_64 | 14,531 | 12,983 |
| freebsd-aarch64 | 14,599 | 12,665 |
| netbsd-x86_64 | 15,309 | 13,765 |
| macos-x86_64 | 14,399 | 13,505 |
| macos-arm64 | 14,400 | 13,450 |

P7's gate is now 14,500 bytes.

**Third pass: `-Oz` (2026-10-16).** Zig compiles C at `-Os` for ReleaseSmall. Adding clang's `-Oz` to the runtime's C files (decoder, `runtime.c`, `nolibc_linux.c`) trades speed for size:

| Runtime | Second pass (bytes, gzipped) | `-Oz` |
| --- | --- | --- |
| linux-x86_64 | 12,891 | 9,903 |
| linux-aarch64 | 12,747 | 10,061 |
| freebsd-x86_64 | 12,983 | 10,032 |
| freebsd-aarch64 | 12,665 | 9,970 |
| netbsd-x86_64 | 13,765 | 10,800 |
| macos-x86_64 | 13,505 | 10,544 |
| macos-arm64 | 13,450 | 11,245 |

Rebuilding the 250 MB Roc payload takes 1.66-1.68 s wall (1.35-1.38 s user) instead of 1.43-1.45 s, about 6.7 ms per MB. The project's stated priority for these pieces is size, so `-Oz` stays; removing the three `-Oz` flags in `build.zig` restores the second pass. P7's gate is now 12,000 bytes.

**Peak memory (2026-10-16).** The runtime used to copy each byte range it needed (index, stored frame, raw reference) into the heap with `pread`. It now maps them read-only, so they are clean page cache rather than private memory. Measured under a cgroup memory cap (`systemd-run --user --scope -p MemoryMax=400M -p MemorySwapMax=0`, output on disk, the level-3 Roc container): before, rebuilding linux-x86_64 (a delta against the raw 252 MB Windows image) was killed at 400 MB and passed at 600 MB; after, it passes at 400 MB, as do macos-x86_64 and macos-arm64. linux-aarch64 is still killed at 400 MB: its reference is a whole frame that has to be decoded into memory (about 250 MB) next to its own 234 MB output. The change also made the runtimes about 70 bytes smaller.

## 16. The Roc compiler as one container (2026-10-16)

`scripts/build-roc-container` packs the pinned nightly (`nightly-2026-10-12-2664a27`) for all five systems it is published for. `flake.nix` fetches each archive by its GitHub release digest (package `roc-all-targets`). Each archive holds one static `roc` executable plus `LICENSE` and `legal_details`, so nothing else has to travel with it.

| Input | Bytes |
| --- | --- |
| linux-x86_64 | 249,432,544 |
| linux-aarch64 | 234,164,056 |
| macos-x86_64 | 265,191,172 |
| macos-arm64 | 252,831,024 |
| windows-x86_64 (`roc.exe`) | 251,697,664 |

| Level | Container | Pack time | Peak memory |
| --- | --- | --- | --- |
| 3 | 436,646,951 | 16 s | 2.1 GB |
| 19 (default) | 400,406,010 | 710 s | 1.9 GB |

The Windows image is stored uncompressed, as the universal format requires, so it is 252 MB of either container. Measured with `zstd -3 --long=31` on single inputs: the Linux aarch64 compiler is 58.8 MB as a whole frame and 42.2 MB as a delta against the Linux x86_64 one, and the macOS x86_64 compiler is 42.7 MB as a delta against Linux x86_64. Cross-CPU deltas therefore save as much as same-OS-family ones for this program, unlike the small apps in §10. `rocosmo-pack` still tries only same-CPU references and the Windows image; with every x86_64 target able to use the Windows image, the gain from also trying cross-CPU references is expected to be small and was not measured.

Running it (level 3 unless noted, `version`):
- Linux x86_64: 1.3 s on the first run (rebuild into the cache; the payload is over the 64 MiB memfd limit), 0.024 s after. Level 19: 1.52 s, then 0.02 s.
- macOS arm64 (real host): native, and Rosetta 2 with `arch -x86_64`, both report the pinned nightly.
- Windows x86_64 (real host): the file renamed to `.exe` runs as the native PE.

It builds apps. On Linux it built P2 for x64musl, arm64musl, x64mac, arm64mac and x64win, and those packed into a container that ran. On the Mac it built and ran an arm64mac P2 app, and on Windows an x64win one. `tests/cli/roc_container.bash` checks all of this in `./test`.

Its output matches native `roc`'s, with two properties of Roc that look like differences at first. Native `roc` produced a 10,096-byte x64musl P2 executable with a warm Roc cache and a 10,128-byte one with an empty cache, so Roc's output depends on the state of its own cache; the container's first build, with an empty cache, was byte-identical to native `roc` with an empty cache. Roc's x64win output differs between any two builds at byte 129, inside the PE header's `TimeDateStamp`.

With the rocosmo-pack container (`scripts/build-pack-container`, 1.6 MB), a Windows or macOS machine with neither Nix nor Zig is a complete build host for apps whose platform ships prebuilt hosts. On each real host the Roc container built P2 for x64musl, arm64musl, x64mac, arm64mac and x64win (Roc's embedded linker cross-links all of them from Windows too), the rocosmo-pack container packed them, and the container ran on the build host and on Linux (`tests/cli/toolchain_hosts.bash`).

basic-cli 0.25.0's Windows target also fails to link on the Windows host (no Visual Studio installed there): `lld-link` reports undefined `mainCRTStartup` and `memcpy`, the Microsoft C runtime. On the Mac, the same basic-cli app builds for arm64mac, x64mac and x64musl.
