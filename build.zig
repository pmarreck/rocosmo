const std = @import("std");

const zstd_common = [_][]const u8{ "common/entropy_common.c", "common/error_private.c", "common/fse_decompress.c", "common/xxhash.c", "common/zstd_common.c" };
const zstd_decompress = [_][]const u8{ "decompress/huf_decompress.c", "decompress/zstd_ddict.c", "decompress/zstd_decompress.c", "decompress/zstd_decompress_block.c" };
const zstd_compress = [_][]const u8{ "compress/fse_compress.c", "compress/hist.c", "compress/huf_compress.c", "compress/zstd_compress.c", "compress/zstd_compress_literals.c", "compress/zstd_compress_sequences.c", "compress/zstd_compress_superblock.c", "compress/zstd_double_fast.c", "compress/zstd_fast.c", "compress/zstd_lazy.c", "compress/zstd_ldm.c", "compress/zstd_opt.c", "compress/zstd_preSplit.c" };

/// Add zstd C sources (lib/ of the zstdz flake input) to a module. `full`
/// adds the encoder; the decode-only variant uses upstream's space-optimizing
/// switches (lib/README.md) because it ships inside every runtime.
fn addZstd(b: *std.Build, mod: *std.Build.Module, src: []const u8, full: bool) void {
	const lib: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ src, "lib" }) };
	mod.addIncludePath(lib);
	const common_flags = [_][]const u8{ "-DZSTD_LEGACY_SUPPORT=0", "-DZSTD_DISABLE_ASM", "-DZSTD_TRACE=0" };
	const small_flags = common_flags ++ [_][]const u8{ "-DHUF_FORCE_DECOMPRESS_X1", "-DZSTD_FORCE_DECOMPRESS_SEQUENCES_SHORT", "-DZSTD_NO_INLINE", "-DZSTD_STRIP_ERROR_STRINGS" };
	const flags: []const []const u8 = if (full) &common_flags else &small_flags;
	mod.addCSourceFiles(.{ .root = lib, .files = &(zstd_common ++ zstd_decompress), .flags = flags });
	if (full) mod.addCSourceFiles(.{ .root = lib, .files = &zstd_compress, .flags = flags });
}

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseFast)") orelse .ReleaseFast;
	const version = "0.1.0";
	// zstd sources come from the flake (zstdz input); nix develop exports ROCOSMO_ZSTD_SRC.
	const zstd_src = b.option([]const u8, "zstd-src", "zstd source tree (default: $ROCOSMO_ZSTD_SRC from nix develop)") orelse
		b.graph.environ_map.get("ROCOSMO_ZSTD_SRC") orelse @panic("set -Dzstd-src or run inside nix develop");

	const lib_mod = b.createModule(.{ .root_source_file = b.path("src/ffi.zig"), .target = target, .optimize = optimize, .link_libc = true });
	addZstd(b, lib_mod, zstd_src, true);
	const lib = b.addLibrary(.{ .name = "rocosmo", .root_module = lib_mod, .linkage = .static });

	const exe_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
	exe_mod.addCSourceFile(.{ .file = b.path("src/rocosmo_pack.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
	exe_mod.addIncludePath(b.path("src"));
	exe_mod.addCMacro("ROCOSMO_VERSION", "\"" ++ version ++ "\"");
	const t = target.result;
	exe_mod.addCMacro("ROCOSMO_PLATFORM", b.fmt("\"{s}-{s}\"", .{ @tagName(t.os.tag), @tagName(t.cpu.arch) }));
	exe_mod.linkLibrary(lib);
	const exe = b.addExecutable(.{ .name = "rocosmo-pack", .root_module = exe_mod });
	b.installArtifact(exe);

	const test_mod = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
	addZstd(b, test_mod, zstd_src, true);
	const tests = b.addTest(.{ .root_module = test_mod });
	const test_step = b.step("test", "Run core unit tests");
	test_step.dependOn(&b.addRunArtifact(tests).step);
}
