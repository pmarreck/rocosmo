# PLAN

Completed items are retired to docs/PLAN_LOG.md. Background for open items lives in docs/plan_context/ and RESEARCH.md.

## Decided 2026-10-17 (BDFN)

- [x] OpenBSD 7.9 arm64: openbsd-aarch64 target and runtime from a two-CPU sysroot; P9 installs an emulated arm64 VM unattended and every container check passes there (RESEARCH.md §17) (done 2026-10-17 09:50 EDT)
- [x] Roc's x64openbsd on a libc-linked platform: P2's platform lists OpenBSD's crt objects and libc, the output runs on OpenBSD amd64 from a container, and Plan.roc maps it (done 2026-10-17 09:50 EDT)
- [x] P2 builds with roc build --no-cache: a warm Roc cache changed x64musl's bytes and broke P4's cross-host identity (RESEARCH.md §17) (done 2026-10-17 09:50 EDT)
- [x] rocosmo command: `--no-cache` passes --no-cache to every roc build; caching stays the default (`--cache` restores it); README documents both (done 2026-10-17 12:50 EDT)

## Publishing (BDFN, 2026-10-14)

- [ ] Maximize target breadth (BDFN, 2026-10-18): make zig, roc and rust each a single universal binary running on as many OS/CPU combos as possible, and publish all three.
  - [x] Batch 1 — Linux CPU family (done 2026-10-18 ~17:10 EDT): widened `pack.Arch` to 8 CPUs (added arm, riscv64, powerpc64le, x86, loongarch64, s390x); only x86_64/aarch64 Linux keep the nolibc syscalls, every other arch links Zig's bundled static musl (no new per-arch asm). Added `targets.zig` rows + uname patterns, `build.zig` runtime rows, usage text, and a two-tier runtime-size gate (static-musl runtimes are larger but run on any Linux of that CPU). New `tests/cli/arch_matrix.bash` (41 assertions): packs an exit-145 payload for all 8 Linux CPUs into ONE zstd container, checks the embedded runtime is byte-identical to the built one, and runs the full rebuild+exec path (memfd and cache) under qemu-user per arch. All 8 CPUs verified: native x86_64 + emulated aarch64/arm/riscv64/powerpc64le/s390x/loongarch64/i386.
  - [ ] Batch 2 — BSD CPUs (Zig-only on the payload side; Roc ships no BSD, Rust BSD needs tier-3 std): add freebsd arm/powerpc64le/riscv64, consider netbsd/openbsd arches. NetBSD `uname -m` returns `evbarm` for both 32/64-bit ARM, so no NetBSD-ARM row without a disambiguated/verified pattern. OpenBSD arm/riscv64 need sysroots added to flake.nix.
  - [ ] Example scripts: fetch every Zig 0.16.0 target; cross-build Rust for every feasible target; rebuild the three maximal containers; publish with a per-row verified(hardware)/verified(emulated)/built-not-run table. Supply side: Zig 0.16.0 ships 26 official target builds (linux x86_64/aarch64/arm/riscv64/powerpc64le/x86/loongarch64/s390x; freebsd x86_64/aarch64/arm/powerpc64le/riscv64; netbsd x86_64/aarch64/arm/x86; openbsd x86_64/aarch64/arm/riscv64; macos x86_64/aarch64; windows x86_64/aarch64/x86). Roc nightly ships only 5 (linux x86_64/aarch64, macos x86_64/arm64, windows x86_64) — hard upstream ceiling. Rust is our own program, cross-built via cargo-zigbuild (linux musl family + windows-gnu with rustup std). rocosmo work needed: widen `Arch` enum beyond {x86_64,aarch64} and propagate; add `known` uname patterns per target; build the zstd-layout runtime for every target by Zig cross-compile (keep the nolibc memfd fast path for x86_64/aarch64 linux, generic libc-linked cache runtime elsewhere). Windows stays x86_64-only (arm64 relay is a separate future item). Verification: native (linux x86_64), qemu-user for other linux arches (nixpkgs#qemu present), recorded hardware for macos/windows-x64; BSD only where a VM exists.
- [x] Release notes: mention both the raw-`execve` (`sh roc`) and WSL2 (`sh roc`) workarounds (done 2026-10-18 13:10 EDT).
- [x] Examples proving the technique packs other compilers (done 2026-10-18 15:30 EDT; examples/, examples/README.md). Zig: official 0.16.0 for five targets joined into one universal `zig` (318,032,468 bytes); `zig version` ran natively on Linux x86_64, macOS arm64 and Windows x86_64, and it compiled examples/hello.zig from the container (exit 145). Compiling needs `lib/` via `ZIG_LIB_DIR` (Zig's own rule). Rust: `rustc` is a ~16 KB shim over librustc_driver/libLLVM + a 317 MB sysroot, so not single-file; packed the compiler's OUTPUT instead (examples/rust_hello cross-built for the three SDK-free targets: linux x86_64/aarch64 musl, windows x86_64) into one 622,440-byte universal binary; printed 145 on Linux x86_64 and Windows x86_64. macOS cross needs an Apple SDK (buildable on a Mac). Offline mechanism check: tests/cli/examples_compilers.bash (in ./test).

- [x] Build the `roc` container with `--windows-launcher`, measure its size against the 400 MB uncompressed-PE container, and publish both so either can be shared (done 2026-10-17 22:20 EDT). 188,462,705 bytes vs 400,390,546 (53% smaller). Verified on the Windows host: Defender active+current, runs under real-time protection (rebuilds and prints the pinned nightly), container and rebuilt cache exe both scan clean. Published to the roc-nightly-2026-10-12-2664a27 pre-release as the `roc-compact` asset beside `roc`, SHA256SUMS and notes updated. `scripts/build-roc-container` grew a `--windows-launcher` flag.
- [ ] basic-cli 0.25.0: macOS targets build on a Mac (verified 2026-10-16) but not from Linux (no libSystem stub); x64win needs Microsoft's C runtime libraries and fails on Linux, macOS and the Windows host alike (RESEARCH.md §16). Platform's responsibility; rocosmo stops with Roc's error.
- [ ] The rocosmo command as a container: blocked on basic-cli (no Windows link anywhere; macOS targets only on a Mac). Alternatives: build its macOS slots on the Mac host, or move it to a platform that cross-builds every target.
- [ ] Recover the decode speed the small decoder lost (about 3x slower; +3 ms per MB on each Linux memfd start): a size-and-speed decoder, differential-tested against libzstd (RESEARCH.md §15; requirements in docs/ZSTD_DECODER_SPEC.md).
- [ ] Attractive README showing the one-command use.

## Awaiting BDFN
- [x] Share the `roc` universal container built by rocosmo: already published as a public pre-release (tag roc-nightly-2026-10-12-2664a27) with the 400 MB `roc` asset, rocosmo-pack, the Roc/rocosmo/zstd licenses and SHA256SUMS; matches the current nightly pin (confirmed 2026-10-17).

- [ ] Decide scope for app icons across OSes (asked 2026-10-14).
- [ ] Decide scope for double-clickable macOS GUI apps (.app bundle in the cache, a wrapper beside the container, or neither) (asked 2026-10-14).
- [ ] Refresh INTENT.md's stale purpose and stopping-point sections (draft offered 2026-10-14).

## Later

- [x] Opt-in `--windows-launcher` (x86_64) built and verified (done 2026-10-17 13:50 EDT; design in docs/plan_context/windows_launcher.md, how-it-works in TECHNIQUE.md). Default off.
  - [x] Packer core: store the app's real PE as a zstd target entry, put a small kernel32-only launcher PE at the front, patch it with the index location and the Windows entry name; round-trip test on Linux that the PE rebuilds byte-exact and the container shrinks.
  - [x] Launcher PE (src, libc-free Zig, kernel32 only): rebuild the Windows payload into %LOCALAPPDATA%\rocosmo\<app id>\<hash>.exe via the shared rt_ffi decode core, then CreateProcessW, inherit handles, forward the exit code.
  - [x] rocosmo-pack CLI + rocosmo command: `--windows-launcher` flag, documented in README/TECHNIQUE as off by default with the dropper/AV and child-process caveats.
  - [x] AV gate: on the Windows host, MpCmdRun.exe on-demand scan of the launcher and the launcher-fronted container, plus an execute-and-cache run for on-access protection; assert no detection.
- [ ] Noted (BDFN, 2026-10-17): a rocosmo-owned Roc platform (libc-free Zig host per target) so the rocosmo command and similar apps cross-build every target from any host; a separate deliverable under INTENT's boundary.

- [ ] Real platform package: per-OS libc-free Zig host with args, environment, I/O and a size-recording allocator.
- [ ] Shared per-architecture code across OSes: analyzed in RESEARCH.md §7, not built.
- [ ] Windows ARM64 native: relay from the x64 host to an embedded arm64 PE; test on Windows 11 on Arm hardware.
- [ ] Build from Linux aarch64 and macOS x86_64 hosts (untested; no hardware used yet).
- [ ] Build rocosmo-pack and the runtimes on a Windows host (packing and building Roc apps there already work through the two containers, tests/cli/toolchain_hosts.bash, 2026-10-16).

## Last

- [ ] Optional Apple Developer ID signing of the macOS payloads on a macOS build host (ad-hoc stays the default; the app id can serve as the signing identifier).

## Recently done

