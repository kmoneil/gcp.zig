//! A Compute Engine client: the VMs in a zone or every zone, each with its
//! status, scheduling, disks, network and the fingerprints a change must
//! send back; a VM's serial console and guest attributes; the zones,
//! machine types and images a create needs; operations, read and waited
//! on; and the writes that create a VM and run it through its life: start,
//! stop, suspend, resume, reset and delete. Each write has a `*Request`
//! twin that builds the exact request without sending it, and carries a
//! `requestId`, so a retry lands once.
//!
//! Every call blocks the calling task until it completes, using the
//! `std.Io` and allocator passed to `init`. A client must not be used from
//! two tasks at once; give each task its own.

const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const body = @import("body.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const logging = @import("logging.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Diagnostics = core.Diagnostics;
const Error = errors.Error;
const HttpTransport = core.transport.HttpTransport;
const PreparedRequest = core.PreparedRequest;
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
    /// operation, and no write: a client that writes asks for
    /// `.read_write`. A provider made from a key file, workload identity or
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
    /// Every call retries 5xx, 429 and dropped connections, the writes
    /// too: each carries its `requestId`, so a resend lands once.
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
    user_agent: []const u8 = "gcp-zig-compute/0.63",
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
    const answer = try rpc.executeLong(self, result.arena, .{ .method = .POST, .path = path, .body = "" });
    result.value = codec.decodeOperation(result.arena.allocator(), scratch.allocator(), answer) catch |err|
        return rpc.decodeFailed(self, err, "operation");
    return result;
}

// Writes. Each answers its operation as production answered it, not yet
// DONE as a rule (RUNNING, or PENDING: a start answered each when
// measured); `waitOperation` waits for it. A refusal comes one of two
// ways: at once, as the call's error, for what Compute checks before
// acting (a name taken, an unknown machine type or image, a VM under
// deletion protection), or in the operation, which ends DONE with
// `failure` set, for what it finds while acting (no room in the zone:
// `Operation.Failure.stockout()`).

/// How long after a write's first attempt a retry may still begin.
/// Production answered a repeated `requestId` with the same operation,
/// while it ran and after it was DONE (measured); how long it keeps one
/// is not documented, so retries stay well inside an hour.
pub const request_id_window_ms = 10 * std.time.ms_per_min;

/// Creates a VM from `spec` in `zone`. An insert was DONE 9 to 13 s
/// later and the VM RUNNING at once after (measured). A name taken is
/// `error.AlreadyExists` at once, even while the first insert still runs;
/// an unknown machine type is `error.InvalidArgument`, an unknown image or
/// family `error.NotFound`. Takes `compute.instances.create` and a client
/// whose scope is not `.read_only`.
pub fn insertInstance(self: *Client, zone: []const u8, spec: types.InstanceSpec, options: types.WriteOptions) Error!types.Owned(types.Operation) {
    return self.write(insertCall, .{ zone, spec, options });
}

/// Creates a VM from an instance body written by the caller, Compute's
/// `Instance` resource as JSON, for what `InstanceSpec` leaves out
/// (accelerators, local SSDs, more disks or interfaces, confidential
/// computing). It is sent as written; the client checks only that it is
/// a JSON object whose `name` is an instance name. Paths in it are
/// relative to the project (`zones/Z/machineTypes/M`) or full URLs.
pub fn insertInstanceJson(self: *Client, zone: []const u8, instance_json: []const u8, options: types.WriteOptions) Error!types.Owned(types.Operation) {
    return self.write(jsonCall, .{ zone, instance_json, options });
}

/// Creates the VM `name` in `zone` from an instance template, which gives
/// the rest. An unknown template is `error.NotFound`.
pub fn insertFromTemplate(self: *Client, zone: []const u8, name: []const u8, template: types.TemplateRef, options: types.WriteOptions) Error!types.Owned(types.Operation) {
    return self.write(templateCall, .{ zone, name, template, options });
}

/// Starts a stopped VM: DONE 9 to 23 s later (measured). Starting a
/// running VM is no refusal: its operation answered DONE at once.
pub fn startInstance(self: *Client, zone: []const u8, name: []const u8, options: types.WriteOptions) Error!types.Owned(types.Operation) {
    return self.write(startCall, .{ zone, name, options });
}

/// Stops a VM: DONE 52 to 54 s later, the VM then `.terminated`
/// (measured). Stopping a stopped VM is no refusal, an operation like
/// any other.
pub fn stopInstance(self: *Client, zone: []const u8, name: []const u8, options: types.StopOptions) Error!types.Owned(types.Operation) {
    return self.write(stopCall, .{ zone, name, options });
}

/// Suspends a running VM, its memory kept: DONE 87 to 93 s later for a
/// standard VM and 281 s for a spot one, which can be suspended
/// (measured). A suspend can fail in its operation when the guest does
/// not answer: UNSUPPORTED_OPERATION "Instance suspend failed due to
/// guest timeout." after four minutes, the VM still RUNNING (measured
/// once in three runs).
pub fn suspendInstance(self: *Client, zone: []const u8, name: []const u8, options: types.SuspendOptions) Error!types.Owned(types.Operation) {
    return self.write(suspendCall, .{ zone, name, options });
}

/// Resumes a suspended VM: DONE 12 to 19 s later (measured). Resuming a
/// running VM is no refusal: its operation answered DONE at once.
pub fn resumeInstance(self: *Client, zone: []const u8, name: []const u8, options: types.WriteOptions) Error!types.Owned(types.Operation) {
    return self.write(resumeCall, .{ zone, name, options });
}

/// Resets a running VM, as a power cycle would, without a shutdown:
/// DONE 2 s later (measured).
pub fn resetInstance(self: *Client, zone: []const u8, name: []const u8, options: types.WriteOptions) Error!types.Owned(types.Operation) {
    return self.write(resetCall, .{ zone, name, options });
}

/// Deletes a VM, and its boot disk when that auto-deletes: DONE about
/// 50 s later, with `no_graceful_shutdown` (measured). A VM under
/// deletion protection is `error.InvalidArgument` at once, "Invalid
/// resource usage: 'Resource cannot be deleted if it's protected against
/// deletion.'." (measured).
pub fn deleteInstance(self: *Client, zone: []const u8, name: []const u8, options: types.DeleteOptions) Error!types.Owned(types.Operation) {
    return self.write(deleteCall, .{ zone, name, options });
}

/// The request `insertInstance` sends for the same arguments, built
/// without sending it, after the same checks with the same errors: to
/// show before the call, or to record after it. Credentials and other
/// headers are not part of it. With `options.request_id` null each call
/// makes its own id, so the preview and the write would differ in it
/// alone: to send exactly what was shown, make one with `newRequestId`
/// and give it to both.
pub fn insertInstanceRequest(self: *Client, zone: []const u8, spec: types.InstanceSpec, options: types.WriteOptions) Error!types.Owned(PreparedRequest) {
    return self.preview(insertCall, .{ zone, spec, options });
}

