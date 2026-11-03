//! Runs one API call: core's request engine builds the URL, attaches
//! credentials and the quota project, sends through the client's
//! transport, maps failures to errors and keeps `Diagnostics` and the log
//! current. The reads are GETs, safe to repeat, and so is the wait on an
//! operation.

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const errors = @import("errors.zig");
const Error = errors.Error;

/// The OAuth scopes a client can ask its token provider for. Every read,
/// and the wait on an operation, takes any of them.
pub const Scope = enum {
    /// `compute.readonly`, the default: every read, and no write.
    read_only,
    /// `compute`: every read and every write.
    read_write,
    /// `cloud-platform`, for credentials already fixed to it.
    cloud_platform,

    pub fn url(self: Scope) []const u8 {
        return switch (self) {
            .read_only => "https://www.googleapis.com/auth/compute.readonly",
            .read_write => "https://www.googleapis.com/auth/compute",
            .cloud_platform => "https://www.googleapis.com/auth/cloud-platform",
        };
    }
};

/// The default scope's URL, `compute.readonly`, the narrowest every read
/// takes.
pub const scope = Scope.read_only.url();

/// How long one wait on an operation may take: the server holds it for up
/// to two minutes (measured 2026-11-03), so the client's own request
/// limit, 30 s by default, would cut every long wait short.
pub const wait_request_timeout_ms: u32 = 150_000;

/// The shared engine, logging under this module's scope.
const Engine = core.rpc.Engine(.gcp_compute);

pub const Call = core.rpc.Call;

/// The engine, filled in from one client's settings. There is no
/// unauthenticated mode: Compute has no emulator.
fn engine(client: *Client) Engine {
    return .{
        .gpa = client.gpa,
        .io = client.io,
        .transport = client.transport,
        .base_url = client.base_url,
        .auth_scope = client.scope.url(),
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
/// first 2xx response, which lives in `response`.
pub fn execute(client: *Client, response: *std.heap.ArenaAllocator, call: Call) Error![]const u8 {
    return engine(client).execute(response, call) catch |err| return tooLarge(client, err);
}

/// `execute` for a call the server may hold open for minutes: the wait on
/// an operation. Its request limit is `wait_request_timeout_ms`, or the
/// client's own when that is longer or none (0).
pub fn executeLong(client: *Client, response: *std.heap.ArenaAllocator, call: Call) Error![]const u8 {
    var e = engine(client);
    if (e.request_timeout_ms != 0 and e.request_timeout_ms < wait_request_timeout_ms) e.request_timeout_ms = wait_request_timeout_ms;
    return e.execute(response, call) catch |err| return tooLarge(client, err);
}

fn tooLarge(client: *Client, err: Error) Error {
    if (err == error.ResponseTooLarge) if (client.diagnostics) |d| {
        d.print("the response was larger than max_response_bytes ({d}); ask for a smaller max_results", .{client.max_response_bytes});
    };
    return err;
}

pub fn decodeFailed(client: *Client, err: @import("codec.zig").DecodeError, what: []const u8) Error {
    if (err == error.InvalidResponse) {
        if (client.diagnostics) |d| d.print("the {s} response could not be decoded", .{what});
    }
    return err;
}
