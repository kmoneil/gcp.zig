//! What `FakeDataflow` holds of a job in full and of its metrics (#310),
//! and how it writes them, in production's wire names: the pipeline, the
//! environment, the SDK and the steps a get carries at each view, and
//! getMetrics' answer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const core = @import("core");
const types = @import("types.zig");

/// What a job's JSON carries, by how it was asked for. A list answers
/// summaries; a plain get adds labels, stage states and a few of the
/// environment's fields; DESCRIPTION adds the rest of the environment
/// and the pipeline; ALL adds the steps (measured 2026-10-20 and
/// 2026-11-07). Every one carries the SDK, in `jobMetadata`.
pub const Level = enum {
    summary,
    get,
    description,
    all,

    /// A get's level from its `view`, or null for a view production
    /// refuses. `JOB_VIEW_UNKNOWN` and `JOB_VIEW_SUMMARY` are a plain get.
    pub fn ofView(view: ?[]const u8) ?Level {
        const name = view orelse return .get;
        if (std.mem.eql(u8, name, "JOB_VIEW_DESCRIPTION")) return .description;
        if (std.mem.eql(u8, name, "JOB_VIEW_ALL")) return .all;
        if (std.mem.eql(u8, name, "JOB_VIEW_SUMMARY") or std.mem.eql(u8, name, "JOB_VIEW_UNKNOWN")) return .get;
        return null;
    }

    fn full(level: Level) bool {
        return level == .description or level == .all;
    }
};

/// A deep copy of `v` in `s`: every slice, and every string in it, copied.
pub fn deepCopy(s: Allocator, comptime T: type, v: T) Allocator.Error!T {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size != .slice) @compileError("deepCopy copies slices, not " ++ @typeName(T));
            if (p.child == u8) return try s.dupe(u8, v);
            const items = try s.alloc(p.child, v.len);
            for (v, items) |x, *y| y.* = try deepCopy(s, p.child, x);
            return items;
        },
        .@"struct" => |info| {
            var out: T = v;
            inline for (info.field_names, info.field_types) |name, F| @field(out, name) = try deepCopy(s, F, @field(v, name));
            return out;
        },
        .@"union" => switch (v) {
            inline else => |payload, tag| return @unionInit(T, @tagName(tag), try deepCopy(s, @TypeOf(payload), payload)),
        },
        .optional => |o| return if (v) |x| try deepCopy(s, o.child, x) else null,
        else => return v,
    }
}

/// Whether each step's properties are a JSON object, as the fake must
/// write them back whole.
pub fn stepsValid(scratch: Allocator, steps: []const types.Step) Allocator.Error!bool {
    for (steps) |step| {
        if (step.properties.len == 0) continue;
        if (!try isJsonObject(scratch, step.properties)) return false;
    }
    return true;
}

/// Whether each update's value kept as JSON text is JSON, and a mean an
/// object, as the fake must write them back.
pub fn metricsValid(scratch: Allocator, metrics: types.JobMetrics) Allocator.Error!bool {
    for (metrics.updates) |u| switch (u.value) {
        .other => |o| {
            if (std.mem.eql(u8, o.field, "mean")) {
                if (!try isJsonObject(scratch, o.json)) return false;
            } else if (!try std.json.validate(scratch, o.json)) return false;
        },
        else => {},
    };
    return true;
}