/// The request `insertInstanceJson` sends, as `insertInstanceRequest`
/// says.
pub fn insertInstanceJsonRequest(self: *Client, zone: []const u8, instance_json: []const u8, options: types.WriteOptions) Error!types.Owned(PreparedRequest) {
    return self.preview(jsonCall, .{ zone, instance_json, options });
}

/// The request `insertFromTemplate` sends, as `insertInstanceRequest`
/// says.
pub fn insertFromTemplateRequest(self: *Client, zone: []const u8, name: []const u8, template: types.TemplateRef, options: types.WriteOptions) Error!types.Owned(PreparedRequest) {
    return self.preview(templateCall, .{ zone, name, template, options });
}

/// The request `startInstance` sends, as `insertInstanceRequest` says.
pub fn startInstanceRequest(self: *Client, zone: []const u8, name: []const u8, options: types.WriteOptions) Error!types.Owned(PreparedRequest) {
    return self.preview(startCall, .{ zone, name, options });
}

/// The request `stopInstance` sends, as `insertInstanceRequest` says.
pub fn stopInstanceRequest(self: *Client, zone: []const u8, name: []const u8, options: types.StopOptions) Error!types.Owned(PreparedRequest) {
    return self.preview(stopCall, .{ zone, name, options });
}

/// The request `suspendInstance` sends, as `insertInstanceRequest` says.
pub fn suspendInstanceRequest(self: *Client, zone: []const u8, name: []const u8, options: types.SuspendOptions) Error!types.Owned(PreparedRequest) {
    return self.preview(suspendCall, .{ zone, name, options });
}

/// The request `resumeInstance` sends, as `insertInstanceRequest` says.
pub fn resumeInstanceRequest(self: *Client, zone: []const u8, name: []const u8, options: types.WriteOptions) Error!types.Owned(PreparedRequest) {
    return self.preview(resumeCall, .{ zone, name, options });
}

/// The request `resetInstance` sends, as `insertInstanceRequest` says.
pub fn resetInstanceRequest(self: *Client, zone: []const u8, name: []const u8, options: types.WriteOptions) Error!types.Owned(PreparedRequest) {
    return self.preview(resetCall, .{ zone, name, options });
}

/// The request `deleteInstance` sends, as `insertInstanceRequest` says.
pub fn deleteInstanceRequest(self: *Client, zone: []const u8, name: []const u8, options: types.DeleteOptions) Error!types.Owned(PreparedRequest) {
    return self.preview(deleteCall, .{ zone, name, options });
}

// Changes to a live VM. Labels, metadata and tags are each replaced whole,
// under the fingerprint the VM was read with: a VM changed since is
// refused `error.FailedPrecondition` (412 `conditionNotMet`), and so is a
// change with no fingerprint (measured). Such a refusal is never retried:
// read the VM again, and send the change again. `updateLabels` and
// `updateMetadata` do that for a change to some entries.

/// Sets the VM's labels to `labels`, every one: a label left out is
/// removed. `fingerprint` is `Instance.label_fingerprint` as read; a stale
/// one is refused, "Labels fingerprint either invalid or resource labels
/// have changed" (measured). The operation's type is
/// "compute.instance.setLabels".
pub fn setLabels(self: *Client, zone: []const u8, name: []const u8, labels: []const types.Label, fingerprint: []const u8, options: types.WriteOptions) Error!types.Owned(types.Operation) {
    return self.write(labelsCall, .{ zone, name, labels, fingerprint, options });
}

/// Sets the VM's metadata to `items`, every one: an item left out is
/// removed. `fingerprint` is `Instance.metadata.fingerprint` as read; a
/// stale one is refused, "Supplied fingerprint does not match current
/// metadata fingerprint." (measured).
pub fn setMetadata(self: *Client, zone: []const u8, name: []const u8, items: []const types.MetadataItem, fingerprint: []const u8, options: types.WriteOptions) Error!types.Owned(types.Operation) {
    return self.write(metadataCall, .{ zone, name, items, fingerprint, options });
}

/// Sets the VM's network tags to `tags`, every one. `fingerprint` is
/// `Instance.tags.fingerprint` as read; a stale one is refused, "Tags
/// fingerprint either invalid or resource tags have changed." (measured).
pub fn setTags(self: *Client, zone: []const u8, name: []const u8, tags: []const []const u8, fingerprint: []const u8, options: types.WriteOptions) Error!types.Owned(types.Operation) {
    return self.write(tagsCall, .{ zone, name, tags, fingerprint, options });
}

/// Moves a stopped VM to another machine type in its zone. On a running
/// VM the call is taken and its operation ends DONE failed,
/// UNSUPPORTED_OPERATION "Instance is starting or running." (measured):
/// stop it first. A machine type the zone lacks is refused at once,
/// running or not, `error.InvalidArgument` (measured).
pub fn setMachineType(self: *Client, zone: []const u8, name: []const u8, machine_type: []const u8, options: types.WriteOptions) Error!types.Owned(types.Operation) {
    return self.write(machineTypeCall, .{ zone, name, machine_type, options });
}

/// Changes how the VM is scheduled: what `scheduling` gives, the rest
/// kept (measured). A running VM with a run limit refuses every change,
/// `error.InvalidArgument` "Termination time cannot be changed while the
/// instance is running." or "Max run duration cannot be changed while the
/// instance is running." (measured): stop it first. `.spot` is sent as
/// the provisioning model with the `preemptible` that agrees with it:
/// production refused STANDARD alone for a spot VM ("For preemptible, only
/// allowed provisioning_model value is SPOT.") and SPOT alone for a
/// standard one ("preemptible=false and provisioning_model=SPOT is
/// contradicting."), and took each with it, stopped (measured).
pub fn setScheduling(self: *Client, zone: []const u8, name: []const u8, scheduling: types.SchedulingChange, options: types.WriteOptions) Error!types.Owned(types.Operation) {
    return self.write(schedulingCall, .{ zone, name, scheduling, options });
}

/// Turns deletion protection on or off: its operation answered DONE at
/// once, either way (measured).
pub fn setDeletionProtection(self: *Client, zone: []const u8, name: []const u8, protect: bool, options: types.WriteOptions) Error!types.Owned(types.Operation) {
    return self.write(protectionCall, .{ zone, name, protect, options });
}

/// Attaches a disk that exists already, to a running VM too: DONE 3 s
/// later (measured). A disk nobody has is `error.NotFound` at once; one
/// another VM uses, or this one, is taken and its operation ends DONE
/// failed, RESOURCE_IN_USE_BY_ANOTHER_RESOURCE "The disk resource '<d>'
/// is already being used by '<vm>'" (measured).
pub fn attachDisk(self: *Client, zone: []const u8, name: []const u8, disk: types.AttachSpec, options: types.WriteOptions) Error!types.Owned(types.Operation) {
    return self.write(attachCall, .{ zone, name, disk, options });
}

