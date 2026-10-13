//! libc-free Roc host for the P2 probe. One source, compiled per target as a
//! single object: Linux talks to the kernel with raw syscalls, macOS calls only
//! libSystem (Apple's stable OS interface), and Windows calls only kernel32.
//! It implements Roc's symbol-ABI runtime functions, the hosted function, an
//! entry point, decimal argument parsing and output.

const std = @import("std");
const builtin = @import("builtin");
const os = builtin.os.tag;

// ---------------------------------------------------------------------------
// OS interface: page allocation, write to stdout/stderr, exit.

const linux = std.os.linux;

const darwin = struct {
	extern "c" fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, off: i64) callconv(.c) *anyopaque;
	extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) callconv(.c) isize;
	extern "c" fn exit(code: c_int) callconv(.c) noreturn;
	const PROT_RW = 0x1 | 0x2;
	const MAP_PRIVATE_ANON = 0x0002 | 0x1000;
};

const win = struct {
	const HANDLE = ?*anyopaque;
	extern "kernel32" fn VirtualAlloc(addr: ?*anyopaque, size: usize, kind: u32, protect: u32) callconv(.winapi) ?*anyopaque;
	extern "kernel32" fn GetStdHandle(which: u32) callconv(.winapi) HANDLE;
	extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: u32, written: ?*u32, overlapped: ?*anyopaque) callconv(.winapi) c_int;
	extern "kernel32" fn ExitProcess(code: u32) callconv(.winapi) noreturn;
	extern "kernel32" fn GetCommandLineA() callconv(.winapi) [*:0]const u8;
	const MEM_COMMIT_RESERVE = 0x1000 | 0x2000;
	const PAGE_READWRITE = 0x04;
	const STD_OUTPUT = @as(u32, @bitCast(@as(i32, -11)));
	const STD_ERROR = @as(u32, @bitCast(@as(i32, -12)));
};

fn osPages(len: usize) ?[*]u8 {
	switch (os) {
		.linux => {
			const r = linux.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
			if (@as(isize, @bitCast(r)) < 0) return null;
			return @ptrFromInt(r);
		},
		.macos => {
			const p = darwin.mmap(null, len, darwin.PROT_RW, darwin.MAP_PRIVATE_ANON, -1, 0);
			if (@intFromPtr(p) == std.math.maxInt(usize)) return null;
			return @ptrCast(p);
		},
		.windows => return @ptrCast(win.VirtualAlloc(null, len, win.MEM_COMMIT_RESERVE, win.PAGE_READWRITE) orelse return null),
		else => @compileError("unsupported OS"),
	}
}

fn osWrite(fd: u8, bytes: []const u8) void {
	switch (os) {
		.linux => _ = linux.write(fd, bytes.ptr, bytes.len),
		.macos => _ = darwin.write(fd, bytes.ptr, bytes.len),
		.windows => {
			const h = win.GetStdHandle(if (fd == 2) win.STD_ERROR else win.STD_OUTPUT);
			var n: u32 = 0;
			_ = win.WriteFile(h, bytes.ptr, @intCast(bytes.len), &n, null);
		},
		else => @compileError("unsupported OS"),
	}
}

fn osExit(code: u8) noreturn {
	switch (os) {
		.linux => linux.exit_group(code),
		.macos => darwin.exit(code),
		.windows => win.ExitProcess(code),
		else => @compileError("unsupported OS"),
	}
}

// ---------------------------------------------------------------------------
// Allocator: a bump arena over OS pages. Each block carries a header holding
// its usable size because roc_realloc and roc_dealloc do not pass old lengths.
// Freed memory is not reused; adequate for a probe, not for production.

const chunk_size: usize = 1 << 20;
const Header = extern struct { size: usize, _pad: usize };
var arena_cur: usize = 0;
var arena_end: usize = 0;

