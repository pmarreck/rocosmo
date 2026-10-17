# PLAN log

Completed PLAN.md items retired by plan-retire, oldest retirement first.

## Retired 2026-10-14

- [x] [Publishing (BDFN, 2026-10-14)] Pack the zstd index and frames without 4 KiB alignment padding; only the dd-copied runtimes stay aligned. pinterm: 2,393,481 to 2,382,443 bytes (done 2026-10-14 08:10 EDT, c6461a3)
- [x] [Initial feasibility milestone] Research current Roc platform ABI, compiler generation, object emission and linker integration with dated primary sources and exact revisions. (2026-10-13 12:25 PM EDT)
- [x] [Initial feasibility milestone] Research current official Cosmopolitan/APE releases, cross-host toolchains and known limitations, especially native macOS ARM64 build support. (2026-10-13 12:25 PM EDT)
- [x] [Initial feasibility milestone] Establish a pinned flake.nix environment with hashed official upstream downloads and an update procedure. (2026-10-13 11:30 AM EDT)
- [x] [Initial feasibility milestone] Separate host/toolchain support from target/runtime support in a sourced OS-and-architecture matrix. (2026-10-13 12:25 PM EDT)
- [x] [Initial feasibility milestone] Compare platform-only integration, linker/compiler changes and alternative runtime paths, including cosmo-libc necessity and licensing. (2026-10-13 12:25 PM EDT)
- [x] [Initial feasibility milestone] Run small isolated feasibility probes and preserve commands, inputs, failures and evidence. (2026-10-13 12:20 PM EDT)
- [x] [Initial feasibility milestone] Assess loader, permissions, signing, quarantine, system API, thread/TLS and ABI constraints. (2026-10-13 12:25 PM EDT)
- [x] [Initial feasibility milestone] Reply to the coordinating agent and stop at the research milestone. (2026-10-13 12:30 PM EDT)
- [x] [BDFN direction added 2026-10-13] Verify the reported cosmocc limits against current sources and a sibling project's attempt. (2026-10-13 12:25 PM EDT)
- [x] [BDFN direction added 2026-10-13] Build a Roc-native polyglot container reusing APE's dispatch tricks. (2026-10-13 12:00 PM EDT)
- [x] [BDFN direction added 2026-10-13] Build every target from Linux x86_64 and macOS arm64 using Roc's cross-compiler. (2026-10-13 12:15 PM EDT)
- [x] [BDFN direction added 2026-10-13] Remove the libc dependency (raw syscalls, libSystem-only, kernel32-only hosts). (2026-10-13 11:50 AM EDT)
- [x] [BDFN direction added 2026-10-13] Document APE's dispatch mechanism separately in APE_DISPATCH.md. (2026-10-13 12:22 PM EDT)
- [x] [Prototype goal (latest OS versions only for now)] One Roc-built file runs natively on Linux, macOS and Windows and contains x86_64 and aarch64 code. (2026-10-13 12:05 PM EDT)
- [x] [Prototype goal (latest OS versions only for now)] It builds from Linux x86_64 and macOS arm64 hosts. (2026-10-13 12:15 PM EDT)
- [x] [Prototype goal (latest OS versions only for now)] Verify on real hardware: Linux x86_64, macOS arm64, Windows x86_64 and WSL2; emulation labeled. (2026-10-13 12:15 PM EDT)
- [x] [Next implementation phase (proposed in RESEARCH.md §9)] Payload compression (zstd). `--assimilate` declined by BDFN (2026-10-13 11:44 PM EDT): a universal binary must not rewrite itself into a single-platform one to save space.
- [x] [BDFN decisions 2026-10-13 (afternoon)] FreeBSD x86_64/aarch64 and NetBSD x86_64 containers verified in QEMU VMs, P9 (2026-10-14 12:20 AM EDT). OpenBSD still open.
- [x] [BDFN decisions 2026-10-13 (afternoon)] Payload compression: zstd with an embedded per-OS/CPU decoder runtime. (2026-10-13 6:10 PM EDT)
- [x] [BDFN decisions 2026-10-13 (afternoon)] Self-cleaning cache: decided and built. (2026-10-13 7:20 PM EDT)
- [x] [zstd runtime design study (BDFN, 2026-10-13 4:10 PM EDT)] Measure gzip vs solid zstd vs packer-chosen delta layouts, decoder cost included: Roc compiler (1 GB), ripgrep, z7z (9 targets incl. BSDs), a synthetic 600-function Roc app and the P2 app. (2026-10-13 4:55 PM EDT)
- [x] [zstd runtime design study (BDFN, 2026-10-13 4:10 PM EDT)] Decode-only zstd: 28-38 KB per target, applies --patch-from deltas, rejects a wrong reference. (2026-10-13 4:30 PM EDT)
- [x] [zstd runtime design study (BDFN, 2026-10-13 4:10 PM EDT)] Research: OpenBSD syscall pinning, in-memory exec, BSD base gzip, bare Mach-O notarization, Rust/Zig target tiers. (2026-10-13 4:40 PM EDT)
- [x] [zstd runtime design study (BDFN, 2026-10-13 4:10 PM EDT)] Write findings and a recommendation into RESEARCH.md §10. (2026-10-13 4:55 PM EDT)
- [x] [zstd runtime design study (BDFN, 2026-10-13 4:10 PM EDT)] Build the shared runtime and the zstd layout; rocosmo-pack chooses raw or zstd per container (RESEARCH.md section 11). (2026-10-13 6:10 PM EDT)
- [x] [zstd runtime design study (BDFN, 2026-10-13 4:10 PM EDT)] Run the FreeBSD and NetBSD runtimes on real hosts or VMs: P9, RESEARCH.md §13 (2026-10-14 12:20 AM EDT).
- [x] [zstd runtime design study (BDFN, 2026-10-13 4:10 PM EDT)] App-namespaced, self-cleaning cache: `--app-id`, embedded `ROCOSMO_APP_ID=<id>;` (Roc, Zig, Rust), default `local.<name>`; macOS uses ~/Library/Caches. (2026-10-13 7:20 PM EDT)
- [x] [Work order (BDFN, 2026-10-13 8:12 PM EDT: signing goes last)] Pack a real app, pinterm (Roc game with a C terminal host), into one file: RESEARCH.md section 12 (2026-10-13 9:05 PM EDT).
	- [x] pinterm 45e5ad7 adds macOS sound (AudioToolbox via dlopen, no SDK); container rebuilt and checked, copy on the Mac at ~/pinterm-rocosmo; someone still has to listen on a Mac (2026-10-14 1:00 AM EDT).
