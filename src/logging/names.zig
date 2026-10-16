//! Resource names: scopes as `entries.list` takes them, bucket and view
//! names, and log ids in and out of their URL-encoded form. Every part has
//! been checked by `validate` before it gets here, so names are plain joins:
//! no part holds a `/`, `?`, `#`, `%` or a space.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const types = @import("types.zig");

pub fn writeParent(w: *Writer, parent: types.Parent) Writer.Error!void {
    switch (parent) {
        .project => |id| try w.print("projects/{s}", .{id}),
        .folder => |id| try w.print("folders/{s}", .{id}),
        .organization => |id| try w.print("organizations/{s}", .{id}),
        .billing_account => |id| try w.print("billingAccounts/{s}", .{id}),
    }
}

pub fn writeBucket(w: *Writer, name: types.BucketName) Writer.Error!void {
    try writeParent(w, name.parent);
    try w.print("/locations/{s}/buckets/{s}", .{ name.location, name.bucket });
}

pub fn writeView(w: *Writer, name: types.ViewName) Writer.Error!void {
    try writeParent(w, name.parent);
    try w.print("/locations/{s}/buckets/{s}/views/{s}", .{ name.location, name.bucket, name.view });
}

pub fn writeScope(w: *Writer, scope: types.Scope) Writer.Error!void {
    switch (scope) {
        .parent => |p| try writeParent(w, p),
        .view => |v| try writeView(w, v),
    }
}

/// `scope`'s resource name, in `arena`.
pub fn scopeName(arena: Allocator, scope: types.Scope) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeScope(&out.writer, scope) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// The log id of a log name, decoded: `projects/P/logs/a%2Fb` gives `a/b`.
/// "" when the name has no `/logs/` part. A `%` not followed by two hex
/// digits is kept as it is: the server encodes only what it must.
pub fn logIdOf(arena: Allocator, log_name: []const u8) Allocator.Error![]const u8 {
    const marker = "/logs/";
    const at = std.mem.indexOf(u8, log_name, marker) orelse return "";
    const encoded = log_name[at + marker.len ..];
    if (std.mem.indexOfScalar(u8, encoded, '%') == null) return encoded;
    var out = try arena.alloc(u8, encoded.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            const hi = std.fmt.charToDigit(encoded[i + 1], 16) catch null;
            const lo = std.fmt.charToDigit(encoded[i + 2], 16) catch null;
            if (hi != null and lo != null) {
                out[n] = hi.? * 16 + lo.?;
                n += 1;
                i += 3;
                continue;
            }
        }
        out[n] = encoded[i];
        n += 1;
        i += 1;
    }
    return out[0..n];
}