/// Detaches the disk the VM knows as `device_name`
/// (`AttachedDisk.device_name`): DONE 4 s later (measured). A device the
/// VM has none of is taken, and its operation ends DONE failed,
/// INVALID_USAGE "No attached disk found with device name '<d>'"
/// (measured).
pub fn detachDisk(self: *Client, zone: []const u8, name: []const u8, device_name: []const u8, options: types.WriteOptions) Error!types.Owned(types.Operation) {
    return self.write(detachCall, .{ zone, name, device_name, options });
}

/// The request `setLabels` sends, as `insertInstanceRequest` says.
pub fn setLabelsRequest(self: *Client, zone: []const u8, name: []const u8, labels: []const types.Label, fingerprint: []const u8, options: types.WriteOptions) Error!types.Owned(PreparedRequest) {
    return self.preview(labelsCall, .{ zone, name, labels, fingerprint, options });
}

/// The request `setMetadata` sends, as `insertInstanceRequest` says.
pub fn setMetadataRequest(self: *Client, zone: []const u8, name: []const u8, items: []const types.MetadataItem, fingerprint: []const u8, options: types.WriteOptions) Error!types.Owned(PreparedRequest) {
    return self.preview(metadataCall, .{ zone, name, items, fingerprint, options });
}

/// The request `setTags` sends, as `insertInstanceRequest` says.
pub fn setTagsRequest(self: *Client, zone: []const u8, name: []const u8, tags: []const []const u8, fingerprint: []const u8, options: types.WriteOptions) Error!types.Owned(PreparedRequest) {
    return self.preview(tagsCall, .{ zone, name, tags, fingerprint, options });
}

/// The request `setMachineType` sends, as `insertInstanceRequest` says.
pub fn setMachineTypeRequest(self: *Client, zone: []const u8, name: []const u8, machine_type: []const u8, options: types.WriteOptions) Error!types.Owned(PreparedRequest) {
    return self.preview(machineTypeCall, .{ zone, name, machine_type, options });
}

/// The request `setScheduling` sends, as `insertInstanceRequest` says.
pub fn setSchedulingRequest(self: *Client, zone: []const u8, name: []const u8, scheduling: types.SchedulingChange, options: types.WriteOptions) Error!types.Owned(PreparedRequest) {
    return self.preview(schedulingCall, .{ zone, name, scheduling, options });
}

/// The request `setDeletionProtection` sends, as `insertInstanceRequest`
/// says.
pub fn setDeletionProtectionRequest(self: *Client, zone: []const u8, name: []const u8, protect: bool, options: types.WriteOptions) Error!types.Owned(PreparedRequest) {
    return self.preview(protectionCall, .{ zone, name, protect, options });
}

/// The request `attachDisk` sends, as `insertInstanceRequest` says.
pub fn attachDiskRequest(self: *Client, zone: []const u8, name: []const u8, disk: types.AttachSpec, options: types.WriteOptions) Error!types.Owned(PreparedRequest) {
    return self.preview(attachCall, .{ zone, name, disk, options });
}

/// The request `detachDisk` sends, as `insertInstanceRequest` says.
pub fn detachDiskRequest(self: *Client, zone: []const u8, name: []const u8, device_name: []const u8, options: types.WriteOptions) Error!types.Owned(PreparedRequest) {
    return self.preview(detachCall, .{ zone, name, device_name, options });
}

/// Sets some labels and removes others, keeping the rest: reads the VM,
/// sends `setLabels` with the labels changed under the fingerprint just
/// read, and reads and sends again when another change landed in between
/// (412), up to `Options.retry.max_attempts` rounds. Answers the
/// operation of the change that was taken.
pub fn updateLabels(self: *Client, zone: []const u8, name: []const u8, change: types.LabelChange) Error!types.Owned(types.Operation) {
    try self.checkLabelChange(change);
    var round: u32 = 0;
    while (true) {
        round += 1;
        var vm = try self.getInstance(zone, name);
        defer vm.deinit();
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const labels = try mergeLabels(scratch.allocator(), vm.value.labels, change);
        return self.setLabels(zone, name, labels, vm.value.label_fingerprint, .{}) catch |err| {
            if (err != error.FailedPrecondition or round >= self.retry.max_attempts) return err;
            logging.debug("labels of {s} changed under the read; reading again", .{name});
            continue;
        };
    }
}

/// Sets some metadata items and removes others, keeping the rest, as
/// `updateLabels` does labels.
pub fn updateMetadata(self: *Client, zone: []const u8, name: []const u8, change: types.MetadataChange) Error!types.Owned(types.Operation) {
    try self.checkMetadataChange(change);
    var round: u32 = 0;
    while (true) {
        round += 1;
        var vm = try self.getInstance(zone, name);
        defer vm.deinit();
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const items = try mergeMetadata(scratch.allocator(), vm.value.metadata.items, change);
        return self.setMetadata(zone, name, items, vm.value.metadata.fingerprint, .{}) catch |err| {
            if (err != error.FailedPrecondition or round >= self.retry.max_attempts) return err;
            logging.debug("metadata of {s} changed under the read; reading again", .{name});
            continue;
        };
    }
}

/// `current` with `change` made: a label set keeps its place, a new one
/// goes last, a removed one goes.
fn mergeLabels(a: Allocator, current: []const types.Label, change: types.LabelChange) Allocator.Error![]const types.Label {
    var out: std.ArrayList(types.Label) = .empty;
    for (current) |l| {
        if (listed(change.remove, l.key)) continue;
        try out.append(a, labelIn(change.set, l.key) orelse l);
    }
    for (change.set) |l| if (labelIn(current, l.key) == null) try out.append(a, l);
    return out.items;
}

fn mergeMetadata(a: Allocator, current: []const types.MetadataItem, change: types.MetadataChange) Allocator.Error![]const types.MetadataItem {
    var out: std.ArrayList(types.MetadataItem) = .empty;
    for (current) |m| {
        if (listed(change.remove, m.key)) continue;
        try out.append(a, itemIn(change.set, m.key) orelse m);
    }
    for (change.set) |m| if (itemIn(current, m.key) == null) try out.append(a, m);
    return out.items;
}

