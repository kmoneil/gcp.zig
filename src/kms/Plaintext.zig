//! What `Key.decrypt` answers: the plaintext, in memory that is wiped when
//! it is released.
//!
//! Everything the call touched lives in one arena over a
//! `core.WipingAllocator`: the response body, which holds the plaintext in
//! base64, the JSON parser's scratch space, and the decoded bytes
//! themselves. One `deinit` zeroes all of it.

const Plaintext = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

/// The bytes, behind a type that will not print them. Read them with
/// `bytes()`.
data: Redacted,
/// Whether the key's primary version decrypted it. False means an older
/// version did: re-encrypting moves the data to the primary.
used_primary: bool,
/// The wiped arena holding everything above. `deinit` frees it.
backing: *Backing,

const Backing = struct {
    wiping: core.WipingAllocator,
    arena: std.heap.ArenaAllocator,
};

/// A slice of secret bytes that no format specifier prints. `{f}` gives
/// `[REDACTED]`; `{}` and `{any}` print the fields of a struct, so the bytes
/// are held as a pointer and a length, which print as an address and a
/// number.
pub const Redacted = struct {
    ptr: [*]const u8,
    len: usize,

    pub fn init(slice_: []const u8) Redacted {
        return .{ .ptr = slice_.ptr, .len = slice_.len };
    }

    pub fn slice(self: Redacted) []const u8 {
        return self.ptr[0..self.len];
    }

    pub fn format(self: Redacted, w: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = self;
        try w.writeAll("[REDACTED]");
    }
};

/// An empty value, with the wiped arena that the call fills.
pub fn init(gpa: Allocator) Allocator.Error!Plaintext {
    const backing = try gpa.create(Backing);
    backing.wiping = .init(gpa);
    backing.arena = .init(backing.wiping.allocator());
    return .{ .data = .init(""), .used_primary = false, .backing = backing };
}

/// The arena every byte of this value lives in.
pub fn arena(self: Plaintext) *std.heap.ArenaAllocator {
    return &self.backing.arena;
}

/// Allocates inside that arena, so what is allocated is wiped with it.
pub fn allocator(self: Plaintext) Allocator {
    return self.backing.arena.allocator();
}

/// Wipes everything the arena holds and empties the value, ready to be
/// filled again: between attempts, so bytes that failed their checksum
/// never outlive the attempt that fetched them.
pub fn clear(self: *Plaintext) void {
    _ = self.backing.arena.reset(.free_all);
    self.data = .init("");
    self.used_primary = false;
}

/// Wipes and frees the plaintext. Pass a `Plaintext` by pointer: a copy
/// whose `deinit` also runs frees the same memory twice.
pub fn deinit(self: *Plaintext) void {
    const gpa = self.backing.wiping.child;
    self.backing.arena.deinit();
    gpa.destroy(self.backing);
    self.* = undefined;
}

/// The plaintext, exactly as encrypted. It lives until `deinit`.
pub fn bytes(self: Plaintext) []const u8 {
    return self.data.slice();
}

/// Prints `[REDACTED]`.
pub fn format(self: Plaintext, w: *std.Io.Writer) std.Io.Writer.Error!void {
    _ = self;
    try w.writeAll("[REDACTED]");
}

const testing = std.testing;

test "deinit wipes every byte the arena held" {
    var backing: [16 * 1024]u8 = @splat(0);
    var fba: std.heap.FixedBufferAllocator = .init(&backing);
    var value: Plaintext = try .init(fba.allocator());
    const chunks_from = fba.end_index;
    for (0..20) |i| {
        const buf = try value.allocator().alloc(u8, 200 + i * 13);
        @memset(buf, 'S');
    }
    value.data = .init(try value.allocator().dupe(u8, "s3cr3t"));
    try testing.expectEqualStrings("s3cr3t", value.bytes());
    const used = fba.end_index;
    value.deinit();
    try testing.expect(std.mem.allEqual(u8, backing[chunks_from..used], 0));
}

test "clear wipes and empties, and no format specifier prints the bytes" {
    var backing: [16 * 1024]u8 = @splat(0);
    var fba: std.heap.FixedBufferAllocator = .init(&backing);
    var value: Plaintext = try .init(fba.allocator());
    defer value.deinit();
    value.data = .init(try value.allocator().dupe(u8, "s3cr3t"));
    value.used_primary = true;
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("[REDACTED]", try std.fmt.bufPrint(&buf, "{f}", .{value}));
    try testing.expectEqualStrings("[REDACTED]", try std.fmt.bufPrint(&buf, "{f}", .{value.data}));
    inline for (.{ "{}", "{any}" }) |spec| {
        const printed = try std.fmt.bufPrint(&buf, spec, .{value});
        try testing.expectEqual(null, std.mem.indexOf(u8, printed, "115, 51"));
        try testing.expectEqual(null, std.mem.indexOf(u8, printed, "s3cr3t"));
    }
    value.clear();
    try testing.expectEqual(null, std.mem.indexOf(u8, &backing, "s3cr3t"));
    try testing.expectEqualStrings("", value.bytes());
    try testing.expect(!value.used_primary);
}
