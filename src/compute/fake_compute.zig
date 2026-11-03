//! Compute Engine in memory, for tests of code that reads VMs and waits on
//! operations: behind `Client.Options.transport`, it answers the module's
//! calls as production answered them when measured on 2026-11-03 (issue
//! #346, milestone 0).
//!
//! - Zones are the fake's options' (us-central1-a, -b and -c by default)
//!   and `putZone`'s. A path under any other zone is 400 "Invalid value
//!   for field 'zone': '<z>'. Unknown zone."
//! - VMs, machine types, images, guest attributes, serial output and
//!   operations are put in by the test: `putInstance`, `setStatus`,
//!   `putMachineType`, `putImage`, `putGuestAttribute`, `appendSerial`
//!   and `putOperation` stand in for whoever created them and for the
//!   VMs themselves. Nothing moves on its own.
//! - Lists sort by name and page by `maxResults` (500 by default, as
//!   production's); `orderBy=creationTimestamp desc` puts the newest
//!   first. A filter and an order together are refused, as production
//!   refused them; an order other than those two is refused in
//!   production's words, and so is a filter that is not `field op value`.
//!   The fake reads `labels.<k> = <v>`, `name = <v>` (a trailing `.*`
//!   matches a prefix, as the probe's sweep used), `status = <s>`, and for
//!   operations `operationType = <t>` and `targetLink eq .*<suffix>`; any
//!   other field is 501.
//! - The aggregated list answers every zone: its VMs, or the
//!   NO_RESULTS_ON_PAGE warning production gives an empty zone, in its
//!   words. Its pages count VMs across zones.
//! - A serial port keeps its last `Options.serial_window` bytes (1 MiB, as
//!   production's console did) at byte offsets; a read with no `start`
//!   answers the newest 1 MiB, one from before the window starts at its
//!   oldest byte, one from `next` with nothing new answers no bytes. Port
//!   5 and up is refused in production's words.
//! - Guest attributes under a namespace (`ns/`) answer `queryValue.items`;
//!   one key (`ns/key`) answers `variableKey` and `variableValue` (not
//!   measured: the API's documented shape); nothing under the path is 404
//!   "The resource '<path>' of type 'Guest Attribute' was not found."
//! - An image family answers its newest image put in that is not
//!   deprecated.
//! - An operation finishes after the number of `wait` calls `putOperation`
//!   says; a GET reads it without moving it. Done, it carries its failure
//!   when the test gave one, as production's failed operations did:
//!   `error.errors`, `httpErrorStatusCode` and `httpErrorMessage`.
//! - Not found, in production's words: "The resource
//!   'projects/<p>/zones/<z>/instances/<n>' was not found" (reason
//!   notFound, domain global), and the same for a machine type, an image,
//!   a family and an operation. A zone nobody has, read itself, is
//!   answered the same way (not measured: production's 404 shape).
//! - Faults a test asks for: refusals, dropped connections, and a lost
//!   answer.
//!
//! Not modelled, answered 501 with the reason: every write (creating,
//! changing, starting, stopping or deleting a VM, in the module's next
//! milestones), a filter on another field, a page token the fake did not
//! make, serial port 0, and another project's paths but for images.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const core = @import("core");
const tp = core.transport;
const types = @import("types.zig");

/// What every link the fake writes starts with: production's links name
/// this host, not the one a client calls (measured 2026-11-03).
const link_base = "https://www.googleapis.com/compute/v1/";

