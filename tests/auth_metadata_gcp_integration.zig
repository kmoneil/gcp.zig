//! `auth.MetadataServer`'s key reads against a real Compute Engine
//! metadata server, and `auth.testing.FakeMetadataServer` held to it.
//!
//! - AUTH_TEST_METADATA=1, on a Compute Engine VM whose instance
//!   attributes include `job`, as tools/vmrun/vmrun's do.
//!
//! The first test reads the server through the calls; the second sends
//! the same requests, refusals included, to the server and to a fake that
//! holds the server's own values, and compares the answers. A token's
//! body is never printed. Without the variable every test skips.
//! tools/vmrun/metadata-test runs these on a spot VM, then preempts it
//! while examples/spot_worker.zig watches.

const std = @import("std");
const auth = @import("auth");
const core = @import("core");
const testing = std.testing;
const Allocator = std.mem.Allocator;

fn enabled() !bool {
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    const v = env.get("AUTH_TEST_METADATA") orelse return false;
    return std.mem.eql(u8, v, "1");
}

fn elapsedMs(since: std.Io.Timestamp) i64 {
    return since.durationTo(std.Io.Clock.awake.now(testing.io)).toMilliseconds();
}

test "metadata: a VM's keys, attributes and preemption state, read and watched" {
    if (!try enabled()) return error.SkipZigTest;
    const io = testing.io;
    var diag: auth.Diagnostics = .{};
    errdefer std.debug.print("diagnostics: HTTP {d}: {s}\n", .{ diag.http_status, diag.message() });
    var metadata = try auth.MetadataServer.init(testing.allocator, io, .{ .diagnostics = &diag });
    defer metadata.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const zone = try metadata.get(io, a, "instance/zone");
    std.debug.print("zone: {s}\n", .{zone});
    try testing.expect(std.mem.startsWith(u8, zone, "projects/") and std.mem.indexOf(u8, zone, "/zones/") != null);
    const job = (try metadata.instanceAttribute(io, a, "job")).?;
    std.debug.print("job: {s}\n", .{job});
    try testing.expectEqual(null, try metadata.instanceAttribute(io, a, "zigps-no-such-key"));
    try testing.expect(std.mem.indexOf(u8, try metadata.get(io, a, "instance/attributes/"), "job\n") != null);
    // vmrun's startup script, a few KB: more than one read's worth.
    try testing.expect((try metadata.instanceAttribute(io, a, "startup-script")).?.len > 1024);
    try testing.expect(!try metadata.preempted(io));
    try testing.expectError(error.NotFound, metadata.get(io, a, "instance/no-such-path"));
    try testing.expectError(error.MetadataRefused, metadata.get(io, a, "instance/attributes"));
    try testing.expectEqual(301, diag.http_status);
    diag.clear();

    var started = std.Io.Clock.awake.now(io);
    const first = try metadata.watch(io, a, "instance/preempted", .{});
    try testing.expect(elapsedMs(started) < 2_000);
    try testing.expectEqualStrings("FALSE", first.value);
    try testing.expectEqual(16, first.etag.len);
    started = std.Io.Clock.awake.now(io);
    const again = try metadata.watch(io, a, "instance/preempted", .{ .last_etag = first.etag, .timeout_s = 2 });
    const waited = elapsedMs(started);
    std.debug.print("a watch with nothing changing answered after {d} ms\n", .{waited});
    try testing.expect(waited >= 1_900 and waited < 5_000);
    try testing.expectEqualStrings(first.etag, again.etag);
    try testing.expectError(error.NotFound, metadata.watch(io, a, "instance/attributes/zigps-no-such-key", .{}));
}

/// One request, sent to both.
const Case = struct {
    name: []const u8,
    method: core.transport.Method = .GET,
    /// After the host.
    target: []const u8,
    headers: []const core.transport.Header = flavor,
    /// The body is compared only when it is the server's own words, not
    /// a listing the fake holds less of, nor an HTML page's styling.
    body: Body = .whole,
    /// `{etag}` in `target` is the key's current ETag on each side.
    etag_of: ?[]const u8 = null,

    const Body = enum { whole, title, none };
};

const flavor: []const core.transport.Header = &.{.{ .name = "Metadata-Flavor", .value = "Google" }};

