//! Application identity for the per-app cache namespace. An app declares it
//! by embedding the marker `ROCOSMO_APP_ID=<id>;` in its executable (a string
//! literal any language can emit); `--app-id` overrides; otherwise the
//! default is `local.<executable name>`.
//!
//! An id is lowercase reverse-DNS: two or more dot-separated labels of
//! [a-z0-9-], each starting and ending with a letter or digit, at most 128
//! bytes. It becomes a cache directory name and shell text, so the alphabet
//! is deliberately narrow. Requiring a dot keeps ids distinct from rocosmo's
//! own cache entries (e.g. `runtime`).

const std = @import("std");

pub const marker = "ROCOSMO_APP_ID=";
pub const terminator = ';';
pub const max_len = 128;

pub fn valid(id: []const u8) bool {
	if (id.len == 0 or id.len > max_len) return false;
	var labels: usize = 0;
	var it = std.mem.splitScalar(u8, id, '.');
	while (it.next()) |label| : (labels += 1) {
		if (label.len == 0 or label[0] == '-' or label[label.len - 1] == '-') return false;
		for (label) |c| switch (c) {
			'a'...'z', '0'...'9', '-' => {},
			else => return false,
		};
	}
	return labels >= 2;
}

fn idChar(c: u8) bool {
	return switch (c) {
		'a'...'z', '0'...'9', '-', '.' => true,
		else => false,
	};
}

pub const ScanError = error{ConflictingAppIds};

/// The id declared in `bytes`, if any. Text that starts with the marker but
/// does not form `marker id ;` is ignored (it is not a declaration, e.g. the
/// packer's own copy of the marker); two different declarations are an error.
pub fn scan(bytes: []const u8) ScanError!?[]const u8 {
	var found: ?[]const u8 = null;
	var from: usize = 0;
	while (std.mem.indexOfPos(u8, bytes, from, marker)) |at| {
		const start = at + marker.len;
		var end = start;
		while (end < bytes.len and end - start <= max_len and idChar(bytes[end])) end += 1;
		from = start;
		if (end >= bytes.len or bytes[end] != terminator) continue;
		const id = bytes[start..end];
		if (!valid(id)) continue;
		if (found) |f| {
			if (!std.mem.eql(u8, f, id)) return error.ConflictingAppIds;
		} else found = id;
	}
	return found;
}

pub const ResolveError = ScanError || error{ InvalidAppId, OutOfMemory };

pub const Source = enum { option, embedded, default };

pub const Resolved = struct { id: []const u8, source: Source };

/// Precedence: an explicit option, else the id every declaring payload
/// agrees on, else `local.<sanitized executable name>`. The result is
/// allocated with `gpa`.
pub fn resolve(gpa: std.mem.Allocator, option: ?[]const u8, payloads: []const []const u8, exe_name: []const u8) ResolveError!Resolved {
	if (option) |o| {
		if (!valid(o)) return error.InvalidAppId;
		return .{ .id = try gpa.dupe(u8, o), .source = .option };
	}
	var found: ?[]const u8 = null;
	for (payloads) |p| if (try scan(p)) |id| {
		if (found) |f| {
			if (!std.mem.eql(u8, f, id)) return error.ConflictingAppIds;
		} else found = id;
	};
	if (found) |f| return .{ .id = try gpa.dupe(u8, f), .source = .embedded };
	return .{ .id = try defaultId(gpa, exe_name), .source = .default };
}

/// `local.` plus the executable name lowercased, without a trailing `.exe`,
/// with every run of other characters folded to one `-` and edge dashes
/// trimmed; `local.app` when nothing usable remains.
fn defaultId(gpa: std.mem.Allocator, exe_name: []const u8) error{OutOfMemory}![]u8 {
	var name = exe_name;
	if (name.len >= 4 and std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".exe")) name = name[0 .. name.len - 4];
	var out: std.ArrayList(u8) = .empty;
	errdefer out.deinit(gpa);
	try out.appendSlice(gpa, "local.");
	const base = out.items.len;
	for (name) |c0| {
		const c = std.ascii.toLower(c0);
		const keep = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
		if (keep) {
			try out.append(gpa, c);
		} else if (out.items.len > base and out.items[out.items.len - 1] != '-') try out.append(gpa, '-');
	}
	while (out.items.len > base and out.items[out.items.len - 1] == '-') _ = out.pop();
	if (out.items.len == base) try out.appendSlice(gpa, "app");
	if (out.items.len > max_len) out.shrinkRetainingCapacity(max_len);
	while (out.items[out.items.len - 1] == '-') _ = out.pop();
	return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "valid classifies a set of candidate ids" {
	const accepted = [_][]const u8{ "llc.mecha.validate", "local.app", "a.b", "com.example.my-app", "x1.y2.z3", "org.0day.tool" };
	const rejected = [_][]const u8{ "", "app", "runtime", ".a.b", "a.b.", "a..b", "-a.b", "a-.b", "a.-b", "Llc.mecha", "a.b c", "a.b;", "a/b.c", "a.b$x", "a_b.c", "a.b\n", "x" ** 60 ++ "." ++ "y" ** 68 };
	for (accepted) |id| try testing.expect(valid(id));
	for (rejected) |id| try testing.expect(!valid(id));
	try testing.expect(valid("x" ** 60 ++ "." ++ "y" ** 67));
}