fn listed(keys: []const []const u8, key: []const u8) bool {
    for (keys) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

fn labelIn(list: []const types.Label, key: []const u8) ?types.Label {
    for (list) |l| if (std.mem.eql(u8, l.key, key)) return l;
    return null;
}

fn itemIn(list: []const types.MetadataItem, key: []const u8) ?types.MetadataItem {
    for (list) |m| if (std.mem.eql(u8, m.key, key)) return m;
    return null;
}

fn checkLabelChange(self: *Client, change: types.LabelChange) Error!void {
    try self.checkLabels(change.set);
    for (change.remove) |k| {
        if (validate.isLabelText(k, true) and labelIn(change.set, k) == null) continue;
        if (self.diagnostics) |d| d.print("invalid label change: a key to remove is a label key, and not one also set", .{});
        return error.InvalidOptions;
    }
}

fn checkMetadataChange(self: *Client, change: types.MetadataChange) Error!void {
    try self.checkMetadata(change.set);
    for (change.remove) |k| {
        if (validate.isMetadataKey(k) and itemIn(change.set, k) == null) continue;
        if (self.diagnostics) |d| d.print("invalid metadata change: a key to remove is a metadata key, and not one also set", .{});
        return error.InvalidOptions;
    }
}

/// A request id as the writes make one: a random UUID (version 4),
/// written into `buf`.
pub fn newRequestId(self: *Client, buf: *[36]u8) []const u8 {
    var bytes: [16]u8 = undefined;
    self.io.random(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return std.fmt.bufPrint(buf, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] }) catch unreachable;
}

/// Sends the call `build` makes and decodes the operation it answers.
fn write(self: *Client, comptime build: anytype, args: anytype) Error!types.Owned(types.Operation) {
    rpc.begin(self);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var call: rpc.Call = try @call(.auto, build, .{ self, a } ++ args);
    call.retry_window_ms = request_id_window_ms;
    var result: types.Owned(types.Operation) = try .init(self.gpa);
    errdefer result.deinit();
    const answer = try rpc.execute(self, result.arena, call);
    result.value = codec.decodeOperation(result.arena.allocator(), a, answer) catch |err|
        return rpc.decodeFailed(self, err, "operation");
    return result;
}

/// The request the call `build` makes, unsent.
fn preview(self: *Client, comptime build: anytype, args: anytype) Error!types.Owned(PreparedRequest) {
    rpc.begin(self);
    var result: types.Owned(PreparedRequest) = try .init(self.gpa);
    errdefer result.deinit();
    const a = result.arena.allocator();
    result.value = try .fromCall(a, self.base_url, try @call(.auto, build, .{ self, a } ++ args));
    return result;
}

/// `POST .../zones/Z/instances` with the spec written as an instance.
fn insertCall(self: *Client, a: Allocator, zone: []const u8, spec: types.InstanceSpec, options: types.WriteOptions) Error!rpc.Call {
    try self.checkWrite();
    try self.checkZone(zone);
    try self.checkSpec(spec);
    const path = try self.writePath(a, zone, null, &.{}, options.request_id);
    return .{ .method = .POST, .path = path, .body = try body.instance(a, zone, spec) };
}

fn jsonCall(self: *Client, a: Allocator, zone: []const u8, instance_json: []const u8, options: types.WriteOptions) Error!rpc.Call {
    try self.checkWrite();
    try self.checkZone(zone);
    try self.checkInstanceJson(a, instance_json);
    const path = try self.writePath(a, zone, null, &.{}, options.request_id);
    return .{ .method = .POST, .path = path, .body = instance_json };
}

/// `POST .../zones/Z/instances?sourceInstanceTemplate=T` with the name
/// alone.
fn templateCall(self: *Client, a: Allocator, zone: []const u8, name: []const u8, template: types.TemplateRef, options: types.WriteOptions) Error!rpc.Call {
    try self.checkWrite();
    try self.checkZone(zone);
    try self.checkName(name, "instance");
    try self.checkTemplate(template);
    const source = try body.templatePath(a, self.project, template);
    const path = try self.writePath(a, zone, null, &.{.{ .name = "sourceInstanceTemplate", .value = source }}, options.request_id);
    return .{ .method = .POST, .path = path, .body = try body.nameOnly(a, name) };
}

fn startCall(self: *Client, a: Allocator, zone: []const u8, name: []const u8, options: types.WriteOptions) Error!rpc.Call {
    return self.verbCall(a, zone, name, .{ .name = "start" }, options.request_id);
}

fn stopCall(self: *Client, a: Allocator, zone: []const u8, name: []const u8, options: types.StopOptions) Error!rpc.Call {
    var flags: std.ArrayList(Flag) = .empty;
    if (options.discard_local_ssd) |d| try flags.append(a, .{ .name = "discardLocalSsd", .value = if (d) "true" else "false" });
    if (options.no_graceful_shutdown) try flags.append(a, .{ .name = "noGracefulShutdown", .value = "true" });
    return self.verbCall(a, zone, name, .{ .name = "stop", .flags = flags.items }, options.request_id);
}

fn suspendCall(self: *Client, a: Allocator, zone: []const u8, name: []const u8, options: types.SuspendOptions) Error!rpc.Call {
    var flags: std.ArrayList(Flag) = .empty;
    if (options.discard_local_ssd) |d| try flags.append(a, .{ .name = "discardLocalSsd", .value = if (d) "true" else "false" });
    return self.verbCall(a, zone, name, .{ .name = "suspend", .flags = flags.items }, options.request_id);
}

fn resumeCall(self: *Client, a: Allocator, zone: []const u8, name: []const u8, options: types.WriteOptions) Error!rpc.Call {
    return self.verbCall(a, zone, name, .{ .name = "resume" }, options.request_id);
}

fn resetCall(self: *Client, a: Allocator, zone: []const u8, name: []const u8, options: types.WriteOptions) Error!rpc.Call {
    return self.verbCall(a, zone, name, .{ .name = "reset" }, options.request_id);
}

fn labelsCall(self: *Client, a: Allocator, zone: []const u8, name: []const u8, labels: []const types.Label, fingerprint: []const u8, options: types.WriteOptions) Error!rpc.Call {
    try self.checkLabels(labels);
    try self.checkFingerprint(fingerprint, "label_fingerprint");
    return self.verbCall(a, zone, name, .{ .name = "setLabels", .body = try body.labels(a, labels, fingerprint) }, options.request_id);
}

fn metadataCall(self: *Client, a: Allocator, zone: []const u8, name: []const u8, items: []const types.MetadataItem, fingerprint: []const u8, options: types.WriteOptions) Error!rpc.Call {
    try self.checkMetadata(items);
    try self.checkFingerprint(fingerprint, "metadata.fingerprint");
    return self.verbCall(a, zone, name, .{ .name = "setMetadata", .body = try body.metadata(a, items, fingerprint) }, options.request_id);
}

fn tagsCall(self: *Client, a: Allocator, zone: []const u8, name: []const u8, tags: []const []const u8, fingerprint: []const u8, options: types.WriteOptions) Error!rpc.Call {
    for (tags) |t| try self.checkName(t, "network tag");
    try self.checkFingerprint(fingerprint, "tags.fingerprint");
    return self.verbCall(a, zone, name, .{ .name = "setTags", .body = try body.tags(a, tags, fingerprint) }, options.request_id);
}

