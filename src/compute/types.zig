//! What the client's calls answer. Each keeps what managing a VM needs and
//! leaves the rest of Compute's large schemas out. Strings and slices live
//! in the `Owned` arena they come in.

const std = @import("std");
const core = @import("core");
const Timestamp = std.Io.Timestamp;

pub const Owned = core.Owned;

/// A key and its value, as a map's entries are kept, in the server's
/// order.
pub const Label = struct {
    key: []const u8,
    value: []const u8,
};

/// Where a VM stands. A VM a caller stopped reads `terminated`, not
/// `stopped`: production answered TERMINATED after a stop and after a
/// guest powered itself off (measured 2026-11-03).
pub const Status = enum {
    provisioning,
    staging,
    running,
    stopping,
    stopped,
    suspending,
    suspended,
    terminated,
    repairing,
    pending,
    pending_stop,
    deprovisioning,
    /// A value this library does not know.
    unknown,

    pub fn parse(text: []const u8) Status {
        const table = .{
            .{ "PROVISIONING", Status.provisioning }, .{ "STAGING", Status.staging },
            .{ "RUNNING", Status.running },           .{ "STOPPING", Status.stopping },
            .{ "STOPPED", Status.stopped },           .{ "SUSPENDING", Status.suspending },
            .{ "SUSPENDED", Status.suspended },       .{ "TERMINATED", Status.terminated },
            .{ "REPAIRING", Status.repairing },       .{ "PENDING", Status.pending },
            .{ "PENDING_STOP", Status.pending_stop }, .{ "DEPROVISIONING", Status.deprovisioning },
        };
        inline for (table) |entry| if (std.mem.eql(u8, text, entry[0])) return entry[1];
        return .unknown;
    }
};

/// One metadata entry. A startup script is one, keyed `startup-script`.
pub const MetadataItem = struct {
    key: []const u8,
    /// Null when the server sent none.
    value: ?[]const u8 = null,
};

/// A VM's metadata and the fingerprint a change to it must send back.
pub const Metadata = struct {
    fingerprint: []const u8 = "",
    items: []const MetadataItem = &.{},
};

/// A VM's network tags and the fingerprint a change to them must send
/// back.
pub const Tags = struct {
    fingerprint: []const u8 = "",
    items: []const []const u8 = &.{},
};

/// A disk attached to a VM.
pub const AttachedDisk = struct {
    /// Such as "persistent-disk-0".
    device_name: []const u8 = "",
    /// The disk's URL; empty for a local SSD.
    source: []const u8 = "",
    boot: bool = false,
    auto_delete: bool = false,
    /// "READ_WRITE" or "READ_ONLY".
    mode: []const u8 = "",
    /// "PERSISTENT" or "SCRATCH".
    type: []const u8 = "",
    /// "SCSI" or "NVME".
    interface: []const u8 = "",
    size_gb: ?u64 = null,
    index: ?u32 = null,
};

/// How a network interface is reached from outside, if it is.
pub const AccessConfig = struct {
    name: []const u8 = "",
    /// "ONE_TO_ONE_NAT", say.
    type: []const u8 = "",
    /// The external address; empty when none is assigned yet.
    nat_ip: []const u8 = "",
};

/// A VM's network interface.
pub const NetworkInterface = struct {
    /// Such as "nic0".
    name: []const u8 = "",
    /// The network's URL.
    network: []const u8 = "",
    /// The subnetwork's URL.
    subnetwork: []const u8 = "",
    /// The internal address, `networkIP`.
    internal_ip: []const u8 = "",
    access_configs: []const AccessConfig = &.{},
};

/// A service account a VM acts as, and the scopes its tokens carry.
pub const ServiceAccount = struct {
    email: []const u8,
    scopes: []const []const u8 = &.{},
};

