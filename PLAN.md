# PLAN

Completed items are retired to docs/PLAN_LOG.md. Background for open items lives in docs/plan_context/ and RESEARCH.md.

## Decided 2026-10-17 (BDFN)

- [x] GitHub repo public, after auditing all 43 commits and the tracked files (no host names, home paths, network details or secrets; only git author metadata) (done 2026-10-17 00:15 EDT)
- [x] Visual Studio 2022 Build Tools (C++ workload, Windows SDK 10.0.26100.0) installed on the Windows test host with winget from PowerShell. basic-cli's x64win still fails to link: Roc's link step names no C runtime library, even with vcvars64 applied (RESEARCH.md §16) (done 2026-10-17 00:33 EDT)
- [x] Roc compiler as a release: prerelease roc-nightly-2026-10-12-2664a27 with the level-19 Roc container, the rocosmo-pack container, Roc's LICENSE and legal_details, Zstandard's license and SHA256SUMS; ran on Linux, macOS (native, Rosetta 2) and Windows before upload, download verified (done 2026-10-17 00:32 EDT)
- [x] docs/ZSTD_DECODER_SPEC.md: what a minimum zstd decoder for the runtimes must do, decoding against another data source (raw-content dictionary, RFC 8878 §5), and how a decoder would be accepted. Spec only (done 2026-10-17 00:22 EDT)
- [x] OpenBSD 7.9 x86_64: target, runtime and rocosmo-pack build against a pinned sysroot from the official sets; P9 installs a VM unattended from the miniroot and every container check passes there, base ksh included (RESEARCH.md §17) (done 2026-10-17 00:46 EDT)
- [ ] OpenBSD arm64 (needs an arm64 sysroot and an emulated VM install).
- [ ] Try Roc's x64openbsd target on a platform whose host links libc; map it in Plan.roc if it runs.

## Publishing (BDFN, 2026-10-14)

- [ ] basic-cli 0.25.0: macOS targets build on a Mac (verified 2026-10-16) but not from Linux (no libSystem stub); x64win needs Microsoft's C runtime libraries and fails on Linux, macOS and the Windows host alike (RESEARCH.md §16). Platform's responsibility; rocosmo stops with Roc's error.
- [ ] The rocosmo command as a container: blocked on basic-cli (no Windows link anywhere; macOS targets only on a Mac). Alternatives: build its macOS slots on the Mac host, or move it to a platform that cross-builds every target.
- [ ] Recover the decode speed the small decoder lost (about 3x slower; +3 ms per MB on each Linux memfd start): a size-and-speed decoder, differential-tested against libzstd (RESEARCH.md §15; requirements in docs/ZSTD_DECODER_SPEC.md).
- [ ] Attractive README showing the one-command use.

## Awaiting BDFN

- [ ] Decide scope for app icons across OSes (asked 2026-10-14).
- [ ] Decide scope for double-clickable macOS GUI apps (.app bundle in the cache, a wrapper beside the container, or neither) (asked 2026-10-14).
- [ ] Refresh INTENT.md's stale purpose and stopping-point sections (draft offered 2026-10-14).

## Later

- [ ] On hold (BDFN, 2026-10-17): opt-in Windows launcher for large universal containers; proposal and risks in docs/plan_context/windows_launcher.md.
- [ ] Noted (BDFN, 2026-10-17): a rocosmo-owned Roc platform (libc-free Zig host per target) so the rocosmo command and similar apps cross-build every target from any host; a separate deliverable under INTENT's boundary.

- [ ] Real platform package: per-OS libc-free Zig host with args, environment, I/O and a size-recording allocator.
- [ ] Shared per-architecture code across OSes: analyzed in RESEARCH.md §7, not built.
- [ ] Windows ARM64 native: relay from the x64 host to an embedded arm64 PE; test on Windows 11 on Arm hardware.
- [ ] Build from Linux aarch64 and macOS x86_64 hosts (untested; no hardware used yet).
- [ ] Build rocosmo-pack and the runtimes on a Windows host (packing and building Roc apps there already work through the two containers, tests/cli/toolchain_hosts.bash, 2026-10-16).

## Last

- [ ] Optional Apple Developer ID signing of the macOS payloads on a macOS build host (ad-hoc stays the default; the app id can serve as the signing identifier).

## Recently done