fn machineTypeCall(self: *Client, a: Allocator, zone: []const u8, name: []const u8, machine_type: []const u8, options: types.WriteOptions) Error!rpc.Call {
    try self.checkName(machine_type, "machine type");
    return self.verbCall(a, zone, name, .{ .name = "setMachineType", .body = try body.machineType(a, zone, machine_type) }, options.request_id);
}

fn schedulingCall(self: *Client, a: Allocator, zone: []const u8, name: []const u8, scheduling: types.SchedulingChange, options: types.WriteOptions) Error!rpc.Call {
    try self.checkSchedulingChange(scheduling);
    return self.verbCall(a, zone, name, .{ .name = "setScheduling", .body = try body.scheduling(a, scheduling) }, options.request_id);
}

fn protectionCall(self: *Client, a: Allocator, zone: []const u8, name: []const u8, protect: bool, options: types.WriteOptions) Error!rpc.Call {
    const flags: []const Flag = &.{.{ .name = "deletionProtection", .value = if (protect) "true" else "false" }};
    return self.verbCall(a, zone, name, .{ .name = "setDeletionProtection", .flags = flags }, options.request_id);
}

fn attachCall(self: *Client, a: Allocator, zone: []const u8, name: []const u8, disk: types.AttachSpec, options: types.WriteOptions) Error!rpc.Call {
    try self.checkReference(disk.disk, "disk");
    if (disk.device_name) |d| try self.checkDeviceName(d);
    const flags: []const Flag = if (disk.force) &.{.{ .name = "forceAttach", .value = "true" }} else &.{};
    return self.verbCall(a, zone, name, .{ .name = "attachDisk", .flags = flags, .body = try body.attach(a, zone, disk) }, options.request_id);
}

fn detachCall(self: *Client, a: Allocator, zone: []const u8, name: []const u8, device_name: []const u8, options: types.WriteOptions) Error!rpc.Call {
    try self.checkDeviceName(device_name);
    return self.verbCall(a, zone, name, .{ .name = "detachDisk", .flags = &.{.{ .name = "deviceName", .value = device_name }} }, options.request_id);
}

/// `DELETE .../zones/Z/instances/N`.
fn deleteCall(self: *Client, a: Allocator, zone: []const u8, name: []const u8, options: types.DeleteOptions) Error!rpc.Call {
    try self.checkWrite();
    try self.checkZone(zone);
    try self.checkName(name, "instance");
    const flags: []const Flag = if (options.no_graceful_shutdown) &.{.{ .name = "noGracefulShutdown", .value = "true" }} else &.{};
    return .{ .method = .DELETE, .path = try self.writePath(a, zone, name, flags, options.request_id) };
}

/// `POST .../zones/Z/instances/N/<verb>?<flags>` with the verb's body,
/// none for most.
fn verbCall(self: *Client, a: Allocator, zone: []const u8, name: []const u8, verb: Verb, request_id: ?[]const u8) Error!rpc.Call {
    try self.checkWrite();
    try self.checkZone(zone);
    try self.checkName(name, "instance");
    const path = try self.writePath(a, zone, try std.fmt.allocPrint(a, "{s}/{s}", .{ name, verb.name }), verb.flags, request_id);
    return .{ .method = .POST, .path = path, .body = verb.body };
}

const Verb = struct { name: []const u8, flags: []const Flag = &.{}, body: []const u8 = "" };

const Flag = struct { name: []const u8, value: []const u8 };

/// `/compute/v1/projects/P/zones/Z/instances[/<tail>]?<flags>&requestId=<id>`,
/// the id `request_id` or a new one.
fn writePath(self: *Client, a: Allocator, zone: []const u8, tail: ?[]const u8, flags: []const Flag, request_id: ?[]const u8) Error![]const u8 {
    const rest = if (tail) |t| try self.print(a, "zones/{s}/instances/{s}", .{ zone, t }) else try self.print(a, "zones/{s}/instances", .{zone});
    return self.requestPath(a, rest, flags, request_id);
}

/// `/compute/v1/projects/P/<rest>?<flags>&requestId=<id>`, the id
/// `request_id` or a new one.
fn requestPath(self: *Client, a: Allocator, rest: []const u8, flags: []const Flag, request_id: ?[]const u8) Error![]const u8 {
    const id = try self.requestIdFor(a, request_id);
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.print("/compute/v1/projects/{s}/{s}", .{ self.project, rest }) catch return error.OutOfMemory;
    var params: core.query.Params = .init(&w.writer);
    for (flags) |f| params.add(f.name, f.value) catch return error.OutOfMemory;
    params.add("requestId", id) catch return error.OutOfMemory;
    return w.written();
}

// Fleets: instance templates and zonal managed instance groups. A group's
// operations are DONE well before its VMs are: an insert in 7 s while
// they were made, RUNNING 30 s later; a resize in 1 s while the VM it
// dropped took 37 s more to go (measured). `waitGroupStable` waits for
// the VMs.

/// One page of the project's global templates (`region` null), or a
/// region's.
pub fn listTemplates(self: *Client, region: ?[]const u8, options: types.ListOptions) Error!types.Owned(types.TemplatePage) {
    rpc.begin(self);
    if (region) |r| try self.checkScope(.{ .region = r });
    try self.checkList(options);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const tail = if (region) |r| try self.print(a, "regions/{s}/instanceTemplates", .{r}) else "global/instanceTemplates";
    return self.read(types.TemplatePage, try self.listPath(a, tail, options), codec.decodeTemplatePage, "template list");
}

/// One template. `error.NotFound` when there is none of that name.
pub fn getTemplate(self: *Client, ref: types.TemplateRef) Error!types.Owned(types.Template) {
    rpc.begin(self);
    try self.checkTemplate(ref);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    return self.read(types.Template, try self.print(a, "/compute/v1/{s}", .{try body.templatePath(a, self.project, ref)}), codec.decodeTemplate, "template");
}

/// Makes the template `spec.name`, global (`region` null) or in a region,
/// its VMs as `spec` describes. A name taken is `error.AlreadyExists`
/// (measured). A group refuses a template whose spot VMs DELETE or have a
/// run limit, in its insert's operation (measured): give a group's
/// template `.termination_action = .stop` and no run limit.
pub fn insertTemplate(self: *Client, region: ?[]const u8, spec: types.InstanceSpec, options: types.WriteOptions) Error!types.Owned(types.Operation) {
    return self.write(insertTemplateCall, .{ region, spec, options });
}

/// Deletes a template. One a group uses is taken, and its operation ends
/// DONE failed, RESOURCE_IN_USE_BY_ANOTHER_RESOURCE (measured).
pub fn deleteTemplate(self: *Client, ref: types.TemplateRef, options: types.WriteOptions) Error!types.Owned(types.Operation) {
    return self.write(deleteTemplateCall, .{ ref, options });
}

