//! Decoders for BigQuery's JSON. The schemas are large; the decode keeps
//! what the types hold and skips the rest, lenient the way the other
//! modules are: unknown fields skipped, unknown enum values read as
//! `.unknown`. Every int64 and uint64 arrives as a JSON string, and times
//! as milliseconds since the epoch in one (measured). A resource without
//! its reference is `error.InvalidResponse`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const types = @import("types.zig");

pub const DecodeError = error{ OutOfMemory, InvalidResponse };

/// A dataset, as get answers.
pub fn decodeDataset(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.Dataset {
    return datasetOf(out, try object(try parse(scratch, body)));
}

/// A page of `datasets.list`: no `datasets` is an empty last page.
pub fn decodeDatasetPage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.DatasetPage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "datasets", .array);
    const datasets = try out.alloc(types.Dataset, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, datasets) |v, *d| {
        d.* = try datasetOf(out, try object(v));
    };
    return .{
        .datasets = datasets,
        .next_page_token = try token(out, obj, "nextPageToken"),
        .unreachable_locations = try stringList(out, obj, "unreachable"),
    };
}

/// A table, as get answers.
pub fn decodeTable(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.Table {
    return tableOf(out, try object(try parse(scratch, body)));
}

/// A page of `tables.list`.
pub fn decodeTablePage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.TablePage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "tables", .array);
    const tables = try out.alloc(types.Table, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, tables) |v, *t| {
        t.* = try tableOf(out, try object(v));
    };
    return .{
        .tables = tables,
        .next_page_token = try token(out, obj, "nextPageToken"),
        .total_items = try integer(u32, obj, "totalItems"),
    };
}

