//! Request paths. Every id is one path segment, percent-encoded on its way
//! into a URL.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const core = @import("core");

/// `/bigquery/v2/projects/P` and then `segments`, each one escaped path
/// segment: collection names and ids, alternating.
pub fn path(arena: Allocator, project: []const u8, segments: []const []const u8) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    writePath(&w.writer, project, segments) catch return error.OutOfMemory;
    return w.written();
}

fn writePath(w: *Writer, project: []const u8, segments: []const []const u8) Writer.Error!void {
    try w.writeAll("/bigquery/v2/projects/");
    try core.query.writeSegment(w, project);
    for (segments) |segment| {
        try w.writeByte('/');
        try core.query.writeSegment(w, segment);
    }
}

/// `.../datasets`.
pub fn datasets(arena: Allocator, project: []const u8) Allocator.Error![]const u8 {
    return path(arena, project, &.{"datasets"});
}

/// `.../datasets/D`.
pub fn dataset(arena: Allocator, project: []const u8, id: []const u8) Allocator.Error![]const u8 {
    return path(arena, project, &.{ "datasets", id });
}

/// `.../datasets/D/tables`.
pub fn tables(arena: Allocator, project: []const u8, dataset_id: []const u8) Allocator.Error![]const u8 {
    return path(arena, project, &.{ "datasets", dataset_id, "tables" });
}

/// `.../datasets/D/tables/T`.
pub fn table(arena: Allocator, project: []const u8, dataset_id: []const u8, id: []const u8) Allocator.Error![]const u8 {
    return path(arena, project, &.{ "datasets", dataset_id, "tables", id });
}

/// `.../jobs`.
pub fn jobs(arena: Allocator, project: []const u8) Allocator.Error![]const u8 {
    return path(arena, project, &.{"jobs"});
}

/// `.../jobs/J`.
pub fn job(arena: Allocator, project: []const u8, id: []const u8) Allocator.Error![]const u8 {
    return path(arena, project, &.{ "jobs", id });
}

/// `.../queries`, where `jobs.query` runs one.
pub fn queries(arena: Allocator, project: []const u8) Allocator.Error![]const u8 {
    return path(arena, project, &.{"queries"});
}

/// `.../queries/J`, a job's results.
pub fn queryResults(arena: Allocator, project: []const u8, job_id: []const u8) Allocator.Error![]const u8 {
    return path(arena, project, &.{ "queries", job_id });
}

const testing = std.testing;

test "paths: every id one escaped segment" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/bigquery/v2/projects/p/datasets", try datasets(a, "p"));
    try testing.expectEqualStrings("/bigquery/v2/projects/bigquery-public-data/datasets/samples", try dataset(a, "bigquery-public-data", "samples"));
    try testing.expectEqualStrings("/bigquery/v2/projects/p/datasets/d/tables", try tables(a, "p", "d"));
    try testing.expectEqualStrings("/bigquery/v2/projects/p/datasets/d/tables/t", try table(a, "p", "d", "t"));
    try testing.expectEqualStrings("/bigquery/v2/projects/p/jobs", try jobs(a, "p"));
    try testing.expectEqualStrings("/bigquery/v2/projects/p/jobs/job_x-1", try job(a, "p", "job_x-1"));
    try testing.expectEqualStrings("/bigquery/v2/projects/p/queries", try queries(a, "p"));
    try testing.expectEqualStrings("/bigquery/v2/projects/p/queries/job_x-1", try queryResults(a, "p", "job_x-1"));
    // A table id may hold spaces and other letters: escaped, never split.
    try testing.expectEqualStrings("/bigquery/v2/projects/p/datasets/d/tables/a%20b%2Fc", try table(a, "p", "d", "a b/c"));
}
