## Pure planning for the `rocosmo` command: which Roc targets to build and how
## to call rocosmo-pack. No I/O; main.roc supplies file contents and env values.
Plan :: [].{

	## The app header's `platform "..."` source: a local path or a package URL.
	platform_ref : Str -> Try([Local(Str), Url(Str)], [NoPlatform])
	platform_ref = |app_src| {
		match Str.split_first(app_src, "platform \"") {
			Err(_) => Err(NoPlatform)
			Ok({ after, .. }) =>
				match Str.split_first(after, "\"") {
					Err(_) => Err(NoPlatform)
					Ok({ before, .. }) =>
						if Str.starts_with(before, "https://") or Str.starts_with(before, "http://") Ok(Url(before)) else Ok(Local(before))
				}
		}
	}

	## Target names a platform header declares: the keys of its `targets: { ... }`
	## record except `inputs_dir`. A byte scanner tracks brace depth and skips
	## strings and `#` comments, so nested `inputs:` keys and quoted colons never count.
	declared_targets : Str -> Try(List(Str), [NoTargetsBlock])
	declared_targets = |src| {
		match Str.split_first(src, "targets:") {
			Err(_) => Err(NoTargetsBlock)
			Ok({ after, .. }) => Ok(record_keys(after.to_utf8()))
		}
	}

	## Which rocosmo-pack slot a Roc target fills, and how strongly it is preferred
	## when two declared targets fill the same slot.
	slot_for : Str -> Try({ slot : Str, rank : U8 }, [NoSlot])
	slot_for = |t| {
		match slot_table.find_first(|e| e.target == t) {
			Ok(e) => Ok({ slot: e.slot, rank: e.rank })
			Err(_) => Err(NoSlot)
		}
	}

	## Pick one target per slot (highest rank; ties keep the first declared), in
	## rocosmo-pack's slot order. Targets with no slot, or beaten, are skipped.
	choose : List(Str) -> { builds : List({ target : Str, slot : Str }), skipped : List(Str) }
	choose = |ts| {
		builds = slot_order.fold(
			[],
			|acc, slot| {
				best = ts.fold(
					Err(NoSlot),
					|cur, t| {
						match slot_for(t) {
							Ok(e) if e.slot == slot =>
								match cur {
									Ok(c) if c.rank >= e.rank => cur
									_ => Ok({ target: t, rank: e.rank })
								}
							_ => cur
						}
					},
				)
				match best {
					Ok(b) => acc.append({ target: b.target, slot })
					Err(_) => acc
				}
			},
		)
		skipped = ts.keep_if(|t| !builds.any(|b| b.target == t))
		{ builds, skipped }
	}

	## A Windows build makes a universal (MZ/PE) container; otherwise POSIX-only.
	format : List({ target : Str, slot : Str }) -> [Universal, PosixOnly]
	format = |bs| if bs.any(|b| b.slot == "windows-x86_64") Universal else PosixOnly

	## Command-line options. Later switches override earlier ones; everything
	## after `--` is positional. Empty strings mean "not given".
	parse_args : List(Str) -> Try({ source : Str, output : Str, app_id : Str, layout : Str, verbose : Bool }, [ShowHelp, ShowAbout, Usage(Str)])
	parse_args = |args| {
		parsed = parse_from(args, { source: "", output: "", app_id: "", layout: "", verbose: Bool.False }, Bool.False)?
		if parsed.source == "" {
			Err(Usage("missing APP.roc"))
		} else if !(parsed.layout == "" or parsed.layout == "raw" or parsed.layout == "zstd" or parsed.layout == "auto") {
			Err(Usage("--layout must be raw, zstd or auto"))
		} else {
			Ok(parsed)
		}
	}

	## Default output name: the app file without `.roc`, or the folder name for main.roc.
	default_output : Str, Str -> Str
	default_output = |path, cwd_name| {
		parts = Str.split_on(path, "/")
		file = parts.last() ?? path
		if file == "main.roc" {
			parent = if parts.len() >= 2 parts.get(parts.len() - 2) ?? "" else ""
			if parent != "" and parent != "." parent else cwd_name
		} else {
			Str.drop_suffix(file, ".roc")
		}
	}

	## Folder where Roc unpacks a URL platform: <cache>/roc/packages/<hash>.
	package_dir : Str, Str, Str -> Try(Str, [BadUrl])
	package_dir = |url, xdg, home| {
		hash = Str.drop_suffix(Str.split_on(url, "/").last() ?? "", ".tar.zst")
		root = if xdg == "" "${home}/.cache" else xdg
		if hash == "" or !hash.to_utf8().all(is_ident) Err(BadUrl) else Ok("${root}/roc/packages/${hash}")
	}

	## A local platform path resolved against the app file's folder.
	local_platform : Str, Str -> Str
	local_platform = |path, rel| {
		if Str.starts_with(rel, "/") {
			rel
		} else {
			parts = Str.split_on(path, "/")
			dir = if parts.len() <= 1 "." else Str.join_with(parts.take_first(parts.len() - 1), "/")
			"${dir}/${rel}"
		}
	}

	## Where the build of one target lands inside the build folder.
	exe_path : Str, Str -> Str
	exe_path = |dir, target| {
		ext = if Str.ends_with(target, "win") or Str.ends_with(target, "mingw") ".exe" else ""
		"${dir}/app-${target}${ext}"
	}

	## `roc build` arguments for one target.
	roc_build_args : Str, Str, Str -> List(Str)
	roc_build_args = |path, dir, target| ["build", "--target=${target}", "--output=${exe_path(dir, target)}", path]

	## rocosmo-pack arguments for the chosen builds.
	pack_args : List({ target : Str, slot : Str }), Str, { output : Str, app_id : Str, layout : Str, verbose : Bool } -> List(Str)
	pack_args = |bs, dir, opts| {
		inputs = bs.fold([], |acc, b| acc.concat(["--${b.slot}", exe_path(dir, b.target)]))
		id = if opts.app_id == "" [] else ["--app-id", opts.app_id]
		layout = if opts.layout == "" [] else ["--layout", opts.layout]
		verbose = if opts.verbose ["-v"] else []
		inputs.concat(id).concat(layout).concat(verbose).concat(["-o", opts.output])
	}
}

