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
const app_id = @import("app_id.zig");
const index = @import("index.zig");
const zenc = @import("zstd_encode.zig");

pub const Payload = struct {
	/// `uname -s`-`uname -m` case pattern, e.g. "Linux-x86_64|Linux-amd64".
	pattern: []const u8,
	bytes: []const u8,
};

pub const Arch = enum { x86_64, aarch64, arm, riscv64, powerpc64le, x86, loongarch64, s390x };

pub const Target = struct {
	/// Index name, e.g. "linux-x86_64"; also the runtime's target argument.
	name: []const u8,
	pattern: []const u8,
	arch: Arch,
	bytes: []const u8,
	/// gzip-compressed runtime executable for this OS/CPU.
	runtime_gz: []const u8,
};

pub const PackError = error{ NotPe, UnsupportedPe, HeadersOverflow, InvalidPattern, InvalidName, InvalidAppId, TooManyTargets, EncodeFailed, OutOfMemory };

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

/// Descriptor the `--windows-launcher` front PE carries, located by its magic
/// and filled in by `patchDescriptor` once the final layout is known. One
/// definition (launcher_desc.zig) is shared with the launcher that reads it.
const desc = @import("launcher_desc.zig");
pub const launcher_magic = desc.magic;
pub const desc_name_max = desc.name_max;
pub const desc_id_max = desc.id_max;
pub const Desc = struct {
	const off_index_offset = desc.off_index_offset;
	const off_index_len = desc.off_index_len;
	const off_target = desc.off_target;
	const off_hash = desc.off_hash;
	const off_app_id = desc.off_app_id;
	pub const size = desc.size;
};

/// Line 1 of the file, inside the DOS header bytes the Windows loader ignores
/// (only "MZ" at 0 and e_lfanew at 0x3c matter). It reads the script region
/// [0x40, e_lfanew) with dd and evals it, so a shell never parses line 2, which
/// holds e_lfanew's NUL bytes: NetBSD sh and OpenBSD ksh refuse any line with
/// a NUL. The block count is patched in by writeFront once e_lfanew is known.
const dos_line_head = "MZ=;eval \"$(dd if=\"$0\" bs=64 skip=1 count=";
const dos_count_width = 3; // up to 999 blocks: a 64 KB script
const dos_line_tail = " 2>/dev/null)\"\n";
/// POSIX-only format (no Windows target): a #!/bin/sh line, so a raw execve
/// runs the file too, then the same trampoline as line 2. The two lines need
/// more than 64 bytes, so this head is 128 and the script region starts there.
const posix_line_head = "#!/bin/sh\neval \"$(dd if=\"$0\" bs=64 skip=2 count=";
comptime {
	if (dos_line_head.len + dos_count_width + dos_line_tail.len > 0x3c) @compileError("line 1 overlaps e_lfanew");
	if (posix_line_head.len + dos_count_width + dos_line_tail.len > 0x80) @compileError("line 2 overlaps the script region");
}

/// universal: a Windows PE whose DOS stub area holds the dispatcher.
/// posix: a plain shell script, for containers without a Windows target.
const Format = enum {
	universal,
	posix,
	fn head(f: Format) []const u8 {
		return switch (f) {
			.universal => dos_line_head,
			.posix => posix_line_head,
		};
	}
	/// Offset of the evaluated script region (the trampoline's dd skip).
	fn start(f: Format) usize {
		return switch (f) {
			.universal => 0x40,
			.posix => 0x80,
		};
	}
};
const script_block = 64;
const script_start =
	"s=$(command -v \"$0\")||s=$0\n" ++
	// Cache home: $XDG_CACHE_HOME, else ~/Library/Caches on macOS, else ~/.cache.
	"c=${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/rocosmo\n" ++
	"[ -n \"$XDG_CACHE_HOME\" ]||[ \"$(uname -s)\" != Darwin ]||c=${HOME:-/tmp}/Library/Caches/rocosmo\n";
const case_start = "case $(uname -s)-$(uname -m) in\n";
const case_end =
	"*) echo \"$0: no payload for $(uname -s)-$(uname -m)\" >&2;exit 127;;\n" ++
	"esac\n";
/// Payloads live in $c/<app id>/<hash>; $d is this app's folder.
const cache_dir =
	"d=$c/$a f=$c/$a/$i\n" ++
	"if [ ! -x \"$f\" ];then\n" ++
	// Unwritable cache home: use a private per-user TMPDIR directory, verified
	// (not a symlink, owned by us) before anything in it is trusted or run.
	"if ! mkdir -p \"$d\" 2>/dev/null;then\n" ++
	"c=${TMPDIR:-/tmp}/rocosmo-$(id -u);d=$c/$a f=$c/$a/$i\n" ++
	"mkdir -m 700 \"$c\" 2>/dev/null\n" ++
	"[ -d \"$c\" ]&&[ ! -L \"$c\" ]&&[ -O \"$c\" ]&&mkdir -p \"$d\"||{ echo \"$0: no private writable cache directory\" >&2;exit 126;}\n" ++
	"fi\n" ++
	"fi\n";
