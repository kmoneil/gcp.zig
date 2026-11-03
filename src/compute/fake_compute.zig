//! Compute Engine in memory, for tests of code that reads, creates, starts,
//! stops and deletes VMs and waits on operations: behind
//! `Client.Options.transport`, it answers the module's calls as production
//! answered them when measured on 2026-11-03 (issue #346, milestone 0).
//!
//! - Zones are the fake's options' (us-central1-a, -b and -c by default)
//!   and `putZone`'s. A path under any other zone is 400 "Invalid value
//!   for field 'zone': '<z>'. Unknown zone."
//! - Every zone has the machine types `Options.machine_types` names
//!   (e2-micro, e2-small, e2-medium and e2-standard-2, as production
//!   described them), and the images `Options.images` holds (debian-12's
//!   newest when measured) are there from the start.
//! - VMs, machine types, images, guest attributes, serial output and
//!   operations a test puts in: `putInstance`, `setStatus`,
//!   `putMachineType`, `putImage`, `putGuestAttribute`, `appendSerial`
//!   and `putOperation` stand in for whoever created them and for the
//!   VMs themselves.
//! - Writes, as production took them. An insert makes the VM
//!   PROVISIONING, and its operation RUNNING; the operation finishes
//!   after `Options.write_waits` waits (one, as production's inserts,
//!   stops, starts and resumes each did), and then the VM is RUNNING.
//!   Start, stop, suspend, resume, reset and delete move a VM the same
//!   way, through STAGING, STOPPING or SUSPENDING to RUNNING, TERMINATED,
//!   SUSPENDED or gone, in the states production took each from:
//!   starting a running VM is an operation DONE at once, stopping a
//!   stopped one an operation like any other (measured). A write from a
//!   state production was not measured in (suspending a stopped VM, say)
//!   is 501. `finishOperations` finishes everything still running.
//! - A write with a `requestId` already seen answers that write's
//!   operation as it stands, and changes nothing (measured). An insert of
//!   a name taken is 409, of a name that is not RFC 1035 or a machine type
//!   the zone lacks 400, of an image nobody has 404, of a standard e2
//!   with onHostMaintenance TERMINATE 400; a delete under deletion
//!   protection is 400; each in production's words.
//! - `setStockout` puts a zone out of room: an insert or a start there is
//!   taken, and its operation ends DONE with ZONE_RESOURCE_POOL_EXHAUSTED
//!   (not measured: Google's documented words), the VM gone or still
//!   TERMINATED. `putTemplate` puts in an instance template for an insert
//!   from one.
//! - Changes to a live VM, as production took them (measured 2026-11-03):
//!   labels, metadata and tags each replaced whole under their
//!   fingerprint, a stale or missing one 412 in production's words, the
//!   change shown at once and a new fingerprint with it; a machine type
//!   set on a stopped VM, refused in its operation on a running one, an
//!   unknown one 400; scheduling changed field by field on a stopped VM,
//!   refused on a running one with a run limit, STANDARD refused for a
//!   spot VM unless `preemptible` false comes with it; deletion protection
//!   DONE at once. A scheduling change to a running VM with no run limit
//!   was not measured, and is 501.
//! - Disks: `putDisk` puts in one a VM can attach, and every VM's boot disk
//!   is one too, named as the VM. An attach of a disk nobody has is 404;
//!   of one in use, by another VM or this one, is taken and its operation
//!   ends DONE with RESOURCE_IN_USE_BY_ANOTHER_RESOURCE; a detach of a
//!   device the VM has none of ends DONE with INVALID_USAGE; each in
//!   production's words. A VM deleted frees its disks, and deletes those
//!   that auto-delete.
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
//! Not modelled, answered 501 with the reason: templates and groups
//! beyond an insert from one (the module's next milestone), detaching a
//! boot disk, a filter on another field, a page token the fake did not
//! make, serial port 0, and another project's paths but for images.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const core = @import("core");
const tp = core.transport;
const types = @import("types.zig");
const validate = @import("validate.zig");

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
    /// Every write's operation by the `requestId` it came with, to answer
    /// a resend.
    request_ids: std.StringHashMapUnmanaged(*FakeOperation) = .empty,
    /// Zones out of room.
    stockouts: std.StringHashMapUnmanaged(void) = .empty,
    /// By "global/<name>" or "regions/<region>/<name>"; a template's zone
    /// and status are unused.
    templates: std.StringHashMapUnmanaged(PutInstance) = .empty,
    /// By "<zone>/<name>", the VMs' boot disks among them.
    disks: std.StringArrayHashMapUnmanaged(FakeDisk) = .empty,
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
        /// The machine types every zone has from the start, `putZone`'s
        /// too. An insert must name one its zone has.
        machine_types: []const PutMachineType = &default_machine_types,
        /// The images there from the start. An insert's image must be one
        /// put in, or the newest in one's family.
        images: []const PutImage = &default_images,
        /// How many `wait` calls a write's operation takes to finish, as
        /// `PutOperation.waits_to_finish` counts them.
        write_waits: u32 = 1,
    };

    /// As production listed them on 2026-11-03.
    pub const default_machine_types = [_]PutMachineType{
        .{ .name = "e2-micro", .guest_cpus = 2, .memory_mb = 1024, .shared_cpu = true, .description = "Efficient Instance, 2 vCPU (1/8 shared physical core) and 1 GB RAM" },
        .{ .name = "e2-small", .guest_cpus = 2, .memory_mb = 2048, .shared_cpu = true, .description = "Efficient Instance, 2 vCPU (1/4 shared physical core) and 2 GB RAM" },
        .{ .name = "e2-medium", .guest_cpus = 2, .memory_mb = 4096, .shared_cpu = true, .description = "Efficient Instance, 2 vCPU (1/2 shared physical core) and 4 GB RAM" },
        .{ .name = "e2-standard-2", .guest_cpus = 2, .memory_mb = 8192, .description = "Efficient Instance, 2 vCPUs, 8 GB RAM" },
    };

    /// debian-12's newest when measured.
    pub const default_images = [_]PutImage{
        .{ .project = "debian-cloud", .name = "debian-12-bookworm-v20261027", .family = "debian-12" },
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
        /// Null: what Compute gives, false for a spot VM, true otherwise.
        automatic_restart: ?bool = null,
        /// Null: what Compute gives, TERMINATE for a spot VM, MIGRATE
        /// otherwise.
        on_host_maintenance: ?types.HostMaintenance = null,
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
        /// How many `wait` calls it takes to finish: the last of them
        /// answers DONE, a read before it RUNNING. 0 is DONE from the
        /// start.
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
        /// In the order attached; the boot disk is not among them.
        attached: std.ArrayList(FakeAttached) = .empty,
    };

    /// An instance template, global or in a region, for an insert from
    /// one; what it gives a VM.
    pub const PutTemplate = struct {
        name: []const u8,
        /// Null for a global template.
        region: ?[]const u8 = null,
        machine_type: []const u8 = "e2-micro",
        labels: []const types.Label = &.{},
        metadata: []const types.MetadataItem = &.{},
        tags: []const []const u8 = &.{},
        spot: bool = false,
        max_run_duration_s: ?u64 = null,
        termination_action: ?types.TerminationAction = null,
    };

    /// A disk a VM can attach.
    pub const PutDisk = struct {
        zone: []const u8,
        name: []const u8,
        size_gb: u64 = 10,
    };

    const FakeDisk = struct {
        size_gb: u64,
        /// The VM that has it attached, its boot disk or another.
        user: ?[]const u8 = null,
    };

    /// A disk attached to a VM beside its boot disk.
    const FakeAttached = struct {
        device_name: []const u8,
        disk: []const u8,
        read_only: bool,
        auto_delete: bool,
    };

    const FakeImage = struct { put: PutImage, created: std.Io.Timestamp };

    const FakeOperation = struct {
        name: []const u8,
        put: PutOperation,
        id: u64,
        inserted: std.Io.Timestamp,
        waits_left: u32,
        /// What finishing does to its VM, once.
        effect: Effect = .none,
    };

    /// What a write's operation does to its VM when it finishes.
    const Effect = enum { none, run, terminate, suspend_vm, remove };

    pub const PutError = Allocator.Error || error{ UnknownZone, AlreadyExists, NotFound };

    pub fn init(gpa: Allocator, io: std.Io, options: Options) FakeCompute {
        var f: FakeCompute = .{ .gpa = gpa, .io = io, .options = options, .store = .init(gpa) };
        for (options.zones) |z| f.addZone(z) catch @panic("OOM");
        for (options.images) |img| f.addImage(img) catch @panic("OOM");
        return f;
    }

    pub fn deinit(f: *FakeCompute) void {
        for (f.instances.values()) |i| {
            i.serial.deinit(f.gpa);
            i.guest.deinit(f.gpa);
            i.attached.deinit(f.gpa);
        }
        f.disks.deinit(f.gpa);
        f.zones.deinit(f.gpa);
        f.instances.deinit(f.gpa);
        f.machine_types.deinit(f.gpa);
        f.images.deinit(f.gpa);
        f.operations.deinit(f.gpa);
        f.request_ids.deinit(f.gpa);
        f.stockouts.deinit(f.gpa);
        f.templates.deinit(f.gpa);
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

    /// A zone, with `Options.machine_types`.
    pub fn putZone(f: *FakeCompute, id: []const u8) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        try f.addZone(try f.store.allocator().dupe(u8, id));
    }

    fn addZone(f: *FakeCompute, id: []const u8) Allocator.Error!void {
        try f.zones.put(f.gpa, id, {});
        for (f.options.machine_types) |m| try f.addMachineType(id, m);
    }

    /// A VM, as if it had been created and had come up as `put.status`.
    pub fn putInstance(f: *FakeCompute, put: PutInstance) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        try f.addInstance(put);
    }

    fn addInstance(f: *FakeCompute, put: PutInstance) PutError!void {
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
        // Its boot disk, named as the VM, unless one of that name is there.
        const gop = try f.disks.getOrPut(f.gpa, key);
        if (!gop.found_existing) gop.value_ptr.* = .{ .size_gb = 10, .user = i.put.name };
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
        try f.addMachineType(zone, put);
    }

    fn addMachineType(f: *FakeCompute, zone: []const u8, put: PutMachineType) Allocator.Error!void {
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
        try f.addImage(put);
    }

    fn addImage(f: *FakeCompute, put: PutImage) Allocator.Error!void {
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

    /// Puts `zone` out of room, or gives it room again: an insert or a
    /// start there is taken, and its operation ends DONE with
    /// ZONE_RESOURCE_POOL_EXHAUSTED.
    pub fn setStockout(f: *FakeCompute, zone: []const u8, out_of_room: bool) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (!f.zones.contains(zone)) return error.UnknownZone;
        if (out_of_room) {
            try f.stockouts.put(f.gpa, try f.store.allocator().dupe(u8, zone), {});
        } else _ = f.stockouts.remove(zone);
    }

    /// An instance template, for an insert from one.
    pub fn putTemplate(f: *FakeCompute, put: PutTemplate) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const s = f.store.allocator();
        const key = if (put.region) |r| try std.fmt.allocPrint(s, "regions/{s}/{s}", .{ r, put.name }) else try std.fmt.allocPrint(s, "global/{s}", .{put.name});
        if (f.templates.contains(key)) return error.AlreadyExists;
        try f.templates.put(f.gpa, key, try dupeInstance(s, .{
            .zone = "",
            .name = put.name,
            .machine_type = put.machine_type,
            .labels = put.labels,
            .metadata = put.metadata,
            .tags = put.tags,
            .spot = put.spot,
            .max_run_duration_s = put.max_run_duration_s,
            .termination_action = put.termination_action,
        }));
    }

    /// A disk a VM can attach, in a zone the fake has.
    pub fn putDisk(f: *FakeCompute, put: PutDisk) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (!f.zones.contains(put.zone)) return error.UnknownZone;
        const key = try std.fmt.allocPrint(f.store.allocator(), "{s}/{s}", .{ put.zone, put.name });
        if (f.disks.contains(key)) return error.AlreadyExists;
        try f.disks.put(f.gpa, key, .{ .size_gb = put.size_gb });
    }

    /// Finishes every operation still running, as waits until DONE would.
    pub fn finishOperations(f: *FakeCompute) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        for (f.operations.values()) |op| if (op.waits_left > 0) {
            op.waits_left = 0;
            f.finish(op);
        };
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
        if (req.method != .GET and !wait) return f.write(req, arena, tail, params);
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
        if (!f.zones.contains(zone)) return unknownZone(arena, zone);
        const rest = tail[slash.? + 1 ..];
        if (std.mem.startsWith(u8, rest, "operations")) {
            const key = try std.fmt.allocPrint(arena, "zones/{s}", .{zone});
            return f.operation(arena, key, rest["operations".len..], params, wait);
        }
        if (wait) return notModelled(arena, "a wait on this path");
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

    /// An image by name, or a family's newest not deprecated: `tail` is
    /// `<name>` or `family/<family>`.
    fn findImage(f: *FakeCompute, project: []const u8, tail: []const u8) ?FakeImage {
        const family = std.mem.cutPrefix(u8, tail, "family/");
        var found: ?FakeImage = null;
        for (f.images.items) |img| {
            if (!std.mem.eql(u8, img.put.project, project)) continue;
            if (family) |fam| {
                if (std.mem.eql(u8, img.put.family, fam) and img.put.deprecated.len == 0) found = img;
            } else if (std.mem.eql(u8, img.put.name, tail)) found = img;
        }
        return found;
    }

    fn imageNotFound(arena: Allocator, project: []const u8, tail: []const u8) Allocator.Error!Reply {
        return fail(arena, 404, "notFound", try std.fmt.allocPrint(arena, "The resource 'projects/{s}/global/images/{s}' was not found", .{ project, tail }));
    }

    fn image(f: *FakeCompute, arena: Allocator, project: []const u8, tail: []const u8) Allocator.Error!Reply {
        const img = f.findImage(project, tail) orelse return imageNotFound(arena, project, tail);
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
        try f.writeDisks(jw, i);
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

    /// The boot disk, then the others in the order attached, as
    /// production listed them.
    fn writeDisks(f: *FakeCompute, jw: *Stringify, i: *FakeInstance) !void {
        const s = f.store.allocator();
        const p = f.options.project_id;
        const z = i.put.zone;
        try jw.objectField("disks");
        try jw.beginArray();
        try jw.write(.{
            .type = "PERSISTENT",
            .mode = "READ_WRITE",
            .source = try std.fmt.allocPrint(s, "{s}projects/{s}/zones/{s}/disks/{s}", .{ link_base, p, z, i.put.name }),
            .deviceName = "persistent-disk-0",
            .index = 0,
            .boot = true,
            .autoDelete = true,
            .interface = "SCSI",
            .diskSizeGb = "10",
        });
        for (i.attached.items, 1..) |d, index| {
            const size = if (f.diskFor(z, d.disk)) |disk| disk.size_gb else 10;
            try jw.write(.{
                .type = "PERSISTENT",
                .mode = if (d.read_only) "READ_ONLY" else "READ_WRITE",
                .source = try std.fmt.allocPrint(s, "{s}projects/{s}/zones/{s}/disks/{s}", .{ link_base, p, z, d.disk }),
                .deviceName = d.device_name,
                .index = index,
                .boot = false,
                .autoDelete = d.auto_delete,
                .interface = "SCSI",
                .diskSizeGb = try std.fmt.allocPrint(s, "{d}", .{size}),
            });
        }
        try jw.endArray();
    }

    fn diskFor(f: *FakeCompute, zone: []const u8, name: []const u8) ?*FakeDisk {
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}/{s}", .{ zone, name }) catch return null;
        return f.disks.getPtr(key);
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
    /// in; a standard VM's MIGRATE, and automatic restart unless it was
    /// asked for none; the provisioning model for both.
    fn writeScheduling(jw: *Stringify, i: *FakeInstance) !void {
        const spot = i.put.spot;
        try jw.objectField("scheduling");
        try jw.beginObject();
        if (i.put.max_run_duration_s) |secs| {
            try jw.objectField("maxRunDuration");
            try jw.print("{{\"seconds\":\"{d}\",\"nanos\":0}}", .{secs});
        }
        try jw.objectField("onHostMaintenance");
        try jw.write(if (i.put.on_host_maintenance) |m| (if (m == .migrate) "MIGRATE" else "TERMINATE") else if (spot) "TERMINATE" else "MIGRATE");
        try jw.objectField("automaticRestart");
        try jw.write(i.put.automatic_restart orelse !spot);
        try jw.objectField("preemptible");
        try jw.write(spot);
        try jw.objectField("provisioningModel");
        try jw.write(if (spot) "SPOT" else "STANDARD");
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
        if (wait and op.waits_left > 0) {
            op.waits_left -= 1;
            if (op.waits_left == 0) f.finish(op);
        }
        return f.operationReply(arena, op);
    }

    fn operationReply(f: *FakeCompute, arena: Allocator, op: *FakeOperation) Allocator.Error!Reply {
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        f.writeOperation(&jw, arena, op) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    // Writes.

    /// A write under `zones/<z>/instances`: an insert, a delete, or a
    /// verb on a VM. A `requestId` already seen answers its operation.
    fn write(f: *FakeCompute, req: tp.Request, arena: Allocator, tail: []const u8, params: Params) Allocator.Error!Reply {
        const rest = std.mem.cutPrefix(u8, tail, "zones/") orelse return notModelled(arena, "a write outside a zone (templates are the module's next milestones)");
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return notModelled(arena, "a write to a zone itself");
        const zone = rest[0..slash];
        if (!f.zones.contains(zone)) return unknownZone(arena, zone);
        const target = std.mem.cutPrefix(u8, rest[slash + 1 ..], "instances") orelse return notModelled(arena, "a write to this zone path (groups are the module's next milestones)");
        const request_id = params.get("requestId");
        if (request_id) |id| if (f.request_ids.get(id)) |op| return f.operationReply(arena, op);
        if (target.len == 0) {
            if (req.method != .POST) return notModelled(arena, "this method on a zone's instances");
            return f.insert(arena, zone, req.body orelse "", params, request_id);
        }
        const path = std.mem.cutPrefix(u8, target, "/") orelse return notModelled(arena, "this zone path");
        const at = std.mem.indexOfScalar(u8, path, '/');
        const name = path[0 .. at orelse path.len];
        const i = f.instanceFor(zone, name) catch return f.notFound(arena, try std.fmt.allocPrint(arena, "zones/{s}/instances/{s}", .{ zone, name }));
        if (at) |a| {
            if (req.method != .POST) return notModelled(arena, "this method on an instance's verb");
            const verb = path[a + 1 ..];
            if (changeOf(verb)) |change| return f.changeVm(arena, i, change, req.body orelse "", params, request_id);
            return f.lifecycle(arena, i, verb, request_id);
        }
        if (req.method != .DELETE) return notModelled(arena, "this method on an instance");
        return f.delete(arena, i, request_id);
    }

    /// What an insert's body or template gives the VM, or production's
    /// refusal.
    const Parsed = union(enum) { ok: PutInstance, refused: Reply };

    fn insert(f: *FakeCompute, arena: Allocator, zone: []const u8, text: []const u8, params: Params, request_id: ?[]const u8) Allocator.Error!Reply {
        const parsed = if (params.get("sourceInstanceTemplate")) |source| try f.fromTemplate(arena, source, text) else try f.fromBody(arena, zone, text);
        var put = switch (parsed) {
            .ok => |p| p,
            .refused => |r| return r,
        };
        put.zone = zone;
        put.status = .provisioning;
        f.addInstance(put) catch |err| switch (err) {
            error.AlreadyExists => return fail(arena, 409, "alreadyExists", try std.fmt.allocPrint(arena, "The resource 'projects/{s}/zones/{s}/instances/{s}' already exists", .{ f.options.project_id, zone, put.name })),
            error.OutOfMemory => return error.OutOfMemory,
            error.UnknownZone, error.NotFound => unreachable, // The zone was checked.
        };
        const out_of_room = f.stockouts.contains(zone);
        const failure = if (out_of_room) try f.stockout(zone) else null;
        const op = try f.addWriteOperation(zone, put.name, "insert", if (out_of_room) .remove else .run, failure, f.options.write_waits, request_id);
        return f.operationReply(arena, op);
    }

    /// The VM an insert's body describes, read as production reads the
    /// fields the fake keeps.
    fn fromBody(f: *FakeCompute, arena: Allocator, zone: []const u8, text: []const u8) Allocator.Error!Parsed {
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .refused = try notModelled(arena, "an insert body that is not JSON") },
        };
        if (value != .object) return .{ .refused = try notModelled(arena, "an insert body that is not an object") };
        const obj = value.object;
        const name = jsonString(obj, "name") orelse return .{ .refused = try notModelled(arena, "an insert with no name") };
        if (!validate.isName(name)) return .{ .refused = try fail(arena, 400, "invalid", try std.fmt.allocPrint(arena, "Invalid value for field 'resource.name': '{s}'. Must be a match of regex '(?:[a-z](?:[-a-z0-9]{{0,61}}[a-z0-9])?)'", .{name})) };
        const machine_path = jsonString(obj, "machineType") orelse return .{ .refused = try notModelled(arena, "an insert with no machine type") };
        const type_at = if (std.mem.lastIndexOfScalar(u8, machine_path, '/')) |s| s + 1 else 0;
        const machine_type = machine_path[type_at..];
        if (!f.machine_types.contains(try std.fmt.allocPrint(arena, "{s}/{s}", .{ zone, machine_type }))) {
            return .{ .refused = try fail(arena, 400, "invalid", try std.fmt.allocPrint(arena, "Invalid value for field 'resource.machineType': '{s}'. Machine type with name '{s}' does not exist in zone '{s}'.", .{ machine_path, machine_type, zone })) };
        }
        if (try f.bootImageRefusal(arena, obj)) |refused| return .{ .refused = refused };
        var put: PutInstance = .{ .zone = zone, .name = name, .machine_type = machine_type };
        if (try schedulingOf(arena, obj, machine_type, &put)) |refused| return .{ .refused = refused };
        put.labels = try labelsOf(arena, obj);
        put.metadata = try metadataOf(arena, obj);
        put.tags = try tagsOf(arena, obj);
        put.deletion_protection = if (obj.get("deletionProtection")) |v| v == .bool and v.bool else false;
        return .{ .ok = put };
    }

    /// Null when the boot disk's image is one the fake has.
    fn bootImageRefusal(f: *FakeCompute, arena: Allocator, obj: std.json.ObjectMap) Allocator.Error!?Reply {
        const source = bootImage(obj) orelse return try notModelled(arena, "an insert with no boot disk from an image");
        const path = trimHost(source);
        const project_path = if (std.mem.startsWith(u8, path, "global/")) try std.fmt.allocPrint(arena, "projects/{s}/{s}", .{ f.options.project_id, path }) else path;
        const rest = std.mem.cutPrefix(u8, project_path, "projects/") orelse return try notModelled(arena, "an image path the fake does not read");
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return try notModelled(arena, "an image path the fake does not read");
        const tail = std.mem.cutPrefix(u8, rest[slash..], "/global/images/") orelse return try notModelled(arena, "an image path the fake does not read");
        if (f.findImage(rest[0..slash], tail) != null) return null;
        return try imageNotFound(arena, rest[0..slash], tail);
    }

    fn bootImage(obj: std.json.ObjectMap) ?[]const u8 {
        const disks = obj.get("disks") orelse return null;
        if (disks != .array or disks.array.items.len == 0 or disks.array.items[0] != .object) return null;
        const params = disks.array.items[0].object.get("initializeParams") orelse return null;
        if (params != .object) return null;
        return jsonString(params.object, "sourceImage");
    }

    /// Spot or not, the run limit and its action into `put`; production's
    /// refusal of a standard e2 that asks for TERMINATE.
    fn schedulingOf(arena: Allocator, obj: std.json.ObjectMap, machine_type: []const u8, put: *PutInstance) Allocator.Error!?Reply {
        const v = obj.get("scheduling") orelse return null;
        if (v != .object) return null;
        const s = v.object;
        const preemptible = if (s.get("preemptible")) |p| p == .bool and p.bool else false;
        put.spot = preemptible or std.mem.eql(u8, jsonString(s, "provisioningModel") orelse "", "SPOT");
        if (s.get("maxRunDuration")) |d| if (d == .object) {
            if (d.object.get("seconds")) |secs| put.max_run_duration_s = switch (secs) {
                .string => |t| std.fmt.parseInt(u64, t, 10) catch null,
                .integer => |n| std.math.cast(u64, n),
                else => null,
            };
        };
        if (jsonString(s, "instanceTerminationAction")) |t| put.termination_action = types.TerminationAction.parse(t);
        if (s.get("automaticRestart")) |r| if (r == .bool) {
            put.automatic_restart = r.bool;
        };
        const terminate = std.mem.eql(u8, jsonString(s, "onHostMaintenance") orelse "", "TERMINATE");
        if (terminate and !put.spot and std.mem.startsWith(u8, machine_type, "e2-")) {
            return try fail(arena, 400, "badRequest", "e2 instances do not support onHostMaintenance=TERMINATE unless they are preemptible.");
        }
        return null;
    }

    fn labelsOf(arena: Allocator, obj: std.json.ObjectMap) Allocator.Error![]const types.Label {
        const v = obj.get("labels") orelse return &.{};
        if (v != .object) return &.{};
        var out: std.ArrayList(types.Label) = .empty;
        var it = v.object.iterator();
        while (it.next()) |e| if (e.value_ptr.* == .string) try out.append(arena, .{ .key = e.key_ptr.*, .value = e.value_ptr.string });
        return out.items;
    }

    fn metadataOf(arena: Allocator, obj: std.json.ObjectMap) Allocator.Error![]const types.MetadataItem {
        const items = itemsOf(obj, "metadata") orelse return &.{};
        var out: std.ArrayList(types.MetadataItem) = .empty;
        for (items) |item| if (item == .object) {
            const key = jsonString(item.object, "key") orelse continue;
            try out.append(arena, .{ .key = key, .value = jsonString(item.object, "value") });
        };
        return out.items;
    }

    fn tagsOf(arena: Allocator, obj: std.json.ObjectMap) Allocator.Error![]const []const u8 {
        const items = itemsOf(obj, "tags") orelse return &.{};
        var out: std.ArrayList([]const u8) = .empty;
        for (items) |item| if (item == .string) try out.append(arena, item.string);
        return out.items;
    }

    /// `obj.<name>.items`, an array.
    fn itemsOf(obj: std.json.ObjectMap, name: []const u8) ?[]const std.json.Value {
        const v = obj.get(name) orelse return null;
        if (v != .object) return null;
        const items = v.object.get("items") orelse return null;
        return if (items == .array) items.array.items else null;
    }

    fn jsonString(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
        const v = obj.get(name) orelse return null;
        return if (v == .string) v.string else null;
    }

    /// A path as the fake reads one: a URL's host and `/compute/v1/` cut.
    fn trimHost(path: []const u8) []const u8 {
        const at = std.mem.indexOf(u8, path, "/compute/v1/") orelse return path;
        return path[at + "/compute/v1/".len ..];
    }

    /// The VM a template gives, named as the insert's body says.
    fn fromTemplate(f: *FakeCompute, arena: Allocator, source: []const u8, text: []const u8) Allocator.Error!Parsed {
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .refused = try notModelled(arena, "an insert body that is not JSON") },
        };
        const name = if (value == .object) jsonString(value.object, "name") else null;
        const n = name orelse return .{ .refused = try notModelled(arena, "an insert from a template with no name") };
        if (!validate.isName(n)) return .{ .refused = try fail(arena, 400, "invalid", try std.fmt.allocPrint(arena, "Invalid value for field 'resource.name': '{s}'. Must be a match of regex '(?:[a-z](?:[-a-z0-9]{{0,61}}[a-z0-9])?)'", .{n})) };
        const path = trimHost(source);
        const own = try std.fmt.allocPrint(arena, "projects/{s}/", .{f.options.project_id});
        const local = std.mem.cutPrefix(u8, path, own) orelse path;
        // `global/instanceTemplates/T` is kept as `global/T`, and
        // `regions/R/instanceTemplates/T` as `regions/R/T`.
        const key = if (std.mem.cutPrefix(u8, local, "global/instanceTemplates/")) |t|
            try std.fmt.allocPrint(arena, "global/{s}", .{t})
        else if (std.mem.startsWith(u8, local, "regions/"))
            try std.mem.replaceOwned(u8, arena, local, "/instanceTemplates/", "/")
        else
            return .{ .refused = try notModelled(arena, "a template path the fake does not read") };
        const t = f.templates.get(key) orelse return .{ .refused = try f.notFound(arena, local) };
        var put = t;
        put.name = n;
        return .{ .ok = put };
    }

    /// How each verb moves a VM: from the states production took it in,
    /// through `during`, to the effect when its operation finishes.
    const Transition = struct {
        verb: []const u8,
        from: []const types.Status,
        /// Null leaves the status as it is.
        during: ?types.Status,
        effect: Effect,
        /// DONE from the start, as a start of a running VM answered.
        at_once: bool = false,
    };

    const transitions = [_]Transition{
        .{ .verb = "start", .from = &.{ .terminated, .stopped }, .during = .staging, .effect = .run },
        .{ .verb = "start", .from = &.{.running}, .during = null, .effect = .none, .at_once = true },
        .{ .verb = "stop", .from = &.{ .running, .staging, .provisioning }, .during = .stopping, .effect = .terminate },
        .{ .verb = "stop", .from = &.{ .terminated, .stopped }, .during = null, .effect = .none },
        .{ .verb = "suspend", .from = &.{.running}, .during = .suspending, .effect = .suspend_vm },
        .{ .verb = "resume", .from = &.{.suspended}, .during = .staging, .effect = .run },
        .{ .verb = "reset", .from = &.{.running}, .during = null, .effect = .none },
    };

    fn lifecycle(f: *FakeCompute, arena: Allocator, i: *FakeInstance, verb: []const u8, request_id: ?[]const u8) Allocator.Error!Reply {
        var known = false;
        const step: Transition = for (transitions) |t| {
            if (!std.mem.eql(u8, t.verb, verb)) continue;
            known = true;
            if (std.mem.indexOfScalar(types.Status, t.from, i.put.status) != null) break t;
        } else {
            if (!known) return notModelled(arena, "this instance verb");
            return notModelled(arena, try std.fmt.allocPrint(arena, "{s} on a VM that is {s}", .{ verb, statusName(i.put.status) }));
        };
        const out_of_room = step.effect == .run and std.mem.eql(u8, verb, "start") and f.stockouts.contains(i.put.zone);
        if (step.during) |s| i.put.status = s;
        const waits: u32 = if (step.at_once) 0 else f.options.write_waits;
        const failure = if (out_of_room) try f.stockout(i.put.zone) else null;
        const op = try f.addWriteOperation(i.put.zone, i.put.name, verb, if (out_of_room) .terminate else step.effect, failure, waits, request_id);
        return f.operationReply(arena, op);
    }

    fn stockout(f: *FakeCompute, zone: []const u8) Allocator.Error!PutOperation.Failure {
        return .{
            .code = "ZONE_RESOURCE_POOL_EXHAUSTED",
            .message = try std.fmt.allocPrint(f.store.allocator(), "The zone 'projects/{s}/zones/{s}' does not have enough resources available to fulfill the request.  Try a different zone, or try again later.", .{ f.options.project_id, zone }),
            .http_status = 503,
        };
    }

    // Changes to a live VM.

    const Change = enum { labels, metadata, tags, machine_type, scheduling, protection, attach, detach };

    fn changeOf(verb: []const u8) ?Change {
        const verbs = [_]struct { []const u8, Change }{
            .{ "setLabels", .labels },
            .{ "setMetadata", .metadata },
            .{ "setTags", .tags },
            .{ "setMachineType", .machine_type },
            .{ "setScheduling", .scheduling },
            .{ "setDeletionProtection", .protection },
            .{ "attachDisk", .attach },
            .{ "detachDisk", .detach },
        };
        for (verbs) |v| if (std.mem.eql(u8, v[0], verb)) return v[1];
        return null;
    }

    /// A change, made at once as production showed a label change at
    /// once, and its operation: DONE after `Options.write_waits` waits, at
    /// once for deletion protection, failed where production failed one.
    fn changeVm(f: *FakeCompute, arena: Allocator, i: *FakeInstance, change: Change, text: []const u8, params: Params, request_id: ?[]const u8) Allocator.Error!Reply {
        const obj: std.json.ObjectMap = if (change == .protection or change == .detach) .empty else blk: {
            const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return notModelled(arena, "a change whose body is not JSON"),
            };
            if (value != .object) return notModelled(arena, "a change whose body is not an object");
            break :blk value.object;
        };
        const outcome = switch (change) {
            .labels => try f.setLabels(arena, i, obj),
            .metadata => try f.setMetadata(arena, i, obj),
            .tags => try f.setTags(arena, i, obj),
            .machine_type => try f.setMachineType(arena, i, obj),
            .scheduling => try f.setScheduling(arena, i, obj),
            .protection => try f.setProtection(i, params),
            .attach => try f.attach(arena, i, obj),
            .detach => try f.detach(arena, i, params),
        };
        const taken = switch (outcome) {
            .refused => |r| return r,
            .taken => |t| t,
        };
        i.fingerprint = try f.fingerprint();
        const waits: u32 = if (change == .protection) 0 else f.options.write_waits;
        const op = try f.addWriteOperation(i.put.zone, i.put.name, taken.operation_type, .none, taken.failure, waits, request_id);
        return f.operationReply(arena, op);
    }

    const Outcome = union(enum) {
        /// Refused at once.
        refused: Reply,
        /// Taken: the operation's type, and its failure when it fails.
        taken: struct { operation_type: []const u8, failure: ?PutOperation.Failure = null },
    };

    fn conditionNotMet(arena: Allocator, message: []const u8) Allocator.Error!Outcome {
        return .{ .refused = try fail(arena, 412, "conditionNotMet", message) };
    }

    fn setLabels(f: *FakeCompute, arena: Allocator, i: *FakeInstance, obj: std.json.ObjectMap) Allocator.Error!Outcome {
        const fp = jsonString(obj, "labelFingerprint") orelse "";
        if (!std.mem.eql(u8, fp, i.label_fingerprint)) return conditionNotMet(arena, "Labels fingerprint either invalid or resource labels have changed");
        const s = f.store.allocator();
        const labels = try labelsOf(arena, obj);
        const kept = try s.alloc(types.Label, labels.len);
        for (labels, kept) |l, *o| o.* = .{ .key = try s.dupe(u8, l.key), .value = try s.dupe(u8, l.value) };
        i.put.labels = kept;
        i.label_fingerprint = try f.fingerprint();
        return .{ .taken = .{ .operation_type = "compute.instance.setLabels" } };
    }

    fn setMetadata(f: *FakeCompute, arena: Allocator, i: *FakeInstance, obj: std.json.ObjectMap) Allocator.Error!Outcome {
        const fp = jsonString(obj, "fingerprint") orelse "";
        if (!std.mem.eql(u8, fp, i.metadata_fingerprint)) return conditionNotMet(arena, "Supplied fingerprint does not match current metadata fingerprint.");
        const s = f.store.allocator();
        var items: std.ArrayList(types.MetadataItem) = .empty;
        if (obj.get("items")) |list| if (list == .array) for (list.array.items) |item| {
            if (item != .object) continue;
            const key = jsonString(item.object, "key") orelse continue;
            const value = jsonString(item.object, "value");
            try items.append(s, .{ .key = try s.dupe(u8, key), .value = if (value) |v| try s.dupe(u8, v) else null });
        };
        i.put.metadata = items.items;
        i.metadata_fingerprint = try f.fingerprint();
        return .{ .taken = .{ .operation_type = "setMetadata" } };
    }

    fn setTags(f: *FakeCompute, arena: Allocator, i: *FakeInstance, obj: std.json.ObjectMap) Allocator.Error!Outcome {
        const fp = jsonString(obj, "fingerprint") orelse "";
        if (!std.mem.eql(u8, fp, i.tags_fingerprint)) return conditionNotMet(arena, "Tags fingerprint either invalid or resource tags have changed.");
        const s = f.store.allocator();
        var tags: std.ArrayList([]const u8) = .empty;
        if (obj.get("items")) |list| if (list == .array) for (list.array.items) |item| {
            if (item == .string) try tags.append(s, try s.dupe(u8, item.string));
        };
        i.put.tags = tags.items;
        i.tags_fingerprint = try f.fingerprint();
        return .{ .taken = .{ .operation_type = "setTags" } };
    }

    fn setMachineType(f: *FakeCompute, arena: Allocator, i: *FakeInstance, obj: std.json.ObjectMap) Allocator.Error!Outcome {
        const path = jsonString(obj, "machineType") orelse return .{ .refused = try notModelled(arena, "a machine type change with none") };
        const at = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| s + 1 else 0;
        const machine_type = path[at..];
        const z = i.put.zone;
        if (!f.machine_types.contains(try std.fmt.allocPrint(arena, "{s}/{s}", .{ z, machine_type }))) {
            return .{ .refused = try fail(arena, 400, "invalid", try std.fmt.allocPrint(arena, "Invalid value for field 'machineType': '{s}'. Machine type with name '{s}' does not exist in zone '{s}'.", .{ path, machine_type, z })) };
        }
        switch (i.put.status) {
            .terminated, .stopped => i.put.machine_type = try f.store.allocator().dupe(u8, machine_type),
            .suspended, .suspending => return .{ .refused = try notModelled(arena, "a machine type change to a suspended VM") },
            else => return .{ .taken = .{
                .operation_type = "setMachineType",
                .failure = .{ .code = "UNSUPPORTED_OPERATION", .message = "Instance is starting or running." },
            } },
        }
        return .{ .taken = .{ .operation_type = "setMachineType" } };
    }

    fn setScheduling(f: *FakeCompute, arena: Allocator, i: *FakeInstance, obj: std.json.ObjectMap) Allocator.Error!Outcome {
        _ = f;
        const model = jsonString(obj, "provisioningModel");
        const preemptible = if (obj.get("preemptible")) |p| p == .bool and p.bool else i.put.spot;
        if (model != null and std.mem.eql(u8, model.?, "STANDARD") and preemptible) {
            return .{ .refused = try fail(arena, 400, "invalid", "Invalid value for field 'resource.provisioningModel': 'STANDARD'. For preemptible, only allowed provisioning_model value is SPOT.") };
        }
        if (model != null and std.mem.eql(u8, model.?, "SPOT") and !preemptible) {
            return .{ .refused = try fail(arena, 400, "invalid", "Invalid value for field 'resource.provisioningModel': 'SPOT'. preemptible=false and provisioning_model=SPOT is contradicting.") };
        }
        const limit = runLimitOf(obj);
        const stopped = i.put.status == .terminated or i.put.status == .stopped;
        if (!stopped) {
            if (i.put.max_run_duration_s == null) return .{ .refused = try notModelled(arena, "a scheduling change to a running VM with no run limit") };
            if (limit != null and limit != i.put.max_run_duration_s) return .{ .refused = try fail(arena, 400, "badRequest", "Max run duration cannot be changed while the instance is running.") };
            return .{ .refused = try fail(arena, 400, "badRequest", "Termination time cannot be changed while the instance is running.") };
        }
        if (model) |m| i.put.spot = std.mem.eql(u8, m, "SPOT");
        if (obj.get("automaticRestart")) |r| if (r == .bool) {
            i.put.automatic_restart = r.bool;
        };
        if (jsonString(obj, "onHostMaintenance")) |m| i.put.on_host_maintenance = if (std.mem.eql(u8, m, "MIGRATE")) .migrate else .terminate;
        if (jsonString(obj, "instanceTerminationAction")) |t| i.put.termination_action = types.TerminationAction.parse(t);
        if (limit) |l| i.put.max_run_duration_s = l;
        return .{ .taken = .{ .operation_type = "setScheduling" } };
    }

    fn runLimitOf(obj: std.json.ObjectMap) ?u64 {
        const d = obj.get("maxRunDuration") orelse return null;
        if (d != .object) return null;
        const secs = d.object.get("seconds") orelse return null;
        return switch (secs) {
            .string => |t| std.fmt.parseInt(u64, t, 10) catch null,
            .integer => |n| std.math.cast(u64, n),
            else => null,
        };
    }

    /// `deletionProtection` true unless it says false: the API's default.
    fn setProtection(f: *FakeCompute, i: *FakeInstance, params: Params) Allocator.Error!Outcome {
        _ = f;
        i.put.deletion_protection = !std.mem.eql(u8, params.get("deletionProtection") orelse "true", "false");
        return .{ .taken = .{ .operation_type = "setDeletionProtection" } };
    }

    fn attach(f: *FakeCompute, arena: Allocator, i: *FakeInstance, obj: std.json.ObjectMap) Allocator.Error!Outcome {
        const source = trimHost(jsonString(obj, "source") orelse return .{ .refused = try notModelled(arena, "an attach with no source disk") });
        const own = try std.fmt.allocPrint(arena, "projects/{s}/", .{f.options.project_id});
        const local = std.mem.cutPrefix(u8, source, own) orelse source;
        const z = i.put.zone;
        const prefix = try std.fmt.allocPrint(arena, "zones/{s}/disks/", .{z});
        const name = std.mem.cutPrefix(u8, local, prefix) orelse return .{ .refused = try notModelled(arena, "an attach of a disk outside the VM's zone or project") };
        const disk = f.diskFor(z, name) orelse return .{ .refused = try f.notFound(arena, local) };
        if (disk.user) |user| return .{ .taken = .{
            .operation_type = "attachDisk",
            .failure = .{
                .code = "RESOURCE_IN_USE_BY_ANOTHER_RESOURCE",
                .message = try std.fmt.allocPrint(f.store.allocator(), "The disk resource 'projects/{s}/zones/{s}/disks/{s}' is already being used by 'projects/{s}/zones/{s}/instances/{s}'", .{ f.options.project_id, z, name, f.options.project_id, z, user }),
            },
        } };
        const s = f.store.allocator();
        const device = jsonString(obj, "deviceName") orelse try std.fmt.allocPrint(arena, "persistent-disk-{d}", .{i.attached.items.len + 1});
        for (i.attached.items) |a| if (std.mem.eql(u8, a.device_name, device)) return .{ .refused = try notModelled(arena, "an attach under a device name the VM has") };
        try i.attached.append(f.gpa, .{
            .device_name = try s.dupe(u8, device),
            .disk = try s.dupe(u8, name),
            .read_only = std.mem.eql(u8, jsonString(obj, "mode") orelse "READ_WRITE", "READ_ONLY"),
            .auto_delete = if (obj.get("autoDelete")) |v| v == .bool and v.bool else false,
        });
        disk.user = i.put.name;
        return .{ .taken = .{ .operation_type = "attachDisk" } };
    }

    fn detach(f: *FakeCompute, arena: Allocator, i: *FakeInstance, params: Params) Allocator.Error!Outcome {
        const device = params.get("deviceName") orelse return .{ .refused = try notModelled(arena, "a detach with no device name") };
        if (std.mem.eql(u8, device, "persistent-disk-0")) return .{ .refused = try notModelled(arena, "detaching a boot disk") };
        for (i.attached.items, 0..) |a, n| {
            if (!std.mem.eql(u8, a.device_name, device)) continue;
            if (f.diskFor(i.put.zone, a.disk)) |disk| disk.user = null;
            _ = i.attached.orderedRemove(n);
            return .{ .taken = .{ .operation_type = "detachDisk" } };
        }
        return .{ .taken = .{
            .operation_type = "detachDisk",
            .failure = .{ .code = "INVALID_USAGE", .message = try std.fmt.allocPrint(f.store.allocator(), "No attached disk found with device name '{s}'", .{device}) },
        } };
    }

    fn delete(f: *FakeCompute, arena: Allocator, i: *FakeInstance, request_id: ?[]const u8) Allocator.Error!Reply {
        if (i.put.deletion_protection) return fail(arena, 400, "invalidResourceUsage", "Invalid resource usage: 'Resource cannot be deleted if it's protected against deletion.'.");
        i.put.status = .stopping;
        const op = try f.addWriteOperation(i.put.zone, i.put.name, "delete", .remove, null, f.options.write_waits, request_id);
        return f.operationReply(arena, op);
    }

    /// A write's operation on the VM `name`, kept under its `requestId`;
    /// finished at once when `waits` is 0.
    fn addWriteOperation(f: *FakeCompute, zone: []const u8, name: []const u8, operation_type: []const u8, effect: Effect, failure: ?PutOperation.Failure, waits: u32, request_id: ?[]const u8) Allocator.Error!*FakeOperation {
        const s = f.store.allocator();
        const op_name = try std.fmt.allocPrint(s, "operation-{d}", .{f.next()});
        const op = try s.create(FakeOperation);
        op.* = .{
            .name = op_name,
            .put = .{
                .scope = .{ .zone = try s.dupe(u8, zone) },
                .operation_type = try s.dupe(u8, operation_type),
                .target_instance = try s.dupe(u8, name),
                .waits_to_finish = waits,
                .failure = failure,
                .client_operation_id = try s.dupe(u8, request_id orelse ""),
            },
            .id = f.next(),
            .inserted = std.Io.Clock.real.now(f.io),
            .waits_left = waits,
            .effect = effect,
        };
        try f.operations.put(f.gpa, try std.fmt.allocPrint(s, "zones/{s}/{s}", .{ zone, op_name }), op);
        if (request_id) |id| try f.request_ids.put(f.gpa, try s.dupe(u8, id), op);
        if (waits == 0) f.finish(op);
        return op;
    }

    /// Does what a finished operation does to its VM, once.
    fn finish(f: *FakeCompute, op: *FakeOperation) void {
        const effect = op.effect;
        op.effect = .none;
        const name = op.put.target_instance orelse return;
        if (effect == .none or op.put.scope != .zone) return;
        const zone = op.put.scope.zone;
        const i = f.instanceFor(zone, name) catch return;
        switch (effect) {
            .none => {},
            .run => i.put.status = .running,
            .terminate => i.put.status = .terminated,
            .suspend_vm => i.put.status = .suspended,
            .remove => f.removeInstance(i),
        }
    }

    /// A VM deleted: its boot disk with it, its other disks freed or, when
    /// they auto-delete, deleted too.
    fn removeInstance(f: *FakeCompute, i: *FakeInstance) void {
        const zone = i.put.zone;
        var buf: [256]u8 = undefined;
        for (i.attached.items) |a| {
            const key = std.fmt.bufPrint(&buf, "{s}/{s}", .{ zone, a.disk }) catch continue;
            if (a.auto_delete) {
                _ = f.disks.orderedRemove(key);
            } else if (f.disks.getPtr(key)) |d| d.user = null;
        }
        const key = std.fmt.bufPrint(&buf, "{s}/{s}", .{ zone, i.put.name }) catch return;
        _ = f.disks.orderedRemove(key);
        i.serial.deinit(f.gpa);
        i.guest.deinit(f.gpa);
        i.attached.deinit(f.gpa);
        _ = f.instances.orderedRemove(key);
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
        try jw.write(switch (failure.http_status) {
            400 => "BAD REQUEST",
            503 => "SERVICE UNAVAILABLE",
            else => "ERROR",
        });
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

    fn unknownZone(arena: Allocator, zone: []const u8) Allocator.Error!Reply {
        return fail(arena, 400, "invalid", try std.fmt.allocPrint(arena, "Invalid value for field 'zone': '{s}'. Unknown zone.", .{zone}));
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
