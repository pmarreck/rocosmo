//! The runtimes' zstd decoder: Meta's single-file educational decoder
//! (zstd's doc/educational_decoder, wrapped by zdec_small.c) plus a content
//! checksum check (xxh64.zig), which that decoder skips. It is about a third
//! the size of space-optimized libzstd and about a third its speed
//! (RESEARCH.md §15: 4.4 ms of CPU per MB against 1.2 on x86_64). Decodes
//! whole frames and `--patch-from` deltas whose reference is a raw-content
//! prefix.
//!
//! Structural corruption is fatal: the decoder calls rocosmo_zdec_fail(),
//! which the runtime defines to report and exit. Errors returned here are the
//! ones found before or after decoding (size, trailing bytes, checksum).

const std = @import("std");
const xxh64 = @import("xxh64.zig");

extern fn rocosmo_zdec(dst: [*]u8, dst_len: usize, src: [*]const u8, src_len: usize, ref: ?[*]const u8, ref_len: usize) usize;
extern fn rocosmo_zdec_content_size(src: [*]const u8, src_len: usize) u64;

pub const DecodeError = error{ Corrupt, NoContentSize, SizeMismatch, OutOfMemory };

const unknown_size = std.math.maxInt(u64);
const frame_header_descriptor = 4;
const checksum_flag = 1 << 2;
const checksum_len = 4;

/// Decompressed size recorded in the frame header, if any.
pub fn contentSize(frame: []const u8) ?u64 {
	if (frame.len < frame_header_descriptor + 1) return null;
	const s = rocosmo_zdec_content_size(frame.ptr, frame.len);
	return if (s == unknown_size) null else s;
}

/// Decode one frame into `out`, which must be exactly its content size. The
/// frame must carry a content checksum (rocosmo-pack always writes one) and
/// end exactly at `frame.len`; a wrong reference fails the checksum.
pub fn decode(frame: []const u8, reference: ?[]const u8, out: []u8) DecodeError!void {
	const want = contentSize(frame) orelse return error.NoContentSize;
	if (want != out.len) return error.SizeMismatch;
	if (frame[frame_header_descriptor] & checksum_flag == 0) return error.Corrupt;
	const r = reference orelse &[_]u8{};
	const n = rocosmo_zdec(out.ptr, out.len, frame.ptr, frame.len, if (reference != null) r.ptr else null, r.len);
	if (n == unknown_size) return error.Corrupt; // trailing bytes after the frame
	if (n != out.len) return error.SizeMismatch;
	const stored = std.mem.readInt(u32, frame[frame.len - checksum_len ..][0..checksum_len], .little);
	if (@as(u32, @truncate(xxh64.hash(0, out))) != stored) return error.Corrupt;
}

// ---------------------------------------------------------------------------
// Differential tests: frames from the packer's libzstd encoder must decode
// to the same bytes here as the source.

const testing = std.testing;
const encode = @import("zstd_encode.zig").encode;

fn sample(len: usize, seed: u32) ![]u8 {
	const buf = try testing.allocator.alloc(u8, len);
	var s: u32 = seed;
	for (buf, 0..) |*c, i| {
		s = s *% 1103515245 +% 12345;
		c.* = if (s >> 29 < 5) "call_function_with_frame_pointer;"[i % 33] else @truncate(s >> 16);
	}
	return buf;
}

fn roundTrip(src: []const u8, reference: ?[]const u8, level: i32) !void {
	const frame = try encode(testing.allocator, src, reference, level);
	defer testing.allocator.free(frame);
	try testing.expectEqual(@as(?u64, src.len), contentSize(frame));
	const out = try testing.allocator.alloc(u8, src.len);
	defer testing.allocator.free(out);
	try decode(frame, reference, out);
	try testing.expectEqualSlices(u8, src, out);
}

test "small decoder matches libzstd's input across sizes and levels" {
	for ([_]usize{ 0, 1, 2, 4095, 131_072, 131_073, 600_000 }) |len| {
		const src = try sample(len, @intCast(len + 7));
		defer testing.allocator.free(src);
		for ([_]i32{ 1, 3, 19 }) |level| try roundTrip(src, null, level);
	}
}

test "small decoder rebuilds deltas against their reference" {
	const a = try sample(400_000, 1);
	defer testing.allocator.free(a);
	const b = try testing.allocator.dupe(u8, a);
	defer testing.allocator.free(b);
	for (0..80) |k| b[k * 4999] ^= 0x5a;
	try roundTrip(b, a, 19);
	try roundTrip(b[1000..], a, 3); // matches reach across the prefix boundary
}

test "small decoder rejects a wrong reference, a wrong size, a missing checksum and trailing bytes" {
	const a = try sample(50_000, 2);
	defer testing.allocator.free(a);
	const other = try sample(50_000, 3);
	defer testing.allocator.free(other);
	const b = try testing.allocator.dupe(u8, a);
	defer testing.allocator.free(b);
	b[100] ^= 1;
	const frame = try encode(testing.allocator, b, a, 19);
	defer testing.allocator.free(frame);
	const out = try testing.allocator.alloc(u8, b.len);
	defer testing.allocator.free(out);
	try testing.expectError(error.Corrupt, decode(frame, other, out));
	try testing.expectError(error.SizeMismatch, decode(frame, a, out[0 .. out.len - 1]));
	const no_sum = try testing.allocator.dupe(u8, frame);
	defer testing.allocator.free(no_sum);
	no_sum[frame_header_descriptor] &= ~@as(u8, checksum_flag);
	try testing.expectError(error.Corrupt, decode(no_sum, a, out));
	const longer = try std.mem.concat(testing.allocator, u8, &.{ frame, "x" });
	defer testing.allocator.free(longer);
	try testing.expectError(error.Corrupt, decode(longer, a, out));
	try testing.expectEqual(@as(?u64, null), contentSize("\x28\xb5"));
	try testing.expectEqual(@as(?u64, null), contentSize("not a zstd frame"));
}
