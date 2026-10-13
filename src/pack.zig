//! rocosmo container packer core: pure in-memory construction of a polyglot
//! file that is simultaneously a Windows PE image and a POSIX shell script
//! which extracts and executes the right embedded native executable.
//! No I/O; callers supply bytes and receive bytes.

const std = @import("std");

pub const Payload = struct {
	/// `uname -s`-`uname -m` case pattern, e.g. "Linux-x86_64|Linux-amd64".
	pattern: []const u8,
	bytes: []const u8,
};

pub const PackError = error{ NotPe, UnsupportedPe, HeadersOverflow, InvalidPattern, OutOfMemory };

/// Patterns become literal shell `case` alternatives, so only a conservative
/// alphabet is allowed: no globbing, quoting, whitespace or command syntax.
pub fn validPattern(p: []const u8) bool {
	var it = std.mem.splitScalar(u8, p, '|');
	while (it.next()) |alt| {
		if (alt.len == 0) return false;
		for (alt) |c| switch (c) {
			'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
			else => return false,
		};
	}
	return true;
}

const payload_align: usize = 4096;
const num_width = 10;

const dos_prefix = "MZqFpD='";
const script_head =
	"'\n" ++
	"s=$(command -v \"$0\")||s=$0\n" ++
	"c=${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/rocosmo\n" ++
	"case $(uname -s)-$(uname -m) in\n";
const script_tail =
	"*) echo \"$0: no payload for $(uname -s)-$(uname -m)\" >&2;exit 127;;\n" ++
	"esac\n" ++
	"f=$c/$i\n" ++
	"if [ ! -x \"$f\" ];then\n" ++
	// Unwritable cache home: use a private per-user TMPDIR directory, verified
	// (not a symlink, owned by us) before anything in it is trusted or run.
	"if ! mkdir -p \"$c\" 2>/dev/null;then\n" ++
	"c=${TMPDIR:-/tmp}/rocosmo-$(id -u) f=$c/$i\n" ++
	"mkdir -m 700 \"$c\" 2>/dev/null\n" ++
	"[ -d \"$c\" ]&&[ ! -L \"$c\" ]&&[ -O \"$c\" ]||{ echo \"$0: no private writable cache directory\" >&2;exit 126;}\n" ++
	"fi\n" ++
	"fi\n" ++
	"if [ ! -x \"$f\" ];then\n" ++
	"t=$f.$$ b=$((n/4096)) r=$((n%4096))\n" ++
	// BSD dd treats count=0 as "until EOF", so never call dd with a zero count.
	"{ { [ $b = 0 ]||dd if=\"$s\" bs=4096 skip=$((o/4096)) count=$b;}&&{ [ $r = 0 ]||dd if=\"$s\" bs=1 skip=$((o+b*4096)) count=$r;};} 2>/dev/null >\"$t\"&&chmod 755 \"$t\"&&mv -f \"$t\" \"$f\"||{ rm -f \"$t\";exit 126;}\n" ++
	"fi\n" ++
	"exec \"$f\" \"$@\"\n" ++
	"exit 127\n";

/// Builds the shell dispatcher that sits in the DOS stub area. Numbers are
/// right-padded to a fixed width so the script length does not depend on them
/// (leading zeros would be octal in shell arithmetic).
fn writeScript(list: *std.ArrayList(u8), gpa: std.mem.Allocator, payloads: []const Payload, offsets: []const usize) !void {
	try list.appendSlice(gpa, dos_prefix);
	try list.append(gpa, '\n');
	while (list.items.len < 0x3c) try list.append(gpa, ' ');
	try list.appendSlice(gpa, "\x00\x00\x00\x00"); // e_lfanew, patched later
	try list.appendSlice(gpa, script_head);
	for (payloads, offsets) |p, off| {
		var digest: [32]u8 = undefined;
		std.crypto.hash.sha2.Sha256.hash(p.bytes, &digest, .{});
		const hex = std.fmt.bytesToHex(digest[0..8], .lower);
		try list.appendSlice(gpa, p.pattern);
		try list.appendSlice(gpa, ") i=");
		try list.appendSlice(gpa, &hex);
		try appendPadded(list, gpa, " o=", off);
		try appendPadded(list, gpa, " n=", p.bytes.len);
		try list.appendSlice(gpa, ";;\n");
	}
	try list.appendSlice(gpa, script_tail);
}

