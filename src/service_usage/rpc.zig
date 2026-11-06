//! Runs one API call: core's request engine builds the URL, attaches
//! credentials and the quota project, sends through the client's
//! transport, maps failures to errors and keeps `Diagnostics` and the log
//! current. Every call here is a GET, safe to repeat.

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const errors = @import("errors.zig");
const Error = errors.Error;

/// The OAuth scopes a client can ask its token provider for. Every call
/// here takes either; production refused `service.management`,
/// `service.management.readonly` and a scope of another API, 403
/// "Request had insufficient authentication scopes." (measured).
pub const Scope = enum {
    /// `cloud-platform.read-only`, the default and the narrowest.
    read_only,
    /// `cloud-platform`, for credentials already fixed to it, as a VM's
    /// metadata server usually is.
    cloud_platform,

    pub fn url(self: Scope) []const u8 {
        return switch (self) {
            .read_only => "https://www.googleapis.com/auth/cloud-platform.read-only",
            .cloud_platform => "https://www.googleapis.com/auth/cloud-platform",
        };
    }
};

/// The default scope's URL, `cloud-platform.read-only`.
pub const scope = Scope.read_only.url();

/// The shared engine, logging under this module's scope.
const Engine = core.rpc.Engine(.gcp_service_usage);

pub const Call = core.rpc.Call;

/// The engine, filled in from one client's settings. There is no
/// unauthenticated mode: production refuses a call without credentials
/// ("Method doesn't allow unregistered callers", measured), and there is
/// no emulator.
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