test "scan finds one declaration, ignores malformed ones, rejects conflicts" {
	try testing.expectEqualStrings("llc.mecha.validate", (try scan("\x00junk ROCOSMO_APP_ID=llc.mecha.validate; more")).?);
	try testing.expectEqualStrings("a.b", (try scan("ROCOSMO_APP_ID=a.b;ROCOSMO_APP_ID=a.b;")).?);
	try testing.expectEqual(@as(?[]const u8, null), try scan("no marker here"));
	try testing.expectEqual(@as(?[]const u8, null), try scan("ROCOSMO_APP_ID=\x00")); // the packer's own literal
	try testing.expectEqual(@as(?[]const u8, null), try scan("ROCOSMO_APP_ID=<id>;")); // help text
	try testing.expectEqual(@as(?[]const u8, null), try scan("ROCOSMO_APP_ID=a.b")); // no terminator
	try testing.expectEqual(@as(?[]const u8, null), try scan("ROCOSMO_APP_ID=a.bxyz")); // runs into other bytes
	try testing.expectEqual(@as(?[]const u8, null), try scan("ROCOSMO_APP_ID=app;")); // not reverse-DNS
	try testing.expectEqual(@as(?[]const u8, null), try scan("ROCOSMO_APP_ID")); // truncated at end
	try testing.expectError(error.ConflictingAppIds, scan("ROCOSMO_APP_ID=a.b; ROCOSMO_APP_ID=a.c;"));
}

test "resolve: option beats embedded beats default; payloads must agree" {
	const gpa = testing.allocator;
	const decl = "..ROCOSMO_APP_ID=llc.mecha.validate;..";
	const none = "plain bytes";
	var r = try resolve(gpa, "llc.mecha.override", &.{decl}, "validate");
	try testing.expectEqualStrings("llc.mecha.override", r.id);
	try testing.expectEqual(Source.option, r.source);
	gpa.free(r.id);
	r = try resolve(gpa, null, &.{ none, decl, decl }, "validate");
	try testing.expectEqualStrings("llc.mecha.validate", r.id);
	try testing.expectEqual(Source.embedded, r.source);
	gpa.free(r.id);
	r = try resolve(gpa, null, &.{none}, "Mecha RotShield.exe");
	try testing.expectEqualStrings("local.mecha-rotshield", r.id);
	try testing.expectEqual(Source.default, r.source);
	gpa.free(r.id);
	try testing.expectError(error.ConflictingAppIds, resolve(gpa, null, &.{ decl, "ROCOSMO_APP_ID=llc.other.app;" }, "x"));
	try testing.expectError(error.InvalidAppId, resolve(gpa, "Not Valid", &.{}, "x"));
}

test "default names are sanitized into a valid id" {
	const gpa = testing.allocator;
	const cases = [_][2][]const u8{
		.{ "validate", "local.validate" },
		.{ "app.exe", "local.app" },
		.{ "APP.EXE", "local.app" },
		.{ "my_tool", "local.my-tool" },
		.{ "--weird--name--", "local.weird-name" },
		.{ "z7z-any", "local.z7z-any" },
		.{ "", "local.app" },
		.{ "!!!", "local.app" },
		.{ "\xc3\xa9t\xc3\xa9", "local.t" },
	};
	for (cases) |c| {
		const r = try resolve(gpa, null, &.{}, c[0]);
		defer gpa.free(r.id);
		try testing.expectEqualStrings(c[1], r.id);
		try testing.expect(valid(r.id));
	}
}
