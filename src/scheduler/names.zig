//! Request paths and job names. Every segment is one path segment,
//! percent-encoded on its way into a URL.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const core = @import("core");

/// `/v1/projects/P/locations`.
pub fn locations(arena: Allocator, project: []const u8) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    writeProject(&w.writer, project) catch return error.OutOfMemory;
    w.writer.writeAll("/locations") catch return error.OutOfMemory;
    return w.written();
}

/// `/v1/projects/P/locations/L/jobs`.
pub fn jobs(arena: Allocator, project: []const u8, location: []const u8) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    writeJobs(&w.writer, project, location) catch return error.OutOfMemory;
    return w.written();
}

/// `/v1/projects/P/locations/L/jobs/J`.
pub fn job(arena: Allocator, project: []const u8, location: []const u8, id: []const u8) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    writeJobs(&w.writer, project, location) catch return error.OutOfMemory;
    w.writer.writeByte('/') catch return error.OutOfMemory;
    core.query.writeSegment(&w.writer, id) catch return error.OutOfMemory;
    return w.written();
}

fn writeProject(w: *Writer, project: []const u8) Writer.Error!void {
    try w.writeAll("/v1/projects/");
    try core.query.writeSegment(w, project);
}

fn writeJobs(w: *Writer, project: []const u8, location: []const u8) Writer.Error!void {
    try writeProject(w, project);
    try w.writeAll("/locations/");
    try core.query.writeSegment(w, location);
    try w.writeAll("/jobs");
}

pub const JobName = struct {
    location: []const u8,
    id: []const u8,
};

/// The parts of a full `projects/<project>/locations/L/jobs/J` name,
/// pointing into it. Null for another project's name or a malformed one.
pub fn jobName(name: []const u8, project: []const u8) ?JobName {
    var parts = std.mem.splitScalar(u8, name, '/');
    if (!std.mem.eql(u8, parts.next() orelse return null, "projects")) return null;
    const p = parts.next() orelse return null;
    if (!std.mem.eql(u8, parts.next() orelse return null, "locations")) return null;
    const location = parts.next() orelse return null;
    if (!std.mem.eql(u8, parts.next() orelse return null, "jobs")) return null;
    const id = parts.next() orelse return null;
    if (parts.next() != null) return null;
    if (!std.mem.eql(u8, p, project) or location.len == 0 or id.len == 0) return null;
    return .{ .location = location, .id = id };
}

const testing = std.testing;

test "paths and full names: this project's jobs, nobody else's" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/v1/projects/p/locations", try locations(a, "p"));
    try testing.expectEqualStrings("/v1/projects/p/locations/us-central1/jobs", try jobs(a, "p", "us-central1"));
    try testing.expectEqualStrings("/v1/projects/p/locations/us-central1/jobs/j-1", try job(a, "p", "us-central1", "j-1"));

    const parsed = jobName("projects/p/locations/us-central1/jobs/j-1", "p").?;
    try testing.expectEqualStrings("us-central1", parsed.location);
    try testing.expectEqualStrings("j-1", parsed.id);
    try testing.expectEqual(null, jobName("projects/q/locations/l/jobs/j", "p"));
    try testing.expectEqual(null, jobName("projects/p/locations/l/jobs/", "p"));
    try testing.expectEqual(null, jobName("projects/p/locations/l/jobs/j/x", "p"));
    try testing.expectEqual(null, jobName("projects/p/locations/l", "p"));
    try testing.expectEqual(null, jobName("projects/p/topics/t", "p"));
    try testing.expectEqual(null, jobName("j-1", "p"));
}
