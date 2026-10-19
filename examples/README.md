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
in ziglang.org's download index, and packs the 16 `zig` executables.

```sh
examples/build-zig-container ./zig            # zstd level 19 by default
./zig --rocosmo-platforms                     # the 16 targets it carries
```

Result: a universal `zig` of **642,023,700 bytes** (the 16 inputs total about
2.8 GB). Packing at level 19 took 59 minutes on one core.

| System | How it ran | `zig version` |
| --- | --- | --- |
| Linux x86_64 | native | `0.16.0` |
| Linux aarch64, arm (32-bit), riscv64, powerpc64le, x86 (i386), loongarch64, s390x | emulated (qemu-user) | `0.16.0` on each |
| macOS 26.7.1 arm64 | native (Apple Silicon) | `0.16.0` |
| macOS x86_64 | Rosetta 2 on Apple Silicon | `0.16.0` |
| Windows 10 x86_64 | native, as `zig.exe`; Microsoft Defender scan finds no threat | `0.16.0` |
| FreeBSD x86_64 and aarch64, NetBSD x86_64, OpenBSD x86_64 and aarch64 | not run from this container (see below) | |

Every POSIX slot's payload, rebuilt from the container, is byte-identical to
the official release's `zig` for that system (15 of 15). The BSD rows were not
run from this container, because the test VMs have 1 GB of memory and the
container alone is 642 MB. The same dispatcher and runtimes run on those
systems in the BSD VM tests (P9) and in the Rust example below.

To compile, Zig needs its `lib/` directory (the standard library, libc headers
and compiler-rt sources), as the official download does: that one is `zig`
plus `lib/` in one folder. `lib/` is the same on every system; the 16 official
0.16.0 downloads hold byte-identical `lib/` trees (113 MB), so one copy serves
the universal `zig` everywhere. It has to be named with `ZIG_LIB_DIR`, though.
Zig looks for `lib/` by walking up from its own executable, and here that is
rocosmo's cached copy of the payload (at about 170 MB, the Linux build is over
the 64 MB limit for running from memory), so a `lib/` placed beside the
container or in the working directory is not found:

```sh
ZIG_LIB_DIR=/path/to/zig-0.16.0/lib ./zig build-exe examples/hello.zig -femit-bin=hello
./hello; echo $?        # 145
```

That compiled and ran on Linux x86_64 and on Windows 10 (with `ZIG_LIB_DIR`
set in PowerShell); without `ZIG_LIB_DIR` it fails with "unable to find zig
installation directory".

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
