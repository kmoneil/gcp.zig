//! Decoders for Compute Engine's JSON. The schemas are large; the decode
//! keeps what the types hold and skips the rest, lenient the way the
//! other modules are: unknown fields skipped, unknown enum values read as
//! `.unknown`, 64-bit numbers taken as strings or numbers. A resource
//! without a name is `error.InvalidResponse`, and so is a field of the
//! wrong JSON type.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const core = @import("core");
const types = @import("types.zig");

pub const DecodeError = error{ OutOfMemory, InvalidResponse };

/// An instance, as get answers.
pub fn decodeInstance(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.Instance {
    return instanceOf(out, try object(try parse(scratch, body)));
}

/// A page of a zone's instances: no `items` key is an empty page, as
/// production answered one.
pub fn decodeInstancePage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.InstancePage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "items", .array);
    const instances = try out.alloc(types.Instance, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, instances) |v, *i| {
        i.* = try instanceOf(out, try object(v));
    };
    return .{ .instances = instances, .next_page_token = try token(out, obj) };
}

/// A page of the aggregated list: `items` maps each scope to its
/// `instances` or a `warning`. NO_RESULTS_ON_PAGE, an empty scope's
/// warning, is left out; every other is kept.
pub fn decodeAggregatedInstancePage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.AggregatedInstancePage {
    const obj = try object(try parse(scratch, body));
    var instances: std.ArrayList(types.Instance) = .empty;
    var warnings: std.ArrayList(types.ScopeWarning) = .empty;
    if (try field(obj, "items", .object)) |items| {
        for (items.keys(), items.values()) |scope, v| {
            const entry = try object(v);
            if (try field(entry, "instances", .array)) |list| for (list.items) |i| {
                try instances.append(out, try instanceOf(out, try object(i)));
            };
            if (try scopeWarning(out, scope, entry)) |w| try warnings.append(out, w);
        }
    }
    return .{
        .instances = try instances.toOwnedSlice(out),
        .warnings = try warnings.toOwnedSlice(out),
        .unreachables = try stringList(out, obj, "unreachables"),
        .next_page_token = try token(out, obj),
    };
}

fn scopeWarning(out: Allocator, scope: []const u8, entry: ObjectMap) DecodeError!?types.ScopeWarning {
    const warning = try field(entry, "warning", .object) orelse return null;
    const code = try text(out, warning, "code");
    if (std.mem.eql(u8, code, "NO_RESULTS_ON_PAGE")) return null;
    return .{ .scope = try out.dupe(u8, scope), .code = code, .message = try text(out, warning, "message") };
}

/// An operation, as a write, a get or a wait answers it.
pub fn decodeOperation(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.Operation {
    return operationOf(out, try object(try parse(scratch, body)));
}

/// A page of a scope's operations.
pub fn decodeOperationPage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.OperationPage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "items", .array);
    const operations = try out.alloc(types.Operation, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, operations) |v, *o| {
        o.* = try operationOf(out, try object(v));
    };
    return .{ .operations = operations, .next_page_token = try token(out, obj) };
}

/// A stretch of a serial console: `contents` absent is no bytes, as a
/// read with nothing new answered.
pub fn decodeSerialOutput(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.SerialOutput {
    const obj = try object(try parse(scratch, body));
    return .{
        .contents = try text(out, obj, "contents"),
        .start = try integer(u64, obj, "start") orelse 0,
        .next = try integer(u64, obj, "next") orelse 0,
    };
}

/// Guest attributes: `queryValue.items` for a path's whole namespace, or
/// `variableKey` and `variableValue` for a single key.
pub fn decodeGuestAttributes(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.GuestAttributes {
    const obj = try object(try parse(scratch, body));
    var attributes: std.ArrayList(types.GuestAttribute) = .empty;
    if (try field(obj, "queryValue", .object)) |qv| if (try field(qv, "items", .array)) |list| {
        for (list.items) |v| {
            const o = try object(v);
            try attributes.append(out, .{
                .namespace = try text(out, o, "namespace"),
                .key = try text(out, o, "key"),
                .value = try text(out, o, "value"),
            });
        }
    };
    if (try string(out, obj, "variableKey")) |key| try attributes.append(out, .{
        .namespace = "",
        .key = key,
        .value = try text(out, obj, "variableValue"),
    });
    return .{ .query_path = try text(out, obj, "queryPath"), .attributes = try attributes.toOwnedSlice(out) };
}

pub fn decodeZone(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.Zone {
    return zoneOf(out, try object(try parse(scratch, body)));
}

pub fn decodeZonePage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.ZonePage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "items", .array);
    const zones = try out.alloc(types.Zone, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, zones) |v, *z| {
        z.* = try zoneOf(out, try object(v));
    };
    return .{ .zones = zones, .next_page_token = try token(out, obj) };
}

pub fn decodeMachineType(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.MachineType {
    return machineTypeOf(out, try object(try parse(scratch, body)));
}

pub fn decodeMachineTypePage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.MachineTypePage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "items", .array);
    const machine_types = try out.alloc(types.MachineType, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, machine_types) |v, *m| {
        m.* = try machineTypeOf(out, try object(v));
    };
    return .{ .machine_types = machine_types, .next_page_token = try token(out, obj) };
}

