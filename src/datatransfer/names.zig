//! Resource names and request paths. Every call about a config or a run
//! takes its name as production gave it, `projects/{p}/locations/{l}/
//! transferConfigs/{id}[/runs/{run}]`, the project by number or id; this
//! file takes one apart, checks each segment, and writes it back as a
//! path, each segment escaped.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const core = @import("core");
const validate = @import("validate.zig");

/// A config's name, taken apart.
pub const ConfigName = struct {
    project: []const u8,
    location: []const u8,
    id: []const u8,
};

/// A run's name, taken apart.
pub const RunName = struct {
    config: ConfigName,
    id: []const u8,
};

pub const NameError = error{
    /// Not `projects/{p}/locations/{l}/transferConfigs/{id}`: a
    /// regionless name among them, which production answers only for a
    /// config in the US.
    NotConfigName,
    NotRunName,
};

/// `name` as a config's, every segment checked.
pub fn parseConfig(name: []const u8) NameError!ConfigName {
    var it = std.mem.splitScalar(u8, name, '/');
    const parts = take(&it, 6) orelse return error.NotConfigName;
    if (it.next() != null) return error.NotConfigName;
    return configOf(parts) orelse error.NotConfigName;
}

/// `name` as a run's, every segment checked.
pub fn parseRun(name: []const u8) NameError!RunName {
    var it = std.mem.splitScalar(u8, name, '/');
    const parts = take(&it, 8) orelse return error.NotRunName;
    if (it.next() != null) return error.NotRunName;
    const config = configOf(parts[0..6].*) orelse return error.NotRunName;
    if (!std.mem.eql(u8, parts[6], "runs") or !validate.isResourceId(parts[7])) return error.NotRunName;
    return .{ .config = config, .id = parts[7] };
}

fn take(it: *std.mem.SplitIterator(u8, .scalar), comptime n: usize) ?[n][]const u8 {
    var out: [n][]const u8 = undefined;
    for (&out) |*p| p.* = it.next() orelse return null;
    return out;
}

fn configOf(parts: [6][]const u8) ?ConfigName {
    if (!std.mem.eql(u8, parts[0], "projects") or !std.mem.eql(u8, parts[2], "locations") or !std.mem.eql(u8, parts[4], "transferConfigs")) return null;
    if (!core.names.isProjectId(parts[1]) or !validate.isLocation(parts[3]) or !validate.isResourceId(parts[5])) return null;
    return .{ .project = parts[1], .location = parts[3], .id = parts[5] };
}

/// `projects/{p}/locations/{l}/transferConfigs/{id}`: a config's name, for
/// a caller that has its location and id.
pub fn configName(arena: Allocator, c: ConfigName) Allocator.Error![]const u8 {
    return std.mem.concat(arena, u8, &.{ "projects/", c.project, "/locations/", c.location, "/transferConfigs/", c.id });
}

/// `/v1/projects/{p}/locations/{l}/transferConfigs/{id}`, and then
/// `segments`, each escaped.
pub fn configPath(arena: Allocator, c: ConfigName, segments: []const []const u8) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    writeConfig(&w.writer, c, segments) catch return error.OutOfMemory;
    return w.written();
}

fn writeConfig(w: *Writer, c: ConfigName, segments: []const []const u8) Writer.Error!void {
    try writeLocation(w, c.project, c.location);
    try w.writeAll("/transferConfigs/");
    try core.query.writeSegment(w, c.id);
    for (segments) |s| {
        try w.writeByte('/');
        try core.query.writeSegment(w, s);
    }
}

fn writeLocation(w: *Writer, project: []const u8, location: []const u8) Writer.Error!void {
    try w.writeAll("/v1/projects/");
    try core.query.writeSegment(w, project);
    try w.writeAll("/locations/");
    try core.query.writeSegment(w, location);
}

/// `/v1/projects/{p}/locations`.
pub fn locations(arena: Allocator, project: []const u8) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    (blk: {
        w.writer.writeAll("/v1/projects/") catch |e| break :blk e;
        core.query.writeSegment(&w.writer, project) catch |e| break :blk e;
        w.writer.writeAll("/locations") catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return w.written();
}

/// `/v1/projects/{p}/locations/{l}/transferConfigs`.
pub fn configs(arena: Allocator, project: []const u8, location: []const u8) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    (blk: {
        writeLocation(&w.writer, project, location) catch |e| break :blk e;
        w.writer.writeAll("/transferConfigs") catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return w.written();
}

const testing = std.testing;

test "names: taken apart, checked, written back as paths" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const name = "projects/82150720798/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862";
    const c = try parseConfig(name);
    try testing.expectEqualStrings("82150720798", c.project);
    try testing.expectEqualStrings("us", c.location);
    try testing.expectEqualStrings("6ad99c4e-0000-2bb7-b042-14223bbd2862", c.id);
    try testing.expectEqualStrings(name, try configName(a, c));
    try testing.expectEqualStrings("/v1/" ++ name, try configPath(a, c, &.{}));
    try testing.expectEqualStrings("/v1/" ++ name ++ ":startManualRuns", try std.mem.concat(a, u8, &.{ try configPath(a, c, &.{}), ":startManualRuns" }));
    const r = try parseRun(name ++ "/runs/6ae65981-0000-2805-bdde-883d24fa83a4");
    try testing.expectEqualStrings("6ae65981-0000-2805-bdde-883d24fa83a4", r.id);
    try testing.expectEqualStrings("/v1/" ++ name ++ "/runs/6ae65981-0000-2805-bdde-883d24fa83a4/transferLogs", try configPath(a, r.config, &.{ "runs", r.id, "transferLogs" }));
    try testing.expectEqualStrings("/v1/projects/extractctl/locations", try locations(a, "extractctl"));
    try testing.expectEqualStrings("/v1/projects/extractctl/locations/us/transferConfigs", try configs(a, "extractctl", "us"));

    for ([_][]const u8{
        "",
        "projects/p/transferConfigs/x",
        "projects/p/locations/us/transferConfigs",
        "projects/p/locations/us/transferConfigs/",
        "projects/p/locations/us/transferConfigs/x/runs/r",
        "projects/p/locations/-/transferConfigs/x",
        "projects/p/locations/us/configs/x",
        "projects/p/regions/us/transferConfigs/x",
        "projects/a b/locations/us/transferConfigs/x",
        "projects/p/locations/us/transferConfigs/x?y",
    }) |bad| try testing.expectError(error.NotConfigName, parseConfig(bad));
    for ([_][]const u8{
        name,
        name ++ "/runs",
        name ++ "/runs/",
        name ++ "/runs/r/transferLogs",
        name ++ "/jobs/r",
    }) |bad| try testing.expectError(error.NotRunName, parseRun(bad));
}