/// A job, as get answers, and as a cancel answers it inside `job`.
pub fn decodeJob(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.Job {
    return jobOf(out, try object(try parse(scratch, body)));
}

/// A cancel's answer: `{"job": Job}`.
pub fn decodeCancel(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.Job {
    const obj = try object(try parse(scratch, body));
    return jobOf(out, try field(obj, "job", .object) orelse return error.InvalidResponse);
}

/// A page of `jobs.list`, newest first as production lists them.
pub fn decodeJobPage(out: Allocator, scratch: Allocator, body: []const u8) DecodeError!types.JobPage {
    const obj = try object(try parse(scratch, body));
    const list = try field(obj, "jobs", .array);
    const jobs = try out.alloc(types.Job, if (list) |l| l.items.len else 0);
    if (list) |l| for (l.items, jobs) |v, *j| {
        j.* = try jobOf(out, try object(v));
    };
    return .{
        .jobs = jobs,
        .next_page_token = try token(out, obj, "nextPageToken"),
        .unreachable_locations = try stringList(out, obj, "unreachable"),
    };
}

fn datasetOf(out: Allocator, obj: ObjectMap) DecodeError!types.Dataset {
    const ref = try field(obj, "datasetReference", .object) orelse return error.InvalidResponse;
    return .{
        .ref = .{
            .project = try string(out, ref, "projectId") orelse return error.InvalidResponse,
            .dataset = try string(out, ref, "datasetId") orelse return error.InvalidResponse,
        },
        .friendly_name = try string(out, obj, "friendlyName") orelse "",
        .description = try string(out, obj, "description") orelse "",
        .labels = try labelMap(out, obj, "labels"),
        .location = try string(out, obj, "location") orelse "",
        .creation_time = try millis(obj, "creationTime"),
        .last_modified_time = try millis(obj, "lastModifiedTime"),
        .default_table_expiration_ms = try integer(i64, obj, "defaultTableExpirationMs"),
        .default_partition_expiration_ms = try integer(i64, obj, "defaultPartitionExpirationMs"),
        .type = try string(out, obj, "type") orelse "",
    };
}

fn tableOf(out: Allocator, obj: ObjectMap) DecodeError!types.Table {
    const ref = try field(obj, "tableReference", .object) orelse return error.InvalidResponse;
    var table: types.Table = .{
        .ref = .{
            .project = try string(out, ref, "projectId") orelse return error.InvalidResponse,
            .dataset = try string(out, ref, "datasetId") orelse return error.InvalidResponse,
            .table = try string(out, ref, "tableId") orelse return error.InvalidResponse,
        },
        .type = if (try field(obj, "type", .string)) |s| types.TableType.fromWire(s) else .table,
        .num_rows = try integer(u64, obj, "numRows"),
        .num_bytes = try integer(u64, obj, "numBytes"),
        .require_partition_filter = try boolean(obj, "requirePartitionFilter") orelse false,
        .friendly_name = try string(out, obj, "friendlyName") orelse "",
        .description = try string(out, obj, "description") orelse "",
        .labels = try labelMap(out, obj, "labels"),
        .location = try string(out, obj, "location") orelse "",
        .creation_time = try millis(obj, "creationTime"),
        .last_modified_time = try millis(obj, "lastModifiedTime"),
        .expiration_time = try millis(obj, "expirationTime"),
    };
    if (try field(obj, "schema", .object)) |schema| table.schema = try fieldList(out, schema);
    if (try field(obj, "timePartitioning", .object)) |p| table.time_partitioning = .{
        .type = try string(out, p, "type") orelse "",
        .field = try string(out, p, "field") orelse "",
        .expiration_ms = try integer(i64, p, "expirationMs"),
    };
    if (try field(obj, "rangePartitioning", .object)) |p| {
        const range = try field(p, "range", .object) orelse return error.InvalidResponse;
        table.range_partitioning = .{
            .field = try string(out, p, "field") orelse "",
            .start = try integer(i64, range, "start") orelse 0,
            .end = try integer(i64, range, "end") orelse 0,
            .interval = try integer(i64, range, "interval") orelse 0,
        };
    }
    if (try field(obj, "clustering", .object)) |c| table.clustering = try stringList(out, c, "fields");
    if (try field(obj, "view", .object)) |v| {
        table.view_query = try string(out, v, "query");
        table.view_uses_legacy_sql = try boolean(v, "useLegacySql") orelse false;
    }
    if (try field(obj, "materializedView", .object)) |m| table.materialized_view = .{
        .query = try string(out, m, "query") orelse "",
        .enable_refresh = try boolean(m, "enableRefresh") orelse true,
        .refresh_interval_ms = try integer(i64, m, "refreshIntervalMs"),
        .last_refresh_time = try millis(m, "lastRefreshTime"),
    };
    return table;
}

/// How deep records nest in a schema: BigQuery allows 15 levels. A
/// deeper one is `error.InvalidResponse`, so a body cannot run the
/// decode, which recurses once a level, out of stack.
pub const max_record_depth = 15;

/// A schema's `fields`, nested records included.
pub fn fieldList(out: Allocator, schema: ObjectMap) DecodeError![]const types.Field {
    return fieldListAt(out, schema, 0);
}

fn fieldListAt(out: Allocator, schema: ObjectMap, depth: usize) DecodeError![]const types.Field {
    const list = try field(schema, "fields", .array) orelse return &.{};
    if (depth > max_record_depth) return error.InvalidResponse;
    const fields = try out.alloc(types.Field, list.items.len);
    for (list.items, fields) |item, *f| f.* = try fieldOf(out, try object(item), depth);
    return fields;
}

fn fieldOf(out: Allocator, obj: ObjectMap, depth: usize) DecodeError!types.Field {
    const name = try string(out, obj, "name") orelse return error.InvalidResponse;
    const type_name = try string(out, obj, "type") orelse "";
    var range_element: ?types.FieldType = null;
    if (try field(obj, "rangeElementType", .object)) |r| {
        if (try field(r, "type", .string)) |s| range_element = types.FieldType.fromWire(s);
    }
    return .{
        .name = name,
        .type = types.FieldType.fromWire(type_name),
        .type_name = type_name,
        .mode = if (try field(obj, "mode", .string)) |s| types.FieldMode.fromWire(s) else .nullable,
        .fields = try fieldListAt(out, obj, depth + 1),
        .range_element = range_element,
        .description = try string(out, obj, "description") orelse "",
        .precision = try integer(i64, obj, "precision"),
        .scale = try integer(i64, obj, "scale"),
        .max_length = try integer(i64, obj, "maxLength"),
    };
}

fn jobOf(out: Allocator, obj: ObjectMap) DecodeError!types.Job {
    const ref = try field(obj, "jobReference", .object) orelse return error.InvalidResponse;
    var job: types.Job = .{
        .ref = .{
            .project = try string(out, ref, "projectId") orelse return error.InvalidResponse,
            // A dry run's job has none (measured).
            .id = try string(out, ref, "jobId") orelse "",
            .location = try string(out, ref, "location") orelse "",
        },
        // `user_email` is snake case on the wire.
        .user_email = try string(out, obj, "user_email") orelse "",
    };
    // A list item carries `state` and `errorResult` at its top; a job,
    // inside `status`.
    if (try field(obj, "state", .string)) |s| job.state = types.JobState.fromWire(s);
    if (try field(obj, "errorResult", .object)) |e| job.@"error" = try jobError(out, e);
    if (try field(obj, "status", .object)) |status| {
        if (try field(status, "state", .string)) |s| job.state = types.JobState.fromWire(s);
        if (try field(status, "errorResult", .object)) |e| job.@"error" = try jobError(out, e);
        if (try field(status, "errors", .array)) |list| {
            const errs = try out.alloc(types.JobError, list.items.len);
            for (list.items, errs) |item, *e| e.* = try jobError(out, try object(item));
            job.errors = errs;
        }
    }
    if (try field(obj, "configuration", .object)) |config| {
        if (try field(config, "jobType", .string)) |s| job.type = types.JobType.fromWire(s);
        job.dry_run = try boolean(config, "dryRun") orelse false;
        job.labels = try labelMap(out, config, "labels");
        if (try field(config, "query", .object)) |q| {
            job.query = try string(out, q, "query") orelse "";
            if (job.type == .unknown) job.type = .query;
        }
    }
    if (try field(obj, "statistics", .object)) |stats| {
        job.creation_time = try millis(stats, "creationTime");
        job.start_time = try millis(stats, "startTime");
        job.end_time = try millis(stats, "endTime");
        job.total_bytes_processed = try integer(u64, stats, "totalBytesProcessed");
        if (try field(stats, "query", .object)) |q| {
            if (job.type == .unknown) job.type = .query;
            job.statement_type = try string(out, q, "statementType") orelse "";
            if (try integer(u64, q, "totalBytesProcessed")) |n| job.total_bytes_processed = n;
            job.total_bytes_billed = try integer(u64, q, "totalBytesBilled");
            job.cache_hit = try boolean(q, "cacheHit");
            job.num_dml_affected_rows = try integer(u64, q, "numDmlAffectedRows");
        }
    }
    return job;
}

fn jobError(out: Allocator, obj: ObjectMap) DecodeError!types.JobError {
    return .{
        .reason = try string(out, obj, "reason") orelse "",
        .location = try string(out, obj, "location") orelse "",
        .message = try string(out, obj, "message") orelse "",
    };
}

pub fn parse(scratch: Allocator, body: []const u8) DecodeError!Value {
    return std.json.parseFromSliceLeaky(Value, scratch, body, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResponse,
    };
}

pub fn object(v: Value) DecodeError!ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => error.InvalidResponse,
    };
}