pub fn decodeImage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.Image {
    const obj = try object(try parse(scratch, body));
    const self_link = try text(out, obj, "selfLink");
    return .{
        .name = try required(out, obj, "name"),
        .project = segmentAfter(self_link, "projects/"),
        .family = try text(out, obj, "family"),
        .status = try text(out, obj, "status"),
        .description = try text(out, obj, "description"),
        .disk_size_gb = try integer(u64, obj, "diskSizeGb"),
        .architecture = try text(out, obj, "architecture"),
        .deprecated = if (try field(obj, "deprecated", .object)) |d| try text(out, d, "state") else "",
        .creation_time = try time(obj, "creationTimestamp"),
        .self_link = self_link,
    };
}

/// An instance template, as get answers.
pub fn decodeTemplate(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.Template {
    return templateOf(out, try object(try parse(scratch, body)));
}

/// A page of templates: no `items` key is an empty page.
pub fn decodeTemplatePage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.TemplatePage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "items", .array);
    const templates = try out.alloc(types.Template, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, templates) |v, *t| {
        t.* = try templateOf(out, try object(v));
    };
    return .{ .templates = templates, .next_page_token = try token(out, obj) };
}

/// A managed instance group, as get answers.
pub fn decodeGroup(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.Group {
    return groupOf(out, try object(try parse(scratch, body)));
}

/// A page of a zone's groups.
pub fn decodeGroupPage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.GroupPage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "items", .array);
    const groups = try out.alloc(types.Group, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, groups) |v, *g| {
        g.* = try groupOf(out, try object(v));
    };
    return .{ .groups = groups, .next_page_token = try token(out, obj) };
}

/// A page of a group's VMs, under `managedInstances`.
pub fn decodeManagedInstancePage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.ManagedInstancePage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "managedInstances", .array);
    const instances = try out.alloc(types.ManagedInstance, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, instances) |v, *m| {
        m.* = try managedOf(out, try object(v));
    };
    return .{ .instances = instances, .next_page_token = try token(out, obj) };
}

/// A template; what its VMs are is under `properties`, read as an
/// instance's fields are.
fn templateOf(out: Allocator, obj: ObjectMap) DecodeError!types.Template {
    const props = try field(obj, "properties", .object) orelse return error.InvalidResponse;
    const region = try text(out, obj, "region");
    return .{
        .name = try required(out, obj, "name"),
        .id = try integerText(out, obj, "id"),
        .region = if (region.len == 0) null else trailing(region),
        .description = try text(out, obj, "description"),
        .creation_time = try time(obj, "creationTimestamp"),
        .machine_type = trailing(try text(out, props, "machineType")),
        .labels = try labelMap(out, props, "labels"),
        .metadata = try metadataOf(out, props),
        .tags = try tagsOf(out, props),
        .disks = try diskList(out, props),
        .source_image = try bootImage(out, props),
        .network_interfaces = try interfaceList(out, props),
        .service_accounts = try accountList(out, props),
        .scheduling = try schedulingOf(out, props),
    };
}

/// The boot disk's `initializeParams.sourceImage`, or empty.
fn bootImage(out: Allocator, props: ObjectMap) DecodeError![]const u8 {
    const list = try field(props, "disks", .array) orelse return "";
    for (list.items) |v| {
        const d = try object(v);
        if (try boolean(d, "boot") != true) continue;
        const params = try field(d, "initializeParams", .object) orelse return "";
        return text(out, params, "sourceImage");
    }
    return "";
}

fn groupOf(out: Allocator, obj: ObjectMap) DecodeError!types.Group {
    const status = try field(obj, "status", .object);
    const actions = try field(obj, "currentActions", .object);
    return .{
        .name = try required(out, obj, "name"),
        .id = try integerText(out, obj, "id"),
        .zone = trailing(try text(out, obj, "zone")),
        .description = try text(out, obj, "description"),
        .creation_time = try time(obj, "creationTimestamp"),
        .base_instance_name = try text(out, obj, "baseInstanceName"),
        .template = pathOf(try text(out, obj, "instanceTemplate")),
        .target_size = try integer(u32, obj, "targetSize") orelse 0,
        .current_actions = if (actions) |a| try actionsOf(a) else .{},
        .is_stable = if (status) |s| try boolean(s, "isStable") orelse false else false,
        .fingerprint = try text(out, obj, "fingerprint"),
        .self_link = try text(out, obj, "selfLink"),
    };
}

