# rocosmo

Research and a working prototype for distributing a [Roc](https://www.roc-lang.org/) program as one file that runs natively on Linux, macOS and Windows and carries both x86_64 and aarch64 code. The file can be built from Linux or macOS.

The approach borrows the polyglot header trick of Cosmopolitan's [Actually Portable Executable](https://justine.lol/ape.html). It does not use Cosmopolitan libc. Roc's own cross-compiler produces a native, libc-free executable per OS and CPU. `rocosmo-pack` then joins them:

- **Windows** loads the file as an ordinary x64 PE.
- **POSIX shells** run its header as a small `sh` dispatcher, which extracts the matching native executable to a content-addressed cache and `exec`s it.

## Status

Prototype. A probe app runs natively on Linux x86_64, macOS arm64 (Apple Silicon) and Windows x86_64 from the same bytes. The Linux aarch64 and macOS x86_64 payloads are verified only under qemu-user and Rosetta 2. Windows ARM64 runs the x64 code under Windows 11's emulator. See [RESEARCH.md](RESEARCH.md) for the full matrix, evidence and limits, and [APE_DISPATCH.md](APE_DISPATCH.md) for how the dispatch works.

## Use

```sh
nix develop
probes/p2_native_targets/build out/p2        # one native executable per target
zig build                                    # builds zig-out/bin/rocosmo-pack
zig-out/bin/rocosmo-pack \
	--windows-x86_64 out/p2/app-x64win.exe \
	--linux-x86_64 out/p2/app-x64musl --linux-aarch64 out/p2/app-arm64musl \
	--macos-x86_64 out/p2/app-x64mac --macos-arm64 out/p2/app-arm64mac \
	-o app
./app 20                                     # prints 121; rename to app.exe on Windows
```

## Test

`./test` runs the packer unit tests and probes P1–P4. Real-hardware checks read SSH host aliases from an untracked `local/hosts.env`:

```sh
ROCOSMO_MACOS_ARM64_HOST=...
ROCOSMO_WINDOWS_X64_HOST=...
ROCOSMO_WSL_X64_HOST=...
```

Missing hosts count as failures, not skips.

See [INTENT.md](INTENT.md) for scope and [PLAN.md](PLAN.md) for progress.
