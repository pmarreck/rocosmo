//! Data tree: one directory of files stored once in a zstd-layout container
//! and installed beside the payload on first run, for apps that look for data
//! next to their own executable (Zig's `lib/`). Pure encode, decode and
//! validation; the packer converts a tar into this form and the runtimes walk
//! it while they write the files.
//!
//! Wire format, little-endian:
//!   "RCSMDAT1"  u32 count
//!   per entry:  u16 path_len, path, u8 flags (bit 0: executable), u64 size, bytes
//! Paths are relative, '/'-separated and portable (see validPath); entries are
//! sorted bytewise and unique, and no file path is a directory of another.

const std = @import("std");

pub const magic = "RCSMDAT1";
pub const max_entries: u32 = 1 << 20;
pub const max_path = 1024;
pub const flag_exec: u8 = 1;

pub const Entry = struct { path: []const u8, exec: bool = false, bytes: []const u8 };

pub const Error = error{ BadMagic, Truncated, TrailingBytes, TooMany, BadPath, Unsorted, PathConflict, BadFlags, UnsupportedEntry, BadTar, OutOfMemory };

/// A path is portable and confined: relative, '/'-separated, at most
/// max_path bytes, with no empty, "." or ".." component (so it cannot climb
/// out of the install directory), no control characters, and none of the
/// characters or trailing dots/spaces Windows file names cannot hold. It must
/// be valid UTF-8, since the Windows launcher converts it to UTF-16.
pub fn validPath(p: []const u8) bool {
	if (p.len == 0 or p.len > max_path or !validUtf8(p)) return false;
	var it = std.mem.splitScalar(u8, p, '/');
	while (it.next()) |c| {
		if (c.len == 0 or std.mem.eql(u8, c, ".") or std.mem.eql(u8, c, "..")) return false;
		for (c) |ch| switch (ch) {
			0...0x1f, 0x7f, '\\', ':', '<', '>', '"', '|', '?', '*' => return false,
			else => {},
		};
		if (c[c.len - 1] == '.' or c[c.len - 1] == ' ') return false;
	}
	return true;
}

/// Strict UTF-8 (no overlong forms, surrogates or code points above U+10FFFF),
/// written as a plain loop: the runtimes walk every path with it, and the
/// standard library's vectorized validator is several times larger.
fn validUtf8(s: []const u8) bool {
	var i: usize = 0;
	while (i < s.len) {
		const c = s[i];
		if (c < 0x80) {
			i += 1;
			continue;
		}
		const n: usize = if (c >= 0xC2 and c <= 0xDF) 2 else if (c >= 0xE0 and c <= 0xEF) 3 else if (c >= 0xF0 and c <= 0xF4) 4 else return false;
		if (s.len - i < n) return false;
		const c1 = s[i + 1];
		// Second-byte ranges exclude overlong forms (E0, F0), surrogates (ED)
		// and code points above U+10FFFF (F4).
		const lo: u8 = if (c == 0xE0) 0xA0 else if (c == 0xF0) 0x90 else 0x80;
		const hi: u8 = if (c == 0xED) 0x9F else if (c == 0xF4) 0x8F else 0xBF;
		if (c1 < lo or c1 > hi) return false;
		for (s[i + 2 .. i + n]) |cc| if (cc & 0xC0 != 0x80) return false;
		i += n;
	}
	return true;
}

/// Serialize sorted, unique, conflict-free entries (checked here, so the
/// packer cannot emit a tree the runtimes would refuse).
pub fn encode(gpa: std.mem.Allocator, entries: []const Entry) Error![]u8 {
	if (entries.len > max_entries) return error.TooMany;
	var files: std.StringHashMapUnmanaged(void) = .empty;
	defer files.deinit(gpa);
	var size: usize = magic.len + 4;
	for (entries, 0..) |e, i| {
		if (!validPath(e.path)) return error.BadPath;
		if (i > 0 and std.mem.order(u8, entries[i - 1].path, e.path) != .lt) return error.Unsorted;
		// No earlier file may be a directory of this one (sorted order puts
		// "a" before "a/b", so checking ancestors against earlier files suffices).
		for (e.path, 0..) |ch, j| if (ch == '/' and files.contains(e.path[0..j])) return error.PathConflict;
		try files.put(gpa, e.path, {});
		size += 2 + e.path.len + 1 + 8 + e.bytes.len;
	}
	const out = try gpa.alloc(u8, size);
	@memcpy(out[0..magic.len], magic);
	std.mem.writeInt(u32, out[magic.len..][0..4], @intCast(entries.len), .little);
	var at: usize = magic.len + 4;
	for (entries) |e| {
		std.mem.writeInt(u16, out[at..][0..2], @intCast(e.path.len), .little);
		at += 2;
		@memcpy(out[at..][0..e.path.len], e.path);
		at += e.path.len;
		out[at] = if (e.exec) flag_exec else 0;
		at += 1;
		std.mem.writeInt(u64, out[at..][0..8], e.bytes.len, .little);
		at += 8;
		@memcpy(out[at..][0..e.bytes.len], e.bytes);
		at += e.bytes.len;
	}
	std.debug.assert(at == size);
	return out;
}

