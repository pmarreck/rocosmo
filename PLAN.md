# PLAN

## Initial feasibility milestone

- [ ] Research current Roc platform ABI, compiler generation, object emission and linker integration with dated primary sources and exact revisions.
- [ ] Research current official Cosmopolitan/APE releases, cross-host toolchains and known limitations, especially native macOS ARM64 build support.
- [ ] Establish a pinned flake.nix environment, using hashed official upstream Cosmopolitan downloads if nixpkgs is stale, with an explicit update procedure.
- [ ] Separate host/toolchain support from target/runtime support in a sourced OS-and-architecture matrix, including native Windows versus WSL and emulation distinctions.
- [ ] Compare platform-only integration, linker/compiler changes and alternative runtime paths, including cosmopolitan-libc necessity and licensing.
- [ ] Run small isolated feasibility probes where affordable and preserve commands, exact inputs, failures and evidence without asserting untested portability.
- [ ] Assess loader installation, executable permissions, signing, quarantine, system APIs, thread/TLS and runtime ABI constraints relevant to ordinary application distribution.
- [ ] Write a feasibility report and minimal implementation proposal, reply to the coordinating agent and stop at the research milestone.

## BDFN direction added 2026-10-13 (additive to the milestone above)

- [ ] Verify the reported cosmocc limits (macOS-inclusive builds only from Linux, only x86_64; mandatory cosmo-libc link) against current sources and the earlier cosmocc attempt in a sibling project.
- [ ] Evaluate a Roc-native polyglot container that reuses APE's dispatch tricks (MZ/shell polyglot header, per-OS/arch routing) to combine per-target Roc executables into one file.
- [ ] Evaluate building every target from every host using Roc's own cross-compilation and embedded linker instead of cosmocc.
- [ ] Evaluate removing the libc dependency (freestanding Linux, libSystem-only macOS, kernel32/ntdll-only Windows hosts).
- [ ] Include Windows x86_64 and, if possible, Windows ARM64 (assess ARM64X versus x64 emulation) as targets.
- [ ] Evaluate sharing per-architecture code across OSes with OS-specific shims to save space, including ABI differences (Windows x64, Apple arm64) and executable-page signing on Apple Silicon.
- [ ] Document APE's per-OS/arch dispatch mechanism separately (APE_DISPATCH.md) from source, with enhancements for a Roc container.

## Prototype goal (BDFN, 2026-10-13; latest OS versions only for now)

- [ ] One Roc-built file that runs natively on Linux, macOS and Windows and contains both x86_64 and aarch64 machine code.
- [ ] That file builds from Linux or macOS hosts on either x86_64 or aarch64.
- [ ] Verify on real hardware: Linux x86_64 (local), macOS arm64 test host, Windows test host and its WSL instance; label emulation separately.
