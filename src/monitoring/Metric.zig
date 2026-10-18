//! A handle on one metric type: its descriptor, created, read and deleted.
//! Making one sends nothing. It borrows the client and the type, so it must
//! not outlive either.

const Metric = @This();

const std = @import("std");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Error = @import("errors.zig").Error;

client: *Client,
/// A whole type, such as "custom.googleapis.com/shop/orders".
type: []const u8,

/// Creates the metric's descriptor, which says its kind, value type, unit,
/// description and labels; or, when it exists with the same kind and value
/// type, answers it, as production did when measured. One with another kind
/// or value type is `error.AlreadyExists`. A first write creates a
/// descriptor too, with string labels and no description: create one first
/// for a unit, a description or labels of another type.
///
/// A descriptor just made may not read back for about 2 s: production
/// answered 404 for its first 1.4 s when measured, and once 404 again after
/// a 200. A write straight after the create was taken.
pub fn create(self: Metric, config: types.MetricConfig) Error!types.Owned(types.MetricInfo) {
    const c = self.client;
    rpc.begin(c);
    if (validate.configProblem(self.type, config)) |p| {
        if (c.diagnostics) |d| d.print("invalid descriptor: {s}", .{p.reason});
        return switch (p.err) {
            .metric_type => error.InvalidMetricType,
            .label => error.InvalidLabel,
            .point, .resource => error.InvalidOptions,
        };
    }
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try names.collection(a, c.project, .metric_descriptors);
    const body = try codec.encodeDescriptor(a, self.type, config);
    return fetch(c, a, .{ .method = .POST, .path = path, .body = body });
}

/// The metric's descriptor. `error.NotFound` when it has none, which a
/// descriptor created moments ago can still be.
pub fn get(self: Metric) Error!types.Owned(types.MetricInfo) {
    const c = self.client;
    rpc.begin(c);
    try self.checkType();
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    return fetch(c, a, .{ .method = .GET, .path = try names.metricDescriptor(a, c.project, self.type) });
}

/// Deletes the metric's descriptor, which makes its data unreadable. A
/// later write creates it again, with string labels and no unit; so can a
/// create at once, of another kind if need be. `error.NotFound` when it has
/// none.
pub fn delete(self: Metric) Error!void {
    const c = self.client;
    rpc.begin(c);
    try self.checkType();
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    try rpc.executeDiscard(c, .{ .method = .DELETE, .path = try names.metricDescriptor(a, c.project, self.type) });
}

fn checkType(self: Metric) Error!void {
    if (validate.metricTypeProblem(self.type)) |reason| {
        if (self.client.diagnostics) |d| d.print("invalid metric type: {s}", .{reason});
        return error.InvalidMetricType;
    }
}

fn fetch(c: *Client, scratch: std.mem.Allocator, call: rpc.Call) Error!types.Owned(types.MetricInfo) {
    var result: types.Owned(types.MetricInfo) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, call);
    result.value = codec.decodeMetricInfo(result.arena.allocator(), scratch, body) catch |err|
        return rpc.decodeFailed(c, err, "metric descriptor");
    return result;
}
