//! rocosmo container packer core: pure in-memory construction of a polyglot
//! file that is simultaneously a Windows PE image and a POSIX shell script
//! which extracts and executes the right embedded native executable.
//! No I/O; callers supply bytes and receive bytes.
//!
//! Two layouts share the header and cache logic:
//!   raw  - each payload is stored as-is and extracted with dd.
//!   zstd - each target is a whole zstd frame or a --patch-from delta against
//!          a same-CPU target or the Windows PE body; a small native runtime
//!          per OS/CPU (stored gzipped, unpacked with the system gzip, cached
//!          once per machine) rebuilds it.

const std = @import("std");
const layout = @import("layout.zig");
const index = @import("index.zig");
const zenc = @import("zstd_encode.zig");

pub const Payload = struct {
	/// `uname -s`-`uname -m` case pattern, e.g. "Linux-x86_64|Linux-amd64".
	pattern: []const u8,
	bytes: []const u8,
};

pub const Arch = enum { x86_64, aarch64 };

pub const Target = struct {
	/// Index name, e.g. "linux-x86_64"; also the runtime's target argument.
	name: []const u8,
	pattern: []const u8,
	arch: Arch,
	bytes: []const u8,
	/// gzip-compressed runtime executable for this OS/CPU.
	runtime_gz: []const u8,
};

pub const PackError = error{ NotPe, UnsupportedPe, HeadersOverflow, InvalidPattern, InvalidName, TooManyTargets, EncodeFailed, OutOfMemory };

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
/// Index entry name of the Windows PE body, a free delta reference.
pub const pe_body_name = "windows-x86_64-body";

const dos_prefix = "MZqFpD='";
const script_start =
	"'\n" ++
	"s=$(command -v \"$0\")||s=$0\n" ++
	"c=${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/rocosmo\n";
const case_start = "case $(uname -s)-$(uname -m) in\n";
const script_head = script_start ++ case_start;
const case_end =
	"*) echo \"$0: no payload for $(uname -s)-$(uname -m)\" >&2;exit 127;;\n" ++
	"esac\n";
const cache_dir =
	"f=$c/$i\n" ++
	"if [ ! -x \"$f\" ];then\n" ++
	// Unwritable cache home: use a private per-user TMPDIR directory, verified
	// (not a symlink, owned by us) before anything in it is trusted or run.
	"if ! mkdir -p \"$c\" 2>/dev/null;then\n" ++
	"c=${TMPDIR:-/tmp}/rocosmo-$(id -u) f=$c/$i\n" ++
	"mkdir -m 700 \"$c\" 2>/dev/null\n" ++
	"[ -d \"$c\" ]&&[ ! -L \"$c\" ]&&[ -O \"$c\" ]||{ echo \"$0: no private writable cache directory\" >&2;exit 126;}\n" ++
	"fi\n" ++
	"fi\n";
// BSD dd treats count=0 as "until EOF", so never call dd with a zero count.
// Copies bytes [o, o+n) of the container to stdout.
const dd_range = "{ { [ $b = 0 ]||dd if=\"$s\" bs=4096 skip=$((o/4096)) count=$b;}&&{ [ $r = 0 ]||dd if=\"$s\" bs=1 skip=$((o+b*4096)) count=$r;};} 2>/dev/null";
const exec_tail =
	"exec \"$f\" \"$@\"\n" ++
	"exit 127\n";
const script_tail = case_end ++ cache_dir ++
	"if [ ! -x \"$f\" ];then\n" ++
	"t=$f.$$ b=$((n/4096)) r=$((n%4096))\n" ++
	dd_range ++ " >\"$t\"&&chmod 755 \"$t\"&&mv -f \"$t\" \"$f\"||{ rm -f \"$t\";exit 126;}\n" ++
	"fi\n" ++ exec_tail;
