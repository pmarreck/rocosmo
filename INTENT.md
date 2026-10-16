# rocosmo

## Purpose

Investigate a Roc platform and associated build toolchain that produce Actually Portable Executable (APE)-style applications across operating systems and CPU architectures, while also allowing builds FROM those platforms. The primary deliverable is sourced feasibility research, not an immediate production compiler or runtime rewrite.

Intended users are Roc application and platform developers who want simpler cross-platform distribution without a Linux-only build requirement.

## Requested outcomes

- Explain whether this can be implemented as a Roc platform alone, needs linker/build integration, or requires compiler/backend changes.
- Map build hosts separately from execution targets. Initial priority is macOS ARM64, Linux x86_64/ARM64, and Windows x86_64/ARM64; survey additional APE targets without claiming that these five exhaust "all platforms."
- Investigate native builds and cross-builds originating on Apple Silicon, specifically the reported historical inability to cross-compile from macOS ARM64.
- Explain what a single artifact can actually contain and execute, distinguishing OS portability, instruction-set portability, native execution, bundled loaders, extraction, and emulation.
- Determine whether cosmopolitan-libc remains necessary and what alternatives would cost.
- Provide evidence-backed options, minimal experiments, blockers, and a recommendation for a later implementation phase.

## Constraints

Research current Roc and Cosmopolitan/APE sources. Record exact versions, revisions, dates, commands and observed results. Treat historical limitations as claims to verify, not facts to repeat. Distinguish the new Roc compiler from the historical Rust compiler and distinguish a Roc runtime platform from a compiler target.

Use flake.nix-controlled dependencies and experiments. The owner explicitly permits direct upstream Cosmopolitan downloads from Jart's official distribution when nixpkgs is outdated. Discover the latest suitable upstream version, then pin its immutable source or release URL, revision/version and content hash; never make an ordinary build silently select "latest." Explain how to update the pin. Native Windows may need an alternative reproducible entry point or WSL; distinguish those paths honestly rather than calling WSL a native Windows build.

Keep compiler experiments isolated. Do not change fleet toolchains, system configurations, or other projects. Public-facing content must exclude private machine names, paths, endpoints and credentials. No public publication or upstream contact is required for this research phase.

## Responsibility boundary

rocosmo packages what a project already builds. It never ports a project to a platform. (BDFN, 2026-10-14)

The project owns:
- its source code and its platform/host code for each OS, including any Windows-specific host;
- the set of targets it supports, as its own build declares them (for Roc, the `targets:` block of the platform header);
- its app id and, later, its signing identity.

rocosmo owns:
- the container format: header, shell dispatcher, payload cache, per-OS/CPU runtimes and the packer;
- building exactly the targets the project declares and packing them, adding none and dropping none;
- mapping a project's target names onto container slots, including choosing among duplicates for one OS/CPU;
- whatever the container format itself requires;
- proving that each container runs on every OS/CPU it claims.

## Current phase (BDFN, 2026-10-13 onward)

The research milestone below was reached (RESEARCH.md). BDFN then directed building the tool itself, and that is now the project's purpose: one file per program that runs natively on every OS and CPU the program is built for.

- The container format and `rocosmo-pack`, with no APE or Cosmopolitan dependency (2026-10-13).
- Two formats, universal (Windows PE plus shell script) and POSIX-only (`#!/bin/sh`), each with raw and zstd payload layouts; the pieces that rebuild payloads kept as small as possible (formats 2026-10-14; size goal 2026-10-15).
- The `rocosmo` command, written in Roc, which builds the targets a Roc app's platform declares and packs them (2026-10-15).
- The Roc compiler packed as one container that runs on every OS the Roc nightlies cover and builds more containers (2026-10-15).
- Publishing: an MIT license, TECHNIQUE.md and a README written for outside readers, and each finished step pushed to GitHub (2026-10-14, 2026-10-16).

Success means each container runs natively on every OS/CPU it claims, shown by `./test` on real hardware and virtual machines; an untested target stays marked untested.

## Evidence and stopping point (research phase, completed)

The initial milestone is a sourced report with a host-by-target matrix, actual versus proposed capabilities, architecture options, licensing/distribution constraints, reproducible experiment records where feasible, and a scoped implementation proposal. A bounded failed experiment with a precise cause is useful evidence; an untested target must remain marked untested. Do not claim feasibility solely because a hello-world compiler stage succeeds.

Stop after the initial report and report to the coordinating agent. This does not authorize an unbounded implementation campaign or additional agents. (Reached 2026-10-13; the current phase above replaces this stopping point. Additional agents still need BDFN's approval.)