fn isJsonObject(scratch: Allocator, text: []const u8) Allocator.Error!bool {
    const v = std.json.parseFromSliceLeaky(std.json.Value, scratch, text, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    return v == .object;
}

/// `environment`: a plain get carries production's few, the shuffle mode
/// and public IPs here; DESCRIPTION and ALL the rest. A list none.
pub fn writeEnvironment(jw: *Stringify, e: types.Environment, level: Level) Stringify.Error!void {
    if (level == .summary) return;
    const full = level.full();
    try jw.objectField("environment");
    try jw.beginObject();
    if (full) {
        try str(jw, "dataset", e.dataset);
        try strings(jw, "experiments", e.experiments);
        try str(jw, "flexResourceSchedulingGoal", e.flex_resource_scheduling_goal);
        try str(jw, "serviceAccountEmail", e.service_account);
        try str(jw, "serviceKmsKeyName", e.service_kms_key_name);
        try strings(jw, "serviceOptions", e.service_options);
    }
    try str(jw, "shuffleMode", e.shuffle_mode);
    if (full) {
        try str(jw, "streamingMode", e.streaming_mode);
        try str(jw, "tempStoragePrefix", e.temp_storage_prefix);
    }
    if (e.use_public_ips) |b| {
        try jw.objectField("usePublicIps");
        try jw.write(b);
    }
    if (full) {
        if (e.worker_pools.len > 0) {
            try jw.objectField("workerPools");
            try jw.beginArray();
            for (e.worker_pools) |p| try writePool(jw, p);
            try jw.endArray();
        }
        try str(jw, "workerRegion", e.worker_region);
        try str(jw, "workerZone", e.worker_zone);
    }
    try jw.endObject();
}

fn writePool(jw: *Stringify, p: types.WorkerPool) Stringify.Error!void {
    try jw.beginObject();
    if (p.max_workers != null or p.autoscaling_algorithm.len > 0) {
        try jw.objectField("autoscalingSettings");
        try jw.beginObject();
        try str(jw, "algorithm", p.autoscaling_algorithm);
        try number(jw, "maxNumWorkers", p.max_workers);
        try jw.endObject();
    }
    try number(jw, "diskSizeGb", p.disk_size_gb);
    try str(jw, "diskType", p.disk_type);
    try str(jw, "ipConfiguration", p.ip_configuration);
    try str(jw, "kind", p.kind);
    try str(jw, "machineType", p.machine_type);
    try str(jw, "network", p.network);
    try number(jw, "numWorkers", p.num_workers);
    try str(jw, "onHostMaintenance", p.on_host_maintenance);
    try str(jw, "subnetwork", p.subnetwork);
    try str(jw, "teardownPolicy", p.teardown_policy);
    try str(jw, "workerHarnessContainerImage", p.harness_image);
    try str(jw, "zone", p.zone);
    try jw.endObject();
}

/// `jobMetadata.sdkVersion`, which every answer carries.
pub fn writeSdk(jw: *Stringify, sdk: types.Sdk) Stringify.Error!void {
    if (sdk.version.len == 0 and sdk.name.len == 0 and sdk.support == .unknown) return;
    try jw.objectField("jobMetadata");
    try jw.beginObject();
    try jw.objectField("sdkVersion");
    try jw.beginObject();
    if (sdk.support != .unknown) {
        try jw.objectField("sdkSupportStatus");
        try jw.write(switch (sdk.support) {
            .supported => "SUPPORTED",
            .stale => "STALE",
            .deprecated => "DEPRECATED",
            .unsupported => "UNSUPPORTED",
            .unknown => unreachable,
        });
    }
    try str(jw, "version", sdk.version);
    try str(jw, "versionDisplayName", sdk.name);
    try jw.endObject();
    try jw.endObject();
}

/// `pipelineDescription`, at DESCRIPTION and ALL; `stepNamesHash` at ALL
/// alone, as production answered (measured 2026-11-07).
pub fn writePipeline(jw: *Stringify, p: types.Pipeline, level: Level) Stringify.Error!void {
    if (!level.full()) return;
    const hash = if (level == .all) p.step_names_hash else "";
    if (p.transforms.len == 0 and p.stages.len == 0 and p.display_data.len == 0 and hash.len == 0) return;
    try jw.objectField("pipelineDescription");
    try jw.beginObject();
    try writeDisplayData(jw, p.display_data);
    if (p.stages.len > 0) {
        try jw.objectField("executionPipelineStage");
        try jw.beginArray();
        for (p.stages) |stage| try writeStage(jw, stage);
        try jw.endArray();
    }
    if (p.transforms.len > 0) {
        try jw.objectField("originalPipelineTransform");
        try jw.beginArray();
        for (p.transforms) |t| try writeTransform(jw, t);
        try jw.endArray();
    }
    try str(jw, "stepNamesHash", hash);
    try jw.endObject();
}

fn writeTransform(jw: *Stringify, t: types.Transform) Stringify.Error!void {
    try jw.beginObject();
    try writeDisplayData(jw, t.display_data);
    try str(jw, "id", t.id);
    try strings(jw, "inputCollectionName", t.input_collections);
    try jw.objectField("kind");
    try jw.write(kindWire(t.kind));
    try str(jw, "name", t.name);
    try strings(jw, "outputCollectionName", t.output_collections);
    try jw.endObject();
}

fn writeStage(jw: *Stringify, s: types.Stage) Stringify.Error!void {
    try jw.beginObject();
    try writeComponents(jw, "componentSource", "originalTransformOrCollection", s.sources);
    try writeComponents(jw, "componentTransform", "originalTransform", s.transforms);
    try str(jw, "id", s.id);
    try writeSources(jw, "inputSource", s.inputs);
    try jw.objectField("kind");
    try jw.write(kindWire(s.kind));
    try str(jw, "name", s.name);
    try writeSources(jw, "outputSource", s.outputs);
    try strings(jw, "prerequisiteStage", s.prerequisites);
    try jw.endObject();
}

fn writeComponents(jw: *Stringify, key: []const u8, original: []const u8, items: []const types.StageComponent) Stringify.Error!void {
    if (items.len == 0) return;
    try jw.objectField(key);
    try jw.beginArray();
    for (items) |c| {
        try jw.beginObject();
        try str(jw, "name", c.name);
        try str(jw, original, c.original);
        try str(jw, "userName", c.user_name);
        try jw.endObject();
    }
    try jw.endArray();
}

fn writeSources(jw: *Stringify, key: []const u8, items: []const types.StageSource) Stringify.Error!void {
    if (items.len == 0) return;
    try jw.objectField(key);
    try jw.beginArray();
    for (items) |src| {
        try jw.beginObject();
        try str(jw, "name", src.name);
        try str(jw, "originalTransformOrCollection", src.original);
        // An int64, which proto3 JSON writes as a string.
        if (src.size_bytes) |n| {
            try jw.objectField("sizeBytes");
            try jw.print("\"{d}\"", .{n});
        }
        try str(jw, "userName", src.user_name);
        try jw.endObject();
    }
    try jw.endArray();
}

fn writeDisplayData(jw: *Stringify, items: []const types.DisplayData) Stringify.Error!void {
    if (items.len == 0) return;
    try jw.objectField("displayData");
    try jw.beginArray();
    for (items) |d| {
        try jw.beginObject();
        try str(jw, "key", d.key);
        try str(jw, "label", d.label);
        try str(jw, "namespace", d.namespace);
        try str(jw, "shortStrValue", d.short);
        try str(jw, "url", d.url);
        var buf: [core.timestamp.max_len]u8 = undefined;
        switch (d.value) {
            .none => {},
            .string => |s| try field(jw, "strValue", s),
            .integer => |n| {
                try jw.objectField("int64Value");
                try jw.print("\"{d}\"", .{n});
            },
            .float => |f| {
                try jw.objectField("floatValue");
                try jw.write(f);
            },
            .boolean => |b| {
                try jw.objectField("boolValue");
                try jw.write(b);
            },
            .timestamp => |t| try field(jw, "timestampValue", core.timestamp.format(&buf, t)),
            .duration => |s| try field(jw, "durationValue", s),
            .java_class => |s| try field(jw, "javaClassValue", s),
        }
        try jw.endObject();
    }
    try jw.endArray();
}

/// `steps`, at ALL, each step's properties written back as given.
pub fn writeSteps(jw: *Stringify, steps: []const types.Step, level: Level) Stringify.Error!void {
    if (level != .all or steps.len == 0) return;
    try jw.objectField("steps");
    try jw.beginArray();
    for (steps) |step| {
        try jw.beginObject();
        try str(jw, "kind", step.kind);
        try str(jw, "name", step.name);
        if (step.properties.len > 0) {
            try jw.objectField("properties");
            try jw.print("{s}", .{step.properties});
        }
        try jw.endObject();
    }
    try jw.endArray();
}

/// getMetrics' answer: the updates made at or after `start`. With none
/// left, the time is `start` itself, as production echoed a time past
/// every update (measured 2026-11-07).
pub fn metricsReply(arena: Allocator, metrics: types.JobMetrics, start: ?std.Io.Timestamp) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeMetrics(&jw, arena, metrics, start) catch return error.OutOfMemory;
    return out.written();
}

