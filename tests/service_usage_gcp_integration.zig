//! Integration tests against real Service Usage, which has no emulator:
//! issue #316. They need a token for `cloud-platform` or
//! `cloud-platform.read-only` whose principal may list the project's
//! services (`serviceusage.services.list` and `.get`: Viewer has them):
//!
//!     GCP_TEST_PROJECT=extractctl GCP_TEST_TOKEN=$(cat token.txt) \
//!     SERVICE_USAGE_TEST=1 zig build test-integration-gcp -Dtest-filter="service_usage:"
//!
//! Without the variables the tests skip. They read only, about a dozen
//! calls, two of them of the disabled list, whose quota is 60 a minute.
//! The script runs against production and then against
//! `FakeServiceUsage` seeded from production's answers: every success
//! body is held equal byte for byte, and every refusal word for word with
//! production's per-call Help Token cut.

const std = @import("std");
const core = @import("core");
const su = @import("service_usage");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const FakeServiceUsage = su.testing.FakeServiceUsage;

/// Every answer, in order, through any transport.
const Recorder = struct {
    inner: core.transport.Transport,
    arena: std.heap.ArenaAllocator,
    answers: std.ArrayList(Answer) = .empty,

    const Answer = struct { url: []const u8, status: u16, body: []const u8 };

    fn init(inner: core.transport.Transport) Recorder {
        return .{ .inner = inner, .arena = .init(testing.allocator) };
    }

    fn deinit(r: *Recorder) void {
        r.arena.deinit();
    }

    fn transport(r: *Recorder) core.transport.Transport {
        return .{ .ptr = r, .vtable = &.{ .send = send } };
    }

    fn send(ptr: *anyopaque, req: core.transport.Request, arena: Allocator) core.transport.Error!core.transport.Response {
        const r: *Recorder = @ptrCast(@alignCast(ptr));
        const response = try r.inner.send(req, arena);
        const a = r.arena.allocator();
        try r.answers.append(a, .{ .url = try a.dupe(u8, req.url), .status = response.status, .body = try a.dupe(u8, response.body) });
        return response;
    }
};

const Env = struct {
    map: std.process.Environ.Map,
    project: []const u8,
    token: []const u8,

    fn init() !?Env {
        var map = try testing.environ.createMap(testing.allocator);
        errdefer map.deinit();
        const project = map.get("GCP_TEST_PROJECT");
        const token = map.get("GCP_TEST_TOKEN");
        if (project == null or token == null or map.get("SERVICE_USAGE_TEST") == null) {
            map.deinit();
            return null;
        }
        return .{ .map = map, .project = project.?, .token = std.mem.trim(u8, token.?, &std.ascii.whitespace) };
    }

    fn deinit(e: *Env) void {
        e.map.deinit();
    }
};

/// One side of the comparison: a client, through a recorder, over
/// production or the fake.
const Side = struct {
    token: core.StaticToken,
    diag: core.Diagnostics = .{},
    http: ?*core.transport.HttpTransport = null,
    recorder: Recorder,
    client: su.Client,

    fn init(s: *Side, project: []const u8, token: []const u8, inner: ?core.transport.Transport) !void {
        const gpa = testing.allocator;
        s.* = .{ .token = .{ .token = token }, .recorder = undefined, .client = undefined };
        const base = inner orelse t: {
            const h = try gpa.create(core.transport.HttpTransport);
            h.* = .init(gpa, testing.io, "gcp-zig-service_usage-test");
            s.http = h;
            break :t h.transport();
        };
        s.recorder = .init(base);
        s.client = try .init(gpa, testing.io, .{
            .project_id = project,
            .token_provider = s.token.provider(),
            .scope = .cloud_platform,
            .transport = s.recorder.transport(),
            .diagnostics = &s.diag,
        });
    }

    fn deinit(s: *Side) void {
        s.client.deinit();
        s.recorder.deinit();
        if (s.http) |h| {
            h.deinit();
            testing.allocator.destroy(h);
        }
    }
};

