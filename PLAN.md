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
- [ ] Optional gzip payload compression and an `--assimilate` mode.

## BDFN decisions 2026-10-13 (afternoon)

- [ ] Add FreeBSD, OpenBSD and NetBSD x86_64 payloads (Roc already targets them); BSD test hosts are still needed.
- [ ] Payload compression. Measured on the probe app: gzip -9 lands within 4-13% of zstd -19 and xz -9, and stock macOS 26.7.1 ships gzip and bzip2 but not zstd or xz. Proposed: gzip now; zstd only with an embedded decoder. Awaiting a decision.
- [ ] Optional Apple Developer ID signing of the macOS payloads, run on a macOS build host; the ad-hoc signature stays the default.
- [ ] Self-cleaning cache: the dispatcher removes this app's superseded extractions. Layout and race handling are awaiting a decision.

## zstd runtime design study (BDFN, 2026-10-13 4:10 PM EDT)

Design under study: the unchanged MZ/sh header picks the OS and CPU and runs a small shared native runtime, cached once per machine. The runtime rebuilds the payload from zstd frames, where secondary targets are zstd `--patch-from` deltas against a reference, and then executes it. Large multi-language apps (100 MB-class Zig/Rust/Roc binaries) are in view, not only small Roc apps.

- [x] Measure gzip vs solid zstd vs packer-chosen delta layouts, decoder cost included: Roc compiler (1 GB), ripgrep, z7z (9 targets incl. BSDs), a synthetic 600-function Roc app and the P2 app. (2026-10-13 4:55 PM EDT)
- [x] Decode-only zstd: 28-38 KB per target, applies --patch-from deltas, rejects a wrong reference. (2026-10-13 4:30 PM EDT)
- [x] Research: OpenBSD syscall pinning, in-memory exec, BSD base gzip, bare Mach-O notarization, Rust/Zig target tiers. (2026-10-13 4:40 PM EDT)
- [x] Write findings and a recommendation into RESEARCH.md §10. (2026-10-13 4:55 PM EDT)
- [ ] Build the shared runtime (decode-only zstd, mini_blar index, memfd or cache exec) and measure its real size; then let rocosmo-pack choose gzip-only or zstd+delta per container.
- [ ] OpenBSD: emit the openbsd.syscalls section or use an OpenBSD sysroot; needs an OpenBSD test host.
- [ ] App-namespaced, self-cleaning cache (BDFN, 2026-10-13): `--app-id` in reverse-DNS form (e.g. `llc.mecha.validate`); payloads under `rocosmo/apps/<app-id>/<hash>`, runtimes shared under `rocosmo/runtime/<hash>`; an app deletes only its own superseded entries; macOS may use `~/Library/Caches/<app-id>`. Open: default when `--app-id` is absent.
