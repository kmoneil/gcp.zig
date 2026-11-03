//! A Compute Engine client: the VMs in a zone or every zone, each with its
//! status, scheduling, disks, network and the fingerprints a change must
//! send back; a VM's serial console and guest attributes; the zones,
//! machine types and images a create needs; and operations, read and
//! waited on. Nothing here creates, changes or deletes anything yet.
//!
//! Every call blocks the calling task until it completes, using the
//! `std.Io` and allocator passed to `init`. A client must not be used from
//! two tasks at once; give each task its own.

const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const codec = @import("codec.zig");
const errors = @import("errors.zig");
const logging = @import("logging.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Diagnostics = core.Diagnostics;
const Error = errors.Error;
const HttpTransport = core.transport.HttpTransport;
const RetryPolicy = core.RetryPolicy;
const TokenProvider = core.TokenProvider;
const Transport = core.transport.Transport;

gpa: Allocator,
io: std.Io,
/// Owned. Scheme, host and port.
base_url: []const u8,
token_provider: TokenProvider,
/// Owned copy of `Options.project_id`.
project: []const u8,
scope: rpc.Scope,
send_quota_project: bool,
retry: RetryPolicy,
request_timeout_ms: u32,
max_response_bytes: usize,
diagnostics: ?*Diagnostics,
transport: Transport,
/// The built-in transport, when `Options.transport` was null.
http: ?*HttpTransport,
/// Owned copy of `Options.user_agent`.
user_agent: []const u8,
/// The delay the last refused attempt asked for, kept by the engine.
server_delay_ms: ?u32 = null,

pub const default_endpoint = "https://compute.googleapis.com";

pub const Options = struct {
    /// Required: the project whose VMs are read, an id or a number.
    project_id: []const u8,
    /// Required. Compute Engine has no emulator, so there is no
    /// unauthenticated mode.
    token_provider: TokenProvider,
    /// The OAuth scope asked of the token provider for every call. The
    /// default, `compute.readonly`, takes every read and the wait on an
    /// operation. A provider made from a key file, workload identity or
    /// impersonation is fixed to the scope its first token was minted for
    /// (`auth.Credentials.bindsScopes`), so a client asks for one scope
    /// only.
    scope: rpc.Scope = .read_only,
    /// Overrides the host: a test server, say. Must be `https`, since it
    /// receives credentials.
    endpoint: ?[]const u8 = null,
    /// Sends the credentials' quota project as `x-goog-user-project`, as
    /// every module does.
    send_quota_project: bool = true,
    /// The reads, and the wait on an operation, retry 5xx, 429 and dropped
    /// connections.
    retry: RetryPolicy = .{},
    /// How long one request may take before it is `error.TimedOut`, which
    /// is retried. 0 removes the limit. A wait on an operation is given
    /// at least 150 s, since the server holds it for up to two minutes.
    request_timeout_ms: u32 = 30_000,
    /// A response whose decompressed body is larger fails with
    /// `error.ResponseTooLarge`. Used by the built-in transport; a
    /// transport passed in keeps its own limit.
    max_response_bytes: usize = core.transport.default_max_response_bytes,
    /// Printable ASCII.
    user_agent: []const u8 = "gcp-zig-compute/0.62",
    /// Filled with details of every failed call; cleared by each new call.
    diagnostics: ?*Diagnostics = null,
    /// Sends requests through this instead of `std.http.Client`. Useful
    /// for tests, including tests of code that uses this library.
    transport: ?Transport = null,
};

/// Copies what it keeps from `options`; nothing borrowed outlives the call
/// except `diagnostics`, the token provider and the transport.
pub fn init(gpa: Allocator, io: std.Io, options: Options) Error!Client {
    const diag = options.diagnostics;
    if (diag) |d| d.clear();
    try checkOptions(options);
    const base_url = core.endpoint.baseUrl(gpa, options.endpoint orelse default_endpoint, .https) catch |err| {
        if (err == error.InvalidEndpoint) if (diag) |d| d.print("invalid endpoint: expected https://host[:port]", .{});
        return err;
    };
    errdefer gpa.free(base_url);
    // Every request carries a bearer token, which must not travel in
    // cleartext.
    if (!std.mem.startsWith(u8, base_url, "https://")) {
        if (diag) |d| d.print("invalid endpoint: endpoints that receive credentials must use https", .{});
        return error.InvalidEndpoint;
    }
    const project = try gpa.dupe(u8, options.project_id);
    errdefer gpa.free(project);
    const user_agent = try gpa.dupe(u8, options.user_agent);
    errdefer gpa.free(user_agent);

    var http: ?*HttpTransport = null;
    const transport = options.transport orelse t: {
        const h = try gpa.create(HttpTransport);
        h.* = .init(gpa, io, user_agent);
        h.max_response_bytes = options.max_response_bytes;
        http = h;
        break :t h.transport();
    };
    return .{
        .gpa = gpa,
        .io = io,
        .base_url = base_url,
        .token_provider = options.token_provider,
        .project = project,
        .scope = options.scope,
        .send_quota_project = options.send_quota_project,
        .retry = options.retry,
        .request_timeout_ms = options.request_timeout_ms,
        .max_response_bytes = options.max_response_bytes,
        .diagnostics = diag,
        .transport = transport,
        .http = http,
        .user_agent = user_agent,
    };
}

fn checkOptions(options: Options) Error!void {
    const diag = options.diagnostics;
    if (!core.names.isProjectId(options.project_id)) {
        if (diag) |d| d.print("invalid project: expected a project id or number", .{});
        return error.InvalidName;
    }
    if (!options.retry.isValid()) {
        if (diag) |d| d.print("invalid retry policy: max_attempts must be at least 1, multiplier finite and at least 1", .{});
        return error.InvalidOptions;
    }
    if (!validate.isUserAgent(options.user_agent)) {
        if (diag) |d| d.print("invalid user agent: expected printable ASCII", .{});
        return error.InvalidOptions;
    }
    if (options.max_response_bytes == 0) {
        if (diag) |d| d.print("invalid max_response_bytes: 0 would refuse every answer", .{});
        return error.InvalidOptions;
    }
}

pub fn deinit(self: *Client) void {
    if (self.http) |h| {
        h.deinit();
        self.gpa.destroy(h);
    }
    self.gpa.free(self.project);
    self.gpa.free(self.user_agent);
    self.gpa.free(self.base_url);
    self.* = undefined;
}

// Instances.

/// One page of a zone's VMs, sorted by name unless `options.order_by`
/// says otherwise.
pub fn listInstances(self: *Client, zone: []const u8, options: types.ListOptions) Error!types.Owned(types.InstancePage) {
    rpc.begin(self);
    try self.checkZone(zone);
    try self.checkList(options);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const path = try self.listPath(scratch.allocator(), try self.print(scratch.allocator(), "zones/{s}/instances", .{zone}), options);
    return self.read(types.InstancePage, path, codec.decodeInstancePage, "instance list");
}

/// One page of the VMs in every zone at once, each with its `zone`. A zone
/// with nothing in it is left out; a zone production could not answer for
/// is in `warnings` (and `unreachables`), not an error, when
/// `options.partial_success` is set. A page is counted in VMs, and may
/// span zones.
pub fn listAllInstances(self: *Client, options: types.ListOptions) Error!types.Owned(types.AggregatedInstancePage) {
    rpc.begin(self);
    try self.checkList(options);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const path = try self.listPath(scratch.allocator(), "aggregated/instances", options);
    return self.read(types.AggregatedInstancePage, path, codec.decodeAggregatedInstancePage, "aggregated instance list");
}

/// One VM. `error.NotFound` when the zone has none of that name.
pub fn getInstance(self: *Client, zone: []const u8, name: []const u8) Error!types.Owned(types.Instance) {
    rpc.begin(self);
    try self.checkZone(zone);
    try self.checkName(name, "instance");
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const path = try self.print(scratch.allocator(), "/compute/v1/projects/{s}/zones/{s}/instances/{s}", .{ self.project, zone, name });
    return self.read(types.Instance, path, codec.decodeInstance, "instance");
}

/// A stretch of a VM's serial console, at most 1 MiB: the newest, or from
/// `options.start` (a `SerialOutput.next`) on. Reading on from `next`
/// until it stops moving follows the console as it grows.
pub fn serialOutput(self: *Client, zone: []const u8, name: []const u8, options: types.SerialOptions) Error!types.Owned(types.SerialOutput) {
    rpc.begin(self);
    try self.checkZone(zone);
    try self.checkName(name, "instance");
    if (options.port < validate.serial_ports.min or options.port > validate.serial_ports.max) {
        if (self.diagnostics) |d| d.print("invalid serial port {d}: a VM has ports 1 to 4", .{options.port});
        return error.InvalidOptions;
    }
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.print("/compute/v1/projects/{s}/zones/{s}/instances/{s}/serialPort", .{ self.project, zone, name }) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    params.addInt("port", options.port) catch return error.OutOfMemory;
    if (options.start) |start| params.addInt("start", start) catch return error.OutOfMemory;
    return self.read(types.SerialOutput, w.written(), codec.decodeSerialOutput, "serial output");
}

/// The guest attributes a VM's guest wrote under `query_path`, a
/// namespace (`zigps/`) or one key (`zigps/probe`). The VM needs the
/// metadata `enable-guest-attributes` set to TRUE. A path with nothing
/// under it is `error.NotFound`, as production answered.
pub fn guestAttributes(self: *Client, zone: []const u8, name: []const u8, query_path: []const u8) Error!types.Owned(types.GuestAttributes) {
    rpc.begin(self);
    try self.checkZone(zone);
    try self.checkName(name, "instance");
    if (!validate.isQueryPath(query_path)) {
        if (self.diagnostics) |d| d.print("invalid query path: expected namespace/ or namespace/key, visible ASCII", .{});
        return error.InvalidName;
    }
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.print("/compute/v1/projects/{s}/zones/{s}/instances/{s}/getGuestAttributes", .{ self.project, zone, name }) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    params.add("queryPath", query_path) catch return error.OutOfMemory;
    return self.read(types.GuestAttributes, w.written(), codec.decodeGuestAttributes, "guest attributes");
}

// What a create needs.

/// One page of the zones the project can use.
pub fn listZones(self: *Client, options: types.ListOptions) Error!types.Owned(types.ZonePage) {
    rpc.begin(self);
    try self.checkList(options);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const path = try self.listPath(scratch.allocator(), "zones", options);
    return self.read(types.ZonePage, path, codec.decodeZonePage, "zone list");
}

pub fn getZone(self: *Client, zone: []const u8) Error!types.Owned(types.Zone) {
    rpc.begin(self);
    try self.checkZone(zone);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const path = try self.print(scratch.allocator(), "/compute/v1/projects/{s}/zones/{s}", .{ self.project, zone });
    return self.read(types.Zone, path, codec.decodeZone, "zone");
}

/// One page of a zone's machine types, 500 to a page by default.
pub fn listMachineTypes(self: *Client, zone: []const u8, options: types.ListOptions) Error!types.Owned(types.MachineTypePage) {
    rpc.begin(self);
    try self.checkZone(zone);
    try self.checkList(options);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const path = try self.listPath(scratch.allocator(), try self.print(scratch.allocator(), "zones/{s}/machineTypes", .{zone}), options);
    return self.read(types.MachineTypePage, path, codec.decodeMachineTypePage, "machine type list");
}

pub fn getMachineType(self: *Client, zone: []const u8, name: []const u8) Error!types.Owned(types.MachineType) {
    rpc.begin(self);
    try self.checkZone(zone);
    try self.checkName(name, "machine type");
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const path = try self.print(scratch.allocator(), "/compute/v1/projects/{s}/zones/{s}/machineTypes/{s}", .{ self.project, zone, name });
    return self.read(types.MachineType, path, codec.decodeMachineType, "machine type");
}

/// An image by name, in `project`: a public one's (`debian-cloud`) or the
/// client's own.
pub fn getImage(self: *Client, project: []const u8, name: []const u8) Error!types.Owned(types.Image) {
    return self.image(project, name, "images/{s}", "image");
}

/// The newest image in `family` that is not deprecated, in `project`:
/// `imageFromFamily("debian-cloud", "debian-12")`.
pub fn imageFromFamily(self: *Client, project: []const u8, family: []const u8) Error!types.Owned(types.Image) {
    return self.image(project, family, "images/family/{s}", "image family");
}

fn image(self: *Client, project: []const u8, name: []const u8, comptime tail: []const u8, what: []const u8) Error!types.Owned(types.Image) {
    rpc.begin(self);
    if (!validate.isProject(project)) {
        if (self.diagnostics) |d| d.print("invalid image project: expected a project id, such as debian-cloud", .{});
        return error.InvalidName;
    }
    try self.checkName(name, what);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const path = try self.print(scratch.allocator(), "/compute/v1/projects/{s}/global/" ++ tail, .{ project, name });
    return self.read(types.Image, path, codec.decodeImage, what);
}

// Operations.

/// One page of a scope's operations, oldest first, as production answered
/// them. A zone's tell what ended
/// a VM: `compute.instances.preempted`, `.deferredDelete` (a run limit),
/// `.guestTerminate` (its guest), each by "system"; filter them with
/// `targetLink eq .*/instances/<name>`.
pub fn listOperations(self: *Client, scope: types.OperationScope, options: types.ListOptions) Error!types.Owned(types.OperationPage) {
    rpc.begin(self);
    try self.checkScope(scope);
    try self.checkList(options);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try self.listPath(a, try self.scopePath(a, scope), options);
    return self.read(types.OperationPage, path, codec.decodeOperationPage, "operation list");
}

/// An operation as it stands now.
pub fn getOperation(self: *Client, ref: types.OperationRef) Error!types.Owned(types.Operation) {
    rpc.begin(self);
    try self.checkScope(ref.scope);
    try self.checkName(ref.name, "operation");
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try std.fmt.allocPrint(a, "/compute/v1/projects/{s}/{s}/{s}", .{ self.project, try self.scopePath(a, ref.scope), ref.name });
    return self.read(types.Operation, path, codec.decodeOperation, "operation");
}

/// Waits for an operation to be DONE, or for `options.timeout_ms` to
/// pass, and answers it as it stands then: done or not, failed or not. A
/// write that failed while acting is DONE with `failure` set, which is an
/// answer, not an error. Each wait call is held by the server for up to
/// two minutes; one that returns sooner with the operation still running
/// is followed by a pause of a second, so an early answer does not spin.
pub fn waitOperation(self: *Client, ref: types.OperationRef, options: types.WaitOptions) Error!types.Owned(types.Operation) {
    rpc.begin(self);
    try self.checkScope(ref.scope);
    try self.checkName(ref.name, "operation");
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try std.fmt.allocPrint(a, "/compute/v1/projects/{s}/{s}/{s}/wait", .{ self.project, try self.scopePath(a, ref.scope), ref.name });
    const clock: std.Io.Clock = .awake;
    const deadline = clock.now(self.io).addDuration(.fromMilliseconds(options.timeout_ms));
    var calls: u32 = 0;
    while (true) {
        const started = clock.now(self.io);
        var result = try self.waitOnce(path);
        calls += 1;
        const now = clock.now(self.io);
        if (result.value.done() or now.toNanoseconds() >= deadline.toNanoseconds()) {
            logging.debug("wait {s}: {t} after {d} call(s)", .{ ref.name, result.value.status, calls });
            return result;
        }
        result.deinit();
        if (started.durationTo(now).toMilliseconds() < 1000) {
            const left = now.durationTo(deadline).toMilliseconds();
            self.io.sleep(.fromMilliseconds(@min(1000, left)), .awake) catch return error.Canceled;
        }
    }
}

fn waitOnce(self: *Client, path: []const u8) Error!types.Owned(types.Operation) {
    var result: types.Owned(types.Operation) = try .init(self.gpa);
    errdefer result.deinit();
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const body = try rpc.executeLong(self, result.arena, .{ .method = .POST, .path = path, .body = "" });
    result.value = codec.decodeOperation(result.arena.allocator(), scratch.allocator(), body) catch |err|
        return rpc.decodeFailed(self, err, "operation");
    return result;
}

// The plumbing.

/// A GET whose answer `decode` reads into an `Owned(T)`.
fn read(
    self: *Client,
    comptime T: type,
    path: []const u8,
    comptime decode: fn (Allocator, Allocator, []const u8) codec.DecodeError!T,
    what: []const u8,
) Error!types.Owned(T) {
    var result: types.Owned(T) = try .init(self.gpa);
    errdefer result.deinit();
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = path });
    result.value = decode(result.arena.allocator(), scratch.allocator(), body) catch |err|
        return rpc.decodeFailed(self, err, what);
    return result;
}