pub fn field(obj: ObjectMap, name: []const u8, comptime tag: std.meta.Tag(Value)) DecodeError!?@FieldType(Value, @tagName(tag)) {
    const v = obj.get(name) orelse return null;
    if (v == .null) return null;
    if (v != tag) return error.InvalidResponse;
    return @field(v, @tagName(tag));
}

pub fn string(out: Allocator, obj: ObjectMap, name: []const u8) DecodeError!?[]const u8 {
    const text = try field(obj, name, .string) orelse return null;
    return try out.dupe(u8, text);
}

pub fn boolean(obj: ObjectMap, name: []const u8) DecodeError!?bool {
    return try field(obj, name, .bool);
}

/// A page token: "" means the last page.
pub fn token(out: Allocator, obj: ObjectMap, name: []const u8) DecodeError!?[]const u8 {
    const text = try field(obj, name, .string) orelse return null;
    if (text.len == 0) return null;
    return try out.dupe(u8, text);
}

/// An integer as a JSON string (every int64 and uint64) or a number (the
/// uint32s, `totalItems`).
pub fn integer(comptime T: type, obj: ObjectMap, name: []const u8) DecodeError!?T {
    const v = obj.get(name) orelse return null;
    const text = switch (v) {
        .null => return null,
        .number_string, .string => |s| s,
        else => return error.InvalidResponse,
    };
    return std.fmt.parseInt(T, text, 10) catch error.InvalidResponse;
}

