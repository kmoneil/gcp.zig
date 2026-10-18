//! Request paths. Every Cloud KMS resource lives under a project and a
//! location: `projects/P/locations/L/keyRings/R/cryptoKeys/K/cryptoKeyVersions/V`.
//! Ids have been checked before a path is built; each segment is still
//! written through `core.query.writeSegment`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const core = @import("core");

/// Where a call points: a location, a key ring, a key or a version, by how
/// far it goes.
pub const Target = struct {
    project: []const u8,
    location: []const u8,
    key_ring: ?[]const u8 = null,
    key: ?[]const u8 = null,
    version: ?u64 = null,

    /// The resource name, `projects/P/locations/L/...`, as the server
    /// writes it in answers.
    pub fn writeName(t: Target, w: *Writer) Writer.Error!void {
        try w.writeAll("projects/");
        try core.query.writeSegment(w, t.project);
        try w.writeAll("/locations/");
        try core.query.writeSegment(w, t.location);
        const ring = t.key_ring orelse return;
        try w.writeAll("/keyRings/");
        try core.query.writeSegment(w, ring);
        const key = t.key orelse return;
        try w.writeAll("/cryptoKeys/");
        try core.query.writeSegment(w, key);
        const version = t.version orelse return;
        try w.print("/cryptoKeyVersions/{d}", .{version});
    }

    pub fn name(t: Target, arena: Allocator) Allocator.Error![]const u8 {
        var w: Writer.Allocating = .init(arena);
        t.writeName(&w.writer) catch return error.OutOfMemory;
        return w.written();
    }

    /// `/v1/` and the name, then `tail` as given: a collection
    /// (`/cryptoKeys`), a method (`:destroy`) or a query (`?keyRingId=r`).
    pub fn path(t: Target, arena: Allocator, tail: []const u8) Allocator.Error![]const u8 {
        var w: Writer.Allocating = .init(arena);
        t.writePath(&w.writer, tail) catch return error.OutOfMemory;
        return w.written();
    }

    pub fn writePath(t: Target, w: *Writer, tail: []const u8) Writer.Error!void {
        try w.writeAll("/v1/");
        try t.writeName(w);
        try w.writeAll(tail);
    }

    /// The target one level up: a version's key, a key's key ring.
    pub fn parent(t: Target) Target {
        var p = t;
        if (p.version != null) {
            p.version = null;
        } else if (p.key != null) {
            p.key = null;
        } else {
            p.key_ring = null;
        }
        return p;
    }
};

/// `/v1/projects/P/locations`.
pub fn locations(arena: Allocator, project: []const u8) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    w.writer.writeAll("/v1/projects/") catch return error.OutOfMemory;
    core.query.writeSegment(&w.writer, project) catch return error.OutOfMemory;
    w.writer.writeAll("/locations") catch return error.OutOfMemory;
    return w.written();
}

/// Whether `name` can be an operation's name in a path: what the server
/// wrote, `projects/P/locations/L/operations/X`, of characters that stay
/// what they are in a URL path.
pub fn isOperationName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "projects/")) return false;
    if (std.mem.indexOf(u8, name, "/operations/") == null) return false;
    if (std.mem.indexOf(u8, name, "..") != null or std.mem.indexOf(u8, name, "//") != null) return false;
    if (name[name.len - 1] == '/') return false;
    for (name) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~', '/' => {},
        else => return false,
    };
    return true;
}

/// `/v1/` and an operation's name, which `isOperationName` has passed.
pub fn operation(arena: Allocator, op_name: []const u8) Allocator.Error![]const u8 {
    return std.mem.concat(arena, u8, &.{ "/v1/", op_name });
}

/// The version number at the end of a version's name, or null when the
/// name does not end `/cryptoKeyVersions/` and a decimal from 1.
pub fn versionId(version_name: []const u8) ?u64 {
    const marker = "/cryptoKeyVersions/";
    const at = std.mem.lastIndexOf(u8, version_name, marker) orelse return null;
    const digits = version_name[at + marker.len ..];
    if (digits.len == 0 or digits.len > 20 or digits[0] == '0') return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u64, digits, 10) catch null;
}

const testing = std.testing;

test "paths: a location, a key ring, a key and a version, with a tail" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loc: Target = .{ .project = "p", .location = "us-central1" };
    try testing.expectEqualStrings("/v1/projects/p/locations/us-central1/keyRings?keyRingId=r", try loc.path(a, "/keyRings?keyRingId=r"));
    const ring: Target = .{ .project = "p", .location = "global", .key_ring = "r" };
    try testing.expectEqualStrings("/v1/projects/p/locations/global/keyRings/r", try ring.path(a, ""));
    const key: Target = .{ .project = "p", .location = "global", .key_ring = "r", .key = "k" };
    try testing.expectEqualStrings("/v1/projects/p/locations/global/keyRings/r/cryptoKeys/k:encrypt", try key.path(a, ":encrypt"));
    const version: Target = .{ .project = "p", .location = "global", .key_ring = "r", .key = "k", .version = 12 };
    try testing.expectEqualStrings("projects/p/locations/global/keyRings/r/cryptoKeys/k/cryptoKeyVersions/12", try version.name(a));
    try testing.expectEqualStrings("/v1/projects/p/locations/global/keyRings/r/cryptoKeys/k/cryptoKeyVersions/12:destroy", try version.path(a, ":destroy"));
    try testing.expectEqualStrings("/v1/projects/example.com:p/locations", try locations(a, "example.com:p"));
    try testing.expectEqualStrings("projects/p/locations/global/keyRings/r/cryptoKeys/k", try version.parent().name(a));
    try testing.expectEqualStrings("projects/p/locations/global/keyRings/r", try version.parent().parent().name(a));
    try testing.expectEqualStrings("projects/p/locations/global", try ring.parent().name(a));
}

test "operation names: the server's form only, safe in a path" {
    try testing.expect(isOperationName("projects/p/locations/us-central1/operations/abc-123_x"));
    for ([_][]const u8{
        "",
        "operations/x",
        "projects/p/locations/l/operations/",
        "projects/p/locations/l/operations/a?b",
        "projects/p/locations/l/operations/a#b",
        "projects/p/locations/l/operations/a%2Fb",
        "projects/p/locations/l/operations/../x",
        "projects/p//operations/x",
        "projects/p/locations/l/operations/a b",
    }) |bad| try testing.expect(!isOperationName(bad));
}

test "version ids: a decimal from 1 at the end of a version's name" {
    try testing.expectEqual(1, versionId("projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1").?);
    try testing.expectEqual(18446744073709551615, versionId("x/cryptoKeyVersions/18446744073709551615").?);
    for ([_][]const u8{ "", "x/cryptoKeyVersions/", "x/cryptoKeyVersions/0", "x/cryptoKeyVersions/01", "x/cryptoKeyVersions/1a", "x/cryptoKeyVersions/18446744073709551616", "x/cryptoKeys/1" }) |bad| {
        try testing.expectEqual(null, versionId(bad));
    }
}
