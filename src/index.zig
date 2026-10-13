//! Payload index of a zstd-layout container: where each target's bytes live
//! and how to rebuild them. Shared by the packer (encode) and the runtime
//! (decode, validate, plan), so both sides read one definition.
//!
//! Wire format, little-endian:
//!   "RCSMIDX1"  u32 count
//!   per entry:  u8 name_len, name, u8 kind, u8 ref (0xFF = none),
//!               u64 offset, u64 stored_len, u64 content_len
//! Kinds: raw (bytes stored as-is, e.g. the Windows PE body used as a free
//! reference), frame (whole zstd frame), delta (zstd frame whose reference is
//! the content of entry `ref`, which must itself be raw or a frame).

const std = @import("std");

pub const magic = "RCSMIDX1";
pub const no_ref: u8 = 0xFF;
pub const max_entries = 64;

pub const Kind = enum(u8) { raw = 0, frame = 1, delta = 2 };

pub const Entry = struct {
	name: []const u8,
	kind: Kind,
	ref: ?u8 = null,
	offset: u64,
	stored_len: u64,
	content_len: u64,
};

pub const Error = error{ BadMagic, Truncated, TrailingBytes, TooMany, BadName, BadKind, BadRef, BadSize, OutOfBounds, NoSuchTarget, OutOfMemory };

const entry_fixed = 1 + 1 + 8 + 8 + 8; // kind, ref, offset, stored_len, content_len

/// Serialize entries and prove the result decodes: the packer can never emit
/// an index the runtime would reject (bounds are checked later, against the
/// finished container).
pub fn encode(gpa: std.mem.Allocator, entries: []const Entry) Error![]u8 {
	if (entries.len > max_entries) return error.TooMany;
	for (entries) |e| if (!validName(e.name)) return error.BadName;
	const bytes = try encodeUnchecked(gpa, entries);
	errdefer gpa.free(bytes);
	const check = try decode(gpa, bytes, std.math.maxInt(u64));
	gpa.free(check);
	return bytes;
}

fn encodeUnchecked(gpa: std.mem.Allocator, entries: []const Entry) Error![]u8 {
	var out: std.ArrayList(u8) = .empty;
	errdefer out.deinit(gpa);
	try out.appendSlice(gpa, magic);
	try appendInt(&out, gpa, u32, @intCast(entries.len));
	for (entries) |e| {
		try out.append(gpa, @intCast(e.name.len));
		try out.appendSlice(gpa, e.name);
		try out.append(gpa, @intFromEnum(e.kind));
		try out.append(gpa, e.ref orelse no_ref);
		try appendInt(&out, gpa, u64, e.offset);
		try appendInt(&out, gpa, u64, e.stored_len);
		try appendInt(&out, gpa, u64, e.content_len);
	}
	return out.toOwnedSlice(gpa);
}

fn appendInt(out: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime T: type, v: T) !void {
	var b: [@sizeOf(T)]u8 = undefined;
	std.mem.writeInt(T, &b, v, .little);
	try out.appendSlice(gpa, &b);
}

/// Names are target identifiers: the same conservative alphabet as shell
/// case patterns, non-empty, at most 255 bytes.
pub fn validName(n: []const u8) bool {
	if (n.len == 0 or n.len > 255) return false;
	for (n) |c| switch (c) {
		'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
		else => return false,
	};
	return true;
}

/// Parse and fully validate an index against the container's size. Returned
/// names borrow from `bytes`.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8, container_len: u64) Error![]Entry {
	if (bytes.len < magic.len + 4) return if (bytes.len >= magic.len and !std.mem.eql(u8, bytes[0..magic.len], magic)) error.BadMagic else error.Truncated;
	if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.BadMagic;
	const count = std.mem.readInt(u32, bytes[magic.len..][0..4], .little);
	if (count > max_entries) return error.TooMany;
	const entries = try gpa.alloc(Entry, count);
	errdefer gpa.free(entries);
	var at: usize = magic.len + 4;
	for (entries) |*e| {
		if (at >= bytes.len) return error.Truncated;
		const name_len = bytes[at];
		at += 1;
		if (bytes.len - at < name_len + entry_fixed) return error.Truncated;
		const name = bytes[at..][0..name_len];
		at += name_len;
		const kind = std.enums.fromInt(Kind, bytes[at]) orelse return error.BadKind;
		const ref = bytes[at + 1];
		e.* = .{
			.name = name,
			.kind = kind,
			.ref = if (ref == no_ref) null else ref,
			.offset = std.mem.readInt(u64, bytes[at + 2 ..][0..8], .little),
			.stored_len = std.mem.readInt(u64, bytes[at + 10 ..][0..8], .little),
			.content_len = std.mem.readInt(u64, bytes[at + 18 ..][0..8], .little),
		};
		at += entry_fixed;
	}
	if (at != bytes.len) return error.TrailingBytes;
	for (entries, 0..) |e, i| {
		if (!validName(e.name)) return error.BadName;
		for (entries[0..i]) |prev| if (std.mem.eql(u8, prev.name, e.name)) return error.BadName;
		const end, const overflow = @addWithOverflow(e.offset, e.stored_len);
		if (overflow != 0 or end > container_len) return error.OutOfBounds;
		switch (e.kind) {
			.raw => {
				if (e.ref != null) return error.BadRef;
				if (e.content_len != e.stored_len) return error.BadSize;
			},
			.frame => if (e.ref != null) return error.BadRef,
			.delta => {
				const r = e.ref orelse return error.BadRef;
				if (r >= entries.len or r == i or entries[r].kind == .delta) return error.BadRef;
			},
		}
	}
	return entries;
}

