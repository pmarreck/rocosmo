# rocosmo

Build a [Roc](https://www.roc-lang.org/) program once and get **one file** that runs natively on Linux, macOS, Windows, FreeBSD and NetBSD, on both x86_64 and aarch64.

```sh
rocosmo app.roc      # builds every target app.roc's platform declares, joins them into ./app
./app                # Linux, macOS, FreeBSD, NetBSD
app.exe              # the same file, renamed, on Windows
```

Each machine runs a real native executable, built for that OS and CPU by Roc's own cross-compiler. Nothing is interpreted or emulated, and nothing needs installing first: the file uses only tools in every base system (`sh`, `dd`, `uname` and a few others).

The packer works for any native executables, not only Roc ones. As a demonstration, `scripts/build-roc-container` turns the Roc compiler itself into one file that runs `roc` on Linux, macOS and Windows.

## How it works

The file is a Windows PE image and a POSIX shell script at the same time:

- **Windows** reads only `MZ` and a header offset at the start of the file, so it loads the file as an ordinary `.exe`.
- **POSIX shells** see a first line that reads a small dispatcher script out of the bytes Windows ignores. The dispatcher picks the executable for this OS and CPU, copies or decompresses it into a per-app cache (on Linux it can run it straight from memory instead), and `exec`s it.

Projects with no Windows build get a plain `#!/bin/sh` file with the same dispatcher.

[TECHNIQUE.md](TECHNIQUE.md) walks through both formats byte by byte. The idea comes from Justine Tunney's [Actually Portable Executable](https://justine.lol/ape.html) format in [Cosmopolitan](https://github.com/jart/cosmopolitan), which showed that one file can be both a PE and a shell script. rocosmo uses no Cosmopolitan code. Its header differs so that shells which reject NUL bytes (NetBSD `sh`, OpenBSD `ksh`) can run it, and it gives each OS its own native executable instead of one image per CPU with a runtime OS layer. [APE_DISPATCH.md](APE_DISPATCH.md) compares the two designs.

## Where it runs

| OS | CPU | How it was verified |
| --- | --- | --- |
| Linux | x86_64 | native, six shells (`dash`, `bash`, `zsh`, `busybox sh`, `oksh`, `mksh`), and WSL2 |
| Linux | aarch64 | runtime and payload under qemu-user; no aarch64 Linux hardware tested |
| macOS | arm64 (Apple Silicon) | native hardware |
| macOS | x86_64 | Rosetta 2 on Apple Silicon |
| Windows | x86_64 | native hardware |
| Windows | arm64 | not tested; Windows 11 on Arm runs the x86_64 image under its x64 emulation |
| FreeBSD 15.1 | x86_64, aarch64 | virtual machines (KVM; emulated for aarch64) |
| NetBSD 11.0 | x86_64 | KVM virtual machine |

OpenBSD is not supported yet. [RESEARCH.md](RESEARCH.md) has the evidence, the commands and the known limits.

## Getting started

Everything builds inside the project's Nix development shell, which pins Zig, a Roc nightly and the other tools:

```sh
nix develop
zig build                                              # zig-out/bin/rocosmo-pack
roc build src/rocosmo/main.roc --output=rocosmo        # the rocosmo command
```

This works on Linux and macOS hosts; a container packed on a Mac is byte-identical to one packed on Linux from the same inputs.

### `rocosmo`: from a Roc app to one file

`rocosmo app.roc` reads the targets the app's platform declares, runs `roc build` once for each, and joins the executables with `rocosmo-pack`. If the platform declares a Windows target the result is the universal file; otherwise it is the `#!/bin/sh` one. When two declared targets fill the same slot, static Linux (musl) is preferred over glibc and Microsoft's toolchain over MinGW. Targets rocosmo cannot pack yet (Windows on Arm, OpenBSD, 32-bit ARM, WebAssembly) are reported and skipped.

```text
rocosmo [-o OUT] [--app-id ID] [--layout raw|zstd|auto] [-v] APP.roc
```

`ROC` and `ROCOSMO_PACK` choose the `roc` and `rocosmo-pack` executables. The platform has to cross-build its own targets, and if one fails `rocosmo` stops with Roc's error. basic-cli 0.25.0, for example, builds its Linux targets anywhere and its macOS targets only on a Mac, and its Windows target does not link from Linux or macOS yet.

### `rocosmo-pack`: join any native executables

```sh
rocosmo-pack -v \
	--windows-x86_64 app.exe \
	--linux-x86_64 app-x64musl --linux-aarch64 app-arm64musl \
	--macos-x86_64 app-x64mac --macos-arm64 app-arm64mac \
	-o app                       # also: --freebsd-x86_64 --freebsd-aarch64 --netbsd-x86_64
```

To get inputs to try it with, `probes/p2_native_targets/build OUTDIR` builds a small Roc test app for every target.

### The Roc compiler in one file

```sh
scripts/build-roc-container roc        # fetches the pinned nightlies and packs them into ./roc
./roc version                          # or roc.exe version on Windows
```

The result holds the pinned Roc nightly for Linux x86_64 and aarch64, macOS x86_64 and arm64, and Windows x86_64: every system the nightlies are published for. The test suite runs it natively on Linux, macOS arm64 (and under Rosetta 2) and Windows x86_64, and on each it builds an app that runs there. It is large, 400 MB at the default `--level 19` (437 MB at `--level 3`), mostly because Windows needs its 252 MB executable stored uncompressed. If you pass the file on, include Roc's `LICENSE` and `legal_details` from the nightly with it.

## Layouts

`--layout raw` stores each executable as-is; the dispatcher copies it out with `dd`. `--layout zstd` stores each one as a [Zstandard](https://github.com/facebook/zstd) frame, or as a delta against a same-CPU executable or the Windows image, plus a small runtime per OS and CPU (about 14.5 KB gzipped) that rebuilds it. The default, `--layout auto`, builds both and keeps the smaller: raw for a single small payload, zstd once the payloads add up to a few tens of KB.

On Linux the zstd layout runs the program from a sealed `memfd` instead of caching it, so only the shared runtime is ever written to disk, once per machine. Payloads over 64 MiB still go to the cache. If the kernel refuses (no `memfd_create`, `vm.memfd_noexec=2`, a security module), the runtime re-runs the file with `ROCOSMO_NO_MEMFD=1`, which selects the cache. Users can set that variable themselves too, and the app's child processes inherit it.

## App id and cache

Each container caches its executable under `<cache>/rocosmo/<app-id>/<hash>`, where `<cache>` is `$XDG_CACHE_HOME` if set, else `~/Library/Caches` on macOS and `~/.cache` elsewhere. Runtimes are shared in `<cache>/rocosmo/runtime/`. When an app installs a new version it removes its own older entries and nothing else.

The app id is lowercase reverse-DNS (`org.example.tool`). `--app-id` sets it. Otherwise rocosmo-pack looks for a declaration embedded in the executables: the literal text `ROCOSMO_APP_ID=` followed by the id and a `;`. Every executable that declares one must agree. Failing both, the id is `local.<output name>`. Declaring it from source:

- **Roc:** the app provides `app_id : Str` (for example `app_id = "ROCOSMO_APP_ID=org.example.tool;"`), and the platform exposes it to the host so the linker keeps it (see `probes/p2_native_targets`).
- **Zig:** `export const rocosmo_app_id = "ROCOSMO_APP_ID=org.example.tool;".*;`
- **Rust:** a `#[used] static` holding the same bytes. Reference it, for example from `--about`, so the linker keeps it.

## Status

A working prototype with no releases yet. The format, the packer, the runtimes and the `rocosmo` command are tested on every system in the table above. Planned work is in [PLAN.md](PLAN.md), and the project's scope is in [INTENT.md](INTENT.md).

## Tests

`./test` runs everything: unit tests, the probes, the CLI suites, and the real-hardware and virtual-machine checks. The BSD checks boot FreeBSD and NetBSD release images under QEMU. The first run downloads about 1.8 GB of compressed images, checks them against the published checksums and keeps only the decompressed images (6.6 GB apparent size) in `~/.cache/rocosmo-vm`; delete that folder to reclaim the space. Real-hardware checks read SSH host aliases from an untracked `local/hosts.env`:

```sh
ROCOSMO_MACOS_ARM64_HOST=...
ROCOSMO_WINDOWS_X64_HOST=...
ROCOSMO_WSL_X64_HOST=...
```

Missing hosts count as failures, not skips. The Roc compiler check copies its 440 MB container to the macOS and Windows hosts once per container version.

## License

rocosmo is MIT-licensed; see [LICENSE](LICENSE).

`rocosmo-pack` and every `--layout zstd` container include code from [Zstandard](https://github.com/facebook/zstd), used under its BSD license. Its BSD terms require binary redistributions to reproduce the notice, so ship [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) alongside such containers. Each zstd container also names the license URL in a comment in its dispatcher script. `--layout raw` containers contain no Zstandard code.