// BSD dd treats count=0 as "until EOF", so never call dd with a zero count.
// Copies bytes [o, o+n) of the container to stdout.
const dd_range = "{ { [ $b = 0 ]||dd if=\"$s\" bs=4096 skip=$((o/4096)) count=$b;}&&{ [ $r = 0 ]||dd if=\"$s\" bs=1 skip=$((o+b*4096)) count=$r;};} 2>/dev/null";
/// Self-cleaning: after installing this payload, remove the app's other
/// finished entries (bare hashes). In-flight temp files (hash.pid) are left
/// alone, and other apps' folders are never touched.
const cleanup = "for e in \"$d\"/*;do case ${e##*/} in $i|*.*);;*)rm -f \"$e\";;esac;done\n";
/// z extracts on a miss. A concurrent run of another version of the same app
/// may clean our entry between install and exec, so check once more.
const exec_tail =
	"[ -x \"$f\" ]||z\n" ++
	"[ -x \"$f\" ]||z\n" ++
	"exec \"$f\" \"$@\"\n" ++
	"exit 127\n";
const script_tail = case_end ++ cache_dir ++
	"z(){ t=$f.$$ b=$((n/4096)) r=$((n%4096))\n" ++
	dd_range ++ " >\"$t\"&&chmod 755 \"$t\"&&mv -f \"$t\" \"$f\"||{ rm -f \"$t\";exit 126;}\n" ++
	cleanup ++ "}\n" ++ exec_tail;
/// zstd layout: o/n locate this OS/CPU's gzipped runtime, cached once per
/// machine as $c/runtime/$h and shared by all apps (rt unpacks it; not r,
/// which ksh predefines as an alias); it reads
/// the index at x/y and writes target $p to a temp file (z). On Linux the
/// runtime instead runs the payload from a memfd (--exec), so only the runtime
/// is cached; it re-runs the container with ROCOSMO_NO_MEMFD=1 to come back
/// to the cache path when that is impossible or the payload is too large.
/// The zstd layout embeds Zstandard decoder runtimes; this comment points
/// recipients at its BSD license (the full text ships in THIRD_PARTY_NOTICES.md).
const zstd_license_line = "# Contains Zstandard (BSD license): https://github.com/facebook/zstd/blob/dev/LICENSE\n";
const script_tail_zstd = case_end ++ zstd_license_line ++ cache_dir ++
	"rt(){ g=$c/runtime/$h\n" ++
	"[ -x \"$g\" ]&&return\n" ++
	"mkdir -p \"$c/runtime\";u=$g.$$ b=$((n/4096)) r=$((n%4096))\n" ++
	dd_range ++ "|gzip -dc >\"$u\"&&chmod 755 \"$u\"&&mv -f \"$u\" \"$g\"||{ rm -f \"$u\";echo \"$0: cannot unpack runtime\" >&2;exit 126;}\n" ++
	"}\n" ++
	"k(){ " ++ cleanup ++ "}\n" ++
	"z(){ rt;t=$f.$$\n" ++
	"\"$g\" \"$s\" $x $y $p \"$t\"&&chmod 755 \"$t\"&&mv -f \"$t\" \"$f\"||{ rm -f \"$t\";exit 126;}\n" ++
	"k;}\n" ++
	"[ -x \"$f\" ]||[ -n \"$ROCOSMO_NO_MEMFD\" ]||case $p in linux-*)rt;k;exec \"$g\" --exec \"$s\" $x $y $p \"$0\" \"$@\";;esac\n" ++
	exec_tail;

fn shortHash(bytes: []const u8) [16]u8 {
	var digest: [32]u8 = undefined;
	std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
	return std.fmt.bytesToHex(digest[0..8], .lower);
}

/// Trampoline prefix, cache-home logic and the app id (validated: safe as shell text).
fn writeStart(list: *std.ArrayList(u8), gpa: std.mem.Allocator, format: Format, id: []const u8) !void {
	try writePrefix(list, gpa, format);
	try list.appendSlice(gpa, script_start);
	try list.appendSlice(gpa, "a=");
	try list.appendSlice(gpa, id);
	try list.append(gpa, '\n');
}

/// The first 64 bytes: the trampoline line, padded. The universal format
/// ends them with e_lfanew, patched later.
fn writePrefix(list: *std.ArrayList(u8), gpa: std.mem.Allocator, format: Format) !void {
	try list.appendSlice(gpa, format.head());
	try list.appendNTimes(gpa, ' ', dos_count_width); // block count, patched by writeFront
	try list.appendSlice(gpa, dos_line_tail);
	switch (format) {
		.universal => {
			while (list.items.len < 0x3c) try list.append(gpa, ' ');
			try list.appendSlice(gpa, "\x00\x00\x00\x00");
		},
		.posix => while (list.items.len < Format.posix.start()) try list.append(gpa, ' '),
	}
}