/// One page of a zone's managed instance groups.
pub fn listGroups(self: *Client, zone: []const u8, options: types.ListOptions) Error!types.Owned(types.GroupPage) {
    rpc.begin(self);
    try self.checkZone(zone);
    try self.checkList(options);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try self.listPath(a, try self.print(a, "zones/{s}/instanceGroupManagers", .{zone}), options);
    return self.read(types.GroupPage, path, codec.decodeGroupPage, "group list");
}

/// One group, with its target size, what its VMs are doing, and whether
/// it is stable.
pub fn getGroup(self: *Client, zone: []const u8, name: []const u8) Error!types.Owned(types.Group) {
    rpc.begin(self);
    try self.checkZone(zone);
    try self.checkName(name, "group");
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const path = try self.print(scratch.allocator(), "/compute/v1/projects/{s}/zones/{s}/instanceGroupManagers/{s}", .{ self.project, zone, name });
    return self.read(types.Group, path, codec.decodeGroup, "group");
}

/// One page of a group's VMs, each with its status and what the group is
/// doing to it. A POST, as the API has it, retried as the reads are.
pub fn listManagedInstances(self: *Client, zone: []const u8, name: []const u8, options: types.ListOptions) Error!types.Owned(types.ManagedInstancePage) {
    rpc.begin(self);
    try self.checkZone(zone);
    try self.checkName(name, "group");
    try self.checkList(options);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try self.listPath(a, try self.print(a, "zones/{s}/instanceGroupManagers/{s}/listManagedInstances", .{ zone, name }), options);
    var result: types.Owned(types.ManagedInstancePage) = try .init(self.gpa);
    errdefer result.deinit();
    const answer = try rpc.execute(self, result.arena, .{ .method = .POST, .path = path, .body = "" });
    result.value = codec.decodeManagedInstancePage(result.arena.allocator(), a, answer) catch |err|
        return rpc.decodeFailed(self, err, "managed instance list");
    return result;
}

/// Makes a group of `spec.target_size` VMs from a template. Its operation
/// was DONE in 7 s, its VMs RUNNING 30 s later (measured): wait with
/// `waitGroupStable`. A template whose spot VMs DELETE, or have a run
/// limit, is taken and the operation ends DONE failed,
/// UNSUPPORTED_OPERATION "Spot virtual machines with termination action
/// set to DELETE cannot be used with Managed Instance Groups." (measured).
pub fn insertGroup(self: *Client, zone: []const u8, spec: types.GroupSpec, options: types.WriteOptions) Error!types.Owned(types.Operation) {
    return self.write(insertGroupCall, .{ zone, spec, options });
}

/// Sets how many VMs the group keeps, making or deleting the difference.
pub fn resizeGroup(self: *Client, zone: []const u8, name: []const u8, size: u32, options: types.WriteOptions) Error!types.Owned(types.Operation) {
    return self.write(resizeGroupCall, .{ zone, name, size, options });
}

/// Makes VMs in the group by name, its target size growing with them
/// (measured).
pub fn createGroupInstances(self: *Client, zone: []const u8, name: []const u8, names: []const []const u8, options: types.WriteOptions) Error!types.Owned(types.Operation) {
    return self.write(createInstancesCall, .{ zone, name, names, options });
}

/// Deletes VMs of the group by name, its target size shrinking with them
/// (measured).
pub fn deleteGroupInstances(self: *Client, zone: []const u8, name: []const u8, names: []const []const u8, options: types.GroupDeleteOptions) Error!types.Owned(types.Operation) {
    return self.write(deleteInstancesCall, .{ zone, name, names, options });
}

/// Deletes the group and its VMs: DONE 80 s later (measured).
pub fn deleteGroup(self: *Client, zone: []const u8, name: []const u8, options: types.GroupDeleteOptions) Error!types.Owned(types.Operation) {
    return self.write(deleteGroupCall, .{ zone, name, options });
}

/// Reads the group every `options.poll_ms` until it is stable (every VM
/// there and doing nothing, as many as its target) or `options.timeout_ms`
/// has passed, and answers it as it stands then.
pub fn waitGroupStable(self: *Client, zone: []const u8, name: []const u8, options: types.GroupWaitOptions) Error!types.Owned(types.Group) {
    const clock: std.Io.Clock = .awake;
    const deadline = clock.now(self.io).addDuration(.fromMilliseconds(options.timeout_ms));
    var reads: u32 = 0;
    while (true) {
        var group = try self.getGroup(zone, name);
        reads += 1;
        const now = clock.now(self.io);
        const left = now.durationTo(deadline).toMilliseconds();
        if (group.value.is_stable or left <= 0) {
            logging.debug("group {s}: stable {} after {d} read(s)", .{ name, group.value.is_stable, reads });
            return group;
        }
        group.deinit();
        self.io.sleep(.fromMilliseconds(@min(options.poll_ms, left)), .awake) catch return error.Canceled;
    }
}

/// The request `insertTemplate` sends, as `insertInstanceRequest` says.
pub fn insertTemplateRequest(self: *Client, region: ?[]const u8, spec: types.InstanceSpec, options: types.WriteOptions) Error!types.Owned(PreparedRequest) {
    return self.preview(insertTemplateCall, .{ region, spec, options });
}

/// The request `deleteTemplate` sends, as `insertInstanceRequest` says.
pub fn deleteTemplateRequest(self: *Client, ref: types.TemplateRef, options: types.WriteOptions) Error!types.Owned(PreparedRequest) {
    return self.preview(deleteTemplateCall, .{ ref, options });
}

/// The request `insertGroup` sends, as `insertInstanceRequest` says.
pub fn insertGroupRequest(self: *Client, zone: []const u8, spec: types.GroupSpec, options: types.WriteOptions) Error!types.Owned(PreparedRequest) {
    return self.preview(insertGroupCall, .{ zone, spec, options });
}

/// The request `resizeGroup` sends, as `insertInstanceRequest` says.
pub fn resizeGroupRequest(self: *Client, zone: []const u8, name: []const u8, size: u32, options: types.WriteOptions) Error!types.Owned(PreparedRequest) {
    return self.preview(resizeGroupCall, .{ zone, name, size, options });
}

/// The request `createGroupInstances` sends, as `insertInstanceRequest`
/// says.
pub fn createGroupInstancesRequest(self: *Client, zone: []const u8, name: []const u8, names: []const []const u8, options: types.WriteOptions) Error!types.Owned(PreparedRequest) {
    return self.preview(createInstancesCall, .{ zone, name, names, options });
}

