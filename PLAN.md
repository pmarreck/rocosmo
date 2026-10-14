# PLAN

Completed items are retired to docs/PLAN_LOG.md. Background for open items lives in docs/plan_context/ and RESEARCH.md.

## Publishing (BDFN, 2026-10-14)

- [x] Add an MIT license (copyright holder: the git author) (done 2026-10-14 14:45 EDT)
- [x] Zstandard BSD notice: THIRD_PARTY_NOTICES.md plus a license-URL comment in zstd containers, not the full text (done 2026-10-14 17:15 EDT)
- [ ] `rocosmo` command in Roc on basic-cli: build exactly the targets the app's platform declares, then pack (universal format when a Windows target exists, else POSIX-only).
- [ ] TECHNIQUE.md: full technique write-up covering both formats, linked from the README.
- [ ] Attractive README showing the one-command use.
- [ ] Audit all commits and tracked files for private details; push only after BDFN picks the remote.
- [x] Two formats: universal (MZ/PE + sh) and POSIX-only (#!/bin/sh, no PE) when no Windows target is given; raw execve runs the POSIX-only one. RESEARCH.md §14 (done 2026-10-14 13:05 EDT, 0ceb5de)

## Awaiting BDFN

- [ ] Decide scope for app icons across OSes (asked 2026-10-14).
- [ ] Decide scope for double-clickable macOS GUI apps (.app bundle in the cache, a wrapper beside the container, or neither) (asked 2026-10-14).
- [ ] Refresh INTENT.md's stale purpose and stopping-point sections (draft offered 2026-10-14).

## Later

- [ ] Ship the Roc compiler itself as a rocosmo container that produces rocosmo containers (BDFN idea, 2026-10-14).
- [ ] Real platform package: per-OS libc-free Zig host with args, environment, I/O and a size-recording allocator.
- [ ] Shared per-architecture code across OSes: analyzed in RESEARCH.md §7, not built.
- [ ] Windows ARM64 native: relay from the x64 host to an embedded arm64 PE; test on Windows 11 on Arm hardware.
- [ ] Build from Linux aarch64 and macOS x86_64 hosts (untested; no hardware used yet).
- [ ] Make the build scripts portable to a Windows build host.
- [ ] OpenBSD runtime and test host (context: docs/plan_context/zstd_runtime.md)

## Last

- [ ] Optional Apple Developer ID signing of the macOS payloads on a macOS build host (ad-hoc stays the default; the app id can serve as the signing identifier).


## Recently done

- [x] Run payloads from memory: Linux done; FreeBSD and NetBSD kernels cannot exec a memfd (RESEARCH.md §13). (2026-10-14 12:30 AM EDT)
- [x] Linux: run the payload from memory (memfd + fexecve) instead of writing a cache file (2026-10-13 8:35 PM EDT). FreeBSD 15.1 and NetBSD 11.0 refuse to exec a memfd (EBADF, EINVAL), so they keep the cache path (RESEARCH.md §13, 2026-10-14 12:30 AM EDT).
- [x] No APE/Cosmopolitan dependency (BDFN, 2026-10-13 11:55 PM EDT): P1 cosmocc probe retired from `./test`, `cosmocc` dropped from the flake, findings kept in RESEARCH.md, Cosmopolitan and APE (Justine Tunney) credited in README.md (2026-10-14 12:35 AM EDT).
- [x] FreeBSD and NetBSD runtimes in QEMU VMs (P9). Found and fixed: NetBSD sh and OpenBSD ksh reject NUL bytes (new dd/eval header line), ksh's `r` alias (function renamed) (2026-10-14 12:20 AM EDT).