fn appendPadded(list: *std.ArrayList(u8), gpa: std.mem.Allocator, label: []const u8, v: usize) !void {
	var buf: [num_width]u8 = undefined;
	const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
	try list.appendSlice(gpa, label);
	try list.appendSlice(gpa, s);
	try list.appendNTimes(gpa, ' ', num_width - s.len);
}

fn alignUp(v: usize, a: usize) usize {
	return (v + a - 1) / a * a;
}

const PeInfo = struct {
	lfanew: usize,
	opt: usize,
	opt_size: usize,
	nsec: usize,
	sec: usize,
	file_align: usize,
	soh: usize,
	min_va: usize,
};

fn parsePe(pe: []const u8) PackError!PeInfo {
	if (pe.len < 0x40 or pe[0] != 'M' or pe[1] != 'Z') return error.NotPe;
	const lfanew = rd32(pe, 0x3c);
	if (lfanew + 24 > pe.len or !std.mem.eql(u8, pe[lfanew..][0..4], "PE\x00\x00")) return error.NotPe;
	const opt = lfanew + 24;
	const opt_size = rd16(pe, lfanew + 20);
	const nsec = rd16(pe, lfanew + 6);
	if (opt + opt_size + 40 * nsec > pe.len or opt_size < 112) return error.NotPe;
	if (rd16(pe, opt) != 0x20b) return error.UnsupportedPe;
	const sec = opt + opt_size;
	var min_va: usize = std.math.maxInt(usize);
	for (0..nsec) |i| min_va = @min(min_va, rd32(pe, sec + 40 * i + 12));
	return .{
		.lfanew = lfanew,
		.opt = opt,
		.opt_size = opt_size,
		.nsec = nsec,
		.sec = sec,
		.file_align = rd32(pe, opt + 36),
		.soh = rd32(pe, opt + 60),
		.min_va = min_va,
	};
}

fn wr32(b: []u8, o: usize, v: usize) void {
	std.mem.writeInt(u32, b[o..][0..4], @intCast(v), .little);
}

fn bump32(b: []u8, o: usize, delta: usize) void {
	const v = rd32(b, o);
	if (v != 0) wr32(b, o, v + delta);
}

