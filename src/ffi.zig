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

pub const Status = enum(c_int) { ok = 0, not_pe = 1, unsupported_pe = 2, headers_overflow = 3, invalid_pattern = 4, out_of_memory = 5, invalid_argument = 6, invalid_name = 7, too_many_targets = 8, encode_failed = 9, unknown_target = 10, invalid_app_id = 11, conflicting_app_ids = 12 };

const gpa = std.heap.c_allocator;

/// The optional PE argument: NULL with length 0 means "no Windows target"
/// (POSIX-only format); NULL with a nonzero length is a caller error.
fn peArg(pe: ?[*]const u8, pe_len: usize) ?struct { pe: ?[]const u8 } {
	if (pe) |p| return .{ .pe = p[0..pe_len] };
	return if (pe_len == 0) .{ .pe = null } else null;
}

/// Build a polyglot container from a Windows PE and per-OS/arch payloads.
/// pe == NULL with pe_len == 0 selects the POSIX-only format (no Windows).
export fn rocosmo_pack(pe: ?[*]const u8, pe_len: usize, payloads: ?[*]const Payload, count: usize, id: ?[*]const u8, id_len: usize, out: ?*?[*]u8, out_len: ?*usize) callconv(.c) Status {
	const idp = id orelse return .invalid_argument;
	const o = out orelse return .invalid_argument;
	const ol = out_len orelse return .invalid_argument;
	const pe_slice = peArg(pe, pe_len) orelse return .invalid_argument;
	if (count > 0 and payloads == null) return .invalid_argument;
	const list = gpa.alloc(pack.Payload, count) catch return .out_of_memory;
	defer gpa.free(list);
	for (list, 0..) |*p, i| {
		const src = payloads.?[i];
		p.* = .{ .pattern = src.pattern[0..src.pattern_len], .bytes = if (src.bytes) |b| b[0..src.bytes_len] else &.{} };
	}
	const result = pack.pack(gpa, pe_slice.pe, list, idp[0..id_len]) catch |e| return switch (e) {
		error.InvalidAppId => .invalid_app_id,
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
		11 => "app id must be lowercase reverse-DNS, e.g. org.example.tool (labels of a-z, 0-9 and -)",
		12 => "payloads declare conflicting ROCOSMO_APP_ID values",
		else => "invalid argument",
	};
}

const targets = @import("targets.zig");
const runtimes = @import("runtimes");

// Every known target must ship a runtime: checked at compile time.
comptime {
	for (targets.known) |k| {
		var found = false;
		for (runtimes.all) |r| found = found or std.mem.eql(u8, r.name, k.name);
		if (!found) @compileError("no runtime built for target " ++ k.name);
	}
}

fn runtimeFor(name: []const u8) []const u8 {
	for (runtimes.all) |r| if (std.mem.eql(u8, r.name, name)) return r.gz;
	unreachable; // guarded by the comptime check above
}

pub const Target = extern struct {
	name: [*]const u8,
	name_len: usize,
	bytes: ?[*]const u8,
	bytes_len: usize,
};

/// Shell case pattern for a known target name (e.g. "linux-x86_64"), or
/// unknown_target. The pattern is static, not NUL-terminated.
export fn rocosmo_target_pattern(name: ?[*]const u8, name_len: usize, pattern: ?*[*]const u8, pattern_len: ?*usize) callconv(.c) Status {
	const np = name orelse return .invalid_argument;
	const p = pattern orelse return .invalid_argument;
	const pl = pattern_len orelse return .invalid_argument;
	const k = targets.find(np[0..name_len]) orelse return .unknown_target;
	p.* = k.pattern.ptr;
	pl.* = k.pattern.len;
	return .ok;
}

/// zstd layout: targets by known name; each gets its embedded runtime.
/// `level` is the zstd compression level (1-22).
export fn rocosmo_pack_zstd(pe: ?[*]const u8, pe_len: usize, list: ?[*]const Target, count: usize, level: c_int, id: ?[*]const u8, id_len: usize, out: ?*?[*]u8, out_len: ?*usize) callconv(.c) Status {
	const idp = id orelse return .invalid_argument;
	const o = out orelse return .invalid_argument;
	const ol = out_len orelse return .invalid_argument;
	const pe_slice = peArg(pe, pe_len) orelse return .invalid_argument;
	if (count > 0 and list == null) return .invalid_argument;
	if (level < 1 or level > 22) return .invalid_argument;
	const ts = gpa.alloc(pack.Target, count) catch return .out_of_memory;
	defer gpa.free(ts);
	for (ts, 0..) |*t, i| {
		const src = list.?[i];
		const name = src.name[0..src.name_len];
		const k = targets.find(name) orelse return .unknown_target;
		t.* = .{ .name = k.name, .pattern = k.pattern, .arch = k.arch, .bytes = if (src.bytes) |b| b[0..src.bytes_len] else &.{}, .runtime_gz = runtimeFor(k.name) };
	}
	const result = pack.packZstd(gpa, pe_slice.pe, ts, level, idp[0..id_len]) catch |e| return switch (e) {
		error.InvalidAppId => .invalid_app_id,
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

const app_id = @import("app_id.zig");

pub const Buffer = extern struct { ptr: ?[*]const u8, len: usize };

/// Resolve the cache namespace: `option` (NULL for none) beats an id that
/// every declaring payload agrees on, which beats `local.<exe_name>`.
/// `*out` is library-owned (rocosmo_free); `*source` is 0 option,
/// 1 embedded, 2 default.
export fn rocosmo_resolve_app_id(option: ?[*]const u8, option_len: usize, payloads: ?[*]const Buffer, count: usize, exe_name: ?[*]const u8, exe_len: usize, out: ?*?[*]u8, out_len: ?*usize, source: ?*c_int) callconv(.c) Status {
	const o = out orelse return .invalid_argument;
	const ol = out_len orelse return .invalid_argument;
	const src = source orelse return .invalid_argument;
	const name = exe_name orelse return .invalid_argument;
	if (count > 0 and payloads == null) return .invalid_argument;
	const list = gpa.alloc([]const u8, count) catch return .out_of_memory;
	defer gpa.free(list);
	for (list, 0..) |*b, i| b.* = if (payloads.?[i].ptr) |p| p[0..payloads.?[i].len] else &.{};
	const r = app_id.resolve(gpa, if (option) |p| p[0..option_len] else null, list, name[0..exe_len]) catch |e| return switch (e) {
		error.InvalidAppId => .invalid_app_id,
		error.ConflictingAppIds => .conflicting_app_ids,
		error.OutOfMemory => .out_of_memory,
	};
	o.* = @constCast(r.id.ptr);
	ol.* = r.id.len;
	src.* = @intFromEnum(r.source);
	return .ok;
}