/// Milliseconds since the epoch, as a JSON string.
fn millis(obj: ObjectMap, name: []const u8) DecodeError!?std.Io.Timestamp {
    const ms = try integer(i64, obj, name) orelse return null;
    return .{ .nanoseconds = @as(i96, ms) * std.time.ns_per_ms };
}

pub fn stringList(out: Allocator, obj: ObjectMap, name: []const u8) DecodeError![]const []const u8 {
    const list = try field(obj, name, .array) orelse return &.{};
    const items = try out.alloc([]const u8, list.items.len);
    for (list.items, items) |v, *s| s.* = switch (v) {
        .string => |text| try out.dupe(u8, text),
        else => return error.InvalidResponse,
    };
    return items;
}

/// A map of strings as pairs, in the order the server wrote them.
pub fn labelMap(out: Allocator, obj: ObjectMap, name: []const u8) DecodeError![]const types.Label {
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

test "decodeDataset and its page: production's public dataset and the probe's own" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();

    const public = try decodeDataset(a, s, production.dataset_public);
    try testing.expectEqualStrings("bigquery-public-data", public.ref.project);
    try testing.expectEqualStrings("samples", public.ref.dataset);
    try testing.expectEqualStrings("US", public.location);
    try testing.expect(public.creation_time != null and public.last_modified_time != null);

    const ours = try decodeDataset(a, s, production.dataset_ours);
    try testing.expectEqualStrings("extractctl", ours.ref.project);
    try testing.expectEqualStrings("zigps probe", ours.description);
    try testing.expectEqual(86_400_000, ours.default_table_expiration_ms.?);
    try testing.expectEqualStrings("probe", ours.labels[0].value);
    try testing.expectEqual(@as(i96, 1792597662365) * std.time.ns_per_ms, ours.creation_time.?.nanoseconds);
    try testing.expectEqualStrings("DEFAULT", ours.type);

    const page = try decodeDatasetPage(a, s, production.datasets_page);
    try testing.expectEqual(1, page.datasets.len);
    try testing.expectEqualStrings("US", page.datasets[0].location);
    try testing.expectEqualStrings("DEFAULT", page.datasets[0].type);
    try testing.expectEqual(null, page.next_page_token);
    try testing.expectEqual(0, (try decodeDatasetPage(a, s, "{\"kind\":\"bigquery#datasetList\",\"etag\":\"e\"}")).datasets.len);
}