/// `currentActions`' counts, each field under its camelCase name.
fn actionsOf(obj: ObjectMap) DecodeError!types.GroupActions {
    var out: types.GroupActions = .{};
    inline for (@typeInfo(types.GroupActions).@"struct".field_names) |name| {
        @field(out, name) = try integer(u32, obj, comptime camelCase(name)) orelse 0;
    }
    return out;
}

fn camelCase(comptime snake: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var upper = false;
        for (snake) |c| {
            if (c == '_') {
                upper = true;
                continue;
            }
            out = out ++ [_]u8{if (upper) std.ascii.toUpper(c) else c};
            upper = false;
        }
        return out;
    }
}

fn managedOf(out: Allocator, obj: ObjectMap) DecodeError!types.ManagedInstance {
    const status = try text(out, obj, "instanceStatus");
    const target = try text(out, obj, "targetStatus");
    const version = try field(obj, "version", .object);
    return .{
        .name = try required(out, obj, "name"),
        .id = try integerText(out, obj, "id"),
        .status = if (status.len == 0) null else types.Status.parse(status),
        .target_status = if (target.len == 0) null else types.Status.parse(target),
        .current_action = types.ManagedAction.parse(try text(out, obj, "currentAction")),
        .template = if (version) |v| pathOf(try text(out, v, "instanceTemplate")) else "",
    };
}

fn instanceOf(out: Allocator, obj: ObjectMap) DecodeError!types.Instance {
    return .{
        .id = try integerText(out, obj, "id"),
        .name = try required(out, obj, "name"),
        .zone = trailing(try text(out, obj, "zone")),
        .machine_type = trailing(try text(out, obj, "machineType")),
        .status = types.Status.parse(try text(out, obj, "status")),
        .status_message = try text(out, obj, "statusMessage"),
        .creation_time = try time(obj, "creationTimestamp"),
        .last_start_time = try time(obj, "lastStartTimestamp"),
        .last_stop_time = try time(obj, "lastStopTimestamp"),
        .last_suspended_time = try time(obj, "lastSuspendedTimestamp"),
        .labels = try labelMap(out, obj, "labels"),
        .label_fingerprint = try text(out, obj, "labelFingerprint"),
        .metadata = try metadataOf(out, obj),
        .tags = try tagsOf(out, obj),
        .disks = try diskList(out, obj),
        .network_interfaces = try interfaceList(out, obj),
        .service_accounts = try accountList(out, obj),
        .scheduling = try schedulingOf(out, obj),
        .deletion_protection = try boolean(obj, "deletionProtection") orelse false,
        .fingerprint = try text(out, obj, "fingerprint"),
        .cpu_platform = try text(out, obj, "cpuPlatform"),
        .hostname = try text(out, obj, "hostname"),
        .self_link = try text(out, obj, "selfLink"),
    };
}

fn metadataOf(out: Allocator, obj: ObjectMap) DecodeError!types.Metadata {
    const md = try field(obj, "metadata", .object) orelse return .{};
    const list = try field(md, "items", .array);
    const items = try out.alloc(types.MetadataItem, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, items) |v, *item| {
        const o = try object(v);
        item.* = .{ .key = try text(out, o, "key"), .value = try string(out, o, "value") };
    };
    return .{ .fingerprint = try text(out, md, "fingerprint"), .items = items };
}

fn tagsOf(out: Allocator, obj: ObjectMap) DecodeError!types.Tags {
    const tags = try field(obj, "tags", .object) orelse return .{};
    return .{ .fingerprint = try text(out, tags, "fingerprint"), .items = try stringList(out, tags, "items") };
}

fn diskList(out: Allocator, obj: ObjectMap) DecodeError![]const types.AttachedDisk {
    const list = try field(obj, "disks", .array) orelse return &.{};
    const disks = try out.alloc(types.AttachedDisk, list.items.len);
    for (list.items, disks) |v, *d| {
        const o = try object(v);
        d.* = .{
            .device_name = try text(out, o, "deviceName"),
            .source = try text(out, o, "source"),
            .boot = try boolean(o, "boot") orelse false,
            .auto_delete = try boolean(o, "autoDelete") orelse false,
            .mode = try text(out, o, "mode"),
            .type = try text(out, o, "type"),
            .interface = try text(out, o, "interface"),
            .size_gb = try integer(u64, o, "diskSizeGb"),
            .index = try integer(u32, o, "index"),
        };
    }
    return disks;
}

fn interfaceList(out: Allocator, obj: ObjectMap) DecodeError![]const types.NetworkInterface {
    const list = try field(obj, "networkInterfaces", .array) orelse return &.{};
    const nics = try out.alloc(types.NetworkInterface, list.items.len);
    for (list.items, nics) |v, *n| {
        const o = try object(v);
        n.* = .{
            .name = try text(out, o, "name"),
            .network = try text(out, o, "network"),
            .subnetwork = try text(out, o, "subnetwork"),
            .internal_ip = try text(out, o, "networkIP"),
            .access_configs = try accessConfigList(out, o),
        };
    }
    return nics;
}