/// A log name for `parent` and the plain log id `log_id`, which may hold
/// `/`: encoded as `%2F`, the one reserved character a log id allows.
pub fn logName(arena: Allocator, parent: types.Parent, log_id: []const u8) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    writeParent(w, parent) catch return error.OutOfMemory;
    w.writeAll("/logs/") catch return error.OutOfMemory;
    for (log_id) |c| {
        if (c == '/') w.writeAll("%2F") catch return error.OutOfMemory else w.writeByte(c) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

/// A parent at the start of a resource name, and what follows its id
/// (with the `/` before it, or "").
pub fn parseParent(text: []const u8) ?struct { parent: types.Parent, rest: []const u8 } {
    const slash = std.mem.indexOfScalar(u8, text, '/') orelse return null;
    const kind = text[0..slash];
    const after = text[slash + 1 ..];
    const end = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
    const id = after[0..end];
    if (id.len == 0) return null;
    const parent: types.Parent = if (std.mem.eql(u8, kind, "projects"))
        .{ .project = id }
    else if (std.mem.eql(u8, kind, "folders"))
        .{ .folder = id }
    else if (std.mem.eql(u8, kind, "organizations"))
        .{ .organization = id }
    else if (std.mem.eql(u8, kind, "billingAccounts"))
        .{ .billing_account = id }
    else
        return null;
    return .{ .parent = parent, .rest = after[end..] };
}

/// `PARENT/locations/L/buckets/B`, the parts pointing into `text`.
pub fn parseBucketName(text: []const u8) ?types.BucketName {
    const p = parseParent(text) orelse return null;
    var it = std.mem.splitScalar(u8, p.rest, '/');
    if ((it.next() orelse return null).len != 0) return null;
    if (!std.mem.eql(u8, it.next() orelse return null, "locations")) return null;
    const location = it.next() orelse return null;
    if (!std.mem.eql(u8, it.next() orelse return null, "buckets")) return null;
    const bucket = it.next() orelse return null;
    if (location.len == 0 or bucket.len == 0 or it.next() != null) return null;
    return .{ .parent = p.parent, .location = location, .bucket = bucket };
}

/// `PARENT/locations/L/buckets/B/views/V`, the parts pointing into `text`.
pub fn parseViewName(text: []const u8) ?types.ViewName {
    const at = std.mem.lastIndexOf(u8, text, "/views/") orelse return null;
    const bucket = parseBucketName(text[0..at]) orelse return null;
    const view = text[at + "/views/".len ..];
    if (view.len == 0 or std.mem.indexOfScalar(u8, view, '/') != null) return null;
    return .{ .parent = bucket.parent, .location = bucket.location, .bucket = bucket.bucket, .view = view };
}

const testing = std.testing;

test "resource names read back into their parts" {
    const b = parseBucketName("projects/extractctl/locations/global/buckets/_Default").?;
    try testing.expectEqualStrings("extractctl", b.parent.project);
    try testing.expectEqualStrings("global", b.location);
    try testing.expectEqualStrings("_Default", b.bucket);
    const v = parseViewName("folders/12/locations/eu/buckets/audit/views/_AllLogs").?;
    try testing.expectEqualStrings("12", v.parent.folder);
    try testing.expectEqualStrings("eu", v.location);
    try testing.expectEqualStrings("audit", v.bucket);
    try testing.expectEqualStrings("_AllLogs", v.view);
    try testing.expectEqualStrings("9", parseParent("organizations/9").?.parent.organization);
    try testing.expectEqualStrings("012345-567890-ABCDEF", parseParent("billingAccounts/012345-567890-ABCDEF/logs").?.parent.billing_account);
    for ([_][]const u8{
        "",
        "projects",
        "projects/",
        "teams/x/locations/global/buckets/b",
        "projects/p/locations/global",
        "projects/p/places/global/buckets/b",
        "projects/p/locations/global/pails/b",
        "projects/p/locations//buckets/b",
        "projects/p/locations/global/buckets/",
        "projects/p/locations/global/buckets/b/extra",
    }) |bad| try testing.expectEqual(null, parseBucketName(bad));
    for ([_][]const u8{
        "projects/p/locations/global/buckets/b/views/",
        "projects/p/locations/global/buckets/b/views/v/w",
        "projects/p/views/v",
    }) |bad| try testing.expectEqual(null, parseViewName(bad));
}

test "scope names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("projects/my-project", try scopeName(a, .{ .parent = .{ .project = "my-project" } }));
    try testing.expectEqualStrings("folders/123", try scopeName(a, .{ .parent = .{ .folder = "123" } }));
    try testing.expectEqualStrings("organizations/9", try scopeName(a, .{ .parent = .{ .organization = "9" } }));
    try testing.expectEqualStrings("billingAccounts/012345-567890-ABCDEF", try scopeName(a, .{ .parent = .{ .billing_account = "012345-567890-ABCDEF" } }));
    try testing.expectEqualStrings(
        "projects/p/locations/global/buckets/_Default/views/_AllLogs",
        try scopeName(a, .{ .view = .{ .parent = .{ .project = "p" }, .location = "global", .bucket = "_Default", .view = "_AllLogs" } }),
    );
}

test "log ids in and out of their encoded form" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("run.googleapis.com/stderr", try logIdOf(a, "projects/p/logs/run.googleapis.com%2Fstderr"));
    try testing.expectEqualStrings("cloudaudit.googleapis.com/activity", try logIdOf(a, "folders/1/logs/cloudaudit.googleapis.com%2factivity"));
    try testing.expectEqualStrings("stdout", try logIdOf(a, "projects/p/logs/stdout"));
    try testing.expectEqualStrings("", try logIdOf(a, "projects/p"));
    try testing.expectEqualStrings("", try logIdOf(a, ""));
    // A stray percent stays as it is, at the end too.
    try testing.expectEqualStrings("a%zzb%", try logIdOf(a, "projects/p/logs/a%zzb%"));
    try testing.expectEqualStrings("a%2", try logIdOf(a, "projects/p/logs/a%2"));
    try testing.expectEqualStrings("projects/p/logs/a%2Fb%2Fc", try logName(a, .{ .project = "p" }, "a/b/c"));
    try testing.expectEqualStrings("a/b/c", try logIdOf(a, try logName(a, .{ .project = "p" }, "a/b/c")));
}
