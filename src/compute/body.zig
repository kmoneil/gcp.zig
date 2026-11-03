//! The bodies the writes send. An insert from `InstanceSpec` is written
//! in the shape milestone 0's inserts took (measured 2026-11-03): the
//! machine type, disk type and network as paths relative to the project,
//! 64-bit numbers as strings, nothing sent that the spec leaves to
//! Compute. The client checks the spec before this writes it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const types = @import("types.zig");

/// The scope a service account is given when the spec names none: the
/// broad one, so what the VM may do is its account's IAM roles alone, as
/// Google recommends.
pub const default_account_scope = "https://www.googleapis.com/auth/cloud-platform";

/// `instances.insert`'s body for `spec` in `zone`.
pub fn instance(arena: Allocator, zone: []const u8, spec: types.InstanceSpec) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeInstance(&jw, arena, zone, spec) catch return error.OutOfMemory;
    return out.written();
}

/// `instances.insert`'s body from a template: the name alone, the
/// template the query names giving the rest.
pub fn nameOnly(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    return Stringify.valueAlloc(arena, .{ .name = name }, .{});
}

fn writeInstance(jw: *Stringify, arena: Allocator, zone: []const u8, spec: types.InstanceSpec) !void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(spec.name);
    if (spec.description) |d| {
        try jw.objectField("description");
        try jw.write(d);
    }
    try jw.objectField("machineType");
    try jw.print("\"zones/{s}/machineTypes/{s}\"", .{ zone, spec.machine_type });
    if (spec.labels.len > 0) {
        try jw.objectField("labels");
        try jw.beginObject();
        for (spec.labels) |l| {
            try jw.objectField(l.key);
            try jw.write(l.value);
        }
        try jw.endObject();
    }
    if (spec.tags.len > 0) {
        try jw.objectField("tags");
        try jw.write(.{ .items = spec.tags });
    }
    try writeDisks(jw, arena, zone, spec);
    try writeInterfaces(jw, arena, zone, spec);
    if (spec.metadata.len > 0) {
        try jw.objectField("metadata");
        try jw.beginObject();
        try jw.objectField("items");
        try jw.beginArray();
        for (spec.metadata) |m| {
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
        try jw.endObject();
    }
    if (spec.service_account) |account| {
        const scopes: []const []const u8 = if (account.scopes.len > 0) account.scopes else &.{default_account_scope};
        try jw.objectField("serviceAccounts");
        try jw.write(.{.{ .email = account.email, .scopes = scopes }});
    }
    try writeScheduling(jw, spec);
    if (spec.deletion_protection) {
        try jw.objectField("deletionProtection");
        try jw.write(true);
    }
    try jw.endObject();
}

fn writeDisks(jw: *Stringify, arena: Allocator, zone: []const u8, spec: types.InstanceSpec) !void {
    try jw.objectField("disks");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("boot");
    try jw.write(true);
    try jw.objectField("autoDelete");
    try jw.write(spec.boot_disk.auto_delete);
    try jw.objectField("initializeParams");
    try jw.beginObject();
    try jw.objectField("sourceImage");
    try jw.write(try imagePath(arena, spec.image));
    if (spec.boot_disk.size_gb) |gb| {
        try jw.objectField("diskSizeGb");
        try jw.print("\"{d}\"", .{gb});
    }
    if (spec.boot_disk.type) |t| {
        try jw.objectField("diskType");
        try jw.write(try zonal(arena, zone, "diskTypes", t));
    }
    try jw.endObject();
    try jw.endObject();
    try jw.endArray();
}

fn writeInterfaces(jw: *Stringify, arena: Allocator, zone: []const u8, spec: types.InstanceSpec) !void {
    try jw.objectField("networkInterfaces");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("network");
    try jw.write(try global(arena, "networks", spec.network));
    if (spec.subnetwork) |s| {
        try jw.objectField("subnetwork");
        try jw.write(try regional(arena, zone, "subnetworks", s));
    }
    if (spec.external_ip) {
        try jw.objectField("accessConfigs");
        try jw.write(.{.{ .name = "External NAT", .type = "ONE_TO_ONE_NAT" }});
    }
    try jw.endObject();
    try jw.endArray();
}

