# Proposal: a Windows launcher for large universal containers

Status: proposed 2026-10-16, awaiting BDFN. Nothing is built.

## Problem

The universal format starts with the app's real Windows PE, stored uncompressed, because Windows runs the file in place. For small apps that costs little. For the Roc compiler container it is 252 MB of 400 MB (RESEARCH.md §16), while the four other targets together take about 148 MB compressed.

## Idea

`rocosmo-pack` would place a small x64 PE launcher at the front instead of the app's PE, and store the real PE as a zstd frame like every other target. On Windows the launcher:

1. finds its own path (`GetModuleFileNameW`) and reads a descriptor the packer patched into it: index offset and length, the target's entry name, its content hash and the app id;
2. looks for `%LOCALAPPDATA%\rocosmo\<app id>\<hash>.exe` and, if it is missing, rebuilds it with the same small zstd decoder the POSIX runtimes use, writing a temporary file and renaming it into place;
3. starts it with `CreateProcessW`, passing `GetCommandLineW()` unchanged and inheriting the standard handles, ignores Ctrl-C itself so the child receives it, waits, and exits with the child's exit code.

The packer would copy the real PE's subsystem (console or GUI) into the launcher's header. The launcher's own PE header is relocated exactly as today.

## Expected effect

- Roc compiler container: roughly 150-200 MB instead of 400 MB (the Windows target becomes a frame or a delta; not measured).
- A native Windows on Arm path: the launcher can check `IsWow64Process2` and choose an embedded arm64 PE. That is the "Windows ARM64 relay" PLAN item.

## Costs and risks

- **Antivirus heuristics.** A program that writes an executable to the user's profile and starts it matches the "dropper" pattern that Windows Defender and SmartScreen score. Today's in-place PE avoids this entirely. It would need testing against Defender on a real host before it could be a default, and possibly an opt-in flag (`--windows-launcher`) only.
- **Behavior differences.** The app's process is a child of the launcher: process trees, job objects, `GetModuleFileName` in the app and Windows Error Reporting all see the cached copy. Signing the container would not sign the cached copy.
- **First run.** Rebuilding a 252 MB PE takes about 1.5 s with the small decoder.
- **Code.** A libc-free Zig launcher using kernel32 only, plus the existing decoder: probably 25-35 KB, which raises every universal zstd container that uses it by that much.

## Suggested decision

Build it as an opt-in `--windows-launcher` (default off) and measure Defender's reaction on the Windows test host before considering it as an automatic choice for large PEs.
