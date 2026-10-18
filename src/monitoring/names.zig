//! Request paths. A metric type goes into a descriptor's path with its
//! slashes literal: measured on 2026-10-18, `%2F` in their place was
//! refused as an invalid metric name.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const core = @import("core");

pub const Collection = enum {
    metric_descriptors,
    resource_descriptors,
    time_series,

    fn segment(c: Collection) []const u8 {
        return switch (c) {
            .metric_descriptors => "metricDescriptors",
            .resource_descriptors => "monitoredResourceDescriptors",
            .time_series => "timeSeries",
        };
    }
};

/// `/v3/projects/P/<collection>`.
pub fn writeCollection(w: *Writer, project: []const u8, c: Collection) Writer.Error!void {
    try w.writeAll("/v3/projects/");
    try core.query.writeSegment(w, project);
    try w.writeByte('/');
    try w.writeAll(c.segment());
}

pub fn collection(arena: Allocator, project: []const u8, c: Collection) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    writeCollection(&w.writer, project, c) catch return error.OutOfMemory;
    return w.written();
}

/// `/v3/projects/P/metricDescriptors/<type>`, the type's slashes literal.
pub fn metricDescriptor(arena: Allocator, project: []const u8, metric_type: []const u8) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    writeCollection(&w.writer, project, .metric_descriptors) catch return error.OutOfMemory;
    w.writer.writeByte('/') catch return error.OutOfMemory;
    core.query.writePath(&w.writer, metric_type) catch return error.OutOfMemory;
    return w.written();
}

/// `/v3/projects/P/monitoredResourceDescriptors/<type>`.
pub fn resourceType(arena: Allocator, project: []const u8, type_name: []const u8) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    writeCollection(&w.writer, project, .resource_descriptors) catch return error.OutOfMemory;
    w.writer.writeByte('/') catch return error.OutOfMemory;
    core.query.writeSegment(&w.writer, type_name) catch return error.OutOfMemory;
    return w.written();
}

const testing = std.testing;

test "paths: a metric type keeps its slashes, a project is one segment" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/v3/projects/p/timeSeries", try collection(a, "p", .time_series));
    try testing.expectEqualStrings("/v3/projects/example.com:p/metricDescriptors", try collection(a, "example.com:p", .metric_descriptors));
    try testing.expectEqualStrings("/v3/projects/p/metricDescriptors/custom.googleapis.com/shop/orders", try metricDescriptor(a, "p", "custom.googleapis.com/shop/orders"));
    try testing.expectEqualStrings("/v3/projects/p/monitoredResourceDescriptors/generic_task", try resourceType(a, "p", "generic_task"));
}
