//! Integration tests against real BigQuery Data Transfer, which has no
//! emulator: milestone 3 of the Data Transfer spec. They need a project
//! with the BigQuery and Data Transfer APIs on and a token for the
//! `cloud-platform` scope whose principal may make a dataset and scheduled
//! queries there (Editor, or BigQuery Admin):
//!
//!     GCP_TEST_PROJECT=extractctl GCP_TEST_TOKEN=$(cat token.txt) \
//!     DATATRANSFER_TEST=1 zig build test-integration-gcp -Dtest-filter="datatransfer:"
//!
//! Without the variables the test skips. The client writes no configs,
//! so the suite makes its `zigps_dt_<run>` dataset and three scheduled
//! queries raw beside it: a manual one, a failing one, and a disabled
//! one, none scheduled to run on its own. Through the client it lists
//! them in their location, reads them, shows a run now's request and
//! holds it byte for byte to what was sent, runs two now and polls them
//! to their end, reads their runs and messages, and meets production's
//! refusals; then it replays the same script on a fake seeded from
//! production's answers, every outcome and word held equal. Everything
//! made is deleted at the end, and a crashed run's leftovers a day old by
//! the next. The queries read no table, so they bill nothing. About three
//! minutes.

const std = @import("std");
const core = @import("core");
const datatransfer = @import("datatransfer");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const FakeDataTransfer = datatransfer.testing.FakeDataTransfer;

const host = "https://bigquerydatatransfer.googleapis.com/v1";

/// Every request sent, in order, through any transport.
const Recorder = struct {
    inner: core.transport.Transport,
    arena: std.heap.ArenaAllocator,
    sent: std.ArrayList(Sent) = .empty,

    const Sent = struct { method: core.transport.Method, url: []const u8, body: []const u8 };

    fn init(inner: core.transport.Transport) Recorder {
        return .{ .inner = inner, .arena = .init(testing.allocator) };
    }

    fn deinit(r: *Recorder) void {
        r.arena.deinit();
    }

    fn transport(r: *Recorder) core.transport.Transport {
        return .{ .ptr = r, .vtable = &.{ .send = send } };
    }

    fn send(ptr: *anyopaque, req: core.transport.Request, arena: Allocator) core.transport.Error!core.transport.Response {
        const r: *Recorder = @ptrCast(@alignCast(ptr));
        const a = r.arena.allocator();
        try r.sent.append(a, .{ .method = req.method, .url = try a.dupe(u8, req.url), .body = try a.dupe(u8, req.body orelse "") });
        return r.inner.send(req, arena);
    }

    fn last(r: *const Recorder) Sent {
        return r.sent.items[r.sent.items.len - 1];
    }
};

/// The three configs the suite made, by role.
const Made = struct {
    manual: []const u8,
    failing: []const u8,
    disabled: []const u8,
};

const Run = struct {
    client: *datatransfer.Client,
    diag: *datatransfer.Diagnostics,
    recorder: *Recorder,
    arena: Allocator,
    made: Made,
    /// On the production run, the fake it seeds with what production
    /// answered, as the fake copies it.
    seeds: ?*FakeDataTransfer,
    /// Polls between reads of a run still going: production's runs take
    /// about 75 s; the fake's end at once.
    poll_ms: u32,
    outcomes: std.ArrayList([]const u8) = .empty,

    fn note(r: *Run, comptime fmt: []const u8, args: anytype) !void {
        const line = try std.fmt.allocPrint(r.arena, fmt, args);
        std.debug.print("datatransfer: {s}\n", .{line});
        try r.outcomes.append(r.arena, line);
    }

    fn noteError(r: *Run, step: []const u8, err: anyerror) !void {
        try r.note("{s}: error.{t}: {s}", .{ step, err, r.diag.message() });
    }
};

/// The schedule, as an outcome names it.
fn scheduleText(s: datatransfer.Schedule) []const u8 {
    return switch (s) {
        .default => "default",
        .manual => "manual",
        .time_based => |t| t.schedule,
        .event_driven => "event-driven",
    };
}

