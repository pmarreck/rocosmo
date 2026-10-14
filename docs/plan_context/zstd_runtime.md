# zstd runtime design study (BDFN, 2026-10-13 4:10 PM EDT)

Moved from PLAN.md. The study is complete; RESEARCH.md §10, §11 and §13 hold the findings.

Design under study: the unchanged MZ/sh header picks the OS and CPU and runs a small shared native runtime, cached once per machine. The runtime rebuilds the payload from zstd frames, where secondary targets are zstd `--patch-from` deltas against a reference, and then executes it. Large multi-language apps (100 MB-class Zig/Rust/Roc binaries) are in view, not only small Roc apps.

OpenBSD remains open: its kernel pins syscall call sites, so the runtime must emit an `openbsd.syscalls` section or link against an OpenBSD sysroot, and testing needs an OpenBSD host. OpenBSD has no cloud-init image, so a VM needs a serial-driven install.
