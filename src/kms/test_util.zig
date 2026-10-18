//! Test-only helpers: `Harness`, a real `Client` wired to core's fake
//! transport and fake clock, and core's test helpers under their own names.
//! Only test blocks import this file, so none of it reaches a normal build.

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const FakeKms = @import("fake_kms.zig").FakeKms;
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
pub const Owned = core.Owned;
/// The allocator a property runs on: the one that looks for leaks in every
/// test run, a plain one under the fuzzer, where the leak checker's record
/// of every allocation is most of a run's cost and grows without end.
pub fn propertyAllocator() std.mem.Allocator {
    return if (@import("builtin").fuzz) std.heap.smp_allocator else std.testing.allocator;
}

/// The base of every URL the harness's client sends.
pub const base = "https://cloudkms.googleapis.com/v1/projects/my-project/locations/us-central1";

/// 2026-10-18T09:46:40Z, where a rig's clock starts.
pub const start_ns: i96 = 1_792_300_000 * std.time.ns_per_s;

/// A real `Client` wired to a `FakeKms` on a `FakeClock`. Initialize it in
/// place with `init`: the client points into the rig.
pub const Rig = struct {
    clock: FakeClock,
    fake: FakeKms,
    diag: Diagnostics,
    token: FakeTokenProvider,
    client: Client,

    pub const Options = struct {
        fake: FakeKms.Options = .{},
        retry: RetryPolicy = .{ .initial_backoff_ms = 1, .max_backoff_ms = 2 },
    };

    pub fn init(r: *Rig, gpa: std.mem.Allocator, options: Options) !void {
        r.* = .{
            .clock = .{ .now_ns = start_ns },
            .fake = undefined,
            .diag = .{},
            .token = .{ .token = "ya29.test-token" },
            .client = undefined,
        };
        r.fake = .init(gpa, r.clock.io(), options.fake);
        errdefer r.fake.deinit();
        r.client = try .init(gpa, r.clock.io(), .{
            .project_id = "my-project",
            .location = "us-central1",
            .token_provider = r.token.provider(),
            .retry = options.retry,
            .diagnostics = &r.diag,
            .transport = r.fake.transport(),
        });
    }

    pub fn deinit(r: *Rig) void {
        r.client.deinit();
        r.fake.deinit();
    }

    /// Moves the clock on.
    pub fn advance(r: *Rig, seconds: i64) void {
        r.clock.now_ns += @as(i96, seconds) * std.time.ns_per_s;
    }
};

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
    };

    pub fn init(h: *Harness, script: []const FakeTransport.Reply, options: Options) !void {
        h.* = .{
            .fake = .init(std.testing.allocator, script),
            .clock = .{},
            .diag = .{},
            .token = .{ .token = "ya29.test-token" },
            .client = undefined,
        };
        errdefer h.fake.deinit();
        h.client = try .init(std.testing.allocator, h.clock.io(), .{
            .project_id = "my-project",
            .location = "us-central1",
            .token_provider = h.token.provider(),
            .retry = options.retry,
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
