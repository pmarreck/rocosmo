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

The app id is lowercase reverse-DNS (`org.example.tool`). `--app-id` sets it. Otherwise rocosmo-pack looks for a declaration embedded in the payloads: the literal text `ROCOSMO_APP_ID=` followed by the id and a `;`. Every payload that declares one must agree. Failing both, the id is `local.<output name>`. Declaring it from source:

- **Roc:** the app provides `app_id : Str` (for example `app_id = "ROCOSMO_APP_ID=org.example.tool;"`), and the platform exposes it to the host so the linker keeps it (see `probes/p2_native_targets`).
- **Zig:** `export const rocosmo_app_id = "ROCOSMO_APP_ID=org.example.tool;".*;`
- **Rust:** a `#[used] static` holding the same bytes. Reference it, for example from `--about`, so the linker keeps it.

## Test

`./test` runs the core unit tests and probes P1–P7. Real-hardware checks read SSH host aliases from an untracked `local/hosts.env`:

```sh
ROCOSMO_MACOS_ARM64_HOST=...
ROCOSMO_WINDOWS_X64_HOST=...
ROCOSMO_WSL_X64_HOST=...
```

Missing hosts count as failures, not skips.

See [INTENT.md](INTENT.md) for scope and [PLAN.md](PLAN.md) for progress.
