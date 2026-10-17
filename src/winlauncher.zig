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
	putAscii(&cache, &ci, ".exe");
	if (ci >= cache.len) fail("rocosmo: path too long");
	cache[ci] = 0;
	const final: [*:0]const u16 = @ptrCast(&cache);

	// Rebuild only on a cache miss.
	const attrs = GetFileAttributesW(final);
	if (attrs == invalid_file_attributes or (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0) {
		rebuild(&self_path, idx_off, idx_len, target, &cache, dir_len, ci);
	}

	return start(final);
}

/// Decode the target entry from this container file and write it to the cache
/// atomically (temp file named with our PID, then MoveFileEx into place).
fn rebuild(self_path: [*]const u16, idx_off: u64, idx_len: u64, target: []const u8, cache: []u16, dir_len: usize, final_len: usize) void {
	const self = CreateFileW(@ptrCast(self_path), GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, 0, null);
	if (self == invalid_handle) fail("rocosmo: cannot open own file");
	defer _ = CloseHandle(self);

	// Determine the container length (the file pointer at end).
	var size: i64 = 0;
	if (SetFilePointerEx(self, 0, &size, 2) == 0) fail("rocosmo: cannot size own file"); // FILE_END = 2
	const container_len: u64 = @intCast(size);

	const idx = alloc(idx_len);
	if (!readAt(self, idx_off, idx)) fail("rocosmo: cannot read the container index");

	var plan: rt.Plan = undefined;
	if (rt.rocosmo_rt_plan_target(idx.ptr, idx.len, container_len, target.ptr, target.len, &plan) != .ok)
		fail("rocosmo: no Windows payload in this container");

	// Optional delta reference, decoded first.
	var ref: ?[]const u8 = null;
	if (plan.ref_kind != 0) {
		const rf = alloc(plan.ref_stored_len);
		if (!readAt(self, plan.ref_offset, rf)) fail("rocosmo: cannot read the payload reference");
		if (plan.ref_kind == 1) {
			ref = rf; // raw
		} else {
			const rb = alloc(plan.ref_content_len);
			if (rt.rocosmo_rt_decode(rf.ptr, rf.len, null, 0, rb.ptr, rb.len) != .ok) fail("rocosmo: cannot decode the payload reference");
			ref = rb;
		}
	}

	const frame = alloc(plan.stored_len);
	if (!readAt(self, plan.offset, frame)) fail("rocosmo: cannot read the Windows payload");
	const out = alloc(plan.content_len);
	const rp = if (ref) |r| r.ptr else null;
	const rl = if (ref) |r| r.len else 0;
	if (rt.rocosmo_rt_decode(frame.ptr, frame.len, rp, rl, out.ptr, out.len) != .ok)
		fail("rocosmo: cannot decode the Windows payload");

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

	const h = CreateFileW(@ptrCast(&tmp), GENERIC_WRITE, 0, null, CREATE_ALWAYS, 0, null);
	if (h == invalid_handle) fail("rocosmo: cannot create the cache file");
	var wrote_ok = true;
	var done: usize = 0;
	while (done < out.len) {
		var put: DWORD = 0;
		const want: DWORD = @intCast(@min(out.len - done, @as(usize, 1) << 30));
		if (WriteFile(h, out.ptr + done, want, &put, null) == 0 or put == 0) {
			wrote_ok = false;
			break;
		}
		done += put;
	}
	_ = CloseHandle(h);
	if (!wrote_ok) {
		_ = DeleteFileW(@ptrCast(&tmp));
		fail("rocosmo: cannot write the cache file");
	}
	if (MoveFileExW(@ptrCast(&tmp), @ptrCast(cache.ptr), MOVEFILE_REPLACE_EXISTING) == 0) {
		_ = DeleteFileW(@ptrCast(&tmp));
		// A concurrent launcher may have won the race and created it already.
		if (GetFileAttributesW(@ptrCast(cache.ptr)) == invalid_file_attributes) fail("rocosmo: cannot install the cache file");
	}
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