/// zstd layout: o/n locate this OS/CPU's gzipped runtime (cached as $c/$h);
/// the runtime reads the index at x/y and writes target $p to a temp file.
const script_tail_zstd = case_end ++ cache_dir ++
	"if [ ! -x \"$f\" ];then\n" ++
	"g=$c/$h\n" ++
	"if [ ! -x \"$g\" ];then\n" ++
	"u=$g.$$ b=$((n/4096)) r=$((n%4096))\n" ++
	dd_range ++ "|gzip -dc >\"$u\"&&chmod 755 \"$u\"&&mv -f \"$u\" \"$g\"||{ rm -f \"$u\";echo \"$0: cannot unpack runtime\" >&2;exit 126;}\n" ++
	"fi\n" ++
	"t=$f.$$\n" ++
	"\"$g\" \"$s\" $x $y $p \"$t\"&&chmod 755 \"$t\"&&mv -f \"$t\" \"$f\"||{ rm -f \"$t\";exit 126;}\n" ++
	"fi\n" ++ exec_tail;

fn shortHash(bytes: []const u8) [16]u8 {
	var digest: [32]u8 = undefined;
	std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
	return std.fmt.bytesToHex(digest[0..8], .lower);
}

fn writeDosPrefix(list: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
	try list.appendSlice(gpa, dos_prefix);
	try list.append(gpa, '\n');
	while (list.items.len < 0x3c) try list.append(gpa, ' ');
	try list.appendSlice(gpa, "\x00\x00\x00\x00"); // e_lfanew, patched later
}

/// Builds the shell dispatcher that sits in the DOS stub area. Numbers are
/// right-padded to a fixed width so the script length does not depend on them
/// (leading zeros would be octal in shell arithmetic).
fn writeScript(list: *std.ArrayList(u8), gpa: std.mem.Allocator, payloads: []const Payload, offsets: []const usize) !void {
	try writeDosPrefix(list, gpa);
	try list.appendSlice(gpa, script_head);
	for (payloads, offsets) |p, off| {
		try list.appendSlice(gpa, p.pattern);
		try list.appendSlice(gpa, ") i=");
		try list.appendSlice(gpa, &shortHash(p.bytes));
		try appendPadded(list, gpa, " o=", off);
		try appendPadded(list, gpa, " n=", p.bytes.len);
		try list.appendSlice(gpa, ";;\n");
	}
	try list.appendSlice(gpa, script_tail);
}

