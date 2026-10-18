//! Test-only helpers: `Harness`, a real `Client` wired to core's fake
//! transport and fake clock, and core's test helpers under their own names.
//! Only test blocks import this file, so none of it reaches a normal build.

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const Budget = @import("budget.zig").Budget;
const Method = core.transport.Method;
const Diagnostics = core.Diagnostics;
const RetryPolicy = core.RetryPolicy;

pub const FakeTransport = core.testing.FakeTransport;
pub const FakeTokenProvider = core.testing.FakeTokenProvider;
pub const FakeClock = core.testing.FakeClock;
pub const ByteGen = core.testing.ByteGen;
pub const fuzzBytes = core.testing.fuzzBytes;
pub const repeat = core.testing.repeat;
pub const no_grow_allocator = core.testing.no_grow_allocator;
/// The allocator a property runs on: the one that looks for leaks in every
/// test run, a plain one under the fuzzer, where the leak checker's record
/// of every allocation is most of a run's cost and grows without end.
pub fn propertyAllocator() std.mem.Allocator {
    return if (@import("builtin").fuzz) std.heap.smp_allocator else std.testing.allocator;
}

/// A real `Client` wired to a `FakeTransport` and a `FakeClock`. Initialize
/// it in place with `init`: the client points into the harness.
pub const Harness = struct {
    fake: FakeTransport,
    clock: FakeClock,
    diag: Diagnostics,
    token: FakeTokenProvider,
    client: Client,

    pub const Options = struct {
        retry: RetryPolicy = .{},
        location: ?[]const u8 = null,
        calls_per_minute: u32 = 60,
        budget: ?*Budget = null,
        /// The quota project the credentials name.
        quota_project: ?[]const u8 = null,
    };

    pub fn init(h: *Harness, script: []const FakeTransport.Reply, options: Options) !void {
        h.* = .{
            .fake = .init(std.testing.allocator, script),
            .clock = .{},
            .diag = .{},
            .token = .{ .token = "ya29.test-token", .quota_project = options.quota_project },
            .client = undefined,
        };
        errdefer h.fake.deinit();
        h.client = try .init(std.testing.allocator, h.clock.io(), .{
            .project_id = "my-project",
            .token_provider = h.token.provider(),
            .location = options.location,
            .retry = options.retry,
            .calls_per_minute = options.calls_per_minute,
            .budget = options.budget,
            .diagnostics = &h.diag,
            .transport = h.fake.transport(),
        });
    }

    pub fn deinit(h: *Harness) void {
        h.client.deinit();
        h.fake.deinit();
    }

    /// Asserts the method, URL and body of the request at `index`.
    pub fn expectRequest(h: *const Harness, index: usize, method: Method, url: []const u8, body: ?[]const u8) !void {
        const r = try h.fake.request(index);
        try std.testing.expectEqual(method, r.method);
        try std.testing.expectEqualStrings(url, r.url);
        if (body) |b| {
            try std.testing.expectEqualStrings(b, r.body orelse return error.TestExpectedBody);
        } else {
            try std.testing.expectEqual(null, r.body);
        }
    }

    pub fn expectRequestCount(h: *const Harness, count: usize) !void {
        try std.testing.expectEqual(count, h.fake.requests.items.len);
    }
};