/// As milestone 0 sent it: `automaticRestart` false with a spot VM,
/// which cannot restart on its own.
fn writeScheduling(jw: *Stringify, spec: types.InstanceSpec) !void {
    const restart: ?bool = if (spec.spot) false else spec.automatic_restart;
    if (restart == null and spec.max_run_duration_s == null and spec.termination_action == null and !spec.spot) return;
    try jw.objectField("scheduling");
    try jw.beginObject();
    if (restart) |r| {
        try jw.objectField("automaticRestart");
        try jw.write(r);
    }
    if (spec.max_run_duration_s) |secs| {
        try jw.objectField("maxRunDuration");
        try jw.print("{{\"seconds\":\"{d}\"}}", .{secs});
    }
    if (spec.termination_action) |action| {
        try jw.objectField("instanceTerminationAction");
        try jw.write(switch (action) {
            .stop => "STOP",
            .delete => "DELETE",
            .unknown => unreachable, // The client refuses it first.
        });
    }
    if (spec.spot) {
        try jw.objectField("provisioningModel");
        try jw.write("SPOT");
    }
    try jw.endObject();
}

/// `projects/P/global/images/family/F`, `projects/P/global/images/N`, or
/// the path as given.
pub fn imagePath(arena: Allocator, ref: types.ImageRef) Allocator.Error![]const u8 {
    return switch (ref) {
        .family => |f| std.fmt.allocPrint(arena, "projects/{s}/global/images/family/{s}", .{ f.project, f.name }),
        .image => |i| std.fmt.allocPrint(arena, "projects/{s}/global/images/{s}", .{ i.project, i.name }),
        .path => |p| p,
    };
}

/// A template's path in `project`.
pub fn templatePath(arena: Allocator, project: []const u8, ref: types.TemplateRef) Allocator.Error![]const u8 {
    return switch (ref) {
        .global => |name| std.fmt.allocPrint(arena, "projects/{s}/global/instanceTemplates/{s}", .{ project, name }),
        .regional => |r| std.fmt.allocPrint(arena, "projects/{s}/regions/{s}/instanceTemplates/{s}", .{ project, r.region, r.name }),
    };
}

/// A name becomes `zones/Z/<kind>/<name>`; a path or URL is kept.
fn zonal(arena: Allocator, zone: []const u8, comptime kind: []const u8, name: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return name;
    return std.fmt.allocPrint(arena, "zones/{s}/" ++ kind ++ "/{s}", .{ zone, name });
}

/// A name becomes `global/<kind>/<name>`; a path or URL is kept.
fn global(arena: Allocator, comptime kind: []const u8, name: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return name;
    return std.fmt.allocPrint(arena, "global/" ++ kind ++ "/{s}", .{name});
}

/// A name becomes `regions/R/<kind>/<name>`, R the zone's region; a path
/// or URL is kept.
fn regional(arena: Allocator, zone: []const u8, comptime kind: []const u8, name: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return name;
    return std.fmt.allocPrint(arena, "regions/{s}/" ++ kind ++ "/{s}", .{ regionOf(zone), name });
}

/// `us-central1` from `us-central1-a`.
pub fn regionOf(zone: []const u8) []const u8 {
    const dash = std.mem.lastIndexOfScalar(u8, zone, '-') orelse return zone;
    return zone[0..dash];
}

const testing = std.testing;

