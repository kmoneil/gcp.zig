//! Test helpers: rest-core's fakes, fake clock and property-test runner,
//! and the two that are Google's own: a fake `Signer`, and an error body
//! carrying a `google.rpc.RetryInfo` delay. The modules' own tests use them,
//! and so can tests of code that uses the modules. Nothing here is
//! referenced by a normal build.

const std = @import("std");
const Allocator = std.mem.Allocator;

const rest_testing = @import("rest_core").testing;
const Header = @import("rest_core").transport.Header;
const Signer = @import("Signer.zig");

pub const FakeTokenProvider = rest_testing.FakeTokenProvider;
pub const FakeTransport = rest_testing.FakeTransport;
pub const FaultTransport = rest_testing.FaultTransport;
pub const ScriptedServer = rest_testing.ScriptedServer;
pub const WipeChecker = rest_testing.WipeChecker;
pub const RefuseOver = rest_testing.RefuseOver;
pub const FakeClock = rest_testing.FakeClock;
pub const ByteGen = rest_testing.ByteGen;
pub const repeat = rest_testing.repeat;
pub const max_fuzz_input = rest_testing.max_fuzz_input;
pub const FuzzOptions = rest_testing.FuzzOptions;
pub const fuzzBytes = rest_testing.fuzzBytes;

/// A `Signer` that answers with one email and one signature, or fails with
/// one error, and keeps the last message it was asked to sign.
pub const FakeSigner = struct {
    /// Returned by `email`, copied into the caller's arena.
    account: []const u8 = "signer@test-project.iam.gserviceaccount.com",
    /// Returned by `sign`, copied into the caller's arena, whatever the
    /// message.
    signature: []const u8 = "\x5a\xa5\x00\xff",
    /// When set, `email` and `sign` both fail with it.
    fail: ?Signer.Error = null,
    /// What `lifetimeS` returns.
    lifetime_s: ?u32 = null,
    /// `sign` calls so far, failed ones included.
    calls: usize = 0,
    message_buffer: [1024]u8 = undefined,
    message_len: usize = 0,

    pub fn signer(self: *FakeSigner) Signer {
        return .{ .ptr = self, .vtable = &.{
            .email = email,
            .sign = sign,
            .lifetime_s = lifetime,
        } };
    }

    /// The message of the latest `sign` call, truncated to 1,024 bytes.
    pub fn lastMessage(self: *const FakeSigner) []const u8 {
        return self.message_buffer[0..self.message_len];
    }

    fn fromPtr(ptr: *anyopaque) *FakeSigner {
        return @ptrCast(@alignCast(ptr));
    }

    fn email(ptr: *anyopaque, io: std.Io, arena: Allocator) Signer.Error![]const u8 {
        _ = io;
        const self = fromPtr(ptr);
        if (self.fail) |err| return err;
        return arena.dupe(u8, self.account);
    }

    fn sign(ptr: *anyopaque, io: std.Io, arena: Allocator, message: []const u8) Signer.Error![]const u8 {
        _ = io;
        const self = fromPtr(ptr);
        self.calls += 1;
        self.message_len = @min(message.len, self.message_buffer.len);
        @memcpy(self.message_buffer[0..self.message_len], message[0..self.message_len]);
        if (self.fail) |err| return err;
        return arena.dupe(u8, self.signature);
    }

    fn lifetime(ptr: *anyopaque) ?u32 {
        return fromPtr(ptr).lifetime_s;
    }
};

/// What a credential naming `project` as its quota project adds to each
/// request it authorizes, for `FakeTokenProvider.credential_headers`.
pub fn quotaProject(comptime project: []const u8) []const Header {
    return &.{.{ .name = "x-goog-user-project", .value = project }};
}

/// A Google API error body whose RetryInfo detail asks for `delay`, a
/// protobuf Duration such as "2s" or "0.004s".
pub fn retryInfoBody(comptime code: u16, comptime status: []const u8, comptime delay: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        \\{{"error":{{"code":{d},"message":"try later","status":"{s}","details":[{{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"{s}"}}]}}}}
    , .{ code, status, delay });
}

test "retryInfoBody: a delay core reads" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const errors = @import("errors.zig");
    try std.testing.expectEqual(2_500, try errors.decodeRetryDelayMs(arena.allocator(), retryInfoBody(503, "UNAVAILABLE", "2.5s")));
}

test "FakeSigner signs with its one signature and keeps the message" {
    var fake: FakeSigner = .{};
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const s = fake.signer();
    try std.testing.expectEqualStrings("\x5a\xa5\x00\xff", try s.sign(std.testing.io, arena.allocator(), "abc"));
    try std.testing.expectEqualStrings("abc", fake.lastMessage());
    fake.fail = error.SigningFailed;
    try std.testing.expectError(error.SigningFailed, s.sign(std.testing.io, arena.allocator(), "d"));
    try std.testing.expectEqual(2, fake.calls);
}