fn accessConfigList(out: Allocator, obj: ObjectMap) DecodeError![]const types.AccessConfig {
    const list = try field(obj, "accessConfigs", .array) orelse return &.{};
    const configs = try out.alloc(types.AccessConfig, list.items.len);
    for (list.items, configs) |v, *c| {
        const o = try object(v);
        c.* = .{ .name = try text(out, o, "name"), .type = try text(out, o, "type"), .nat_ip = try text(out, o, "natIP") };
    }
    return configs;
}

fn accountList(out: Allocator, obj: ObjectMap) DecodeError![]const types.ServiceAccount {
    const list = try field(obj, "serviceAccounts", .array) orelse return &.{};
    const accounts = try out.alloc(types.ServiceAccount, list.items.len);
    for (list.items, accounts) |v, *a| {
        const o = try object(v);
        a.* = .{ .email = try text(out, o, "email"), .scopes = try stringList(out, o, "scopes") };
    }
    return accounts;
}

/// The VM's scheduling, and its termination time from `resourceStatus`
/// when the scheduling itself has none.
fn schedulingOf(out: Allocator, obj: ObjectMap) DecodeError!types.Scheduling {
    const s = try field(obj, "scheduling", .object) orelse return .{};
    const action = try text(out, s, "instanceTerminationAction");
    const model = try text(out, s, "provisioningModel");
    return .{
        // None is the API's default, STANDARD.
        .provisioning_model = if (model.len == 0) .standard else types.ProvisioningModel.parse(model),
        .preemptible = try boolean(s, "preemptible") orelse false,
        .automatic_restart = try boolean(s, "automaticRestart"),
        .on_host_maintenance = try text(out, s, "onHostMaintenance"),
        .max_run_duration_s = if (try field(s, "maxRunDuration", .object)) |d| try integer(u64, d, "seconds") else null,
        .termination_action = if (action.len == 0) null else types.TerminationAction.parse(action),
        .termination_time = try terminationTime(obj, s),
    };
}

fn terminationTime(obj: ObjectMap, scheduling: ObjectMap) DecodeError!?std.Io.Timestamp {
    if (try time(scheduling, "terminationTime")) |t| return t;
    const status = try field(obj, "resourceStatus", .object) orelse return null;
    const s = try field(status, "scheduling", .object) orelse return null;
    return time(s, "terminationTimestamp");
}

fn operationOf(out: Allocator, obj: ObjectMap) DecodeError!types.Operation {
    return .{
        .name = try required(out, obj, "name"),
        .scope = try operationScope(out, obj),
        .status = types.OperationStatus.parse(try text(out, obj, "status")),
        .progress = @intCast(@min(100, try integer(u32, obj, "progress") orelse 0)),
        .operation_type = try text(out, obj, "operationType"),
        .target = pathOf(try text(out, obj, "targetLink")),
        .target_id = try integerText(out, obj, "targetId"),
        .user = try text(out, obj, "user"),
        .client_operation_id = try text(out, obj, "clientOperationId"),
        .insert_time = try time(obj, "insertTime"),
        .start_time = try time(obj, "startTime"),
        .end_time = try time(obj, "endTime"),
        .failure = try failureOf(out, obj),
        .warnings = try warningList(out, obj),
    };
}

/// A zone's or a region's operation by its URL, else a global one.
fn operationScope(out: Allocator, obj: ObjectMap) DecodeError!types.OperationScope {
    const zone = try text(out, obj, "zone");
    if (zone.len > 0) return .{ .zone = trailing(zone) };
    const region = try text(out, obj, "region");
    if (region.len > 0) return .{ .region = trailing(region) };
    return .global;
}

fn failureOf(out: Allocator, obj: ObjectMap) DecodeError!?types.Operation.Failure {
    const e = try field(obj, "error", .object) orelse return null;
    const list = try field(e, "errors", .array) orelse return .{ .errors = &.{} };
    const items = try out.alloc(types.Operation.Failure.Item, list.items.len);
    for (list.items, items) |v, *item| {
        const o = try object(v);
        item.* = .{ .code = try text(out, o, "code"), .message = try text(out, o, "message"), .location = try text(out, o, "location") };
    }
    return .{ .errors = items, .http_status = try integer(u16, obj, "httpErrorStatusCode") };
}

fn warningList(out: Allocator, obj: ObjectMap) DecodeError![]const types.Operation.Warning {
    const list = try field(obj, "warnings", .array) orelse return &.{};
    const warnings = try out.alloc(types.Operation.Warning, list.items.len);
    for (list.items, warnings) |v, *w| {
        const o = try object(v);
        w.* = .{ .code = try text(out, o, "code"), .message = try text(out, o, "message") };
    }
    return warnings;
}

