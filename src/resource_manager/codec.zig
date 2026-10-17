//! JSON in: projects, one by one and in pages. A body is parsed into a
//! `std.json.Value` in a scratch arena and read from there, every string
//! copied into the result's arena, so the response can go when the result
//! is made. Every field is optional but `name` and `projectId`, `null`
//! counts as absent (the proto3 JSON rule), unknown fields are ignored
//! (discovery has `tags`, `configuredCapabilities` and
//! `isManagementProject`, which the published proto has not), and the state
//! is read from a name or a number, as a client that asks for
//! `enum-encoding=int` gets it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const core = @import("core");
const types = @import("types.zig");
const validate = @import("validate.zig");

pub const DecodeError = error{ InvalidResponse, OutOfMemory };

/// One project, as `projects.get` sends it.
pub fn decodeProject(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.Project {
    const root = try parse(scratch, body);
    return project(out, root);
}

/// A page of `projects.search`: `{}` is an empty last page.
pub fn decodeProjectPage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.ProjectPage {
    const root = try parse(scratch, body);
    const obj = try object(root);
    const list = try field(obj, "projects", .array);
    const items = try out.alloc(types.Project, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, items) |v, *p| {
        p.* = try project(out, v);
    };
    return .{ .items = items, .next_page_token = try token(out, obj) };
}

fn parse(scratch: Allocator, body: []const u8) DecodeError!Value {
    return std.json.parseFromSliceLeaky(Value, scratch, body, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResponse,
    };
}

fn object(v: Value) DecodeError!std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => error.InvalidResponse,
    };
}

/// The field's value when it holds `tag`, null when absent or `null`, and
/// `InvalidResponse` when it holds anything else.
fn field(obj: std.json.ObjectMap, name: []const u8, comptime tag: std.meta.Tag(Value)) DecodeError!?@FieldType(Value, @tagName(tag)) {
    const v = obj.get(name) orelse return null;
    if (v == .null) return null;
    if (v != tag) return error.InvalidResponse;
    return @field(v, @tagName(tag));
}

/// `nextPageToken`: absent or "" ends the search.
fn token(out: Allocator, obj: std.json.ObjectMap) DecodeError!?[]const u8 {
    const t = try field(obj, "nextPageToken", .string) orelse return null;
    if (t.len == 0) return null;
    return try out.dupe(u8, t);
}

fn project(out: Allocator, v: Value) DecodeError!types.Project {
    const obj = try object(v);
    const name = try field(obj, "name", .string) orelse return error.InvalidResponse;
    const number = numberOf(name) orelse return error.InvalidResponse;
    const project_id = try field(obj, "projectId", .string) orelse return error.InvalidResponse;
    var p: types.Project = .{
        .number = number,
        .name = try out.dupe(u8, name),
        .project_id = try out.dupe(u8, project_id),
    };
    if (try field(obj, "displayName", .string)) |s| p.display_name = try out.dupe(u8, s);
    if (try field(obj, "parent", .string)) |s| {
        if (s.len > 0) p.parent = try parent(out, s);
    }
    p.state = try state(obj);
    p.create_time = try time(obj, "createTime");
    p.update_time = try time(obj, "updateTime");
    p.delete_time = try time(obj, "deleteTime");
    if (try field(obj, "etag", .string)) |s| p.etag = try out.dupe(u8, s);
    if (try field(obj, "labels", .object)) |labels| {
        const list = try out.alloc(types.Label, labels.count());
        var it = labels.iterator();
        var i: usize = 0;
        while (it.next()) |kv| : (i += 1) {
            const value = switch (kv.value_ptr.*) {
                .string => |s| s,
                else => return error.InvalidResponse,
            };
            list[i] = .{ .key = try out.dupe(u8, kv.key_ptr.*), .value = try out.dupe(u8, value) };
        }
        p.labels = list;
    }
    return p;
}

/// The digits of "projects/415104041262".
pub fn numberOf(name: []const u8) ?u64 {
    const prefix = "projects/";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const digits = name[prefix.len..];
    if (!validate.isNumber(digits)) return null;
    return std.fmt.parseInt(u64, digits, 10) catch null;
}