pub const Plan = struct { target: Entry, reference: ?Entry };

/// What must be read and decoded to rebuild the target named `name`.
/// Expects entries that passed `decode`.
pub fn plan(entries: []const Entry, name: []const u8) Error!Plan {
	for (entries) |e| {
		if (!std.mem.eql(u8, e.name, name)) continue;
		return .{ .target = e, .reference = if (e.ref) |r| entries[r] else null };
	}
	return error.NoSuchTarget;
}
// ---------------------------------------------------------------------------
const testing = std.testing;

const sample = [_]Entry{
	.{ .name = "windows-x86_64-body", .kind = .raw, .offset = 4096, .stored_len = 3000, .content_len = 3000 },
	.{ .name = "linux-x86_64", .kind = .delta, .ref = 0, .offset = 8192, .stored_len = 100, .content_len = 9000 },
	.{ .name = "macos-arm64", .kind = .frame, .offset = 12288, .stored_len = 700, .content_len = 50000 },
	.{ .name = "linux-aarch64", .kind = .delta, .ref = 2, .offset = 16384, .stored_len = 90, .content_len = 4000 },
};
const sample_len: u64 = 16384 + 90;

fn expectEntries(want: []const Entry, got: []const Entry) !void {
	try testing.expectEqual(want.len, got.len);
	for (want, got) |w, g| {
		try testing.expectEqualStrings(w.name, g.name);
		try testing.expectEqual(w.kind, g.kind);
		try testing.expectEqual(w.ref, g.ref);
		try testing.expectEqual(w.offset, g.offset);
		try testing.expectEqual(w.stored_len, g.stored_len);
		try testing.expectEqual(w.content_len, g.content_len);
	}
}

test "decode(encode(entries)) == entries, and the encoding is canonical" {
	const bytes = try encode(testing.allocator, &sample);
	defer testing.allocator.free(bytes);
	try testing.expectEqualStrings(magic, bytes[0..8]);
	const got = try decode(testing.allocator, bytes, sample_len);
	defer testing.allocator.free(got);
	try expectEntries(&sample, got);
	const again = try encode(testing.allocator, got);
	defer testing.allocator.free(again);
	try testing.expectEqualSlices(u8, bytes, again);
}

test "plan resolves a delta's reference and a frame needs none" {
	const p = try plan(&sample, "linux-aarch64");
	try testing.expectEqualStrings("linux-aarch64", p.target.name);
	try testing.expectEqualStrings("macos-arm64", p.reference.?.name);
	const q = try plan(&sample, "macos-arm64");
	try testing.expect(q.reference == null);
	try testing.expectError(error.NoSuchTarget, plan(&sample, "plan9-mips"));
	try testing.expectError(error.NoSuchTarget, plan(&sample, "linux"));
}

/// Encode a variant of `sample` with one entry replaced.
fn variant(i: usize, e: Entry) ![]u8 {
	var v = sample;
	v[i] = e;
	return encodeUnchecked(testing.allocator, &v);
}

