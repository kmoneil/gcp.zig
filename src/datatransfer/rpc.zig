//! Runs one API call: core's request engine builds the URL, attaches
//! credentials and the quota project, sends through the client's
//! transport, maps failures to errors and keeps `Diagnostics` and the log
//! current.

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const errors = @import("errors.zig");
const Error = errors.Error;

/// The OAuth scopes a client can ask its token provider for. Data
/// Transfer has no scope of its own: every read takes any of these, and a
/// run now the first two (discovery).
pub const Scope = enum {
    /// `bigquery`, the default, as `bigquery.Client`'s: one token serves
    /// both modules.
    bigquery,
    /// `cloud-platform`, for credentials already fixed to it.
    cloud_platform,
    /// `cloud-platform.read-only`: reads every Google Cloud API, so
    /// offered rather than the default.
    cloud_platform_read_only,

    pub fn url(self: Scope) []const u8 {
        return switch (self) {
            .bigquery => "https://www.googleapis.com/auth/bigquery",
            .cloud_platform => "https://www.googleapis.com/auth/cloud-platform",
            .cloud_platform_read_only => "https://www.googleapis.com/auth/cloud-platform.read-only",
        };
    }
};

/// The default scope's URL.
pub const scope = Scope.bigquery.url();

/// The shared engine, logging under this module's scope.
const Engine = core.rpc.Engine(.gcp_datatransfer);

pub const Call = core.rpc.Call;

/// The engine, filled in from one client's settings. There is no
/// unauthenticated mode: Data Transfer has no emulator.
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

/// Sends `call`, retrying transient failures as `call.retryable` allows,
/// and returns the body of the first 2xx response, which lives in
/// `response`.
pub fn execute(client: *Client, response: *std.heap.ArenaAllocator, call: Call) Error![]const u8 {
    return engine(client).execute(response, call) catch |err| return tooLarge(client, err);
}

fn tooLarge(client: *Client, err: Error) Error {
    if (err == error.ResponseTooLarge) if (client.diagnostics) |d| {
        d.print("the response was larger than max_response_bytes ({d}); ask for a smaller page_size", .{client.max_response_bytes});
    };
    return err;
}

pub fn decodeFailed(client: *Client, err: @import("codec.zig").DecodeError, what: []const u8) Error {
    if (err == error.InvalidResponse) {
        if (client.diagnostics) |d| d.print("the {s} response could not be decoded", .{what});
    }
    return err;
}