/// "organizations/123" or "folders/876"; any other kept whole as `.other`.
pub fn parent(out: Allocator, text: []const u8) Allocator.Error!types.Parent {
    const name = try out.dupe(u8, text);
    inline for (.{ .{ "organizations/", types.Parent.Kind.organization }, .{ "folders/", types.Parent.Kind.folder } }) |kind| {
        if (std.mem.startsWith(u8, name, kind[0]) and name.len > kind[0].len) {
            return .{ .kind = kind[1], .id = name[kind[0].len..], .name = name };
        }
    }
    return .{ .kind = .other, .id = name, .name = name };
}

fn state(obj: std.json.ObjectMap) DecodeError!types.State {
    const v = obj.get("state") orelse return .unspecified;
    return switch (v) {
        .null => .unspecified,
        .string => |s| types.State.fromWire(s),
        // Numbers arrive as text: the parse keeps them so.
        .number_string => |s| if (std.fmt.parseInt(i64, s, 10)) |n| types.State.fromNumber(n) else |_| .unknown,
        else => error.InvalidResponse,
    };
}

fn time(obj: std.json.ObjectMap, name: []const u8) DecodeError!?std.Io.Timestamp {
    const text = try field(obj, name, .string) orelse return null;
    return core.timestamp.parse(text) catch error.InvalidResponse;
}

const testing = std.testing;
const bodies = @import("production_bodies.zig");

fn decodeOne(body: []const u8) !struct { arena: std.heap.ArenaAllocator, project: types.Project } {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    errdefer arena.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const p = try decodeProject(arena.allocator(), scratch.allocator(), body);
    return .{ .arena = arena, .project = p };
}

test "golden: production's search page and get, as measured" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    const page = try decodeProjectPage(arena.allocator(), scratch.allocator(), bodies.search_extractctl);
    // Nothing the page holds points into the response.
    scratch.deinit();
    try testing.expectEqual(1, page.items.len);
    try testing.expectEqual(null, page.next_page_token);
    const p = page.items[0];
    try testing.expectEqual(82150720798, p.number);
    try testing.expectEqualStrings("projects/82150720798", p.name);
    try testing.expectEqualStrings("extractctl", p.project_id);
    try testing.expectEqualStrings("extractctl", p.display_name.?);
    try testing.expectEqual(null, p.parent);
    try testing.expectEqual(.active, p.state);
    try testing.expectEqual(1_767_568_790_778_573_000, p.create_time.?.nanoseconds);
    try testing.expectEqual(null, p.update_time);
    try testing.expectEqual(0, p.labels.len);
    try testing.expectEqualStrings("W/\"80ecc814d017d568\"", p.etag.?);

    var got = try decodeOne(bodies.get_extractctl);
    defer got.arena.deinit();
    try testing.expectEqual(p.create_time.?.nanoseconds, got.project.update_time.?.nanoseconds);

    var public = try decodeOne(bodies.get_public);
    defer public.arena.deinit();
    try testing.expectEqual(.folder, public.project.parent.?.kind);
    try testing.expectEqualStrings("460805882129", public.project.parent.?.id);
    try testing.expectEqualStrings("folders/460805882129", public.project.parent.?.name);
    try testing.expectEqualStrings("BigQuery Public Data", public.project.label());
}

test "golden: the state as a number, as enum-encoding=int sends it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const page = try decodeProjectPage(arena.allocator(), arena.allocator(), bodies.search_enum_int);
    try testing.expectEqual(.active, page.items[0].state);
}