fn print(self: *Client, a: Allocator, comptime fmt: []const u8, args: anytype) Error![]const u8 {
    _ = self;
    return std.fmt.allocPrint(a, fmt, args) catch error.OutOfMemory;
}

/// `/compute/v1/projects/P/<tail>?<the list's query>`.
fn listPath(self: *Client, a: Allocator, tail: []const u8, options: types.ListOptions) Error![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.print("/compute/v1/projects/{s}/{s}", .{ self.project, tail }) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    params.addOptional("filter", options.filter) catch return error.OutOfMemory;
    params.addOptional("orderBy", options.order_by) catch return error.OutOfMemory;
    params.addNonZero("maxResults", options.max_results) catch return error.OutOfMemory;
    params.addOptional("pageToken", options.page_token) catch return error.OutOfMemory;
    if (options.partial_success) params.add("returnPartialSuccess", "true") catch return error.OutOfMemory;
    return w.written();
}

/// `zones/Z/operations`, `regions/R/operations` or `global/operations`.
fn scopePath(self: *Client, a: Allocator, scope: types.OperationScope) Error![]const u8 {
    return switch (scope) {
        .zone => |z| self.print(a, "zones/{s}/operations", .{z}),
        .region => |r| self.print(a, "regions/{s}/operations", .{r}),
        .global => "global/operations",
    };
}

