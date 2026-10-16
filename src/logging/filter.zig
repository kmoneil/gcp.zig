//! The filter a query sends: the caller's own, passed through as written,
//! and the clauses the module adds from `QueryOptions`, joined so the
//! caller's meaning cannot change:
//!
//!     (
//!     <caller's filter>
//!     )
//!     AND timestamp >= "2026-10-16T09:00:00Z"
//!     AND severity >= WARNING
//!
//! In the Logging query language OR binds tighter than AND, so `X AND c`
//! already applies `c` to all of X; the parentheses are for readers who
//! expect the usual rule, and the line breaks keep a trailing `--` comment
//! in the caller's filter from swallowing a clause. An empty caller filter
//! gives the clauses alone, with no leading `AND`, which the API refuses.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const core = @import("core");
const types = @import("types.zig");
const validate = @import("validate.zig");

/// What is wrong with a filter or a clause, for `Diagnostics`.
pub const Problem = enum {
    filter_not_utf8,
    log_id_not_quotable,
    resource_type_not_quotable,
    severity_unnamed,
    since_out_of_range,
    until_out_of_range,
    too_long,

    pub fn text(p: Problem) []const u8 {
        return switch (p) {
            .filter_not_utf8 => "invalid filter: it is not UTF-8",
            .log_id_not_quotable => "invalid log id: control characters and text that is not UTF-8 cannot be quoted in a filter",
            .resource_type_not_quotable => "invalid resource type: control characters and text that is not UTF-8 cannot be quoted in a filter",
            .severity_unnamed => "invalid min_severity: the query language names only DEFAULT, DEBUG, INFO, NOTICE, WARNING, ERROR, CRITICAL, ALERT and EMERGENCY",
            .since_out_of_range => "invalid since: outside 0001-01-01 to 9999-12-31",
            .until_out_of_range => "invalid until: outside 0001-01-01 to 9999-12-31",
            .too_long => "invalid filter: over 20,000 characters once the clauses are joined",
        };
    }
};

/// The parts of `QueryOptions` that become the filter.
pub const Parts = struct {
    filter: []const u8 = "",
    since: ?std.Io.Timestamp = null,
    until: ?std.Io.Timestamp = null,
    min_severity: ?types.Severity = null,
    log_id: ?[]const u8 = null,
    resource_type: ?[]const u8 = null,
};

/// The first thing wrong with `parts`, before anything is written.
pub fn check(parts: Parts) ?Problem {
    if (!std.unicode.utf8ValidateSlice(parts.filter)) return .filter_not_utf8;
    if (parts.log_id) |v| if (!validate.isClauseValue(v)) return .log_id_not_quotable;
    if (parts.resource_type) |v| if (!validate.isClauseValue(v)) return .resource_type_not_quotable;
    if (parts.min_severity) |s| if (s.name() == null) return .severity_unnamed;
    if (parts.since) |t| if (!core.timestamp.inRange(t)) return .since_out_of_range;
    if (parts.until) |t| if (!core.timestamp.inRange(t)) return .until_out_of_range;
    return null;
}

pub const Joined = union(enum) { ok: []const u8, refused: Problem };

/// The joined filter, in `arena`, or the problem with it. "" when there is
/// nothing to filter by.
pub fn join(arena: Allocator, parts: Parts) Allocator.Error!Joined {
    if (check(parts)) |p| return .{ .refused = p };
    var out: Writer.Allocating = .init(arena);
    write(&out.writer, parts) catch return error.OutOfMemory;
    const text = try out.toOwnedSlice();
    if (validate.charCount(text) > validate.max_filter_chars) return .{ .refused = .too_long };
    return .{ .ok = text };
}

fn write(w: *Writer, parts: Parts) Writer.Error!void {
    var any = false;
    if (parts.filter.len > 0) {
        try w.writeAll("(\n");
        try w.writeAll(parts.filter);
        try w.writeAll("\n)");
        any = true;
    }
    if (parts.since) |t| {
        try clause(w, &any);
        try w.writeAll("timestamp >= ");
        try writeTime(w, t);
    }
    if (parts.until) |t| {
        try clause(w, &any);
        try w.writeAll("timestamp < ");
        try writeTime(w, t);
    }
    if (parts.min_severity) |s| {
        try clause(w, &any);
        try w.print("severity >= {s}", .{s.name().?});
    }
    if (parts.log_id) |id| {
        try clause(w, &any);
        try w.writeAll("log_id(");
        try writeQuoted(w, id);
        try w.writeAll(")");
    }
    if (parts.resource_type) |t| {
        try clause(w, &any);
        try w.writeAll("resource.type = ");
        try writeQuoted(w, t);
    }
}

fn clause(w: *Writer, any: *bool) Writer.Error!void {
    if (any.*) try w.writeAll("\nAND ");
    any.* = true;
}