test "decode: every field, parents of each kind, labels in order, unknown keys ignored" {
    var got = try decodeOne(
        \\{"name":"projects/415104041262","parent":"organizations/123","projectId":"payments-prod","state":"DELETE_REQUESTED",
        \\ "displayName":"Payments (prod)","createTime":"2021-03-04T10:11:12Z","updateTime":"2025-06-01T08:00:00.1Z",
        \\ "deleteTime":"2026-10-01T00:00:00.123456789Z","etag":"e","labels":{"env":"prod","a":""},
        \\ "tags":{"x":"y"},"configuredCapabilities":["c"],"isManagementProject":false,"future":{"deep":[1,2]}}
    );
    defer got.arena.deinit();
    const p = got.project;
    try testing.expectEqual(415104041262, p.number);
    try testing.expectEqual(.organization, p.parent.?.kind);
    try testing.expectEqualStrings("123", p.parent.?.id);
    try testing.expectEqual(.delete_requested, p.state);
    try testing.expectEqual(1_614_852_672 * std.time.ns_per_s, p.create_time.?.nanoseconds);
    try testing.expectEqual(1_748_764_800 * std.time.ns_per_s + 100_000_000, p.update_time.?.nanoseconds);
    try testing.expectEqual(123_456_789, @mod(p.delete_time.?.nanoseconds, std.time.ns_per_s));
    try testing.expectEqual(2, p.labels.len);
    try testing.expectEqualStrings("env", p.labels[0].key);
    try testing.expectEqualStrings("prod", p.labels[0].value);
    try testing.expectEqualStrings("a", p.labels[1].key);
    try testing.expectEqualStrings("", p.labels[1].value);

    var other = try decodeOne("{\"name\":\"projects/1\",\"projectId\":\"a\",\"parent\":\"regions/x\",\"state\":7}");
    defer other.arena.deinit();
    try testing.expectEqual(.other, other.project.parent.?.kind);
    try testing.expectEqualStrings("regions/x", other.project.parent.?.id);
    try testing.expectEqual(.unknown, other.project.state);
    // A kind with no id after it is no folder.
    var bare = try decodeOne("{\"name\":\"projects/1\",\"projectId\":\"a\",\"parent\":\"folders/\"}");
    defer bare.arena.deinit();
    try testing.expectEqual(.other, bare.project.parent.?.kind);
}

test "decode: absent, null and empty are the defaults" {
    var got = try decodeOne("{\"name\":\"projects/7\",\"projectId\":\"a\",\"displayName\":null,\"parent\":\"\",\"state\":null,\"labels\":null,\"createTime\":null}");
    defer got.arena.deinit();
    const p = got.project;
    try testing.expectEqual(null, p.display_name);
    try testing.expectEqualStrings("a", p.label());
    try testing.expectEqual(null, p.parent);
    try testing.expectEqual(.unspecified, p.state);
    try testing.expectEqual(null, p.create_time);
    try testing.expectEqual(0, p.labels.len);
    for ([_]struct { []const u8, types.State }{
        .{ "\"ACTIVE\"", .active }, .{ "\"STATE_UNSPECIFIED\"", .unspecified }, .{ "\"PURGED\"", .unknown },
        .{ "0", .unspecified },     .{ "1", .active },                          .{ "2", .delete_requested },
        .{ "-1", .unknown },        .{ "99999999999999999999", .unknown },      .{ "1.5", .unknown },
    }) |case| {
        const body = try std.fmt.allocPrint(testing.allocator, "{{\"name\":\"projects/7\",\"projectId\":\"a\",\"state\":{s}}}", .{case[0]});
        defer testing.allocator.free(body);
        var s = try decodeOne(body);
        defer s.arena.deinit();
        try testing.expectEqual(case[1], s.project.state);
    }
}

test "decode: what is no project is InvalidResponse" {
    for ([_][]const u8{
        "",                                                                           "[]",
        "{}",                                                                         "{\"name\":\"projects/1\"}",
        "{\"projectId\":\"a\"}",                                                      "{\"name\":\"projects/x\",\"projectId\":\"a\"}",
        "{\"name\":\"projects/\",\"projectId\":\"a\"}",                               "{\"name\":\"folders/1\",\"projectId\":\"a\"}",
        "{\"name\":\"projects/18446744073709551616\",\"projectId\":\"a\"}",           "{\"name\":1,\"projectId\":\"a\"}",
        "{\"name\":\"projects/1\",\"projectId\":\"a\",\"labels\":{\"k\":1}}",         "{\"name\":\"projects/1\",\"projectId\":\"a\",\"labels\":[]}",
        "{\"name\":\"projects/1\",\"projectId\":\"a\",\"createTime\":\"yesterday\"}", "{\"name\":\"projects/1\",\"projectId\":\"a\",\"state\":true}",
        "{\"name\":\"projects/1\",\"projectId\":\"a\",\"parent\":5}",                 "{\"name\":\"projects/-1\",\"projectId\":\"a\"}",
    }) |body| {
        try testing.expectError(error.InvalidResponse, decodeOne(body));
    }
}

