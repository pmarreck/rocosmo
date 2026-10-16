//! XXH64 (xxHash, 64-bit) written for size, for the runtimes' zstd content
//! checksum: plain loops, no unrolled or vectorized paths. std.hash.XxHash64
//! compiles to about 3.7 KB in a ReleaseSmall runtime; this is a fraction.
//! Algorithm: https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md

const std = @import("std");

const p1: u64 = 0x9E3779B185EBCA87;
const p2: u64 = 0xC2B2AE3D27D4EB4F;
const p3: u64 = 0x165667B19E3779F9;
const p4: u64 = 0x85EBCA77C2B2AE63;
const p5: u64 = 0x27D4EB2F165667C5;

fn round(acc: u64, lane: u64) u64 {
	return std.math.rotl(u64, acc +% lane *% p2, 31) *% p1;
}

fn merge(acc: u64, v: u64) u64 {
	return (acc ^ round(0, v)) *% p1 +% p4;
}

fn le64(b: []const u8) u64 {
	return std.mem.readInt(u64, b[0..8], .little);
}

fn le32(b: []const u8) u64 {
	return std.mem.readInt(u32, b[0..4], .little);
}

/// XXH64 of `input` with `seed`: 32-byte stripes into four lanes, then the
/// tail in 8-, 4- and 1-byte steps, then the avalanche.
pub fn hash(seed: u64, input: []const u8) u64 {
	var b = input;
	var h: u64 = undefined;
	if (b.len >= 32) {
		var v = [4]u64{ seed +% p1 +% p2, seed +% p2, seed, seed -% p1 };
		while (b.len >= 32) : (b = b[32..]) {
			for (&v, 0..) |*lane, i| lane.* = round(lane.*, le64(b[i * 8 ..]));
		}
		h = std.math.rotl(u64, v[0], 1) +% std.math.rotl(u64, v[1], 7) +% std.math.rotl(u64, v[2], 12) +% std.math.rotl(u64, v[3], 18);
		for (v) |lane| h = merge(h, lane);
	} else {
		h = seed +% p5;
	}
	h +%= input.len;
	while (b.len >= 8) : (b = b[8..]) h = std.math.rotl(u64, h ^ round(0, le64(b)), 27) *% p1 +% p4;
	if (b.len >= 4) {
		h = std.math.rotl(u64, h ^ (le32(b) *% p1), 23) *% p2 +% p3;
		b = b[4..];
	}
	for (b) |c| h = std.math.rotl(u64, h ^ (@as(u64, c) *% p5), 11) *% p1;
	h ^= h >> 33;
	h *%= p2;
	h ^= h >> 29;
	h *%= p3;
	h ^= h >> 32;
	return h;
}

// Differential test against the standard library's implementation over every
// length 0-300 (each tail path and stripe boundary) and a few large inputs,
// with two seeds; plus the published value for the empty input.
test "matches std.hash.XxHash64" {
	try std.testing.expectEqual(@as(u64, 0xEF46DB3751D8E999), hash(0, ""));
	var buf: [70_000]u8 = undefined;
	var s: u32 = 1;
	for (&buf) |*c| {
		s = s *% 1103515245 +% 12345;
		c.* = @truncate(s >> 16);
	}
	for ([_]u64{ 0, 0x9E3779B97F4A7C15 }) |seed| {
		for (0..301) |n| try std.testing.expectEqual(std.hash.XxHash64.hash(seed, buf[0..n]), hash(seed, buf[0..n]));
		for ([_]usize{ 4096, 65_537, buf.len }) |n| try std.testing.expectEqual(std.hash.XxHash64.hash(seed, buf[0..n]), hash(seed, buf[0..n]));
	}
}
