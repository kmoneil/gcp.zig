//! Request paths and full names. Every segment is one path segment,
//! percent-encoded on its way into a URL. The locations list is v1's:
//! v2 has none, and v1 answers on the same host (measured 2026-10-19).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const core = @import("core");

/// `/v1/projects/P/locations`: the one v1 path.
pub fn locations(arena: Allocator, project: []const u8) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    w.writer.writeAll("/v1/projects/") catch return error.OutOfMemory;
    core.query.writeSegment(&w.writer, project) catch return error.OutOfMemory;
    w.writer.writeAll("/locations") catch return error.OutOfMemory;
    return w.written();
}

/// `/v2/projects/P/locations/L/services`.
pub fn services(arena: Allocator, project: []const u8, location: []const u8) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    writeServices(&w.writer, project, location) catch return error.OutOfMemory;
    return w.written();
}

/// `/v2/projects/P/locations/L/services/S`.
pub fn service(arena: Allocator, project: []const u8, location: []const u8, id: []const u8) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    writeServices(&w.writer, project, location) catch return error.OutOfMemory;
    w.writer.writeByte('/') catch return error.OutOfMemory;
    core.query.writeSegment(&w.writer, id) catch return error.OutOfMemory;
    return w.written();
}

/// `/v2/projects/P/locations/L/services/S/revisions`, `S` may be `-`.
pub fn revisions(arena: Allocator, project: []const u8, location: []const u8, service_id: []const u8) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    writeServices(&w.writer, project, location) catch return error.OutOfMemory;
    w.writer.writeByte('/') catch return error.OutOfMemory;
    core.query.writeSegment(&w.writer, service_id) catch return error.OutOfMemory;
    w.writer.writeAll("/revisions") catch return error.OutOfMemory;
    return w.written();
}

/// `/v2/projects/P/locations/L/services/S/revisions/R`.
pub fn revision(arena: Allocator, project: []const u8, location: []const u8, service_id: []const u8, id: []const u8) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    writeServices(&w.writer, project, location) catch return error.OutOfMemory;
    w.writer.writeByte('/') catch return error.OutOfMemory;
    core.query.writeSegment(&w.writer, service_id) catch return error.OutOfMemory;
    w.writer.writeAll("/revisions/") catch return error.OutOfMemory;
    core.query.writeSegment(&w.writer, id) catch return error.OutOfMemory;
    return w.written();
}

fn writeServices(w: *Writer, project: []const u8, location: []const u8) Writer.Error!void {
    try w.writeAll("/v2/projects/");
    try core.query.writeSegment(w, project);
    try w.writeAll("/locations/");
    try core.query.writeSegment(w, location);
    try w.writeAll("/services");
}

pub const ServiceName = struct {
    location: []const u8,
    id: []const u8,
};

/// The parts of `projects/<project>/locations/L/services/S`, pointing
/// into it. Null for another project's name or a malformed one.
pub fn serviceName(name: []const u8, project: []const u8) ?ServiceName {
    var parts = std.mem.splitScalar(u8, name, '/');
    if (!std.mem.eql(u8, parts.next() orelse return null, "projects")) return null;
    const p = parts.next() orelse return null;
    if (!std.mem.eql(u8, parts.next() orelse return null, "locations")) return null;
    const location = parts.next() orelse return null;
    if (!std.mem.eql(u8, parts.next() orelse return null, "services")) return null;
    const id = parts.next() orelse return null;
    if (parts.next() != null) return null;
    if (!std.mem.eql(u8, p, project) or location.len == 0 or id.len == 0) return null;
    return .{ .location = location, .id = id };
}

pub const RevisionName = struct {
    location: []const u8,
    service: []const u8,
    id: []const u8,
};

/// The parts of `projects/<project>/locations/L/services/S/revisions/R`.
pub fn revisionName(name: []const u8, project: []const u8) ?RevisionName {
    var parts = std.mem.splitScalar(u8, name, '/');
    if (!std.mem.eql(u8, parts.next() orelse return null, "projects")) return null;
    const p = parts.next() orelse return null;
    if (!std.mem.eql(u8, parts.next() orelse return null, "locations")) return null;
    const location = parts.next() orelse return null;
    if (!std.mem.eql(u8, parts.next() orelse return null, "services")) return null;
    const service_id = parts.next() orelse return null;
    if (!std.mem.eql(u8, parts.next() orelse return null, "revisions")) return null;
    const id = parts.next() orelse return null;
    if (parts.next() != null) return null;
    if (!std.mem.eql(u8, p, project) or location.len == 0 or service_id.len == 0 or id.len == 0) return null;
    return .{ .location = location, .service = service_id, .id = id };
}

const testing = std.testing;

test "paths and full names: this project's services and revisions, nobody else's" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/v1/projects/p/locations", try locations(a, "p"));
    try testing.expectEqualStrings("/v2/projects/p/locations/us-central1/services", try services(a, "p", "us-central1"));
    try testing.expectEqualStrings("/v2/projects/p/locations/us-central1/services/s", try service(a, "p", "us-central1", "s"));
    try testing.expectEqualStrings("/v2/projects/p/locations/us-central1/services/-/revisions", try revisions(a, "p", "us-central1", "-"));
    try testing.expectEqualStrings("/v2/projects/p/locations/us-central1/services/s/revisions/r", try revision(a, "p", "us-central1", "s", "r"));

    const svc = serviceName("projects/p/locations/l/services/s", "p").?;
    try testing.expectEqualStrings("l", svc.location);
    try testing.expectEqualStrings("s", svc.id);
    try testing.expectEqual(null, serviceName("projects/q/locations/l/services/s", "p"));
    try testing.expectEqual(null, serviceName("projects/p/locations/l/services/", "p"));
    try testing.expectEqual(null, serviceName("projects/p/locations/l/services/s/x", "p"));
    try testing.expectEqual(null, serviceName("projects/p/locations/l", "p"));
    try testing.expectEqual(null, serviceName("s", "p"));

    const rev = revisionName("projects/p/locations/l/services/s/revisions/r-00002-ab", "p").?;
    try testing.expectEqualStrings("l", rev.location);
    try testing.expectEqualStrings("s", rev.service);
    try testing.expectEqualStrings("r-00002-ab", rev.id);
    try testing.expectEqual(null, revisionName("projects/q/locations/l/services/s/revisions/r", "p"));
    try testing.expectEqual(null, revisionName("projects/p/locations/l/services/s/revisions/", "p"));
    try testing.expectEqual(null, revisionName("projects/p/locations/l/services/s", "p"));
    try testing.expectEqual(null, revisionName("projects/p/locations/l/services/s/revisions/r/x", "p"));
}