/// Walks an encoded tree without allocating, validating each entry before
/// returning it: bounds, flags, path safety and order.
pub const Iterator = struct {
	bytes: []const u8,
	pos: usize,
	left: u32,
	prev: ?[]const u8 = null,

	pub fn init(bytes: []const u8) Error!Iterator {
		if (bytes.len < magic.len + 4) return if (bytes.len >= magic.len and !std.mem.eql(u8, bytes[0..magic.len], magic)) error.BadMagic else error.Truncated;
		if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.BadMagic;
		const count = std.mem.readInt(u32, bytes[magic.len..][0..4], .little);
		if (count > max_entries) return error.TooMany;
		return .{ .bytes = bytes, .pos = magic.len + 4, .left = count };
	}

	pub fn next(it: *Iterator) Error!?Entry {
		if (it.left == 0) return if (it.pos == it.bytes.len) null else error.TrailingBytes;
		const b = it.bytes;
		if (b.len - it.pos < 2) return error.Truncated;
		const plen = std.mem.readInt(u16, b[it.pos..][0..2], .little);
		it.pos += 2;
		if (b.len - it.pos < @as(usize, plen) + 1 + 8) return error.Truncated;
		const path = b[it.pos..][0..plen];
		it.pos += plen;
		const flags = b[it.pos];
		it.pos += 1;
		const size = std.mem.readInt(u64, b[it.pos..][0..8], .little);
		it.pos += 8;
		if (size > b.len - it.pos) return error.Truncated;
		if (flags & ~flag_exec != 0) return error.BadFlags;
		if (!validPath(path)) return error.BadPath;
		if (it.prev) |p| if (std.mem.order(u8, p, path) != .lt) return error.Unsorted;
		const bytes = b[it.pos..][0..@intCast(size)];
		it.pos += @intCast(size);
		it.prev = path;
		it.left -= 1;
		return .{ .path = path, .exec = flags & flag_exec != 0, .bytes = bytes };
	}
};