/// Builds the shell dispatcher that sits in the DOS stub area. Numbers are
/// right-padded to a fixed width so the script length does not depend on them
/// (leading zeros would be octal in shell arithmetic).
fn writeScript(list: *std.ArrayList(u8), gpa: std.mem.Allocator, format: Format, id: []const u8, payloads: []const Payload, offsets: []const usize) !void {
	try writeStart(list, gpa, format, id);
	try list.appendSlice(gpa, case_start);
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

fn writeScriptZstd(list: *std.ArrayList(u8), gpa: std.mem.Allocator, format: Format, id: []const u8, targets: []const Target, rt_offsets: []const usize, idx_off: usize, idx_len: usize) !void {
	try writeStart(list, gpa, format, id);
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

/// Where the script region ends and, in the universal format, where the
/// relocated PE headers and body land after a script of `script_len`.
const Header = struct { script_end: usize, soh: usize, body_end: usize };

fn headerLayout(pe_info: ?PeInfo, pe_len: usize, script_len: usize) PackError!Header {
	// Whole 64-byte blocks, so the trampoline's dd reads exactly the script region.
	const script_end = alignUp(script_len, script_block);
	const format: Format = if (pe_info == null) .posix else .universal;
	if ((script_end - format.start()) / script_block >= std.math.pow(usize, 10, dos_count_width)) return error.HeadersOverflow;
	const info = pe_info orelse return .{ .script_end = script_end, .soh = script_end, .body_end = script_end };
	const lfanew = script_end;
	const hdr_len = 24 + info.opt_size + 40 * info.nsec;
	const soh = @max(alignUp(lfanew + hdr_len, info.file_align), info.soh);
	if (soh > info.min_va) return error.HeadersOverflow;
	return .{ .script_end = script_end, .soh = soh, .body_end = soh + (pe_len - info.soh) };
}

/// Writes [script][relocated PE headers][PE body] into the front of `out`.
/// The Windows loader reads only e_magic and e_lfanew from the DOS header, so
/// the DOS stub region carries the POSIX shell dispatcher instead. Without a
/// PE (POSIX-only format) only the script is written.
fn writeFront(out: []u8, pe_in: ?[]const u8, pe_info: ?PeInfo, script: []const u8, h: Header) void {
	const format: Format = if (pe_in == null) .posix else .universal;
	@memcpy(out[0..script.len], script);
	@memset(out[script.len..h.script_end], '\n');
	_ = std.fmt.bufPrint(out[format.head().len..][0..dos_count_width], "{d}", .{(h.script_end - format.start()) / script_block}) catch unreachable;
	const pe = pe_in orelse return;
	const info = pe_info.?;
	const hdr_len = 24 + info.opt_size + 40 * info.nsec;
	const delta = h.soh - info.soh;
	const lfanew = h.script_end;
	wr32(out, 0x3c, lfanew);
	@memcpy(out[lfanew..][0..hdr_len], pe[info.lfanew..][0..hdr_len]);
	@memcpy(out[h.soh..h.body_end], pe[info.soh..]);

	const opt = lfanew + 24;
	const sec = opt + info.opt_size;
	wr32(out, opt + 60, h.soh); // SizeOfHeaders
	wr32(out, opt + 64, 0); // CheckSum: not required for executables
	bump32(out, lfanew + 12, delta); // PointerToSymbolTable
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
/// `pe` null selects the POSIX-only format: [#!/bin/sh script][aligned payloads].
pub fn pack(gpa: std.mem.Allocator, pe: ?[]const u8, payloads: []const Payload, id: []const u8) PackError![]u8 {
	const info: ?PeInfo = if (pe) |p| try parsePe(p) else null;
	const format: Format = if (pe == null) .posix else .universal;
	if (!app_id.valid(id)) return error.InvalidAppId;
	for (payloads) |p| if (!validPattern(p.pattern)) return error.InvalidPattern;
	const offsets = try gpa.alloc(usize, payloads.len);
	defer gpa.free(offsets);
	@memset(offsets, 0);

	var probe: std.ArrayList(u8) = .empty;
	defer probe.deinit(gpa);
	try writeScript(&probe, gpa, format, id, payloads, offsets);
	const h = try headerLayout(info, if (pe) |p| p.len else 0, probe.items.len);

	var cursor = alignUp(h.body_end, payload_align);
	for (payloads, offsets) |p, *off| {
		off.* = cursor;
		cursor = alignUp(cursor + p.bytes.len, payload_align);
	}
	const total = if (payloads.len == 0) h.body_end else offsets[payloads.len - 1] + payloads[payloads.len - 1].bytes.len;

	var script: std.ArrayList(u8) = .empty;
	defer script.deinit(gpa);
	try writeScript(&script, gpa, format, id, payloads, offsets);
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
/// Output: [script][PE][runtimes][index][frames]; only the runtimes, which the
/// shell copies with dd, are 4 KiB aligned. `pe` null selects the POSIX-only
/// format: no PE, and index entry 0 (the PE body) is empty and never referenced.
pub fn packZstd(gpa: std.mem.Allocator, pe: ?[]const u8, targets: []const Target, level: i32, id: []const u8) PackError![]u8 {
	return packZstdImpl(gpa, pe, targets, level, id, null);
}

/// `--windows-launcher` variant: the front PE is a small launcher (not the
/// app), so the app's own Windows executable is stored as an ordinary
/// compressed target entry named `win_name` and rebuilt on first run. The
/// launcher's body is never offered as a delta reference, and its embedded
/// descriptor is patched with the index location and that entry's name, cache
/// hash and app id. `win_name` must name one of `targets`.
pub fn packZstdLauncher(gpa: std.mem.Allocator, launcher: []const u8, targets: []const Target, level: i32, id: []const u8, win_name: []const u8) PackError![]u8 {
	var found = false;
	for (targets) |t| if (std.mem.eql(u8, t.name, win_name)) {
		found = true;
	};
	if (!found) return error.InvalidName;
	return packZstdImpl(gpa, launcher, targets, level, id, win_name);
}

fn packZstdImpl(gpa: std.mem.Allocator, pe: ?[]const u8, targets: []const Target, level: i32, id: []const u8, win_name: ?[]const u8) PackError![]u8 {
	const info: ?PeInfo = if (pe) |p| try parsePe(p) else null;
	const format: Format = if (pe == null) .posix else .universal;
	const is_launcher = win_name != null;
	if (!app_id.valid(id)) return error.InvalidAppId;
	for (targets) |t| {
		if (!validPattern(t.pattern)) return error.InvalidPattern;
		if (!index.validName(t.name) or std.mem.eql(u8, t.name, pe_body_name)) return error.InvalidName;
	}
	const n = targets.len;
	if (n > layout.max_targets) return error.TooManyTargets;
	// The launcher front is not the app, so its body is never a delta reference.
	const body: []const u8 = if (pe != null and !is_launcher) pe.?[info.?.soh..] else &.{};
	const pe_ref_usable = pe != null and !is_launcher;

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
			const usable = if (r == n) pe_ref_usable and t.arch == .x86_64 else (r != ti and targets[r].arch == t.arch);
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
	try writeScriptZstd(&probe, gpa, format, id, targets, rt_offsets, 0, idx_len);
	const h = try headerLayout(info, if (pe) |p| p.len else 0, probe.items.len);

	// Only the runtime blobs are aligned: the shell copies them with 4 KiB dd
	// blocks. The runtime preads the index and frames, so those pack tightly.
	var cursor = h.body_end;
	for (targets, rt_offsets) |t, *off| {
		off.* = alignUp(cursor, payload_align);
		cursor = off.* + t.runtime_gz.len;
	}
	const idx_off = cursor;
	cursor += idx_len;
	const frame_offsets = try gpa.alloc(usize, n);
	defer gpa.free(frame_offsets);
	for (chosen, frame_offsets) |f, *off| {
		off.* = cursor;
		cursor += f.len;
	}
	const total = cursor;

	fillEntries(entries, targets, plan.choice, chosen, body.len, h.soh, 1, frame_offsets);
	const idx = index.encode(gpa, entries) catch |e| return mapIdx(e);
	defer gpa.free(idx);
	std.debug.assert(idx.len == idx_len);
	var script: std.ArrayList(u8) = .empty;
	defer script.deinit(gpa);
	try writeScriptZstd(&script, gpa, format, id, targets, rt_offsets, idx_off, idx_len);
	std.debug.assert(script.items.len == probe.items.len);

	const out = try gpa.alloc(u8, total);
	errdefer gpa.free(out);
	@memset(out, 0);
	writeFront(out, pe, info, script.items, h);
	for (targets, rt_offsets) |t, off| @memcpy(out[off..][0..t.runtime_gz.len], t.runtime_gz);
	@memcpy(out[idx_off..][0..idx_len], idx);
	for (chosen, frame_offsets) |f, off| @memcpy(out[off..][0..f.len], f);
	if (win_name) |name| {
		for (targets) |t| if (std.mem.eql(u8, t.name, name)) {
			try patchDescriptor(out, idx_off, idx_len, name, &shortHash(t.bytes), id);
		};
	}
	return out;
}

/// Fill the launcher's descriptor in the finished container: find its magic in
/// the (verbatim) launcher body and write the index location plus the app
/// entry's name, cache hash and app id, so the launcher can rebuild it.
fn patchDescriptor(out: []u8, idx_off: usize, idx_len: usize, name: []const u8, hash: []const u8, id: []const u8) PackError!void {
	const at = std.mem.indexOf(u8, out, &launcher_magic) orelse return error.UnsupportedPe;
	if (name.len > desc_name_max or id.len > desc_id_max or hash.len != 16) return error.InvalidName;
	const d = out[at..][0..Desc.size];
	std.mem.writeInt(u64, d[Desc.off_index_offset..][0..8], idx_off, .little);
	std.mem.writeInt(u64, d[Desc.off_index_len..][0..8], idx_len, .little);
	@memset(d[Desc.off_target..][0..desc_name_max], 0);
	@memcpy(d[Desc.off_target..][0..name.len], name);
	@memcpy(d[Desc.off_hash..][0..16], hash);
	@memset(d[Desc.off_app_id..][0..desc_id_max], 0);
	@memcpy(d[Desc.off_app_id..][0..id.len], id);
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
const test_id = "dev.rocosmo.test";

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

/// The evaluated script region [start, end), read from the trampoline's
/// `dd bs=64 skip=S count=N` in the first 128 bytes (both formats).
fn scriptRegion(out: []const u8) struct { start: usize, end: usize } {
	const head = out[0..@min(out.len, 0x80)];
	const at = std.mem.indexOf(u8, head, "bs=64 skip=") orelse return .{ .start = 0, .end = 0 };
	const skip = std.fmt.parseInt(usize, std.mem.sliceTo(head[at + 11 ..], ' '), 10) catch return .{ .start = 0, .end = 0 };
	const c = std.mem.indexOfPos(u8, head, at, "count=") orelse return .{ .start = 0, .end = 0 };
	const count = std.fmt.parseInt(usize, std.mem.sliceTo(head[c + 6 ..], ' '), 10) catch return .{ .start = 0, .end = 0 };
	return .{ .start = 64 * skip, .end = 64 * (skip + count) };
}

fn scriptEnd(out: []const u8) usize {
	return scriptRegion(out).end;
}

/// Independent reading of the shell entry. Universal format: line 1 must end
/// inside the DOS header's free bytes (before e_lfanew at 0x3c), hold no NUL,
/// and dd exactly the NUL-free script region [0x40, e_lfanew) for eval, so
/// shells that reject NUL bytes (NetBSD sh, OpenBSD ksh) never read e_lfanew's
/// zero bytes. POSIX-only format: line 1 is "#!/bin/sh" and line 2, inside
/// the NUL-free first 128 bytes, evals the region [0x80, end).
fn expectTrampoline(out: []const u8) !void {
	const r = scriptRegion(out);
	try testing.expect(r.end > r.start);
	try testing.expect(std.mem.indexOfScalar(u8, out[0..0x3c], 0) == null);
	if (std.mem.startsWith(u8, out, "MZ")) {
		const nl = std.mem.indexOfScalar(u8, out[0..0x3c], '\n') orelse return error.TestLineOneTooLong;
		try testing.expect(std.mem.indexOf(u8, out[0..nl], "bs=64 skip=1 count=") != null);
		try testing.expectEqual(@as(usize, rd32(out, 0x3c)), r.end);
	} else {
		try testing.expect(std.mem.startsWith(u8, out, "#!/bin/sh\n"));
		const nl = std.mem.indexOfScalarPos(u8, out[0..0x80], 10, '\n') orelse return error.TestLineTwoTooLong;
		try testing.expect(std.mem.startsWith(u8, out[10..nl], "eval "));
		try testing.expect(std.mem.indexOf(u8, out[10..nl], "bs=64 skip=2 count=") != null);
		try testing.expect(std.mem.indexOfScalar(u8, out[0..0x80], 0) == null);
	}
	const script = out[r.start..r.end];
	try testing.expect(std.mem.indexOfScalar(u8, script, 0) == null);
	try testing.expect(std.mem.indexOf(u8, script, "exit 127\n") != null);
}

/// ksh (pdksh, mksh) predefines these aliases; a dispatcher function with one
/// of these names is rewritten by alias expansion before it is defined.
const ksh_aliases = [_][]const u8{ "autoload", "command", "fc", "functions", "hash", "history", "integer", "local", "login", "nohup", "r", "stop", "suspend", "type" };

fn expectNoAliasedFunctions(out: []const u8) !void {
	const script = out[scriptRegion(out).start..scriptEnd(out)];
	var defined: usize = 0;
	var lines = std.mem.splitScalar(u8, script, '\n');
	while (lines.next()) |l| {
		const paren = std.mem.indexOf(u8, l, "(){") orelse continue;
		defined += 1;
		for (ksh_aliases) |a| try testing.expect(!std.mem.eql(u8, l[0..paren], a));
	}
	try testing.expect(defined > 0);
}

test "line 1 is a NUL-free trampoline that evals exactly the script region" {
	const gpa = testing.allocator;
	const pe = try fakePe(gpa);
	defer gpa.free(pe);
	const out = try pack(gpa, pe, &.{.{ .pattern = "Linux-x86_64", .bytes = "abc" }}, test_id);
	defer gpa.free(out);
	try expectTrampoline(out);
	try expectNoAliasedFunctions(out);
}

test "e_lfanew locates a PE header whose sections hold the original bytes" {
	const gpa = testing.allocator;
	const pe = try fakePe(gpa);
	defer gpa.free(pe);
	const out = try pack(gpa, pe, &.{}, test_id);
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

/// Parse "pattern) ... off=N len=M" lines back out of the script: an
/// independent reading of what the shell will execute.
fn scriptEntry(out: []const u8, pattern: []const u8) ?struct { off: usize, len: usize } {
	const end = scriptEnd(out);
	const text = out[0..end];
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
	const out = try pack(gpa, pe, &payloads, test_id);
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
	const a = try pack(gpa, pe, &.{.{ .pattern = "Linux-x86_64", .bytes = "one" }}, test_id);
	defer gpa.free(a);
	const b = try pack(gpa, pe, &.{.{ .pattern = "Linux-x86_64", .bytes = "one" }}, test_id);
	defer gpa.free(b);
	const c = try pack(gpa, pe, &.{.{ .pattern = "Linux-x86_64", .bytes = "two" }}, test_id);
	defer gpa.free(c);
	try testing.expectEqualSlices(u8, a, b);
	const ia = std.mem.indexOf(u8, a, "i=").?;
	const ic = std.mem.indexOf(u8, c, "i=").?;
	try testing.expect(!std.mem.eql(u8, a[ia..][0..18], c[ic..][0..18]));
}

test "rejects non-PE input and PE32 (non-plus) images" {
	const gpa = testing.allocator;
	try testing.expectError(error.NotPe, pack(gpa, "not a pe at all, definitely not", &.{}, test_id));
	const pe = try fakePe(gpa);
	defer gpa.free(pe);
	std.mem.writeInt(u16, pe[0x80 + 24 ..][0..2], 0x10b, .little);
	try testing.expectError(error.UnsupportedPe, pack(gpa, pe, &.{}, test_id));
}

test "fails rather than overlapping headers with the first section" {
	const gpa = testing.allocator;
	const pe = try fakePe(gpa);
	defer gpa.free(pe);
	var many: [200]Payload = undefined;
	for (&many) |*p| p.* = .{ .pattern = "Some-Very-Long-Pattern-To-Bloat-The-Script", .bytes = "x" };
	try testing.expectError(error.HeadersOverflow, pack(gpa, pe, &many, test_id));
}

test "pattern validation classifies a set of candidate patterns" {
	const accepted = [_][]const u8{ "Linux-x86_64", "Linux-x86_64|Linux-amd64", "Darwin-arm64", "FreeBSD-amd64", "a.b_c-d" };
	const rejected = [_][]const u8{ "", "|", "Linux-x86_64|", "|Linux", "a||b", "Linux*", "a b", "a;b", "$(x)", "a`b`", "a'b", "a\"b", "a\nb", "a)b", "a\\b", "a?b", "[a]" };
	for (accepted) |p| try testing.expect(validPattern(p));
	for (rejected) |p| try testing.expect(!validPattern(p));
	const gpa = testing.allocator;
	const pe = try fakePe(gpa);
	defer gpa.free(pe);
	try testing.expectError(error.InvalidPattern, pack(gpa, pe, &.{.{ .pattern = "x) rm -rf ~;;", .bytes = "" }}, test_id));
}

// ---------------------------------------------------------------------------
// zstd layout. The oracle is again the input: an independent reader parses
// the script and index, decodes with zstd and must reproduce every target.

const zdec = @import("zstd_decode.zig");

/// Value of `key=` on the script line that starts with `pattern`.
fn scriptField(out: []const u8, pattern: []const u8, key: []const u8) ?[]const u8 {
	const text = out[0..scriptEnd(out)];
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
	const text = out[0..scriptEnd(out)];
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
	const out = try packZstd(gpa, pe, &ts, 19, test_id);
	defer gpa.free(out);
	try expectTrampoline(out);
	try expectNoAliasedFunctions(out);
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
	const out = try packZstd(gpa, pe, &ts, 19, test_id);
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

test "zstd layout pads only the runtime blobs the shell copies with dd" {
	const gpa = testing.allocator;
	const pe = try fakePe(gpa);
	defer gpa.free(pe);
	const z = try ZTest.init(gpa);
	defer z.deinit(gpa);
	const ts = z.targets();
	const out = try packZstd(gpa, pe, &ts, 19, test_id);
	defer gpa.free(out);
	// The index follows the last runtime blob directly.
	var rt_end: usize = 0;
	for (ts) |t| {
		const o = try std.fmt.parseInt(usize, scriptField(out, t.pattern, "o").?, 10);
		rt_end = @max(rt_end, o + t.runtime_gz.len);
	}
	const x = scriptGlobal(out, "x").?;
	const y = scriptGlobal(out, "y").?;
	try testing.expectEqual(rt_end, x);
	// The runtime preads the frames, so they follow the index and each other with no gap.
	const entries = try index.decode(gpa, out[x..][0..y], out.len);
	defer gpa.free(entries);
	var cursor: usize = x + y;
	for (entries[1..]) |e| {
		try testing.expectEqual(cursor, e.offset);
		cursor += e.stored_len;
	}
	try testing.expectEqual(out.len, cursor);
}

test "zstd layout keeps the PE sections intact and is deterministic" {
	const gpa = testing.allocator;
	const pe = try fakePe(gpa);
	defer gpa.free(pe);
	const z = try ZTest.init(gpa);
	defer z.deinit(gpa);
	const ts = z.targets();
	const a = try packZstd(gpa, pe, &ts, 19, test_id);
	defer gpa.free(a);
	const b = try packZstd(gpa, pe, &ts, 19, test_id);
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
	try testing.expectError(error.InvalidPattern, packZstd(gpa, pe, &.{.{ .name = "linux-x86_64", .pattern = "a;b", .arch = .x86_64, .bytes = "x", .runtime_gz = "r" }}, 3, test_id));
	try testing.expectError(error.InvalidName, packZstd(gpa, pe, &.{.{ .name = "a b", .pattern = "Linux-x86_64", .arch = .x86_64, .bytes = "x", .runtime_gz = "r" }}, 3, test_id));
}

test "the script names the app id, and an invalid id is refused before packing" {
	const gpa = testing.allocator;
	const pe = try fakePe(gpa);
	defer gpa.free(pe);
	const out = try pack(gpa, pe, &.{.{ .pattern = "Linux-x86_64", .bytes = "abc" }}, "llc.mecha.validate");
	defer gpa.free(out);
	try testing.expect(std.mem.indexOf(u8, out[0..scriptEnd(out)], "\na=llc.mecha.validate\n") != null);
	for ([_][]const u8{ "", "app", "a.b;x", "A.B", "a b.c", "a.b$(id)" }) |bad| {
		try testing.expectError(error.InvalidAppId, pack(gpa, pe, &.{}, bad));
		try testing.expectError(error.InvalidAppId, packZstd(gpa, pe, &.{}, 3, bad));
	}
}

// ---------------------------------------------------------------------------
// POSIX-only format: no Windows target, so no PE. The file is a #!/bin/sh
// script, which lets a raw execve run it with no ENOEXEC fallback.

test "POSIX-only raw layout is a #!/bin/sh script with every payload stored byte-for-byte" {
	const gpa = testing.allocator;
	var big: [10000]u8 = undefined;
	for (&big, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
	const payloads = [_]Payload{
		.{ .pattern = "Linux-x86_64|Linux-amd64", .bytes = &big },
		.{ .pattern = "Darwin-arm64", .bytes = "tiny" },
	};
	const out = try pack(gpa, null, &payloads, test_id);
	defer gpa.free(out);
	try expectTrampoline(out);
	try expectNoAliasedFunctions(out);
	try testing.expect(std.mem.indexOf(u8, out[0..scriptEnd(out)], "MZ") == null);
	for (payloads) |p| {
		const e = scriptEntry(out, p.pattern) orelse return error.TestMissingEntry;
		try testing.expectEqualSlices(u8, p.bytes, out[e.off..][0..e.len]);
		try testing.expect(e.off % 4096 == 0);
	}
}

test "POSIX-only zstd layout rebuilds every target byte-exact and references no PE body" {
	const gpa = testing.allocator;
	const z = try ZTest.init(gpa);
	defer z.deinit(gpa);
	const ts = z.targets();
	const out = try packZstd(gpa, null, &ts, 19, test_id);
	defer gpa.free(out);
	try expectTrampoline(out);
	try expectNoAliasedFunctions(out);
	for (ts) |t| {
		const got = try rebuild(gpa, out, t.name);
		defer gpa.free(got);
		try testing.expectEqualSlices(u8, t.bytes, got);
	}
	const entries = try index.decode(gpa, out[scriptGlobal(out, "x").?..][0..scriptGlobal(out, "y").?], out.len);
	defer gpa.free(entries);
	try testing.expectEqual(@as(usize, 0), entries[0].stored_len);
	for (entries[1..]) |e| try testing.expect(e.ref == null or e.ref.? != 0);
}

/// A fake launcher PE: the shape of fakePe, with the launcher magic and a
/// zeroed descriptor at the start of the first section's body, where the
/// packer will find and patch it (the body is copied verbatim into the output).
fn fakeLauncherPe(gpa: std.mem.Allocator) ![]u8 {
	const pe = try fakePe(gpa);
	const info = try parsePe(pe);
	@memcpy(pe[info.soh..][0..launcher_magic.len], &launcher_magic);
	@memset(pe[info.soh + launcher_magic.len ..][0 .. Desc.size - launcher_magic.len], 0);
	return pe;
}

fn descField(out: []const u8, comptime off: usize, len: usize) []const u8 {
	const at = std.mem.indexOf(u8, out, &launcher_magic).?;
	return std.mem.sliceTo(out[at + off ..][0..len], 0);
}

test "windows launcher: app PE stored compressed, launcher at the front, descriptor patched" {
	const gpa = testing.allocator;
	const launcher = try fakeLauncherPe(gpa);
	defer gpa.free(launcher);
	const app = try fakePe(gpa); // the app's real Windows executable
	defer gpa.free(app);
	const z = try ZTest.init(gpa);
	defer z.deinit(gpa);
	const ts = [_]Target{
		.{ .name = "windows-x86_64", .pattern = "Windows-x86_64", .arch = .x86_64, .bytes = app, .runtime_gz = "" },
		.{ .name = "linux-x86_64", .pattern = "Linux-x86_64", .arch = .x86_64, .bytes = z.x64, .runtime_gz = "rt1" },
		.{ .name = "linux-aarch64", .pattern = "Linux-aarch64", .arch = .aarch64, .bytes = z.arm, .runtime_gz = "rt2" },
	};
	const out = try packZstdLauncher(gpa, launcher, &ts, 19, test_id, "windows-x86_64");
	defer gpa.free(out);

	// The front is a universal polyglot built from the launcher, not the app.
	try expectTrampoline(out);
	try testing.expect(std.mem.startsWith(u8, out, "MZ"));

	// The app's Windows executable rebuilds byte-for-byte from the container.
	const got = try rebuild(gpa, out, "windows-x86_64");
	defer gpa.free(got);
	try testing.expectEqualSlices(u8, app, got);

	// It is stored compressed (a frame or delta), never raw at the front.
	const entries = try index.decode(gpa, out[scriptGlobal(out, "x").?..][0..scriptGlobal(out, "y").?], out.len);
	defer gpa.free(entries);
	for (entries) |e| if (std.mem.eql(u8, e.name, "windows-x86_64")) {
		try testing.expect(e.kind != .raw);
		try testing.expect(e.stored_len < app.len);
	};

	// The descriptor names the index location, the entry, its hash and the app id.
	const at = std.mem.indexOf(u8, out, &launcher_magic).?;
	try testing.expectEqual(scriptGlobal(out, "x").?, std.mem.readInt(u64, out[at + Desc.off_index_offset ..][0..8], .little));
	try testing.expectEqual(scriptGlobal(out, "y").?, std.mem.readInt(u64, out[at + Desc.off_index_len ..][0..8], .little));
	try testing.expectEqualStrings("windows-x86_64", descField(out, Desc.off_target, desc_name_max));
	try testing.expectEqualStrings(&shortHash(app), out[at + Desc.off_hash ..][0..16]);
	try testing.expectEqualStrings(test_id, descField(out, Desc.off_app_id, desc_id_max));
}

test "windows launcher: win_name must name a target, and the launcher body is never a delta reference" {
	const gpa = testing.allocator;
	const launcher = try fakeLauncherPe(gpa);
	defer gpa.free(launcher);
	const z = try ZTest.init(gpa);
	defer z.deinit(gpa);
	const ts = z.targets();
	try testing.expectError(error.InvalidName, packZstdLauncher(gpa, launcher, &ts, 3, test_id, "windows-x86_64"));
	// No entry references entry 0 (the launcher body), which stores nothing.
	const out = try packZstdLauncher(gpa, launcher, &ts, 3, test_id, "linux-x86_64");
	defer gpa.free(out);
	const entries = try index.decode(gpa, out[scriptGlobal(out, "x").?..][0..scriptGlobal(out, "y").?], out.len);
	defer gpa.free(entries);
	try testing.expectEqual(@as(usize, 0), entries[0].stored_len);
	for (entries[1..]) |e| try testing.expect(e.ref == null or e.ref.? != 0);
}

test "zstd containers name Zstandard's license in the script; raw containers do not" {
	const gpa = testing.allocator;
	const pe = try fakePe(gpa);
	defer gpa.free(pe);
	const z = try ZTest.init(gpa);
	defer z.deinit(gpa);
	const ts = z.targets();
	for ([_]?[]const u8{ pe, null }) |maybe_pe| {
		const zo = try packZstd(gpa, maybe_pe, &ts, 3, test_id);
		defer gpa.free(zo);
		const r = scriptRegion(zo);
		try testing.expect(std.mem.indexOf(u8, zo[r.start..r.end], zstd_license_line) != null);
		const raw = try pack(gpa, maybe_pe, &.{.{ .pattern = "Linux-x86_64", .bytes = "abc" }}, test_id);
		defer gpa.free(raw);
		try testing.expect(std.mem.indexOf(u8, raw, "zstd") == null);
	}
}