fn bump(len: usize, alignment: usize) ?[*]u8 {
	const a = @max(alignment, @alignOf(Header));
	var start = std.mem.alignForward(usize, arena_cur + @sizeOf(Header), a);
	if (arena_cur == 0 or start + len > arena_end) {
		const want = @max(chunk_size, len + a + @sizeOf(Header));
		const base = osPages(want) orelse return null;
		arena_cur = @intFromPtr(base);
		arena_end = arena_cur + want;
		start = std.mem.alignForward(usize, arena_cur + @sizeOf(Header), a);
	}
	const hdr: *Header = @ptrFromInt(start - @sizeOf(Header));
	hdr.size = len;
	arena_cur = start + len;
	return @ptrFromInt(start);
}

fn crash(msg: []const u8) noreturn {
	osWrite(2, msg);
	osWrite(2, "\n");
	osExit(1);
}

fn rocAlloc(length: usize, alignment: usize) callconv(.c) *anyopaque {
	return @ptrCast(bump(length, alignment) orelse crash("roc_alloc: out of memory"));
}

fn rocDealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
	_ = ptr;
	_ = alignment;
}

fn rocRealloc(ptr: *anyopaque, new_length: usize, alignment: usize) callconv(.c) *anyopaque {
	const old: [*]u8 = @ptrCast(ptr);
	const hdr: *Header = @ptrFromInt(@intFromPtr(old) - @sizeOf(Header));
	const fresh = bump(new_length, alignment) orelse crash("roc_realloc: out of memory");
	@memcpy(fresh[0..@min(hdr.size, new_length)], old[0..@min(hdr.size, new_length)]);
	return @ptrCast(fresh);
}

fn rocDbg(bytes: [*]const u8, len: usize) callconv(.c) void {
	osWrite(2, "ROC DBG: ");
	osWrite(2, bytes[0..len]);
	osWrite(2, "\n");
}

fn rocExpectFailed(bytes: [*]const u8, len: usize) callconv(.c) void {
	osWrite(2, "Expect failed: ");
	osWrite(2, bytes[0..len]);
	osWrite(2, "\n");
}

fn rocCrashed(bytes: [*]const u8, len: usize) callconv(.c) void {
	osWrite(2, "Roc crashed: ");
	crash(bytes[0..len]);
}

fn hostDouble(n: i64) callconv(.c) i64 {
	return n * 2;
}

comptime {
	@export(&rocAlloc, .{ .name = "roc_alloc" });
	@export(&rocDealloc, .{ .name = "roc_dealloc" });
	@export(&rocRealloc, .{ .name = "roc_realloc" });
	@export(&rocDbg, .{ .name = "roc_dbg" });
	@export(&rocExpectFailed, .{ .name = "roc_expect_failed" });
	@export(&rocCrashed, .{ .name = "roc_crashed" });
	@export(&hostDouble, .{ .name = "roc_host_double" });
}

extern fn roc_main(n: i64) callconv(.c) i64;

// ---------------------------------------------------------------------------
// Program logic shared by every entry point.

fn parseI64(s: []const u8) i64 {
	var neg = false;
	var i: usize = 0;
	if (s.len > 0 and s[0] == '-') {
		neg = true;
		i = 1;
	}
	var v: i64 = 0;
	while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) v = v *% 10 +% (s[i] - '0');
	return if (neg) -%v else v;
}

fn printI64(v: i64) void {
	var buf: [24]u8 = undefined;
	var i: usize = buf.len;
	buf[i - 1] = '\n';
	i -= 1;
	var u: u64 = if (v < 0) @intCast(-%v) else @intCast(v);
	while (true) {
		i -= 1;
		buf[i] = '0' + @as(u8, @intCast(u % 10));
		u /= 10;
		if (u == 0) break;
	}
	if (v < 0) {
		i -= 1;
		buf[i] = '-';
	}
	osWrite(1, buf[i..]);
}

fn run(arg: ?[]const u8) noreturn {
	printI64(roc_main(if (arg) |a| parseI64(a) else 20));
	osExit(0);
}

