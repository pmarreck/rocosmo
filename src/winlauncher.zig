//! rocosmo `--windows-launcher` front: a small, libc-free Windows x86_64
//! executable that imports only KERNEL32.DLL. The packer places it at the
//! front of a universal container instead of the app's own (large,
//! uncompressed) PE, and stores that PE as an ordinary compressed entry. At
//! run time this launcher rebuilds the app's executable into a per-user cache
//! and starts it, forwarding the command line, standard handles and exit code.
//!
//! It deliberately avoids the classic "dropper" shape where that is possible:
//! it writes one executable, named by the content hash of what the container
//! already holds, into the app's own cache folder, and runs that. The payload
//! and its reference are decoded by the same reviewed core the POSIX runtimes
//! use (rt_ffi.zig + the small zstd decoder); only the Windows I/O lives here.
//!
//! The container file layout beyond this PE (index and frames) is an "overlay"
//! the Windows loader does not map, so the launcher reads its own file to get
//! those bytes. The descriptor it reads (launcher_desc.zig) is patched into
//! this image by the packer and is therefore present in the loaded process.

const std = @import("std");
const d = @import("launcher_desc.zig");
const rt = @import("rt_ffi.zig");
const datatree = @import("datatree.zig");

// ---------------------------------------------------------------------------
// KERNEL32 only. Handles are opaque pointers; BOOL is a C int.

const HANDLE = ?*anyopaque;
const BOOL = i32;
const DWORD = u32;
const invalid_handle: HANDLE = @ptrFromInt(std.math.maxInt(usize));
const invalid_file_attributes: DWORD = 0xFFFF_FFFF;

