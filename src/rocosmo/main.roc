app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.25.0/CZsY7tYZwR3rj9kYbpaCfxki2yVAaRL8bBwMLvB2xkbA.tar.zst" }

## `rocosmo APP.roc`: build every target the app's platform declares with
## `roc build`, then join them into one container with rocosmo-pack.
## Planning is pure (Plan.roc); this file only reads files, env and runs tools.

import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stderr
import pf.Stdout
import Plan

version = "0.1.0"

usage =
	\\Usage: rocosmo [OPTIONS] APP.roc
	\\
	\\Build a Roc app for every OS/CPU target its platform declares, then join the
	\\executables into one rocosmo container. With a Windows target the file is
	\\also a Windows PE; without one it is a #!/bin/sh script.
	\\
	\\  -o, /o, --output OUT   output path (default: the app name)
	\\  --app-id ID            cache namespace, lowercase reverse-DNS
	\\  --layout raw|zstd|auto passed to rocosmo-pack (default auto)
	\\  --no-cache             pass --no-cache to every roc build, so the output
	\\                         does not depend on what Roc's cache holds
	\\  --cache                use Roc's cache (the default)
	\\  -v, --verbose          let rocosmo-pack report layout and size
	\\  -h, --help             show this help
	\\      --about            one-line description
	\\
	\\Environment: ROC (default roc), ROCOSMO_PACK (default rocosmo-pack).

main! = |raw_args| {
	args = raw_args.map(|a| OsStr.to_str_try(a) ?? "")
	match Plan.parse_args(args) {
		Err(ShowHelp) => Stdout.line!(usage)
		Err(ShowAbout) => {
			p = Env.platform!()
			Stdout.line!("rocosmo ${version}: build a Roc app into one container for every OS its platform targets (${Str.inspect(p.os)} ${Str.inspect(p.arch)})")
		}
		Err(Usage(msg)) => {
			Stderr.line!("rocosmo: ${msg}\n\n${usage}")?
			Err(Exit(2))
		}
		Ok(opts) =>
			match run!(opts) {
				Ok({}) => Ok({})
				Err(msg) => {
					Stderr.line!("rocosmo: ${msg}")?
					Err(Exit(1))
				}
			}
	}
}

env_or! = |name, fallback| Env.var_str!(OsStr.from_str(name)) ?? fallback

read_text! : Str => Try(Str, Str)
read_text! = |file| {
	match Path.read_bytes!(Path.from_os_str(OsStr.from_str(file))) {
		Ok(bytes) =>
			match Str.from_utf8(bytes) {
				Ok(text) => Ok(text)
				Err(_) => Err("${file} is not UTF-8")
			}
		Err(_) => Err("cannot read ${file}")
	}
}

## Run a tool with inherited output; a failure becomes a message.
run_tool! : Str, List(Str) => Try({}, Str)
run_tool! = |program, args| {
	match Cmd.new_str(program).args_str(args).exec_cmd!() {
		Ok({}) => Ok({})
		Err(ExecCmdFailed({ exit_code, .. })) => Err("${program} ${Str.join_with(args, " ")} exited with ${exit_code.to_str()}")
		Err(FailedToGetExitCode(_)) => Err("cannot run ${program}")
	}
}

run! = |opts| {
	roc = env_or!("ROC", "roc")
	packer = env_or!("ROCOSMO_PACK", "rocosmo-pack")
	app_src = read_text!(opts.source)?
	# Fetches a URL platform into Roc's cache and rejects a broken app early.
	run_tool!(roc, ["check", opts.source])?
	platform_file =
		match Plan.platform_ref(app_src) {
			Ok(Local(rel)) => Plan.local_platform(opts.source, rel)
			Ok(Url(url)) =>
				match Plan.package_dir(url, env_or!("XDG_CACHE_HOME", ""), env_or!("HOME", "")) {
					Ok(dir) => "${dir}/main.roc"
					Err(BadUrl) => return Err("cannot locate the platform package for ${url}")
				}
			Err(NoPlatform) => return Err("${opts.source} has no platform \"...\" in its header")
		}
	declared =
		match Plan.declared_targets(read_text!(platform_file)?) {
			Ok(ts) => ts
			Err(NoTargetsBlock) => return Err("${platform_file} declares no targets: block")
		}
	{ builds, skipped } = Plan.choose(declared)
	if builds.is_empty() {
		return Err("the platform declares no target rocosmo can pack (${Str.join_with(declared, ", ")})")
	}
	if !skipped.is_empty() {
		Stderr.line!("rocosmo: skipping ${Str.join_with(skipped, ", ")} (no slot, or a preferred target fills it)") ?? {}
	}
	cwd_name =
		match Env.cwd!() {
			Ok(p) => Str.split_on(Path.display(p), "/").last() ?? "app"
			Err(_) => "app"
		}
	output = if opts.output == "" Plan.default_output(opts.source, cwd_name) else opts.output
	tmp =
		match Env.create_temp_dir_with_prefix!("rocosmo-") {
			Ok(p) => p
			Err(_) => return Err("cannot create a build folder")
		}
	dir = Path.display(tmp)
	result = build_and_pack!(roc, packer, opts, builds, dir, output)
	_ = Path.delete_all!(tmp)
	result
}

build_and_pack! = |roc, packer, opts, builds, dir, output| {
	for b in builds {
		Stderr.line!("rocosmo: building ${b.target} -> ${b.slot}") ?? {}
		run_tool!(roc, Plan.roc_build_args(opts.source, dir, b.target, opts.no_cache))?
	}
	run_tool!(packer, Plan.pack_args(builds, dir, { output, app_id: opts.app_id, layout: opts.layout, verbose: opts.verbose }))
}