const cases = [_]Case{
    .{ .name = "a key", .target = "/computeMetadata/v1/instance/preempted" },
    .{ .name = "a key, alt=json", .target = "/computeMetadata/v1/instance/preempted?alt=json" },
    .{ .name = "a key, a doubled slash", .target = "/computeMetadata/v1/instance//preempted" },
    .{ .name = "a key, an unknown parameter", .target = "/computeMetadata/v1/instance/preempted?foo=bar" },
    .{ .name = "an attribute", .target = "/computeMetadata/v1/instance/attributes/job" },
    .{ .name = "an attribute with a newline", .target = "/computeMetadata/v1/instance/attributes/job-args" },
    .{ .name = "the zone", .target = "/computeMetadata/v1/instance/zone" },
    .{ .name = "the project", .target = "/computeMetadata/v1/project/project-id" },
    .{ .name = "the server's root", .target = "/" },
    .{ .name = "v1's root", .target = "/computeMetadata/v1/", .body = .none },
    .{ .name = "an attribute not set", .target = "/computeMetadata/v1/instance/attributes/zigps-no-such-key", .body = .title },
    .{ .name = "a project attribute not set", .target = "/computeMetadata/v1/project/attributes/zigps-no-such-key", .body = .title },
    .{ .name = "no such path", .target = "/computeMetadata/v1/instance/no-such-path", .body = .title },
    .{ .name = "a key with a trailing slash", .target = "/computeMetadata/v1/instance/zone/", .body = .title },
    .{ .name = "a slash as %2F", .target = "/computeMetadata/v1/instance%2Fzone", .body = .title },
    .{ .name = "a directory without its slash", .target = "/computeMetadata/v1/instance/attributes" },
    .{ .name = "no flavor header", .target = "/computeMetadata/v1/instance/preempted", .headers = &.{}, .body = .title },
    .{ .name = "the flavor's value lowercased", .target = "/computeMetadata/v1/instance/preempted", .headers = &.{.{ .name = "Metadata-Flavor", .value = "google" }}, .body = .title },
    .{ .name = "X-Forwarded-For", .target = "/computeMetadata/v1/instance/preempted", .headers = &.{ .{ .name = "Metadata-Flavor", .value = "Google" }, .{ .name = "X-Forwarded-For", .value = "10.0.0.1" } }, .body = .title },
    .{ .name = "POST", .method = .POST, .target = "/computeMetadata/v1/instance/preempted", .body = .title },
    .{ .name = "a watch, last_etag=0", .target = "/computeMetadata/v1/instance/preempted?wait_for_change=true&last_etag=0&timeout_sec=30" },
    .{ .name = "a watch, another ETag", .target = "/computeMetadata/v1/instance/preempted?wait_for_change=true&last_etag=0123456789abcdef&timeout_sec=30" },
    .{ .name = "a watch, timeout_sec=0", .target = "/computeMetadata/v1/instance/preempted?wait_for_change=true&last_etag={etag}&timeout_sec=0", .etag_of = "/computeMetadata/v1/instance/preempted" },
    .{ .name = "a watch, wait_for_change=false", .target = "/computeMetadata/v1/instance/preempted?wait_for_change=false&last_etag={etag}&timeout_sec=30", .etag_of = "/computeMetadata/v1/instance/preempted" },
    .{ .name = "a watch that runs out", .target = "/computeMetadata/v1/instance/preempted?wait_for_change=true&last_etag={etag}&timeout_sec=1", .etag_of = "/computeMetadata/v1/instance/preempted" },
    .{ .name = "a watch on a key not set", .target = "/computeMetadata/v1/instance/attributes/zigps-no-such-key?wait_for_change=true&timeout_sec=2", .body = .title },
    .{ .name = "a watch on a listing", .target = "/computeMetadata/v1/instance/attributes/?wait_for_change=true&timeout_sec=2" },
    .{ .name = "a watch on the token", .target = "/computeMetadata/v1/instance/service-accounts/default/token?wait_for_change=true&timeout_sec=2" },
    .{ .name = "the token", .target = "/computeMetadata/v1/instance/service-accounts/default/token", .body = .none },
};

