//! A read's filter, written as Cloud Monitoring reads one: the metric type
//! first, then each condition, joined by AND. Values are quoted, their `"`
//! and `\` escaped with a backslash: measured on 2026-10-18, a label value
//! `a"b\c` matched `metric.labels.k = "a\"b\\c"`, and single quotes were
//! refused.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const types = @import("types.zig");
const validate = @import("validate.zig");

/// Why a filter will not be sent, or null.
pub fn problem(f: types.Filter) ?[]const u8 {
    for (f.metric_labels) |m| if (matchProblem(m)) |p| return p;
    if (f.resource_type) |t| if (!validate.isResourceType(t)) return "a resource type is letters, digits, _ and ., at most 256";
    for (f.resource_labels) |m| if (matchProblem(m)) |p| return p;
    if (f.raw) |r| {
        if (r.len == 0) return "a raw filter is not empty; leave it null";
        if (!std.unicode.utf8ValidateSlice(r)) return "a raw filter is UTF-8";
    }
    return null;
}

fn matchProblem(m: types.Match) ?[]const u8 {
    if (!validate.isLabelKey(m.key)) return "a label key is a letter, then letters, digits and _, at most 100 bytes";
    if (!std.unicode.utf8ValidateSlice(m.value)) return "a value to match is UTF-8";
    for (m.value) |c| if (c < 0x20 or c == 0x7f) return "a value to match has no control characters";
    return null;
}

/// The filter for `metric_type`'s series that `f`, already checked,
/// selects.
pub fn build(arena: Allocator, metric_type: []const u8, f: types.Filter) Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    write(&out.writer, metric_type, f) catch return error.OutOfMemory;
    return out.written();
}

fn write(w: *Writer, metric_type: []const u8, f: types.Filter) Writer.Error!void {
    try w.writeAll("metric.type = ");
    try quoted(w, metric_type);
    for (f.metric_labels) |m| try condition(w, "metric.labels.", m);
    if (f.resource_type) |t| {
        try w.writeAll(" AND resource.type = ");
        try quoted(w, t);
    }
    for (f.resource_labels) |m| try condition(w, "resource.labels.", m);
    if (f.raw) |r| try w.print(" AND {s}", .{r});
}

fn condition(w: *Writer, prefix: []const u8, m: types.Match) Writer.Error!void {
    try w.print(" AND {s}{s} ", .{ prefix, m.key });
    switch (m.op) {
        .equals => try w.writeAll("= "),
        .not_equals => try w.writeAll("!= "),
        .starts_with, .ends_with, .has_substring => try w.print("= {t}(", .{m.op}),
    }
    try quoted(w, m.value);
    switch (m.op) {
        .starts_with, .ends_with, .has_substring => try w.writeByte(')'),
        else => {},
    }
}

/// `text` in double quotes, its `"` and `\` escaped.
pub fn quoted(w: *Writer, text: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (text) |c| {
        if (c == '"' or c == '\\') try w.writeByte('\\');
        try w.writeByte(c);
    }
    try w.writeByte('"');
}

const testing = std.testing;

test "build: the type, then each condition, joined by AND" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("metric.type = \"custom.googleapis.com/a\"", try build(a, "custom.googleapis.com/a", .{}));
    try testing.expectEqualStrings(
        \\metric.type = "custom.googleapis.com/a" AND metric.labels.region = "eu" AND metric.labels.code != "200" AND metric.labels.path = starts_with("/api") AND metric.labels.host = ends_with(".internal") AND metric.labels.agent = has_substring("bot") AND resource.type = "generic_task" AND resource.labels.job = "api" AND metric.labels.code = one_of("500", "503")
    , try build(a, "custom.googleapis.com/a", .{
        .metric_labels = &.{
            .{ .key = "region", .value = "eu" },
            .{ .key = "code", .op = .not_equals, .value = "200" },
            .{ .key = "path", .op = .starts_with, .value = "/api" },
            .{ .key = "host", .op = .ends_with, .value = ".internal" },
            .{ .key = "agent", .op = .has_substring, .value = "bot" },
        },
        .resource_type = "generic_task",
        .resource_labels = &.{.{ .key = "job", .value = "api" }},
        .raw = "metric.labels.code = one_of(\"500\", \"503\")",
    }));
}

test "build: quotes and backslashes escaped, as production matched them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        \\metric.type = "custom.googleapis.com/zigps-m0-62b2c8/gauge" AND metric.labels.k = "a\"b\\c"
    , try build(arena.allocator(), "custom.googleapis.com/zigps-m0-62b2c8/gauge", .{ .metric_labels = &.{.{ .key = "k", .value = "a\"b\\c" }} }));
}

test "problem: keys, values, resource types and raw filters it will not send" {
    try testing.expectEqual(null, problem(.{ .metric_labels = &.{.{ .key = "Region", .value = "é \"q\"" }}, .resource_type = "k8s_container", .raw = "x" }));
    const cases = [_]types.Filter{
        .{ .metric_labels = &.{.{ .key = "a.b", .value = "v" }} },
        .{ .metric_labels = &.{.{ .key = "a", .value = "\xff" }} },
        .{ .metric_labels = &.{.{ .key = "a", .value = "line\nbreak" }} },
        .{ .resource_labels = &.{.{ .key = "1z", .value = "v" }} },
        .{ .resource_type = "a b" },
        .{ .raw = "" },
        .{ .raw = "\xc3" },
    };
    for (cases) |c| try testing.expect(problem(c) != null);
}
