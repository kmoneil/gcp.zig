//! Runs one API call: core's request engine builds the URL, attaches
//! credentials and the quota project, sends through the client's transport,
//! maps failures to errors and keeps `Diagnostics` and the log current. This
//! file binds that engine to a Cloud KMS client, and turns a refusal that
//! names a version's state into the error for that state.

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const logging = @import("logging.zig");
const Error = errors.Error;

/// The OAuth scope the client asks its token provider for. Every Cloud KMS
/// method takes it or `cloud-platform`; there is no narrower one.
pub const scope = "https://www.googleapis.com/auth/cloudkms";

/// The shared engine, logging under this module's scope.
const Engine = core.rpc.Engine(.gcp_kms);

pub const Call = core.rpc.Call;

/// The engine, filled in from one client's settings. There is no
/// unauthenticated mode: Cloud KMS has no emulator.
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

/// Sends `call`, retrying transient failures as `call` allows, and returns
/// the body of the first 2xx response, which lives in `response`. A
/// refusal that names a key version's state is that state's error.
pub fn execute(client: *Client, response: *std.heap.ArenaAllocator, call: Call) Error![]const u8 {
    var error_body: ?[]const u8 = null;
    var with_body = call;
    with_body.error_body_out = &error_body;
    return engine(client).execute(response, with_body) catch |err| return refined(client, err, error_body);
}

/// `execute` for calls whose response body is not needed.
pub fn executeDiscard(client: *Client, call: Call) Error!void {
    var response: std.heap.ArenaAllocator = .init(client.gpa);
    defer response.deinit();
    _ = try execute(client, &response, call);
}

/// The error for a failed call: `FAILED_PRECONDITION` with a
/// `PreconditionFailure` naming a version's state becomes that state's
/// error; everything else stays as the engine mapped it.
fn refined(client: *Client, err: Error, error_body: ?[]const u8) Error {
    if (err == error.ResponseTooLarge) if (client.diagnostics) |d| {
        d.print("the response was larger than max_response_bytes ({d}); ask for a smaller page_size", .{client.max_response_bytes});
    };
    if (err != error.FailedPrecondition) return err;
    const body = error_body orelse return err;
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const violations = core.errors.decodePreconditionFailures(scratch.allocator(), body) catch return err;
    for (violations) |v| {
        if (stateError(v.type)) |state_err| return state_err;
    }
    return err;
}

/// The error a `PreconditionFailure` violation type stands for, as Cloud
/// KMS writes them for a version that is not enabled.
pub fn stateError(violation_type: []const u8) ?Error {
    const map = std.StaticStringMap(Error).initComptime(.{
        .{ "KEY_PENDING_GENERATION", error.KeyVersionPending },
        .{ "KEY_DISABLED", error.KeyVersionDisabled },
        .{ "KEY_DESTROY_SCHEDULED", error.KeyVersionDestroyed },
        .{ "KEY_DESTROYED", error.KeyVersionDestroyed },
    });
    return map.get(violation_type);
}

/// Sends a create that a repeat after it landed would refuse as
/// `ALREADY_EXISTS`, as a key ring's or a key's is. A failure the house
/// rule would retry is followed by a read of `get_path`: found, the create
/// landed and the read is its answer; `NOT_FOUND`, the create goes out
/// again, up to the retry policy's attempts. So `ALREADY_EXISTS` always
/// means the id was taken before this call. `what` names the resource for
/// the log and `Diagnostics`.
pub fn createOnce(client: *Client, response: *std.heap.ArenaAllocator, create: Call, get_path: []const u8, what: []const u8) Error![]const u8 {
    var call = create;
    call.retry = false;
    var attempt: u32 = 0;
    while (true) {
        attempt += 1;
        _ = response.reset(.retain_capacity);
        if (execute(client, response, call)) |body| {
            return body;
        } else |err| {
            if (!core.isRetryable(err)) return err;
            const delay_ms = waitMs(client, attempt) orelse return err;
            logging.warn("creating {s} failed with {t}; reading it in {d} ms", .{ what, err, delay_ms });
            try client.io.sleep(.fromMilliseconds(delay_ms), .awake);
            _ = response.reset(.retain_capacity);
            if (execute(client, response, .{ .method = .GET, .path = get_path })) |found| {
                if (client.diagnostics) |d| d.clear();
                return found;
            } else |get_err| switch (get_err) {
                error.NotFound => {},
                error.OutOfMemory, error.Canceled => return get_err,
                else => {
                    if (client.diagnostics) |d| d.print(
                        "creating {s} failed with {t}, and reading it to see whether it landed failed with {t}: it may exist",
                        .{ what, err, get_err },
                    );
                    return err;
                },
            }
            if (attempt >= client.retry.max_attempts) return err;
        }
    }
}

/// Whether a failed attempt may be tried again when a repeat would make
/// something new: only a failure raised before the request left, a
/// refused connection or a name lookup that failed. A TLS failure or an
/// unreachable network can also come after the request went, on a
/// connection already open.
pub fn unsentOnly(err: anyerror, http_status: u16) bool {
    _ = http_status;
    return switch (err) {
        error.ConnectionRefused, error.NameServerFailure => true,
        else => false,
    };
}

/// How long to wait before attempt `attempt + 1`, under the client's
/// policy and the delay the last refusal asked for; null when the policy
/// will not wait that long.
pub fn waitMs(client: *Client, attempt: u32) ?u32 {
    return client.retry.waitMs(attempt, core.rpc.entropy(client.io), client.server_delay_ms);
}

pub fn decodeFailed(client: *Client, err: codec.DecodeError, what: []const u8) Error {
    if (err == error.InvalidResponse) {
        if (client.diagnostics) |d| d.print("the {s} response could not be decoded", .{what});
    }
    return err;
}

const testing = std.testing;

test "stateError: the four violation types Cloud KMS writes, nothing else" {
    try testing.expectEqual(error.KeyVersionPending, stateError("KEY_PENDING_GENERATION").?);
    try testing.expectEqual(error.KeyVersionDisabled, stateError("KEY_DISABLED").?);
    try testing.expectEqual(error.KeyVersionDestroyed, stateError("KEY_DESTROY_SCHEDULED").?);
    try testing.expectEqual(error.KeyVersionDestroyed, stateError("KEY_DESTROYED").?);
    try testing.expectEqual(null, stateError("INVALID_ENUM_VALUE_CHOICE"));
    try testing.expectEqual(null, stateError("key_disabled"));
}

test "unsentOnly: a refused connection and a failed lookup, nothing after a send" {
    try testing.expect(unsentOnly(error.ConnectionRefused, 0));
    try testing.expect(unsentOnly(error.NameServerFailure, 0));
    for ([_]anyerror{ error.ConnectionResetByPeer, error.TimedOut, error.Unavailable, error.Internal, error.TlsFailure, error.NetworkUnreachable }) |err| {
        try testing.expect(!unsentOnly(err, 503));
    }
}
