//! Prints a bucket's settings, every one a read gives, as a console's
//! bucket page shows them.
//!
//!     zig build example-gcs_bucket -- my-bucket
//!
//! Where it is, its class and protection, its labels and lifecycle, and
//! the settings this library reads but does not set: Autoclass, CORS, the
//! website, access logging, the IP filter and replication. A setting the
//! bucket does not have says so. The IP filter needs
//! `storage.buckets.getIpFilter`, which `roles/storage.admin` holds; a
//! caller without it reads the bucket with no filter in it, so this says
//! "none, or not readable".
//!
//! Credentials come from `auth.findDefault`, as for gcs_cp. Against the
//! emulator, which keeps none of these settings, it prints the few there
//! are.

const std = @import("std");
const auth = @import("auth");
const storage = @import("storage");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{ .scope = .gcp_storage, .level = .warn }},
};

const usage =
    \\usage: gcs_bucket BUCKET
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};
    if (args.len != 2 or std.mem.startsWith(u8, args[1], "-")) return badUsage(out);

    const endpoint = storage.Endpoint.fromEnv(init.environ_map);
    var diag: storage.Diagnostics = .{};
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    if (endpoint == null) {
        var lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
        lookup.diagnostics = &diag;
        creds = auth.findDefault(init.gpa, init.io, lookup, .{}) catch |err| return fail(err, &diag);
    }
    var client = storage.Client.init(init.gpa, init.io, .{
        .endpoint = endpoint,
        .token_provider = if (creds) |c| c.provider() else null,
        .diagnostics = &diag,
    }) catch |err| return fail(err, &diag);
    defer client.deinit();

    var read = client.bucket(args[1]).get() catch |err| return fail(err, &diag);
    defer read.deinit();
    try page(out, read.value);
}

fn page(out: *std.Io.Writer, b: storage.BucketInfo) !void {
    try out.print("{s}\n", .{b.name});
    try out.print("  location        {s} ({s})\n", .{ b.location, b.location_type orelse "type not given" });
    if (b.data_locations.len > 0) {
        try out.writeAll("  regions        ");
        for (b.data_locations) |region| try out.print(" {s}", .{region});
        try out.writeByte('\n');
    }
    try out.print("  replication     {s}\n", .{if (b.rpo) |rpo| switch (rpo) {
        .default => "default",
        .async_turbo => "turbo",
        .unknown => "a kind this library does not know",
    } else "none (a single region)"});
    try out.print("  class           {s}\n", .{b.storage_class});
    if (b.autoclass) |a| {
        if (a.enabled) {
            try out.print("  autoclass       on, down to {s}\n", .{a.terminal_storage_class orelse "NEARLINE"});
        } else {
            try out.print("  autoclass       off since {s}\n", .{a.toggle_time orelse "a time not given"});
        }
    } else try out.writeAll("  autoclass       never on\n");
    try out.print("  created         {s}\n", .{b.time_created});
    try out.print("  versioning      {s}\n", .{onOff(b.versioning)});
    if (b.soft_delete) |s| {
        try out.print("  soft delete     {d} s\n", .{s.retention_s});
    } else try out.writeAll("  soft delete     off\n");
    if (b.retention_policy) |r| {
        try out.print("  retention       {d} s{s}\n", .{ r.period_s, if (r.locked) ", locked" else "" });
    }
    try out.print("  uniform access  {s}\n", .{onOff(b.uniform_bucket_level_access)});
    try out.print("  public access   {t}\n", .{b.public_access_prevention});
    try out.print("  requester pays  {s}\n", .{onOff(b.requester_pays)});
    if (b.default_kms_key_name) |key| try out.print("  default key     {s}\n", .{key});
    if (b.hierarchical_namespace) try out.writeAll("  namespace       hierarchical\n");
    for (b.labels) |label| try out.print("  label           {s}={s}\n", .{ label.key, label.value });
    if (b.lifecycle.len > 0) try out.print("  lifecycle       {d} rule(s)\n", .{b.lifecycle.len});

    if (b.cors.len == 0) try out.writeAll("  CORS            none\n");
    for (b.cors, 1..) |rule, i| {
        try out.print("  CORS rule {d}     origins", .{i});
        try list(out, rule.origins);
        try out.writeAll("; methods");
        try list(out, rule.methods);
        if (rule.response_headers.len > 0) {
            try out.writeAll("; headers");
            try list(out, rule.response_headers);
        }
        if (rule.max_age_s) |age| try out.print("; cached {d} s", .{age});
        try out.writeByte('\n');
    }
    if (b.website) |w| {
        try out.print("  website         main page {s}, not found {s}\n", .{ w.main_page_suffix orelse "none", w.not_found_page orelse "none" });
    } else try out.writeAll("  website         none\n");
    if (b.logging) |l| {
        try out.print("  access logs     to gs://{s}/{s}\n", .{ l.log_bucket, l.log_object_prefix orelse "" });
    } else try out.writeAll("  access logs     none\n");
    if (b.ip_filter) |f| {
        try out.print("  IP filter       {s}\n", .{if (f.enforced) "enforced" else "not enforced"});
        if (f.public_ranges.len > 0) {
            try out.writeAll("    public       ");
            try list(out, f.public_ranges);
            try out.writeByte('\n');
        }
        for (f.vpc_sources) |source| {
            try out.print("    network      {s}:", .{source.network});
            try list(out, source.ranges);
            try out.writeByte('\n');
        }
        try out.print("    other orgs' networks {s}, service agents {s}\n", .{ allowed(f.allow_cross_org_vpcs), allowed(f.allow_all_service_agent_access) });
    } else try out.writeAll("  IP filter       none, or not readable\n");
}

fn list(out: *std.Io.Writer, items: []const []const u8) !void {
    if (items.len == 0) return out.writeAll(" none");
    for (items) |item| try out.print(" {s}", .{item});
}

fn onOff(on: bool) []const u8 {
    return if (on) "on" else "off";
}

fn allowed(yes: bool) []const u8 {
    return if (yes) "allowed" else "not allowed";
}

fn badUsage(out: *std.Io.Writer) !void {
    try out.writeAll(usage);
    try out.flush();
    return error.BadUsage;
}

fn fail(err: anyerror, diag: *const storage.Diagnostics) anyerror {
    if (diag.message().len > 0) {
        std.debug.print("error: {t}: {s}\n", .{ err, diag.message() });
    } else {
        std.debug.print("error: {t}\n", .{err});
    }
    return err;
}