fn script(r: *Run) !void {
    const c = r.client;
    const a = r.arena;

    {
        var locations = try c.listLocations(.{});
        defer locations.deinit();
        var has_us = false;
        for (locations.value.locations) |l| {
            has_us = has_us or std.mem.eql(u8, l.id, "us");
            if (r.seeds) |fake| try fake.putLocation(l.id);
        }
        try r.note("locations: {d}, us among them={}", .{ locations.value.locations.len, has_us });
    }

    // The suite's configs, listed in their location and read.
    {
        var page = try c.listTransferConfigs("us", .{ .data_sources = &.{"scheduled_query"} });
        defer page.deinit();
        var ours: usize = 0;
        for (page.value.configs) |config| {
            const mine = std.mem.eql(u8, config.name, r.made.manual) or std.mem.eql(u8, config.name, r.made.failing) or std.mem.eql(u8, config.name, r.made.disabled);
            if (!mine) continue;
            ours += 1;
            try r.note("listed {s}: owner=\"{s}\" schedule={s} disabled={}", .{ config.display_name[config.display_name.len - 6 ..], config.owner_email, scheduleText(config.schedule), config.disabled });
        }
        try r.note("listed ours: {d}", .{ours});
    }
    for ([_][]const u8{ r.made.manual, r.made.failing, r.made.disabled }) |name| {
        var config = try c.getTransferConfig(name);
        defer config.deinit();
        const v = config.value;
        const q = v.scheduled_query.?;
        try r.note("config {s}: state={t} schedule={s} next={} disabled={} region={s} owner={} query={s} template={s} disposition={s}", .{
            v.display_name[v.display_name.len - 6 ..], v.state,               scheduleText(v.schedule), v.next_run_time != null,           v.disabled,
            v.dataset_region,                          v.owner_email.len > 0, q.query,                  q.destination_table_name_template, q.write_disposition,
        });
    }

    // Run now, shown first; two, polled to their end.
    const run_time = std.Io.Clock.real.now(testing.io);
    var ok_run: []const u8 = undefined;
    var failed_run: []const u8 = undefined;
    {
        const options: datatransfer.StartManualRunOptions = .{ .run_time = run_time };
        var preview = try c.startManualRunRequest(r.made.manual, options);
        defer preview.deinit();
        var started = try c.startManualRun(r.made.manual, options);
        defer started.deinit();
        try testing.expectEqualStrings(preview.value.url, r.recorder.last().url);
        try testing.expectEqualStrings(preview.value.body, r.recorder.last().body);
        const run = started.value.runs[0];
        try r.note("run now: {d} run(s), state={t}, run time as asked={}", .{ started.value.runs.len, run.state, run.run_time.?.nanoseconds == run_time.nanoseconds - @mod(run_time.nanoseconds, std.time.ns_per_us) });
        ok_run = try a.dupe(u8, run.name);
        var failing = try c.startManualRun(r.made.failing, .{ .run_time = run_time });
        defer failing.deinit();
        failed_run = try a.dupe(u8, failing.value.runs[0].name);
        if (c.startManualRun(r.made.disabled, .{})) |s| {
            var unexpected = s;
            unexpected.deinit();
            try r.note("disabled: started", .{});
        } else |err| try r.noteError("disabled", err);
    }
    var ends: [2]datatransfer.TransferRun = undefined;
    var ends_owned: [2]datatransfer.Owned(datatransfer.TransferRun) = undefined;
    for ([_][]const u8{ ok_run, failed_run }, 0..) |name, i| {
        var reads: usize = 0;
        var run = try c.getRun(name);
        while (!run.value.ended()) : (reads += 1) {
            if (reads > 120) return error.TestUnexpectedResult;
            run.deinit();
            try testing.io.sleep(.fromMilliseconds(r.poll_ms), .awake);
            run = try c.getRun(name);
        }
        ends_owned[i] = run;
        ends[i] = run.value;
        if (r.seeds) |_| std.debug.print("datatransfer: (run ended after {d} reads)\n", .{reads});
    }
    defer for (&ends_owned) |*o| o.deinit();
    try r.note("ended: {t} error={?d}; {t} error={?d} {s}", .{
        ends[0].state,
        if (ends[0].@"error") |e| e.code else null,
        ends[1].state,
        if (ends[1].@"error") |e| e.code else null,
        if (ends[1].@"error") |e| e.message[0..@min(e.message.len, 23)] else "",
    });

    // Runs and messages read back.
    {
        var runs = try c.listRuns(r.made.manual, .{});
        defer runs.deinit();
        var latest = try c.listRuns(r.made.manual, .{ .latest_only = true, .states = &.{.succeeded} });
        defer latest.deinit();
        try r.note("runs: {d}, latest succeeded {d}", .{ runs.value.runs.len, latest.value.runs.len });
        var messages = try c.listMessages(ok_run, .{});
        defer messages.deinit();
        try r.note("messages: {d}, newest \"{s}\"", .{ messages.value.messages.len, messages.value.messages[0].text });
        var errors_only = try c.listMessages(failed_run, .{ .severities = &.{.@"error"} });
        defer errors_only.deinit();
        try r.note("failed run's errors: {d}, division by zero={}", .{
            errors_only.value.messages.len,
            errors_only.value.messages.len > 0 and std.mem.indexOf(u8, errors_only.value.messages[0].text, "division by zero: 1 / 0") != null,
        });
        var config = try c.getTransferConfig(r.made.failing);
        defer config.deinit();
        var manual = try c.getTransferConfig(r.made.manual);
        defer manual.deinit();
        try r.note("configs after: manual {t}, failing {t}", .{ manual.value.state, config.value.state });
    }

    // Refusals.
    const nobody = try c.configName(a, "us", "00000000-0000-0000-0000-000000000000");
    if (c.getTransferConfig(nobody)) |got| {
        var unexpected = got;
        unexpected.deinit();
        try r.note("nobody's config: answered", .{});
    } else |err| try r.noteError("nobody's config", err);
    if (c.listTransferConfigs("zz-nowhere1", .{})) |got| {
        var unexpected = got;
        unexpected.deinit();
        try r.note("made-up location: answered", .{});
    } else |err| try r.noteError("made-up location", err);
    const no_run = try std.mem.concat(a, u8, &.{ r.made.manual, "/runs/00000000-0000-0000-0000-000000000000" });
    if (c.getRun(no_run)) |got| {
        var unexpected = got;
        unexpected.deinit();
        try r.note("nobody's run: answered", .{});
    } else |err| {
        // The run's name carries the suite's own config.
        try r.note("nobody's run: error.{t}: {s}", .{ err, try std.mem.replaceOwned(u8, a, r.diag.message(), r.made.manual, "<config>") });
    }
}

