//! Root for all core unit tests (`zig build test`).
test {
	_ = @import("pack.zig");
	_ = @import("layout.zig");
	_ = @import("zstd_decode.zig");
	_ = @import("zstd_encode.zig");
	_ = @import("zstd_small.zig");
	_ = @import("xxh64.zig");
	_ = @import("index.zig");
	_ = @import("targets.zig");
	_ = @import("rt_ffi.zig");
	_ = @import("app_id.zig");
	_ = @import("datatree.zig");
}

/// The runtimes report and exit on structurally corrupt zstd input; no unit
/// test feeds the small decoder such input, so reaching this is a test bug.
export fn rocosmo_zdec_fail() noreturn {
	@panic("small zstd decoder met corrupt input");
}
