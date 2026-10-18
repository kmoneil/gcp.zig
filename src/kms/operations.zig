//! Deletes, the only calls in this library that answer a long-running
//! operation: a key version's, a key's and a key ring's. Each is sent, and
//! its operation polled under the client's backoff until it is done.
//!
//! A delete is retried as sent, since a repeat of one that landed can only
//! be refused: after an attempt that may have reached the server,
//! `NOT_FOUND` means the first one did. A first attempt's `NOT_FOUND` is
//! the caller's error.

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const logging = @import("logging.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const Error = @import("errors.zig").Error;

/// Deletes what `path` names (`what` says what, for the log and
/// `Diagnostics`), and waits for its operation to finish.
pub fn delete(client: *Client, path: []const u8, what: []const u8) Error!void {
    var attempt: u32 = 0;
    var response: std.heap.ArenaAllocator = .init(client.gpa);
    defer response.deinit();
    const body = while (true) {
        attempt += 1;
        _ = response.reset(.retain_capacity);
        if (rpc.execute(client, &response, .{ .method = .DELETE, .path = path, .retry = false })) |b| {
            break b;
        } else |err| {
            if (err == error.NotFound and attempt > 1) {
                logging.debug("{s} was gone on attempt {d}: the earlier one deleted it", .{ what, attempt });
                if (client.diagnostics) |d| d.clear();
                return;
            }
            if (!core.isRetryable(err) or attempt >= client.retry.max_attempts) return err;
            const delay_ms = rpc.waitMs(client, attempt) orelse return err;
            logging.warn("deleting {s} failed with {t}; trying again in {d} ms", .{ what, err, delay_ms });
            try client.io.sleep(.fromMilliseconds(delay_ms), .awake);
        }
    };
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const op = codec.decodeOperation(scratch.allocator(), scratch.allocator(), body) catch |err|
        return rpc.decodeFailed(client, err, "delete operation");
    return wait(client, op, what);
}

/// Polls `first` until it is done: an error it ended with is returned as
/// its status maps, and a wait that outlasts the retry policy's attempts
/// is `error.DeadlineExceeded`, the operation's name in `Diagnostics`.
fn wait(client: *Client, first: codec.Operation, what: []const u8) Error!void {
    var op = first;
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    var attempt: u32 = 0;
    while (!op.done) {
        attempt += 1;
        if (attempt > client.retry.max_attempts) {
            if (client.diagnostics) |d| d.print("deleting {s} is still running as operation {s}", .{ what, op.name });
            return error.DeadlineExceeded;
        }
        if (!names.isOperationName(op.name)) {
            if (client.diagnostics) |d| d.print("the delete's operation has a name this client will not put in a path: {s}", .{op.name});
            return error.InvalidResponse;
        }
        const delay_ms = rpc.waitMs(client, attempt) orelse client.retry.max_backoff_ms;
        try client.io.sleep(.fromMilliseconds(delay_ms), .awake);
        // At most `max_attempts` small answers: the arena keeps them all.
        const a = scratch.allocator();
        const path = try names.operation(a, op.name);
        var response: std.heap.ArenaAllocator = .init(client.gpa);
        defer response.deinit();
        const body = try rpc.execute(client, &response, .{ .method = .GET, .path = path });
        op = codec.decodeOperation(a, a, body) catch |err| return rpc.decodeFailed(client, err, "operation");
    }
    const failure = op.failure orelse return;
    if (client.diagnostics) |d| d.print("deleting {s} failed after it started: {s}", .{ what, failure.message });
    return core.errors.fromRpcCode(failure.code);
}