fn zoneOf(out: Allocator, obj: ObjectMap) DecodeError!types.Zone {
    return .{
        .name = try required(out, obj, "name"),
        .region = trailing(try text(out, obj, "region")),
        .status = try text(out, obj, "status"),
        .description = try text(out, obj, "description"),
        .available_cpu_platforms = try stringList(out, obj, "availableCpuPlatforms"),
    };
}

fn machineTypeOf(out: Allocator, obj: ObjectMap) DecodeError!types.MachineType {
    return .{
        .name = try required(out, obj, "name"),
        .zone = trailing(try text(out, obj, "zone")),
        .description = try text(out, obj, "description"),
        .guest_cpus = try integer(u32, obj, "guestCpus") orelse 0,
        .memory_mb = try integer(u64, obj, "memoryMb") orelse 0,
        .shared_cpu = try boolean(obj, "isSharedCpu") orelse false,
        .maximum_persistent_disks = try integer(u32, obj, "maximumPersistentDisks") orelse 0,
    };
}

/// The last path segment: a zone's id from its URL, say.
fn trailing(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| return name[i + 1 ..];
    return name;
}

/// The segment after `marker`, or "".
fn segmentAfter(name: []const u8, marker: []const u8) []const u8 {
    const head = std.mem.indexOf(u8, name, marker) orelse return "";
    const rest = name[head + marker.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    return rest[0..end];
}

/// A link's path from `projects/` on, whichever host it names.
fn pathOf(link: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, link, "projects/") orelse return link;
    return link[at..];
}

fn parse(scratch: Allocator, body: []const u8) DecodeError!Value {
    return std.json.parseFromSliceLeaky(Value, scratch, body, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResponse,
    };
}

fn object(v: Value) DecodeError!ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => error.InvalidResponse,
    };
}

fn field(obj: ObjectMap, name: []const u8, comptime tag: std.meta.Tag(Value)) DecodeError!?@FieldType(Value, @tagName(tag)) {
    const v = obj.get(name) orelse return null;
    if (v == .null) return null;
    if (v != tag) return error.InvalidResponse;
    return @field(v, @tagName(tag));
}

fn string(out: Allocator, obj: ObjectMap, name: []const u8) DecodeError!?[]const u8 {
    const s = try field(obj, name, .string) orelse return null;
    return try out.dupe(u8, s);
}

/// A string field, "" when absent.
fn text(out: Allocator, obj: ObjectMap, name: []const u8) DecodeError![]const u8 {
    return try string(out, obj, name) orelse "";
}

/// A string field a resource cannot be without.
fn required(out: Allocator, obj: ObjectMap, name: []const u8) DecodeError![]const u8 {
    const s = try string(out, obj, name) orelse return error.InvalidResponse;
    if (s.len == 0) return error.InvalidResponse;
    return s;
}

fn boolean(obj: ObjectMap, name: []const u8) DecodeError!?bool {
    return try field(obj, name, .bool);
}

/// `nextPageToken`: "" means the last page.
fn token(out: Allocator, obj: ObjectMap) DecodeError!?[]const u8 {
    const s = try field(obj, "nextPageToken", .string) orelse return null;
    if (s.len == 0) return null;
    return try out.dupe(u8, s);
}

/// RFC 3339 with an offset, as Compute writes them
/// ("2026-11-03T10:31:05.869-08:00").
fn time(obj: ObjectMap, name: []const u8) DecodeError!?std.Io.Timestamp {
    const s = try field(obj, name, .string) orelse return null;
    return core.timestamp.parse(s) catch error.InvalidResponse;
}

/// An integer that may arrive as a JSON number or a string, as Compute
/// sends 64-bit ones ("diskSizeGb": "10", "start": "1765733").
fn integer(comptime T: type, obj: ObjectMap, name: []const u8) DecodeError!?T {
    const v = obj.get(name) orelse return null;
    const digits = switch (v) {
        .null => return null,
        .number_string, .string => |s| s,
        else => return error.InvalidResponse,
    };
    return std.fmt.parseInt(T, digits, 10) catch error.InvalidResponse;
}

/// A 64-bit id kept as the text the server wrote, number or string; ""
/// when absent.
fn integerText(out: Allocator, obj: ObjectMap, name: []const u8) DecodeError![]const u8 {
    const v = obj.get(name) orelse return "";
    return switch (v) {
        .null => "",
        .number_string, .string => |s| try out.dupe(u8, s),
        else => error.InvalidResponse,
    };
}

fn stringList(out: Allocator, obj: ObjectMap, name: []const u8) DecodeError![]const []const u8 {
    const list = try field(obj, name, .array) orelse return &.{};
    const items = try out.alloc([]const u8, list.items.len);
    for (list.items, items) |v, *s| s.* = switch (v) {
        .string => |t| try out.dupe(u8, t),
        else => return error.InvalidResponse,
    };
    return items;
}