## rocosmo-pack's slot order; the flag for each is `--<slot>`.
slot_order = ["windows-x86_64", "linux-x86_64", "linux-aarch64", "macos-x86_64", "macos-arm64", "freebsd-x86_64", "freebsd-aarch64", "netbsd-x86_64", "openbsd-x86_64", "openbsd-aarch64"]

## Roc target -> slot. Static musl beats dynamic glibc (runs on any distro);
## MSVC beats MinGW. Targets without a slot (arm64win, arm32, wasm) are skipped
## until rocosmo has a runtime for them. x64openbsd needs a platform whose host
## links OpenBSD's libc, as OpenBSD accepts system calls only from libc.
slot_table = [
	{ target: "x64musl", slot: "linux-x86_64", rank: 3 },
	{ target: "x64glibc", slot: "linux-x86_64", rank: 1 },
	{ target: "x64linux", slot: "linux-x86_64", rank: 1 },
	{ target: "arm64musl", slot: "linux-aarch64", rank: 3 },
	{ target: "arm64glibc", slot: "linux-aarch64", rank: 1 },
	{ target: "arm64linux", slot: "linux-aarch64", rank: 1 },
	{ target: "x64mac", slot: "macos-x86_64", rank: 3 },
	{ target: "arm64mac", slot: "macos-arm64", rank: 3 },
	{ target: "x64win", slot: "windows-x86_64", rank: 3 },
	{ target: "x64mingw", slot: "windows-x86_64", rank: 2 },
	{ target: "x64freebsd", slot: "freebsd-x86_64", rank: 3 },
	{ target: "x64netbsd", slot: "netbsd-x86_64", rank: 3 },
	{ target: "x64openbsd", slot: "openbsd-x86_64", rank: 3 },
]

## One argument at a time; `rest` is true after `--`.
parse_from = |args, o, rest| {
	match args {
		[] => Ok(o)
		[a, .. as tail] =>
			if rest or a == "-" or !(Str.starts_with(a, "-") or Str.starts_with(a, "/")) or (Str.starts_with(a, "/") and !is_slash_option(a)) {
				if o.source == "" parse_from(tail, { ..o, source: a }, rest) else Err(Usage("more than one APP.roc: ${a}"))
			} else if a == "--" {
				parse_from(tail, o, Bool.True)
			} else if a == "-h" or a == "--help" or a == "/?" {
				Err(ShowHelp)
			} else if a == "--about" {
				Err(ShowAbout)
			} else if a == "-v" or a == "--verbose" {
				parse_from(tail, { ..o, verbose: Bool.True }, rest)
			} else if a == "-o" or a == "/o" or a == "--output" or a == "--app-id" or a == "--layout" {
				match tail {
					[v, .. as more] => parse_from(more, set_opt(o, a, v), rest)
					[] => Err(Usage("${a} needs a value"))
				}
			} else {
				match Str.split_first(a, "=") {
					Ok({ before, after }) if before == "--output" or before == "--app-id" or before == "--layout" => parse_from(tail, set_opt(o, before, after), rest)
					_ => Err(Usage("unknown option ${a}"))
				}
			}
	}
}