pub const FakeCompute = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    options: Options,
    /// Strings and resources, freed with the fake.
    store: std.heap.ArenaAllocator,
    zones: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// By "<zone>/<name>".
    instances: std.StringArrayHashMapUnmanaged(*FakeInstance) = .empty,
    /// By "<zone>/<name>".
    machine_types: std.StringArrayHashMapUnmanaged(PutMachineType) = .empty,
    /// In the order put in.
    images: std.ArrayList(FakeImage) = .empty,
    /// By "<scope path>/<name>", the scope path `zones/<z>`,
    /// `regions/<r>` or `global`.
    operations: std.StringArrayHashMapUnmanaged(*FakeOperation) = .empty,
    counter: u64 = 0,
    calls: usize = 0,
    faults: [3]Fault = .{ .{}, .{}, .{} },

    const refuse = 0;
    const drop = 1;
    const lose = 2;

    const Fault = struct { n: usize = 0, status: u16 = 0 };

    pub const Options = struct {
        project_id: []const u8 = "my-project",
        zones: []const []const u8 = &.{ "us-central1-a", "us-central1-b", "us-central1-c" },
        /// How much of a serial port is kept.
        serial_window: usize = 1 << 20,
    };

    pub const PutInstance = struct {
        zone: []const u8,
        name: []const u8,
        status: types.Status = .running,
        machine_type: []const u8 = "e2-micro",
        labels: []const types.Label = &.{},
        metadata: []const types.MetadataItem = &.{},
        tags: []const []const u8 = &.{},
        spot: bool = false,
        max_run_duration_s: ?u64 = null,
        termination_action: ?types.TerminationAction = null,
        deletion_protection: bool = false,
    };

    pub const PutMachineType = struct {
        name: []const u8,
        guest_cpus: u32 = 2,
        memory_mb: u64 = 1024,
        shared_cpu: bool = false,
        description: []const u8 = "",
    };

    pub const PutImage = struct {
        project: []const u8,
        name: []const u8,
        family: []const u8 = "",
        /// "DEPRECATED", "OBSOLETE" or "DELETED" to leave it out of its
        /// family.
        deprecated: []const u8 = "",
        disk_size_gb: u64 = 10,
    };

    pub const PutOperation = struct {
        scope: types.OperationScope,
        operation_type: []const u8 = "insert",
        /// The instance it acts on, in the scope's zone; null for none.
        target_instance: ?[]const u8 = null,
        /// How many `wait` calls answer it still RUNNING before it is DONE.
        waits_to_finish: u32 = 0,
        /// Set to make it end failed.
        failure: ?Failure = null,
        /// Who started it: "system" for what Compute did on its own.
        user: []const u8 = "fake@my-project.iam.gserviceaccount.com",
        client_operation_id: []const u8 = "",

        pub const Failure = struct {
            code: []const u8,
            message: []const u8,
            http_status: u16 = 400,
        };
    };

    const FakeInstance = struct {
        put: PutInstance,
        id: u64,
        created: std.Io.Timestamp,
        label_fingerprint: []const u8,
        metadata_fingerprint: []const u8,
        tags_fingerprint: []const u8,
        fingerprint: []const u8,
        serial: std.ArrayList(u8) = .empty,
        /// Bytes written before `serial`'s first, dropped from the window.
        serial_dropped: u64 = 0,
        guest: std.ArrayList(types.GuestAttribute) = .empty,
    };

    const FakeImage = struct { put: PutImage, created: std.Io.Timestamp };

    const FakeOperation = struct {
        name: []const u8,
        put: PutOperation,
        id: u64,
        inserted: std.Io.Timestamp,
        waits_left: u32,
    };

    pub const PutError = Allocator.Error || error{ UnknownZone, AlreadyExists, NotFound };

    pub fn init(gpa: Allocator, io: std.Io, options: Options) FakeCompute {
        var f: FakeCompute = .{ .gpa = gpa, .io = io, .options = options, .store = .init(gpa) };
        for (options.zones) |z| f.zones.put(gpa, z, {}) catch @panic("OOM");
        return f;
    }

    pub fn deinit(f: *FakeCompute) void {
        for (f.instances.values()) |i| {
            i.serial.deinit(f.gpa);
            i.guest.deinit(f.gpa);
        }
        f.zones.deinit(f.gpa);
        f.instances.deinit(f.gpa);
        f.machine_types.deinit(f.gpa);
        f.images.deinit(f.gpa);
        f.operations.deinit(f.gpa);
        f.store.deinit();
        f.* = undefined;
    }

    /// Goes into `Client.Options.transport`.
    pub fn transport(f: *FakeCompute) tp.Transport {
        return .{ .ptr = f, .vtable = &.{ .send = send } };
    }

    // Faults, each for the next `n` calls.

    /// Answers them with `status`, and changes nothing.
    pub fn refuseNext(f: *FakeCompute, n: usize, status: u16) void {
        f.setFault(refuse, .{ .n = n, .status = status });
    }

    /// Closes their connection before any answer.
    pub fn dropNext(f: *FakeCompute, n: usize) void {
        f.setFault(drop, .{ .n = n });
    }

    /// Serves them and answers `status` instead of what was read.
    pub fn loseNext(f: *FakeCompute, n: usize, status: u16) void {
        f.setFault(lose, .{ .n = n, .status = status });
    }

    fn setFault(f: *FakeCompute, slot: usize, fault: Fault) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.faults[slot] = fault;
    }

    fn takeFault(f: *FakeCompute, slot: usize) ?Fault {
        const fault = &f.faults[slot];
        if (fault.n == 0) return null;
        fault.n -= 1;
        return fault.*;
    }

    /// Calls served, refusals included.
    pub fn callCount(f: *FakeCompute) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.calls;
    }

    // What a test puts in.

    pub fn putZone(f: *FakeCompute, id: []const u8) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        try f.zones.put(f.gpa, try f.store.allocator().dupe(u8, id), {});
    }

    /// A VM, as if it had been created and had come up as `put.status`.
    pub fn putInstance(f: *FakeCompute, put: PutInstance) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (!f.zones.contains(put.zone)) return error.UnknownZone;
        const s = f.store.allocator();
        const key = try std.fmt.allocPrint(s, "{s}/{s}", .{ put.zone, put.name });
        if (f.instances.contains(key)) return error.AlreadyExists;
        const i = try s.create(FakeInstance);
        i.* = .{
            .put = try dupeInstance(s, put),
            .id = f.next(),
            .created = std.Io.Clock.real.now(f.io),
            .label_fingerprint = try f.fingerprint(),
            .metadata_fingerprint = try f.fingerprint(),
            .tags_fingerprint = try f.fingerprint(),
            .fingerprint = try f.fingerprint(),
        };
        try f.instances.put(f.gpa, key, i);
    }

    /// Moves a VM to `status`, as its own lifecycle would.
    pub fn setStatus(f: *FakeCompute, zone: []const u8, name: []const u8, status: types.Status) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const i = try f.instanceFor(zone, name);
        i.put.status = status;
    }

    /// Bytes the VM wrote to its serial console (port 1, the one tests
    /// read; every port answers the same bytes).
    pub fn appendSerial(f: *FakeCompute, zone: []const u8, name: []const u8, bytes: []const u8) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const i = try f.instanceFor(zone, name);
        try i.serial.appendSlice(f.gpa, bytes);
        if (i.serial.items.len > f.options.serial_window) {
            const extra = i.serial.items.len - f.options.serial_window;
            i.serial.replaceRangeAssumeCapacity(0, extra, &.{});
            i.serial_dropped += extra;
        }
    }

    /// A guest attribute, as the VM's guest would write it.
    pub fn putGuestAttribute(f: *FakeCompute, zone: []const u8, name: []const u8, attribute: types.GuestAttribute) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const i = try f.instanceFor(zone, name);
        const s = f.store.allocator();
        try i.guest.append(f.gpa, .{
            .namespace = try s.dupe(u8, attribute.namespace),
            .key = try s.dupe(u8, attribute.key),
            .value = try s.dupe(u8, attribute.value),
        });
    }

    pub fn putMachineType(f: *FakeCompute, zone: []const u8, put: PutMachineType) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (!f.zones.contains(zone)) return error.UnknownZone;
        const s = f.store.allocator();
        const key = try std.fmt.allocPrint(s, "{s}/{s}", .{ zone, put.name });
        try f.machine_types.put(f.gpa, key, .{
            .name = try s.dupe(u8, put.name),
            .guest_cpus = put.guest_cpus,
            .memory_mb = put.memory_mb,
            .shared_cpu = put.shared_cpu,
            .description = try s.dupe(u8, put.description),
        });
    }

    /// An image; the last one put in a family is its newest.
    pub fn putImage(f: *FakeCompute, put: PutImage) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const s = f.store.allocator();
        try f.images.append(f.gpa, .{ .put = .{
            .project = try s.dupe(u8, put.project),
            .name = try s.dupe(u8, put.name),
            .family = try s.dupe(u8, put.family),
            .deprecated = try s.dupe(u8, put.deprecated),
            .disk_size_gb = put.disk_size_gb,
        }, .created = std.Io.Clock.real.now(f.io) });
    }

    /// An operation, named `operation-<n>`, which it answers.
    pub fn putOperation(f: *FakeCompute, put: PutOperation) PutError![]const u8 {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const s = f.store.allocator();
        if (put.scope == .zone and !f.zones.contains(put.scope.zone)) return error.UnknownZone;
        const name = try std.fmt.allocPrint(s, "operation-{d}", .{f.next()});
        const op = try s.create(FakeOperation);
        op.* = .{
            .name = name,
            .put = try dupeOperation(s, put),
            .id = f.next(),
            .inserted = std.Io.Clock.real.now(f.io),
            .waits_left = put.waits_to_finish,
        };
        try f.operations.put(f.gpa, try std.fmt.allocPrint(s, "{s}/{s}", .{ try scopeKey(s, op.put.scope), name }), op);
        return name;
    }

    fn instanceFor(f: *FakeCompute, zone: []const u8, name: []const u8) PutError!*FakeInstance {
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}/{s}", .{ zone, name }) catch return error.NotFound;
        return f.instances.get(key) orelse error.NotFound;
    }

    fn next(f: *FakeCompute) u64 {
        f.counter += 1;
        return f.counter;
    }

    fn fingerprint(f: *FakeCompute) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(f.store.allocator(), "fp{d}=", .{f.next()});
    }

    fn dupeInstance(s: Allocator, put: PutInstance) Allocator.Error!PutInstance {
        var out = put;
        out.zone = try s.dupe(u8, put.zone);
        out.name = try s.dupe(u8, put.name);
        out.machine_type = try s.dupe(u8, put.machine_type);
        const labels = try s.alloc(types.Label, put.labels.len);
        for (put.labels, labels) |l, *o| o.* = .{ .key = try s.dupe(u8, l.key), .value = try s.dupe(u8, l.value) };
        out.labels = labels;
        const items = try s.alloc(types.MetadataItem, put.metadata.len);
        for (put.metadata, items) |m, *o| o.* = .{ .key = try s.dupe(u8, m.key), .value = if (m.value) |v| try s.dupe(u8, v) else null };
        out.metadata = items;
        const tags = try s.alloc([]const u8, put.tags.len);
        for (put.tags, tags) |t, *o| o.* = try s.dupe(u8, t);
        out.tags = tags;
        return out;
    }

    fn dupeOperation(s: Allocator, put: PutOperation) Allocator.Error!PutOperation {
        var out = put;
        out.scope = switch (put.scope) {
            .zone => |z| .{ .zone = try s.dupe(u8, z) },
            .region => |r| .{ .region = try s.dupe(u8, r) },
            .global => .global,
        };
        out.operation_type = try s.dupe(u8, put.operation_type);
        out.target_instance = if (put.target_instance) |t| try s.dupe(u8, t) else null;
        out.user = try s.dupe(u8, put.user);
        out.client_operation_id = try s.dupe(u8, put.client_operation_id);
        if (put.failure) |fail_| out.failure = .{
            .code = try s.dupe(u8, fail_.code),
            .message = try s.dupe(u8, fail_.message),
            .http_status = fail_.http_status,
        };
        return out;
    }

    fn scopeKey(a: Allocator, scope: types.OperationScope) Allocator.Error![]const u8 {
        return switch (scope) {
            .zone => |z| std.fmt.allocPrint(a, "zones/{s}", .{z}),
            .region => |r| std.fmt.allocPrint(a, "regions/{s}", .{r}),
            .global => "global",
        };
    }

    // The transport.

    pub const Reply = struct {
        status: u16,
        headers: []const tp.Header = &.{},
        body: []const u8,
    };

    fn send(ptr: *anyopaque, req: tp.Request, arena: Allocator) tp.Error!tp.Response {
        const f: *FakeCompute = @ptrCast(@alignCast(ptr));
        const reply = try f.serve(req, arena);
        return .{ .status = reply.status, .headers = reply.headers, .body = reply.body };
    }

    /// One request, as `send` serves it: for a test that wants to send
    /// what no client would.
    pub fn serve(f: *FakeCompute, req: tp.Request, arena: Allocator) tp.Error!Reply {
        const path = pathOf(req.url);
        const q_at = std.mem.indexOfScalar(u8, path, '?');
        const route_text = path[0 .. q_at orelse path.len];
        const query = if (q_at) |q| path[q + 1 ..] else "";
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.calls += 1;
        if (f.takeFault(drop) != null) return error.ConnectionResetByPeer;
        if (f.takeFault(refuse)) |fault| return refusal(arena, fault.status);
        const lost = f.takeFault(lose);
        const reply = try f.route(req, arena, route_text, query);
        if (lost) |fault| return refusal(arena, fault.status);
        return reply;
    }

    fn route(f: *FakeCompute, req: tp.Request, arena: Allocator, route_text: []const u8, query: []const u8) Allocator.Error!Reply {
        if (req.bearer == null) return fail(arena, 401, "required", "Request is missing required authentication credential. Expected OAuth 2 access token, login cookie or other valid authentication credential. See https://developers.google.com/identity/sign-in/web/devconsole-project.");
        const rest = std.mem.cutPrefix(u8, route_text, "/compute/v1/projects/") orelse return notModelled(arena, "this path");
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return notModelled(arena, "this path");
        const project = rest[0..slash];
        const tail = rest[slash + 1 ..];
        const params = try parseParams(arena, query);
        if (std.mem.startsWith(u8, tail, "global/images/")) {
            if (req.method != .GET) return notModelled(arena, "an image write");
            return f.image(arena, project, tail["global/images/".len..]);
        }
        if (!std.mem.eql(u8, project, f.options.project_id)) return notModelled(arena, "a project other than the fake's own");
        const wait = req.method == .POST and std.mem.endsWith(u8, tail, "/wait");
        if (req.method != .GET and !wait) return notModelled(arena, "a write (the module's next milestones)");
        if (std.mem.eql(u8, tail, "zones")) return f.listZones(arena, params);
        if (std.mem.eql(u8, tail, "aggregated/instances")) return f.aggregated(arena, params);
        if (std.mem.startsWith(u8, tail, "global/operations")) return f.operation(arena, "global", tail["global/operations".len..], params, wait);
        if (std.mem.startsWith(u8, tail, "regions/")) return f.regionPath(arena, tail["regions/".len..], params, wait);
        if (std.mem.startsWith(u8, tail, "zones/")) return f.zonePath(arena, tail["zones/".len..], params, wait);
        return notModelled(arena, "this path");
    }

    fn regionPath(f: *FakeCompute, arena: Allocator, tail: []const u8, params: Params, wait: bool) Allocator.Error!Reply {
        const slash = std.mem.indexOfScalar(u8, tail, '/') orelse return notModelled(arena, "a region's own path");
        const rest = tail[slash..];
        if (!std.mem.startsWith(u8, rest, "/operations")) return notModelled(arena, "a region path other than its operations");
        const key = try std.fmt.allocPrint(arena, "regions/{s}", .{tail[0..slash]});
        return f.operation(arena, key, rest["/operations".len..], params, wait);
    }

    fn zonePath(f: *FakeCompute, arena: Allocator, tail: []const u8, params: Params, wait: bool) Allocator.Error!Reply {
        const slash = std.mem.indexOfScalar(u8, tail, '/');
        const zone = tail[0 .. slash orelse tail.len];
        if (slash == null) return f.getZone(arena, zone);
        if (!f.zones.contains(zone)) return fail(arena, 400, "invalid", try std.fmt.allocPrint(arena, "Invalid value for field 'zone': '{s}'. Unknown zone.", .{zone}));
        const rest = tail[slash.? + 1 ..];
        if (std.mem.startsWith(u8, rest, "operations")) {
            const key = try std.fmt.allocPrint(arena, "zones/{s}", .{zone});
            return f.operation(arena, key, rest["operations".len..], params, wait);
        }
        if (wait) return notModelled(arena, "a write (the module's next milestones)");
        if (std.mem.eql(u8, rest, "instances")) return f.listInstances(arena, zone, params);
        if (std.mem.cutPrefix(u8, rest, "instances/")) |inst| return f.instancePath(arena, zone, inst, params);
        if (std.mem.eql(u8, rest, "machineTypes")) return f.listMachineTypes(arena, zone, params);
        if (std.mem.cutPrefix(u8, rest, "machineTypes/")) |name| return f.getMachineType(arena, zone, name);
        return notModelled(arena, "this zone path");
    }

    fn instancePath(f: *FakeCompute, arena: Allocator, zone: []const u8, tail: []const u8, params: Params) Allocator.Error!Reply {
        const slash = std.mem.indexOfScalar(u8, tail, '/');
        const name = tail[0 .. slash orelse tail.len];
        const i = f.instanceFor(zone, name) catch return f.notFound(arena, try std.fmt.allocPrint(arena, "zones/{s}/instances/{s}", .{ zone, name }));
        if (slash == null) return f.writeInstanceReply(arena, i);
        const what = tail[slash.? + 1 ..];
        if (std.mem.eql(u8, what, "serialPort")) return f.serialPort(arena, i, params);
        if (std.mem.eql(u8, what, "getGuestAttributes")) return guestAttributes(arena, i, params);
        return notModelled(arena, "this instance path");
    }

    // Lists.

    fn listInstances(f: *FakeCompute, arena: Allocator, zone: []const u8, params: Params) Allocator.Error!Reply {
        const plan = listPlan(params) orelse return listRefusal(arena, params);
        var matched: std.ArrayList(*FakeInstance) = .empty;
        for (f.instances.values()) |i| {
            if (!std.mem.eql(u8, i.put.zone, zone)) continue;
            switch (instanceMatches(i, plan.filter)) {
                .yes => try matched.append(arena, i),
                .no => {},
                .unmodelled => return notModelled(arena, "a filter on this field"),
            }
        }
        sortInstances(matched.items, plan.newest_first);
        const page = try pageOf(arena, matched.items.len, plan) orelse return notModelled(arena, "a page token the fake did not make");
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeList(f, &jw, arena, "compute#instanceList", try std.fmt.allocPrint(arena, "zones/{s}/instances", .{zone}), matched.items[page.start..page.end], page.next) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn aggregated(f: *FakeCompute, arena: Allocator, params: Params) Allocator.Error!Reply {
        const plan = listPlan(params) orelse return listRefusal(arena, params);
        var matched: std.ArrayList(*FakeInstance) = .empty;
        for (f.instances.values()) |i| switch (instanceMatches(i, plan.filter)) {
            .yes => try matched.append(arena, i),
            .no => {},
            .unmodelled => return notModelled(arena, "a filter on this field"),
        };
        sortByZoneThenName(matched.items);
        const page = try pageOf(arena, matched.items.len, plan) orelse return notModelled(arena, "a page token the fake did not make");
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        f.writeAggregated(&jw, arena, matched.items[page.start..page.end], page.next) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn writeAggregated(f: *FakeCompute, jw: *Stringify, arena: Allocator, page: []const *FakeInstance, next_token: ?[]const u8) !void {
        const zones = try arena.dupe([]const u8, f.zones.keys());
        std.mem.sort([]const u8, zones, {}, lessString);
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write("compute#instanceAggregatedList");
        try jw.objectField("id");
        try jw.print("\"projects/{s}/aggregated/instances\"", .{f.options.project_id});
        try jw.objectField("items");
        try jw.beginObject();
        for (zones) |z| {
            try jw.objectField(try std.fmt.allocPrint(arena, "zones/{s}", .{z}));
            try jw.beginObject();
            var any = false;
            for (page) |i| if (std.mem.eql(u8, i.put.zone, z)) {
                if (!any) {
                    try jw.objectField("instances");
                    try jw.beginArray();
                    any = true;
                }
                try f.writeInstance(jw, i);
            };
            if (any) try jw.endArray() else try writeEmptyScope(jw, arena, z);
            try jw.endObject();
        }
        try jw.endObject();
        if (next_token) |t| {
            try jw.objectField("nextPageToken");
            try jw.write(t);
        }
        try jw.objectField("selfLink");
        try jw.print("\"{s}projects/{s}/aggregated/instances\"", .{ link_base, f.options.project_id });
        try jw.endObject();
    }

    fn writeEmptyScope(jw: *Stringify, arena: Allocator, zone: []const u8) !void {
        const scope = try std.fmt.allocPrint(arena, "zones/{s}", .{zone});
        try jw.objectField("warning");
        try jw.write(.{
            .code = "NO_RESULTS_ON_PAGE",
            .message = try std.fmt.allocPrint(arena, "No results for the scope '{s}'.", .{scope}),
            .data = .{.{ .key = "scope", .value = scope }},
        });
    }

    fn listZones(f: *FakeCompute, arena: Allocator, params: Params) Allocator.Error!Reply {
        const plan = listPlan(params) orelse return listRefusal(arena, params);
        if (plan.filter != null) return notModelled(arena, "a filter on zones");
        const zones = try arena.dupe([]const u8, f.zones.keys());
        std.mem.sort([]const u8, zones, {}, lessString);
        const page = try pageOf(arena, zones.len, plan) orelse return notModelled(arena, "a page token the fake did not make");
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeZoneList(f, &jw, zones[page.start..page.end], page.next) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn writeZoneList(f: *FakeCompute, jw: *Stringify, zones: []const []const u8, next_token: ?[]const u8) !void {
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write("compute#zoneList");
        try jw.objectField("items");
        try jw.beginArray();
        for (zones) |z| try f.writeZone(jw, z);
        try jw.endArray();
        if (next_token) |t| {
            try jw.objectField("nextPageToken");
            try jw.write(t);
        }
        try jw.endObject();
    }

    fn writeZone(f: *FakeCompute, jw: *Stringify, zone: []const u8) !void {
        const region = zone[0 .. std.mem.lastIndexOfScalar(u8, zone, '-') orelse zone.len];
        const p = f.options.project_id;
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write("compute#zone");
        try jw.objectField("name");
        try jw.write(zone);
        try jw.objectField("description");
        try jw.write(zone);
        try jw.objectField("status");
        try jw.write("UP");
        try jw.objectField("region");
        try jw.print("\"{s}projects/{s}/regions/{s}\"", .{ link_base, p, region });
        try jw.objectField("selfLink");
        try jw.print("\"{s}projects/{s}/zones/{s}\"", .{ link_base, p, zone });
        try jw.endObject();
    }

    fn getZone(f: *FakeCompute, arena: Allocator, zone: []const u8) Allocator.Error!Reply {
        if (!f.zones.contains(zone)) return f.notFound(arena, try std.fmt.allocPrint(arena, "zones/{s}", .{zone}));
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        f.writeZone(&jw, zone) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn listMachineTypes(f: *FakeCompute, arena: Allocator, zone: []const u8, params: Params) Allocator.Error!Reply {
        const plan = listPlan(params) orelse return listRefusal(arena, params);
        if (plan.filter != null) return notModelled(arena, "a filter on machine types");
        var matched: std.ArrayList(PutMachineType) = .empty;
        for (f.machine_types.keys(), f.machine_types.values()) |k, m| {
            if (std.mem.startsWith(u8, k, zone) and k.len > zone.len and k[zone.len] == '/') try matched.append(arena, m);
        }
        std.mem.sort(PutMachineType, matched.items, {}, struct {
            fn less(_: void, a: PutMachineType, b: PutMachineType) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.less);
        const page = try pageOf(arena, matched.items.len, plan) orelse return notModelled(arena, "a page token the fake did not make");
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeMachineTypes(f, &jw, zone, matched.items[page.start..page.end], page.next) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn writeMachineTypes(f: *FakeCompute, jw: *Stringify, zone: []const u8, list: []const PutMachineType, next_token: ?[]const u8) !void {
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write("compute#machineTypeList");
        try jw.objectField("items");
        try jw.beginArray();
        for (list) |m| try f.writeMachineType(jw, zone, m);
        try jw.endArray();
        if (next_token) |t| {
            try jw.objectField("nextPageToken");
            try jw.write(t);
        }
        try jw.endObject();
    }

    fn writeMachineType(f: *FakeCompute, jw: *Stringify, zone: []const u8, m: PutMachineType) !void {
        _ = f;
        try jw.write(.{
            .kind = "compute#machineType",
            .name = m.name,
            .description = m.description,
            .guestCpus = m.guest_cpus,
            .memoryMb = m.memory_mb,
            .zone = zone,
            .isSharedCpu = m.shared_cpu,
        });
    }

    fn getMachineType(f: *FakeCompute, arena: Allocator, zone: []const u8, name: []const u8) Allocator.Error!Reply {
        const key = try std.fmt.allocPrint(arena, "{s}/{s}", .{ zone, name });
        const m = f.machine_types.get(key) orelse return f.notFound(arena, try std.fmt.allocPrint(arena, "zones/{s}/machineTypes/{s}", .{ zone, name }));
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        f.writeMachineType(&jw, zone, m) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn image(f: *FakeCompute, arena: Allocator, project: []const u8, tail: []const u8) Allocator.Error!Reply {
        const family = std.mem.cutPrefix(u8, tail, "family/");
        var found: ?FakeImage = null;
        for (f.images.items) |img| {
            if (!std.mem.eql(u8, img.put.project, project)) continue;
            if (family) |fam| {
                if (std.mem.eql(u8, img.put.family, fam) and img.put.deprecated.len == 0) found = img;
            } else if (std.mem.eql(u8, img.put.name, tail)) found = img;
        }
        const img = found orelse return fail(arena, 404, "notFound", try std.fmt.allocPrint(arena, "The resource 'projects/{s}/global/images/{s}' was not found", .{ project, tail }));
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeImage(&jw, project, img) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn writeImage(jw: *Stringify, project: []const u8, img: FakeImage) !void {
        var buf: [core.timestamp.max_len]u8 = undefined;
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write("compute#image");
        try jw.objectField("creationTimestamp");
        try jw.write(core.timestamp.format(&buf, img.created));
        try jw.objectField("name");
        try jw.write(img.put.name);
        try jw.objectField("status");
        try jw.write("READY");
        try jw.objectField("diskSizeGb");
        try jw.print("\"{d}\"", .{img.put.disk_size_gb});
        if (img.put.family.len > 0) {
            try jw.objectField("family");
            try jw.write(img.put.family);
        }
        if (img.put.deprecated.len > 0) {
            try jw.objectField("deprecated");
            try jw.write(.{ .state = img.put.deprecated });
        }
        try jw.objectField("selfLink");
        try jw.print("\"{s}projects/{s}/global/images/{s}\"", .{ link_base, project, img.put.name });
        try jw.endObject();
    }

    // An instance.

    fn writeInstanceReply(f: *FakeCompute, arena: Allocator, i: *FakeInstance) Allocator.Error!Reply {
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        f.writeInstance(&jw, i) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn writeInstance(f: *FakeCompute, jw: *Stringify, i: *FakeInstance) !void {
        const s = f.store.allocator();
        const p = f.options.project_id;
        const z = i.put.zone;
        var buf: [core.timestamp.max_len]u8 = undefined;
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write("compute#instance");
        try jw.objectField("id");
        try jw.print("\"{d}\"", .{i.id});
        try jw.objectField("creationTimestamp");
        try jw.write(core.timestamp.format(&buf, i.created));
        try jw.objectField("name");
        try jw.write(i.put.name);
        try jw.objectField("tags");
        try jw.write(.{ .items = i.put.tags, .fingerprint = i.tags_fingerprint });
        try jw.objectField("machineType");
        try jw.print("\"{s}projects/{s}/zones/{s}/machineTypes/{s}\"", .{ link_base, p, z, i.put.machine_type });
        try jw.objectField("status");
        try jw.write(statusName(i.put.status));
        try jw.objectField("zone");
        try jw.print("\"{s}projects/{s}/zones/{s}\"", .{ link_base, p, z });
        try jw.objectField("networkInterfaces");
        try jw.write(.{.{
            .network = try std.fmt.allocPrint(s, "{s}projects/{s}/global/networks/default", .{ link_base, p }),
            .networkIP = try std.fmt.allocPrint(s, "10.128.0.{d}", .{i.id % 250 + 2}),
            .name = "nic0",
        }});
        try jw.objectField("disks");
        try jw.write(.{.{
            .type = "PERSISTENT",
            .mode = "READ_WRITE",
            .source = try std.fmt.allocPrint(s, "{s}projects/{s}/zones/{s}/disks/{s}", .{ link_base, p, z, i.put.name }),
            .deviceName = "persistent-disk-0",
            .index = 0,
            .boot = true,
            .autoDelete = true,
            .interface = "SCSI",
            .diskSizeGb = "10",
        }});
        try writeMetadata(jw, i);
        try jw.objectField("selfLink");
        try jw.print("\"{s}projects/{s}/zones/{s}/instances/{s}\"", .{ link_base, p, z, i.put.name });
        try writeScheduling(jw, i);
        try writeLabels(jw, i);
        try jw.objectField("deletionProtection");
        try jw.write(i.put.deletion_protection);
        try jw.objectField("fingerprint");
        try jw.write(i.fingerprint);
        try jw.endObject();
    }

    fn writeMetadata(jw: *Stringify, i: *FakeInstance) !void {
        try jw.objectField("metadata");
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write("compute#metadata");
        try jw.objectField("fingerprint");
        try jw.write(i.metadata_fingerprint);
        if (i.put.metadata.len > 0) {
            try jw.objectField("items");
            try jw.beginArray();
            for (i.put.metadata) |m| {
                try jw.beginObject();
                try jw.objectField("key");
                try jw.write(m.key);
                if (m.value) |v| {
                    try jw.objectField("value");
                    try jw.write(v);
                }
                try jw.endObject();
            }
            try jw.endArray();
        }
        try jw.endObject();
    }

    /// As production wrote a spot VM's: TERMINATE and preemptible filled
    /// in; a standard VM's MIGRATE and automatic restart.
    fn writeScheduling(jw: *Stringify, i: *FakeInstance) !void {
        const spot = i.put.spot;
        try jw.objectField("scheduling");
        try jw.beginObject();
        if (i.put.max_run_duration_s) |secs| {
            try jw.objectField("maxRunDuration");
            try jw.print("{{\"seconds\":\"{d}\",\"nanos\":0}}", .{secs});
        }
        try jw.objectField("onHostMaintenance");
        try jw.write(if (spot) "TERMINATE" else "MIGRATE");
        try jw.objectField("automaticRestart");
        try jw.write(!spot);
        try jw.objectField("preemptible");
        try jw.write(spot);
        if (spot) {
            try jw.objectField("provisioningModel");
            try jw.write("SPOT");
        }
        if (i.put.termination_action) |action| {
            try jw.objectField("instanceTerminationAction");
            try jw.write(if (action == .delete) "DELETE" else "STOP");
        }
        try jw.endObject();
    }

    fn writeLabels(jw: *Stringify, i: *FakeInstance) !void {
        if (i.put.labels.len > 0) {
            try jw.objectField("labels");
            try jw.beginObject();
            for (i.put.labels) |l| {
                try jw.objectField(l.key);
                try jw.write(l.value);
            }
            try jw.endObject();
        }
        try jw.objectField("labelFingerprint");
        try jw.write(i.label_fingerprint);
    }

    fn serialPort(f: *FakeCompute, arena: Allocator, i: *FakeInstance, params: Params) Allocator.Error!Reply {
        const port_text = params.get("port") orelse "1";
        const port = std.fmt.parseInt(u32, port_text, 10) catch return notModelled(arena, "a serial port that is not a number");
        if (port > 4) return fail(arena, 400, "invalid", try std.fmt.allocPrint(arena, "Invalid value for field 'port': '{d}'. Must be less than or equal to 4", .{port}));
        if (port == 0) return notModelled(arena, "serial port 0");
        const total = i.serial_dropped + i.serial.items.len;
        const window_start = i.serial_dropped;
        const asked: u64 = if (params.get("start")) |s| std.fmt.parseInt(u64, s, 10) catch return notModelled(arena, "a serial start that is not a number") else if (total > 1 << 20) total - (1 << 20) else window_start;
        const start = @min(@max(asked, window_start), total);
        const end = @min(total, start + (1 << 20));
        const contents = i.serial.items[@intCast(start - window_start)..@intCast(end - window_start)];
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        jw.write(.{
            .kind = "compute#serialPortOutput",
            .contents = contents,
            .start = try std.fmt.allocPrint(arena, "{d}", .{start}),
            .next = try std.fmt.allocPrint(arena, "{d}", .{end}),
            .selfLink = try std.fmt.allocPrint(arena, "{s}projects/{s}/zones/{s}/instances/{s}/serialPortOutput", .{ link_base, f.options.project_id, i.put.zone, i.put.name }),
        }) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn guestAttributes(arena: Allocator, i: *FakeInstance, params: Params) Allocator.Error!Reply {
        const path = params.get("queryPath") orelse return notModelled(arena, "guest attributes with no query path");
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        const slash = std.mem.indexOfScalar(u8, path, '/') orelse return notModelled(arena, "a query path with no namespace");
        const namespace = path[0..slash];
        const key = path[slash + 1 ..];
        var matched: std.ArrayList(types.GuestAttribute) = .empty;
        for (i.guest.items) |g| {
            if (!std.mem.eql(u8, g.namespace, namespace)) continue;
            if (key.len == 0 or std.mem.eql(u8, g.key, key)) try matched.append(arena, g);
        }
        if (matched.items.len == 0) return fail(arena, 404, "notFound", try std.fmt.allocPrint(arena, "The resource '{s}' of type 'Guest Attribute' was not found.", .{path}));
        if (key.len > 0) {
            jw.write(.{ .kind = "compute#guestAttributes", .variableKey = path, .variableValue = matched.items[0].value }) catch return error.OutOfMemory;
        } else {
            jw.write(.{ .kind = "compute#guestAttributes", .queryPath = path, .queryValue = .{ .items = matched.items } }) catch return error.OutOfMemory;
        }
        return .{ .status = 200, .body = out.written() };
    }

    // Operations.

    fn operation(f: *FakeCompute, arena: Allocator, scope_key: []const u8, tail: []const u8, params: Params, wait: bool) Allocator.Error!Reply {
        if (tail.len == 0) return f.listOperations(arena, scope_key, params);
        const rest = std.mem.cutPrefix(u8, tail, "/") orelse return notModelled(arena, "this operations path");
        const name = std.mem.cutSuffix(u8, rest, "/wait") orelse rest;
        const key = try std.fmt.allocPrint(arena, "{s}/{s}", .{ scope_key, name });
        const op = f.operations.get(key) orelse return f.notFound(arena, try std.fmt.allocPrint(arena, "{s}/operations/{s}", .{ scope_key, name }));
        if (wait and op.waits_left > 0) op.waits_left -= 1;
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        f.writeOperation(&jw, arena, op) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn listOperations(f: *FakeCompute, arena: Allocator, scope_key: []const u8, params: Params) Allocator.Error!Reply {
        const plan = listPlan(params) orelse return listRefusal(arena, params);
        var matched: std.ArrayList(*FakeOperation) = .empty;
        for (f.operations.keys(), f.operations.values()) |k, op| {
            if (!std.mem.startsWith(u8, k, scope_key) or k.len <= scope_key.len or k[scope_key.len] != '/') continue;
            switch (try f.operationMatches(arena, op, plan.filter)) {
                .yes => try matched.append(arena, op),
                .no => {},
                .unmodelled => return notModelled(arena, "a filter on this field"),
            }
        }
        const page = try pageOf(arena, matched.items.len, plan) orelse return notModelled(arena, "a page token the fake did not make");
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        f.writeOperationList(&jw, arena, matched.items[page.start..page.end], page.next) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn writeOperationList(f: *FakeCompute, jw: *Stringify, arena: Allocator, list: []const *FakeOperation, next_token: ?[]const u8) !void {
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write("compute#operationList");
        try jw.objectField("items");
        try jw.beginArray();
        for (list) |op| try f.writeOperation(jw, arena, op);
        try jw.endArray();
        if (next_token) |t| {
            try jw.objectField("nextPageToken");
            try jw.write(t);
        }
        try jw.endObject();
    }

    fn targetLink(f: *FakeCompute, arena: Allocator, op: *FakeOperation) Allocator.Error!?[]const u8 {
        const name = op.put.target_instance orelse return null;
        return switch (op.put.scope) {
            .zone => |z| try std.fmt.allocPrint(arena, "{s}projects/{s}/zones/{s}/instances/{s}", .{ link_base, f.options.project_id, z, name }),
            else => null,
        };
    }

    fn writeOperation(f: *FakeCompute, jw: *Stringify, arena: Allocator, op: *FakeOperation) !void {
        const p = f.options.project_id;
        const done = op.waits_left == 0;
        var buf: [core.timestamp.max_len]u8 = undefined;
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write("compute#operation");
        try jw.objectField("id");
        try jw.print("\"{d}\"", .{op.id});
        try jw.objectField("name");
        try jw.write(op.name);
        switch (op.put.scope) {
            .zone => |z| {
                try jw.objectField("zone");
                try jw.print("\"{s}projects/{s}/zones/{s}\"", .{ link_base, p, z });
            },
            .region => |r| {
                try jw.objectField("region");
                try jw.print("\"{s}projects/{s}/regions/{s}\"", .{ link_base, p, r });
            },
            .global => {},
        }
        if (op.put.client_operation_id.len > 0) {
            try jw.objectField("clientOperationId");
            try jw.write(op.put.client_operation_id);
        }
        try jw.objectField("operationType");
        try jw.write(op.put.operation_type);
        if (try f.targetLink(arena, op)) |link| {
            try jw.objectField("targetLink");
            try jw.write(link);
        }
        try jw.objectField("status");
        try jw.write(if (done) "DONE" else "RUNNING");
        try jw.objectField("user");
        try jw.write(op.put.user);
        try jw.objectField("progress");
        try jw.write(@as(u8, if (done) 100 else 0));
        try jw.objectField("insertTime");
        try jw.write(core.timestamp.format(&buf, op.inserted));
        if (done) if (op.put.failure) |failure| try writeFailure(jw, failure);
        try jw.objectField("selfLink");
        try jw.print("\"{s}projects/{s}/{s}/operations/{s}\"", .{ link_base, p, try scopeKey(arena, op.put.scope), op.name });
        try jw.endObject();
    }

    fn writeFailure(jw: *Stringify, failure: PutOperation.Failure) !void {
        try jw.objectField("error");
        try jw.write(.{ .errors = .{.{ .code = failure.code, .message = failure.message }} });
        try jw.objectField("httpErrorStatusCode");
        try jw.write(failure.http_status);
        try jw.objectField("httpErrorMessage");
        try jw.write(if (failure.http_status == 400) "BAD REQUEST" else "ERROR");
    }

    // Filters, orders and pages.

    const Params = struct {
        names: []const []const u8,
        values: []const []const u8,

        fn get(p: Params, name: []const u8) ?[]const u8 {
            for (p.names, p.values) |n, v| if (std.mem.eql(u8, n, name)) return v;
            return null;
        }
    };

    fn parseParams(arena: Allocator, query: []const u8) Allocator.Error!Params {
        var names: std.ArrayList([]const u8) = .empty;
        var values: std.ArrayList([]const u8) = .empty;
        var pairs = std.mem.splitScalar(u8, query, '&');
        while (pairs.next()) |pair| {
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            try names.append(arena, try percentDecode(arena, pair[0..eq]));
            try values.append(arena, try percentDecode(arena, if (eq < pair.len) pair[eq + 1 ..] else ""));
        }
        return .{ .names = names.items, .values = values.items };
    }

    fn percentDecode(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
        const out = try arena.alloc(u8, text.len);
        var n: usize = 0;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '%' and i + 2 < text.len) {
                if (std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16)) |b| {
                    out[n] = b;
                    n += 1;
                    i += 2;
                    continue;
                } else |_| {}
            }
            out[n] = if (text[i] == '+') ' ' else text[i];
            n += 1;
        }
        return out[0..n];
    }

    const Filter = struct { field: []const u8, op: []const u8, value: []const u8 };

    const Plan = struct {
        filter: ?Filter,
        newest_first: bool,
        max: usize,
        start: usize,
    };

    /// The list's filter, order and page, or null when production refuses
    /// them (`listRefusal` says how).
    fn listPlan(params: Params) ?Plan {
        const filter_text = params.get("filter");
        const order = params.get("orderBy");
        if (filter_text != null and order != null) return null;
        var newest_first = false;
        if (order) |o| {
            if (std.mem.eql(u8, o, "creationTimestamp desc")) newest_first = true else if (!std.mem.eql(u8, o, "name")) return null;
        }
        var filter: ?Filter = null;
        if (filter_text) |t| filter = parseFilter(t) orelse return null;
        const max = if (params.get("maxResults")) |m| std.fmt.parseInt(usize, m, 10) catch 500 else 500;
        var start: usize = 0;
        if (params.get("pageToken")) |token| start = std.fmt.parseInt(usize, std.mem.cutPrefix(u8, token, "fake-page-") orelse "x", 10) catch std.math.maxInt(usize);
        return .{ .filter = filter, .newest_first = newest_first, .max = if (max == 0) 500 else @min(max, 500), .start = start };
    }

    fn listRefusal(arena: Allocator, params: Params) Allocator.Error!Reply {
        const filter_text = params.get("filter");
        if (params.get("orderBy")) |o| {
            if (filter_text != null) return fail(arena, 400, "invalid", try std.fmt.allocPrint(arena, "Invalid value for field 'orderBy': '{s}'. Specifying both a list filter and sort order is not currently supported.", .{o}));
            return fail(arena, 400, "invalid", try std.fmt.allocPrint(arena, "Invalid value for field 'orderBy': '{s}'. Invalid sort order expression: sorting not supported on the specified field.", .{o}));
        }
        return fail(arena, 400, "invalid", try std.fmt.allocPrint(arena, "Invalid value for field 'filter': '{s}'. Invalid list filter expression.", .{filter_text orelse ""}));
    }

    /// `field op value`, `field=value`, a value perhaps quoted; null when
    /// it is not that shape.
    fn parseFilter(text: []const u8) ?Filter {
        const t = std.mem.trim(u8, text, " ");
        for ([_][]const u8{ " eq ", " = ", "=" }) |op| {
            const at = std.mem.indexOf(u8, t, op) orelse continue;
            const field_ = std.mem.trim(u8, t[0..at], " ");
            var value = std.mem.trim(u8, t[at + op.len ..], " ");
            if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
            if (field_.len == 0 or value.len == 0 or std.mem.indexOfAny(u8, value, "=") != null) return null;
            return .{ .field = field_, .op = std.mem.trim(u8, op, " "), .value = value };
        }
        return null;
    }

    const Match = enum { yes, no, unmodelled };

    fn instanceMatches(i: *FakeInstance, filter: ?Filter) Match {
        const f = filter orelse return .yes;
        if (std.mem.cutPrefix(u8, f.field, "labels.")) |key| {
            for (i.put.labels) |l| if (std.mem.eql(u8, l.key, key)) return if (std.mem.eql(u8, l.value, f.value)) .yes else .no;
            return .no;
        }
        if (std.mem.eql(u8, f.field, "name")) return if (nameMatches(i.put.name, f.value)) .yes else .no;
        if (std.mem.eql(u8, f.field, "status")) return if (std.mem.eql(u8, statusName(i.put.status), f.value)) .yes else .no;
        return .unmodelled;
    }

    fn operationMatches(f: *FakeCompute, arena: Allocator, op: *FakeOperation, filter: ?Filter) Allocator.Error!Match {
        const flt = filter orelse return .yes;
        if (std.mem.eql(u8, flt.field, "operationType")) return if (std.mem.eql(u8, op.put.operation_type, flt.value)) .yes else .no;
        if (std.mem.eql(u8, flt.field, "targetLink")) {
            const suffix = std.mem.cutPrefix(u8, flt.value, ".*") orelse return .unmodelled;
            const link = try f.targetLink(arena, op) orelse return .no;
            return if (std.mem.endsWith(u8, link, suffix)) .yes else .no;
        }
        return .unmodelled;
    }

    /// An exact name, or a prefix ending in `.*`.
    fn nameMatches(name: []const u8, pattern: []const u8) bool {
        if (std.mem.cutSuffix(u8, pattern, ".*")) |prefix| return std.mem.startsWith(u8, name, prefix);
        return std.mem.eql(u8, name, pattern);
    }

    const Page = struct { start: usize, end: usize, next: ?[]const u8 };

    /// The page `plan` asks for, its token the fake's own; null for a
    /// token past the end, which the fake did not make.
    fn pageOf(arena: Allocator, len: usize, plan: Plan) Allocator.Error!?Page {
        if (plan.start > len) return null;
        const end = @min(len, plan.start + plan.max);
        const token: ?[]const u8 = if (end < len) try std.fmt.allocPrint(arena, "fake-page-{d}", .{end}) else null;
        return .{ .start = plan.start, .end = end, .next = token };
    }

    fn sortInstances(list: []*FakeInstance, newest_first: bool) void {
        if (newest_first) {
            std.mem.sort(*FakeInstance, list, {}, struct {
                fn less(_: void, a: *FakeInstance, b: *FakeInstance) bool {
                    return a.id > b.id;
                }
            }.less);
        } else std.mem.sort(*FakeInstance, list, {}, struct {
            fn less(_: void, a: *FakeInstance, b: *FakeInstance) bool {
                return std.mem.lessThan(u8, a.put.name, b.put.name);
            }
        }.less);
    }

    fn sortByZoneThenName(list: []*FakeInstance) void {
        std.mem.sort(*FakeInstance, list, {}, struct {
            fn less(_: void, a: *FakeInstance, b: *FakeInstance) bool {
                return switch (std.mem.order(u8, a.put.zone, b.put.zone)) {
                    .lt => true,
                    .gt => false,
                    .eq => std.mem.lessThan(u8, a.put.name, b.put.name),
                };
            }
        }.less);
    }

    fn lessString(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    fn writeList(f: *FakeCompute, jw: *Stringify, arena: Allocator, kind: []const u8, id_tail: []const u8, list: []const *FakeInstance, next_token: ?[]const u8) !void {
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write(kind);
        try jw.objectField("id");
        try jw.print("\"projects/{s}/{s}\"", .{ f.options.project_id, id_tail });
        if (list.len > 0) {
            try jw.objectField("items");
            try jw.beginArray();
            for (list) |i| try f.writeInstance(jw, i);
            try jw.endArray();
        }
        if (next_token) |t| {
            try jw.objectField("nextPageToken");
            try jw.write(t);
        }
        try jw.objectField("selfLink");
        try jw.write(try std.fmt.allocPrint(arena, "{s}projects/{s}/{s}", .{ link_base, f.options.project_id, id_tail }));
        try jw.endObject();
    }

    fn statusName(status: types.Status) []const u8 {
        return switch (status) {
            .provisioning => "PROVISIONING",
            .staging => "STAGING",
            .running => "RUNNING",
            .stopping => "STOPPING",
            .stopped => "STOPPED",
            .suspending => "SUSPENDING",
            .suspended => "SUSPENDED",
            .terminated => "TERMINATED",
            .repairing => "REPAIRING",
            .pending => "PENDING",
            .pending_stop => "PENDING_STOP",
            .deprovisioning => "DEPROVISIONING",
            .unknown => "UNKNOWN",
        };
    }

    // Answers.

    fn pathOf(url: []const u8) []const u8 {
        const scheme = std.mem.indexOf(u8, url, "://") orelse return url;
        const after = url[scheme + 3 ..];
        const slash = std.mem.indexOfScalar(u8, after, '/') orelse return "/";
        return after[slash..];
    }

    fn notFound(f: *FakeCompute, arena: Allocator, tail: []const u8) Allocator.Error!Reply {
        return fail(arena, 404, "notFound", try std.fmt.allocPrint(arena, "The resource 'projects/{s}/{s}' was not found", .{ f.options.project_id, tail }));
    }

    /// Compute's older error shape, as production answered every refusal.
    fn fail(arena: Allocator, code: u16, reason: []const u8, message: []const u8) Allocator.Error!Reply {
        return .{ .status = code, .body = try Stringify.valueAlloc(arena, .{ .@"error" = .{
            .code = code,
            .message = message,
            .errors = .{.{ .message = message, .domain = "global", .reason = reason }},
        } }, .{}) };
    }

    fn notModelled(arena: Allocator, what: []const u8) Allocator.Error!Reply {
        return fail(arena, 501, "notImplemented", try std.fmt.allocPrint(arena, "fake: {s} is not modelled yet", .{what}));
    }

    fn refusal(arena: Allocator, status: u16) Allocator.Error!Reply {
        const reason = switch (status) {
            400 => "invalid",
            401 => "required",
            403 => "forbidden",
            404 => "notFound",
            429 => "rateLimitExceeded",
            500 => "backendError",
            503 => "backendError",
            else => "unknown",
        };
        return fail(arena, status, reason, "fake: refused as the test asked");
    }
};
