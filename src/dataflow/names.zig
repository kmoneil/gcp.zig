//! Request paths. Every segment is one path segment, percent-encoded on
//! its way into a URL. v1b3 is the only REST version, its "b3"
//! permanent; paths take the project and location as raw segments, not
//! AIP names.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const core = @import("core");

/// `/v1b3/projects/P/jobs:aggregated`: every region's jobs in one list.
pub fn aggregated(arena: Allocator, project: []const u8) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    w.writer.writeAll("/v1b3/projects/") catch return error.OutOfMemory;
    core.query.writeSegment(&w.writer, project) catch return error.OutOfMemory;
    w.writer.writeAll("/jobs:aggregated") catch return error.OutOfMemory;
    return w.written();
}

/// `/v1b3/projects/P/locations/L/jobs`.
pub fn jobs(arena: Allocator, project: []const u8, location: []const u8) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    writeJobs(&w.writer, project, location) catch return error.OutOfMemory;
    return w.written();
}

/// `/v1b3/projects/P/locations/L/jobs/ID`.
pub fn job(arena: Allocator, project: []const u8, location: []const u8, id: []const u8) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    writeJobs(&w.writer, project, location) catch return error.OutOfMemory;
    w.writer.writeByte('/') catch return error.OutOfMemory;
    core.query.writeSegment(&w.writer, id) catch return error.OutOfMemory;
    return w.written();
}

/// `/v1b3/projects/P/locations/L/jobs/ID/messages`.
pub fn messages(arena: Allocator, project: []const u8, location: []const u8, id: []const u8) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    writeJobs(&w.writer, project, location) catch return error.OutOfMemory;
    w.writer.writeByte('/') catch return error.OutOfMemory;
    core.query.writeSegment(&w.writer, id) catch return error.OutOfMemory;
    w.writer.writeAll("/messages") catch return error.OutOfMemory;
    return w.written();
}

fn writeJobs(w: *Writer, project: []const u8, location: []const u8) Writer.Error!void {
    try w.writeAll("/v1b3/projects/");
    try core.query.writeSegment(w, project);
    try w.writeAll("/locations/");
    try core.query.writeSegment(w, location);
    try w.writeAll("/jobs");
}

const testing = std.testing;

test "paths: the aggregated list's colon survives, segments are encoded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/v1b3/projects/p/jobs:aggregated", try aggregated(a, "p"));
    try testing.expectEqualStrings("/v1b3/projects/p/locations/us-central1/jobs", try jobs(a, "p", "us-central1"));
    try testing.expectEqualStrings("/v1b3/projects/p/locations/us-central1/jobs/2026-10-20_07_09_34-85", try job(a, "p", "us-central1", "2026-10-20_07_09_34-85"));
    try testing.expectEqualStrings("/v1b3/projects/p/locations/us-central1/jobs/j/messages", try messages(a, "p", "us-central1", "j"));
}