## Windows-style switches; any other leading `/` is an absolute path.
is_slash_option = |a| a == "/o" or a == "/?"

set_opt = |o, name, v| {
	if name == "--app-id" {
		{ ..o, app_id: v }
	} else if name == "--layout" {
		{ ..o, layout: v }
	} else {
		{ ..o, output: v }
	}
}

is_ident = |b| (b >= 97 and b <= 122) or (b >= 65 and b <= 90) or (b >= 48 and b <= 57) or b == 95

## Keys at depth 1 of the first `{ ... }` in bytes.
record_keys : List(U8) -> List(Str)
record_keys = |bytes| {
	var $keys = []
	var $word = []
	var $depth = 0.I64
	var $i = 0
	var $mode = Code
	var $done = Bool.False
	n = bytes.len()
	while $i < n and !$done {
		b = bytes.get($i) ?? 0
		match $mode {
			Comment => if b == 10 {
				$mode = Code
			}
			Quoted => if b == 34 {
				$mode = Code
			}
			Code =>
				if b == 35 {
					$mode = Comment
				} else if b == 34 {
					$mode = Quoted
					$word = []
				} else if b == 123 {
					$depth = $depth + 1
					$word = []
				} else if b == 125 {
					$depth = $depth - 1
					$word = []
					if $depth == 0 {
						$done = Bool.True
					}
				} else if b == 58 {
					if $depth == 1 and !$word.is_empty() {
						key = Str.from_utf8($word) ?? ""
						if key != "inputs_dir" {
							$keys = $keys.append(key)
						}
					}
					$word = []
				} else if is_ident(b) {
					prev = if $i == 0 0 else bytes.get($i - 1) ?? 0
					$word = if is_ident(prev) $word.append(b) else [b]
				} else if b == 32 or b == 9 or b == 10 or b == 13 {
					{}
				} else {
					$word = []
				}
		}
		$i = $i + 1
	}
	$keys
}

basic_cli_header =
	\\platform ""
	\\	requires { main! : List(Str) => Try({}, [Exit(I32), ..]) }
	\\	exposes [Cmd]
	\\	packages {}
	\\	provides { "roc_main": main_for_host! }
	\\	targets: {
	\\		inputs_dir: "targets/",
	\\		x64mac: { inputs: ["libhost.a", app] },
	\\		# a comment with fake: { entries }
	\\		x64win: { inputs: ["host.lib", "x:y.lib", app] },
	\\		x64musl: {
	\\			inputs: ["crt1.o", "libhost.a", app, "libc.a"],
	\\			output: Exe,
	\\		},
	\\	}

expect Plan.platform_ref("app [main!] { pf: platform \"./platform/main.roc\" }") == Ok(Local("./platform/main.roc"))
expect Plan.platform_ref("app [main!] { pf: platform \"https://example.com/x/ABC.tar.zst\" }") == Ok(Url("https://example.com/x/ABC.tar.zst"))
expect Plan.platform_ref("app [main!] {}") == Err(NoPlatform)
expect Plan.declared_targets(basic_cli_header) == Ok(["x64mac", "x64win", "x64musl"])
expect Plan.declared_targets("platform \"\" requires {}") == Err(NoTargetsBlock)

expect Plan.slot_for("x64musl") == Ok({ slot: "linux-x86_64", rank: 3 })
expect Plan.slot_for("x64glibc") == Ok({ slot: "linux-x86_64", rank: 1 })
expect Plan.slot_for("arm64mac") == Ok({ slot: "macos-arm64", rank: 3 })
expect Plan.slot_for("x64win") == Ok({ slot: "windows-x86_64", rank: 3 })
expect Plan.slot_for("x64netbsd") == Ok({ slot: "netbsd-x86_64", rank: 3 })
expect Plan.slot_for("x64openbsd") == Ok({ slot: "openbsd-x86_64", rank: 3 })
expect Plan.slot_for("arm64win") == Err(NoSlot)
expect Plan.slot_for("wasm32") == Err(NoSlot)

# Every Roc target name from `roc build --help`, classified as a set.
all_roc_targets = ["x64musl", "arm64musl", "arm32musl", "x64glibc", "x64linux", "arm64linux", "arm64glibc", "arm32linux", "x64mac", "arm64mac", "x64win", "arm64win", "x64mingw", "arm64mingw", "x64freebsd", "x64openbsd", "x64netbsd", "x64elf", "wasm32"]
expect all_roc_targets.keep_if(|t| Plan.slot_for(t).is_ok()) == ["x64musl", "arm64musl", "x64glibc", "x64linux", "arm64linux", "arm64glibc", "x64mac", "arm64mac", "x64win", "x64mingw", "x64freebsd", "x64openbsd", "x64netbsd"]

