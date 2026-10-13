//! Root for all core unit tests (`zig build test`).
test {
	_ = @import("pack.zig");
	_ = @import("layout.zig");
	_ = @import("zstd_decode.zig");
	_ = @import("zstd_encode.zig");
	_ = @import("index.zig");
	_ = @import("targets.zig");
	_ = @import("rt_ffi.zig");
	_ = @import("app_id.zig");
}
