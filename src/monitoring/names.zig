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
    alerts,
    alert_policies,
    snoozes,

    fn segment(c: Collection) []const u8 {
        return switch (c) {
            .metric_descriptors => "metricDescriptors",
            .resource_descriptors => "monitoredResourceDescriptors",
            .time_series => "timeSeries",
            .alerts => "alerts",
            .alert_policies => "alertPolicies",
            .snoozes => "snoozes",
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

/// `/v3/projects/P/alerts/<id>`.
pub fn alert(arena: Allocator, project: []const u8, id: []const u8) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    writeCollection(&w.writer, project, .alerts) catch return error.OutOfMemory;
    w.writer.writeByte('/') catch return error.OutOfMemory;
    core.query.writeSegment(&w.writer, id) catch return error.OutOfMemory;
    return w.written();
}

/// `/v3/projects/P/alertPolicies/<id>`.
pub fn alertPolicy(arena: Allocator, project: []const u8, id: []const u8) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    writeCollection(&w.writer, project, .alert_policies) catch return error.OutOfMemory;
    w.writer.writeByte('/') catch return error.OutOfMemory;
    core.query.writeSegment(&w.writer, id) catch return error.OutOfMemory;
    return w.written();
}

/// `/v3/projects/P/snoozes/<id>`.
pub fn snooze(arena: Allocator, project: []const u8, id: []const u8) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    writeCollection(&w.writer, project, .snoozes) catch return error.OutOfMemory;
    w.writer.writeByte('/') catch return error.OutOfMemory;
    core.query.writeSegment(&w.writer, id) catch return error.OutOfMemory;
    return w.written();
}

/// The id in `id_or_name`: the trailing segment when it is exactly
/// `projects/<project>/alerts/<id>`, the input itself when it is no full
/// name at all. Null for another project's name or a malformed one.
pub fn alertId(id_or_name: []const u8, project: []const u8) ?[]const u8 {
    return idIn(id_or_name, project, .alerts);
}

/// `alertId` for `projects/<project>/alertPolicies/<id>`.
pub fn alertPolicyId(id_or_name: []const u8, project: []const u8) ?[]const u8 {
    return idIn(id_or_name, project, .alert_policies);
}

/// `alertId` for `projects/<project>/snoozes/<id>`.
pub fn snoozeId(id_or_name: []const u8, project: []const u8) ?[]const u8 {
    return idIn(id_or_name, project, .snoozes);
}

fn idIn(id_or_name: []const u8, project: []const u8, c: Collection) ?[]const u8 {
    if (!std.mem.startsWith(u8, id_or_name, "projects/")) return id_or_name;
    var parts = std.mem.splitScalar(u8, id_or_name, '/');
    _ = parts.next();
    const p = parts.next() orelse return null;
    if (!std.mem.eql(u8, parts.next() orelse return null, c.segment())) return null;
    const id = parts.next() orelse return null;
    if (parts.next() != null) return null;
    if (!std.mem.eql(u8, p, project) or id.len == 0) return null;
    return id;
}

test "alert paths and names: a bare id, this project's full name, nobody else's" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("/v3/projects/p/alerts/9", try alert(arena.allocator(), "p", "9"));
    try std.testing.expectEqualStrings("9", alertId("9", "p").?);
    try std.testing.expectEqualStrings("9", alertId("projects/p/alerts/9", "p").?);
    try std.testing.expectEqual(null, alertId("projects/q/alerts/9", "p"));
    try std.testing.expectEqual(null, alertId("projects/p/alerts/", "p"));
    try std.testing.expectEqual(null, alertId("projects/p/alerts/9/x", "p"));
    try std.testing.expectEqual(null, alertId("projects/p/alertPolicies/9", "p"));
    try std.testing.expectEqual(null, alertId("projects/p", "p"));
}

test "alert policy paths and names" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("/v3/projects/p/alertPolicies/95", try alertPolicy(arena.allocator(), "p", "95"));
    try std.testing.expectEqualStrings("95", alertPolicyId("95", "p").?);
    try std.testing.expectEqualStrings("95", alertPolicyId("projects/p/alertPolicies/95", "p").?);
    try std.testing.expectEqual(null, alertPolicyId("projects/q/alertPolicies/95", "p"));
    try std.testing.expectEqual(null, alertPolicyId("projects/p/alerts/95", "p"));
    try std.testing.expectEqual(null, alertPolicyId("projects/p/alertPolicies/95/conditions/1", "p"));
    try std.testing.expectEqualStrings("/v3/projects/p/snoozes/14", try snooze(arena.allocator(), "p", "14"));
    try std.testing.expectEqualStrings("14", snoozeId("projects/p/snoozes/14", "p").?);
    try std.testing.expectEqual(null, snoozeId("projects/p/alertPolicies/14", "p"));
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