/// The request `deleteGroupInstances` sends, as `insertInstanceRequest`
/// says.
pub fn deleteGroupInstancesRequest(self: *Client, zone: []const u8, name: []const u8, names: []const []const u8, options: types.GroupDeleteOptions) Error!types.Owned(PreparedRequest) {
    return self.preview(deleteInstancesCall, .{ zone, name, names, options });
}

/// The request `deleteGroup` sends, as `insertInstanceRequest` says.
pub fn deleteGroupRequest(self: *Client, zone: []const u8, name: []const u8, options: types.GroupDeleteOptions) Error!types.Owned(PreparedRequest) {
    return self.preview(deleteGroupCall, .{ zone, name, options });
}

fn insertTemplateCall(self: *Client, a: Allocator, region: ?[]const u8, spec: types.InstanceSpec, options: types.WriteOptions) Error!rpc.Call {
    try self.checkWrite();
    if (region) |r| try self.checkScope(.{ .region = r });
    try self.checkSpec(spec);
    if (region == null) if (spec.subnetwork) |s| if (std.mem.indexOfScalar(u8, s, '/') == null) {
        if (self.diagnostics) |d| d.print("invalid subnetwork: a global template names one by its path, regions/R/subnetworks/S", .{});
        return error.InvalidOptions;
    };
    const tail = if (region) |r| try self.print(a, "regions/{s}/instanceTemplates", .{r}) else "global/instanceTemplates";
    return .{ .method = .POST, .path = try self.requestPath(a, tail, &.{}, options.request_id), .body = try body.template(a, region, spec) };
}

fn deleteTemplateCall(self: *Client, a: Allocator, ref: types.TemplateRef, options: types.WriteOptions) Error!rpc.Call {
    try self.checkWrite();
    try self.checkTemplate(ref);
    const full = try body.templatePath(a, self.project, ref);
    const rest = full["projects/".len + self.project.len + 1 ..];
    return .{ .method = .DELETE, .path = try self.requestPath(a, rest, &.{}, options.request_id) };
}

fn insertGroupCall(self: *Client, a: Allocator, zone: []const u8, spec: types.GroupSpec, options: types.WriteOptions) Error!rpc.Call {
    try self.checkWrite();
    try self.checkZone(zone);
    try self.checkName(spec.name, "group");
    if (spec.base_instance_name) |b| try self.checkName(b, "base instance");
    try self.checkTemplate(spec.template);
    if (spec.description) |d| if (!std.unicode.utf8ValidateSlice(d) or d.len > 2048) {
        if (self.diagnostics) |x| x.print("invalid description: expected UTF-8, at most 2048 bytes", .{});
        return error.InvalidOptions;
    };
    const path = try self.requestPath(a, try self.print(a, "zones/{s}/instanceGroupManagers", .{zone}), &.{}, options.request_id);
    return .{ .method = .POST, .path = path, .body = try body.group(a, self.project, spec) };
}

fn resizeGroupCall(self: *Client, a: Allocator, zone: []const u8, name: []const u8, size: u32, options: types.WriteOptions) Error!rpc.Call {
    const size_text = try self.print(a, "{d}", .{size});
    return self.groupVerbCall(a, zone, name, "resize", &.{.{ .name = "size", .value = size_text }}, "", options.request_id);
}

fn createInstancesCall(self: *Client, a: Allocator, zone: []const u8, name: []const u8, names: []const []const u8, options: types.WriteOptions) Error!rpc.Call {
    try self.checkInstanceNames(names);
    return self.groupVerbCall(a, zone, name, "createInstances", &.{}, try body.createInstances(a, names), options.request_id);
}

fn deleteInstancesCall(self: *Client, a: Allocator, zone: []const u8, name: []const u8, names: []const []const u8, options: types.GroupDeleteOptions) Error!rpc.Call {
    try self.checkInstanceNames(names);
    const flags: []const Flag = if (options.no_graceful_shutdown) &.{.{ .name = "noGracefulShutdown", .value = "true" }} else &.{};
    return self.groupVerbCall(a, zone, name, "deleteInstances", flags, try body.deleteInstances(a, zone, names), options.request_id);
}

fn deleteGroupCall(self: *Client, a: Allocator, zone: []const u8, name: []const u8, options: types.GroupDeleteOptions) Error!rpc.Call {
    try self.checkWrite();
    try self.checkZone(zone);
    try self.checkName(name, "group");
    const flags: []const Flag = if (options.no_graceful_shutdown) &.{.{ .name = "noGracefulShutdown", .value = "true" }} else &.{};
    const path = try self.requestPath(a, try self.print(a, "zones/{s}/instanceGroupManagers/{s}", .{ zone, name }), flags, options.request_id);
    return .{ .method = .DELETE, .path = path };
}

/// `POST .../zones/Z/instanceGroupManagers/G/<verb>?<flags>` with `text`.
fn groupVerbCall(self: *Client, a: Allocator, zone: []const u8, name: []const u8, verb: []const u8, flags: []const Flag, text: []const u8, request_id: ?[]const u8) Error!rpc.Call {
    try self.checkWrite();
    try self.checkZone(zone);
    try self.checkName(name, "group");
    const path = try self.requestPath(a, try self.print(a, "zones/{s}/instanceGroupManagers/{s}/{s}", .{ zone, name, verb }), flags, request_id);
    return .{ .method = .POST, .path = path, .body = text };
}

/// At least one VM, each by an instance name: production refused an
/// empty one, "The URL is malformed." (measured).
fn checkInstanceNames(self: *Client, names: []const []const u8) Error!void {
    if (names.len == 0) {
        if (self.diagnostics) |d| d.print("invalid instances: name at least one", .{});
        return error.InvalidOptions;
    }
    for (names) |n| try self.checkName(n, "instance");
}

fn requestIdFor(self: *Client, a: Allocator, given: ?[]const u8) Error![]const u8 {
    if (given) |id| {
        if (validate.isRequestId(id)) return id;
        if (self.diagnostics) |d| d.print("invalid request id: expected a UUID such as 8068f1b8-03fc-4f7f-a5bd-d5e775aa7212, not all zeros", .{});
        return error.InvalidOptions;
    }
    return self.newRequestId(try a.create([36]u8));
}

fn checkFingerprint(self: *Client, fingerprint: []const u8, field: []const u8) Error!void {
    if (validate.isFingerprint(fingerprint)) return;
    if (self.diagnostics) |d| d.print("invalid fingerprint: expected Instance.{s} as the VM was read; production refuses a change with none as one with a stale one (412)", .{field});
    return error.InvalidOptions;
}

fn checkDeviceName(self: *Client, device_name: []const u8) Error!void {
    if (validate.isDeviceName(device_name)) return;
    if (self.diagnostics) |d| d.print("invalid device name: expected 1 to 63 letters, digits, - and _, as AttachedDisk.device_name reads", .{});
    return error.InvalidName;
}