/// How a VM was bought.
pub const ProvisioningModel = enum {
    standard,
    spot,
    flex_start,
    reservation_bound,
    unknown,

    pub fn parse(text: []const u8) ProvisioningModel {
        if (std.mem.eql(u8, text, "STANDARD")) return .standard;
        if (std.mem.eql(u8, text, "SPOT")) return .spot;
        if (std.mem.eql(u8, text, "FLEX_START")) return .flex_start;
        if (std.mem.eql(u8, text, "RESERVATION_BOUND")) return .reservation_bound;
        return .unknown;
    }
};

/// What happens to a VM at its run limit, or when a spot VM is taken
/// back.
pub const TerminationAction = enum {
    stop,
    delete,
    unknown,

    pub fn parse(text: []const u8) ?TerminationAction {
        if (std.mem.eql(u8, text, "STOP")) return .stop;
        if (std.mem.eql(u8, text, "DELETE")) return .delete;
        if (std.mem.eql(u8, text, "INSTANCE_TERMINATION_ACTION_UNSPECIFIED")) return null;
        return .unknown;
    }
};

/// How a VM is scheduled. Production fills in `on_host_maintenance`
/// TERMINATE and `preemptible` true for a spot VM on its own (measured
/// 2026-11-03).
pub const Scheduling = struct {
    /// Production wrote STANDARD or SPOT for every VM measured; none is
    /// read as the API's default, `.standard`.
    provisioning_model: ProvisioningModel = .standard,
    preemptible: bool = false,
    /// Null when the server sent none (it means true).
    automatic_restart: ?bool = null,
    /// "MIGRATE" or "TERMINATE"; empty when the server sent none.
    on_host_maintenance: []const u8 = "",
    /// The run limit, in seconds.
    max_run_duration_s: ?u64 = null,
    termination_action: ?TerminationAction = null,
    /// When a run limit ends the VM: `resourceStatus.scheduling`'s, or the
    /// `terminationTime` the VM was given.
    termination_time: ?Timestamp = null,
};

/// A VM.
pub const Instance = struct {
    /// A 64-bit number, kept as the server writes it.
    id: []const u8 = "",
    name: []const u8,
    /// The zone's id, `us-central1-a`, from its URL.
    zone: []const u8 = "",
    /// The machine type's name, `e2-micro`, from its URL.
    machine_type: []const u8 = "",
    status: Status = .unknown,
    status_message: []const u8 = "",
    creation_time: ?Timestamp = null,
    last_start_time: ?Timestamp = null,
    last_stop_time: ?Timestamp = null,
    last_suspended_time: ?Timestamp = null,
    labels: []const Label = &.{},
    /// What `setLabels` must send back.
    label_fingerprint: []const u8 = "",
    metadata: Metadata = .{},
    tags: Tags = .{},
    disks: []const AttachedDisk = &.{},
    network_interfaces: []const NetworkInterface = &.{},
    service_accounts: []const ServiceAccount = &.{},
    scheduling: Scheduling = .{},
    deletion_protection: bool = false,
    /// The whole VM's fingerprint, what an update must send back.
    fingerprint: []const u8 = "",
    /// Such as "AMD Rome"; empty until the VM has run.
    cpu_platform: []const u8 = "",
    hostname: []const u8 = "",
    self_link: []const u8 = "",

    /// Running now.
    pub fn running(self: Instance) bool {
        return self.status == .running;
    }

    /// Stopped by a caller, or by its guest, or at a run limit with STOP:
    /// production reports all of these TERMINATED.
    pub fn stopped(self: Instance) bool {
        return self.status == .terminated or self.status == .stopped;
    }

    /// The value of label `key`, or null.
    pub fn label(self: Instance, key: []const u8) ?[]const u8 {
        for (self.labels) |l| if (std.mem.eql(u8, l.key, key)) return l.value;
        return null;
    }

    /// The value of metadata `key`, or null when it is absent or has
    /// none.
    pub fn metadataValue(self: Instance, key: []const u8) ?[]const u8 {
        for (self.metadata.items) |item| if (std.mem.eql(u8, item.key, key)) return item.value;
        return null;
    }
};

