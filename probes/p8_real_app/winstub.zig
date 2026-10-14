// Windows slot for an app without a native Windows build: say so, exit 1.
const std = @import("std");
const w = std.os.windows;
extern "kernel32" fn GetStdHandle(n: u32) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn WriteFile(h: ?w.HANDLE, b: [*]const u8, n: u32, written: ?*u32, o: ?*anyopaque) callconv(.winapi) w.BOOL;
extern "kernel32" fn ExitProcess(code: u32) callconv(.winapi) noreturn;
const msg = "This app has no native Windows build yet. Under WSL, run it with: sh ./<name>\r\n";
pub fn main() void {
	_ = WriteFile(GetStdHandle(@bitCast(@as(i32, -12))), msg, msg.len, null, null);
	ExitProcess(1);
}
