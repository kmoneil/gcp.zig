//! A request as a client would send it, built without sending it: to show
//! before the call, as a console's confirmation does, or to record after
//! it. A module builds one from the same `rpc.Call` its write sends, so the
//! URL and the body are byte for byte what the call sends. Credentials and
//! other headers are not part of it.

const PreparedRequest = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const rpc = @import("rpc.zig");
const transport = @import("transport.zig");

method: transport.Method,
/// The whole URL, the client's endpoint included.
url: []const u8,
/// The body as sent; empty for a request that sends none.
body: []const u8,

/// What `rpc.Engine.execute` sends for `call` against `base_url`, the
/// engine's own base URL. Allocates the URL in `arena`; the body is
/// copied there too, so the result outlives the call's own memory.
pub fn fromCall(arena: Allocator, base_url: []const u8, call: rpc.Call) Allocator.Error!PreparedRequest {
    return .{
        .method = call.method,
        .url = try std.mem.concat(arena, u8, &.{ base_url, call.path }),
        .body = if (call.body) |b| try arena.dupe(u8, b) else "",
    };
}

const testing = std.testing;

test "fromCall: the whole URL, the body copied, none as empty" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var body = "{}".*;
    const r = try fromCall(arena.allocator(), "https://service.googleapis.com", .{ .method = .POST, .path = "/v1/things/a:run", .body = &body });
    body[0] = 'x';
    try testing.expectEqual(.POST, r.method);
    try testing.expectEqualStrings("https://service.googleapis.com/v1/things/a:run", r.url);
    try testing.expectEqualStrings("{}", r.body);
    const none = try fromCall(arena.allocator(), "https://service.googleapis.com", .{ .method = .GET, .path = "/v1/things" });
    try testing.expectEqualStrings("", none.body);
}