/// Lays out [script+relocated PE headers][PE body shifted][aligned payloads].
/// The Windows loader reads only e_magic and e_lfanew from the DOS header, so
/// the DOS stub region carries the POSIX shell dispatcher instead.
pub fn pack(gpa: std.mem.Allocator, pe: []const u8, payloads: []const Payload) PackError![]u8 {
	const info = try parsePe(pe);
	for (payloads) |p| if (!validPattern(p.pattern)) return error.InvalidPattern;
	const offsets = try gpa.alloc(usize, payloads.len);
	defer gpa.free(offsets);
	@memset(offsets, 0);

	var probe: std.ArrayList(u8) = .empty;
	defer probe.deinit(gpa);
	try writeScript(&probe, gpa, payloads, offsets);

	var lfanew = alignUp(probe.items.len, 8);
	// e_lfanew's bytes sit inside the quoted string; a 0x27 byte would end it.
	while (@as(u8, @truncate(lfanew)) == '\'' or @as(u8, @truncate(lfanew >> 8)) == '\'') lfanew += 8;
	const hdr_len = 24 + info.opt_size + 40 * info.nsec;
	const soh = @max(alignUp(lfanew + hdr_len, info.file_align), info.soh);
	if (soh > info.min_va) return error.HeadersOverflow;
	const delta = soh - info.soh;

	const body_end = soh + (pe.len - info.soh);
	var cursor = alignUp(body_end, payload_align);
	for (payloads, offsets) |p, *off| {
		off.* = cursor;
		cursor = alignUp(cursor + p.bytes.len, payload_align);
	}
	const total = if (payloads.len == 0) body_end else offsets[payloads.len - 1] + payloads[payloads.len - 1].bytes.len;

	var script: std.ArrayList(u8) = .empty;
	defer script.deinit(gpa);
	try writeScript(&script, gpa, payloads, offsets);
	std.debug.assert(script.items.len == probe.items.len);

	const out = try gpa.alloc(u8, total);
	errdefer gpa.free(out);
	@memset(out, 0);
	@memcpy(out[0..script.items.len], script.items);
	@memset(out[script.items.len..lfanew], '\n');
	wr32(out, 0x3c, lfanew);
	@memcpy(out[lfanew..][0..hdr_len], pe[info.lfanew..][0..hdr_len]);
	@memcpy(out[soh..body_end], pe[info.soh..]);

	const opt = lfanew + 24;
	const sec = opt + info.opt_size;
	wr32(out, opt + 60, soh); // SizeOfHeaders
	wr32(out, opt + 64, 0); // CheckSum: not required for executables
	bump32(out, lfanew + 12, delta); // PointerToSymbolTable
	for (0..info.nsec) |i| {
		const h = sec + 40 * i;
		bump32(out, h + 20, delta); // PointerToRawData
		bump32(out, h + 24, delta); // PointerToRelocations
		bump32(out, h + 28, delta); // PointerToLinenumbers
	}
	const ndirs = rd32(out, opt + 108);
	if (ndirs > 4) bump32(out, opt + 112 + 8 * 4, delta); // certificate table uses a file offset
	if (ndirs > 6) relocateDebugDirectory(out, sec, info.nsec, rd32(out, opt + 112 + 8 * 6), rd32(out, opt + 116 + 8 * 6), delta);

	for (payloads, offsets) |p, off| @memcpy(out[off..][0..p.bytes.len], p.bytes);
	return out;
}

/// Debug directory entries record file offsets of their data; shift them.
fn relocateDebugDirectory(out: []u8, sec: usize, nsec: usize, rva: usize, size: usize, delta: usize) void {
	if (rva == 0 or size == 0) return;
	for (0..nsec) |i| {
		const h = sec + 40 * i;
		const va = rd32(out, h + 12);
		const raw = rd32(out, h + 16);
		if (rva >= va and rva + size <= va + raw) {
			const base = rd32(out, h + 20) + (rva - va);
			var e: usize = 0;
			while (e + 28 <= size) : (e += 28) bump32(out, base + e + 24, delta);
			return;
		}
	}
}
// ---------------------------------------------------------------------------
// Tests. The oracle is the input itself: every PE section and every payload
// must reappear byte-for-byte where the output's own headers and script say.

const testing = std.testing;

/// A minimal valid-shape PE32+ image with two sections, built field by field
/// so the test does not depend on the packer's parser.
fn fakePe(gpa: std.mem.Allocator) ![]u8 {
	const file_align = 0x200;
	const size_of_headers = 0x400;
	const opt_size = 240;
	var buf = try gpa.alloc(u8, size_of_headers + 2 * file_align);
	@memset(buf, 0);
	buf[0] = 'M';
	buf[1] = 'Z';
	const lfanew: u32 = 0x80;
	std.mem.writeInt(u32, buf[0x3c..][0..4], lfanew, .little);
	@memcpy(buf[lfanew..][0..4], "PE\x00\x00");
	const coff = lfanew + 4;
	std.mem.writeInt(u16, buf[coff..][0..2], 0x8664, .little);
	std.mem.writeInt(u16, buf[coff + 2 ..][0..2], 2, .little);
	std.mem.writeInt(u16, buf[coff + 16 ..][0..2], opt_size, .little);
	const opt = coff + 20;
	std.mem.writeInt(u16, buf[opt..][0..2], 0x20b, .little);
	std.mem.writeInt(u32, buf[opt + 32 ..][0..4], 0x1000, .little);
	std.mem.writeInt(u32, buf[opt + 36 ..][0..4], file_align, .little);
	std.mem.writeInt(u32, buf[opt + 60 ..][0..4], size_of_headers, .little);
	std.mem.writeInt(u32, buf[opt + 108 ..][0..4], 16, .little);
	const sec = opt + opt_size;
	for (0..2) |i| {
		const h = sec + 40 * i;
		@memcpy(buf[h..][0..5], if (i == 0) ".text" else ".data");
		std.mem.writeInt(u32, buf[h + 8 ..][0..4], file_align, .little);
		std.mem.writeInt(u32, buf[h + 12 ..][0..4], @intCast(0x1000 * (i + 1)), .little);
		std.mem.writeInt(u32, buf[h + 16 ..][0..4], file_align, .little);
		std.mem.writeInt(u32, buf[h + 20 ..][0..4], @intCast(size_of_headers + file_align * i), .little);
		@memset(buf[size_of_headers + file_align * i ..][0..file_align], @intCast(0xA0 + i));
	}
	return buf;
}

