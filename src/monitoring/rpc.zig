//! Runs one API call: core's request engine builds the URL, attaches
//! credentials and the quota project, sends through the client's transport,
//! maps failures to errors and keeps `Diagnostics` and the log current. This
//! file binds that engine to a Cloud Monitoring client, and runs a write:
//! a refusal that judged the points one by one is the write's result, and a
//! failure is retried only as `Options.write_retries` allows.

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const logging = @import("logging.zig");
const types = @import("types.zig");
const Error = errors.Error;

/// The OAuth scope the client asks its token provider for: the narrowest
/// one every call here takes. `monitoring.write` cannot delete a
/// descriptor, and `monitoring.read` cannot write.
pub const scope = "https://www.googleapis.com/auth/monitoring";

/// The shared engine, logging under this module's scope.
const Engine = core.rpc.Engine(.gcp_monitoring);

pub const Call = core.rpc.Call;

/// The engine, filled in from one client's settings. There is no
/// unauthenticated mode: Cloud Monitoring has no emulator.
fn engine(client: *Client) Engine {
    return .{
        .gpa = client.gpa,
        .io = client.io,
        .transport = client.transport,
        .base_url = client.base_url,
        .auth_scope = scope,
        .token_provider = client.token_provider,
        .send_quota_project = client.send_quota_project,
        .retry = client.retry,
        .request_timeout_ms = client.request_timeout_ms,
        .diagnostics = client.diagnostics,
        .server_delay_out = &client.server_delay_ms,
    };
}

/// Starts a public call: `Diagnostics` describe only the latest call.
pub fn begin(client: *Client) void {
    engine(client).begin();
}

/// Sends `call`, retrying transient failures, and returns the body of the
/// first 2xx response, which lives in `response`. Reads and descriptor
/// calls go this way: each is safe to repeat. Creating a descriptor twice
/// was 200 both times when measured, and deleting one twice is `NotFound`.
pub fn execute(client: *Client, response: *std.heap.ArenaAllocator, call: Call) Error![]const u8 {
    return engine(client).execute(response, call) catch |err| return tooLarge(client, err);
}

/// `execute` for calls whose response body is not needed.
pub fn executeDiscard(client: *Client, call: Call) Error!void {
    return engine(client).executeDiscard(call) catch |err| return tooLarge(client, err);
}

fn tooLarge(client: *Client, err: Error) Error {
    if (err == error.ResponseTooLarge) if (client.diagnostics) |d| {
        d.print("the response was larger than max_response_bytes ({d}); ask for a smaller page_size", .{client.max_response_bytes});
    };
    return err;
}

/// Whether a failed write is worth another try under `rule`. A failure
/// raised before the request left is always worth one: a refused
/// connection, or a name lookup that failed. A TLS failure or an
/// unreachable network can also come from a read or a write on a
/// connection already open, after the request may have gone, so they are
/// not counted with those.
pub fn writeRetryable(rule: types.WriteRetries, err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused, error.NameServerFailure => true,
        else => rule == .transient and core.isRetryable(err),
    };
}

/// Sends one `timeSeries.create` of `points` series. A 2xx answer wrote
/// them all. An error that carries a `CreateTimeSeriesSummary` is the
/// result, never retried: the server judged each point, and sending the
/// stored ones again would only have them refused. Any other failure is
/// retried as `client.write_retries` allows, then returned. The result's
/// refusals and message live in `out`.
pub fn write(client: *Client, out: *std.heap.ArenaAllocator, path: []const u8, body: []const u8, points: u32) Error!types.WriteResult {
    var response: std.heap.ArenaAllocator = .init(client.gpa);
    defer response.deinit();
    var local: core.Diagnostics = .{};
    var e = engine(client);
    if (e.diagnostics == null) e.diagnostics = &local;
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        var error_body: ?[]const u8 = null;
        if (e.execute(&response, .{
            .method = .POST,
            .path = path,
            .body = body,
            .retry = false,
            .error_body_out = &error_body,
        })) |_| {
            return .{ .points = points, .written = points };
        } else |err| {
            if (error_body) |eb| {
                var scratch: std.heap.ArenaAllocator = .init(client.gpa);
                defer scratch.deinit();
                const summary = codec.decodeSummary(out.allocator(), scratch.allocator(), eb) catch |decode_err| {
                    if (decode_err == error.InvalidResponse) if (client.diagnostics) |d| d.print("the write's summary could not be decoded", .{});
                    return decode_err;
                };
                if (summary) |s| {
                    logging.debug("a write of {d} points wrote {d}", .{ points, s.written });
                    return .{ .points = points, .written = @min(s.written, points), .refused = s.refused, .message = s.message };
                }
            }
            if (attempt >= client.retry.max_attempts or !writeRetryable(client.write_retries, err)) return tooLarge(client, err);
            const delay_ms = client.retry.waitMs(attempt, core.rpc.entropy(client.io), client.server_delay_ms) orelse return err;
            logging.warn("a write failed with {t}; retrying in {d} ms (attempt {d} of {d})", .{ err, delay_ms, attempt + 1, client.retry.max_attempts });
            _ = response.reset(.retain_capacity);
            try client.io.sleep(.fromMilliseconds(delay_ms), .awake);
        }
    }
}

pub fn decodeFailed(client: *Client, err: codec.DecodeError, what: []const u8) Error {
    if (err == error.InvalidResponse) {
        if (client.diagnostics) |d| d.print("the {s} response could not be decoded", .{what});
    }
    return err;
}

test "writeRetryable: unsent failures always, the rest only when asked" {
    for ([_]anyerror{ error.ConnectionRefused, error.NameServerFailure }) |err| {
        try std.testing.expect(writeRetryable(.unsent_only, err));
        try std.testing.expect(writeRetryable(.transient, err));
    }
    for ([_]anyerror{ error.ResourceExhausted, error.Internal, error.Unavailable, error.DeadlineExceeded, error.ConnectionResetByPeer, error.ConnectionTimedOut, error.TimedOut, error.TlsFailure, error.NetworkUnreachable }) |err| {
        try std.testing.expect(!writeRetryable(.unsent_only, err));
        try std.testing.expect(writeRetryable(.transient, err));
    }
    for ([_]anyerror{ error.InvalidArgument, error.PermissionDenied, error.NotFound, error.UnknownHostName, error.Unauthenticated }) |err| {
        try std.testing.expect(!writeRetryable(.transient, err));
    }
}