fn writeScriptZstd(list: *std.ArrayList(u8), gpa: std.mem.Allocator, targets: []const Target, rt_offsets: []const usize, idx_off: usize, idx_len: usize) !void {
	try writeDosPrefix(list, gpa);
	try list.appendSlice(gpa, script_start);
	try appendPadded(list, gpa, "x=", idx_off);
	try appendPadded(list, gpa, " y=", idx_len);
	try list.append(gpa, '\n');
	try list.appendSlice(gpa, case_start);
	for (targets, rt_offsets) |t, off| {
		try list.appendSlice(gpa, t.pattern);
		try list.appendSlice(gpa, ") i=");
		try list.appendSlice(gpa, &shortHash(t.bytes));
		try list.appendSlice(gpa, " h=");
		try list.appendSlice(gpa, &shortHash(t.runtime_gz));
		try appendPadded(list, gpa, " o=", off);
		try appendPadded(list, gpa, " n=", t.runtime_gz.len);
		try list.appendSlice(gpa, " p=");
		try list.appendSlice(gpa, t.name);
		try list.appendSlice(gpa, ";;\n");
	}
	try list.appendSlice(gpa, script_tail_zstd);
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

/// Where the relocated PE headers and body land after a script of `script_len`.
const Header = struct { lfanew: usize, soh: usize, body_end: usize };

fn headerLayout(info: PeInfo, pe_len: usize, script_len: usize) PackError!Header {
	var lfanew = alignUp(script_len, 8);
	// e_lfanew's bytes sit inside the quoted string; a 0x27 byte would end it.
	while (@as(u8, @truncate(lfanew)) == '\'' or @as(u8, @truncate(lfanew >> 8)) == '\'') lfanew += 8;
	const hdr_len = 24 + info.opt_size + 40 * info.nsec;
	const soh = @max(alignUp(lfanew + hdr_len, info.file_align), info.soh);
	if (soh > info.min_va) return error.HeadersOverflow;
	return .{ .lfanew = lfanew, .soh = soh, .body_end = soh + (pe_len - info.soh) };
}

/// Writes [script][relocated PE headers][PE body] into the front of `out`.
/// The Windows loader reads only e_magic and e_lfanew from the DOS header, so
/// the DOS stub region carries the POSIX shell dispatcher instead.
fn writeFront(out: []u8, pe: []const u8, info: PeInfo, script: []const u8, h: Header) void {
	const hdr_len = 24 + info.opt_size + 40 * info.nsec;
	const delta = h.soh - info.soh;
	@memcpy(out[0..script.len], script);
	@memset(out[script.len..h.lfanew], '\n');
	wr32(out, 0x3c, h.lfanew);
	@memcpy(out[h.lfanew..][0..hdr_len], pe[info.lfanew..][0..hdr_len]);
	@memcpy(out[h.soh..h.body_end], pe[info.soh..]);

	const opt = h.lfanew + 24;
	const sec = opt + info.opt_size;
	wr32(out, opt + 60, h.soh); // SizeOfHeaders
	wr32(out, opt + 64, 0); // CheckSum: not required for executables
	bump32(out, h.lfanew + 12, delta); // PointerToSymbolTable
	for (0..info.nsec) |i| {
		const s = sec + 40 * i;
		bump32(out, s + 20, delta); // PointerToRawData
		bump32(out, s + 24, delta); // PointerToRelocations
		bump32(out, s + 28, delta); // PointerToLinenumbers
	}
	const ndirs = rd32(out, opt + 108);
	if (ndirs > 4) bump32(out, opt + 112 + 8 * 4, delta); // certificate table uses a file offset
	if (ndirs > 6) relocateDebugDirectory(out, sec, info.nsec, rd32(out, opt + 112 + 8 * 6), rd32(out, opt + 116 + 8 * 6), delta);
}

/// Raw layout: [script+relocated PE headers][PE body shifted][aligned payloads].
pub fn pack(gpa: std.mem.Allocator, pe: []const u8, payloads: []const Payload) PackError![]u8 {
	const info = try parsePe(pe);
	for (payloads) |p| if (!validPattern(p.pattern)) return error.InvalidPattern;
	const offsets = try gpa.alloc(usize, payloads.len);
	defer gpa.free(offsets);
	@memset(offsets, 0);

	var probe: std.ArrayList(u8) = .empty;
	defer probe.deinit(gpa);
	try writeScript(&probe, gpa, payloads, offsets);
	const h = try headerLayout(info, pe.len, probe.items.len);

	var cursor = alignUp(h.body_end, payload_align);
	for (payloads, offsets) |p, *off| {
		off.* = cursor;
		cursor = alignUp(cursor + p.bytes.len, payload_align);
	}
	const total = if (payloads.len == 0) h.body_end else offsets[payloads.len - 1] + payloads[payloads.len - 1].bytes.len;

	var script: std.ArrayList(u8) = .empty;
	defer script.deinit(gpa);
	try writeScript(&script, gpa, payloads, offsets);
	std.debug.assert(script.items.len == probe.items.len);

	const out = try gpa.alloc(u8, total);
	errdefer gpa.free(out);
	@memset(out, 0);
	writeFront(out, pe, info, script.items, h);
	for (payloads, offsets) |p, off| @memcpy(out[off..][0..p.bytes.len], p.bytes);
	return out;
}

/// zstd layout. Every target is encoded whole, and as a delta against each
/// same-CPU target and (x86_64 only) the Windows PE body; deltas across CPUs
/// are not tried because they measured 91-100% of a whole frame (RESEARCH.md
/// section 10). layout.optimal then picks roots and references exhaustively.
/// Output: [script][PE][runtimes][index][frames], blobs 4 KiB aligned.
pub fn packZstd(gpa: std.mem.Allocator, pe: []const u8, targets: []const Target, level: i32) PackError![]u8 {
	const info = try parsePe(pe);
	for (targets) |t| {
		if (!validPattern(t.pattern)) return error.InvalidPattern;
		if (!index.validName(t.name) or std.mem.eql(u8, t.name, pe_body_name)) return error.InvalidName;
	}
	const n = targets.len;
	if (n > layout.max_targets) return error.TooManyTargets;
	const body = pe[info.soh..];

	// Candidate frames: whole[t], and delta[r * n + t] with r == n meaning the PE body.
	const whole = try gpa.alloc([]u8, n);
	var whole_done: usize = 0;
	defer {
		for (whole[0..whole_done]) |f| gpa.free(f);
		gpa.free(whole);
	}
	const delta = try gpa.alloc(?[]u8, (n + 1) * n);
	@memset(delta, null);
	defer {
		for (delta) |d| if (d) |f| gpa.free(f);
		gpa.free(delta);
	}
	for (targets, 0..) |t, ti| {
		whole[ti] = zenc.encode(gpa, t.bytes, null, level) catch |e| return mapEnc(e);
		whole_done += 1;
		for (0..n + 1) |r| {
			const ref: []const u8 = if (r == n) body else targets[r].bytes;
			const usable = if (r == n) t.arch == .x86_64 else (r != ti and targets[r].arch == t.arch);
			if (usable) delta[r * n + ti] = zenc.encode(gpa, t.bytes, ref, level) catch |e| return mapEnc(e);
		}
	}
	const alone = try gpa.alloc(u64, n);
	defer gpa.free(alone);
	for (alone, whole) |*a, f| a.* = f.len;
	const costs = try gpa.alloc(?u64, (n + 1) * n);
	defer gpa.free(costs);
	for (costs, delta) |*c, d| c.* = if (d) |f| f.len else null;
	const plan = try layout.optimal(gpa, n, 1, alone, costs);
	defer plan.deinit(gpa);

	// The frame stored for each target.
	const chosen = try gpa.alloc([]const u8, n);
	defer gpa.free(chosen);
	for (chosen, plan.choice, 0..) |*c, ch, ti| c.* = switch (ch) {
		.root => whole[ti],
		.delta => |r| delta[r * n + ti].?,
	};

	// Sizes first: the index and script have fixed widths for given names.
	const entries = try gpa.alloc(index.Entry, n + 1);
	defer gpa.free(entries);
	fillEntries(entries, targets, plan.choice, chosen, body.len, 0, 0, &.{});
	const idx_probe = index.encode(gpa, entries) catch |e| return mapIdx(e);
	const idx_len = idx_probe.len;
	gpa.free(idx_probe);
	const rt_offsets = try gpa.alloc(usize, n);
	defer gpa.free(rt_offsets);
	@memset(rt_offsets, 0);
	var probe: std.ArrayList(u8) = .empty;
	defer probe.deinit(gpa);
	try writeScriptZstd(&probe, gpa, targets, rt_offsets, 0, idx_len);
	const h = try headerLayout(info, pe.len, probe.items.len);

	var cursor = alignUp(h.body_end, payload_align);
	for (targets, rt_offsets) |t, *off| {
		off.* = cursor;
		cursor = alignUp(cursor + t.runtime_gz.len, payload_align);
	}
	const idx_off = cursor;
	cursor = alignUp(cursor + idx_len, payload_align);
	const frame_offsets = try gpa.alloc(usize, n);
	defer gpa.free(frame_offsets);
	var total = idx_off + idx_len;
	for (chosen, frame_offsets) |f, *off| {
		off.* = cursor;
		total = cursor + f.len;
		cursor = alignUp(total, payload_align);
	}

	fillEntries(entries, targets, plan.choice, chosen, body.len, h.soh, 1, frame_offsets);
	const idx = index.encode(gpa, entries) catch |e| return mapIdx(e);
	defer gpa.free(idx);
	std.debug.assert(idx.len == idx_len);
	var script: std.ArrayList(u8) = .empty;
	defer script.deinit(gpa);
	try writeScriptZstd(&script, gpa, targets, rt_offsets, idx_off, idx_len);
	std.debug.assert(script.items.len == probe.items.len);

	const out = try gpa.alloc(u8, total);
	errdefer gpa.free(out);
	@memset(out, 0);
	writeFront(out, pe, info, script.items, h);
	for (targets, rt_offsets) |t, off| @memcpy(out[off..][0..t.runtime_gz.len], t.runtime_gz);
	@memcpy(out[idx_off..][0..idx_len], idx);
	for (chosen, frame_offsets) |f, off| @memcpy(out[off..][0..f.len], f);
	return out;
}

/// Index entry 0 is the PE body (raw, a free reference); entry t+1 is target t.
/// With `placed` == 0 offsets are zero (for sizing only).
fn fillEntries(entries: []index.Entry, targets: []const Target, choice: []const layout.Choice, chosen: []const []const u8, body_len: usize, body_off: usize, placed: u1, frame_offsets: []const usize) void {
	const n = targets.len;
	entries[0] = .{ .name = pe_body_name, .kind = .raw, .offset = body_off, .stored_len = body_len, .content_len = body_len };
	for (targets, choice, chosen, 0..) |t, ch, f, ti| {
		entries[ti + 1] = .{
			.name = t.name,
			.kind = if (ch == .root) .frame else .delta,
			// layout reference r < n is target r (entry r + 1); r == n is the PE body (entry 0).
			.ref = switch (ch) {
				.root => null,
				.delta => |r| if (r == n) 0 else @intCast(r + 1),
			},
			.offset = if (placed == 1) frame_offsets[ti] else 0,
			.stored_len = f.len,
			.content_len = t.bytes.len,
		};
	}
}

fn mapEnc(e: anyerror) PackError {
	return if (e == error.OutOfMemory) error.OutOfMemory else error.EncodeFailed;
}

fn mapIdx(e: index.Error) PackError {
	return switch (e) {
		error.OutOfMemory => error.OutOfMemory,
		error.TooMany => error.TooManyTargets,
		error.BadName => error.InvalidName,
		else => unreachable, // the packer builds only well-formed entries
	};
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

/// Shared with other modules' tests.
pub const testPe = fakePe;

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

// ---------------------------------------------------------------------------
// zstd layout. The oracle is again the input: an independent reader parses
// the script and index, decodes with zstd and must reproduce every target.

const zdec = @import("zstd_decode.zig");

/// Value of `key=` on the script line that starts with `pattern`.
fn scriptField(out: []const u8, pattern: []const u8, key: []const u8) ?[]const u8 {
	const text = out[0..rd32(out, 0x3c)];
	var lines = std.mem.splitScalar(u8, text, '\n');
	while (lines.next()) |line| {
		if (!std.mem.startsWith(u8, line, pattern) or line.len <= pattern.len or line[pattern.len] != ')') continue;
		return fieldIn(line, key);
	}
	return null;
}

fn fieldIn(line: []const u8, key: []const u8) ?[]const u8 {
	var words = std.mem.tokenizeAny(u8, line, " ;");
	while (words.next()) |w| if (std.mem.startsWith(u8, w, key) and w.len > key.len and w[key.len] == '=') return w[key.len + 1 ..];
	return null;
}

/// Global `key=` assignment on its own line (the index location).
fn scriptGlobal(out: []const u8, key: []const u8) ?u64 {
	const text = out[0..rd32(out, 0x3c)];
	var lines = std.mem.splitScalar(u8, text, '\n');
	while (lines.next()) |line| {
		if (std.mem.indexOfScalar(u8, line, ')') != null) continue;
		const v = fieldIn(line, key) orelse continue;
		return std.fmt.parseInt(u64, v, 10) catch null;
	}
	return null;
}

fn rebuild(gpa: std.mem.Allocator, out: []const u8, name: []const u8) ![]u8 {
	const x = scriptGlobal(out, "x") orelse return error.TestNoIndex;
	const y = scriptGlobal(out, "y") orelse return error.TestNoIndex;
	const entries = try index.decode(gpa, out[x..][0..y], out.len);
	defer gpa.free(entries);
	const p = try index.plan(entries, name);
	var ref_buf: ?[]u8 = null;
	defer if (ref_buf) |r| gpa.free(r);
	const ref: ?[]const u8 = if (p.reference) |r| switch (r.kind) {
		.raw => out[r.offset..][0..r.stored_len],
		else => blk: {
			ref_buf = try gpa.alloc(u8, r.content_len);
			try zdec.decode(out[r.offset..][0..r.stored_len], null, ref_buf.?);
			break :blk ref_buf.?;
		},
	} else null;
	const buf = try gpa.alloc(u8, p.target.content_len);
	errdefer gpa.free(buf);
	switch (p.target.kind) {
		.raw => @memcpy(buf, out[p.target.offset..][0..p.target.stored_len]),
		else => try zdec.decode(out[p.target.offset..][0..p.target.stored_len], ref, buf),
	}
	return buf;
}

fn sampleBytes(gpa: std.mem.Allocator, len: usize, seed: u32) ![]u8 {
	const b = try gpa.alloc(u8, len);
	var s = seed;
	for (b) |*c| {
		s = s *% 1103515245 +% 12345;
		c.* = if (s >> 29 < 5) "mov_call_ret_"[(s >> 16) % 13] else @truncate(s >> 16);
	}
	return b;
}

const ZTest = struct {
	x64: []u8,
	x64b: []u8,
	arm: []u8,
	fn init(gpa: std.mem.Allocator) !ZTest {
		const x64 = try sampleBytes(gpa, 60_000, 1);
		const x64b = try gpa.dupe(u8, x64);
		for (0..20) |k| x64b[k * 2777] ^= 0x33;
		return .{ .x64 = x64, .x64b = x64b, .arm = try sampleBytes(gpa, 40_000, 2) };
	}
	fn deinit(self: ZTest, gpa: std.mem.Allocator) void {
		gpa.free(self.x64);
		gpa.free(self.x64b);
		gpa.free(self.arm);
	}
	fn targets(self: ZTest) [3]Target {
		return .{
			.{ .name = "linux-x86_64", .pattern = "Linux-x86_64|Linux-amd64", .arch = .x86_64, .bytes = self.x64, .runtime_gz = "RUNTIME linux-x86_64" },
			.{ .name = "macos-x86_64", .pattern = "Darwin-x86_64", .arch = .x86_64, .bytes = self.x64b, .runtime_gz = "RUNTIME macos-x86_64" },
			.{ .name = "linux-aarch64", .pattern = "Linux-aarch64|Linux-arm64", .arch = .aarch64, .bytes = self.arm, .runtime_gz = "RUNTIME linux-aarch64" },
		};
	}
};

test "zstd layout: every target rebuilds byte-exact from the script, index and frames" {
	const gpa = testing.allocator;
	const pe = try fakePe(gpa);
	defer gpa.free(pe);
	const z = try ZTest.init(gpa);
	defer z.deinit(gpa);
	const ts = z.targets();
	const out = try packZstd(gpa, pe, &ts, 19);
	defer gpa.free(out);
	try testing.expectEqualStrings("MZqFpD='", out[0..8]);
	for (ts) |t| {
		try testing.expectEqualStrings(t.name, scriptField(out, t.pattern, "p") orelse return error.TestNoLine);
		const got = try rebuild(gpa, out, t.name);
		defer gpa.free(got);
		try testing.expectEqualSlices(u8, t.bytes, got);
		// The runtime blob named on the line is stored verbatim and 4 KiB aligned.
		const o = try std.fmt.parseInt(usize, scriptField(out, t.pattern, "o").?, 10);
		const n = try std.fmt.parseInt(usize, scriptField(out, t.pattern, "n").?, 10);
		try testing.expectEqualStrings(t.runtime_gz, out[o..][0..n]);
		try testing.expect(o % 4096 == 0);
		// Cache identities match the raw layout's, so both layouts share a cache.
		var d: [32]u8 = undefined;
		std.crypto.hash.sha2.Sha256.hash(t.bytes, &d, .{});
		try testing.expectEqualStrings(&std.fmt.bytesToHex(d[0..8], .lower), scriptField(out, t.pattern, "i").?);
	}
}

test "zstd layout: a near-identical same-CPU target becomes a delta; CPUs never cross" {
	const gpa = testing.allocator;
	const pe = try fakePe(gpa);
	defer gpa.free(pe);
	const z = try ZTest.init(gpa);
	defer z.deinit(gpa);
	const ts = z.targets();
	const out = try packZstd(gpa, pe, &ts, 19);
	defer gpa.free(out);
	const entries = try index.decode(gpa, out[scriptGlobal(out, "x").?..][0..scriptGlobal(out, "y").?], out.len);
	defer gpa.free(entries);
	var deltas: usize = 0;
	for (entries) |e| {
		if (e.kind != .delta) continue;
		deltas += 1;
		const r = entries[e.ref.?];
		const same_cpu = std.mem.endsWith(u8, e.name, "x86_64") == (std.mem.endsWith(u8, r.name, "x86_64") or r.kind == .raw);
		try testing.expect(same_cpu);
	}
	try testing.expectEqual(@as(usize, 1), deltas);
}

test "zstd layout keeps the PE sections intact and is deterministic" {
	const gpa = testing.allocator;
	const pe = try fakePe(gpa);
	defer gpa.free(pe);
	const z = try ZTest.init(gpa);
	defer z.deinit(gpa);
	const ts = z.targets();
	const a = try packZstd(gpa, pe, &ts, 19);
	defer gpa.free(a);
	const b = try packZstd(gpa, pe, &ts, 19);
	defer gpa.free(b);
	try testing.expectEqualSlices(u8, a, b);
	const lfanew = rd32(a, 0x3c);
	const opt = lfanew + 24;
	const sec = opt + rd16(a, lfanew + 20);
	const in_sec = rd32(pe, 0x3c) + 24 + rd16(pe, rd32(pe, 0x3c) + 20);
	for (0..2) |i| {
		const size = rd32(a, sec + 40 * i + 16);
		try testing.expectEqualSlices(u8, pe[rd32(pe, in_sec + 40 * i + 20)..][0..size], a[rd32(a, sec + 40 * i + 20)..][0..size]);
	}
	try testing.expect(rd32(a, opt + 60) <= rd32(a, sec + 12));
}

test "zstd layout rejects bad target names and patterns" {
	const gpa = testing.allocator;
	const pe = try fakePe(gpa);
	defer gpa.free(pe);
	try testing.expectError(error.InvalidPattern, packZstd(gpa, pe, &.{.{ .name = "linux-x86_64", .pattern = "a;b", .arch = .x86_64, .bytes = "x", .runtime_gz = "r" }}, 3));
	try testing.expectError(error.InvalidName, packZstd(gpa, pe, &.{.{ .name = "a b", .pattern = "Linux-x86_64", .arch = .x86_64, .bytes = "x", .runtime_gz = "r" }}, 3));
}