fn rd32(b: []const u8, o: usize) u32 {
	return std.mem.readInt(u32, b[o..][0..4], .little);
}
fn rd16(b: []const u8, o: usize) u16 {
	return std.mem.readInt(u16, b[o..][0..2], .little);
}

test "output starts as both an MZ header and a shell assignment" {
	const gpa = testing.allocator;
	const pe = try fakePe(gpa);
	defer gpa.free(pe);
	const out = try pack(gpa, pe, &.{});
	defer gpa.free(out);
	try testing.expectEqualStrings("MZqFpD='", out[0..8]);
}

test "e_lfanew locates a PE header whose sections hold the original bytes" {
	const gpa = testing.allocator;
	const pe = try fakePe(gpa);
	defer gpa.free(pe);
	const out = try pack(gpa, pe, &.{});
	defer gpa.free(out);
	const lfanew = rd32(out, 0x3c);
	try testing.expectEqualStrings("PE\x00\x00", out[lfanew..][0..4]);
	const coff = lfanew + 4;
	const nsec = rd16(out, coff + 2);
	const opt = coff + 20;
	const sec = opt + rd16(out, coff + 16);
	const in_lfanew = rd32(pe, 0x3c);
	const in_sec = in_lfanew + 24 + rd16(pe, in_lfanew + 20);
	try testing.expectEqual(@as(u16, 2), nsec);
	for (0..nsec) |i| {
		const o = sec + 40 * i;
		const io = in_sec + 40 * i;
		const size = rd32(out, o + 16);
		try testing.expectEqual(rd32(pe, io + 16), size);
		try testing.expectEqual(rd32(pe, io + 12), rd32(out, o + 12)); // VAs unchanged
		try testing.expectEqualSlices(u8, pe[rd32(pe, io + 20)..][0..size], out[rd32(out, o + 20)..][0..size]);
		try testing.expect(rd32(out, o + 20) % rd32(out, opt + 36) == 0);
	}
	// Headers must still end before the first section is mapped.
	try testing.expect(rd32(out, opt + 60) <= rd32(out, sec + 12));
}

test "shell text before the PE header contains no stray single quote" {
	const gpa = testing.allocator;
	const pe = try fakePe(gpa);
	defer gpa.free(pe);
	const out = try pack(gpa, pe, &.{.{ .pattern = "Linux-x86_64", .bytes = "abc" }});
	defer gpa.free(out);
	const lfanew = rd32(out, 0x3c);
	// Exactly two quotes delimit the swallowed DOS header: offsets 7 and 0x40.
	var quotes: usize = 0;
	for (out[0..lfanew]) |c| quotes += @intFromBool(c == '\'');
	try testing.expectEqual(@as(usize, 2), quotes);
	try testing.expectEqual(@as(u8, '\''), out[0x40]);
	try testing.expect(std.mem.indexOf(u8, out[0..lfanew], "exit") != null);
}

/// Parse "pattern) ... off=N len=M" lines back out of the script: an
/// independent reading of what the shell will execute.
fn scriptEntry(out: []const u8, pattern: []const u8) ?struct { off: usize, len: usize } {
	const lfanew = rd32(out, 0x3c);
	const text = out[0..lfanew];
	const at = std.mem.indexOf(u8, text, pattern) orelse return null;
	const line_end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse return null;
	const line = text[at..line_end];
	const o = std.mem.indexOf(u8, line, "o=") orelse return null;
	const l = std.mem.indexOf(u8, line, "n=") orelse return null;
	const off = std.fmt.parseInt(usize, std.mem.sliceTo(line[o + 2 ..], ' '), 10) catch return null;
	const len = std.fmt.parseInt(usize, std.mem.sliceTo(line[l + 2 ..], ' '), 10) catch return null;
	return .{ .off = off, .len = len };
}

