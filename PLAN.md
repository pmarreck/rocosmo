# PLAN

Completed items are retired to docs/PLAN_LOG.md. Background for open items lives in docs/plan_context/ and RESEARCH.md.

## Publishing (BDFN, 2026-10-14)

- [x] `rocosmo` command in Roc on basic-cli (src/rocosmo): builds the targets the platform declares, then packs; universal with a Windows target, else POSIX-only (done 2026-10-16 00:40 EDT)
- [ ] basic-cli 0.25.0: macOS targets build on a Mac (verified 2026-10-16) but not from Linux (no libSystem stub); x64win needs Microsoft's C runtime libraries and fails on Linux, macOS and the Windows host alike (RESEARCH.md §16). Platform's responsibility; rocosmo stops with Roc's error.
- [x] TECHNIQUE.md: both formats, dispatcher, layouts, memfd, limits; linked from the README, trampoline lines checked against the packer (done 2026-10-16 10:28 EDT)
- [x] Roc compiler as one container: scripts/build-roc-container, five nightlies, 400 MB at level 19; runs and builds apps on Linux, macOS (native, Rosetta 2) and Windows; RESEARCH.md §16 (done 2026-10-16 10:47 EDT)
- [x] rocosmo-pack as one container: scripts/build-pack-container, eight targets, 1.6 MB; runs on Linux, macOS, Windows and in the BSD VMs; packs byte-identically on Linux, macOS and Windows (binary stdio on Windows fixed) (done 2026-10-16 10:58 EDT)
- [ ] The rocosmo command as a container: blocked on basic-cli (no Windows link anywhere; macOS targets only on a Mac). Alternatives: build its macOS slots on the Mac host, or move it to a platform that cross-builds every target.
- [x] Shrink the per-OS/CPU runtimes: zstd's educational decoder, 23.6-28.4 KB to 14.4-15.3 KB gzipped, P7 gate 16,000 bytes; RESEARCH.md §15 (done 2026-10-16 10:19 EDT)
- [x] Runtimes, second pass: compact XXH64 and function sections, 12.7-13.8 KB gzipped, gate 14,500 (done 2026-10-16 11:10 EDT)
- [ ] Recover the decode speed the small decoder lost (about 3x slower; +3 ms per MB on each Linux memfd start): a size-and-speed decoder, differential-tested against libzstd (RESEARCH.md §15).
- [ ] Push each finished step to GitHub (BDFN, 2026-10-16): new private repo, visibility left for BDFN to change.
- [ ] Attractive README showing the one-command use.
- [ ] Audit all commits and tracked files for private details; push only after BDFN picks the remote.

## Awaiting BDFN

- [ ] Windows launcher for large universal containers (opt-in, after a Defender test?): proposal and risks in docs/plan_context/windows_launcher.md (asked 2026-10-16).
- [ ] Install Visual Studio Build Tools (the MSVC C runtime) on the Windows test host so basic-cli's x64win target can be tried there? It changes that machine's setup (asked 2026-10-16).
- [ ] Make the GitHub repo public, and publish the Roc container as a release asset (Roc's UPL license and legal_details would ship with it)? (asked 2026-10-16)

- [ ] Decide scope for app icons across OSes (asked 2026-10-14).
- [ ] Decide scope for double-clickable macOS GUI apps (.app bundle in the cache, a wrapper beside the container, or neither) (asked 2026-10-14).
- [ ] Refresh INTENT.md's stale purpose and stopping-point sections (draft offered 2026-10-14).

## Later

- [ ] Real platform package: per-OS libc-free Zig host with args, environment, I/O and a size-recording allocator.
- [ ] Shared per-architecture code across OSes: analyzed in RESEARCH.md §7, not built.
- [ ] Windows ARM64 native: relay from the x64 host to an embedded arm64 PE; test on Windows 11 on Arm hardware.
- [ ] Build from Linux aarch64 and macOS x86_64 hosts (untested; no hardware used yet).
- [ ] Make the build scripts portable to a Windows build host.
- [ ] OpenBSD runtime and test host (context: docs/plan_context/zstd_runtime.md)

## Last

- [ ] Optional Apple Developer ID signing of the macOS payloads on a macOS build host (ad-hoc stays the default; the app id can serve as the signing identifier).


## Recently done