/// The options every list takes.
pub const ListOptions = struct {
    /// Compute's own filter syntax, sent as written: `labels.env = prod`,
    /// `name = "web-.*"`, `status = RUNNING`. Production refuses a filter
    /// and an order together, so the client does too.
    filter: ?[]const u8 = null,
    /// `name` or `creationTimestamp desc`, the only two production takes.
    order_by: ?[]const u8 = null,
    /// 0 for the server's default, 500, which is also the largest.
    max_results: u32 = 0,
    page_token: ?[]const u8 = null,
    /// Answer what can be answered when part of the list cannot be read,
    /// rather than failing the whole call (`returnPartialSuccess`).
    partial_success: bool = false,
};

pub const InstancePage = struct {
    instances: []const Instance,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
};

/// A scope (a zone, a region) an aggregated list could not answer for, or
/// warned about.
pub const ScopeWarning = struct {
    /// Such as "zones/us-central1-b".
    scope: []const u8,
    /// Such as "UNREACHABLE".
    code: []const u8,
    message: []const u8 = "",
};

/// One page of the VMs in every zone. Production answers every zone it
/// has, those with nothing in them with a warning, NO_RESULTS_ON_PAGE
/// (131 of 132 on 2026-11-03); those are left out here, and every other
/// warning kept.
pub const AggregatedInstancePage = struct {
    /// Each with its `zone`.
    instances: []const Instance,
    warnings: []const ScopeWarning = &.{},
    /// Scopes production says it could not reach.
    unreachables: []const []const u8 = &.{},
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
};

/// Which part of a serial console to read.
pub const SerialOptions = struct {
    /// 1 to 4.
    port: u8 = 1,
    /// A byte offset, as `SerialOutput.next` gives. Null for the newest
    /// megabyte; an offset older than what the VM still keeps is moved up
    /// to the oldest byte kept, as production does.
    start: ?u64 = null,
};

/// A stretch of a serial console. Production answers at most 1 MiB at a
/// time; with no `start`, the newest.
pub const SerialOutput = struct {
    contents: []const u8,
    /// Where `contents` begins, as a byte offset into everything the port
    /// has written.
    start: u64,
    /// Where the next read should begin; equal to `start` with no bytes
    /// when there is nothing new.
    next: u64,
};

/// One guest attribute a VM's guest wrote.
pub const GuestAttribute = struct {
    namespace: []const u8,
    key: []const u8,
    value: []const u8,
};

/// The guest attributes under a query path.
pub const GuestAttributes = struct {
    query_path: []const u8,
    attributes: []const GuestAttribute,
};

/// A zone.
pub const Zone = struct {
    name: []const u8,
    /// The region's id, from its URL.
    region: []const u8 = "",
    /// "UP" or "DOWN".
    status: []const u8 = "",
    description: []const u8 = "",
    available_cpu_platforms: []const []const u8 = &.{},
};

pub const ZonePage = struct {
    zones: []const Zone,
    next_page_token: ?[]const u8 = null,
};

/// A machine type in a zone.
pub const MachineType = struct {
    name: []const u8,
    zone: []const u8 = "",
    description: []const u8 = "",
    guest_cpus: u32 = 0,
    memory_mb: u64 = 0,
    /// A shared core, as e2-micro's.
    shared_cpu: bool = false,
    maximum_persistent_disks: u32 = 0,
};

pub const MachineTypePage = struct {
    machine_types: []const MachineType,
    next_page_token: ?[]const u8 = null,
};

/// A disk image.
pub const Image = struct {
    name: []const u8,
    /// The project it lives in, from its URL.
    project: []const u8 = "",
    family: []const u8 = "",
    /// "READY", say.
    status: []const u8 = "",
    description: []const u8 = "",
    disk_size_gb: ?u64 = null,
    /// "X86_64" or "ARM64"; empty when the server sent none.
    architecture: []const u8 = "",
    /// "DEPRECATED", "OBSOLETE" or "DELETED"; empty for an active image.
    deprecated: []const u8 = "",
    creation_time: ?Timestamp = null,
    self_link: []const u8 = "",
};