expect Plan.choose(["x64glibc", "arm64mac", "x64musl", "wasm32", "x64win"]) == {
	builds: [{ target: "x64win", slot: "windows-x86_64" }, { target: "x64musl", slot: "linux-x86_64" }, { target: "arm64mac", slot: "macos-arm64" }],
	skipped: ["x64glibc", "wasm32"],
}
expect Plan.choose(["x64linux", "x64glibc"]).builds == [{ target: "x64linux", slot: "linux-x86_64" }]
expect Plan.choose([]) == { builds: [], skipped: [] }
expect Plan.format(Plan.choose(["x64musl", "x64win"]).builds) == Universal
expect Plan.format(Plan.choose(["x64musl", "arm64mac", "x64mingw"]).builds) == Universal
expect Plan.format(Plan.choose(["x64musl", "arm64mac", "arm64win"]).builds) == PosixOnly

defaults = { source: "", output: "", app_id: "", layout: "", verbose: Bool.False }
expect Plan.parse_args(["app.roc"]) == Ok({ ..defaults, source: "app.roc" })
expect Plan.parse_args(["-o", "a", "my app.roc", "--output", "b c", "--layout=zstd", "--app-id", "org.x.y", "-v"]) == Ok({ source: "my app.roc", output: "b c", app_id: "org.x.y", layout: "zstd", verbose: Bool.True })
expect Plan.parse_args(["--output=out", "--", "-weird.roc"]) == Ok({ ..defaults, source: "-weird.roc", output: "out" })
expect Plan.parse_args(["/o", "w", "x.roc"]) == Ok({ ..defaults, source: "x.roc", output: "w" })
expect Plan.parse_args(["x.roc", "-h"]) == Err(ShowHelp)
expect Plan.parse_args(["--about"]) == Err(ShowAbout)
expect Plan.parse_args([]) == Err(Usage("missing APP.roc"))
expect Plan.parse_args(["a.roc", "b.roc"]) == Err(Usage("more than one APP.roc: b.roc"))
expect Plan.parse_args(["a.roc", "-o"]) == Err(Usage("-o needs a value"))
expect Plan.parse_args(["a.roc", "--bogus"]) == Err(Usage("unknown option --bogus"))
expect Plan.parse_args(["a.roc", "--layout", "gzip"]) == Err(Usage("--layout must be raw, zstd or auto"))

expect Plan.default_output("examples/hello.roc", "proj") == "hello"
expect Plan.default_output("pinterm/main.roc", "proj") == "pinterm"
expect Plan.default_output("main.roc", "proj") == "proj"

expect Plan.package_dir("https://github.com/o/r/releases/download/0.25.0/CZsY.tar.zst", "", "/home/u") == Ok("/home/u/.cache/roc/packages/CZsY")
expect Plan.package_dir("https://x/y/H.tar.zst", "/xdg", "/home/u") == Ok("/xdg/roc/packages/H")
expect Plan.package_dir("https://x/y/", "", "/h") == Err(BadUrl)
expect Plan.package_dir("https://x/y/...tar.zst", "", "/h") == Err(BadUrl)
expect Plan.package_dir("https://x/y/a b.tar.zst", "", "/h") == Err(BadUrl)
expect Plan.parse_args(["/abs/app.roc"]) == Ok({ ..defaults, source: "/abs/app.roc" })

expect Plan.local_platform("dir/app.roc", "./platform/main.roc") == "dir/./platform/main.roc"
expect Plan.local_platform("app.roc", "platform/main.roc") == "./platform/main.roc"
expect Plan.local_platform("dir/app.roc", "/abs/main.roc") == "/abs/main.roc"

expect Plan.exe_path("b", "x64musl") == "b/app-x64musl"
expect Plan.exe_path("b", "x64win") == "b/app-x64win.exe"
expect Plan.exe_path("b", "x64mingw") == "b/app-x64mingw.exe"
expect Plan.roc_build_args("my app.roc", "b", "x64win") == ["build", "--target=x64win", "--output=b/app-x64win.exe", "my app.roc"]

expect Plan.pack_args([{ target: "x64win", slot: "windows-x86_64" }, { target: "x64musl", slot: "linux-x86_64" }], "b", { output: "out", app_id: "", layout: "", verbose: Bool.False }) == ["--windows-x86_64", "b/app-x64win.exe", "--linux-x86_64", "b/app-x64musl", "-o", "out"]
expect Plan.pack_args([{ target: "arm64mac", slot: "macos-arm64" }], "b", { output: "o", app_id: "org.a.b", layout: "zstd", verbose: Bool.True }) == ["--macos-arm64", "b/app-arm64mac", "--app-id", "org.a.b", "--layout", "zstd", "-v", "-o", "o"]