test "every payload is stored byte-for-byte at the offset its script line names" {
	const gpa = testing.allocator;
	const pe = try fakePe(gpa);
	defer gpa.free(pe);
	var big: [10000]u8 = undefined;
	for (&big, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
	const payloads = [_]Payload{
		.{ .pattern = "Linux-x86_64|Linux-amd64", .bytes = &big },
		.{ .pattern = "Darwin-arm64", .bytes = "tiny" },
		.{ .pattern = "Linux-aarch64|Linux-arm64", .bytes = "" },
	};
	const out = try pack(gpa, pe, &payloads);
	defer gpa.free(out);
	for (payloads) |p| {
		const e = scriptEntry(out, p.pattern) orelse return error.TestMissingEntry;
		try testing.expectEqual(p.bytes.len, e.len);
		try testing.expectEqualSlices(u8, p.bytes, out[e.off..][0..e.len]);
		try testing.expect(e.off % 4096 == 0);
	}
}

test "identical payload bytes get identical cache identities; different bytes differ" {
	const gpa = testing.allocator;
	const pe = try fakePe(gpa);
	defer gpa.free(pe);
	const a = try pack(gpa, pe, &.{.{ .pattern = "Linux-x86_64", .bytes = "one" }});
	defer gpa.free(a);
	const b = try pack(gpa, pe, &.{.{ .pattern = "Linux-x86_64", .bytes = "one" }});
	defer gpa.free(b);
	const c = try pack(gpa, pe, &.{.{ .pattern = "Linux-x86_64", .bytes = "two" }});
	defer gpa.free(c);
	try testing.expectEqualSlices(u8, a, b);
	const ia = std.mem.indexOf(u8, a, "i=").?;
	const ic = std.mem.indexOf(u8, c, "i=").?;
	try testing.expect(!std.mem.eql(u8, a[ia..][0..18], c[ic..][0..18]));
}

test "rejects non-PE input and PE32 (non-plus) images" {
	const gpa = testing.allocator;
	try testing.expectError(error.NotPe, pack(gpa, "not a pe at all, definitely not", &.{}));
	const pe = try fakePe(gpa);
	defer gpa.free(pe);
	std.mem.writeInt(u16, pe[0x80 + 24 ..][0..2], 0x10b, .little);
	try testing.expectError(error.UnsupportedPe, pack(gpa, pe, &.{}));
}

test "fails rather than overlapping headers with the first section" {
	const gpa = testing.allocator;
	const pe = try fakePe(gpa);
	defer gpa.free(pe);
	var many: [200]Payload = undefined;
	for (&many) |*p| p.* = .{ .pattern = "Some-Very-Long-Pattern-To-Bloat-The-Script", .bytes = "x" };
	try testing.expectError(error.HeadersOverflow, pack(gpa, pe, &many));
}

test "pattern validation classifies a set of candidate patterns" {
	const accepted = [_][]const u8{ "Linux-x86_64", "Linux-x86_64|Linux-amd64", "Darwin-arm64", "FreeBSD-amd64", "a.b_c-d" };
	const rejected = [_][]const u8{ "", "|", "Linux-x86_64|", "|Linux", "a||b", "Linux*", "a b", "a;b", "$(x)", "a`b`", "a'b", "a\"b", "a\nb", "a)b", "a\\b", "a?b", "[a]" };
	for (accepted) |p| try testing.expect(validPattern(p));
	for (rejected) |p| try testing.expect(!validPattern(p));
	const gpa = testing.allocator;
	const pe = try fakePe(gpa);
	defer gpa.free(pe);
	try testing.expectError(error.InvalidPattern, pack(gpa, pe, &.{.{ .pattern = "x) rm -rf ~;;", .bytes = "" }}));
}