test "decodeTable and its page: every type in a schema, partitioning, views" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();

    const shakespeare = try decodeTable(a, s, production.table_shakespeare);
    try testing.expectEqualStrings("shakespeare", shakespeare.ref.table);
    try testing.expectEqual(types.TableType.table, shakespeare.type);
    try testing.expectEqual(164_656, shakespeare.num_rows.?);
    try testing.expectEqual(6_432_064, shakespeare.num_bytes.?);
    try testing.expectEqual(4, shakespeare.schema.len);
    try testing.expectEqual(types.FieldType.int64, shakespeare.schema[1].type);
    try testing.expectEqualStrings("INTEGER", shakespeare.schema[1].type_name);
    try testing.expectEqual(types.FieldMode.required, shakespeare.schema[1].mode);

    // The every-type table: legacy names, a RANGE's element type, arrays
    // and nested records.
    const typed = try decodeTable(a, s, production.table_typed);
    const by_name = struct {
        fn get(fields: []const types.Field, name: []const u8) types.Field {
            for (fields) |f| if (std.mem.eql(u8, f.name, name)) return f;
            unreachable;
        }
    }.get;
    try testing.expectEqual(types.FieldType.float64, by_name(typed.schema, "nan").type);
    try testing.expectEqual(types.FieldType.bignumeric, by_name(typed.schema, "bignumeric").type);
    try testing.expectEqual(types.FieldType.interval, by_name(typed.schema, "interval_sum").type);
    try testing.expectEqual(types.FieldType.range, by_name(typed.schema, "range_ts_open").type);
    try testing.expectEqual(types.FieldType.timestamp, by_name(typed.schema, "range_ts_open").range_element.?);
    try testing.expectEqual(types.FieldType.datetime, by_name(typed.schema, "range_datetime").range_element.?);
    try testing.expectEqual(types.FieldMode.repeated, by_name(typed.schema, "array_int").mode);
    const record = by_name(typed.schema, "record");
    try testing.expectEqual(types.FieldType.record, record.type);
    try testing.expectEqual(3, record.fields.len);
    try testing.expectEqual(types.FieldMode.repeated, record.fields[2].mode);
    try testing.expectEqualStrings("z", record.fields[2].fields[0].name);
    try testing.expect(typed.expiration_time != null);

    const events = try decodeTable(a, s, production.table_events);
    try testing.expectEqualStrings("DAY", events.time_partitioning.?.type);
    try testing.expectEqualStrings("ts", events.time_partitioning.?.field);
    try testing.expectEqualStrings("user", events.clustering[0]);
    try testing.expectEqual(2, events.num_rows.?);

    const view = try decodeTable(a, s, production.table_view);
    try testing.expectEqual(types.TableType.view, view.type);
    try testing.expect(std.mem.startsWith(u8, view.view_query.?, "SELECT user, n FROM"));
    try testing.expect(!view.view_uses_legacy_sql);
    try testing.expectEqual(0, view.num_rows.?);

    const mv = try decodeTable(a, s, production.table_materialized_view);
    try testing.expectEqual(types.TableType.materialized_view, mv.type);
    try testing.expect(mv.materialized_view.?.enable_refresh);
    try testing.expectEqual(1_800_000, mv.materialized_view.?.refresh_interval_ms.?);

    const page = try decodeTablePage(a, s, production.tables_page);
    try testing.expectEqual(4, page.tables.len);
    try testing.expectEqual(types.TableType.view, page.tables[1].type);
    try testing.expectEqual(0, page.tables[0].schema.len);
    try testing.expectEqual(null, page.tables[0].num_rows);
    const public = try decodeTablePage(a, s, production.tables_page_public);
    try testing.expectEqual(7, public.total_items.?);
    try testing.expect(public.next_page_token != null);
}

test "decodeJob and its page: the history, a cancelled job, a refused one, a dry run" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();

    const page = try decodeJobPage(a, s, production.jobs_page);
    try testing.expectEqual(5, page.jobs.len);
    const first = page.jobs[0];
    try testing.expectEqualStrings("US", first.ref.location);
    try testing.expectEqual(types.JobState.done, first.state);
    try testing.expectEqual(types.JobType.query, first.type);
    try testing.expect(first.query.len > 0);
    try testing.expect(first.creation_time != null and first.end_time != null);
    try testing.expectEqualStrings("zig-gcp@extractctl.iam.gserviceaccount.com", first.user_email);
    try testing.expectEqualStrings("SELECT", first.statement_type);
    try testing.expectEqual(10_485_760, first.total_bytes_billed.?);
    // Newest first.
    for (page.jobs[0 .. page.jobs.len - 1], page.jobs[1..]) |newer, older| {
        try testing.expect(newer.creation_time.?.nanoseconds >= older.creation_time.?.nanoseconds);
    }

    const cancelled = try decodeJob(a, s, production.job_cancelled);
    try testing.expect(cancelled.failed());
    try testing.expectEqualStrings("stopped", cancelled.@"error".?.reason);
    try testing.expectEqualStrings("Job execution was cancelled: User requested cancellation", cancelled.@"error".?.message);

    const over = try decodeJob(a, s, production.job_over_limit);
    try testing.expect(over.failed());
    try testing.expectEqualStrings("bytesBilledLimitExceeded", over.@"error".?.reason);

    const dry = try decodeJob(a, s, production.job_dry_run);
    try testing.expect(dry.dry_run);
    try testing.expectEqualStrings("", dry.ref.id);
    try testing.expectEqual(5_114_816, dry.total_bytes_processed.?);
    try testing.expectEqual(types.JobState.done, dry.state);

    const running = try decodeCancel(a, s, production.cancel_running);
    try testing.expectEqual(types.JobState.running, running.state);
    try testing.expectEqual(null, running.@"error");
}

