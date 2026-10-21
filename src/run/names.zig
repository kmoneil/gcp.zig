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
    return path(arena, project, location, &.{"services"});
}

/// `/v2/projects/P/locations/L/services/S`.
pub fn service(arena: Allocator, project: []const u8, location: []const u8, id: []const u8) Allocator.Error![]const u8 {
    return path(arena, project, location, &.{ "services", id });
}

/// `/v2/projects/P/locations/L/services/S/revisions`, `S` may be `-`.
pub fn revisions(arena: Allocator, project: []const u8, location: []const u8, service_id: []const u8) Allocator.Error![]const u8 {
    return path(arena, project, location, &.{ "services", service_id, "revisions" });
}

/// `/v2/projects/P/locations/L/services/S/revisions/R`.
pub fn revision(arena: Allocator, project: []const u8, location: []const u8, service_id: []const u8, id: []const u8) Allocator.Error![]const u8 {
    return path(arena, project, location, &.{ "services", service_id, "revisions", id });
}

/// `/v2/projects/P/locations/L/jobs`.
pub fn jobs(arena: Allocator, project: []const u8, location: []const u8) Allocator.Error![]const u8 {
    return path(arena, project, location, &.{"jobs"});
}

/// `/v2/projects/P/locations/L/jobs/J`.
pub fn job(arena: Allocator, project: []const u8, location: []const u8, id: []const u8) Allocator.Error![]const u8 {
    return path(arena, project, location, &.{ "jobs", id });
}

/// `/v2/projects/P/locations/L/jobs/J/executions`, `J` may be `-`.
pub fn executions(arena: Allocator, project: []const u8, location: []const u8, job_id: []const u8) Allocator.Error![]const u8 {
    return path(arena, project, location, &.{ "jobs", job_id, "executions" });
}

/// `/v2/projects/P/locations/L/jobs/J/executions/E`.
pub fn execution(arena: Allocator, project: []const u8, location: []const u8, job_id: []const u8, id: []const u8) Allocator.Error![]const u8 {
    return path(arena, project, location, &.{ "jobs", job_id, "executions", id });
}

/// `/v2/projects/P/locations/L/operations/O`.
pub fn operation(arena: Allocator, project: []const u8, location: []const u8, id: []const u8) Allocator.Error![]const u8 {
    return path(arena, project, location, &.{ "operations", id });
}

/// `/v2/projects/P/locations/L` and then `segments`, each one escaped
/// path segment: collection names and ids, alternating.
fn path(arena: Allocator, project: []const u8, location: []const u8, segments: []const []const u8) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    writePath(&w.writer, project, location, segments) catch return error.OutOfMemory;
    return w.written();
}

fn writePath(w: *Writer, project: []const u8, location: []const u8, segments: []const []const u8) Writer.Error!void {
    try w.writeAll("/v2/projects/");
    try core.query.writeSegment(w, project);
    try w.writeAll("/locations/");
    try core.query.writeSegment(w, location);
    for (segments) |segment| {
        try w.writeByte('/');
        try core.query.writeSegment(w, segment);
    }
}

pub const ServiceName = struct {
    location: []const u8,
    id: []const u8,
};

/// The parts of `projects/<project>/locations/L/services/S`, pointing
/// into it. Null for another project's name or a malformed one.
pub fn serviceName(name: []const u8, project: []const u8) ?ServiceName {
    const parts = split(1, name, project, .{"services"}) orelse return null;
    return .{ .location = parts[0], .id = parts[1] };
}

pub const RevisionName = struct {
    location: []const u8,
    service: []const u8,
    id: []const u8,
};

/// The parts of `projects/<project>/locations/L/services/S/revisions/R`.
pub fn revisionName(name: []const u8, project: []const u8) ?RevisionName {
    const parts = split(2, name, project, .{ "services", "revisions" }) orelse return null;
    return .{ .location = parts[0], .service = parts[1], .id = parts[2] };
}

pub const JobName = struct {
    location: []const u8,
    id: []const u8,
};

/// The parts of `projects/<project>/locations/L/jobs/J`.
pub fn jobName(name: []const u8, project: []const u8) ?JobName {
    const parts = split(1, name, project, .{"jobs"}) orelse return null;
    return .{ .location = parts[0], .id = parts[1] };
}

pub const ExecutionName = struct {
    location: []const u8,
    job: []const u8,
    id: []const u8,
};