fn writeMetrics(jw: *Stringify, arena: Allocator, metrics: types.JobMetrics, start: ?std.Io.Timestamp) !void {
    var kept: std.ArrayList(types.MetricUpdate) = .empty;
    for (metrics.updates) |u| {
        if (start) |s| if (u.update_time) |t| if (t.nanoseconds < s.nanoseconds) continue;
        try kept.append(arena, u);
    }
    const time = if (start != null and kept.items.len == 0) start else metrics.metric_time;
    var buf: [core.timestamp.max_len]u8 = undefined;
    try jw.beginObject();
    if (time) |t| try field(jw, "metricTime", core.timestamp.format(&buf, t));
    if (kept.items.len > 0) {
        try jw.objectField("metrics");
        try jw.beginArray();
        for (kept.items) |u| try writeUpdate(jw, arena, u);
        try jw.endArray();
    }
    try jw.endObject();
}

fn writeUpdate(jw: *Stringify, arena: Allocator, u: types.MetricUpdate) !void {
    var buf: [core.timestamp.max_len]u8 = undefined;
    try jw.beginObject();
    if (u.cumulative) |c| {
        try jw.objectField("cumulative");
        try jw.write(c);
    }
    try str(jw, "kind", u.kind);
    try jw.objectField("name");
    try jw.beginObject();
    // Production marks a tentative update in its context; a test that set
    // only the flag gets the mark written for it, so it reads back so.
    const marked = u.contextValue("tentative") != null;
    if (u.context.len > 0 or u.tentative) {
        try jw.objectField("context");
        try jw.beginObject();
        for (u.context) |c| try field(jw, c.key, c.value);
        if (u.tentative and !marked) try field(jw, "tentative", "true");
        try jw.endObject();
    }
    try str(jw, "name", u.name);
    try str(jw, "origin", u.origin);
    try jw.endObject();
    switch (u.value) {
        .none => {},
        .integer => |n| {
            try jw.objectField("scalar");
            try jw.write(n);
        },
        .float => |f| {
            try jw.objectField("scalar");
            try jw.write(f);
        },
        .boolean => |b| {
            try jw.objectField("scalar");
            try jw.write(b);
        },
        .other => |o| if (std.mem.eql(u8, o.field, "mean")) {
            // `{"meanSum":...,"meanCount":...}`, its members written back
            // as the update's own.
            const mean = try std.json.parseFromSliceLeaky(std.json.Value, arena, o.json, .{ .parse_numbers = false });
            for (mean.object.keys(), mean.object.values()) |k, v| {
                try jw.objectField(k);
                try jw.write(v);
            }
        } else {
            try jw.objectField(o.field);
            try jw.print("{s}", .{o.json});
        },
    }
    if (u.update_time) |t| try field(jw, "updateTime", core.timestamp.format(&buf, t));
    try jw.endObject();
}

