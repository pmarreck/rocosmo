# PLAN

## Initial feasibility milestone

- [x] Research current Roc platform ABI, compiler generation, object emission and linker integration with dated primary sources and exact revisions. (2026-10-13 12:25 PM EDT)
- [x] Research current official Cosmopolitan/APE releases, cross-host toolchains and known limitations, especially native macOS ARM64 build support. (2026-10-13 12:25 PM EDT)
- [x] Establish a pinned flake.nix environment with hashed official upstream downloads and an update procedure. (2026-10-13 11:30 AM EDT)
- [x] Separate host/toolchain support from target/runtime support in a sourced OS-and-architecture matrix. (2026-10-13 12:25 PM EDT)
- [x] Compare platform-only integration, linker/compiler changes and alternative runtime paths, including cosmo-libc necessity and licensing. (2026-10-13 12:25 PM EDT)
- [x] Run small isolated feasibility probes and preserve commands, inputs, failures and evidence. (2026-10-13 12:20 PM EDT)
- [x] Assess loader, permissions, signing, quarantine, system API, thread/TLS and ABI constraints. (2026-10-13 12:25 PM EDT)
- [x] Reply to the coordinating agent and stop at the research milestone. (2026-10-13 12:30 PM EDT)

## BDFN direction added 2026-10-13

- [x] Verify the reported cosmocc limits against current sources and a sibling project's attempt. (2026-10-13 12:25 PM EDT)
- [x] Build a Roc-native polyglot container reusing APE's dispatch tricks. (2026-10-13 12:00 PM EDT)
- [x] Build every target from Linux x86_64 and macOS arm64 using Roc's cross-compiler. (2026-10-13 12:15 PM EDT)
- [x] Remove the libc dependency (raw syscalls, libSystem-only, kernel32-only hosts). (2026-10-13 11:50 AM EDT)
- [x] Document APE's dispatch mechanism separately in APE_DISPATCH.md. (2026-10-13 12:22 PM EDT)
- [ ] Windows ARM64 native: relay from the x64 host to an embedded arm64 PE; test on Windows 11 on Arm hardware.
- [ ] Shared per-architecture code across OSes: analyzed (RESEARCH.md §7), not built.

## Prototype goal (latest OS versions only for now)

- [x] One Roc-built file runs natively on Linux, macOS and Windows and contains x86_64 and aarch64 code. (2026-10-13 12:05 PM EDT)
- [x] It builds from Linux x86_64 and macOS arm64 hosts. (2026-10-13 12:15 PM EDT)
- [ ] Build from Linux aarch64 and macOS x86_64 hosts (untested; no hardware used yet).
- [x] Verify on real hardware: Linux x86_64, macOS arm64, Windows x86_64 and WSL2; emulation labeled. (2026-10-13 12:15 PM EDT)

## Next implementation phase (proposed in RESEARCH.md §9)

- [ ] Real platform package: per-OS libc-free Zig host with args, environment, I/O and a size-recording allocator.
- [ ] `rocosmo` wrapper command running all target builds plus packing; build scripts portable to a Windows build host.
- [x] Payload compression (zstd, below). `--assimilate` declined by BDFN (2026-10-13 11:44 PM EDT): a universal binary must not rewrite itself into a single-platform one to save space.

## BDFN decisions 2026-10-13 (afternoon)

- [x] FreeBSD x86_64/aarch64 and NetBSD x86_64 containers verified in QEMU VMs, P9 (2026-10-14 12:20 AM EDT). OpenBSD still open (item 5).
- [x] Payload compression: zstd with an embedded per-OS/CPU decoder runtime (see the zstd runtime section below). (2026-10-13 6:10 PM EDT)
- [x] Self-cleaning cache: decided and built (see below). (2026-10-13 7:20 PM EDT)

## zstd runtime design study (BDFN, 2026-10-13 4:10 PM EDT)