/// A map of strings as pairs, in the order the server wrote them.
fn labelMap(out: Allocator, obj: ObjectMap, name: []const u8) DecodeError![]const types.Label {
    const map = try field(obj, name, .object) orelse return &.{};
    const items = try out.alloc(types.Label, map.count());
    for (map.keys(), map.values(), items) |k, v, *l| l.* = .{
        .key = try out.dupe(u8, k),
        .value = switch (v) {
            .string => |s| try out.dupe(u8, s),
            else => return error.InvalidResponse,
        },
    };
    return items;
}

const testing = std.testing;
const production = @import("production_bodies.zig");

const Arenas = struct {
    out: std.heap.ArenaAllocator,
    scratch: std.heap.ArenaAllocator,

    fn init() Arenas {
        return .{ .out = .init(testing.allocator), .scratch = .init(testing.allocator) };
    }

    fn deinit(a: *Arenas) void {
        a.out.deinit();
        a.scratch.deinit();
    }
};

test "decodeInstance: production's spot VM" {
    var a: Arenas = .init();
    defer a.deinit();
    const i = try decodeInstance(a.out.allocator(), a.scratch.allocator(), production.instance_spot);
    try testing.expectEqualStrings("zigps-m0-11031830-a", i.name);
    try testing.expectEqualStrings("6231655708778534534", i.id);
    try testing.expectEqualStrings("us-central1-a", i.zone);
    try testing.expectEqualStrings("e2-micro", i.machine_type);
    try testing.expectEqual(types.Status.running, i.status);
    try testing.expect(i.running());
    try testing.expectEqualStrings("compute-m0", i.label("tool").?);
    try testing.expectEqualStrings("rNhSjTzLR00=", i.label_fingerprint);
    try testing.expectEqualStrings("inPgXPhJXaM=", i.metadata.fingerprint);
    try testing.expectEqualStrings("TRUE", i.metadataValue("enable-guest-attributes").?);
    try testing.expect(std.mem.indexOf(u8, i.metadataValue("startup-script").?, "guest-attributes/zigps/probe") != null);
    try testing.expectEqualStrings("42WmSpB8rSM=", i.tags.fingerprint);
    try testing.expectEqual(0, i.tags.items.len);
    try testing.expectEqual(1, i.disks.len);
    try testing.expect(i.disks[0].boot and i.disks[0].auto_delete);
    try testing.expectEqual(10, i.disks[0].size_gb.?);
    try testing.expectEqualStrings("persistent-disk-0", i.disks[0].device_name);
    try testing.expectEqualStrings("10.128.0.13", i.network_interfaces[0].internal_ip);
    try testing.expectEqual(0, i.network_interfaces[0].access_configs.len);
    try testing.expectEqual(types.ProvisioningModel.spot, i.scheduling.provisioning_model);
    try testing.expect(i.scheduling.preemptible);
    try testing.expectEqual(false, i.scheduling.automatic_restart.?);
    try testing.expectEqualStrings("TERMINATE", i.scheduling.on_host_maintenance);
    try testing.expectEqual(3600, i.scheduling.max_run_duration_s.?);
    try testing.expectEqual(types.TerminationAction.delete, i.scheduling.termination_action.?);
    // From resourceStatus.scheduling: an hour after it was made.
    try testing.expect(i.scheduling.termination_time != null);
    try testing.expectEqualStrings("AMD Rome", i.cpu_platform);
    try testing.expect(!i.deletion_protection);
    try testing.expect(i.creation_time != null and i.last_start_time != null);
}

test "decodeInstance: standard, suspended, powered off" {
    var a: Arenas = .init();
    defer a.deinit();
    const out = a.out.allocator();
    const s = a.scratch.allocator();
    const standard = try decodeInstance(out, s, production.instance_standard);
    try testing.expectEqual(types.ProvisioningModel.standard, standard.scheduling.provisioning_model);
    try testing.expect(standard.deletion_protection);
    const suspended = try decodeInstance(out, s, production.instance_suspended);
    try testing.expectEqual(types.Status.suspended, suspended.status);
    try testing.expectEqualStrings("e2-small", suspended.machine_type);
    try testing.expect(!suspended.stopped());
    const off = try decodeInstance(out, s, production.instance_powered_off);
    try testing.expectEqual(types.Status.terminated, off.status);
    try testing.expect(off.stopped());
    try testing.expectEqualStrings("", off.status_message);
    try testing.expect(off.last_stop_time != null);
    const limited = try decodeInstance(out, s, production.instance_run_limit);
    try testing.expectEqual(120, limited.scheduling.max_run_duration_s.?);
    const restartless = try decodeInstance(out, s, production.instance_standard_restartless);
    try testing.expectEqual(types.ProvisioningModel.standard, restartless.scheduling.provisioning_model);
    try testing.expectEqual(false, restartless.scheduling.automatic_restart.?);
    try testing.expectEqual(1800, restartless.scheduling.max_run_duration_s.?);
    try testing.expectEqual(types.TerminationAction.delete, restartless.scheduling.termination_action.?);
    // None at all is the API's default.
    const bare = try decodeInstance(out, s, "{\"name\":\"a\",\"scheduling\":{}}");
    try testing.expectEqual(types.ProvisioningModel.standard, bare.scheduling.provisioning_model);
}