test "instance: milestone 0's insert, byte for byte in its order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try instance(arena.allocator(), "us-central1-a", .{
        .name = "zigps-m0-11031830-a",
        .machine_type = "e2-micro",
        .image = .{ .family = .{ .project = "debian-cloud", .name = "debian-12" } },
        .boot_disk = .{ .size_gb = 10, .type = "pd-standard" },
        .spot = true,
        .max_run_duration_s = 3600,
        .termination_action = .delete,
        .labels = &.{ .{ .key = "purpose", .value = "gcp-zig-test" }, .{ .key = "tool", .value = "compute-m0" } },
        .metadata = &.{ .{ .key = "startup-script", .value = "#!/bin/bash\necho hi\n" }, .{ .key = "enable-guest-attributes", .value = "TRUE" } },
    });
    try testing.expectEqualStrings(
        \\{"name":"zigps-m0-11031830-a","machineType":"zones/us-central1-a/machineTypes/e2-micro","labels":{"purpose":"gcp-zig-test","tool":"compute-m0"},"disks":[{"boot":true,"autoDelete":true,"initializeParams":{"sourceImage":"projects/debian-cloud/global/images/family/debian-12","diskSizeGb":"10","diskType":"zones/us-central1-a/diskTypes/pd-standard"}}],"networkInterfaces":[{"network":"global/networks/default"}],"metadata":{"items":[{"key":"startup-script","value":"#!/bin/bash\necho hi\n"},{"key":"enable-guest-attributes","value":"TRUE"}]},"scheduling":{"automaticRestart":false,"maxRunDuration":{"seconds":"3600"},"instanceTerminationAction":"DELETE","provisioningModel":"SPOT"}}
    , got);
}

test "instance: the least, and every other field" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        \\{"name":"web-1","machineType":"zones/europe-west1-b/machineTypes/n2-standard-4","disks":[{"boot":true,"autoDelete":true,"initializeParams":{"sourceImage":"projects/my-project/global/images/web-v3"}}],"networkInterfaces":[{"network":"global/networks/default"}]}
    , try instance(a, "europe-west1-b", .{ .name = "web-1", .machine_type = "n2-standard-4", .image = .{ .image = .{ .project = "my-project", .name = "web-v3" } } }));
    try testing.expectEqualStrings(
        \\{"name":"web-2","description":"the second","machineType":"zones/europe-west1-b/machineTypes/n2-standard-4","tags":{"items":["http-server","ssh"]},"disks":[{"boot":true,"autoDelete":false,"initializeParams":{"sourceImage":"global/images/web-v3","diskType":"projects/p/zones/europe-west1-b/diskTypes/pd-ssd"}}],"networkInterfaces":[{"network":"projects/shared/global/networks/vpc","subnetwork":"regions/europe-west1/subnetworks/apps","accessConfigs":[{"name":"External NAT","type":"ONE_TO_ONE_NAT"}]}],"metadata":{"items":[{"key":"flag"}]},"serviceAccounts":[{"email":"web@p.iam.gserviceaccount.com","scopes":["https://www.googleapis.com/auth/cloud-platform"]}],"scheduling":{"automaticRestart":true,"instanceTerminationAction":"STOP"},"deletionProtection":true}
    , try instance(a, "europe-west1-b", .{
        .name = "web-2",
        .description = "the second",
        .machine_type = "n2-standard-4",
        .image = .{ .path = "global/images/web-v3" },
        .boot_disk = .{ .type = "projects/p/zones/europe-west1-b/diskTypes/pd-ssd", .auto_delete = false },
        .tags = &.{ "http-server", "ssh" },
        .network = "projects/shared/global/networks/vpc",
        .subnetwork = "apps",
        .external_ip = true,
        .metadata = &.{.{ .key = "flag" }},
        .service_account = .{ .email = "web@p.iam.gserviceaccount.com" },
        .automatic_restart = true,
        .termination_action = .stop,
        .deletion_protection = true,
    }));
    try testing.expectEqualStrings("{\"name\":\"web-3\"}", try nameOnly(a, "web-3"));
}

test "paths: images, templates, regions" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("projects/p/global/instanceTemplates/t", try templatePath(a, "p", .{ .global = "t" }));
    try testing.expectEqualStrings("projects/p/regions/us-east1/instanceTemplates/t", try templatePath(a, "p", .{ .regional = .{ .region = "us-east1", .name = "t" } }));
    try testing.expectEqualStrings("us-central1", regionOf("us-central1-a"));
    try testing.expectEqualStrings("europe-west1", regionOf("europe-west1-b"));
}