/// Where an operation lives, which says how to read it again.
pub const OperationScope = union(enum) {
    /// A zone's id: a VM's operations.
    zone: []const u8,
    /// A region's id.
    region: []const u8,
    /// Templates' and other global resources' operations.
    global,
};

/// What `Client.getOperation` and `Client.waitOperation` take.
pub const OperationRef = struct {
    name: []const u8,
    scope: OperationScope,
};

pub const OperationStatus = enum {
    pending,
    running,
    done,
    unknown,

    pub fn parse(text: []const u8) OperationStatus {
        if (std.mem.eql(u8, text, "PENDING")) return .pending;
        if (std.mem.eql(u8, text, "RUNNING")) return .running;
        if (std.mem.eql(u8, text, "DONE")) return .done;
        return .unknown;
    }
};

/// Compute's own long-running operation, which every write answers at
/// once. A write that failed while acting succeeds as a call and ends
/// DONE with `failure` set: setting a running VM's machine type
/// (UNSUPPORTED_OPERATION, "Instance is starting or running."), deleting
/// a template a group uses (RESOURCE_IN_USE_BY_ANOTHER_RESOURCE), all
/// measured 2026-11-03.
pub const Operation = struct {
    name: []const u8,
    scope: OperationScope,
    status: OperationStatus = .unknown,
    /// 0 to 100.
    progress: u8 = 0,
    /// Such as "insert", "stop", "compute.instance.setLabels" or
    /// "compute.instances.preempted": production's names are not one
    /// vocabulary, so this stays a string.
    operation_type: []const u8 = "",
    /// What it acts on, as a path from `projects/` on: production's links
    /// name the `www.googleapis.com` host rather than the one a client
    /// calls, so only the path is kept.
    target: []const u8 = "",
    target_id: []const u8 = "",
    /// Who started it: an account, or "system" for what Compute did on
    /// its own (a preemption, a run limit, a guest's power-off).
    user: []const u8 = "",
    /// The write's `requestId`, when it had one.
    client_operation_id: []const u8 = "",
    insert_time: ?Timestamp = null,
    start_time: ?Timestamp = null,
    end_time: ?Timestamp = null,
    /// Set when the operation is done and failed.
    failure: ?Failure = null,
    warnings: []const Warning = &.{},

    pub const Failure = struct {
        errors: []const Item,
        /// The HTTP status the failure would have had (`httpErrorStatusCode`).
        http_status: ?u16 = null,

        pub const Item = struct {
            /// Such as "UNSUPPORTED_OPERATION" or
            /// "ZONE_RESOURCE_POOL_EXHAUSTED".
            code: []const u8,
            message: []const u8 = "",
            location: []const u8 = "",
        };

        /// The first error's code.
        pub fn code(self: Failure) []const u8 {
            return if (self.errors.len > 0) self.errors[0].code else "";
        }

        /// The first error's message.
        pub fn message(self: Failure) []const u8 {
            return if (self.errors.len > 0) self.errors[0].message else "";
        }

        /// The zone had no room for what was asked: worth asking another
        /// zone, which is the caller's choice to make.
        pub fn stockout(self: Failure) bool {
            for (self.errors) |e| {
                if (std.mem.startsWith(u8, e.code, "ZONE_RESOURCE_POOL_EXHAUSTED")) return true;
                if (std.mem.indexOf(u8, e.message, "does not have enough resources") != null) return true;
            }
            return false;
        }
    };

    pub const Warning = struct {
        code: []const u8,
        message: []const u8 = "",
    };

    pub fn done(self: Operation) bool {
        return self.status == .done;
    }

    /// Done, and not failed.
    pub fn succeeded(self: Operation) bool {
        return self.status == .done and self.failure == null;
    }

    /// What `Client.getOperation` and `Client.waitOperation` take to read
    /// this one again.
    pub fn ref(self: Operation) OperationRef {
        return .{ .name = self.name, .scope = self.scope };
    }

    /// Whether it acts on the instance `name`: its target's path ends in
    /// `/instances/<name>`.
    pub fn targetsInstance(self: Operation, name: []const u8) bool {
        const tail = "/instances/";
        if (self.target.len < tail.len + name.len) return false;
        const end = self.target[self.target.len - name.len - tail.len ..];
        return std.mem.startsWith(u8, end, tail) and std.mem.eql(u8, end[tail.len..], name);
    }
};

