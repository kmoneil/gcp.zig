//! Renames an object within its bucket, in one atomic step: no copy, no
//! delete, no early deletion fee.
//!
//!     zig build example-gcs_mv -- gs://my-bucket/reports/draft.pdf reports/final.pdf
//!     ... -- gs://my-bucket/a.txt b.txt --no-clobber
//!
//! The source's generation is read first and the move pinned to it, so the
//! move takes exactly the object that was read, and a lost answer is safe
//! to repeat. `--no-clobber` refuses to replace an object already at the
//! destination. Cloud Storage keeps the object's metadata, custom time and
//! access control list, and gives it a new generation.
//!
//! Credentials come from `auth.findDefault`, as for gcs_cp. Against the
//! emulator, which has no move, the library copies and then deletes, and
//! says so in a warning.

const std = @import("std");
const auth = @import("auth");
const storage = @import("storage");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{ .scope = .gcp_storage, .level = .warn }},
};

const usage =
    \\usage: gcs_mv gs://BUCKET/SOURCE DESTINATION [--no-clobber]
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    var positional: std.ArrayList([]const u8) = .empty;
    var no_clobber = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--no-clobber")) {
            no_clobber = true;
        } else try positional.append(arena, arg);
    }
    if (positional.items.len != 2) return badUsage(out);
    const url = positional.items[0];
    if (!std.mem.startsWith(u8, url, "gs://")) return badUsage(out);
    const rest = url["gs://".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return badUsage(out);
    const bucket_name = rest[0..slash];
    const source = rest[slash + 1 ..];
    const destination = positional.items[1];

    const endpoint = storage.Endpoint.fromEnv(init.environ_map);
    var diag: storage.Diagnostics = .{};
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    if (endpoint == null) {
        var lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
        lookup.diagnostics = &diag;
        creds = auth.findDefault(init.gpa, init.io, lookup, .{}) catch |err| return fail(err, &diag);
    }
    var client = storage.Client.init(init.gpa, init.io, .{
        .endpoint = endpoint,
        .token_provider = if (creds) |c| c.provider() else null,
        .diagnostics = &diag,
    }) catch |err| return fail(err, &diag);
    defer client.deinit();
    const object = client.bucket(bucket_name).object(source);

    var read = object.get(.{}) catch |err| return fail(err, &diag);
    defer read.deinit();
    var moved = object.moveTo(destination, .{
        .if_source_generation_match = read.value.generation,
        .preconditions = if (no_clobber) .does_not_exist else .{},
    }) catch |err| switch (err) {
        error.FailedPrecondition => {
            std.debug.print("error: not moved: {s} already exists, or {s} changed since it was read\n", .{ destination, source });
            return err;
        },
        else => return fail(err, &diag),
    };
    defer moved.deinit();
    try out.print("moved gs://{s}/{s} to gs://{s}/{s}, generation {d}, {d} bytes\n", .{
        bucket_name, source, bucket_name, moved.value.name, moved.value.generation, moved.value.size,
    });
}

fn badUsage(out: *std.Io.Writer) !void {
    try out.writeAll(usage);
    try out.flush();
    return error.BadUsage;
}

fn fail(err: anyerror, diag: *const storage.Diagnostics) anyerror {
    if (diag.message().len > 0) {
        std.debug.print("error: {t}: {s}\n", .{ err, diag.message() });
    } else {
        std.debug.print("error: {t}\n", .{err});
    }
    return err;
}