test "the fields milestone 0's bodies did not carry, in the discovery document's shapes" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();

    const datasets = try decodeDatasetPage(a, s,
        \\{"datasets":[{"datasetReference":{"projectId":"p","datasetId":"d"},"friendlyName":"Sales"}],
        \\ "nextPageToken":"n","unreachable":["eu-west9"]}
    );
    try testing.expectEqualStrings("Sales", datasets.datasets[0].friendly_name);
    try testing.expectEqualStrings("n", datasets.next_page_token.?);
    try testing.expectEqualStrings("eu-west9", datasets.unreachable_locations[0]);
    const dataset = try decodeDataset(a, s,
        \\{"datasetReference":{"projectId":"p","datasetId":"d"},"defaultPartitionExpirationMs":"5184000000"}
    );
    try testing.expectEqual(5_184_000_000, dataset.default_partition_expiration_ms.?);

    const table = try decodeTable(a, s,
        \\{"tableReference":{"projectId":"p","datasetId":"d","tableId":"t"},
        \\ "friendlyName":"Orders","description":"one a row","labels":{"team":"data"},"location":"EU",
        \\ "requirePartitionFilter":true,
        \\ "timePartitioning":{"type":"HOUR","expirationMs":"3600000"},
        \\ "rangePartitioning":{"field":"n","range":{"start":"0","end":"100","interval":"10"}},
        \\ "schema":{"fields":[{"name":"price","type":"NUMERIC","precision":"10","scale":"2","description":"in cents"},
        \\                     {"name":"code","type":"STRING","maxLength":"8"}]}}
    );
    try testing.expectEqualStrings("Orders", table.friendly_name);
    try testing.expectEqualStrings("one a row", table.description);
    try testing.expectEqualStrings("data", table.labels[0].value);
    try testing.expectEqualStrings("EU", table.location);
    try testing.expect(table.require_partition_filter);
    try testing.expectEqualStrings("HOUR", table.time_partitioning.?.type);
    try testing.expectEqualStrings("", table.time_partitioning.?.field);
    try testing.expectEqual(3_600_000, table.time_partitioning.?.expiration_ms.?);
    try testing.expectEqualDeep(types.RangePartitioning{ .field = "n", .start = 0, .end = 100, .interval = 10 }, table.range_partitioning.?);
    try testing.expectEqual(10, table.schema[0].precision.?);
    try testing.expectEqual(2, table.schema[0].scale.?);
    try testing.expectEqualStrings("in cents", table.schema[0].description);
    try testing.expectEqual(8, table.schema[1].max_length.?);
    try testing.expectEqual(types.FieldMode.nullable, table.schema[1].mode);

    const view = try decodeTable(a, s,
        \\{"tableReference":{"projectId":"p","datasetId":"d","tableId":"v"},"type":"VIEW","view":{"query":"SELECT 1"}}
    );
    try testing.expect(!view.view_uses_legacy_sql);
    const legacy = try decodeTable(a, s,
        \\{"tableReference":{"projectId":"p","datasetId":"d","tableId":"v"},"type":"VIEW","view":{"query":"SELECT 1","useLegacySql":true}}
    );
    try testing.expect(legacy.view_uses_legacy_sql);
    const mv = try decodeTable(a, s,
        \\{"tableReference":{"projectId":"p","datasetId":"d","tableId":"m"},"type":"MATERIALIZED_VIEW",
        \\ "materializedView":{"query":"SELECT 1","enableRefresh":false,"lastRefreshTime":"1792597662365"}}
    );
    try testing.expect(!mv.materialized_view.?.enable_refresh);
    try testing.expectEqual(@as(i96, 1792597662365) * std.time.ns_per_ms, mv.materialized_view.?.last_refresh_time.?.nanoseconds);
    try testing.expectEqual(null, mv.materialized_view.?.refresh_interval_ms);
    const plain = try decodeTable(a, s,
        \\{"tableReference":{"projectId":"p","datasetId":"d","tableId":"m"},"materializedView":{}}
    );
    try testing.expect(plain.materialized_view.?.enable_refresh);
    try testing.expectEqual(types.TableType.table, plain.type);

    // A list item with its state and error at its top only, and a job
    // with warnings beside its success.
    const jobs = try decodeJobPage(a, s,
        \\{"jobs":[{"jobReference":{"projectId":"p","jobId":"j","location":"EU"},"state":"DONE",
        \\          "errorResult":{"reason":"invalidQuery","message":"m"},
        \\          "configuration":{"jobType":"LOAD","labels":{"k":"v"}}}],
        \\ "unreachable":["asia-south9"]}
    );
    try testing.expectEqual(types.JobState.done, jobs.jobs[0].state);
    try testing.expectEqualStrings("invalidQuery", jobs.jobs[0].@"error".?.reason);
    try testing.expectEqual(types.JobType.load, jobs.jobs[0].type);
    try testing.expectEqualStrings("v", jobs.jobs[0].labels[0].value);
    try testing.expectEqualStrings("asia-south9", jobs.unreachable_locations[0]);
    const dml = try decodeJob(a, s,
        \\{"jobReference":{"projectId":"p","jobId":"j"},
        \\ "status":{"state":"DONE","errors":[{"reason":"warning","location":"q","message":"w"}]},
        \\ "configuration":{"query":{"query":"DELETE FROM d.t WHERE TRUE"}},
        \\ "statistics":{"totalBytesProcessed":"1","startTime":"1792597662365",
        \\   "query":{"statementType":"DELETE","totalBytesProcessed":"20","numDmlAffectedRows":"3","cacheHit":false}}}
    );
    try testing.expect(dml.succeeded());
    try testing.expectEqualStrings("q", dml.errors[0].location);
    try testing.expectEqualStrings("w", dml.errors[0].message);
    try testing.expectEqual(types.JobType.query, dml.type);
    try testing.expectEqual(20, dml.total_bytes_processed.?);
    try testing.expectEqual(3, dml.num_dml_affected_rows.?);
    try testing.expectEqual(false, dml.cache_hit.?);
    try testing.expect(dml.start_time != null);
    const stats_only = try decodeJob(a, s,
        \\{"jobReference":{"projectId":"p","jobId":"j"},"statistics":{"totalBytesProcessed":"7","query":{}}}
    );
    try testing.expectEqual(types.JobType.query, stats_only.type);
    try testing.expectEqual(7, stats_only.total_bytes_processed.?);
    try testing.expectEqual(types.JobState.unknown, stats_only.state);
    // A query job named by its configuration alone.
    const config_only = try decodeJob(a, s,
        \\{"jobReference":{"projectId":"p","jobId":"j"},"configuration":{"query":{"query":"SELECT 1"}}}
    );
    try testing.expectEqual(types.JobType.query, config_only.type);
    try testing.expectEqualStrings("SELECT 1", config_only.query);
    // A null is the field left out, wherever it stands.
    const nulls = try decodeTable(a, s,
        \\{"tableReference":{"projectId":"p","datasetId":"d","tableId":"t"},"type":null,"description":null,
        \\ "numRows":null,"schema":null,"labels":null,"clustering":null,"view":null}
    );
    try testing.expectEqual(types.TableType.table, nulls.type);
    try testing.expectEqualStrings("", nulls.description);
    try testing.expectEqual(null, nulls.num_rows);
    try testing.expectEqual(0, nulls.schema.len);
}

