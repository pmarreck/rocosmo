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
  Apple Silicon (tested; §5 P1).
- **Remaining gaps.** Windows ARM64 runs only the x64 PE under Prism
  emulation; a native ARM64 relay is designed but not built. Linux aarch64 is
  tested only under qemu-user. An aarch64 Linux build host and an x86_64 macOS
  build host are untested.

## 2. Pinned inputs

| Input | Version / revision | Provenance |
| --- | --- | --- |
| Roc compiler | `nightly-2026-10-12-2664a27` | [roc-lang/nightlies release](https://github.com/roc-lang/nightlies/releases/tag/nightly-2026-10-12-2664a27), per-system tarballs hashed in `flake.nix` from the release's SHA-256 digests |
| Roc source read | `main` at `c79847aa738cfb849b27e52354474d536a073da8` (2026-10-13) | <https://github.com/roc-lang/roc/tree/c79847aa738cfb849b27e52354474d536a073da8> |
| Cosmopolitan toolchain | `cosmocc-4.0.2.zip` | <https://cosmo.zip/pub/cosmocc/cosmocc-4.0.2.zip>; GitHub release 4.0.2 published 2025-01-06 is still the latest release on 2026-10-13. The mutable `cosmocc.zip` alias currently has the same size and ETag; the flake never uses it. |
| Cosmopolitan source read | `master` at `c7c9916eb8ceaa5062c917d1fea5efb0ee6b49b4` (2026-10-13) | <https://github.com/jart/cosmopolitan/tree/c7c9916eb8ceaa5062c917d1fea5efb0ee6b49b4> |
| Zig (hosts, packer) | 0.16.0 from nixpkgs (`flake.lock`) | nixpkgs |

nixpkgs also packages `cosmocc` 4.0.2, but only for `x86_64-linux`. The flake
fetches the official zip so macOS hosts get the same toolchain.

### Updating pins

- **Roc:** pick a tag from the nightlies releases page. Set `rocNightly`, then
  copy each asset's `sha256:` digest into `rocAssets` (convert with
  `nix hash convert --hash-algo sha256 --to sri HEX`). Run `./test`.
- **Cosmopolitan:** when a new `cosmocc-X.Y.Z.zip` appears, set
  `cosmoccVersion`, use `lib.fakeHash` for `cosmoccHash`, run
  `nix build .#cosmocc`, copy the reported hash and run `./test`.
- **nixpkgs:** `nix flake update`, then `./test`.

## 3. Terms kept separate

- **Build host:** where `roc build` and the packer run.
- **Target:** a Roc target name (`x64musl`, `arm64mac`, ...), meaning an object
  format, OS ABI and CPU.
- **Runtime platform:** the Roc *platform* (Roc API plus host) that supplies I/O
  and allocation; distinct from a compiler target.
- **Native:** the CPU executes the payload's own instructions under that OS.
- **Emulated:** qemu-user, Rosetta 2 or Prism translates the instructions.
- **WSL2:** a real Linux kernel in a VM on Windows; counted as a Linux result.

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

`./test` runs P1–P4 plus the packer unit tests; 54 checks passed on
2026-10-13. Real-hardware checks need SSH aliases in the ignored
`local/hosts.env` (`ROCOSMO_MACOS_ARM64_HOST`, `ROCOSMO_WINDOWS_X64_HOST`,
`ROCOSMO_WSL_X64_HOST`). An unset alias fails the suite rather than skipping.

Test hosts used: a Linux x86_64 NixOS build host; an Apple M4 Max on macOS
26.7.1 with Xcode; a Windows 10 22H2 (build 19045) x86_64 PC; and WSL2
(kernel 6.18.33.2-microsoft-standard-WSL2) on that PC.

### P1: Roc archive linked by cosmocc (`probes/p1_cosmo_archive`)

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
- WSL2 Linux x86_64, direct `./app`.

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
    mode, or shipping the extracted native file.
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
4. **Add optional gzip payload compression and `--assimilate`.**

Open questions for the BDFN:

- Do the BSDs matter? Adding them is one more payload each, and Roc already has
  FreeBSD/OpenBSD/NetBSD x64 targets.
- Is unsigned distribution acceptable, or should macOS Developer ID and
  Authenticode signing be in scope?
- Should cache cleanup be the program's job or the user's?
