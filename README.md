# rocosmo

Build a [Roc](https://www.roc-lang.org/) program once and get **one file** that runs natively on Linux, macOS, Windows, FreeBSD, NetBSD and OpenBSD, on both x86_64 and aarch64.

```sh
rocosmo app.roc      # builds every target app.roc's platform declares, joins them into ./app
./app                # Linux, macOS, FreeBSD, NetBSD, OpenBSD
app.exe              # the same file, renamed, on Windows
```

Each machine runs a real native executable, built for that OS and CPU by Roc's own cross-compiler. Nothing is interpreted or emulated, and nothing needs installing first: the file uses only tools in every base system (`sh`, `dd`, `uname` and a few others).

The packer works for any native executables, not only Roc ones. `scripts/build-roc-container` turns the Roc compiler itself into one file that runs `roc` on Linux, macOS and Windows, and `scripts/build-pack-container` does the same for `rocosmo-pack`.

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
| Linux | arm (32-bit), riscv64, powerpc64le, x86 (i386), loongarch64, s390x | runtime and payload under qemu-user, from one container holding all eight Linux CPUs (`tests/cli/arch_matrix.bash`); no hardware tested |
| macOS | arm64 (Apple Silicon) | native hardware |
| macOS | x86_64 | Rosetta 2 on Apple Silicon |
| Windows | x86_64 | native hardware |
| Windows | arm64 | not tested; Windows 11 on Arm runs the x86_64 image under its x64 emulation |
| FreeBSD 15.1 | x86_64, aarch64 | virtual machines (KVM; emulated for aarch64) |
| NetBSD 11.0 | x86_64 | KVM virtual machine |
| OpenBSD 7.9 | x86_64, aarch64 | virtual machines (KVM; emulated for aarch64), installed unattended from the official miniroots |

[RESEARCH.md](RESEARCH.md) has the evidence, the commands and the known limits.

## Getting started

Everything builds inside the project's Nix development shell, which pins Zig, a Roc nightly and the other tools:

```sh
nix develop
zig build                                              # zig-out/bin/rocosmo-pack
roc build src/rocosmo/main.roc --output=rocosmo        # the rocosmo command
```

This works on Linux and macOS hosts; a container packed on a Mac is byte-identical to one packed on Linux from the same inputs.

### `rocosmo`: from a Roc app to one file

`rocosmo app.roc` reads the targets the app's platform declares, runs `roc build` once for each, and joins the executables with `rocosmo-pack`. If the platform declares a Windows target the result is the universal file; otherwise it is the `#!/bin/sh` one. When two declared targets fill the same slot, static Linux (musl) is preferred over glibc and Microsoft's toolchain over MinGW. Targets rocosmo cannot pack yet (Windows on Arm, 32-bit ARM, WebAssembly) are reported and skipped. Roc's `x64openbsd` target needs a platform whose host links OpenBSD's libc, because OpenBSD accepts system calls only from libc; the test platform in `probes/p2_native_targets` does, and its output runs on OpenBSD 7.9. Roc has no arm64 OpenBSD target.

```text
rocosmo [-o OUT] [--app-id ID] [--layout raw|zstd|auto] [--no-cache] [--windows-launcher] [-v] APP.roc
```

`ROC` and `ROCOSMO_PACK` choose the `roc` and `rocosmo-pack` executables. The platform has to cross-build its own targets, and if one fails `rocosmo` stops with Roc's error. basic-cli 0.25.0, for example, builds its Linux targets anywhere and its macOS targets only on a Mac, and its Windows target does not link from Linux or macOS yet.

By default `roc build` uses Roc's build cache, which makes repeat builds fast. A warm cache can change the output bytes, though: with the same Roc nightly, a Linux x86_64 build of the test app is 10,128 bytes from an empty cache and 10,096 bytes from a warm one (RESEARCH.md §17). `--no-cache` passes `--no-cache` to every `roc build`, so the container does not depend on what that machine built before, at the cost of a full compile per target. `--cache` restores the default; the later switch wins.

### `rocosmo-pack`: join any native executables

```sh
rocosmo-pack -v \
	--windows-x86_64 app.exe \
	--linux-x86_64 app-x64musl --linux-aarch64 app-arm64musl \
	--macos-x86_64 app-x64mac --macos-arm64 app-arm64mac \
	-o app                       # rocosmo-pack --help lists every target flag
```

To get inputs to try it with, `probes/p2_native_targets/build OUTDIR` builds a small Roc test app for every target.

A container lists the targets it carries when its only argument is `--rocosmo-platforms`. It extracts and runs nothing:

```text
$ sh app --rocosmo-platforms
windows-x86_64
linux-x86_64       Linux-x86_64|Linux-amd64
linux-riscv64      Linux-riscv64
macos-arm64        Darwin-arm64|Darwin-aarch64
```

The second column is the `uname -s`-`uname -m` pattern that selects each target. The shell dispatcher answers the flag, so on Windows, where the file runs as the app's own PE, the flag goes to the app. In any other position it also goes to the app. In the universal format the dispatcher has to fit in the space before the PE's first section; with a PE whose first section is at 0x1000 and that has up to seven sections (`zig.exe`, for example), every target in the table fits, with no room for more.

`scripts/build-pack-container OUT` packs `rocosmo-pack` itself into one 1.6 MB file for all ten targets, so it runs without Nix or Zig on every system in the table above. The tests run it on Linux, macOS, Windows, FreeBSD, NetBSD and OpenBSD, and on Linux, macOS and Windows its containers are byte-identical to the ones the native build writes.

### The Roc compiler in one file

```sh
scripts/build-roc-container roc        # fetches the pinned nightlies and packs them into ./roc
./roc version                          # or roc.exe version on Windows
```

The result holds the pinned Roc nightly for Linux x86_64 and aarch64, macOS x86_64 and arm64, and Windows x86_64: every system the nightlies are published for. The test suite runs it natively on Linux, macOS arm64 (and under Rosetta 2) and Windows x86_64, and on each it builds an app that runs there. It is large, 400 MB at the default `--level 19` (437 MB at `--level 3`), mostly because Windows loads its 252 MB executable in place, so it is stored uncompressed at the front. The opt-in `--windows-launcher` layout avoids that (see below). If you pass the file on, include Roc's `LICENSE` and `legal_details` from the nightly with it.

### The Windows launcher (optional)

The universal format starts with the app's real Windows executable, stored uncompressed, because Windows maps the file in place. For a large program that is most of the file. `--windows-launcher` (on `rocosmo` and `rocosmo-pack`, off by default) stores a small launcher at the front instead and keeps the real executable as a compressed entry. On first run the launcher rebuilds that executable into `%LOCALAPPDATA%\rocosmo\<app id>\<hash>.exe` and starts it, forwarding the command line, standard handles and exit code. The launcher is a 64 KB program that imports only `KERNEL32.DLL`.

It is opt-in because it changes two things. The app then runs as a child process of the launcher, so process trees and `GetModuleFileName` see the cached copy, and the first run spends about a second rebuilding a large executable. Writing an executable to the user profile and starting it is also the shape some antivirus heuristics score as a "dropper"; on the Windows test host, Microsoft Defender (real-time protection on, current signatures) does not flag the launcher, the container or the rebuilt executable (`tests/cli/windows_launcher.bash`). Prefer the default in-place format unless the Windows image is large enough that the saving matters.

### Building without Nix

Together, the Roc container and the rocosmo-pack container are a complete toolchain on Linux, macOS and Windows. Nothing else needs installing, as long as the app's platform ships its host for every target, as P2 does. The tests do exactly that on the Windows and macOS hosts: the Roc container builds the P2 app for all five targets, the rocosmo-pack container joins them, and the resulting file runs there and back on Linux.

## Layouts

`--layout raw` stores each executable as-is; the dispatcher copies it out with `dd`. `--layout zstd` stores each one as a [Zstandard](https://github.com/facebook/zstd) frame, or as a delta against a same-CPU executable or the Windows image, plus a small runtime per OS and CPU (about 10 KB gzipped) that rebuilds it. The default, `--layout auto`, builds both and keeps the smaller: raw for a single small payload, zstd once the payloads add up to a few tens of KB.

On Linux the zstd layout runs the program from a sealed `memfd` instead of caching it, so only the shared runtime is ever written to disk, once per machine. Payloads over 64 MiB still go to the cache. If the kernel refuses (no `memfd_create`, `vm.memfd_noexec=2`, a security module), the runtime re-runs the file with `ROCOSMO_NO_MEMFD=1`, which selects the cache. Users can set that variable themselves too, and the app's child processes inherit it.

## App id and cache

Each container caches its executable under `<cache>/rocosmo/<app-id>/<hash>`, where `<cache>` is `$XDG_CACHE_HOME` if set, else `~/Library/Caches` on macOS and `~/.cache` elsewhere. Runtimes are shared in `<cache>/rocosmo/runtime/`. When an app installs a new version it removes its own older entries and nothing else.

The app id is lowercase reverse-DNS (`org.example.tool`). `--app-id` sets it. Otherwise rocosmo-pack looks for a declaration embedded in the executables: the literal text `ROCOSMO_APP_ID=` followed by the id and a `;`. Every executable that declares one must agree. Failing both, the id is `local.<output name>`. Declaring it from source:

- **Roc:** the app provides `app_id : Str` (for example `app_id = "ROCOSMO_APP_ID=org.example.tool;"`), and the platform exposes it to the host so the linker keeps it (see `probes/p2_native_targets`).
- **Zig:** `export const rocosmo_app_id = "ROCOSMO_APP_ID=org.example.tool;".*;`
- **Rust:** a `#[used] static` holding the same bytes. Reference it, for example from `--about`, so the linker keeps it.

## Examples

The technique is not specific to Roc. [examples/](examples/) packs other
toolchains the same way: the official Zig compiler becomes one universal `zig`
(318 MB) that runs and compiles on Linux, macOS and Windows, and a small Rust
program cross-built for several targets becomes one 622 KB universal binary.
Rust's own `rustc` is a shim over a large dynamically-linked sysroot, so it is
not a single-file compiler; [examples/README.md](examples/README.md) explains
what each example proves and its caveats.

## Status

A working prototype with no releases yet. The format, the packer, the runtimes and the `rocosmo` command are tested on every system in the table above. Planned work is in [PLAN.md](PLAN.md), and the project's scope is in [INTENT.md](INTENT.md).

## Tests

`./test` runs everything: unit tests, the probes, the CLI suites, and the real-hardware and virtual-machine checks. The BSD checks boot FreeBSD and NetBSD release images under QEMU. The first run downloads about 1.8 GB of compressed images, checks them against the published checksums and keeps only the decompressed images (6.6 GB apparent size) in `~/.cache/rocosmo-vm`. OpenBSD publishes no ready-to-boot image, so the first run also installs OpenBSD 7.9 for each CPU from its miniroot (5.8 MB for amd64, 45 MB for arm64). The installer downloads kernels and sets from the OpenBSD CDN (about 700 MB for amd64, 525 MB for arm64) and verifies them; the installed disks use 1.4 GB and 1.0 GB in the same folder. The arm64 install runs emulated and took about 11 minutes here. Delete that folder to reclaim the space. Building also fetches OpenBSD's `base79.tgz` and `comp79.tgz` for both CPUs once through Nix (pinned by SHA-256) and keeps only the headers and libraries the OpenBSD runtimes link against. Real-hardware checks read SSH host aliases from an untracked `local/hosts.env`:

```sh
ROCOSMO_MACOS_ARM64_HOST=...
ROCOSMO_WINDOWS_X64_HOST=...
ROCOSMO_WSL_X64_HOST=...
```

Missing hosts count as failures, not skips. The Roc compiler check copies its 440 MB container to the macOS and Windows hosts once per container version.

## License

rocosmo is MIT-licensed; see [LICENSE](LICENSE).

`rocosmo-pack` and every `--layout zstd` container include code from [Zstandard](https://github.com/facebook/zstd), used under its BSD license. Its BSD terms require binary redistributions to reproduce the notice, so ship [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) alongside such containers. Each zstd container also names the license URL in a comment in its dispatcher script. `--layout raw` containers contain no Zstandard code.