fn cstrSlice(p: [*:0]const u8) []const u8 {
	var n: usize = 0;
	while (p[n] != 0) n += 1;
	return p[0..n];
}

// ---------------------------------------------------------------------------
// Entry points. Linux has no C runtime, so _start reads argc/argv from the
// initial stack. macOS's dyld calls main. Windows' console subsystem calls
// mainCRTStartup with no arguments; we take the last command-line token.

fn linuxMain(sp: [*]usize) callconv(.c) noreturn {
	const argc = sp[0];
	const argv: [*][*:0]const u8 = @ptrCast(sp + 1);
	run(if (argc > 1) cstrSlice(argv[1]) else null);
}

fn linuxStart() callconv(.naked) noreturn {
	switch (builtin.cpu.arch) {
		.x86_64 => asm volatile (
			\\ xor %%rbp, %%rbp
			\\ mov %%rsp, %%rdi
			\\ and $-16, %%rsp
			\\ call %[f:P]
			:
			: [f] "X" (&linuxMain),
		),
		.aarch64 => asm volatile (
			\\ mov x29, #0
			\\ mov x30, #0
			\\ mov x0, sp
			\\ b %[f]
			:
			: [f] "X" (&linuxMain),
		),
		else => @compileError("unsupported arch"),
	}
}

fn darwinMain(argc: c_int, argv: [*][*:0]const u8) callconv(.c) c_int {
	run(if (argc > 1) cstrSlice(argv[1]) else null);
}

fn windowsStart() callconv(.c) noreturn {
	const line = cstrSlice(win.GetCommandLineA());
	var end = line.len;
	while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t')) end -= 1;
	var start = end;
	while (start > 0 and line[start - 1] != ' ' and line[start - 1] != '\t' and line[start - 1] != '"') start -= 1;
	const tok = line[start..end];
	const has_arg = std.mem.indexOfAny(u8, line[0..start], " \t") != null;
	run(if (has_arg and tok.len > 0) tok else null);
}

comptime {
	switch (os) {
		.linux => @export(&linuxStart, .{ .name = "_start" }),
		.macos => @export(&darwinMain, .{ .name = "main" }),
		.windows => @export(&windowsStart, .{ .name = "mainCRTStartup" }),
		else => {},
	}
}

// Compiler-emitted memory intrinsics, since there is no libc to provide them.
fn memcpyImpl(dst: [*]u8, src: [*]const u8, n: usize) callconv(.c) [*]u8 {
	var i: usize = 0;
	while (i < n) : (i += 1) dst[i] = src[i];
	return dst;
}
fn memmoveImpl(dst: [*]u8, src: [*]const u8, n: usize) callconv(.c) [*]u8 {
	if (@intFromPtr(dst) < @intFromPtr(src)) return memcpyImpl(dst, src, n);
	var i = n;
	while (i > 0) {
		i -= 1;
		dst[i] = src[i];
	}
	return dst;
}
fn memsetImpl(dst: [*]u8, c: c_int, n: usize) callconv(.c) [*]u8 {
	var i: usize = 0;
	while (i < n) : (i += 1) dst[i] = @truncate(@as(c_uint, @bitCast(c)));
	return dst;
}
fn memcmpImpl(a: [*]const u8, b: [*]const u8, n: usize) callconv(.c) c_int {
	var i: usize = 0;
	while (i < n) : (i += 1) if (a[i] != b[i]) return @as(c_int, a[i]) - @as(c_int, b[i]);
	return 0;
}

comptime {
	// macOS gets these from libSystem; elsewhere the host must define them.
	if (os != .macos) {
		@export(&memcpyImpl, .{ .name = "memcpy", .linkage = .weak });
		@export(&memmoveImpl, .{ .name = "memmove", .linkage = .weak });
		@export(&memsetImpl, .{ .name = "memset", .linkage = .weak });
		@export(&memcmpImpl, .{ .name = "memcmp", .linkage = .weak });
	}
}

pub const panic = std.debug.no_panic;