fn checkSchedulingChange(self: *Client, change: types.SchedulingChange) Error!void {
    const d = self.diagnostics;
    if (std.meta.eql(change, types.SchedulingChange{})) {
        if (d) |x| x.print("invalid scheduling change: it changes nothing; give at least one field", .{});
        return error.InvalidOptions;
    }
    const spot = change.spot == true;
    if (spot and change.automatic_restart == true) {
        if (d) |x| x.print("invalid scheduling: a spot VM cannot restart on its own (\"Preemptible instances cannot be automatically restarted.\")", .{});
        return error.InvalidOptions;
    }
    if (spot and change.on_host_maintenance == .migrate) {
        if (d) |x| x.print("invalid scheduling: a spot VM's host maintenance is TERMINATE, the only one it takes", .{});
        return error.InvalidOptions;
    }
    if (change.termination_action == .unknown or change.max_run_duration_s == 0) {
        if (d) |x| x.print("invalid scheduling: a termination action is .stop or .delete, and a run limit at least a second", .{});
        return error.InvalidOptions;
    }
}

/// A write needs a scope that takes one: `compute.readonly` takes none.
fn checkWrite(self: *Client) Error!void {
    if (self.scope != .read_only) return;
    if (self.diagnostics) |d| d.print("this client asks for compute.readonly, which takes no write; give Options.scope .read_write", .{});
    return error.InvalidOptions;
}

fn checkSpec(self: *Client, spec: types.InstanceSpec) Error!void {
    try self.checkName(spec.name, "instance");
    try self.checkName(spec.machine_type, "machine type");
    try self.checkImage(spec.image);
    try self.checkBootDisk(spec.boot_disk);
    try self.checkScheduling(spec);
    try self.checkMetadata(spec.metadata);
    try self.checkLabels(spec.labels);
    for (spec.tags) |t| try self.checkName(t, "network tag");
    if (spec.service_account) |account| try self.checkAccount(account);
    try self.checkReference(spec.network, "network");
    if (spec.subnetwork) |s| try self.checkReference(s, "subnetwork");
    if (spec.description) |d| if (!std.unicode.utf8ValidateSlice(d) or d.len > 2048) {
        if (self.diagnostics) |x| x.print("invalid description: expected UTF-8, at most 2048 bytes", .{});
        return error.InvalidOptions;
    };
}

fn checkImage(self: *Client, ref: types.ImageRef) Error!void {
    switch (ref) {
        .family, .image => |named| {
            if (!validate.isProject(named.project)) {
                if (self.diagnostics) |d| d.print("invalid image project: expected a project id, such as debian-cloud", .{});
                return error.InvalidName;
            }
            try self.checkName(named.name, if (ref == .family) "image family" else "image");
        },
        .path => |p| try self.checkReference(p, "image path"),
    }
}

fn checkBootDisk(self: *Client, disk: types.BootDisk) Error!void {
    if (disk.size_gb) |gb| if (gb < validate.min_disk_gb) {
        if (self.diagnostics) |d| d.print("invalid boot disk size {d} GB: Compute makes none under {d}", .{ gb, validate.min_disk_gb });
        return error.InvalidOptions;
    };
    if (disk.type) |t| try self.checkReference(t, "disk type");
}

fn checkScheduling(self: *Client, spec: types.InstanceSpec) Error!void {
    const d = self.diagnostics;
    if (spec.spot and spec.automatic_restart == true) {
        if (d) |x| x.print("invalid scheduling: a spot VM cannot restart on its own (\"Preemptible instances cannot be automatically restarted.\")", .{});
        return error.InvalidOptions;
    }
    if (spec.termination_action == .unknown) {
        if (d) |x| x.print("invalid termination action: .unknown is what a read answers for one this library does not know; give .stop or .delete", .{});
        return error.InvalidOptions;
    }
    if (spec.max_run_duration_s == 0) {
        if (d) |x| x.print("invalid run limit: 0 s; give null for none", .{});
        return error.InvalidOptions;
    }
}

fn checkMetadata(self: *Client, items: []const types.MetadataItem) Error!void {
    for (items) |m| {
        if (!validate.isMetadataKey(m.key)) {
            if (self.diagnostics) |d| d.print("invalid metadata key: expected letters, digits, - and _, under 128 bytes", .{});
            return error.InvalidOptions;
        }
        const v = m.value orelse continue;
        if (v.len > validate.max_metadata_value or !std.unicode.utf8ValidateSlice(v)) {
            if (self.diagnostics) |d| d.print("invalid metadata value: expected UTF-8, at most 256 KiB", .{});
            return error.InvalidOptions;
        }
    }
}

fn checkLabels(self: *Client, labels: []const types.Label) Error!void {
    if (labels.len > 64) {
        if (self.diagnostics) |d| d.print("invalid labels: a VM takes at most 64", .{});
        return error.InvalidOptions;
    }
    for (labels) |l| if (!validate.isLabelText(l.key, true) or !validate.isLabelText(l.value, false)) {
        if (self.diagnostics) |d| d.print("invalid label: a key starts with a lowercase letter; keys and values are lowercase letters, digits, _ and -, at most 63 characters", .{});
        return error.InvalidOptions;
    };
}

fn checkAccount(self: *Client, account: types.ServiceAccount) Error!void {
    try self.checkReference(account.email, "service account email");
    for (account.scopes) |s| try self.checkReference(s, "service account scope");
}

/// A path, URL or email a body carries: visible ASCII.
fn checkReference(self: *Client, text: []const u8, what: []const u8) Error!void {
    if (validate.isReference(text)) return;
    if (self.diagnostics) |d| d.print("invalid {s}: expected a name, path or URL, visible ASCII", .{what});
    return error.InvalidOptions;
}

fn checkTemplate(self: *Client, ref: types.TemplateRef) Error!void {
    switch (ref) {
        .global => |name| try self.checkName(name, "instance template"),
        .regional => |r| {
            try self.checkScope(.{ .region = r.region });
            try self.checkName(r.name, "instance template");
        },
    }
}

/// A JSON object whose `name` is an instance name.
fn checkInstanceJson(self: *Client, a: Allocator, text: []const u8) Error!void {
    const d = self.diagnostics;
    const value = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (d) |x| x.print("invalid instance body: expected a JSON object", .{});
            return error.InvalidOptions;
        },
    };
    if (value != .object) {
        if (d) |x| x.print("invalid instance body: expected a JSON object", .{});
        return error.InvalidOptions;
    }
    const name = value.object.get("name") orelse .null;
    if (name != .string) {
        if (d) |x| x.print("invalid instance body: it needs a name", .{});
        return error.InvalidName;
    }
    try self.checkName(name.string, "instance");
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
    const answer = try rpc.execute(self, result.arena, .{ .method = .GET, .path = path });
    result.value = decode(result.arena.allocator(), scratch.allocator(), answer) catch |err|
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
