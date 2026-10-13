//! C ABI over the pure packer core. Buffers are pointer-plus-length; no NUL
//! terminators are assumed anywhere. Output is allocated by this library and
//! must be released with rocosmo_free.

const std = @import("std");
const pack = @import("pack.zig");

pub const Payload = extern struct {
	pattern: [*]const u8,
	pattern_len: usize,
	bytes: ?[*]const u8,
	bytes_len: usize,
};

pub const Status = enum(c_int) { ok = 0, not_pe = 1, unsupported_pe = 2, headers_overflow = 3, invalid_pattern = 4, out_of_memory = 5, invalid_argument = 6, invalid_name = 7, too_many_targets = 8, encode_failed = 9, unknown_target = 10 };

const gpa = std.heap.c_allocator;

/// Build a polyglot container from a Windows PE and per-OS/arch payloads.
export fn rocosmo_pack(pe: ?[*]const u8, pe_len: usize, payloads: ?[*]const Payload, count: usize, out: ?*?[*]u8, out_len: ?*usize) callconv(.c) Status {
	const o = out orelse return .invalid_argument;
	const ol = out_len orelse return .invalid_argument;
	const pe_ptr = pe orelse return .invalid_argument;
	if (count > 0 and payloads == null) return .invalid_argument;
	const list = gpa.alloc(pack.Payload, count) catch return .out_of_memory;
	defer gpa.free(list);
	for (list, 0..) |*p, i| {
		const src = payloads.?[i];
		p.* = .{ .pattern = src.pattern[0..src.pattern_len], .bytes = if (src.bytes) |b| b[0..src.bytes_len] else &.{} };
	}
	const result = pack.pack(gpa, pe_ptr[0..pe_len], list) catch |e| return switch (e) {
		error.NotPe => .not_pe,
		error.UnsupportedPe => .unsupported_pe,
		error.HeadersOverflow => .headers_overflow,
		error.InvalidPattern => .invalid_pattern,
		error.OutOfMemory => .out_of_memory,
		error.InvalidName => .invalid_name,
		error.TooManyTargets => .too_many_targets,
		error.EncodeFailed => .encode_failed,
	};
	o.* = result.ptr;
	ol.* = result.len;
	return .ok;
}

export fn rocosmo_free(ptr: ?[*]u8, len: usize) callconv(.c) void {
	if (ptr) |p| gpa.free(p[0..len]);
}

export fn rocosmo_status_message(status: c_int) callconv(.c) [*:0]const u8 {
	return switch (status) {
		0 => "ok",
		1 => "input is not a PE image",
		2 => "only PE32+ (64-bit) images are supported",
		3 => "dispatcher script and PE headers do not fit before the first section",
		4 => "payload pattern may contain only letters, digits, '_', '-', '.' and '|' separators",
		5 => "out of memory",
		7 => "target names may contain only letters, digits, '_', '-' and '.'",
		8 => "too many targets",
		9 => "zstd compression failed",
		10 => "unknown target name",
		else => "invalid argument",
	};
}