/// The script both sides run, each outcome written as a line: what it
/// answered, or the error and production's words without the Help Token.
fn script(s: *Side, a: Allocator, disabled: []const u8, lines: *std.ArrayList([]const u8)) !void {
    const c = &s.client;
    const W = struct {
        fn services(arena: Allocator, list: []const su.Service) ![]const u8 {
            var w: std.Io.Writer.Allocating = .init(arena);
            for (list) |x| try w.writer.print("{s}|{s}|{s}|{t}|{s};", .{ x.name, x.title, x.summary, x.state, x.project_number });
            return w.written();
        }
        fn failed(arena: Allocator, err: anyerror, diag: *const core.Diagnostics) ![]const u8 {
            const message = diag.message();
            const cut = std.mem.indexOf(u8, message, "\nHelp Token: ") orelse message.len;
            return std.fmt.allocPrint(arena, "error.{t}: {s}", .{ err, message[0..cut] });
        }
    };

    var first = try c.listServices(.{ .page_size = 3 });
    defer first.deinit();
    // Production's enabled list answers a page token in one of two forms
    // at random (an offset in 17 of 30 calls, a cursor in 13, measured):
    // whether there is one is what both sides must agree on.
    try lines.append(a, try std.fmt.allocPrint(a, "enabled, 3 a page: {s} more={}", .{ try W.services(a, first.value.services), first.value.next_page_token != null }));
    var every = try c.enabledServices();
    defer every.deinit();
    try lines.append(a, try std.fmt.allocPrint(a, "every enabled one: {s}", .{try W.services(a, every.value)}));
    var off = try c.listServices(.{ .state = .disabled, .page_size = 2 });
    defer off.deinit();
    try lines.append(a, try std.fmt.allocPrint(a, "disabled, 2 a page: {s} more={}", .{ try W.services(a, off.value.services), off.value.next_page_token != null }));
    var itself = try c.getService("serviceusage.googleapis.com");
    defer itself.deinit();
    try lines.append(a, try std.fmt.allocPrint(a, "get serviceusage: {s}", .{try W.services(a, &.{itself.value})}));
    var one_off = try c.getService(disabled);
    defer one_off.deinit();
    try lines.append(a, try std.fmt.allocPrint(a, "get a disabled one: {s}", .{try W.services(a, &.{one_off.value})}));
    var batch = try c.getServices(&.{ disabled, "serviceusage.googleapis.com", disabled });
    defer batch.deinit();
    try lines.append(a, try std.fmt.allocPrint(a, "batch of three: {s}", .{try W.services(a, batch.value)}));
    if (c.getService("zigps-nope-316.googleapis.com")) |unexpected| {
        var u = unexpected;
        u.deinit();
        return error.TestUnexpectedResult;
    } else |err| try lines.append(a, try std.fmt.allocPrint(a, "get one nobody has: {s}", .{try W.failed(a, err, &s.diag)}));
    if (c.getServices(&.{ "serviceusage.googleapis.com", "zigps-nope-a.googleapis.com", "zigps-nope-b.googleapis.com" })) |unexpected| {
        var u = unexpected;
        u.deinit();
        return error.TestUnexpectedResult;
    } else |err| try lines.append(a, try std.fmt.allocPrint(a, "batch with two nobody has: {s}", .{try W.failed(a, err, &s.diag)}));
    if (c.listServices(.{ .page_token = "abc" })) |unexpected| {
        var u = unexpected;
        u.deinit();
        return error.TestUnexpectedResult;
    } else |err| try lines.append(a, try std.fmt.allocPrint(a, "a page token nobody gave: {s}", .{try W.failed(a, err, &s.diag)}));
    // Refused before sending, the same on both sides.
    if (c.getService("ServiceUsage.googleapis.com")) |unexpected| {
        var u = unexpected;
        u.deinit();
        return error.TestUnexpectedResult;
    } else |err| try lines.append(a, try std.fmt.allocPrint(a, "an upper case name: error.{t}: {s}", .{ err, s.diag.message() }));
}