test "decode: pages, empty and with a token" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const empty = try decodeProjectPage(a, a, "{}");
    try testing.expectEqual(0, empty.items.len);
    try testing.expectEqual(null, empty.next_page_token);
    const searching = try decodeProjectPage(a, a, "{\"nextPageToken\":\"EAE\"}");
    try testing.expectEqual(0, searching.items.len);
    try testing.expectEqualStrings("EAE", searching.next_page_token.?);
    const blank = try decodeProjectPage(a, a, "{\"projects\":null,\"nextPageToken\":\"\"}");
    try testing.expectEqual(null, blank.next_page_token);
    const two = try decodeProjectPage(a, a, "{\"projects\":[{\"name\":\"projects/1\",\"projectId\":\"a\"},{\"name\":\"projects/2\",\"projectId\":\"b\"}],\"nextPageToken\":\"t\"}");
    try testing.expectEqual(2, two.items.len);
    try testing.expectEqual(2, two.items[1].number);
    for ([_][]const u8{ "[]", "{\"projects\":{}}", "{\"projects\":[1]}", "{\"nextPageToken\":5}", "{\"projects\":[{}]}" }) |body| {
        try testing.expectError(error.InvalidResponse, decodeProjectPage(a, a, body));
    }
}

test "decode: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var scratch: std.heap.ArenaAllocator = .init(gpa);
            defer scratch.deinit();
            _ = try decodeProjectPage(arena.allocator(), scratch.allocator(),
                \\{"projects":[{"name":"projects/1","projectId":"a","parent":"folders/2","displayName":"A","labels":{"k":"v"},"etag":"e"}],"nextPageToken":"t"}
            );
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{});
}

const test_util = @import("test_util.zig");

fn arbitraryProperty(_: void, input: []const u8) !void {
    const gpa = test_util.propertyAllocator();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    const page = decodeProjectPage(arena.allocator(), scratch.allocator(), input) catch |err| {
        scratch.deinit();
        switch (err) {
            error.InvalidResponse => return,
            else => return err,
        }
    };
    // Nothing a page holds points into the body or the parse.
    scratch.deinit();
    for (page.items) |p| {
        try testing.expect(std.mem.startsWith(u8, p.name, "projects/"));
        try testing.expectEqual(p.number, numberOf(p.name).?);
        if (p.parent) |up| try testing.expect(up.name.len > 0);
    }
    if (page.next_page_token) |t| try testing.expect(t.len > 0);
}

test "fuzz decodeProjectPage: arbitrary bodies never crash, and a page stands on its own" {
    try test_util.fuzzBytes({}, arbitraryProperty, .{ .corpus = &.{
        bodies.search_extractctl,
        bodies.search_enum_int,
        "{\"projects\":[{\"name\":\"projects/1\",\"projectId\":\"a\",\"labels\":{\"a\":\"1\",\"a\":\"2\"}}]}",
        "{\"projects\":[{\"name\":\"projects/00001\",\"projectId\":\"\",\"state\":-0}],\"nextPageToken\":\"\\ud800\"}",
        "{\"a\":[[[[[[[[[[[[[[[[[[[[1]]]]]]]]]]]]]]]]]]]}",
        "",
        "null",
    } });
}