/// Convert a tar archive (ustar, GNU long names or pax paths) into an encoded
/// tree: regular files become entries (executable if any x bit is set),
/// directories are implied, and links or special files are refused. Leading
/// "./" is dropped and entries are sorted, so equal trees encode equally.
pub fn fromTar(gpa: std.mem.Allocator, tar: []const u8) Error![]u8 {
	var r: std.Io.Reader = .fixed(tar);
	var name_buf: [4096]u8 = undefined;
	var link_buf: [4096]u8 = undefined;
	var it: std.tar.Iterator = .init(&r, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
	var list: std.ArrayList(Entry) = .empty;
	defer {
		for (list.items) |e| gpa.free(e.path);
		list.deinit(gpa);
	}
	while (it.next() catch |e| return if (e == error.TarUnsupportedHeader) error.UnsupportedEntry else error.BadTar) |f| {
		switch (f.kind) {
			.directory => continue,
			.sym_link => return error.UnsupportedEntry,
			.file => {},
		}
		var name = f.name;
		while (std.mem.startsWith(u8, name, "./")) name = name[2..];
		if (!validPath(name)) return error.BadPath;
		const content = r.take(@intCast(f.size)) catch return error.BadTar;
		it.unread_file_bytes = 0;
		const path = try gpa.dupe(u8, name);
		list.append(gpa, .{ .path = path, .exec = f.mode & 0o111 != 0, .bytes = content }) catch |e| {
			gpa.free(path);
			return e;
		};
	}
	std.mem.sort(Entry, list.items, {}, struct {
		fn lt(_: void, a: Entry, b: Entry) bool {
			return std.mem.lessThan(u8, a.path, b.path);
		}
	}.lt);
	return encode(gpa, list.items);
}

// ---------------------------------------------------------------------------
const testing = std.testing;

fn decodeAll(gpa: std.mem.Allocator, bytes: []const u8) ![]Entry {
	var it = try Iterator.init(bytes);
	var list: std.ArrayList(Entry) = .empty;
	errdefer list.deinit(gpa);
	while (try it.next()) |e| try list.append(gpa, e);
	return list.toOwnedSlice(gpa);
}

test "validPath accepts portable relative paths and rejects every unsafe or unportable one" {
	const good = [_][]const u8{ "a", "caf\xc3\xa9/\xe6\x97\xa5.h", "lib/std/std.zig", "lib/libc/include/x86_64-linux-gnu/bits/a.h", "x-y_z.1", "a/b/c", ".hidden", "a/.b", "lib/c++/v1/__config", "a b/c", "UPPER/lower" };
	const bad = [_][]const u8{ "", "/abs", "a//b", "a/./b", "a/../b", "..", ".", "./a", "a/", "a\\b", "C:x", "a:b", "a\x00b", "a\nb", "a\x7fb", "a<b", "a>b", "a\"b", "a|b", "a?b", "a*b", "a/b.", "a/b ", "dir./x", "bad\xffutf8", "half\xc3", "\xed\xa0\x80surrogate" };
	for (good) |p| testing.expect(validPath(p)) catch |e| {
		std.debug.print("should accept: {s}\n", .{p});
		return e;
	};
	for (bad) |p| testing.expect(!validPath(p)) catch |e| {
		std.debug.print("should reject: {s}\n", .{p});
		return e;
	};
	var long: [max_path + 1]u8 = undefined;
	@memset(&long, 'a');
	try testing.expect(validPath(long[0..max_path]));
	try testing.expect(!validPath(&long));
}

test "encode then decode returns the same entries, flags and bytes" {
	const gpa = testing.allocator;
	const in = [_]Entry{
		.{ .path = "lib/a.txt", .bytes = "alpha" },
		.{ .path = "lib/bin/tool", .exec = true, .bytes = "#!x" },
		.{ .path = "lib/empty", .bytes = "" },
		.{ .path = "lib/z/deep/file", .bytes = "zz" },
	};
	const bytes = try encode(gpa, &in);
	defer gpa.free(bytes);
	try testing.expectEqualStrings(magic, bytes[0..8]);
	const out = try decodeAll(gpa, bytes);
	defer gpa.free(out);
	try testing.expectEqual(in.len, out.len);
	for (in, out) |a, b| {
		try testing.expectEqualStrings(a.path, b.path);
		try testing.expectEqual(a.exec, b.exec);
		try testing.expectEqualSlices(u8, a.bytes, b.bytes);
	}
	const empty = try encode(gpa, &.{});
	defer gpa.free(empty);
	const none = try decodeAll(gpa, empty);
	defer gpa.free(none);
	try testing.expectEqual(@as(usize, 0), none.len);
}

test "encode refuses unsorted, duplicate, conflicting and invalid paths" {
	const gpa = testing.allocator;
	try testing.expectError(error.Unsorted, encode(gpa, &.{ .{ .path = "b", .bytes = "" }, .{ .path = "a", .bytes = "" } }));
	try testing.expectError(error.Unsorted, encode(gpa, &.{ .{ .path = "a", .bytes = "" }, .{ .path = "a", .bytes = "" } }));
	try testing.expectError(error.PathConflict, encode(gpa, &.{ .{ .path = "a", .bytes = "" }, .{ .path = "a/b", .bytes = "" } }));
	try testing.expectError(error.PathConflict, encode(gpa, &.{ .{ .path = "a", .bytes = "" }, .{ .path = "a-x", .bytes = "" }, .{ .path = "a/b", .bytes = "" } }));
	try testing.expectError(error.BadPath, encode(gpa, &.{.{ .path = "../evil", .bytes = "" }}));
}

test "decode rejects bad magic, every truncation, trailing bytes, bad flags and unsafe paths" {
	const gpa = testing.allocator;
	const bytes = try encode(gpa, &.{ .{ .path = "lib/a", .bytes = "abc" }, .{ .path = "lib/b", .exec = true, .bytes = "de" } });
	defer gpa.free(bytes);
	// Every proper prefix is rejected (no partial tree is ever accepted).
	for (0..bytes.len) |n| {
		if (decodeAll(gpa, bytes[0..n])) |es| {
			gpa.free(es);
			std.debug.print("accepted a {d}-byte prefix of {d}\n", .{ n, bytes.len });
			return error.TestUnexpectedResult;
		} else |_| {}
	}
	var extra = try gpa.alloc(u8, bytes.len + 1);
	defer gpa.free(extra);
	@memcpy(extra[0..bytes.len], bytes);
	extra[bytes.len] = 0;
	try testing.expectError(error.TrailingBytes, decodeAll(gpa, extra));
	var bad = try gpa.dupe(u8, bytes);
	defer gpa.free(bad);
	bad[0] = 'X';
	try testing.expectError(error.BadMagic, decodeAll(gpa, bad));
	// First entry's flags byte: after magic, count, u16 length and the path.
	@memcpy(bad, bytes);
	bad[8 + 4 + 2 + "lib/a".len] = 2;
	try testing.expectError(error.BadFlags, decodeAll(gpa, bad));
	// A traversal path written past the encoder's checks is refused on read.
	@memcpy(bad, bytes);
	@memcpy(bad[8 + 4 + 2 ..][0..5], "../aa");
	try testing.expectError(error.BadPath, decodeAll(gpa, bad));
	// Out-of-order entries are refused on read too.
	@memcpy(bad, bytes);
	bad[8 + 4 + 2 + 4] = 'z'; // "lib/z" then "lib/b"
	try testing.expectError(error.Unsorted, decodeAll(gpa, bad));
}

fn testTar(gpa: std.mem.Allocator, comptime build: fn (*std.tar.Writer) anyerror!void) ![]u8 {
	var aw: std.Io.Writer.Allocating = .init(gpa);
	errdefer aw.deinit();
	var tw: std.tar.Writer = .{ .underlying_writer = &aw.writer };
	try build(&tw);
	try tw.finishPedantically();
	return aw.toOwnedSlice();
}

test "fromTar keeps regular files, drops directories, sorts, maps the exec bit and strips ./" {
	const gpa = testing.allocator;
	const tar = try testTar(gpa, struct {
		fn f(w: *std.tar.Writer) !void {
			try w.writeDir("lib", .{ .mode = 0o755 });
			try w.writeFileBytes("lib/z.txt", "zed", .{ .mode = 0o644 });
			try w.writeFileBytes("./lib/a/tool", "run", .{ .mode = 0o755 });
			try w.writeFileBytes("lib/a/data", "", .{ .mode = 0o600 });
		}
	}.f);
	defer gpa.free(tar);
	const tree = try fromTar(gpa, tar);
	defer gpa.free(tree);
	const es = try decodeAll(gpa, tree);
	defer gpa.free(es);
	try testing.expectEqual(@as(usize, 3), es.len);
	try testing.expectEqualStrings("lib/a/data", es[0].path);
	try testing.expect(!es[0].exec);
	try testing.expectEqualStrings("lib/a/tool", es[1].path);
	try testing.expect(es[1].exec);
	try testing.expectEqualStrings("run", es[1].bytes);
	try testing.expectEqualStrings("lib/z.txt", es[2].path);
	try testing.expectEqualStrings("zed", es[2].bytes);
}

test "fromTar refuses symlinks and unsafe paths" {
	const gpa = testing.allocator;
	const link = try testTar(gpa, struct {
		fn f(w: *std.tar.Writer) !void {
			try w.writeFileBytes("lib/a", "x", .{});
			try w.writeLink("lib/b", "a", .{});
		}
	}.f);
	defer gpa.free(link);
	try testing.expectError(error.UnsupportedEntry, fromTar(gpa, link));
	const evil = try testTar(gpa, struct {
		fn f(w: *std.tar.Writer) !void {
			try w.writeFileBytes("lib/../../evil", "x", .{});
		}
	}.f);
	defer gpa.free(evil);
	try testing.expectError(error.BadPath, fromTar(gpa, evil));
	try testing.expectError(error.BadTar, fromTar(gpa, "not a tar archive at all, just some bytes that are long enough to fill a header block maybe" ** 8));
}

test "validUtf8 agrees with the standard library on every 1-3 byte input and 2^20 seeded 4-byte inputs" {
	var b: [4]u8 = undefined;
	for (0..256) |x| {
		b[0] = @intCast(x);
		try testing.expectEqual(std.unicode.utf8ValidateSlice(b[0..1]), validUtf8(b[0..1]));
		for (0..256) |y| {
			b[1] = @intCast(y);
			try testing.expectEqual(std.unicode.utf8ValidateSlice(b[0..2]), validUtf8(b[0..2]));
			for (0..256) |z| {
				b[2] = @intCast(z);
				if (std.unicode.utf8ValidateSlice(b[0..3]) != validUtf8(b[0..3])) {
					std.debug.print("disagree on {x}\n", .{b[0..3]});
					return error.TestUnexpectedResult;
				}
			}
		}
	}
	var prng = std.Random.DefaultPrng.init(0x726f636f736d6f);
	const r = prng.random();
	for (0..1 << 20) |_| {
		r.bytes(&b);
		// Bias half the samples toward 4-byte leads so the hard cases are hit.
		if (r.boolean()) b[0] = 0xF0 | (b[0] & 0x07);
		if (std.unicode.utf8ValidateSlice(&b) != validUtf8(&b)) {
			std.debug.print("disagree on {x}\n", .{b});
			return error.TestUnexpectedResult;
		}
	}
}