test "service_usage: the script against production and the fake, every answer the same" {
    var env = (try Env.init()) orelse return error.SkipZigTest;
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var prod: Side = undefined;
    try prod.init(env.project, env.token, null);
    defer prod.deinit();
    // The first disabled service, as production lists them.
    var probe = prod.client.listServices(.{ .state = .disabled, .page_size = 1 }) catch |err| {
        std.debug.print("listServices: {t}: {s}\n", .{ err, prod.diag.message() });
        return err;
    };
    defer probe.deinit();
    const disabled = try a.dupe(u8, probe.value.services[0].name);
    var prod_lines: std.ArrayList([]const u8) = .empty;
    script(&prod, a, disabled, &prod_lines) catch |err| {
        std.debug.print("production: {t}: {s}\n", .{ err, prod.diag.message() });
        return err;
    };
    const script_end = prod.recorder.answers.items.len;

    // What production holds: the enabled list itself is in it.
    var saw_itself = false;
    var enabled = try prod.client.enabledServices();
    defer enabled.deinit();
    for (enabled.value) |s| {
        try testing.expectEqual(su.State.enabled, s.state);
        if (std.mem.eql(u8, s.name, "serviceusage.googleapis.com")) saw_itself = true;
    }
    try testing.expect(saw_itself);

    // The fake, seeded from production's answers: every enabled service,
    // and the disabled ones the disabled page showed.
    var fake: FakeServiceUsage = .init(testing.allocator, testing.io, .{ .project_id = env.project, .project_number = enabled.value[0].project_number });
    defer fake.deinit();
    for (enabled.value) |s| try fake.putService(.{ .name = s.name, .title = s.title, .summary = s.summary, .state = s.state });
    var off = try prod.client.listServices(.{ .state = .disabled, .page_size = 3 });
    defer off.deinit();
    for (off.value.services) |s| try fake.putService(.{ .name = s.name, .title = s.title, .summary = s.summary, .state = s.state });

    var double: Side = undefined;
    try double.init(env.project, "t", fake.transport());
    defer double.deinit();
    var fake_lines: std.ArrayList([]const u8) = .empty;
    try script(&double, a, disabled, &fake_lines);

    var differ: usize = 0;
    for (prod_lines.items, fake_lines.items) |p, f| if (!std.mem.eql(u8, p, f)) {
        differ += 1;
        std.debug.print("production: {s}\nfake:       {s}\n", .{ p, f });
    };
    try testing.expectEqual(prod_lines.items.len, fake_lines.items.len);
    try testing.expectEqual(0, differ);

    // Byte for byte: each success body, its page token left out.
    const answered = prod.recorder.answers.items[1..script_end];
    try testing.expectEqual(answered.len, double.recorder.answers.items.len);
    for (answered, double.recorder.answers.items) |p, f| {
        try testing.expectEqual(p.status, f.status);
        if (p.status != 200) continue;
        const want = try withoutToken(a, p.body);
        const got = try withoutToken(a, f.body);
        if (!std.mem.eql(u8, want, got)) {
            std.debug.print("{s}\nproduction: {s}\nfake:       {s}\n", .{ p.url, want, got });
            return error.TestExpectedEqual;
        }
    }
}

/// `body` with its `"nextPageToken":"..."` value emptied: the one part of
/// a page the two sides write in forms of their own.
fn withoutToken(a: Allocator, body: []const u8) ![]const u8 {
    const key = "\"nextPageToken\":\"";
    const at = std.mem.indexOf(u8, body, key) orelse return body;
    const start = at + key.len;
    const end = std.mem.indexOfScalarPos(u8, body, start, '"') orelse return body;
    return std.mem.concat(a, u8, &.{ body[0..start], body[end..] });
}
