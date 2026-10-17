//! The OS/CPU targets rocosmo knows: index name, the `uname -s`-`uname -m`
//! case pattern that selects it, and its CPU (deltas stay within one CPU).
//! One table for the CLI flags, the zstd layout and the embedded runtimes.

const std = @import("std");
const pack = @import("pack.zig");

pub const Known = struct { name: []const u8, pattern: []const u8, arch: pack.Arch };

pub const known = [_]Known{
	.{ .name = "linux-x86_64", .pattern = "Linux-x86_64|Linux-amd64", .arch = .x86_64 },
	.{ .name = "linux-aarch64", .pattern = "Linux-aarch64|Linux-arm64", .arch = .aarch64 },
	.{ .name = "macos-x86_64", .pattern = "Darwin-x86_64", .arch = .x86_64 },
	.{ .name = "macos-arm64", .pattern = "Darwin-arm64|Darwin-aarch64", .arch = .aarch64 },
	.{ .name = "freebsd-x86_64", .pattern = "FreeBSD-amd64|FreeBSD-x86_64", .arch = .x86_64 },
	.{ .name = "freebsd-aarch64", .pattern = "FreeBSD-arm64|FreeBSD-aarch64", .arch = .aarch64 },
	.{ .name = "netbsd-x86_64", .pattern = "NetBSD-amd64|NetBSD-x86_64", .arch = .x86_64 },
	.{ .name = "openbsd-x86_64", .pattern = "OpenBSD-amd64|OpenBSD-x86_64", .arch = .x86_64 },
	.{ .name = "openbsd-aarch64", .pattern = "OpenBSD-arm64|OpenBSD-aarch64", .arch = .aarch64 },
};

pub fn find(name: []const u8) ?Known {
	for (known) |k| if (std.mem.eql(u8, k.name, name)) return k;
	return null;
}

// ---------------------------------------------------------------------------
const testing = std.testing;

/// Which known target a `uname -s`-`uname -m` string selects, by matching
/// the pattern alternatives exactly as the shell `case` does.
fn select(uname: []const u8) ?[]const u8 {
	var hit: ?[]const u8 = null;
	for (known) |k| {
		var alts = std.mem.splitScalar(u8, k.pattern, '|');
		while (alts.next()) |a| if (std.mem.eql(u8, a, uname)) {
			if (hit != null) return "AMBIGUOUS";
			hit = k.name;
		};
	}
	return hit;
}

test "uname strings classify to exactly one target or none" {
	const cases = [_]struct { []const u8, ?[]const u8 }{
		.{ "Linux-x86_64", "linux-x86_64" },
		.{ "Linux-aarch64", "linux-aarch64" },
		.{ "Linux-arm64", "linux-aarch64" },
		.{ "Darwin-x86_64", "macos-x86_64" },
		.{ "Darwin-arm64", "macos-arm64" },
		.{ "FreeBSD-amd64", "freebsd-x86_64" },
		.{ "FreeBSD-arm64", "freebsd-aarch64" },
		.{ "NetBSD-amd64", "netbsd-x86_64" },
		.{ "OpenBSD-amd64", "openbsd-x86_64" },
		.{ "OpenBSD-arm64", "openbsd-aarch64" },
		.{ "OpenBSD-aarch64", "openbsd-aarch64" },
		.{ "OpenBSD-riscv64", null },
		.{ "Linux-armv7l", null },
		.{ "Linux-riscv64", null },
		.{ "Darwin-i386", null },
		.{ "linux-x86_64", null }, // uname -s is capitalized; matching is exact
		.{ "Plan9-mips", null },
		.{ "", null },
	};
	for (cases) |c| {
		const got = select(c[0]);
		if (c[1]) |want| try testing.expectEqualStrings(want, got orelse "none") else try testing.expect(got == null);
	}
}

test "every known target has a valid, unique name and pattern, and find returns it" {
	for (known, 0..) |k, i| {
		try testing.expect(pack.validPattern(k.pattern));
		for (known[0..i]) |prev| try testing.expect(!std.mem.eql(u8, prev.name, k.name));
		const f = find(k.name) orelse return error.TestNotFound;
		try testing.expectEqualStrings(k.pattern, f.pattern);
	}
	try testing.expect(find("windows-x86_64") == null);
	try testing.expect(find("linux") == null);
	try testing.expect(find("") == null);
}