/// A timestamp literal, in UTC with `Z` and every digit it needs.
pub fn writeTime(w: *Writer, t: std.Io.Timestamp) Writer.Error!void {
    var buf: [core.timestamp.max_len]u8 = undefined;
    try w.print("\"{s}\"", .{core.timestamp.format(&buf, t)});
}

/// A string literal: double-quoted, with `"` and `\` escaped by a
/// backslash and a tab written `\t`, each of which production read back
/// on 2026-10-16. `text` has passed `validate.isClauseValue`.
pub fn writeQuoted(w: *Writer, text: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (text) |c| switch (c) {
        '"', '\\' => {
            try w.writeByte('\\');
            try w.writeByte(c);
        },
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

const testing = std.testing;
const repeat = core.testing.repeat;

fn joined(arena: Allocator, parts: Parts) ![]const u8 {
    return switch (try join(arena, parts)) {
        .ok => |text| text,
        .refused => |p| {
            std.debug.print("refused: {s}\n", .{p.text()});
            return error.TestUnexpectedRefusal;
        },
    };
}

fn refusal(arena: Allocator, parts: Parts) !Problem {
    return switch (try join(arena, parts)) {
        .ok => error.TestExpectedRefusal,
        .refused => |p| p,
    };
}

const t0: std.Io.Timestamp = .{ .nanoseconds = 1_792_141_200 * std.time.ns_per_s };

test "join: nothing, the filter alone, the clauses alone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("", try joined(a, .{}));
    try testing.expectEqualStrings("(\nseverity>=ERROR\n)", try joined(a, .{ .filter = "severity>=ERROR" }));
    // No leading AND: the API refuses one as unparseable.
    try testing.expectEqualStrings(
        "timestamp >= \"2026-10-16T09:00:00Z\"\nAND severity >= WARNING",
        try joined(a, .{ .since = t0, .min_severity = .warning }),
    );
}

test "join: every clause, in order, after the caller's filter" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text = try joined(arena.allocator(), .{
        .filter = "a OR b -- trailing comment",
        .since = t0,
        .until = .{ .nanoseconds = t0.nanoseconds + 3_600 * std.time.ns_per_s + 5 },
        .min_severity = .@"error",
        .log_id = "run.googleapis.com/stderr",
        .resource_type = "cloud_run_revision",
    });
    try testing.expectEqualStrings(
        \\(
        \\a OR b -- trailing comment
        \\)
        \\AND timestamp >= "2026-10-16T09:00:00Z"
        \\AND timestamp < "2026-10-16T10:00:00.000000005Z"
        \\AND severity >= ERROR
        \\AND log_id("run.googleapis.com/stderr")
        \\AND resource.type = "cloud_run_revision"
    , text);
}

test "join: quoting escapes quotation marks and backslashes, and writes a tab as \\t" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        "log_id(\"a\\\"b\\\\c d\u{e9}\\tx\")",
        try joined(arena.allocator(), .{ .log_id = "a\"b\\c d\u{e9}\tx" }),
    );
}

test "join: each refusal, each with an input only it refuses" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(.filter_not_utf8, try refusal(a, .{ .filter = "a\xffb" }));
    // A control character in the caller's own filter is theirs to send.
    _ = try joined(a, .{ .filter = "a\tb\nc" });
    try testing.expectEqual(.log_id_not_quotable, try refusal(a, .{ .log_id = "a\nb" }));
    try testing.expectEqual(.resource_type_not_quotable, try refusal(a, .{ .resource_type = "a\nb" }));
    try testing.expectEqual(.severity_unnamed, try refusal(a, .{ .min_severity = @fromBackingInt(@intCast(450)) }));
    try testing.expectEqual(.severity_unnamed, try refusal(a, .{ .min_severity = .unknown }));
    try testing.expectEqual(.since_out_of_range, try refusal(a, .{ .since = .{ .nanoseconds = core.timestamp.max.nanoseconds + 1 } }));
    try testing.expectEqual(.until_out_of_range, try refusal(a, .{ .until = .{ .nanoseconds = core.timestamp.min.nanoseconds - 1 } }));
}

test "join: the 20,000 characters count on the joined text, in characters" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // "(\n" and "\n)" add four characters.
    const fits = repeat("x", validate.max_filter_chars - 4);
    _ = try joined(a, .{ .filter = fits });
    try testing.expectEqual(.too_long, try refusal(a, .{ .filter = fits ++ "x" }));
    // Two-byte characters count once each.
    const wide = repeat("\u{e9}", validate.max_filter_chars - 4);
    _ = try joined(a, .{ .filter = wide });
    // The clauses count too.
    try testing.expectEqual(.too_long, try refusal(a, .{ .filter = fits, .min_severity = .info }));
}

test "join: every allocation failure is OutOfMemory without leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            _ = try join(arena.allocator(), .{ .filter = "a", .since = t0, .log_id = "x/y" });
        }
    }.run, .{});
}
