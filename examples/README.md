# Packing other compilers

rocosmo joins one native executable per OS/CPU into a single file that runs on
all of them (and compresses the payloads). Nothing about that is specific to
Roc. These two worked examples pack other toolchains the same way.

Each build script downloads or cross-builds the inputs, then calls
`rocosmo-pack`. The measurements below were taken on a Linux x86_64 build
machine on 2026-10-18. "Emulated" means the container's own runtime for that
CPU, under qemu-user, rebuilt the payload into a file that then ran under the
same qemu. The in-memory path is not used there: for a large payload it re-runs
the container through the host's `/bin/sh`, which would pick the x86_64 slot.

## Zig: the compiler as one file

Zig ships one self-contained executable per platform (the Linux builds are
statically linked against musl), so no compiler is needed to make a universal
`zig`. `examples/build-zig-container` downloads the official Zig 0.16.0 release
for all 16 slots rocosmo has, checks each archive against the SHA-256 published
in ziglang.org's download index, and packs the 16 `zig` executables together
with Zig's `lib/` (the standard library, libc headers and compiler-rt sources).

```sh
examples/build-zig-container ./zig            # zstd level 19 by default
./zig --rocosmo-platforms                     # the 16 targets it carries
./zig build-exe examples/hello.zig -femit-bin=hello && ./hello; echo $?   # 145
```

Result: a universal `zig` of **522,616,162 bytes** that compiles with no setup:
no `ZIG_LIB_DIR`, nothing to unpack beside it. The inputs are the 16 executables
(about 2.8 GB) plus `lib/` (113 MB, 19,542 files). Packing at level 19 took
10 minutes 21 seconds on a 128-core host; rocosmo-pack compresses the frames on
8 threads by default (`--jobs`).

Zig finds `lib/` by walking up from its own executable, and `lib/` is
byte-identical in all 16 official downloads. So `lib/` is packed once, as a
data tree (`rocosmo-pack --data`), and on first run the container installs it
beside the cached `zig`. The Windows `zig.exe` sits behind the launcher
(`--windows-launcher`), which installs it the same way. The tree holds files
only: the 6 empty directories of the official `lib/` are not recreated, and
none of the tests below needed them.

| System | How it ran | Result, with no `ZIG_LIB_DIR` |
| --- | --- | --- |
| Linux x86_64 | native, empty environment | `zig version` 0.16.0; compiles `hello.zig`, which exits 145 |
| macOS 26.7.1 arm64 | native (Apple Silicon) | compiles `hello.zig`, which exits 145 |
| macOS x86_64 | Rosetta 2 on Apple Silicon | compiles `hello.zig`, which exits 145 |
| Windows 10 x86_64 | native, as `zig.exe`; Microsoft Defender scan of the container and of the installed directory finds no threat | compiles `hello.zig`, which exits 145 |
| Linux aarch64, riscv64 | emulated (qemu-user) | compiles and links `hello.zig` (`-fno-lld`); it exits 145 under qemu |
| Linux arm (32-bit), powerpc64le, x86 (i386), loongarch64, s390x | emulated (qemu-user) | `zig version` 0.16.0; compiles `hello.zig` and its std imports to assembly (600,000-750,000 lines); linking not run (see below) |
| FreeBSD x86_64 and aarch64, NetBSD x86_64, OpenBSD x86_64 and aarch64 | not run from this container (see below) | |

The installed `zig` is byte-identical to the official release's on every
system checked (Linux, both macOS builds, Windows), and so is every one of the
19,542 `lib/` files.

The emulated rows stop short of linking for reasons outside rocosmo. Zig links
by running itself again as LLD, and qemu-user (without binfmt_misc
registration) cannot start that foreign child process. Zig's in-process linker
(`-fno-lld`) covers aarch64 and riscv64 but not the other five CPUs. The two
32-bit builds also need `-j1` under qemu on this 128-CPU host; with one thread
per CPU they run out of address space. The BSD rows were not run from this
container because the test VMs have 1 GB of memory. The same dispatcher and
runtimes run on those systems in the BSD VM tests (P9) and in the Rust example
below.

## Rust: the compiler's output as one file

Rust's compiler is not a single file. `rustc` is a ~16 KB shim that dynamically
links `librustc_driver` and `libLLVM` and needs a multi-hundred-MB sysroot (the
per-target `std`), so it cannot be packed as one executable. What rocosmo can
pack is the compiler's **output**: `examples/build-rust-container`
cross-compiles the small program in `examples/rust_hello` with rustup and
cargo-zigbuild (Zig as the cross-linker; NetBSD, which cargo-zigbuild does not
support, links through `zig cc -target x86_64-netbsd`) and joins the results.

It builds 11 slots on Linux: Linux on x86_64, aarch64, armv7, riscv64,
powerpc64le, i686 and loongarch64 (static musl), Windows x86_64 (GNU), FreeBSD
x86_64 and aarch64, and NetBSD x86_64. The two macOS slots need an Apple SDK, so
they are built on a Mac (`cargo build --release --target aarch64-apple-darwin`,
and `x86_64-apple-darwin`, in `examples/rust_hello`) and passed in:

```sh
examples/build-rust-container ./rust-hello \
	--macos-arm64 rust_hello-aarch64-apple-darwin --macos-x86_64 rust_hello-x86_64-apple-darwin
```

Linux s390x and OpenBSD are left out: Rust ships no prebuilt standard library
for them (tier 3). Result: a 13-slot universal binary of **1,848,998 bytes**.
The program prints 12*12 + 1:

| System | How it ran | Output |
| --- | --- | --- |
| Linux x86_64 | native | `145` |
| Linux aarch64, arm (32-bit), riscv64, powerpc64le, x86 (i386), loongarch64 | emulated (qemu-user) | `145` on each |
| macOS 26.7.1 arm64 | native (Apple Silicon) | `145` |
| macOS x86_64 | Rosetta 2 on Apple Silicon | `145` |
| Windows 10 x86_64 | native, as `rust-hello.exe`; Microsoft Defender scan finds no threat | `145` |
| FreeBSD 15.1 amd64 | KVM virtual machine (`sh rust-hello` and `./rust-hello`) | `145` |
| FreeBSD 15.1 arm64 | emulated virtual machine (QEMU, no KVM) | `145` |
| NetBSD 11.0 amd64 | KVM virtual machine | `145` |

## Running a universal container

On Linux and macOS, `chmod +x` the file and run it. `FILE --rocosmo-platforms`
lists the targets it carries. A non-shell launcher that calls `execve` directly
gets `ENOEXEC` from the `MZ` header; run it as `sh FILE` in that case. Under
WSL2, `./FILE` may start the embedded Windows build through WSL's `MZ` handler;
run `sh FILE` to get the Linux build. On macOS, a copy downloaded with a browser
runs from Terminal, but opening it from Finder shows Gatekeeper's dialog because
the file is unsigned; run it from Terminal or remove the quarantine attribute
(`xattr -d com.apple.quarantine FILE`). See [../TECHNIQUE.md](../TECHNIQUE.md)
("Limits") for the full list.

## Tests

`tests/cli/examples_compilers.bash` (part of the top-level `./test`) is the
fast, offline check of the mechanism: it packs the dev shell's own `zig` and a
locally compiled `rust_hello` into one-slot containers and verifies that `zig`
runs and compiles from its container and that the Rust program runs from its
container. `tests/cli/arch_matrix.bash` checks every Linux CPU with one
container under qemu-user. The multi-OS containers above are built on demand by
the two scripts.
