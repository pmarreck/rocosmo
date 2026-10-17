//! C ABI of the runtime core (rocosmo_rt.h): index validation, rebuild
//! planning and zstd decoding, with no I/O. Linked into every per-OS/CPU
//! runtime together with the small zstd decoder (zstd_small.zig).

const std = @import("std");
const index = @import("index.zig");
const zdec = @import("zstd_small.zig");

/// C malloc/free: from the C library, or from nolibc_linux.c in the libc-free
/// Linux runtimes (where std.heap.c_allocator is unavailable).
const heap = if (@import("builtin").link_libc) std.heap.c_allocator else std.mem.Allocator{ .ptr = undefined, .vtable = &extern_malloc_vtable };

extern fn malloc(n: usize) ?[*]u8;
extern fn free(p: ?[*]u8) void;
const extern_malloc_vtable: std.mem.Allocator.VTable = .{
	.alloc = struct {
		fn f(_: *anyopaque, n: usize, a: std.mem.Alignment, _: usize) ?[*]u8 {
			return if (a.toByteUnits() <= 16) malloc(n) else null; // nolibc blocks are 16-byte aligned
		}
	}.f,
	.resize = std.mem.Allocator.noResize,
	.remap = std.mem.Allocator.noRemap,
	.free = struct {
		fn f(_: *anyopaque, m: []u8, _: std.mem.Alignment, _: usize) void {
			free(m.ptr);
		}
	}.f,
};

pub const Plan = extern struct {
	offset: u64,
	stored_len: u64,
	content_len: u64,
	kind: u32,
	ref_kind: u32,
	ref_offset: u64,
	ref_stored_len: u64,
	ref_content_len: u64,
};

pub const Status = enum(c_int) { ok = 0, bad_index = 1, no_such_target = 2, corrupt = 3, size_mismatch = 4, out_of_memory = 5, invalid_argument = 6 };

/// Validate the whole index before trusting any offset in it, then report the
/// byte ranges needed to rebuild `name` (target and, for a delta, its reference).
pub export fn rocosmo_rt_plan_target(idx: ?[*]const u8, idx_len: usize, container_len: u64, name: ?[*]const u8, name_len: usize, out: ?*Plan) callconv(.c) Status {
	const o = out orelse return .invalid_argument;
	const ip = idx orelse return .invalid_argument;
	const np = name orelse return .invalid_argument;
	const entries = index.decode(heap, ip[0..idx_len], container_len) catch |e| return if (e == error.OutOfMemory) .out_of_memory else .bad_index;
	defer heap.free(entries);
	const p = index.plan(entries, np[0..name_len]) catch return .no_such_target;
	o.* = .{
		.offset = p.target.offset,
		.stored_len = p.target.stored_len,
		.content_len = p.target.content_len,
		.kind = @intFromEnum(p.target.kind),
		.ref_kind = if (p.reference) |r| (if (r.kind == .raw) 1 else 2) else 0,
		.ref_offset = if (p.reference) |r| r.offset else 0,
		.ref_stored_len = if (p.reference) |r| r.stored_len else 0,
		.ref_content_len = if (p.reference) |r| r.content_len else 0,
	};
	return .ok;
}

pub export fn rocosmo_rt_decode(frame: ?[*]const u8, frame_len: usize, ref: ?[*]const u8, ref_len: usize, out: ?[*]u8, out_len: usize) callconv(.c) Status {
	const fp = frame orelse return .invalid_argument;
	const op: [*]u8 = out orelse if (out_len == 0) @constCast(&[_]u8{}) else return .invalid_argument;
	const r: ?[]const u8 = if (ref) |rp| rp[0..ref_len] else null;
	zdec.decode(fp[0..frame_len], r, op[0..out_len]) catch |e| return switch (e) {
		error.OutOfMemory => .out_of_memory,
		error.SizeMismatch, error.NoContentSize => .size_mismatch,
		error.Corrupt => .corrupt,
	};
	return .ok;
}

export fn rocosmo_rt_status_message(status: c_int) callconv(.c) [*:0]const u8 {
	return switch (status) {
		0 => "ok",
		1 => "container index is malformed",
		2 => "container has no payload for this target",
		3 => "payload data is corrupt or the reference does not match",
		4 => "payload size does not match the index",
		5 => "out of memory",
		else => "invalid argument",
	};
}

// ---------------------------------------------------------------------------
// End to end through the C ABI: a packed container, read back only via the
// runtime's two entry points, must yield every target's exact bytes.

const testing = std.testing;
const pack = @import("pack.zig");

fn field(text: []const u8, key: []const u8) []const u8 {
	const at = std.mem.indexOf(u8, text, key).? + key.len;
	return std.mem.sliceTo(text[at..], ' ');
}

test "runtime C API rebuilds each target of a packed container" {
	const gpa = testing.allocator;
	const pe = try pack.testPe(gpa);
	defer gpa.free(pe);
	var a: [30_000]u8 = undefined;
	for (&a, 0..) |*c, i| c.* = @truncate(i *% 7 +% (i >> 9));
	var b = a;
	b[1234] ^= 0xff;
	const ts = [_]pack.Target{
		.{ .name = "linux-x86_64", .pattern = "Linux-x86_64", .arch = .x86_64, .bytes = &a, .runtime_gz = "rt1" },
		.{ .name = "macos-x86_64", .pattern = "Darwin-x86_64", .arch = .x86_64, .bytes = &b, .runtime_gz = "rt2" },
	};
	const out = try pack.packZstd(gpa, pe, &ts, 19, "dev.rocosmo.test");
	defer gpa.free(out);
	const script = out[0..std.mem.readInt(u32, out[0x3c..][0..4], .little)];
	const x = try std.fmt.parseInt(usize, field(script, "\nx="), 10);
	const y = try std.fmt.parseInt(usize, field(script, " y="), 10);
	for (ts) |t| {
		var p: Plan = undefined;
		try testing.expectEqual(Status.ok, rocosmo_rt_plan_target(out[x..].ptr, y, out.len, t.name.ptr, t.name.len, &p));
		const ref_frame = out[p.ref_offset..][0..p.ref_stored_len];
		const ref_buf = try gpa.alloc(u8, p.ref_content_len);
		defer gpa.free(ref_buf);
		if (p.ref_kind == 2) try testing.expectEqual(Status.ok, rocosmo_rt_decode(ref_frame.ptr, ref_frame.len, null, 0, ref_buf.ptr, ref_buf.len));
		const ref: ?[]const u8 = switch (p.ref_kind) {
			0 => null,
			1 => ref_frame,
			else => ref_buf,
		};
		const buf = try gpa.alloc(u8, p.content_len);
		defer gpa.free(buf);
		const fr = out[p.offset..][0..p.stored_len];
		try testing.expectEqual(Status.ok, rocosmo_rt_decode(fr.ptr, fr.len, if (ref) |r| r.ptr else null, if (ref) |r| r.len else 0, buf.ptr, buf.len));
		try testing.expectEqualSlices(u8, t.bytes, buf);
	}
	var p: Plan = undefined;
	try testing.expectEqual(Status.no_such_target, rocosmo_rt_plan_target(out[x..].ptr, y, out.len, "plan9-mips", 10, &p));
	try testing.expectEqual(Status.bad_index, rocosmo_rt_plan_target(out[x..].ptr, y - 1, out.len, "linux-x86_64", 12, &p));
	try testing.expectEqual(Status.bad_index, rocosmo_rt_plan_target(out[x..].ptr, y, x, "linux-x86_64", 12, &p)); // container too short
}