fn kindWire(kind: types.TransformKind) []const u8 {
    return switch (kind) {
        .unknown => "UNKNOWN_KIND",
        .par_do => "PAR_DO_KIND",
        .group_by_key => "GROUP_BY_KEY_KIND",
        .flatten => "FLATTEN_KIND",
        .read => "READ_KIND",
        .write => "WRITE_KIND",
        .constant => "CONSTANT_KIND",
        .singleton => "SINGLETON_KIND",
        .shuffle => "SHUFFLE_KIND",
    };
}

/// A string field, left out when empty.
fn str(jw: *Stringify, name: []const u8, value: []const u8) Stringify.Error!void {
    if (value.len == 0) return;
    try field(jw, name, value);
}

fn field(jw: *Stringify, name: []const u8, value: []const u8) Stringify.Error!void {
    try jw.objectField(name);
    try jw.write(value);
}

/// A list of strings, left out when empty.
fn strings(jw: *Stringify, name: []const u8, values: []const []const u8) Stringify.Error!void {
    if (values.len == 0) return;
    try jw.objectField(name);
    try jw.beginArray();
    for (values) |v| try jw.write(v);
    try jw.endArray();
}

/// An int32 field, left out when null.
fn number(jw: *Stringify, name: []const u8, value: ?i64) Stringify.Error!void {
    const n = value orelse return;
    try jw.objectField(name);
    try jw.write(n);
}
