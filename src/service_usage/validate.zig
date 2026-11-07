//! What the client checks before sending, so a bad name costs no request.

const std = @import("std");

/// The most services one list page holds: production refuses more, "Invalid
/// page size, should be in [0, 200]." (measured).
pub const max_page_size = 200;

/// The most services `getServices` asks for at once: production refuses
/// more, "Number of services must not exceed the maximum batch size (30)."
/// (measured).
pub const max_batch = 30;

/// Why a service name is not one the client sends.
pub const NameProblem = union(enum) {
    /// An empty name would make the get a list (measured).
    empty,
    /// A byte outside `a-z`, `0-9`, `.` and `-`, and where.
    byte: struct { at: usize, value: u8 },
};

/// A service name such as `pubsub.googleapis.com`: lower case letters,
/// digits, `.` and `-`, as all 13,018 production listed were (measured).
/// Production answers an upper case name or a space as a service it does
/// not know; this refuses what is outside the set before sending, and
/// says where. A name in the set can still be unknown, as
/// `pubsub.googleapis.com.` with its trailing dot was.
pub fn serviceNameProblem(name: []const u8) ?NameProblem {
    if (name.len == 0) return .empty;
    for (name, 0..) |c, i| switch (c) {
        'a'...'z', '0'...'9', '.', '-' => {},
        else => return .{ .byte = .{ .at = i, .value = c } },
    };
    return null;
}

/// Writes `problem` as the end of a diagnostic: "empty", or the byte and
/// where it is.
pub fn describe(w: *std.Io.Writer, problem: NameProblem) std.Io.Writer.Error!void {
    switch (problem) {
        .empty => try w.writeAll("empty"),
        .byte => |b| {
            if (b.value > ' ' and b.value < 0x7f) {
                try w.print("'{c}' at byte {d}", .{ b.value, b.at });
            } else {
                try w.print("byte 0x{x:0>2} at byte {d}", .{ b.value, b.at });
            }
            try w.writeAll("; expected a-z, 0-9, '.' and '-', such as pubsub.googleapis.com");
        },
    }
}

/// A page token travels as a query parameter; production's are opaque.
pub fn isPageToken(token: []const u8) bool {
    if (token.len == 0) return false;
    for (token) |c| if (c <= ' ' or c >= 0x7f) return false;
    return true;
}

/// A user agent goes into a header, so it must be printable ASCII.
pub fn isUserAgent(agent: []const u8) bool {
    if (agent.len == 0) return false;
    for (agent) |c| if (c < ' ' or c >= 0x7f) return false;
    return true;
}

const testing = std.testing;

fn described(problem: NameProblem) ![]const u8 {
    const S = struct {
        var buf: [256]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&S.buf);
    try describe(&w, problem);
    return w.buffered();
}

test "service names: what production listed goes, what it does not know is refused and placed" {
    try testing.expectEqual(null, serviceNameProblem("pubsub.googleapis.com"));
    try testing.expectEqual(null, serviceNameProblem("pubsub"));
    try testing.expectEqual(null, serviceNameProblem("a10-thunder-adc-601b150-byol.endpoints.a10networks-public-396315.cloud.goog"));
    try testing.expectEqual(NameProblem.empty, serviceNameProblem("").?);
    try testing.expectEqualStrings("empty", try described(serviceNameProblem("").?));
    try testing.expectEqualStrings("'P' at byte 0; expected a-z, 0-9, '.' and '-', such as pubsub.googleapis.com", try described(serviceNameProblem("PUBSUB.googleapis.com").?));
    try testing.expectEqualStrings("byte 0x20 at byte 6; expected a-z, 0-9, '.' and '-', such as pubsub.googleapis.com", try described(serviceNameProblem("pubsub .googleapis.com").?));
    try testing.expectEqualStrings("'/' at byte 1; expected a-z, 0-9, '.' and '-', such as pubsub.googleapis.com", try described(serviceNameProblem("a/b").?));
    try testing.expectEqualStrings("byte 0xc3 at byte 0; expected a-z, 0-9, '.' and '-', such as pubsub.googleapis.com", try described(serviceNameProblem("\xc3\xa9").?));
    for ("?#%_:~+ ABZ\n\x00\x7f") |c| try testing.expect(serviceNameProblem(&.{c}) != null);
}

test "page tokens and user agents: what goes into a request" {
    try testing.expect(isPageToken("ZW5hYmxlZC1zZXJ2aWNlcy1vZmZzZXQ6Mw=="));
    try testing.expect(!isPageToken(""));
    try testing.expect(!isPageToken("a b"));
    try testing.expect(isUserAgent("gcp-zig-service_usage/0.69"));
    try testing.expect(!isUserAgent("a\n"));
}
