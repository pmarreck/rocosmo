//! Encoder half of libzstd for the packer: whole frames and `--patch-from`
//! style deltas against a raw-content reference. Frames always carry their
//! content size and a checksum so the runtime can verify a rebuild.

const std = @import("std");
const decode = @import("zstd_decode.zig");

const CCtx = opaque {};
extern fn ZSTD_createCCtx() ?*CCtx;
extern fn ZSTD_freeCCtx(*CCtx) usize;
extern fn ZSTD_CCtx_setParameter(*CCtx, c_int, c_int) usize;
extern fn ZSTD_CCtx_setPledgedSrcSize(*CCtx, c_ulonglong) usize;
extern fn ZSTD_CCtx_refPrefix(*CCtx, ?*const anyopaque, usize) usize;
extern fn ZSTD_compress2(*CCtx, ?*anyopaque, usize, ?*const anyopaque, usize) usize;
extern fn ZSTD_compressBound(usize) usize;
extern fn ZSTD_isError(usize) c_uint;

const c_compression_level = 100;
const c_window_log = 101;
const c_enable_ldm = 160;
const c_content_size_flag = 200;
const c_checksum_flag = 201;
const min_window_log = 10;
/// Above this window, enable long-distance matching, as `zstd --long` does.
const ldm_window_log = 27;

/// Compress `src` into one frame. With a `reference`, the frame is a delta
/// whose matches may point into the reference (zstd's --patch-from): the
/// window grows to cover reference plus source so far-apart copies are found.
pub fn encode(gpa: std.mem.Allocator, src: []const u8, reference: ?[]const u8, level: i32) error{ OutOfMemory, EncodeFailed }![]u8 {
	const c = ZSTD_createCCtx() orelse return error.OutOfMemory;
	defer _ = ZSTD_freeCCtx(c);
	const span = src.len + if (reference) |r| r.len else 0;
	var wlog: c_int = min_window_log;
	while (wlog < decode.window_log_max and (@as(u64, 1) << @intCast(wlog)) < span) wlog += 1;
	const params = [_][2]c_int{
		.{ c_compression_level, level },
		.{ c_window_log, wlog },
		.{ c_enable_ldm, @intFromBool(wlog > ldm_window_log) },
		.{ c_content_size_flag, 1 },
		.{ c_checksum_flag, 1 },
	};
	for (params) |p| if (ZSTD_isError(ZSTD_CCtx_setParameter(c, p[0], p[1])) != 0) return error.EncodeFailed;
	if (ZSTD_isError(ZSTD_CCtx_setPledgedSrcSize(c, src.len)) != 0) return error.EncodeFailed;
	if (reference) |r| if (ZSTD_isError(ZSTD_CCtx_refPrefix(c, r.ptr, r.len)) != 0) return error.EncodeFailed;
	const buf = try gpa.alloc(u8, ZSTD_compressBound(src.len));
	errdefer gpa.free(buf);
	const n = ZSTD_compress2(c, buf.ptr, buf.len, src.ptr, src.len);
	if (ZSTD_isError(n) != 0) return error.EncodeFailed;
	return gpa.realloc(buf, n);
}

// ---------------------------------------------------------------------------
const testing = std.testing;

/// Deterministic sample: an LCG-driven mix of repeated phrases and noise, so
/// it compresses partially, like an executable.
fn sample(gpa: std.mem.Allocator, len: usize, seed: u32) ![]u8 {
	const buf = try gpa.alloc(u8, len);
	var s: u32 = seed;
	var i: usize = 0;
	while (i < len) {
		s = s *% 1103515245 +% 12345;
		if (s >> 28 < 6) {
			const phrase = "call_function_with_frame_pointer;";
			const n = @min(phrase.len, len - i);
			@memcpy(buf[i..][0..n], phrase[0..n]);
			i += n;
		} else {
			buf[i] = @truncate(s >> 16);
			i += 1;
		}
	}
	return buf;
}

fn roundTrip(src: []const u8, reference: ?[]const u8) !usize {
	const frame = try encode(testing.allocator, src, reference, 19);
	defer testing.allocator.free(frame);
	try testing.expectEqual(@as(?u64, src.len), decode.contentSize(frame));
	const out = try testing.allocator.alloc(u8, src.len);
	defer testing.allocator.free(out);
	try decode.decode(frame, reference, out);
	try testing.expectEqualSlices(u8, src, out);
	return frame.len;
}

test "whole frames round-trip at boundary and interior sizes" {
	for ([_]usize{ 0, 1, 2, 4095, 4096, 100_000 }) |len| {
		const src = try sample(testing.allocator, len, @intCast(len + 7));
		defer testing.allocator.free(src);
		_ = try roundTrip(src, null);
	}
}

test "a delta against a similar reference round-trips and is much smaller" {
	const a = try sample(testing.allocator, 200_000, 1);
	defer testing.allocator.free(a);
	const b = try testing.allocator.dupe(u8, a);
	defer testing.allocator.free(b);
	for (0..50) |k| b[k * 3999] ^= 0x5a; // scattered edits
	const whole = try roundTrip(b, null);
	const delta = try roundTrip(b, a);
	try testing.expect(delta * 10 < whole);
}

test "a delta decoded against the wrong reference is rejected" {
	const a = try sample(testing.allocator, 50_000, 2);
	defer testing.allocator.free(a);
	const other = try sample(testing.allocator, 50_000, 3);
	defer testing.allocator.free(other);
	const b = try testing.allocator.dupe(u8, a);
	defer testing.allocator.free(b);
	b[100] ^= 1;
	const frame = try encode(testing.allocator, b, a, 19);
	defer testing.allocator.free(frame);
	const out = try testing.allocator.alloc(u8, b.len);
	defer testing.allocator.free(out);
	try testing.expectError(error.Corrupt, decode.decode(frame, other, out));
}

test "truncated or mis-sized frames are rejected" {
	const src = try sample(testing.allocator, 10_000, 4);
	defer testing.allocator.free(src);
	const frame = try encode(testing.allocator, src, null, 19);
	defer testing.allocator.free(frame);
	const out = try testing.allocator.alloc(u8, src.len);
	defer testing.allocator.free(out);
	try testing.expectError(error.Corrupt, decode.decode(frame[0 .. frame.len - 1], null, out));
	try testing.expectError(error.SizeMismatch, decode.decode(frame, null, out[0 .. out.len - 1]));
}