test "records nest 15 levels deep, and no deeper" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();
    const Nest = struct {
        /// A table whose schema nests `levels` records around an INTEGER.
        fn body(arena: Allocator, levels: usize) ![]const u8 {
            var w: std.Io.Writer.Allocating = .init(arena);
            try w.writer.writeAll("{\"tableReference\":{\"projectId\":\"p\",\"datasetId\":\"d\",\"tableId\":\"t\"},\"schema\":{\"fields\":[");
            for (0..levels) |_| try w.writer.writeAll("{\"name\":\"r\",\"type\":\"RECORD\",\"fields\":[");
            try w.writer.writeAll("{\"name\":\"n\",\"type\":\"INTEGER\"}");
            for (0..levels) |_| try w.writer.writeAll("]}");
            try w.writer.writeAll("]}}");
            return w.written();
        }
    };
    var table = try decodeTable(a, s, try Nest.body(s, max_record_depth));
    var f = table.schema[0];
    for (0..max_record_depth) |_| f = f.fields[0];
    try testing.expectEqual(types.FieldType.int64, f.type);
    try testing.expectError(error.InvalidResponse, decodeTable(a, s, try Nest.body(s, max_record_depth + 1)));
    // Far past it, refused just as soon.
    try testing.expectError(error.InvalidResponse, decodeTable(a, s, try Nest.body(s, 5000)));
    table = try decodeTable(a, s, try Nest.body(s, 0));
    try testing.expectEqual(1, table.schema.len);
    // An empty page token is the last page.
    try testing.expectEqual(null, (try decodeJobPage(a, s, "{\"nextPageToken\":\"\"}")).next_page_token);
}