test "decodeInstancePage: an empty list has no items key" {
    var a: Arenas = .init();
    defer a.deinit();
    const page = try decodeInstancePage(a.out.allocator(), a.scratch.allocator(), production.instance_list_empty);
    try testing.expectEqual(0, page.instances.len);
    try testing.expect(page.next_page_token == null);
}

test "decodeAggregatedInstancePage: empty zones' warnings are left out" {
    var a: Arenas = .init();
    defer a.deinit();
    const out = a.out.allocator();
    const s = a.scratch.allocator();
    const two = try decodeAggregatedInstancePage(out, s, production.aggregated_two);
    try testing.expectEqual(2, two.instances.len);
    for (two.instances) |i| try testing.expectEqualStrings("us-central1-a", i.zone);
    try testing.expectEqual(0, two.warnings.len);
    try testing.expectEqual(0, two.unreachables.len);
    try testing.expect(two.next_page_token == null);
    const page = try decodeAggregatedInstancePage(out, s, production.aggregated_page);
    try testing.expectEqual(1, page.instances.len);
    try testing.expect(page.next_page_token != null);
    // A warning other than an empty scope's is kept, with its scope.
    const unreachable_zone =
        \\{"items":{"zones/a-b1-c":{"warning":{"code":"UNREACHABLE","message":"down"}}},"unreachables":["zones/a-b1-c"]}
    ;
    const w = try decodeAggregatedInstancePage(out, s, unreachable_zone);
    try testing.expectEqualStrings("zones/a-b1-c", w.warnings[0].scope);
    try testing.expectEqualStrings("UNREACHABLE", w.warnings[0].code);
    try testing.expectEqualStrings("zones/a-b1-c", w.unreachables[0]);
}

test "decodeOperation: running, done, failed in its operation" {
    var a: Arenas = .init();
    defer a.deinit();
    const out = a.out.allocator();
    const s = a.scratch.allocator();
    const running = try decodeOperation(out, s, production.operation_running);
    try testing.expectEqual(types.OperationStatus.running, running.status);
    try testing.expectEqualStrings("us-central1-a", running.scope.zone);
    try testing.expectEqualStrings("insert", running.operation_type);
    try testing.expectEqualStrings("8068f1b8-03fc-4f7f-a5bd-d5e775aa7212", running.client_operation_id);
    try testing.expect(running.targetsInstance("zigps-m0-11031830-a"));
    // The link named www.googleapis.com; only the path is kept.
    try testing.expect(std.mem.startsWith(u8, running.target, "projects/extractctl/zones/"));
    try testing.expect(!running.done());
    const done = try decodeOperation(out, s, production.operation_done);
    try testing.expect(done.succeeded());
    try testing.expectEqual(100, done.progress);
    try testing.expect(done.end_time != null);
    const failed = try decodeOperation(out, s, production.operation_failed);
    try testing.expect(failed.done() and !failed.succeeded());
    try testing.expectEqualStrings("UNSUPPORTED_OPERATION", failed.failure.?.code());
    try testing.expectEqualStrings("Instance is starting or running.", failed.failure.?.message());
    try testing.expectEqual(400, failed.failure.?.http_status.?);
    try testing.expect(!failed.failure.?.stockout());
    const suspending = try decodeOperation(out, s, production.operation_suspending);
    try testing.expectEqual(types.OperationStatus.running, suspending.status);
}

test "decodeOperationPage: a preemption, by system" {
    var a: Arenas = .init();
    defer a.deinit();
    const page = try decodeOperationPage(a.out.allocator(), a.scratch.allocator(), production.operation_list);
    try testing.expectEqual(3, page.operations.len);
    const last = page.operations[2];
    try testing.expectEqualStrings("compute.instances.preempted", last.operation_type);
    try testing.expectEqualStrings("system", last.user);
    try testing.expect(last.targetsInstance("zigps-m0-11031830-a"));
}

test "decodeSerialOutput: offsets as strings, nothing new" {
    var a: Arenas = .init();
    defer a.deinit();
    const out = a.out.allocator();
    const s = a.scratch.allocator();
    const tail = try decodeSerialOutput(out, s, production.serial_tail);
    try testing.expectEqual(1765733, tail.start);
    try testing.expectEqual(2814309, tail.next);
    try testing.expect(std.mem.startsWith(u8, tail.contents, "zigps-m0 serial line 18234"));
    const none = try decodeSerialOutput(out, s, production.serial_nothing_new);
    try testing.expectEqual(0, none.contents.len);
    try testing.expectEqual(none.start, none.next);
}