/// A raw call beside the client, for what it deliberately has no verb
/// for: the dataset, and the configs.
fn raw(transport: core.transport.Transport, token: []const u8, arena: Allocator, method: core.transport.Method, url: []const u8, body: ?[]const u8) !core.transport.Response {
    return transport.send(.{ .method = method, .url = url, .bearer = token, .body = body, .timeout_ms = 60_000 }, arena);
}

fn makeConfig(transport: core.transport.Transport, token: []const u8, arena: Allocator, project: []const u8, body: []const u8) ![]const u8 {
    const url = try std.fmt.allocPrint(arena, "{s}/projects/{s}/locations/us/transferConfigs", .{ host, project });
    const res = try raw(transport, token, arena, .POST, url, body);
    if (res.status != 200) {
        std.debug.print("datatransfer: making a config: {d} {s}\n", .{ res.status, res.body });
        return error.TestUnexpectedResult;
    }
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, res.body, .{});
    return v.object.get("name").?.string;
}

/// Deletes the suite's configs and dataset; then any `zigps-dt-` config
/// and `zigps_dt_` dataset a day old, left by a crashed run.
fn sweep(transport: core.transport.Transport, token: []const u8, arena: Allocator, project: []const u8, made: []const []const u8, dataset: ?[]const u8) void {
    for (made) |name| {
        const url = std.fmt.allocPrint(arena, "{s}/{s}", .{ host, name }) catch return;
        const res = raw(transport, token, arena, .DELETE, url, null) catch |err| {
            std.debug.print("datatransfer: delete {s}: {t}\n", .{ name, err });
            continue;
        };
        std.debug.print("datatransfer: deleted {s}: {d}\n", .{ name, res.status });
    }
    if (dataset) |d| {
        const url = std.fmt.allocPrint(arena, "https://bigquery.googleapis.com/bigquery/v2/projects/{s}/datasets/{s}?deleteContents=true", .{ project, d }) catch return;
        const res = raw(transport, token, arena, .DELETE, url, null) catch return;
        std.debug.print("datatransfer: deleted dataset {s}: {d}\n", .{ d, res.status });
    }
    // Leftovers a day old.
    const list_url = std.fmt.allocPrint(arena, "{s}/projects/{s}/locations/us/transferConfigs", .{ host, project }) catch return;
    const listed = raw(transport, token, arena, .GET, list_url, null) catch return;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, listed.body, .{}) catch return;
    const configs = if (v == .object) v.object.get("transferConfigs") else null;
    if (configs == null or configs.? != .array) return;
    const day_ago = std.Io.Clock.real.now(testing.io).nanoseconds - std.time.ns_per_day;
    for (configs.?.array.items) |item| {
        if (item != .object) continue;
        const display = item.object.get("displayName") orelse continue;
        if (display != .string or !std.mem.startsWith(u8, display.string, "zigps-dt-")) continue;
        const updated = item.object.get("updateTime") orelse continue;
        const t = core.timestamp.parse(if (updated == .string) updated.string else "") catch continue;
        if (t.nanoseconds > day_ago) continue;
        const url = std.fmt.allocPrint(arena, "{s}/{s}", .{ host, item.object.get("name").?.string }) catch continue;
        _ = raw(transport, token, arena, .DELETE, url, null) catch continue;
        std.debug.print("datatransfer: swept {s}\n", .{display.string});
    }
}