test "decode classifies a set of malformed indexes, each with its own error" {
	const good = try encode(testing.allocator, &sample);
	defer testing.allocator.free(good);
	const Case = struct { bytes: []const u8, len: u64 = sample_len, want: Error };
	var owned: std.ArrayList([]u8) = .empty;
	defer {
		for (owned.items) |b| testing.allocator.free(b);
		owned.deinit(testing.allocator);
	}
	const s = sample;
	const mk = struct {
		fn f(list: *std.ArrayList([]u8), i: usize, e: Entry) ![]const u8 {
			const b = try variant(i, e);
			try list.append(testing.allocator, b);
			return b;
		}
	}.f;
	var bad_magic = try testing.allocator.dupe(u8, good);
	try owned.append(testing.allocator, bad_magic);
	bad_magic[0] = 'X';
	var bad_kind = try testing.allocator.dupe(u8, good);
	try owned.append(testing.allocator, bad_kind);
	bad_kind[8 + 4 + 1 + s[0].name.len] = 7; // first entry's kind byte
	const trailing = try std.mem.concat(testing.allocator, u8, &.{ good, "x" });
	try owned.append(testing.allocator, trailing);

	const cases = [_]Case{
		.{ .bytes = bad_magic, .want = error.BadMagic },
		.{ .bytes = good[0..7], .want = error.Truncated },
		.{ .bytes = good[0 .. good.len - 1], .want = error.Truncated },
		.{ .bytes = trailing, .want = error.TrailingBytes },
		.{ .bytes = bad_kind, .want = error.BadKind },
		.{ .bytes = good, .len = sample_len - 1, .want = error.OutOfBounds },
		.{ .bytes = try mk(&owned, 1, .{ .name = "linux-x86_64", .kind = .delta, .offset = 8192, .stored_len = 100, .content_len = 9000 }), .want = error.BadRef }, // delta without ref
		.{ .bytes = try mk(&owned, 1, .{ .name = "linux-x86_64", .kind = .delta, .ref = 9, .offset = 8192, .stored_len = 100, .content_len = 9000 }), .want = error.BadRef }, // ref out of range
		.{ .bytes = try mk(&owned, 1, .{ .name = "linux-x86_64", .kind = .delta, .ref = 1, .offset = 8192, .stored_len = 100, .content_len = 9000 }), .want = error.BadRef }, // self
		.{ .bytes = try mk(&owned, 1, .{ .name = "linux-x86_64", .kind = .delta, .ref = 3, .offset = 8192, .stored_len = 100, .content_len = 9000 }), .want = error.BadRef }, // delta of a delta
		.{ .bytes = try mk(&owned, 2, .{ .name = "macos-arm64", .kind = .frame, .ref = 0, .offset = 12288, .stored_len = 700, .content_len = 50000 }), .want = error.BadRef }, // frame with ref
		.{ .bytes = try mk(&owned, 0, .{ .name = "windows-x86_64-body", .kind = .raw, .offset = 4096, .stored_len = 3000, .content_len = 2999 }), .want = error.BadSize },
		.{ .bytes = try mk(&owned, 0, .{ .name = "", .kind = .raw, .offset = 4096, .stored_len = 3000, .content_len = 3000 }), .want = error.BadName },
		.{ .bytes = try mk(&owned, 0, .{ .name = "a b", .kind = .raw, .offset = 4096, .stored_len = 3000, .content_len = 3000 }), .want = error.BadName },
		.{ .bytes = try mk(&owned, 2, .{ .name = "linux-x86_64", .kind = .frame, .offset = 12288, .stored_len = 700, .content_len = 50000 }), .want = error.BadName }, // duplicate
		.{ .bytes = try mk(&owned, 2, .{ .name = "macos-arm64", .kind = .frame, .offset = std.math.maxInt(u64) - 10, .stored_len = 700, .content_len = 50000 }), .want = error.OutOfBounds }, // overflow
	};
	for (cases, 0..) |c, k| {
		const r = decode(testing.allocator, c.bytes, c.len);
		if (r) |e| {
			testing.allocator.free(e);
			std.debug.print("case {d}: expected {t}, decoded fine\n", .{ k, c.want });
			return error.TestUnexpectedSuccess;
		} else |err| if (err != c.want) {
			std.debug.print("case {d}: expected {t}, got {t}\n", .{ k, c.want, err });
			return error.TestWrongError;
		}
	}
	const ok = try decode(testing.allocator, good, sample_len);
	testing.allocator.free(ok);
}

test "encode refuses entries the decoder would reject" {
	try testing.expectError(error.BadName, encode(testing.allocator, &.{.{ .name = "x;y", .kind = .raw, .offset = 0, .stored_len = 1, .content_len = 1 }}));
	var many: [max_entries + 1]Entry = undefined;
	for (&many, 0..) |*e, i| e.* = .{ .name = "n", .kind = .raw, .offset = i, .stored_len = 0, .content_len = 0 };
	try testing.expectError(error.TooMany, encode(testing.allocator, &many));
}
