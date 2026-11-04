//! Test-only helpers: `Harness`, a real `Client` wired to core's fake
//! transport, and core's test helpers under their own names. Only test
//! blocks import this file, so none of it reaches a normal build.

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const Method = core.transport.Method;
const Diagnostics = core.Diagnostics;

pub const FakeTransport = core.testing.FakeTransport;
pub const FakeTokenProvider = core.testing.FakeTokenProvider;
pub const FakeClock = core.testing.FakeClock;
pub const fuzzBytes = core.testing.fuzzBytes;
pub const ByteGen = core.testing.ByteGen;

/// The allocator a property runs on: the one that looks for leaks in every
/// test run, a plain one under the fuzzer, where the leak checker's record
/// of every allocation is most of a run's cost and grows without end.
pub fn propertyAllocator() std.mem.Allocator {
    return if (@import("builtin").fuzz) std.heap.smp_allocator else std.testing.allocator;
}

/// Where the harness's clock starts: the afternoon milestone 0 ran,
/// 2026-11-04T19:30:00Z.
pub const milestone_0_ns: i96 = 1_793_820_600 * std.time.ns_per_s;

/// A real `Client` wired to a `FakeTransport`. Initialize it in place with
/// `init`: the client points into the harness.
pub const Harness = struct {
    fake: FakeTransport,
    clock: FakeClock,
    diag: Diagnostics,
    token: FakeTokenProvider,
    client: Client,

    /// The client options a test may set; the harness supplies the rest.
    pub const Options = struct {
        scope: Client.Scope = .read_only,
        currency_code: ?[]const u8 = null,
        retry: core.RetryPolicy = .{},
    };

    pub fn init(h: *Harness, script: []const FakeTransport.Reply) !void {
        return h.initWith(script, .{});
    }

    pub fn initWith(h: *Harness, script: []const FakeTransport.Reply, options: Options) !void {
        h.* = .{
            .fake = .init(std.testing.allocator, script),
            .clock = .{ .now_ns = milestone_0_ns },
            .diag = .{},
            .token = .{ .token = "ya29.test-token" },
            .client = undefined,
        };
        errdefer h.fake.deinit();
        h.client = try .init(std.testing.allocator, h.clock.io(), .{
            .token_provider = h.token.provider(),
            .scope = options.scope,
            .currency_code = options.currency_code,
            .retry = options.retry,
            .diagnostics = &h.diag,
            .transport = h.fake.transport(),
        });
    }

    pub fn deinit(h: *Harness) void {
        h.client.deinit();
        h.fake.deinit();
    }

    /// Asserts the method and URL of the request at `index`.
    pub fn expectRequest(h: *const Harness, index: usize, method: Method, url: []const u8) !void {
        const r = try h.fake.request(index);
        try std.testing.expectEqual(method, r.method);
        try std.testing.expectEqualStrings(url, r.url);
        try std.testing.expectEqual(null, r.body);
    }

    pub fn expectRequestCount(h: *const Harness, count: usize) !void {
        try std.testing.expectEqual(count, h.fake.requests.items.len);
    }
};
