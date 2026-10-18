//! IAM on key rings and keys: `GET ...:getIamPolicy`, `POST
//! ...:setIamPolicy` with `{"policy": ...}`, and `POST
//! ...:testIamPermissions`, through `core.iam`, on the resource's own
//! path. Versions have no policy of their own; a key's applies to them.
//! `testIamPermissions` answers an empty list for a resource that does not
//! exist, and Google says it "may fail open": a diagnostic, not a check.

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const Error = @import("errors.zig").Error;
const Policy = core.iam.Policy;

/// A key ring or a key, as `core.iam.update` reads and writes its policy.
pub const Resource = struct {
    client: *Client,
    target: names.Target,

    pub fn readPolicy(r: Resource) Error!types.Owned(Policy) {
        var scratch: std.heap.ArenaAllocator = .init(r.client.gpa);
        defer scratch.deinit();
        const path = try r.target.path(scratch.allocator(), ":getIamPolicy?options.requestedPolicyVersion=3");
        return fetch(r.client, .{ .method = .GET, .path = path });
    }

    /// Writes `policy` whole, with no `updateMask`. Retried only under an
    /// etag: a retry then fails cleanly, as `error.Aborted`, when the
    /// first attempt landed.
    pub fn writePolicy(r: Resource, policy: Policy) Error!types.Owned(Policy) {
        var scratch: std.heap.ArenaAllocator = .init(r.client.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const path = try r.target.path(a, ":setIamPolicy");
        const conditional = if (policy.etag) |etag| etag.len > 0 else false;
        return fetch(r.client, .{ .method = .POST, .path = path, .body = try core.iam.encodeSet(a, policy), .retry = conditional });
    }

    /// The delay the last refused call asked for, for `core.iam.update`.
    pub fn serverDelayMs(r: Resource) ?u32 {
        return r.client.server_delay_ms;
    }
};

/// `getIamPolicy`, after checking the resource's ids.
pub fn read(r: Resource) Error!types.Owned(Policy) {
    rpc.begin(r.client);
    try r.client.checkTarget(r.target);
    return r.readPolicy();
}

/// `setIamPolicy`, after the check every service shares: roles of a known
/// form.
pub fn set(r: Resource, policy: Policy) Error!types.Owned(Policy) {
    rpc.begin(r.client);
    try r.client.checkTarget(r.target);
    for (policy.bindings) |b| {
        if (core.iam.roleProblem(b.role)) |problem| {
            if (r.client.diagnostics) |d| d.print("role \"{s}\": {s}", .{ b.role, problem });
            return error.InvalidArgument;
        }
    }
    return r.writePolicy(policy);
}

/// `addIamBinding` and `removeIamBinding`, after the checks.
pub fn change(r: Resource, what: core.iam.Change) Error!types.Owned(Policy) {
    const c = r.client;
    rpc.begin(c);
    try c.checkTarget(r.target);
    const grant = switch (what) {
        inline else => |g| g,
    };
    if (core.iam.roleProblem(grant.role)) |problem| {
        if (c.diagnostics) |d| d.print("role \"{s}\": {s}", .{ grant.role, problem });
        return error.InvalidArgument;
    }
    if (core.iam.memberProblem(grant.member, .{ .deleted = what == .revoke })) |problem| {
        if (c.diagnostics) |d| d.print("member \"{s}\": {s}", .{ grant.member, problem });
        return error.InvalidArgument;
    }
    return core.iam.update(c.gpa, c.io, c.retry, r, what);
}

/// `testIamPermissions`: the permissions the caller holds, of those asked.
pub fn testPermissions(r: Resource, permissions: []const []const u8) Error!types.Owned([]const []const u8) {
    const c = r.client;
    rpc.begin(c);
    try c.checkTarget(r.target);
    if (core.iam.permissionsProblem(permissions)) |problem| {
        if (c.diagnostics) |d| d.print("{s}", .{problem});
        return error.InvalidArgument;
    }
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try r.target.path(a, ":testIamPermissions");
    var result: types.Owned([]const []const u8) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, .{ .method = .POST, .path = path, .body = try core.iam.encodePermissions(a, permissions) });
    result.value = core.iam.decodePermissions(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(c, err, "testIamPermissions answer");
    return result;
}

fn fetch(c: *Client, call: rpc.Call) Error!types.Owned(Policy) {
    var result: types.Owned(Policy) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, call);
    result.value = core.iam.decode(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(c, err, "IAM policy");
    return result;
}