- [x] [Work order (BDFN, 2026-10-13 8:12 PM EDT: signing goes last)] Trim the Linux runtimes (libc-free, no stdio): 44-48 KB to 27.5 KB gzipped; RESEARCH.md section 11.x (2026-10-13 9:52 PM EDT).

## Retired 2026-10-16

- [x] [Recently done] Run payloads from memory: Linux done; FreeBSD and NetBSD kernels cannot exec a memfd (RESEARCH.md §13). (2026-10-14 12:30 AM EDT)
- [x] [Recently done] Linux: run the payload from memory (memfd + fexecve) instead of writing a cache file (2026-10-13 8:35 PM EDT). FreeBSD 15.1 and NetBSD 11.0 refuse to exec a memfd (EBADF, EINVAL), so they keep the cache path (RESEARCH.md §13, 2026-10-14 12:30 AM EDT).
- [x] [Recently done] FreeBSD and NetBSD runtimes in QEMU VMs (P9). Found and fixed: NetBSD sh and OpenBSD ksh reject NUL bytes (new dd/eval header line), ksh's `r` alias (function renamed) (2026-10-14 12:20 AM EDT).
- [x] [Recently done] No APE/Cosmopolitan dependency (BDFN, 2026-10-13 11:55 PM EDT): P1 cosmocc probe retired from `./test`, `cosmocc` dropped from the flake, findings kept in RESEARCH.md, Cosmopolitan and APE (Justine Tunney) credited in README.md (2026-10-14 12:35 AM EDT).
- [x] [Publishing (BDFN, 2026-10-14)] Two formats: universal (MZ/PE + sh) and POSIX-only (#!/bin/sh, no PE) when no Windows target is given; raw execve runs the POSIX-only one. RESEARCH.md §14 (done 2026-10-14 13:05 EDT, 0ceb5de)
- [x] [Publishing (BDFN, 2026-10-14)] Add an MIT license (copyright holder: the git author) (done 2026-10-14 14:45 EDT)
- [x] [Publishing (BDFN, 2026-10-14)] Zstandard BSD notice: THIRD_PARTY_NOTICES.md plus a license-URL comment in zstd containers, not the full text (done 2026-10-14 17:15 EDT)
- [x] [Publishing (BDFN, 2026-10-14)] `rocosmo` command in Roc on basic-cli (src/rocosmo): builds the targets the platform declares, then packs; universal with a Windows target, else POSIX-only (done 2026-10-16 00:40 EDT)
- [x] [Publishing (BDFN, 2026-10-14)] Shrink the per-OS/CPU runtimes: zstd's educational decoder, 23.6-28.4 KB to 14.4-15.3 KB gzipped, P7 gate 16,000 bytes; RESEARCH.md §15 (done 2026-10-16 10:19 EDT)

## Retired 2026-10-17

- [x] [Publishing (BDFN, 2026-10-14)] TECHNIQUE.md: both formats, dispatcher, layouts, memfd, limits; linked from the README, trampoline lines checked against the packer (done 2026-10-16 10:28 EDT)
- [x] [Publishing (BDFN, 2026-10-14)] Roc compiler as one container: scripts/build-roc-container, five nightlies, 400 MB at level 19; runs and builds apps on Linux, macOS (native, Rosetta 2) and Windows; RESEARCH.md §16 (done 2026-10-16 10:47 EDT)
- [x] [Publishing (BDFN, 2026-10-14)] rocosmo-pack as one container: scripts/build-pack-container, eight targets, 1.6 MB; runs on Linux, macOS, Windows and in the BSD VMs; packs byte-identically on Linux, macOS and Windows (binary stdio on Windows fixed) (done 2026-10-16 10:58 EDT)
- [x] [Publishing (BDFN, 2026-10-14)] Runtimes, second pass: compact XXH64, function sections and -Oz, 9.9-11.3 KB gzipped (decode 16% slower), gate 12,000; RESEARCH.md §15 (done 2026-10-16 11:19 EDT)
- [x] [Publishing (BDFN, 2026-10-14)] Runtime maps container ranges instead of copying them: the Roc linux-x86_64 rebuild now fits a 400 MB cgroup cap (killed before); RESEARCH.md §15 (done 2026-10-16 11:39 EDT)
- [x] [Decided 2026-10-17 (BDFN)] GitHub repo public, after auditing all 43 commits and the tracked files (no host names, home paths, network details or secrets; only git author metadata) (done 2026-10-17 00:15 EDT)
- [x] [Decided 2026-10-17 (BDFN)] Roc compiler as a release: prerelease roc-nightly-2026-10-12-2664a27 with the level-19 Roc container, the rocosmo-pack container, Roc's LICENSE and legal_details, Zstandard's license and SHA256SUMS; ran on Linux, macOS (native, Rosetta 2) and Windows before upload, download verified (done 2026-10-17 00:32 EDT)
- [x] [Decided 2026-10-17 (BDFN)] docs/ZSTD_DECODER_SPEC.md: what a minimum zstd decoder for the runtimes must do, decoding against another data source (raw-content dictionary, RFC 8878 §5), and how a decoder would be accepted. Spec only (done 2026-10-17 00:22 EDT)
