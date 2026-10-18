# Packing other compilers

rocosmo joins one native executable per OS/CPU into a single file that runs on
all of them (and compresses the payloads). Nothing about that is specific to
Roc. These two worked examples pack other toolchains the same way.

Each build script downloads or cross-builds the inputs, then calls
`rocosmo-pack`. The measurements and runs below were recorded on a Linux x86_64
build machine, with the cross-OS runs done on an Apple-silicon Mac and a Windows
x86_64 machine.

## Zig: the compiler as one file

Zig ships one self-contained executable per platform (the Linux builds are
statically linked against musl), so no compiler is needed to make a universal
`zig`: `examples/build-zig-container` downloads the official Zig 0.16.0 release
for the five targets rocosmo covers (Windows x86_64; Linux and macOS on x86_64
and aarch64), verifies each archive's published SHA-256, and packs the five
`zig` executables.

```sh
examples/build-zig-container ./zig            # zstd level 19 by default
```

Result: a universal `zig` of **318,032,468 bytes**. Recorded runs:

| System | Command | Output |
| --- | --- | --- |
| Linux x86_64 | `./zig version` | `0.16.0` |
| macOS arm64 | `./zig version` | `0.16.0` |
| Windows x86_64 | `zig.exe version` | `0.16.0` |

It also compiles. `examples/hello.zig` built through the container exits with
code 145 (= 12*12 + 1):

```sh
ZIG_LIB_DIR=/path/to/zig/lib ./zig build-exe examples/hello.zig -femit-bin=hello
./hello; echo $?        # 145
```

One caveat, documented rather than hidden: `zig version`, `zig env` and the like
run straight from the container, but *compiling* needs Zig's `lib/` directory,
which `zig` locates next to its own executable. rocosmo runs the Linux build
from memory and the others from a per-app cache, so that directory is not beside
it; point `ZIG_LIB_DIR` at a matching `lib/` (the same one that ships in the Zig
archive). That is Zig's own requirement, not a rocosmo limitation.

## Rust: the compiler's output as one file

Rust's compiler is not a single file. `rustc` is a ~16 KB shim that dynamically
links `librustc_driver` and `libLLVM` and needs a multi-hundred-MB sysroot (the
per-target `std`), so it cannot be packed as one executable. What rocosmo can
pack is the compiler's **output**: `examples/build-rust-container` cross-compiles
the small program in `examples/rust_hello` with rustup and cargo-zigbuild (Zig as
the cross-linker) and joins the results into one universal binary.

```sh
examples/build-rust-container ./rust-hello    # zstd level 19 by default
```

This Linux-only example covers the targets that need no Apple SDK: Linux x86_64
and aarch64 (static musl) and Windows x86_64 (GNU). Result: a universal binary
of **622,440 bytes**. Recorded runs (the program prints 12*12 + 1):

| System | Command | Output |
| --- | --- | --- |
| Linux x86_64 | `./rust-hello` | `145` |
| Windows x86_64 | `rust-hello.exe` | `145` |

macOS is left out here because cross-compiling Rust to macOS needs an Apple SDK;
on a Mac you can add the two Apple slots (`--macos-x86_64`, `--macos-arm64`) the
same way and pack a five-target binary.

## Running a universal container

On Linux and macOS, `chmod +x` the file and run it. A non-shell launcher that
calls `execve` directly gets `ENOEXEC` from the `MZ` header; run it as `sh FILE`
in that case. Under WSL2, `./FILE` may start the embedded Windows build through
WSL's `MZ` handler; run `sh FILE` to get the Linux build. See
[../TECHNIQUE.md](../TECHNIQUE.md) ("Limits") for the full list.

## Tests

`tests/cli/examples_compilers.bash` (part of the top-level `./test`) is the
fast, offline check of the mechanism: it packs the dev shell's own `zig` and a
locally compiled `rust_hello` into one-slot containers and verifies that `zig`
runs and compiles from its container and that the Rust program runs from its
container. The multi-OS containers above are built on demand by the two scripts.