test "datatransfer: scheduled queries listed, read, run now and followed to their end; replayed on the fake" {
    const gpa = testing.allocator;
    var env = try testing.environ.createMap(gpa);
    defer env.deinit();
    const project = env.get("GCP_TEST_PROJECT") orelse return error.SkipZigTest;
    const token_text = env.get("GCP_TEST_TOKEN") orelse return error.SkipZigTest;
    if (env.get("DATATRANSFER_TEST") == null) return error.SkipZigTest;
    var token: core.StaticToken = .{ .token = std.mem.trim(u8, token_text, &std.ascii.whitespace) };
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var bytes: [3]u8 = undefined;
    testing.io.random(&bytes);
    const run_id = try std.fmt.allocPrint(a, "{x}", .{bytes});
    const dataset = try std.fmt.allocPrint(a, "zigps_dt_{s}", .{run_id});

    var http: core.transport.HttpTransport = .init(gpa, testing.io, "zig-gcp-datatransfer-gcp-integration/0.1");
    defer http.deinit();
    const tp = http.transport();
    sweep(tp, token.token, a, project, &.{}, null);
    {
        const url = try std.fmt.allocPrint(a, "https://bigquery.googleapis.com/bigquery/v2/projects/{s}/datasets", .{project});
        const body = try std.fmt.allocPrint(a, "{{\"datasetReference\":{{\"projectId\":\"{s}\",\"datasetId\":\"{s}\"}},\"location\":\"US\",\"labels\":{{\"zigps\":\"suite\"}},\"defaultTableExpirationMs\":\"86400000\"}}", .{ project, dataset });
        const res = try raw(tp, token.token, a, .POST, url, body);
        try testing.expectEqual(200, res.status);
    }
    var made_names: std.ArrayList([]const u8) = .empty;
    defer sweep(tp, token.token, a, project, made_names.items, dataset);
    const config_body = struct {
        fn of(arena: Allocator, role: []const u8, run: []const u8, ds: []const u8, query: []const u8, extra: []const u8) ![]const u8 {
            return std.fmt.allocPrint(arena,
                \\{{"displayName":"zigps-dt-{s}-{s}","dataSourceId":"scheduled_query","destinationDatasetId":"{s}","params":{{"query":"{s}","destination_table_name_template":"zigps_{s}_{{run_date}}","write_disposition":"WRITE_TRUNCATE"}},{s}}}
            , .{ run, role, ds, query, role, extra });
        }
    }.of;
    const made: Made = .{
        .manual = try makeConfig(tp, token.token, a, project, try config_body(a, "manual", run_id, dataset, "SELECT @run_date AS d, 17 AS x", "\"scheduleOptions\":{\"disableAutoScheduling\":true}")),
        .failing = try makeConfig(tp, token.token, a, project, try config_body(a, "broken", run_id, dataset, "SELECT 1 / 0 AS x", "\"scheduleOptions\":{\"disableAutoScheduling\":true}")),
        .disabled = try makeConfig(tp, token.token, a, project, try config_body(a, "paused", run_id, dataset, "SELECT 2 AS x", "\"schedule\":\"every 24 hours\",\"disabled\":true")),
    };
    try made_names.appendSlice(a, &.{ made.manual, made.failing, made.disabled });

    // Production, through the client.
    var recorder: Recorder = .init(tp);
    defer recorder.deinit();
    var diag: datatransfer.Diagnostics = .{};
    var client = try datatransfer.Client.init(gpa, testing.io, .{
        .project_id = project,
        .token_provider = token.provider(),
        .scope = .cloud_platform,
        .diagnostics = &diag,
        .transport = recorder.transport(),
    });
    defer client.deinit();
    var fake: FakeDataTransfer = .init(gpa, testing.io, .{ .project_id = project, .project_number = std.mem.sliceTo(made.manual["projects/".len..], '/') });
    defer fake.deinit();
    var live: Run = .{ .client = &client, .diag = &diag, .recorder = &recorder, .arena = a, .made = made, .seeds = &fake, .poll_ms = 3000 };
    try script(&live);

    // The fake, seeded from production's reads, given the same script.
    for ([_][]const u8{ made.manual, made.failing, made.disabled }) |name| {
        var config = try client.getTransferConfig(name);
        defer config.deinit();
        const v = config.value;
        var runs = try client.listRuns(name, .{});
        defer runs.deinit();
        const outcome: FakeDataTransfer.ManualRun = if (runs.value.runs.len == 0) .pending else switch (runs.value.runs[0].state) {
            .succeeded => .succeeded,
            .failed => .{ .failed = runs.value.runs[0].@"error".? },
            else => .pending,
        };
        _ = try fake.putConfig(.{
            .location = v.location,
            .id = v.id,
            .display_name = v.display_name,
            .data_source_id = v.data_source_id,
            .destination_dataset_id = v.destination_dataset_id,
            .schedule = v.schedule,
            .next_run_time = v.next_run_time,
            .disabled = v.disabled,
            .owner_email = v.owner_email,
            .update_time = v.update_time,
            .params = v.params,
            .manual_run = outcome,
        });
    }
    var fake_recorder: Recorder = .init(fake.transport());
    defer fake_recorder.deinit();
    var fake_diag: datatransfer.Diagnostics = .{};
    var fake_client = try datatransfer.Client.init(gpa, testing.io, .{
        .project_id = project,
        .token_provider = token.provider(),
        .scope = .cloud_platform,
        .diagnostics = &fake_diag,
        .transport = fake_recorder.transport(),
    });
    defer fake_client.deinit();
    var replay: Run = .{ .client = &fake_client, .diag = &fake_diag, .recorder = &fake_recorder, .arena = a, .made = made, .seeds = null, .poll_ms = 1 };
    // The fake starts with production's state before the script's runs:
    // the configs as they were made.
    try script(&replay);

    var differences: usize = 0;
    for (live.outcomes.items, 0..) |want, i| {
        const got = if (i < replay.outcomes.items.len) replay.outcomes.items[i] else "(none)";
        if (!std.mem.eql(u8, want, got)) {
            differences += 1;
            std.debug.print("datatransfer replay differs at step {d}:\n  production: {s}\n  fake:       {s}\n", .{ i, want, got });
        }
    }
    try testing.expectEqual(live.outcomes.items.len, replay.outcomes.items.len);
    try testing.expectEqual(0, differences);
    std.debug.print("datatransfer: {d} outcomes, production and fake agree\n", .{live.outcomes.items.len});
}
