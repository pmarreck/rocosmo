const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseFast)") orelse .ReleaseFast;
	const version = "0.1.0";

	const lib_mod = b.createModule(.{ .root_source_file = b.path("src/ffi.zig"), .target = target, .optimize = optimize, .link_libc = true });
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

	const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/pack.zig"), .target = target, .optimize = optimize }) });
	const test_step = b.step("test", "Run packer core unit tests");
	test_step.dependOn(&b.addRunArtifact(tests).step);
}