/// One page of a scope's operations. A zone's are how a caller tells what
/// ended a VM: `compute.instances.preempted`, `.deferredDelete` (a run
/// limit) or `.guestTerminate` (its guest powered off), each by "system".
pub const OperationPage = struct {
    operations: []const Operation,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
};

/// How long `Client.waitOperation` waits.
pub const WaitOptions = struct {
    /// The longest to wait, in milliseconds. One wait call may run up to
    /// about two minutes past it, since the server holds each one that
    /// long while the operation runs. 0 means a single wait call.
    timeout_ms: u32 = 600_000,
};

// Writes.

/// A VM to create, in the shape most VMs take: one boot disk from an
/// image, one network interface, labels, metadata, tags, a service
/// account and how it is scheduled. What it leaves out (accelerators,
/// local SSDs, more disks or interfaces, confidential computing and the
/// rest of Compute's schema) `Client.insertInstanceJson` sends as written.
pub const InstanceSpec = struct {
    /// RFC 1035: a lowercase letter, then up to 62 lowercase letters,
    /// digits and `-`, not ending in `-`.
    name: []const u8,
    /// A machine type in the VM's zone: `e2-micro`, `n2-standard-4`.
    machine_type: []const u8,
    /// The boot disk's image.
    image: ImageRef,
    boot_disk: BootDisk = .{},
    /// A spot VM, taken back when Google needs the room. Production fills
    /// in `on_host_maintenance` TERMINATE and `preemptible` for one
    /// (measured), and a spot VM cannot restart on its own, so the client
    /// sends `automaticRestart` false with it.
    spot: bool = false,
    /// A run limit, in seconds, at which `termination_action` happens.
    max_run_duration_s: ?u64 = null,
    /// What happens at the run limit, or when a spot VM is taken back.
    /// Null sends none, and Compute's default is to stop it.
    termination_action: ?TerminationAction = null,
    /// A standard VM restarts after Compute ends it (a host failure, say)
    /// unless this is false. Null sends none: Compute's default, true.
    /// Must not be true for a spot VM.
    automatic_restart: ?bool = null,
    /// Keys `[a-zA-Z0-9-_]`, under 128 bytes; each value at most 256 KiB.
    /// A startup script is the item `startup-script`.
    metadata: []const MetadataItem = &.{},
    labels: []const Label = &.{},
    /// Network tags, each an RFC 1035 name, for firewall rules.
    tags: []const []const u8 = &.{},
    /// The account the VM acts as. Null gives it none, so code on the VM
    /// has no Google credentials.
    service_account: ?ServiceAccount = null,
    /// A network's name in the project (`default`), or its path or URL.
    network: []const u8 = "default",
    /// A subnetwork's name in the zone's region, or its path or URL. Null
    /// lets Compute choose, which an auto mode network allows.
    subnetwork: ?[]const u8 = null,
    /// An external address, ephemeral, so the VM is reachable from (and
    /// can reach) the internet without Cloud NAT.
    external_ip: bool = false,
    /// While true, a delete is refused (`error.InvalidArgument`,
    /// "Resource cannot be deleted if it's protected against deletion.").
    deletion_protection: bool = false,
    description: ?[]const u8 = null,
};

/// An image a boot disk is made from.
pub const ImageRef = union(enum) {
    /// The newest in a family that is not deprecated:
    /// `.{ .family = .{ .project = "debian-cloud", .name = "debian-12" } }`.
    family: Named,
    /// One image by name.
    image: Named,
    /// A path or URL as Compute takes it:
    /// `projects/debian-cloud/global/images/family/debian-12`.
    path: []const u8,

    pub const Named = struct {
        /// The project the image lives in: a public one's (`debian-cloud`)
        /// or the client's own.
        project: []const u8,
        name: []const u8,
    };
};