fn checkZone(self: *Client, zone: []const u8) Error!void {
    if (validate.isZone(zone)) return;
    if (self.diagnostics) |d| d.print("invalid zone: expected a zone id such as us-central1-a", .{});
    return error.InvalidName;
}

fn checkName(self: *Client, name: []const u8, what: []const u8) Error!void {
    if (validate.isName(name)) return;
    if (self.diagnostics) |d| d.print("invalid {s} name: expected a lowercase letter, then up to 62 lowercase letters, digits or -, not ending in -", .{what});
    return error.InvalidName;
}

fn checkScope(self: *Client, scope: types.OperationScope) Error!void {
    switch (scope) {
        .zone => |z| try self.checkZone(z),
        .region => |r| if (!validate.isZone(r)) {
            if (self.diagnostics) |d| d.print("invalid region: expected a region id such as us-central1", .{});
            return error.InvalidName;
        },
        .global => {},
    }
}

fn checkList(self: *Client, options: types.ListOptions) Error!void {
    const d = self.diagnostics;
    if (options.filter) |f| if (!validate.isListExpression(f)) {
        if (d) |x| x.print("invalid filter: expected printable ASCII", .{});
        return error.InvalidOptions;
    };
    if (options.order_by) |o| if (!validate.isListExpression(o)) {
        if (d) |x| x.print("invalid order: expected printable ASCII", .{});
        return error.InvalidOptions;
    };
    if (options.filter != null and options.order_by != null) {
        if (d) |x| x.print("a filter and an order together: Compute refuses them (\"Specifying both a list filter and sort order is not currently supported.\")", .{});
        return error.InvalidOptions;
    }
    if (options.max_results > validate.max_page_size) {
        if (d) |x| x.print("invalid max_results {d}: at most {d}", .{ options.max_results, validate.max_page_size });
        return error.InvalidOptions;
    }
    if (options.page_token) |t| if (!validate.isPageToken(t)) {
        if (d) |x| x.print("invalid page token: expected visible ASCII", .{});
        return error.InvalidName;
    };
}
