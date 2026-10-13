//! Decode-only view of libzstd: whole frames and `--patch-from` deltas, whose
//! reference is supplied as a raw-content prefix (ZSTD_DCtx_refPrefix). The
//! runtime links only this half, built space-optimized.

const std = @import("std");

const DCtx = opaque {};
extern fn ZSTD_createDCtx() ?*DCtx;
extern fn ZSTD_freeDCtx(*DCtx) usize;
extern fn ZSTD_DCtx_setParameter(*DCtx, c_int, c_int) usize;
extern fn ZSTD_DCtx_refPrefix(*DCtx, ?*const anyopaque, usize) usize;
extern fn ZSTD_decompressDCtx(*DCtx, ?*anyopaque, usize, ?*const anyopaque, usize) usize;
extern fn ZSTD_getFrameContentSize(?*const anyopaque, usize) c_ulonglong;
extern fn ZSTD_isError(usize) c_uint;

const d_window_log_max = 100;
/// Largest back-reference window zstd supports on 64-bit targets.
pub const window_log_max = 31;
const content_size_unknown: c_ulonglong = std.math.maxInt(c_ulonglong);
const content_size_error: c_ulonglong = std.math.maxInt(c_ulonglong) - 1;

pub const DecodeError = error{ Corrupt, NoContentSize, SizeMismatch, OutOfMemory };

/// Decompressed size recorded in the frame header, if any.
pub fn contentSize(frame: []const u8) ?u64 {
	const s = ZSTD_getFrameContentSize(frame.ptr, frame.len);
	if (s == content_size_unknown or s == content_size_error) return null;
	return s;
}

/// Decode one frame into `out`, which must be exactly its content size. A
/// delta needs the same `reference` bytes it was made against; a wrong
/// reference fails the frame checksum rather than producing wrong bytes.
pub fn decode(frame: []const u8, reference: ?[]const u8, out: []u8) DecodeError!void {
	const want = contentSize(frame) orelse return error.NoContentSize;
	if (want != out.len) return error.SizeMismatch;
	const d = ZSTD_createDCtx() orelse return error.OutOfMemory;
	defer _ = ZSTD_freeDCtx(d);
	if (ZSTD_isError(ZSTD_DCtx_setParameter(d, d_window_log_max, window_log_max)) != 0) return error.Corrupt;
	if (reference) |r| if (ZSTD_isError(ZSTD_DCtx_refPrefix(d, r.ptr, r.len)) != 0) return error.Corrupt;
	const n = ZSTD_decompressDCtx(d, out.ptr, out.len, frame.ptr, frame.len);
	if (ZSTD_isError(n) != 0) return error.Corrupt;
	if (n != out.len) return error.SizeMismatch;
}