/// A VM's boot disk.
pub const BootDisk = struct {
    /// At least 10. Null: the image's size.
    size_gb: ?u64 = null,
    /// `pd-balanced`, `pd-standard`, `pd-ssd`, `hyperdisk-balanced` and
    /// the like, by what the machine type takes. Null: Compute's default.
    type: ?[]const u8 = null,
    /// Deleted with the VM.
    auto_delete: bool = true,
};

/// An instance template, global or in one region, in the client's
/// project.
pub const TemplateRef = union(enum) {
    global: []const u8,
    regional: struct { region: []const u8, name: []const u8 },
};

/// What every write takes.
pub const WriteOptions = struct {
    /// Sent as `requestId`, so a write sent again lands once: production
    /// answered the same operation for a repeated id, while it ran and
    /// after (measured). A UUID, not all zeros. Null: the client makes
    /// one, and every retry of the call sends it.
    request_id: ?[]const u8 = null,
};

/// What `Client.stopInstance` takes.
pub const StopOptions = struct {
    request_id: ?[]const u8 = null,
    /// Skips the guest's graceful shutdown.
    no_graceful_shutdown: bool = false,
    /// Required for a VM with local SSDs: true discards what they hold.
    /// Null sends none.
    discard_local_ssd: ?bool = null,
};

/// What `Client.suspendInstance` takes.
pub const SuspendOptions = struct {
    request_id: ?[]const u8 = null,
    /// As `StopOptions.discard_local_ssd`.
    discard_local_ssd: ?bool = null,
};

/// What `Client.deleteInstance` takes.
pub const DeleteOptions = struct {
    request_id: ?[]const u8 = null,
    /// Skips the guest's graceful shutdown.
    no_graceful_shutdown: bool = false,
};

const testing = std.testing;

test "Status.parse: every state, and one this library does not know" {
    try testing.expectEqual(Status.running, Status.parse("RUNNING"));
    try testing.expectEqual(Status.terminated, Status.parse("TERMINATED"));
    try testing.expectEqual(Status.pending_stop, Status.parse("PENDING_STOP"));
    try testing.expectEqual(Status.unknown, Status.parse("HIBERNATING"));
    try testing.expect((Instance{ .name = "a", .status = .terminated }).stopped());
    try testing.expect(!(Instance{ .name = "a", .status = .suspended }).stopped());
}

test "Operation: stockouts, targets and refs" {
    const stock: Operation.Failure = .{ .errors = &.{.{ .code = "ZONE_RESOURCE_POOL_EXHAUSTED", .message = "x" }} };
    try testing.expect(stock.stockout());
    const words: Operation.Failure = .{ .errors = &.{.{ .code = "X", .message = "The zone 'z' does not have enough resources available" }} };
    try testing.expect(words.stockout());
    const other: Operation.Failure = .{ .errors = &.{.{ .code = "UNSUPPORTED_OPERATION", .message = "Instance is starting or running." }} };
    try testing.expect(!other.stockout());
    try testing.expectEqualStrings("UNSUPPORTED_OPERATION", other.code());

    const op: Operation = .{ .name = "operation-1", .scope = .{ .zone = "us-central1-a" }, .target = "projects/p/zones/us-central1-a/instances/web-1" };
    try testing.expect(op.targetsInstance("web-1"));
    try testing.expect(!op.targetsInstance("eb-1"));
    try testing.expect(!op.targetsInstance("web-12"));
    try testing.expectEqualStrings("us-central1-a", op.ref().scope.zone);
}

test "Instance: labels and metadata by key" {
    const i: Instance = .{
        .name = "a",
        .labels = &.{.{ .key = "env", .value = "prod" }},
        .metadata = .{ .items = &.{ .{ .key = "startup-script", .value = "echo" }, .{ .key = "flag" } } },
    };
    try testing.expectEqualStrings("prod", i.label("env").?);
    try testing.expect(i.label("nope") == null);
    try testing.expectEqualStrings("echo", i.metadataValue("startup-script").?);
    try testing.expect(i.metadataValue("flag") == null);
}
