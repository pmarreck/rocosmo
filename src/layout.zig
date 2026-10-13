//! Optimal depth-1 payload layout: which targets are stored as whole zstd
//! frames ("roots") and which as `--patch-from` deltas against a root or a
//! free reference (bytes the container holds raw anyway, such as the Windows
//! PE body). Deltas never reference other deltas, so a rebuild decodes at
//! most one reference. Pure computation over a measured cost matrix.

const std = @import("std");

pub const Choice = union(enum) { root, delta: usize };

pub const Plan = struct {
	total: u64,
	/// One entry per target. A delta's reference index is a target index
	/// (< n_targets) or n_targets + free-reference index.
	choice: []Choice,

	pub fn deinit(self: Plan, gpa: std.mem.Allocator) void {
		gpa.free(self.choice);
	}
};

pub const max_targets = 16;

/// Exhaustive search over root subsets (2^n, n <= max_targets): for each,
/// every non-root target takes its cheapest delta from a root or free
/// reference. `alone[t]` is target t's whole-frame size; `patch[r * n + t]`
/// is the delta size of target t against reference r (null = not measured).
/// Ties keep the earliest subset and the lowest reference index, so the plan
/// is deterministic.
pub fn optimal(gpa: std.mem.Allocator, n: usize, n_free: usize, alone: []const u64, patch: []const ?u64) !Plan {
	std.debug.assert(n <= max_targets and alone.len == n and patch.len == (n + n_free) * n);
	var best_total: ?u64 = null;
	var best_mask: u32 = 0;
	var mask: u32 = 0;
	while (mask < (@as(u32, 1) << @intCast(n))) : (mask += 1) {
		var total: u64 = 0;
		var feasible = true;
		for (0..n) |t| {
			if (isRoot(mask, t)) {
				total += alone[t];
			} else if (cheapestRef(n, n_free, patch, mask, t)) |r| {
				total += patch[r * n + t].?;
			} else {
				feasible = false;
				break;
			}
		}
		if (feasible and (best_total == null or total < best_total.?)) {
			best_total = total;
			best_mask = mask;
		}
	}
	const choice = try gpa.alloc(Choice, n);
	for (choice, 0..) |*c, t| c.* = if (isRoot(best_mask, t)) .root else .{ .delta = cheapestRef(n, n_free, patch, best_mask, t).? };
	return .{ .total = best_total orelse 0, .choice = choice };
}

fn isRoot(mask: u32, t: usize) bool {
	return (mask >> @intCast(t)) & 1 == 1;
}

fn cheapestRef(n: usize, n_free: usize, patch: []const ?u64, mask: u32, t: usize) ?usize {
	var best: ?usize = null;
	for (0..n + n_free) |r| {
		if (r < n and !isRoot(mask, r)) continue;
		const c = patch[r * n + t] orelse continue;
		if (best == null or c < patch[best.? * n + t].?) best = r;
	}
	return best;
}

// ---------------------------------------------------------------------------
// The same cases the AWK prototype (probes/p5_payload_layout) is tested on.

const testing = std.testing;

fn expectPlan(n: usize, n_free: usize, alone: []const u64, patch: []const ?u64, total: u64, want: []const Choice) !void {
	const p = try optimal(testing.allocator, n, n_free, alone, patch);
	defer p.deinit(testing.allocator);
	try testing.expectEqual(total, p.total);
	try testing.expectEqualSlices(Choice, want, p.choice);
}

test "stores the best reference, not the smallest payload" {
	// targets a b c; patch[r][t]
	try expectPlan(3, 0, &.{ 120, 100, 100 }, &.{
		null, 10,   10,
		60,   null, 50,
		60,   50,   null,
	}, 140, &.{ .root, .{ .delta = 0 }, .{ .delta = 0 } });
}

test "a free raw reference costs nothing and can serve every target" {
	try expectPlan(1, 1, &.{50}, &.{ null, 5 }, 5, &.{.{ .delta = 1 }});
}

test "deltas larger than whole frames are not used" {
	try expectPlan(2, 0, &.{ 10, 10 }, &.{ null, 20, 20, null }, 20, &.{ .root, .root });
}

test "deltas never chain through another delta" {
	try expectPlan(3, 0, &.{ 100, 100, 100 }, &.{
		null, 1,    90,
		100,  null, 1,
		100,  100,  null,
	}, 191, &.{ .root, .{ .delta = 0 }, .{ .delta = 0 } });
}

test "unmeasured pairs are never chosen" {
	try expectPlan(2, 0, &.{ 30, 30 }, &.{ null, null, 1, null }, 31, &.{ .{ .delta = 1 }, .root });
}