fn roundTripProperty(_: void, input: []const u8) !void {
    const gpa = test_util.propertyAllocator();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var g: test_util.ByteGen = .init(input);
    const n = g.intRange(usize, 0, 4);
    const want = try a.alloc(types.Project, n);
    var body: std.Io.Writer.Allocating = .init(a);
    var jw: std.json.Stringify = .{ .writer = &body.writer };
    try jw.beginObject();
    try jw.objectField("projects");
    try jw.beginArray();
    for (want) |*p| {
        var text: [48]u8 = undefined;
        const number = g.int(u64);
        p.* = .{
            .number = number,
            .name = try std.fmt.allocPrint(a, "projects/{d}", .{number}),
            .project_id = try a.dupe(u8, g.utf8(&text, 30)),
            .display_name = if (g.boolean()) try a.dupe(u8, g.utf8(&text, 30)) else null,
            .parent = if (g.boolean()) try parent(a, try std.fmt.allocPrint(a, "{s}/{d}", .{ g.pick([]const u8, &.{ "folders", "organizations", "regions" }), g.int(u32) })) else null,
            .state = g.pick(types.State, &.{ .unspecified, .active, .delete_requested }),
            .create_time = if (g.boolean()) .{ .nanoseconds = @as(i96, g.intRange(u64, 0, 253_402_300_799)) * std.time.ns_per_s + g.intRange(u32, 0, 999_999_999) } else null,
            .labels = &.{},
        };
        const labels = try a.alloc(types.Label, g.intRange(usize, 0, 3));
        for (labels, 0..) |*l, i| l.* = .{ .key = try std.fmt.allocPrint(a, "k{d}", .{i}), .value = try a.dupe(u8, g.utf8(&text, 10)) };
        p.labels = labels;
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(p.name);
        if (p.parent) |x| {
            try jw.objectField("parent");
            try jw.write(x.name);
        }
        try jw.objectField("projectId");
        try jw.write(p.project_id);
        if (p.state != .unspecified) {
            try jw.objectField("state");
            if (g.boolean()) try jw.write(@backingInt(p.state)) else try jw.write(if (p.state == .active) "ACTIVE" else "DELETE_REQUESTED");
        }
        if (p.display_name) |d| {
            try jw.objectField("displayName");
            try jw.write(d);
        }
        if (p.create_time) |t| {
            var buf: [core.timestamp.max_len]u8 = undefined;
            try jw.objectField("createTime");
            try jw.write(core.timestamp.format(&buf, t));
        }
        if (labels.len > 0) {
            try jw.objectField("labels");
            try jw.beginObject();
            for (labels) |l| {
                try jw.objectField(l.key);
                try jw.write(l.value);
            }
            try jw.endObject();
        }
        try jw.objectField("unknown");
        try jw.write(.{ .nested = .{ 1, 2 } });
        try jw.endObject();
    }
    try jw.endArray();
    const sent_token: ?[]const u8 = if (g.boolean()) "t0k3n" else null;
    if (sent_token) |t| {
        try jw.objectField("nextPageToken");
        try jw.write(t);
    }
    try jw.endObject();

    const page = try decodeProjectPage(a, a, body.written());
    try testing.expectEqual(want.len, page.items.len);
    for (want, page.items) |w, got| {
        try testing.expectEqual(w.number, got.number);
        try testing.expectEqualStrings(w.name, got.name);
        try testing.expectEqualStrings(w.project_id, got.project_id);
        if (w.display_name) |d| try testing.expectEqualStrings(d, got.display_name.?) else try testing.expectEqual(null, got.display_name);
        if (w.parent) |x| {
            try testing.expectEqual(x.kind, got.parent.?.kind);
            try testing.expectEqualStrings(x.id, got.parent.?.id);
        } else try testing.expectEqual(null, got.parent);
        try testing.expectEqual(w.state, got.state);
        try testing.expectEqual(w.create_time, got.create_time);
        try testing.expectEqual(w.labels.len, got.labels.len);
        for (w.labels, got.labels) |wl, gl| {
            try testing.expectEqualStrings(wl.key, gl.key);
            try testing.expectEqualStrings(wl.value, gl.value);
        }
    }
    if (sent_token) |t| try testing.expectEqualStrings(t, page.next_page_token.?) else try testing.expectEqual(null, page.next_page_token);
}

test "fuzz project round trip: random projects, written as production writes them, read back whole" {
    try test_util.fuzzBytes({}, roundTripProperty, .{ .corpus = &.{ "", "\x04\xff\xff\xff\xff\xff\xff\xff\xff\x03\x01\x01\x01" } });
}