/// What a side answered, as one line: status, the flavor header, the
/// content type, whether an ETag came and whether it is the one asked
/// about, how long it took in whole seconds, the Location, and the body
/// as the case says.
fn line(a: Allocator, case: Case, res: core.transport.Response, asked_etag: ?[]const u8, ms: i64) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print("{d}, flavor {s}, {s}", .{ res.status, res.header("Metadata-Flavor") orelse "none", res.header("Content-Type") orelse "no type" });
    if (res.header("ETag")) |etag| {
        const shaped = etag.len == 16 and for (etag) |c| {
            if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) break false;
        } else true;
        try w.print(", ETag {s}{s}", .{ if (shaped) "of 16 hex digits" else etag, if (asked_etag != null and std.mem.eql(u8, asked_etag.?, etag)) ", the one asked about" else "" });
    }
    try w.print(", {d} s", .{@divTrunc(ms + 500, 1000)});
    if (res.header("Location")) |location| try w.print(", to {s}", .{location});
    // Never a token's body, whatever the case says.
    const token = res.status == 200 and std.mem.indexOf(u8, case.target, "/token") != null;
    switch (if (token) .none else case.body) {
        .whole => try w.print(", body \"{f}\"", .{std.zig.fmtString(res.body)}),
        .title => {
            const start = std.mem.indexOf(u8, res.body, "<title>") orelse res.body.len;
            const end = std.mem.indexOfPos(u8, res.body, start, "</title>") orelse res.body.len;
            try w.print(", title \"{s}\"", .{res.body[@min(start + "<title>".len, res.body.len)..end]});
        },
        .none => {},
    }
    return out.written();
}

fn send(a: Allocator, t: core.transport.Transport, method: core.transport.Method, target: []const u8, headers: []const core.transport.Header) !core.transport.Response {
    const url = try std.fmt.allocPrint(a, "http://metadata.google.internal{s}", .{target});
    return t.send(.{ .method = method, .url = url, .headers = headers, .timeout_ms = 30_000 }, a);
}

test "metadata: the fake, holding the server's own values, answers every request as the server does" {
    if (!try enabled()) return error.SkipZigTest;
    const io = testing.io;
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var http = core.transport.HttpTransport.init(gpa, io, "gcp-zig-auth-test");
    defer http.deinit();
    const real = http.transport();
    var metadata = try auth.MetadataServer.init(gpa, io, .{});
    defer metadata.deinit();

    // The fake holds what the server holds for the keys the cases read.
    const zone_path = try metadata.get(io, a, "instance/zone");
    var fake: auth.testing.FakeMetadataServer = .init(gpa, io, .{
        .project_id = try metadata.projectId(io, a),
        .project_number = try metadata.get(io, a, "project/numeric-project-id"),
        .zone = zone_path[std.mem.lastIndexOfScalar(u8, zone_path, '/').? + 1 ..],
        .email = try metadata.email(io, a),
    });
    defer fake.deinit();
    for ([_][]const u8{ "job", "job-args" }) |key| {
        const path = try std.fmt.allocPrint(a, "instance/attributes/{s}", .{key});
        try fake.set(path, try metadata.get(io, a, path));
    }
    const fake_t = fake.transport();

    var differences: usize = 0;
    for (cases) |case| {
        var lines: [2][]const u8 = undefined;
        for ([_]core.transport.Transport{ real, fake_t }, &lines) |t, *out| {
            var target = case.target;
            var asked: ?[]const u8 = null;
            if (case.etag_of) |of| {
                asked = (try send(a, t, .GET, of, flavor)).header("ETag").?;
                target = try std.mem.replaceOwned(u8, a, case.target, "{etag}", asked.?);
            }
            const started = std.Io.Clock.awake.now(io);
            const res = try send(a, t, case.method, target, case.headers);
            out.* = try line(a, case, res, asked, elapsedMs(started));
        }
        if (std.mem.eql(u8, lines[0], lines[1])) {
            std.debug.print("agree   {s}: {s}\n", .{ case.name, lines[0] });
        } else {
            differences += 1;
            std.debug.print("DIFFER  {s}:\n  server: {s}\n  fake:   {s}\n", .{ case.name, lines[0], lines[1] });
        }
    }
    std.debug.print("{d} of {d} requests answered alike\n", .{ cases.len - differences, cases.len });
    try testing.expectEqual(0, differences);
}