test "decodeGuestAttributes: a namespace, and a single key" {
    var a: Arenas = .init();
    defer a.deinit();
    const out = a.out.allocator();
    const s = a.scratch.allocator();
    const ga = try decodeGuestAttributes(out, s, production.guest_attributes);
    try testing.expectEqualStrings("zigps/", ga.query_path);
    try testing.expectEqual(1, ga.attributes.len);
    try testing.expectEqualStrings("probe", ga.attributes[0].key);
    try testing.expectEqualStrings("ready", ga.attributes[0].value);
    const one = try decodeGuestAttributes(out, s, "{\"variableKey\":\"zigps/probe\",\"variableValue\":\"ready\"}");
    try testing.expectEqualStrings("zigps/probe", one.attributes[0].key);
}

test "decodeZone, decodeMachineType(Page), decodeImage" {
    var a: Arenas = .init();
    defer a.deinit();
    const out = a.out.allocator();
    const s = a.scratch.allocator();
    const z = try decodeZone(out, s, production.zone);
    try testing.expectEqualStrings("us-central1-a", z.name);
    try testing.expectEqualStrings("us-central1", z.region);
    try testing.expectEqualStrings("UP", z.status);
    const m = try decodeMachineType(out, s, production.machine_type);
    try testing.expectEqualStrings("e2-micro", m.name);
    try testing.expectEqual(2, m.guest_cpus);
    try testing.expectEqual(1024, m.memory_mb);
    try testing.expect(m.shared_cpu);
    const page = try decodeMachineTypePage(out, s, production.machine_type_page);
    try testing.expectEqual(5, page.machine_types.len);
    try testing.expect(page.next_page_token != null);
    const img = try decodeImage(out, s, production.image);
    try testing.expectEqualStrings("debian-12", img.family);
    try testing.expectEqualStrings("debian-cloud", img.project);
    try testing.expectEqualStrings("READY", img.status);
    try testing.expectEqual(10, img.disk_size_gb.?);
    try testing.expectEqualStrings("", img.deprecated);
}

test "decoders refuse what is not their shape" {
    var a: Arenas = .init();
    defer a.deinit();
    const out = a.out.allocator();
    const s = a.scratch.allocator();
    try testing.expectError(error.InvalidResponse, decodeInstance(out, s, "{}"));
    try testing.expectError(error.InvalidResponse, decodeInstance(out, s, "[]"));
    try testing.expectError(error.InvalidResponse, decodeInstance(out, s, "{\"name\":3}"));
    try testing.expectError(error.InvalidResponse, decodeInstance(out, s, "{\"name\":\"a\",\"labels\":{\"k\":1}}"));
    try testing.expectError(error.InvalidResponse, decodeOperation(out, s, "{\"name\":\"op\",\"progress\":\"x\"}"));
    try testing.expectError(error.InvalidResponse, decodeSerialOutput(out, s, "{\"start\":\"-1\"}"));
    try testing.expectError(error.InvalidResponse, decodeInstancePage(out, s, "not json"));
}

/// Every decoder takes the bytes it is given and either reads them or
/// refuses them, never anything worse. The corpus is production's answers.
fn decodeProperty(_: void, input: []const u8) !void {
    var a: Arenas = .init();
    defer a.deinit();
    const out = a.out.allocator();
    const s = a.scratch.allocator();
    if (input.len == 0) return;
    const body = input[1..];
    switch (input[0] % 10) {
        0 => _ = decodeInstance(out, s, body) catch return,
        1 => _ = decodeInstancePage(out, s, body) catch return,
        2 => _ = decodeAggregatedInstancePage(out, s, body) catch return,
        3 => _ = decodeOperation(out, s, body) catch return,
        4 => _ = decodeOperationPage(out, s, body) catch return,
        5 => _ = decodeSerialOutput(out, s, body) catch return,
        6 => _ = decodeGuestAttributes(out, s, body) catch return,
        7 => _ = decodeZonePage(out, s, body) catch return,
        8 => _ = decodeMachineTypePage(out, s, body) catch return,
        else => _ = decodeImage(out, s, body) catch return,
    }
}

test "fuzz compute codec: every decoder reads or refuses, never worse" {
    try @import("test_util.zig").fuzzBytes({}, decodeProperty, .{
        .corpus = &.{
            "\x00" ++ production.instance_spot,
            "\x01" ++ production.instance_list_empty,
            "\x02" ++ production.aggregated_page,
            "\x03" ++ production.operation_failed,
            "\x04" ++ production.operation_list,
            "\x05" ++ production.serial_tail,
            "\x06" ++ production.guest_attributes,
            "\x08" ++ production.machine_type_page,
            "\x09" ++ production.image,
        },
    });
}