test "lenient where it can be, InvalidResponse where it cannot" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();

    const odd = try decodeTable(a, s,
        \\{"tableReference":{"projectId":"p","datasetId":"d","tableId":"t"},"type":"CLONE","newField":1,
        \\ "schema":{"fields":[{"name":"u","type":"UUID","mode":"OPTIONAL"}]}}
    );
    try testing.expectEqual(types.TableType.unknown, odd.type);
    try testing.expectEqual(types.FieldType.unknown, odd.schema[0].type);
    try testing.expectEqualStrings("UUID", odd.schema[0].type_name);
    try testing.expectEqual(types.FieldMode.unknown, odd.schema[0].mode);

    for ([_][]const u8{
        "[]",
        "{\"datasetReference\":{\"datasetId\":\"d\"}}",
        "{\"datasetReference\":{\"projectId\":\"p\",\"datasetId\":\"d\"},\"creationTime\":\"yesterday\"}",
        "{\"datasetReference\":{\"projectId\":\"p\",\"datasetId\":\"d\"},\"labels\":{\"k\":1}}",
    }) |body| try testing.expectError(error.InvalidResponse, decodeDataset(a, s, body));
    for ([_][]const u8{
        "{\"tableReference\":{\"projectId\":\"p\",\"datasetId\":\"d\"}}",
        "{\"tableReference\":{\"projectId\":\"p\",\"datasetId\":\"d\",\"tableId\":\"t\"},\"numRows\":\"-1\"}",
        "{\"tableReference\":{\"projectId\":\"p\",\"datasetId\":\"d\",\"tableId\":\"t\"},\"schema\":{\"fields\":[{\"type\":\"STRING\"}]}}",
        "{\"tableReference\":{\"projectId\":\"p\",\"datasetId\":\"d\",\"tableId\":\"t\"},\"rangePartitioning\":{\"field\":\"n\"}}",
        "{\"tableReference\":{\"projectId\":\"p\",\"datasetId\":\"d\",\"tableId\":\"t\"},\"clustering\":{\"fields\":[1]}}",
    }) |body| try testing.expectError(error.InvalidResponse, decodeTable(a, s, body));
    for ([_][]const u8{
        "{\"status\":{\"state\":\"DONE\"}}",
        "{\"jobReference\":{\"jobId\":\"j\"}}",
        "{\"jobReference\":{\"projectId\":\"p\",\"jobId\":\"j\"},\"status\":{\"errors\":[1]}}",
        "{\"jobReference\":{\"projectId\":\"p\",\"jobId\":\"j\"},\"statistics\":{\"creationTime\":1.5}}",
    }) |body| try testing.expectError(error.InvalidResponse, decodeJob(a, s, body));
    try testing.expectError(error.InvalidResponse, decodeCancel(a, s, "{\"kind\":\"bigquery#jobCancelResponse\"}"));
    try testing.expectError(error.InvalidResponse, decodeTablePage(a, s, "{\"totalItems\":true}"));
}

fn decodersProperty(_: void, input: []const u8) !void {
    const test_util = @import("test_util.zig");
    var out: std.heap.ArenaAllocator = .init(test_util.propertyAllocator());
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(test_util.propertyAllocator());
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();
    inline for (.{ decodeDataset, decodeDatasetPage, decodeTable, decodeTablePage, decodeJob, decodeCancel, decodeJobPage }) |decode| {
        if (decode(a, s, input)) |_| {} else |err| try testing.expectEqual(error.InvalidResponse, err);
    }
}

test "fuzz decoders: any body decodes or is InvalidResponse, never a crash or a leak" {
    try @import("test_util.zig").fuzzBytes({}, decodersProperty, .{ .corpus = &.{
        production.dataset_public,
        production.dataset_ours,
        production.datasets_page,
        production.table_shakespeare,
        production.table_typed,
        production.table_events,
        production.tables_page,
        production.jobs_page,
        production.job_cancelled,
        production.cancel_running,
    } });
}
