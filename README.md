# rocosmo

Research and a working prototype for distributing a [Roc](https://www.roc-lang.org/) program as one file that runs natively on Linux, macOS and Windows and carries both x86_64 and aarch64 code. The file can be built from Linux or macOS.

The approach descends from Justine Tunney's [Actually Portable Executable](https://justine.lol/ape.html) (APE), the polyglot file format of [Cosmopolitan](https://github.com/jart/cosmopolitan), which showed that one file can be both a Windows PE and a POSIX shell script. rocosmo uses no Cosmopolitan code. Its header differs from APE's so that shells which reject NUL bytes (NetBSD `sh`, OpenBSD `ksh`) can run it too (RESEARCH.md §13). Roc's own cross-compiler produces a native, libc-free executable per OS and CPU. `rocosmo-pack` then joins them:

- **Windows** loads the file as an ordinary x64 PE.
- **POSIX shells** run its header as a small `sh` dispatcher, which extracts the matching native executable to a content-addressed cache and `exec`s it.

When a project has no Windows build, `rocosmo-pack` writes a POSIX-only container instead: a `#!/bin/sh` script with the same dispatcher and no PE, which any POSIX caller can `execve` directly (RESEARCH.md §14).

## Status

Prototype. A probe app runs natively on Linux x86_64, macOS arm64 (Apple Silicon) and Windows x86_64 from the same bytes. FreeBSD 15.1 and NetBSD 11.0 x86_64 run it in KVM virtual machines, and FreeBSD aarch64 in an emulated one. The Linux aarch64 and macOS x86_64 payloads are verified only under qemu-user and Rosetta 2. Windows ARM64 runs the x64 code under Windows 11's emulator. See [RESEARCH.md](RESEARCH.md) for the full matrix, evidence and limits, and [APE_DISPATCH.md](APE_DISPATCH.md) for how the dispatch works.

## Use

```sh
nix develop
probes/p2_native_targets/build out/p2        # one native executable per target
zig build                                    # builds zig-out/bin/rocosmo-pack
zig-out/bin/rocosmo-pack -v \
	--windows-x86_64 out/p2/app-x64win.exe \
	--linux-x86_64 out/p2/app-x64musl --linux-aarch64 out/p2/app-arm64musl \
	--macos-x86_64 out/p2/app-x64mac --macos-arm64 out/p2/app-arm64mac \
	-o app                                   # also: --freebsd-x86_64 --freebsd-aarch64 --netbsd-x86_64
./app 20                                     # prints 121; rename to app.exe on Windows
```

## Layouts

`--layout raw` stores each payload as-is; the shell copies it out with `dd`. `--layout zstd` stores each target as a zstd frame or as a delta against a same-CPU target or the Windows PE body, plus a small gzipped runtime per OS/CPU that the shell unpacks with the system `gzip` once per machine and that rebuilds the payload into the cache. The default, `--layout auto`, builds both and keeps the smaller: raw for tiny apps, zstd once payloads reach a few hundred KB. zstd sources come from the pinned `zstdz` flake input.

## App id and cache

Each container caches its payload under `<cache>/rocosmo/<app-id>/<hash>`, where `<cache>` is `$XDG_CACHE_HOME` if set, else `~/Library/Caches` on macOS and `~/.cache` elsewhere. Runtimes are shared in `<cache>/rocosmo/runtime/`. When an app installs a new payload it removes its own older entries and nothing else.

On Linux the zstd layout does not cache the payload at all. The runtime rebuilds it into a sealed `memfd` and `fexecve`s it, so only the shared runtime (about 27 KB gzipped) is ever written to disk, once per machine. Payloads over 64 MiB still go to the cache: a cached file shares page cache between runs, while a memfd copy is private memory rebuilt on every start. If the kernel refuses (no `memfd_create`, `vm.memfd_noexec=2`, a security module), the runtime re-runs the container with `ROCOSMO_NO_MEMFD=1`, which selects the cache path; users can set that variable themselves too. It is inherited by the app's child processes. The raw layout has no runtime and always uses the cache.

The app id is lowercase reverse-DNS (`org.example.tool`). `--app-id` sets it. Otherwise rocosmo-pack looks for a declaration embedded in the payloads: the literal text `ROCOSMO_APP_ID=` followed by the id and a `;`. Every payload that declares one must agree. Failing both, the id is `local.<output name>`. Declaring it from source:

- **Roc:** the app provides `app_id : Str` (for example `app_id = "ROCOSMO_APP_ID=org.example.tool;"`), and the platform exposes it to the host so the linker keeps it (see `probes/p2_native_targets`).
- **Zig:** `export const rocosmo_app_id = "ROCOSMO_APP_ID=org.example.tool;".*;`
- **Rust:** a `#[used] static` holding the same bytes. Reference it, for example from `--about`, so the linker keeps it.

## Test

`./test` runs the core unit tests and probes P2–P9 (P8, the pinterm build, is run by hand; P1, a Cosmopolitan comparison, is retired). P9 boots FreeBSD and NetBSD release images under QEMU; the first run downloads about 1.8 GB of compressed images, checks them against the published checksums and keeps only the decompressed images (6.6 GB apparent size) in `~/.cache/rocosmo-vm`; delete that folder to reclaim the space. Real-hardware checks read SSH host aliases from an untracked `local/hosts.env`:

```sh
ROCOSMO_MACOS_ARM64_HOST=...
ROCOSMO_WINDOWS_X64_HOST=...
ROCOSMO_WSL_X64_HOST=...
```

Missing hosts count as failures, not skips.

See [INTENT.md](INTENT.md) for scope and [PLAN.md](PLAN.md) for progress.

## License

rocosmo is MIT-licensed; see [LICENSE](LICENSE).

`rocosmo-pack` and every `--layout zstd` container include code from [Zstandard](https://github.com/facebook/zstd), which Meta distributes under a BSD license or GPLv2. Under the BSD terms, anyone redistributing those binaries must reproduce Zstandard's copyright notice and license in their documentation. `--layout raw` containers contain no Zstandard code.