/// The parts of `projects/<project>/locations/L/jobs/J/executions/E`.
pub fn executionName(name: []const u8, project: []const u8) ?ExecutionName {
    const parts = split(2, name, project, .{ "jobs", "executions" }) orelse return null;
    return .{ .location = parts[0], .job = parts[1], .id = parts[2] };
}

pub const OperationName = struct {
    location: []const u8,
    id: []const u8,
};

/// The parts of `projects/<project>/locations/L/operations/O`.
pub fn operationName(name: []const u8, project: []const u8) ?OperationName {
    const parts = split(1, name, project, .{"operations"}) orelse return null;
    return .{ .location = parts[0], .id = parts[1] };
}

/// The location and then each id of
/// `projects/<project>/locations/L/<collections[0]>/X0/...`, pointing into
/// `name`. Null for another project's name, another shape, or an empty
/// segment.
fn split(comptime n: usize, name: []const u8, project: []const u8, collections: [n][]const u8) ?[n + 1][]const u8 {
    var parts = std.mem.splitScalar(u8, name, '/');
    if (!std.mem.eql(u8, parts.next() orelse return null, "projects")) return null;
    if (!std.mem.eql(u8, parts.next() orelse return null, project)) return null;
    if (!std.mem.eql(u8, parts.next() orelse return null, "locations")) return null;
    var out: [n + 1][]const u8 = undefined;
    out[0] = parts.next() orelse return null;
    for (collections, 1..) |collection, i| {
        if (!std.mem.eql(u8, parts.next() orelse return null, collection)) return null;
        out[i] = parts.next() orelse return null;
    }
    if (parts.next() != null) return null;
    for (out) |segment| if (segment.len == 0) return null;
    return out;
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

test "paths and full names: jobs, executions and operations" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/v2/projects/p/locations/us-central1/jobs", try jobs(a, "p", "us-central1"));
    try testing.expectEqualStrings("/v2/projects/p/locations/us-central1/jobs/j", try job(a, "p", "us-central1", "j"));
    try testing.expectEqualStrings("/v2/projects/p/locations/us-central1/jobs/-/executions", try executions(a, "p", "us-central1", "-"));
    try testing.expectEqualStrings("/v2/projects/p/locations/us-central1/jobs/j/executions/j-x7k2p", try execution(a, "p", "us-central1", "j", "j-x7k2p"));
    try testing.expectEqualStrings("/v2/projects/p/locations/us-central1/operations/a6062a44-2b3b", try operation(a, "p", "us-central1", "a6062a44-2b3b"));
    // Every segment is escaped on its own.
    try testing.expectEqualStrings("/v2/projects/p/locations/l/jobs/a%20b/executions/c%3Fd", try execution(a, "p", "l", "a b", "c?d"));

    const j = jobName("projects/p/locations/l/jobs/j", "p").?;
    try testing.expectEqualStrings("l", j.location);
    try testing.expectEqualStrings("j", j.id);
    try testing.expectEqual(null, jobName("projects/p/locations/l/services/j", "p"));
    try testing.expectEqual(null, jobName("projects/q/locations/l/jobs/j", "p"));
    try testing.expectEqual(null, jobName("projects/p/locations//jobs/j", "p"));

    const e = executionName("projects/p/locations/l/jobs/j/executions/j-x7k2p", "p").?;
    try testing.expectEqualStrings("l", e.location);
    try testing.expectEqualStrings("j", e.job);
    try testing.expectEqualStrings("j-x7k2p", e.id);
    try testing.expectEqual(null, executionName("projects/p/locations/l/jobs/j/executions/", "p"));
    try testing.expectEqual(null, executionName("projects/p/locations/l/jobs/j/tasks/t", "p"));
    try testing.expectEqual(null, executionName("projects/p/locations/l/jobs/j/executions/e/tasks/t", "p"));

    const o = operationName("projects/p/locations/us-central1/operations/a6062a44", "p").?;
    try testing.expectEqualStrings("us-central1", o.location);
    try testing.expectEqualStrings("a6062a44", o.id);
    try testing.expectEqual(null, operationName("projects/p/locations/l/operations", "p"));
    try testing.expectEqual(null, operationName("projects/q/locations/l/operations/o", "p"));
    try testing.expectEqual(null, operationName("operations/o", "p"));
}