Design under study: the unchanged MZ/sh header picks the OS and CPU and runs a small shared native runtime, cached once per machine. The runtime rebuilds the payload from zstd frames, where secondary targets are zstd `--patch-from` deltas against a reference, and then executes it. Large multi-language apps (100 MB-class Zig/Rust/Roc binaries) are in view, not only small Roc apps.

- [x] Measure gzip vs solid zstd vs packer-chosen delta layouts, decoder cost included: Roc compiler (1 GB), ripgrep, z7z (9 targets incl. BSDs), a synthetic 600-function Roc app and the P2 app. (2026-10-13 4:55 PM EDT)
- [x] Decode-only zstd: 28-38 KB per target, applies --patch-from deltas, rejects a wrong reference. (2026-10-13 4:30 PM EDT)
- [x] Research: OpenBSD syscall pinning, in-memory exec, BSD base gzip, bare Mach-O notarization, Rust/Zig target tiers. (2026-10-13 4:40 PM EDT)
- [x] Write findings and a recommendation into RESEARCH.md §10. (2026-10-13 4:55 PM EDT)
- [x] Build the shared runtime and the zstd layout; rocosmo-pack chooses raw or zstd per container (RESEARCH.md section 11). (2026-10-13 6:10 PM EDT)
- [ ] Run payloads from memory on Linux/FreeBSD/NetBSD for small payloads.
- [x] Run the FreeBSD and NetBSD runtimes on real hosts or VMs: P9, RESEARCH.md §13 (2026-10-14 12:20 AM EDT).
- [ ] OpenBSD: emit the openbsd.syscalls section or use an OpenBSD sysroot; needs an OpenBSD test host.
- [x] App-namespaced, self-cleaning cache: `--app-id`, embedded `ROCOSMO_APP_ID=<id>;` (Roc, Zig, Rust), default `local.<name>`; macOS uses ~/Library/Caches. (2026-10-13 7:20 PM EDT)

## Work order (BDFN, 2026-10-13 8:12 PM EDT: signing goes last)

1. [x] Pack a real app, pinterm (Roc game with a C terminal host), into one file: RESEARCH.md section 12 (2026-10-13 9:05 PM EDT).
   - [ ] pinterm 45e5ad7 adds macOS sound (AudioToolbox via dlopen, no SDK). Rebuild the container, then update RESEARCH.md section 12's "silent on macOS" item; someone still has to listen on a Mac.
2. [x] Linux: run the payload from memory (memfd + fexecve) instead of writing a cache file (2026-10-13 8:35 PM EDT). Next: FreeBSD/NetBSD (memfd_create since FreeBSD 13.0, NetBSD 11.0), now testable in P9's VMs.
3. [x] Trim the Linux runtimes (libc-free, no stdio): 44-48 KB to 27.5 KB gzipped; RESEARCH.md section 11.x (2026-10-13 9:52 PM EDT).
4. ~~`--assimilate`~~ declined (see above); the container never rewrites itself.
4a. [ ] No APE/Cosmopolitan dependency (BDFN, 2026-10-13 11:55 PM EDT): retire the P1 cosmocc probe from `./test` and drop `cosmocc` from the flake; keep its findings in RESEARCH.md and credit Cosmopolitan and APE (Justine Tunney) in README.md as the design the container format descends from. The shipped pipeline already uses none of it.
5. [x] FreeBSD and NetBSD runtimes in QEMU VMs (P9, 2026-10-14 12:20 AM EDT). Found and fixed: NetBSD sh and OpenBSD ksh reject NUL bytes (new dd/eval header line), ksh's `r` alias (function renamed). Next: OpenBSD (runtime needs `openbsd.syscalls` or a sysroot; no cloud-init image, so a serial-driven install).
6. Windows ARM64 native relay; builds from Linux aarch64 and macOS x86_64 hosts.
7. Real platform package and `rocosmo` wrapper command; shared per-arch code.
8. Last: optional Apple Developer ID signing of the macOS payloads on a macOS build host (ad-hoc stays the default; the app id can serve as the signing identifier).