extern "kernel32" fn GetModuleFileNameW(mod: ?*anyopaque, name: [*]u16, size: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: [*]u16, size: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetStdHandle(which: DWORD) callconv(.winapi) HANDLE;
extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: DWORD, written: ?*DWORD, ov: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: DWORD, share: DWORD, sa: ?*anyopaque, disp: DWORD, flags: DWORD, template: HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: DWORD, read: ?*DWORD, ov: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn SetFilePointerEx(h: HANDLE, dist: i64, new_pos: ?*i64, method: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) DWORD;
extern "kernel32" fn CreateDirectoryW(name: [*:0]const u16, sa: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn MoveFileExW(existing: [*:0]const u16, new: [*:0]const u16, flags: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn DeleteFileW(name: [*:0]const u16) callconv(.winapi) BOOL;
extern "kernel32" fn RemoveDirectoryW(name: [*:0]const u16) callconv(.winapi) BOOL;
extern "kernel32" fn GetProcessHeap() callconv(.winapi) HANDLE;
extern "kernel32" fn HeapAlloc(heap: HANDLE, flags: DWORD, n: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn HeapFree(heap: HANDLE, flags: DWORD, mem: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]u16;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (DWORD) callconv(.winapi) BOOL, add: BOOL) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetExitCodeProcess(h: HANDLE, code: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn ExitProcess(code: u32) callconv(.winapi) noreturn;

const GENERIC_READ: DWORD = 0x8000_0000;
const GENERIC_WRITE: DWORD = 0x4000_0000;
const FILE_SHARE_READ: DWORD = 0x1;
const OPEN_EXISTING: DWORD = 3;
const CREATE_NEW: DWORD = 1;
const CREATE_ALWAYS: DWORD = 2;
const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x10;
const FILE_BEGIN: DWORD = 0;
const MOVEFILE_REPLACE_EXISTING: DWORD = 0x1;
const STD_ERROR: DWORD = @bitCast(@as(i32, -12));
const STILL_ACTIVE: DWORD = 259;
const INFINITE: DWORD = 0xFFFF_FFFF;

const STARTUPINFOW = extern struct {
	cb: DWORD = @sizeOf(STARTUPINFOW),
	lpReserved: ?[*]u16 = null,
	lpDesktop: ?[*]u16 = null,
	lpTitle: ?[*]u16 = null,
	dwX: DWORD = 0,
	dwY: DWORD = 0,
	dwXSize: DWORD = 0,
	dwYSize: DWORD = 0,
	dwXCountChars: DWORD = 0,
	dwYCountChars: DWORD = 0,
	dwFillAttribute: DWORD = 0,
	dwFlags: DWORD = 0,
	wShowWindow: u16 = 0,
	cbReserved2: u16 = 0,
	lpReserved2: ?*u8 = null,
	hStdInput: HANDLE = null,
	hStdOutput: HANDLE = null,
	hStdError: HANDLE = null,
};
const PROCESS_INFORMATION = extern struct {
	hProcess: HANDLE = null,
	hThread: HANDLE = null,
	dwProcessId: DWORD = 0,
	dwThreadId: DWORD = 0,
};
extern "kernel32" fn CreateProcessW(
	app: ?[*:0]const u16,
    cmd: ?[*]u16,
    proc_attr: ?*anyopaque,
    thread_attr: ?*anyopaque,
    inherit: BOOL,
    flags: DWORD,
    env: ?*anyopaque,
    cwd: ?[*:0]const u16,
    si: *STARTUPINFOW,
    pi: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
// The descriptor, patched by the packer. Named section and exported so it is
// kept and findable; initialized with the magic the packer searches for.
export var rocosmo_launcher_descriptor: [d.size]u8 linksection(".rcsmdsc") = blk: {
	var b = [_]u8{0} ** d.size;
	@memcpy(b[0..d.magic.len], &d.magic);
	break :blk b;
};

// C symbols the core and the small zstd decoder need, over kernel32.
export fn malloc(n: usize) callconv(.c) ?*anyopaque {
	return HeapAlloc(GetProcessHeap(), 0, if (n == 0) 1 else n);
}
export fn free(p: ?*anyopaque) callconv(.c) void {
	if (p) |ptr| _ = HeapFree(GetProcessHeap(), 0, ptr);
}
const HEAP_ZERO_MEMORY: DWORD = 0x8;
export fn calloc(count: usize, size: usize) callconv(.c) ?*anyopaque {
	const n = std.math.mul(usize, count, size) catch return null;
	return HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, if (n == 0) 1 else n);
}
export fn rocosmo_zdec_fail() callconv(.c) noreturn {
	fail("rocosmo: container payload is corrupt");
}
comptime {
	@export(&memcpyImpl, .{ .name = "memcpy", .linkage = .weak });
	@export(&memmoveImpl, .{ .name = "memmove", .linkage = .weak });
	@export(&memsetImpl, .{ .name = "memset", .linkage = .weak });
	@export(&memcmpImpl, .{ .name = "memcmp", .linkage = .weak });
}
// Explicit loops, never @memcpy/@memset: the compiler lowers those to
// memcpy/memset libcalls, which would recurse into these very definitions.
fn memcpyImpl(dst: [*]u8, src: [*]const u8, n: usize) callconv(.c) [*]u8 {
	var i: usize = 0;
	while (i < n) : (i += 1) dst[i] = src[i];
	return dst;
}
fn memmoveImpl(dst: [*]u8, src: [*]const u8, n: usize) callconv(.c) [*]u8 {
	if (@intFromPtr(dst) < @intFromPtr(src)) {
		var i: usize = 0;
		while (i < n) : (i += 1) dst[i] = src[i];
	} else {
		var i = n;
		while (i > 0) {
			i -= 1;
			dst[i] = src[i];
		}
	}
	return dst;
}
fn memsetImpl(dst: [*]u8, c: c_int, n: usize) callconv(.c) [*]u8 {
	var i: usize = 0;
	while (i < n) : (i += 1) dst[i] = @truncate(@as(c_uint, @bitCast(c)));
	return dst;
}
fn memcmpImpl(a: [*]const u8, b: [*]const u8, n: usize) callconv(.c) c_int {
	for (a[0..n], b[0..n]) |x, y| if (x != y) return @as(c_int, x) - @as(c_int, y);
	return 0;
}

// ---------------------------------------------------------------------------

fn say(bytes: []const u8) void {
	var n: DWORD = 0;
	_ = WriteFile(GetStdHandle(STD_ERROR), bytes.ptr, @intCast(bytes.len), &n, null);
}
fn fail(msg: []const u8) noreturn {
	say(msg);
	say("\n");
	ExitProcess(120);
}

const heap: std.mem.Allocator = .{ .ptr = undefined, .vtable = &heap_vtable };
const heap_vtable: std.mem.Allocator.VTable = .{
	.alloc = struct {
		fn f(_: *anyopaque, n: usize, a: std.mem.Alignment, _: usize) ?[*]u8 {
			// HeapAlloc returns 16-byte-aligned blocks on x64.
			return if (a.toByteUnits() <= 16) @ptrCast(malloc(n)) else null;
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

/// Read `len` bytes of the open file at absolute `off` into `buf`.
fn readAt(h: HANDLE, off: u64, buf: []u8) bool {
	if (SetFilePointerEx(h, @bitCast(off), null, FILE_BEGIN) == 0) return false;
	var done: usize = 0;
	while (done < buf.len) {
		var got: DWORD = 0;
		const want: DWORD = @intCast(@min(buf.len - done, @as(usize, 1) << 30));
		if (ReadFile(h, buf.ptr + done, want, &got, null) == 0 or got == 0) return false;
		done += got;
	}
	return true;
}

fn alloc(n: usize) []u8 {
	const p = heap.alloc(u8, if (n == 0) 1 else n) catch fail("rocosmo: out of memory");
	return p[0..n];
}

/// Append ASCII `s` to a UTF-16 buffer at `*i` (widening each byte).
fn putAscii(buf: []u16, i: *usize, s: []const u8) void {
	for (s) |c| {
		if (i.* >= buf.len) fail("rocosmo: path too long");
		buf[i.*] = c;
		i.* += 1;
	}
}
fn putW(buf: []u16, i: *usize, s: []const u16) void {
	for (s) |c| {
		if (i.* >= buf.len) fail("rocosmo: path too long");
		buf[i.*] = c;
		i.* += 1;
	}
}

/// NUL-terminated ASCII length of a NUL-padded descriptor field.
fn fieldLen(bytes: []const u8) usize {
	return std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
}

fn run() u32 {
	const desc = &rocosmo_launcher_descriptor;
	const idx_off = std.mem.readInt(u64, desc[d.off_index_offset..][0..8], .little);
	const idx_len = std.mem.readInt(u64, desc[d.off_index_len..][0..8], .little);
	const target = desc[d.off_target..][0..fieldLen(desc[d.off_target..][0..d.name_max])];
	const hash = desc[d.off_hash..][0..16];
	const app_id = desc[d.off_app_id..][0..fieldLen(desc[d.off_app_id..][0..d.id_max])];
	if (idx_len == 0 or target.len == 0 or app_id.len == 0) fail("rocosmo: launcher was not packed (empty descriptor)");

	// This executable's own path.
	var self_path: [32768]u16 = undefined;
	const self_len = GetModuleFileNameW(null, &self_path, self_path.len);
	if (self_len == 0 or self_len >= self_path.len) fail("rocosmo: cannot find own path");

	// Cache path: %LOCALAPPDATA%\rocosmo\<app id>\<hash>.exe
	var cache: [32768]u16 = undefined;
	var ci: usize = 0;
	const base_len = GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"), &cache, cache.len);
	if (base_len == 0 or base_len >= cache.len) fail("rocosmo: LOCALAPPDATA is not set");
	ci = base_len;
	putAscii(&cache, &ci, "\\rocosmo");
	cache[ci] = 0;
	_ = CreateDirectoryW(@ptrCast(&cache), null); // ignore "already exists"
	putAscii(&cache, &ci, "\\");
	putAscii(&cache, &ci, app_id);
	cache[ci] = 0;
	_ = CreateDirectoryW(@ptrCast(&cache), null);
	const dir_len = ci;
	putAscii(&cache, &ci, "\\");
	putAscii(&cache, &ci, hash);
	// With a data tree the app is installed with it in <hash>\<name>.exe, so an
	// app that looks beside its own executable (Zig's lib\) finds the tree.
	const has_data = desc[d.off_flags] & d.flag_data != 0;
	const tree_dir_len = ci;
	if (has_data) {
		putAscii(&cache, &ci, "\\");
		putAscii(&cache, &ci, exeName(app_id));
	}
	putAscii(&cache, &ci, ".exe");
	if (ci >= cache.len) fail("rocosmo: path too long");
	cache[ci] = 0;
	const final: [*:0]const u16 = @ptrCast(&cache);

	// Rebuild only on a cache miss.
	const attrs = GetFileAttributesW(final);
	if (attrs == invalid_file_attributes or (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0) {
		if (has_data) installTree(&self_path, idx_off, idx_len, target, &cache, tree_dir_len, ci, exeName(app_id)) else rebuild(&self_path, idx_off, idx_len, target, &cache, dir_len, ci);
	}

	return start(final);
}

/// This container file, opened for reading, with its length and index.
const Container = struct { h: HANDLE, len: u64, idx: []u8 };

fn openContainer(self_path: [*]const u16, idx_off: u64, idx_len: u64) Container {
	const self = CreateFileW(@ptrCast(self_path), GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, 0, null);
	if (self == invalid_handle) fail("rocosmo: cannot open own file");
	// Determine the container length (the file pointer at end).
	var size: i64 = 0;
	if (SetFilePointerEx(self, 0, &size, 2) == 0) fail("rocosmo: cannot size own file"); // FILE_END = 2
	const idx = alloc(idx_len);
	if (!readAt(self, idx_off, idx)) fail("rocosmo: cannot read the container index");
	return .{ .h = self, .len = @intCast(size), .idx = idx };
}

/// Rebuild index entry `name` (its delta reference first, if any) into a new
/// heap buffer, through the same core the POSIX runtimes use.
fn decodeEntry(c: Container, name: []const u8, missing: []const u8) []u8 {
	var plan: rt.Plan = undefined;
	if (rt.rocosmo_rt_plan_target(c.idx.ptr, c.idx.len, c.len, name.ptr, name.len, &plan) != .ok) fail(missing);
	var ref: ?[]const u8 = null;
	if (plan.ref_kind != 0) {
		const rf = alloc(plan.ref_stored_len);
		if (!readAt(c.h, plan.ref_offset, rf)) fail("rocosmo: cannot read the payload reference");
		if (plan.ref_kind == 1) {
			ref = rf; // raw
		} else {
			const rb = alloc(plan.ref_content_len);
			if (rt.rocosmo_rt_decode(rf.ptr, rf.len, null, 0, rb.ptr, rb.len) != .ok) fail("rocosmo: cannot decode the payload reference");
			ref = rb;
		}
	}
	const frame = alloc(plan.stored_len);
	if (!readAt(c.h, plan.offset, frame)) fail("rocosmo: cannot read the container payload");
	const out = alloc(plan.content_len);
	const rp = if (ref) |r| r.ptr else null;
	const rl = if (ref) |r| r.len else 0;
	if (rt.rocosmo_rt_decode(frame.ptr, frame.len, rp, rl, out.ptr, out.len) != .ok)
		fail("rocosmo: cannot decode the container payload");
	return out;
}

/// Create `path` (which must not exist) holding `bytes`.
fn writeNew(path: [*:0]const u16, bytes: []const u8) bool {
	const h = CreateFileW(path, GENERIC_WRITE, 0, null, CREATE_NEW, 0, null);
	if (h == invalid_handle) return false;
	var ok = true;
	var done: usize = 0;
	while (done < bytes.len) {
		var put: DWORD = 0;
		const want: DWORD = @intCast(@min(bytes.len - done, @as(usize, 1) << 30));
		if (WriteFile(h, bytes.ptr + done, want, &put, null) == 0 or put == 0) {
			ok = false;
			break;
		}
		done += put;
	}
	if (CloseHandle(h) == 0) ok = false;
	return ok;
}

/// Decode the target entry from this container file and write it to the cache
/// atomically (temp file named with our PID, then MoveFileEx into place).
fn rebuild(self_path: [*]const u16, idx_off: u64, idx_len: u64, target: []const u8, cache: []u16, dir_len: usize, final_len: usize) void {
	const c = openContainer(self_path, idx_off, idx_len);
	defer _ = CloseHandle(c.h);
	const out = decodeEntry(c, target, "rocosmo: no Windows payload in this container");

	// Write to <hash>.exe.<pid>, then rename into place.
	var ti = final_len;
	var tmp: [32768]u16 = undefined;
	@memcpy(tmp[0..final_len], cache[0..final_len]);
	putAscii(&tmp, &ti, ".");
	var pid_buf: [10]u8 = undefined;
	putAscii(&tmp, &ti, std.fmt.bufPrint(&pid_buf, "{d}", .{GetCurrentProcessId()}) catch unreachable);
	if (ti >= tmp.len) fail("rocosmo: path too long");
	tmp[ti] = 0;
	_ = dir_len;

	if (!writeNew(@ptrCast(&tmp), out)) {
		_ = DeleteFileW(@ptrCast(&tmp));
		fail("rocosmo: cannot write the cache file");
	}
	if (MoveFileExW(@ptrCast(&tmp), @ptrCast(cache.ptr), MOVEFILE_REPLACE_EXISTING) == 0) {
		_ = DeleteFileW(@ptrCast(&tmp));
		// A concurrent launcher may have won the race and created it already.
		if (GetFileAttributesW(@ptrCast(cache.ptr)) == invalid_file_attributes) fail("rocosmo: cannot install the cache file");
	}
}

/// The installed executable's base name with a data tree: the app id's last
/// label (dev.rocosmo.zig -> zig), as the POSIX dispatcher names it.
fn exeName(app_id: []const u8) []const u8 {
	return app_id[(std.mem.lastIndexOfScalar(u8, app_id, '.') orelse return app_id) + 1 ..];
}

/// Append a data tree path (validated UTF-8, '/'-separated) as UTF-16 with
/// backslashes.
fn putTreePath(buf: []u16, i: *usize, path: []const u8) void {
	if (buf.len - i.* < path.len + 1) fail("rocosmo: path too long");
	const n = std.unicode.utf8ToUtf16Le(buf[i.*..], path) catch fail("rocosmo: data tree path is not UTF-8");
	for (buf[i.*..][0..n]) |*c| {
		if (c.* == '/') c.* = '\\';
	}
	i.* += n;
}

/// With a data tree: build `\\?\<cache>\<hash>.<pid>\` holding <name>.exe and
/// every file of the tree, then move the directory into place as <hash>, so
/// the app finds the tree beside itself. `\\?\` lifts the 260-character path
/// limit for the deep tree. The tree's paths were validated by the core walk
/// (relative, no . or .., no Windows-reserved characters).
fn installTree(self_path: [*]const u16, idx_off: u64, idx_len: u64, target: []const u8, cache: []u16, dir_len: usize, exe_len: usize, name: []const u8) void {
	const c = openContainer(self_path, idx_off, idx_len);
	defer _ = CloseHandle(c.h);
	const payload = decodeEntry(c, target, "rocosmo: no Windows payload in this container");
	const tree = decodeEntry(c, d.data_entry, "rocosmo: no data tree in this container");

	var tmp: [32768]u16 = undefined;
	var ti: usize = 0;
	putAscii(&tmp, &ti, "\\\\?\\");
	putW(&tmp, &ti, cache[0..dir_len]);
	putAscii(&tmp, &ti, ".");
	var pid_buf: [10]u8 = undefined;
	putAscii(&tmp, &ti, std.fmt.bufPrint(&pid_buf, "{d}", .{GetCurrentProcessId()}) catch unreachable);
	tmp[ti] = 0;
	const tmp_len = ti;
	if (CreateDirectoryW(@ptrCast(&tmp), null) == 0) fail("rocosmo: cannot create the install directory");

	var path: [32768]u16 = undefined;
	var pi: usize = 0;
	putW(&path, &pi, tmp[0..tmp_len]);
	putAscii(&path, &pi, "\\");
	putAscii(&path, &pi, name);
	putAscii(&path, &pi, ".exe");
	path[pi] = 0;
	if (!writeNew(@ptrCast(&path), payload)) failInstall(&tmp, tmp_len, tree, name, "rocosmo: cannot write the application");

	var it = datatree.Iterator.init(tree) catch failInstall(&tmp, tmp_len, tree, name, "rocosmo: data tree is malformed");
	var prev_dir: []const u8 = "";
	while (it.next() catch failInstall(&tmp, tmp_len, tree, name, "rocosmo: data tree is malformed")) |e| {
		pi = tmp_len;
		putAscii(&path, &pi, "\\");
		const rel_start = pi;
		putTreePath(&path, &pi, e.path);
		path[pi] = 0;
		// Parent directories, unless this file shares the previous one's.
		const dir = e.path[0 .. std.mem.lastIndexOfScalar(u8, e.path, '/') orelse 0];
		if (!std.mem.eql(u8, dir, prev_dir)) {
			var k = rel_start;
			while (k < pi) : (k += 1) if (path[k] == '\\') {
				path[k] = 0;
				_ = CreateDirectoryW(@ptrCast(&path), null); // exists: fine; real failures surface below
				path[k] = '\\';
			};
			prev_dir = dir;
		}
		if (!writeNew(@ptrCast(&path), e.bytes)) failInstall(&tmp, tmp_len, tree, name, "rocosmo: cannot write the data tree");
	}

	var final: [32768]u16 = undefined;
	var fi: usize = 0;
	putAscii(&final, &fi, "\\\\?\\");
	putW(&final, &fi, cache[0..dir_len]);
	final[fi] = 0;
	if (MoveFileExW(@ptrCast(&tmp), @ptrCast(&final), 0) == 0) {
		removeTree(&tmp, tmp_len, tree, name);
		// A concurrent launcher may have installed it first.
		cache[exe_len] = 0;
		if (GetFileAttributesW(@ptrCast(cache.ptr)) == invalid_file_attributes) fail("rocosmo: cannot install the application directory");
	}
}

fn failInstall(tmp: []u16, tmp_len: usize, tree: []const u8, name: []const u8, msg: []const u8) noreturn {
	removeTree(tmp, tmp_len, tree, name);
	fail(msg);
}

/// Best-effort removal of an unfinished install directory: the files we wrote
/// (the executable and the tree's entries), then every directory, deepest
/// first. Each directory is an ancestor of some file, so trying the ancestors
/// of each entry in order removes them all once they are empty.
fn removeTree(tmp: []u16, tmp_len: usize, tree: []const u8, name: []const u8) void {
	var path: [32768]u16 = undefined;
	var pi: usize = 0;
	putW(&path, &pi, tmp[0..tmp_len]);
	putAscii(&path, &pi, "\\");
	putAscii(&path, &pi, name);
	putAscii(&path, &pi, ".exe");
	path[pi] = 0;
	_ = DeleteFileW(@ptrCast(&path));
	for (0..2) |pass| {
		var it = datatree.Iterator.init(tree) catch break;
		while (it.next() catch null) |e| {
			pi = tmp_len;
			putAscii(&path, &pi, "\\");
			const rel_start = pi;
			putTreePath(&path, &pi, e.path);
			path[pi] = 0;
			if (pass == 0) {
				_ = DeleteFileW(@ptrCast(&path));
				continue;
			}
			var k = pi;
			while (k > rel_start) {
				k -= 1;
				if (path[k] != '\\') continue;
				path[k] = 0;
				_ = RemoveDirectoryW(@ptrCast(&path));
			}
		}
	}
	tmp[tmp_len] = 0;
	_ = RemoveDirectoryW(@ptrCast(tmp.ptr));
}

/// Ctrl-C handler: return TRUE so this launcher ignores the event and stays
/// alive to wait on the child, which receives the same event and handles it.
fn ctrlHandler(_: DWORD) callconv(.winapi) BOOL {
	return 1;
}

/// Start the cached executable, forwarding the command line and standard
/// handles, wait for it, and return its exit code.
fn start(final: [*:0]const u16) u32 {
	_ = SetConsoleCtrlHandler(&ctrlHandler, 1);
	var si: STARTUPINFOW = .{};
	var pi: PROCESS_INFORMATION = .{};
	// CreateProcessW may write to the command-line buffer, so copy it.
	const orig = GetCommandLineW();
	var n: usize = 0;
	while (orig[n] != 0) n += 1;
	const cmd = heap.alloc(u16, n + 1) catch fail("rocosmo: out of memory");
	@memcpy(cmd[0..n], orig[0..n]);
	cmd[n] = 0;
	if (CreateProcessW(final, cmd.ptr, null, null, 1, 0, null, null, &si, &pi) == 0)
		fail("rocosmo: cannot start the application");
	_ = WaitForSingleObject(pi.hProcess, INFINITE);
	var code: DWORD = STILL_ACTIVE;
	_ = GetExitCodeProcess(pi.hProcess, &code);
	_ = CloseHandle(pi.hThread);
	_ = CloseHandle(pi.hProcess);
	return code;
}

/// std.start provides mainCRTStartup (console subsystem) and calls this; we
/// exit with the child's code ourselves. A trivial panic handler keeps the
/// import table to KERNEL32 (no debug/stack-trace machinery).
pub fn main() void {
	ExitProcess(run());
}

pub const panic = std.debug.FullPanic(struct {
	fn p(_: []const u8, _: ?usize) noreturn {
		fail("rocosmo: launcher panic");
	}
}.p);
