//! A worker on a spot VM that stops when Compute Engine takes the VM
//! back. It reads the job its controller put in the VM's attributes, then
//! watches `instance/preempted`, and the metadata server wakes it within
//! moments of `TRUE`, with no polling.
//!
//!     zig build example-spot_worker            # on a Compute Engine VM
//!     zig build example-spot_worker -- --fake  # no VM: preempted a second in
//!
//! Anywhere but Google Cloud there is no metadata server, and it says so.
//! `--fake` reads `auth.testing.FakeMetadataServer` instead, and preempts
//! it after a second.

const std = @import("std");
const auth = @import("auth");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{ .scope = .gcp_auth, .level = .warn }},
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    const use_fake = args.len == 2 and std.mem.eql(u8, args[1], "--fake");
    if (args.len > 1 and !use_fake) {
        std.debug.print("usage: spot_worker [--fake]\n", .{});
        return error.Usage;
    }

    var fake: auth.testing.FakeMetadataServer = .init(init.gpa, io, .{});
    defer fake.deinit();
    if (use_fake) try fake.set("instance/attributes/job", "resize-images");
    var diag: auth.Diagnostics = .{};
    var metadata = try auth.MetadataServer.init(init.gpa, io, .{
        .transport = if (use_fake) fake.transport() else null,
        .diagnostics = &diag,
    });
    defer metadata.deinit();
    if (!use_fake and !metadata.probe(io)) {
        std.debug.print("no metadata server answered: this is not Google Cloud (try --fake)\n", .{});
        return error.NotOnGoogleCloud;
    }

    const zone = metadata.get(io, arena, "instance/zone") catch |err| {
        std.debug.print("reading the zone failed: {t}: {s}\n", .{ err, diag.message() });
        return err;
    };
    const job = try metadata.instanceAttribute(io, arena, "job") orelse "(no job attribute)";
    try out.print("{s} in {s}: working until this VM is preempted\n", .{ job, zone });
    try out.flush();

    var preempting = if (use_fake) try io.concurrent(preemptLater, .{ &fake, io }) else null;
    defer if (preempting) |*p| p.cancel(io);

    var etag: ?[]const u8 = null;
    while (true) {
        const seen = metadata.watch(io, arena, "instance/preempted", .{ .last_etag = etag, .timeout_s = 300 }) catch |err| {
            std.debug.print("watching instance/preempted failed: {t}: {s}\n", .{ err, diag.message() });
            return err;
        };
        if (std.mem.eql(u8, seen.value, "TRUE")) break;
        etag = seen.etag;
    }
    const now_ms = @divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms);
    try out.print("preempted at {d}.{d:0>3} (Unix time): stopping\n", .{ @divTrunc(now_ms, 1000), @as(u64, @intCast(@mod(now_ms, 1000))) });
}

/// Compute Engine taking the VM back, a second in.
fn preemptLater(fake: *auth.testing.FakeMetadataServer, io: std.Io) void {
    io.sleep(.fromSeconds(1), .awake) catch return;
    fake.preempt() catch {};
}
