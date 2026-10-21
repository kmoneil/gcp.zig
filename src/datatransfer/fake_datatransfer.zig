//! BigQuery Data Transfer in memory, for tests of code that reads
//! scheduled queries and their runs and runs one now: behind
//! `Client.Options.transport`, it answers the module's calls as
//! production answered them when measured on 2026-10-21.
//!
//! - Locations, configs, runs and messages are put in by the test
//!   (`putLocation`, `putConfig`, `putRun`, `putMessage`); `setRunState`
//!   stands in for the service moving a run on. Nothing moves on its own.
//! - Names carry the project by number (`Options.project_number`), as
//!   production's do; a path may name the project by id or number.
//! - Configs list one location at a time: `-` is refused, "BigQuery Data
//!   Transfer Service does not yet support location: unknown", and a
//!   location nobody put, "Request uses an invalid location: <l>", as
//!   production refused a made-up one. They list by id, as production
//!   listed them. A list carries no owner; a get does. Both schedule
//!   shapes are written, as production writes them.
//! - A run now makes one run, its `runTime` the time asked (production
//!   took one ahead of its own clock) and its `scheduleTime` now:
//!   `PENDING` until the test moves it, or ended at once as the config's
//!   `PutConfig.manual_run` says, with production's messages for a
//!   scheduled query. Sent twice, it makes two runs. A disabled config is
//!   refused in production's words. The config's state becomes its
//!   latest run's.
//! - Runs list newest run time first, `LATEST` one a run date; messages
//!   newest first; both by their filters. A succeeded run's error is
//!   `{}`, as production writes it.
//! - Refused in production's words: a config or a run nobody has, a
//!   state outside the enum, a page size on the locations list. Faults a
//!   test asks for: refusals, dropped connections, and a lost answer (a
//!   lost run now leaves its run started, as a real one would).
//!
//! Not modelled, answered 501 with the reason: writes to configs,
//! backfills (`requestedTimeRange`), deleting runs, data sources, the
//! regionless paths, and a project other than the fake's own.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const core = @import("core");
const tp = core.transport;
const types = @import("types.zig");
const validate = @import("validate.zig");

pub const FakeDataTransfer = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    options: Options,
    /// Strings and resources, freed with the fake.
    store: std.heap.ArenaAllocator,
    locations: std.ArrayList([]const u8) = .empty,
    configs: std.ArrayList(*FakeConfig) = .empty,
    faults: [3]Fault = .{ .{}, .{}, .{} },
    calls: usize = 0,
    runs_started: usize = 0,
    next_id: u64 = 1,

    const Fault = struct { n: usize = 0, status: u16 = 0 };
    const refuse = 0;
    const drop = 1;
    const lose = 2;

    pub const Options = struct {
        /// The project, by id: what paths may name.
        project_id: []const u8 = "my-project",
        /// The project, by number: what names carry, as production's do.
        project_number: []const u8 = "123456789012",
    };

    pub const Reply = struct { status: u16, headers: []const tp.Header = &.{}, body: []const u8 };

    /// How a run now ends: still `PENDING` for the test to move on, or at
    /// once.
    pub const ManualRun = union(enum) {
        pending,
        succeeded,
        /// Failed with this error, as a query that fails as it runs.
        failed: types.Status,
    };

    const FakeConfig = struct {
        config: types.TransferConfig,
        manual_run: ManualRun,
        runs: std.ArrayList(*FakeRun) = .empty,
    };

    const FakeRun = struct {
        run: types.TransferRun,
        messages: std.ArrayList(types.TransferMessage) = .empty,
    };

    pub fn init(gpa: Allocator, io: std.Io, options: Options) FakeDataTransfer {
        return .{ .gpa = gpa, .io = io, .options = options, .store = .init(gpa) };
    }

    pub fn deinit(f: *FakeDataTransfer) void {
        for (f.configs.items) |c| {
            for (c.runs.items) |r| r.messages.deinit(f.gpa);
            c.runs.deinit(f.gpa);
        }
        f.locations.deinit(f.gpa);
        f.configs.deinit(f.gpa);
        f.store.deinit();
        f.* = undefined;
    }

    /// Goes into `Client.Options.transport`.
    pub fn transport(f: *FakeDataTransfer) tp.Transport {
        return .{ .ptr = f, .vtable = &.{ .send = send } };
    }

    // Faults, each for the next `n` calls.

    /// Answers them with `status`, and changes nothing.
    pub fn refuseNext(f: *FakeDataTransfer, n: usize, status: u16) void {
        f.setFault(refuse, .{ .n = n, .status = status });
    }

    /// Closes their connection before any answer.
    pub fn dropNext(f: *FakeDataTransfer, n: usize) void {
        f.setFault(drop, .{ .n = n });
    }

    /// Serves them and answers `status` instead of what was read.
    pub fn loseNext(f: *FakeDataTransfer, n: usize, status: u16) void {
        f.setFault(lose, .{ .n = n, .status = status });
    }

    fn setFault(f: *FakeDataTransfer, slot: usize, fault: Fault) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.faults[slot] = fault;
    }

    fn takeFault(f: *FakeDataTransfer, slot: usize) ?Fault {
        const fault = &f.faults[slot];
        if (fault.n == 0) return null;
        fault.n -= 1;
        return fault.*;
    }

    // What a test reads.

    /// Calls served, refusals included.
    pub fn callCount(f: *FakeDataTransfer) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.calls;
    }

    /// Runs started by a run now: what a test of "ran it once" asks.
    pub fn runsStarted(f: *FakeDataTransfer) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.runs_started;
    }

    // What a test puts in.

    pub const PutError = error{ OutOfMemory, InvalidEntry };

    /// A location configs can live in, as `listLocations` answers it.
    pub fn putLocation(f: *FakeDataTransfer, id: []const u8) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (!validate.isLocation(id) or f.hasLocation(id)) return error.InvalidEntry;
        try f.locations.append(f.gpa, try f.store.allocator().dupe(u8, id));
    }

    pub const PutConfig = struct {
        /// A location put before.
        location: []const u8,
        /// Empty for one made up, UUID-like.
        id: []const u8 = "",
        display_name: []const u8 = "",
        data_source_id: []const u8 = "scheduled_query",
        destination_dataset_id: []const u8 = "",
        schedule: types.Schedule = .manual,
        next_run_time: ?std.Io.Timestamp = null,
        disabled: bool = false,
        owner_email: []const u8 = "",
        update_time: ?std.Io.Timestamp = null,
        /// A scheduled query's params; written as production writes them.
        scheduled_query: ?types.ScheduledQuery = null,
        /// Params of another data source, each value's JSON text.
        params: []const types.Param = &.{},
        /// How a run now of it ends.
        manual_run: ManualRun = .pending,
    };

    /// A config, answering its name.
    pub fn putConfig(f: *FakeDataTransfer, c: PutConfig) PutError![]const u8 {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (!f.hasLocation(c.location) or !validate.isDataSourceId(c.data_source_id)) return error.InvalidEntry;
        const s = f.store.allocator();
        const id = if (c.id.len > 0) try s.dupe(u8, c.id) else try f.newId();
        if (!validate.isResourceId(id) or f.findConfig(c.location, id) != null) return error.InvalidEntry;
        const location = try s.dupe(u8, c.location);
        const params = if (c.scheduled_query) |q| try scheduledParams(s, q) else try dupeParams(s, c.params);
        const held = try s.create(FakeConfig);
        held.* = .{
            .config = .{
                .name = try std.fmt.allocPrint(s, "projects/{s}/locations/{s}/transferConfigs/{s}", .{ f.options.project_number, location, id }),
                .location = location,
                .id = id,
                .display_name = try s.dupe(u8, c.display_name),
                .data_source_id = try s.dupe(u8, c.data_source_id),
                .destination_dataset_id = try s.dupe(u8, c.destination_dataset_id),
                .dataset_region = try std.ascii.allocLowerString(s, location),
                .schedule = try dupeSchedule(s, c.schedule),
                .next_run_time = c.next_run_time,
                .disabled = c.disabled,
                .update_time = c.update_time orelse std.Io.Clock.real.now(f.io),
                .owner_email = try s.dupe(u8, c.owner_email),
                .params = params,
            },
            .manual_run = switch (c.manual_run) {
                .failed => |e| .{ .failed = .{ .code = e.code, .message = try s.dupe(u8, e.message) } },
                else => c.manual_run,
            },
        };
        try f.configs.append(f.gpa, held);
        return held.config.name;
    }

    pub const PutRun = struct {
        /// A config's name, as `putConfig` answered it.
        config: []const u8,
        id: []const u8 = "",
        state: types.TransferState = .succeeded,
        schedule_time: ?std.Io.Timestamp = null,
        run_time: ?std.Io.Timestamp = null,
        start_time: ?std.Io.Timestamp = null,
        end_time: ?std.Io.Timestamp = null,
        @"error": ?types.Status = null,
        /// The schedule it ran on; empty for one started by hand.
        schedule: []const u8 = "",
    };

    /// A run of a config put before, answering its name. Its config's
    /// state becomes its own when it is the newest.
    pub fn putRun(f: *FakeDataTransfer, r: PutRun) PutError![]const u8 {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (r.state == .unknown) return error.InvalidEntry;
        const held = f.configNamed(r.config) orelse return error.InvalidEntry;
        const s = f.store.allocator();
        const id = if (r.id.len > 0) try s.dupe(u8, r.id) else try f.newId();
        if (!validate.isResourceId(id) or findRun(held, id) != null) return error.InvalidEntry;
        const run = try f.addRun(held, id, r.run_time orelse std.Io.Clock.real.now(f.io));
        run.run.state = r.state;
        run.run.schedule_time = r.schedule_time orelse run.run.run_time;
        run.run.start_time = r.start_time;
        run.run.end_time = r.end_time;
        run.run.schedule = try s.dupe(u8, r.schedule);
        if (r.@"error") |e| run.run.@"error" = .{ .code = e.code, .message = try s.dupe(u8, e.message) };
        held.config.state = r.state;
        return run.run.name;
    }

    /// A message of a run put before or started.
    pub fn putMessage(f: *FakeDataTransfer, run_name: []const u8, m: types.TransferMessage) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (m.severity == .unknown) return error.InvalidEntry;
        const run = f.runNamed(run_name) orelse return error.InvalidEntry;
        try run.messages.append(f.gpa, .{
            .time = m.time orelse std.Io.Clock.real.now(f.io),
            .severity = m.severity,
            .text = try f.store.allocator().dupe(u8, m.text),
        });
    }

    /// Moves a run on, as the service would: started when it runs, ended
    /// (with `err` for a failure) when it ends. Its config's state follows.
    pub fn setRunState(f: *FakeDataTransfer, run_name: []const u8, state: types.TransferState, err: ?types.Status) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (state == .unknown) return error.InvalidEntry;
        const run = f.runNamed(run_name) orelse return error.InvalidEntry;
        if (run.run.state.ended()) return error.InvalidEntry;
        const now = std.Io.Clock.real.now(f.io);
        if (state != .pending and run.run.start_time == null) run.run.start_time = now;
        run.run.state = state;
        run.run.update_time = now;
        if (state.ended()) run.run.end_time = now;
        if (err) |e| run.run.@"error" = .{ .code = e.code, .message = try f.store.allocator().dupe(u8, e.message) };
        if (f.configOfRun(run_name)) |held| held.config.state = state;
    }

    fn hasLocation(f: *FakeDataTransfer, id: []const u8) bool {
        for (f.locations.items) |l| if (std.ascii.eqlIgnoreCase(l, id)) return true;
        return false;
    }

    fn newId(f: *FakeDataTransfer) Allocator.Error![]const u8 {
        defer f.next_id += 1;
        return std.fmt.allocPrint(f.store.allocator(), "{x:0>8}-0000-4000-8000-{x:0>12}", .{ f.next_id, f.next_id });
    }

    fn findConfig(f: *FakeDataTransfer, location: []const u8, id: []const u8) ?*FakeConfig {
        for (f.configs.items) |c| {
            if (std.ascii.eqlIgnoreCase(c.config.location, location) and std.mem.eql(u8, c.config.id, id)) return c;
        }
        return null;
    }

    fn findRun(held: *FakeConfig, id: []const u8) ?*FakeRun {
        for (held.runs.items) |r| if (std.mem.eql(u8, r.run.id, id)) return r;
        return null;
    }

    /// A config by a name as `putConfig` answered it.
    fn configNamed(f: *FakeDataTransfer, name: []const u8) ?*FakeConfig {
        for (f.configs.items) |c| if (std.mem.eql(u8, c.config.name, name)) return c;
        return null;
    }

    fn configOfRun(f: *FakeDataTransfer, run_name: []const u8) ?*FakeConfig {
        const at = std.mem.lastIndexOf(u8, run_name, "/runs/") orelse return null;
        return f.configNamed(run_name[0..at]);
    }

    fn runNamed(f: *FakeDataTransfer, name: []const u8) ?*FakeRun {
        const at = std.mem.lastIndexOf(u8, name, "/runs/") orelse return null;
        const held = f.configNamed(name[0..at]) orelse return null;
        return findRun(held, name[at + "/runs/".len ..]);
    }

    fn addRun(f: *FakeDataTransfer, held: *FakeConfig, id: []const u8, run_time: std.Io.Timestamp) Allocator.Error!*FakeRun {
        const s = f.store.allocator();
        const now = std.Io.Clock.real.now(f.io);
        const run = try s.create(FakeRun);
        const c = held.config;
        run.* = .{ .run = .{
            .name = try std.fmt.allocPrint(s, "{s}/runs/{s}", .{ c.name, id }),
            .config_name = c.name,
            .id = id,
            .state = .pending,
            .schedule_time = now,
            .run_time = run_time,
            .update_time = now,
            .data_source_id = c.data_source_id,
            .destination_dataset_id = c.destination_dataset_id,
            .params = c.params,
        } };
        try held.runs.append(f.gpa, run);
        return run;
    }

    fn scheduledParams(s: Allocator, q: types.ScheduledQuery) Allocator.Error![]const types.Param {
        var list: std.ArrayList(types.Param) = .empty;
        const pairs = [_]struct { []const u8, []const u8 }{
            .{ "query", q.query },
            .{ "destination_table_name_template", q.destination_table_name_template },
            .{ "write_disposition", q.write_disposition },
            .{ "partitioning_field", q.partitioning_field },
        };
        for (pairs) |pair| {
            if (pair[1].len == 0 and !std.mem.eql(u8, pair[0], "query")) continue;
            try list.append(s, .{ .key = pair[0], .json = try Stringify.valueAlloc(s, pair[1], .{}) });
        }
        return list.items;
    }

    fn dupeParams(s: Allocator, params: []const types.Param) PutError![]const types.Param {
        const out = try s.alloc(types.Param, params.len);
        for (params, out) |p, *o| {
            // Each value must be JSON, as production would hold it.
            _ = std.json.parseFromSliceLeaky(std.json.Value, s, p.json, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidEntry,
            };
            o.* = .{ .key = try s.dupe(u8, p.key), .json = try s.dupe(u8, p.json) };
        }
        return out;
    }

    fn dupeSchedule(s: Allocator, schedule: types.Schedule) Allocator.Error!types.Schedule {
        return switch (schedule) {
            .time_based => |t| .{ .time_based = .{ .schedule = try s.dupe(u8, t.schedule), .start_time = t.start_time, .end_time = t.end_time } },
            .event_driven => |sub| .{ .event_driven = try s.dupe(u8, sub) },
            else => schedule,
        };
    }

    // The transport.

    fn send(ptr: *anyopaque, req: tp.Request, arena: Allocator) tp.Error!tp.Response {
        const f: *FakeDataTransfer = @ptrCast(@alignCast(ptr));
        const reply = try f.serve(req, arena);
        return .{ .status = reply.status, .headers = reply.headers, .body = reply.body };
    }

    /// One request, as `send` serves it: for a test that wants to send
    /// what no client would.
    pub fn serve(f: *FakeDataTransfer, req: tp.Request, arena: Allocator) tp.Error!Reply {
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

    fn route(f: *FakeDataTransfer, req: tp.Request, arena: Allocator, route_text: []const u8, query: []const u8) Allocator.Error!Reply {
        if (req.bearer == null) return fail(arena, 401, "UNAUTHENTICATED", "Request is missing required authentication credential. Expected OAuth 2 access token, login cookie or other valid authentication credential. See https://developers.google.com/identity/sign-in/web/devconsole-project.");
        const target = try parseRoute(arena, route_text) orelse return notModelled(arena, "this path, a regionless one among them");
        if (!std.mem.eql(u8, target.project, f.options.project_id) and !std.mem.eql(u8, target.project, f.options.project_number)) {
            return notModelled(arena, "a project other than the fake's own");
        }
        const params = try parseParams(arena, query) orelse return fail(arena, 400, "INVALID_ARGUMENT", "Invalid query string.");
        switch (req.method) {
            .GET => {},
            .POST => switch (target.kind) {
                .start => |c| return f.start(arena, target.project, c, req.body orelse ""),
                else => return notModelled(arena, "a write other than a run now"),
            },
            else => return notModelled(arena, "anything but a read or a run now"),
        }
        switch (target.kind) {
            .locations => {
                // Production refused a page size here (measured).
                if (paramOf(params, "pageSize") != null) return fail(arena, 400, "INVALID_ARGUMENT", "Request contains an invalid argument.");
                return json(arena, f.locations.items, writeLocations, f.options.project_id);
            },
            .configs => |location| return f.listConfigs(arena, location, params),
            .config => |c| {
                const held = f.findConfig(c.location, c.id) orelse return configNotFound(arena, target.project, c.location, c.id);
                return json(arena, held.config, writeConfig, .get);
            },
            .runs => |c| {
                const held = f.findConfig(c.location, c.id) orelse return configNotFound(arena, target.project, c.location, c.id);
                return f.listRuns(arena, held, params);
            },
            .run => |r| {
                const held = f.findConfig(r.location, r.config) orelse return configNotFound(arena, target.project, r.location, r.config);
                const run = findRun(held, r.id) orelse return runNotFound(arena, held, r.id);
                return json(arena, run.run, writeRun, {});
            },
            .messages => |r| {
                const held = f.findConfig(r.location, r.config) orelse return configNotFound(arena, target.project, r.location, r.config);
                const run = findRun(held, r.id) orelse return runNotFound(arena, held, r.id);
                return f.listMessages(arena, run, params);
            },
            .start => return notModelled(arena, "a read of this path"),
        }
    }

    fn listConfigs(f: *FakeDataTransfer, arena: Allocator, location: []const u8, params: []const Param) Allocator.Error!Reply {
        if (std.mem.eql(u8, location, "-")) return fail(arena, 400, "INVALID_ARGUMENT", "BigQuery Data Transfer Service does not yet support location: unknown");
        if (!f.hasLocation(location)) return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Request uses an invalid location: {s}", .{location}));
        var picked: std.ArrayList(types.TransferConfig) = .empty;
        for (f.configs.items) |c| {
            if (!std.ascii.eqlIgnoreCase(c.config.location, location)) continue;
            if (!wanted(params, "dataSourceIds", c.config.data_source_id)) continue;
            try picked.append(arena, c.config);
        }
        // By id, as production listed them (measured twice).
        std.mem.sort(types.TransferConfig, picked.items, {}, struct {
            fn less(_: void, x: types.TransferConfig, y: types.TransferConfig) bool {
                return std.mem.lessThan(u8, x.id, y.id);
            }
        }.less);
        const window = pageOf(params, picked.items.len) orelse return pageRefusal(arena);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        (blk: {
            jw.beginObject() catch |e| break :blk e;
            if (window.to > window.from) {
                jw.objectField("transferConfigs") catch |e| break :blk e;
                jw.beginArray() catch |e| break :blk e;
                for (picked.items[window.from..window.to]) |c| writeConfig(&jw, c, .list) catch |e| break :blk e;
                jw.endArray() catch |e| break :blk e;
            }
            writeToken(&jw, window.next) catch |e| break :blk e;
            jw.endObject() catch |e| break :blk e;
        }) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn listRuns(f: *FakeDataTransfer, arena: Allocator, held: *FakeConfig, params: []const Param) Allocator.Error!Reply {
        _ = f;
        for (params) |p| if (std.mem.eql(u8, p.name, "states") and types.TransferState.fromWire(p.value) == .unknown) {
            return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Invalid value at 'states' (type.googleapis.com/google.cloud.bigquery.datatransfer.v1.TransferState), \"{s}\"", .{p.value}));
        };
        var picked: std.ArrayList(types.TransferRun) = .empty;
        for (held.runs.items) |r| {
            const wire = r.run.state.wireName() orelse continue;
            if (!wanted(params, "states", wire)) continue;
            try picked.append(arena, r.run);
        }
        // Newest run time first, then newest schedule time (measured).
        std.mem.sort(types.TransferRun, picked.items, {}, newerRun);
        if (paramOf(params, "runAttempt")) |attempt| if (std.mem.eql(u8, attempt, "LATEST")) {
            // One a run date, the latest of each (measured).
            var kept: std.ArrayList(types.TransferRun) = .empty;
            var last_day: ?i64 = null;
            for (picked.items) |r| {
                const day = dayOf(r.run_time);
                if (last_day != null and last_day.? == day) continue;
                last_day = day;
                try kept.append(arena, r);
            }
            picked = kept;
        };
        const window = pageOf(params, picked.items.len) orelse return pageRefusal(arena);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        (blk: {
            jw.beginObject() catch |e| break :blk e;
            if (window.to > window.from) {
                jw.objectField("transferRuns") catch |e| break :blk e;
                jw.beginArray() catch |e| break :blk e;
                for (picked.items[window.from..window.to]) |r| writeRun(&jw, r, {}) catch |e| break :blk e;
                jw.endArray() catch |e| break :blk e;
            }
            writeToken(&jw, window.next) catch |e| break :blk e;
            jw.endObject() catch |e| break :blk e;
        }) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn newerRun(_: void, a: types.TransferRun, b: types.TransferRun) bool {
        const at = nanosOf(a.run_time);
        const bt = nanosOf(b.run_time);
        if (at != bt) return at > bt;
        return nanosOf(a.schedule_time) > nanosOf(b.schedule_time);
    }

    fn nanosOf(t: ?std.Io.Timestamp) i96 {
        return if (t) |ts| ts.nanoseconds else std.math.minInt(i96);
    }

    fn dayOf(t: ?std.Io.Timestamp) i64 {
        const ns = nanosOf(t);
        return @intCast(@divFloor(ns, std.time.ns_per_day));
    }

    fn listMessages(f: *FakeDataTransfer, arena: Allocator, run: *FakeRun, params: []const Param) Allocator.Error!Reply {
        _ = f;
        var picked: std.ArrayList(types.TransferMessage) = .empty;
        for (run.messages.items) |m| {
            if (!wanted(params, "messageTypes", m.severity.wireName().?)) continue;
            try picked.append(arena, m);
        }
        // Newest first (measured).
        std.mem.sort(types.TransferMessage, picked.items, {}, newerMessage);
        const window = pageOf(params, picked.items.len) orelse return pageRefusal(arena);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        (blk: {
            jw.beginObject() catch |e| break :blk e;
            if (window.to > window.from) {
                jw.objectField("transferMessages") catch |e| break :blk e;
                jw.beginArray() catch |e| break :blk e;
                for (picked.items[window.from..window.to]) |m| writeMessage(&jw, m) catch |e| break :blk e;
                jw.endArray() catch |e| break :blk e;
            }
            writeToken(&jw, window.next) catch |e| break :blk e;
            jw.endObject() catch |e| break :blk e;
        }) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn newerMessage(_: void, a: types.TransferMessage, b: types.TransferMessage) bool {
        return nanosOf(a.time) > nanosOf(b.time);
    }

    /// A run now: one run, its run time the one asked, its outcome as the
    /// config says; production's messages for a scheduled query.
    fn start(f: *FakeDataTransfer, arena: Allocator, project: []const u8, c: ConfigRoute, body: []const u8) Allocator.Error!Reply {
        const held = f.findConfig(c.location, c.id) orelse return configNotFound(arena, project, c.location, c.id);
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
        if (value != .object) return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
        if (value.object.get("requestedTimeRange") != null) return notModelled(arena, "a backfill over a time range");
        const asked = value.object.get("requestedRunTime") orelse return unmeasured(arena, "a run now without a time");
        if (asked != .string) return fail(arena, 400, "INVALID_ARGUMENT", "Invalid value at 'requested_run_time' (type.googleapis.com/google.protobuf.Timestamp)");
        const run_time = core.timestamp.parse(asked.string) catch return fail(arena, 400, "INVALID_ARGUMENT", "Invalid value at 'requested_run_time' (type.googleapis.com/google.protobuf.Timestamp)");
        if (held.config.disabled) return fail(arena, 400, "INVALID_ARGUMENT", "Transfer is disabled. Please enable the transfer config before starting transfer runs.");

        const run = try f.addRun(held, try f.newId(), run_time);
        f.runs_started += 1;
        held.config.state = .pending;
        // The answer shows the run as it was started, PENDING (measured).
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        (blk: {
            jw.beginObject() catch |e| break :blk e;
            jw.objectField("runs") catch |e| break :blk e;
            jw.beginArray() catch |e| break :blk e;
            writeRun(&jw, run.run, {}) catch |e| break :blk e;
            jw.endArray() catch |e| break :blk e;
            jw.endObject() catch |e| break :blk e;
        }) catch return error.OutOfMemory;
        try f.dispatched(run);
        switch (held.manual_run) {
            .pending => {},
            .succeeded => try f.finish(held, run, .succeeded, null),
            .failed => |e| try f.finish(held, run, .failed, e),
        }
        return .{ .status = 200, .body = out.written() };
    }

    /// The first line production writes on a run's story.
    fn dispatched(f: *FakeDataTransfer, run: *FakeRun) Allocator.Error!void {
        const s = f.store.allocator();
        try run.messages.append(f.gpa, .{
            .time = std.Io.Clock.real.now(f.io),
            .severity = .info,
            .text = try std.fmt.allocPrint(s, "Dispatched run to data source with id {d}", .{f.next_id}),
        });
    }

    /// A run ended at once, with production's lines for a scheduled query.
    fn finish(f: *FakeDataTransfer, held: *FakeConfig, run: *FakeRun, state: types.TransferState, err: ?types.Status) Allocator.Error!void {
        const s = f.store.allocator();
        const now = std.Io.Clock.real.now(f.io);
        run.run.state = state;
        run.run.start_time = now;
        run.run.end_time = now;
        run.run.update_time = now;
        held.config.state = state;
        const job = try std.fmt.allocPrint(s, "scheduled_query_{s}", .{run.run.id});
        const lines: []const struct { types.MessageSeverity, []const u8 } = if (err) |e| &.{
            .{ .info, "Starting to process the query job with no parameters." },
            .{ .info, try std.fmt.allocPrint(s, "Job {s} (table {s}) started.", .{ job, held.config.destination_dataset_id }) },
            .{ .@"error", try std.fmt.allocPrint(s, "BigQuery job {s} failed with error INVALID_ARGUMENT: {s}. Check BigQuery job details for more information.", .{ job, e.message }) },
            .{ .info, "Summary: succeeded 0 jobs, failed 1 jobs." },
        } else &.{
            .{ .info, "Starting to process the query job with no parameters." },
            .{ .info, try std.fmt.allocPrint(s, "Job {s} (table {s}) started.", .{ job, held.config.destination_dataset_id }) },
            .{ .info, try std.fmt.allocPrint(s, "Job {s} (table {s}) completed successfully.", .{ job, held.config.destination_dataset_id }) },
            .{ .info, "Summary: succeeded 1 jobs, failed 0 jobs." },
        };
        for (lines, 1..) |line, i| try run.messages.append(f.gpa, .{
            // Apart by a microsecond each, so newest first is their order.
            .time = .{ .nanoseconds = now.nanoseconds + @as(i96, @intCast(i)) * std.time.ns_per_us },
            .severity = line[0],
            .text = line[1],
        });
        if (err) |e| run.run.@"error" = .{ .code = e.code, .message = try s.dupe(u8, e.message) };
    }

    // Writing what production writes.

    const Shape = enum { get, list };

    fn writeTime(jw: *Stringify, name: []const u8, t: ?std.Io.Timestamp) Stringify.Error!void {
        const ts = t orelse return;
        var buf: [core.timestamp.max_len]u8 = undefined;
        try jw.objectField(name);
        try jw.write(core.timestamp.format(&buf, ts));
    }

    fn writeString(jw: *Stringify, name: []const u8, text: []const u8) Stringify.Error!void {
        if (text.len == 0) return;
        try jw.objectField(name);
        try jw.write(text);
    }

    fn writeParams(jw: *Stringify, params: []const types.Param) Stringify.Error!void {
        if (params.len == 0) return;
        try jw.objectField("params");
        try jw.beginObject();
        for (params) |p| {
            try jw.objectField(p.key);
            try jw.beginWriteRaw();
            try jw.writer.writeAll(p.json);
            jw.endWriteRaw();
        }
        try jw.endObject();
    }

    fn stateWire(state: types.TransferState) ?[]const u8 {
        return state.wireName();
    }

    fn writeLocations(jw: *Stringify, locations: []const []const u8, project: []const u8) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("locations");
        try jw.beginArray();
        for (locations) |l| {
            try jw.beginObject();
            try jw.objectField("name");
            try jw.print("\"projects/{s}/locations/{s}\"", .{ project, l });
            try jw.objectField("labels");
            try jw.beginObject();
            try jw.objectField("cloud.googleapis.com/location");
            try jw.write(l);
            try jw.endObject();
            try jw.objectField("locationId");
            try jw.write(l);
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();
    }

    fn writeConfig(jw: *Stringify, c: types.TransferConfig, shape: Shape) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(c.name);
        try writeString(jw, "destinationDatasetId", c.destination_dataset_id);
        try writeString(jw, "displayName", c.display_name);
        try writeTime(jw, "updateTime", c.update_time);
        try writeString(jw, "dataSourceId", c.data_source_id);
        switch (c.schedule) {
            .time_based => |t| {
                try jw.objectField("schedule");
                try jw.write(t.schedule);
            },
            else => {},
        }
        try writeParams(jw, c.params);
        try writeTime(jw, "nextRunTime", c.next_run_time);
        if (stateWire(c.state)) |state| {
            try jw.objectField("state");
            try jw.write(state);
        }
        if (c.disabled) {
            try jw.objectField("disabled");
            try jw.write(true);
        }
        try writeString(jw, "datasetRegion", c.dataset_region);
        try jw.objectField("emailPreferences");
        try jw.beginObject();
        try jw.endObject();
        // Both shapes, as production answered them for a config made with
        // either (measured).
        try jw.objectField("scheduleOptions");
        try jw.beginObject();
        switch (c.schedule) {
            .manual => {
                try jw.objectField("disableAutoScheduling");
                try jw.write(true);
            },
            .time_based => |t| {
                try writeTime(jw, "startTime", t.start_time);
                try writeTime(jw, "endTime", t.end_time);
            },
            else => {},
        }
        try jw.endObject();
        if (shape == .get) if (c.owner_email.len > 0) {
            try jw.objectField("ownerInfo");
            try jw.beginObject();
            try jw.objectField("email");
            try jw.write(c.owner_email);
            try jw.endObject();
        };
        switch (c.schedule) {
            .default => {},
            .manual => {
                try jw.objectField("scheduleOptionsV2");
                try jw.beginObject();
                try jw.objectField("manualSchedule");
                try jw.beginObject();
                try jw.endObject();
                try jw.endObject();
            },
            .time_based => |t| {
                try jw.objectField("scheduleOptionsV2");
                try jw.beginObject();
                try jw.objectField("timeBasedSchedule");
                try jw.beginObject();
                try jw.objectField("schedule");
                try jw.write(t.schedule);
                try writeTime(jw, "startTime", t.start_time);
                try writeTime(jw, "endTime", t.end_time);
                try jw.endObject();
                try jw.endObject();
            },
            .event_driven => |sub| {
                try jw.objectField("scheduleOptionsV2");
                try jw.beginObject();
                try jw.objectField("eventDrivenSchedule");
                try jw.beginObject();
                try jw.objectField("pubsubSubscription");
                try jw.write(sub);
                try jw.endObject();
                try jw.endObject();
            },
        }
        try jw.endObject();
    }

    fn writeRun(jw: *Stringify, r: types.TransferRun, _: void) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(r.name);
        try writeString(jw, "destinationDatasetId", r.destination_dataset_id);
        try writeTime(jw, "scheduleTime", r.schedule_time);
        try writeTime(jw, "startTime", r.start_time);
        try writeTime(jw, "endTime", r.end_time);
        try writeTime(jw, "updateTime", r.update_time);
        try writeString(jw, "dataSourceId", r.data_source_id);
        if (stateWire(r.state)) |state| {
            try jw.objectField("state");
            try jw.write(state);
        }
        try writeParams(jw, r.params);
        try writeTime(jw, "runTime", r.run_time);
        try writeString(jw, "schedule", r.schedule);
        // A run that ended carries its error, `{}` for a success
        // (measured); one not yet ended, none.
        if (r.@"error") |e| {
            try jw.objectField("errorStatus");
            try jw.beginObject();
            try jw.objectField("code");
            try jw.write(e.code);
            try jw.objectField("message");
            try jw.write(e.message);
            try jw.endObject();
        } else if (r.state.ended()) {
            try jw.objectField("errorStatus");
            try jw.beginObject();
            try jw.endObject();
        }
        try jw.objectField("emailPreferences");
        try jw.beginObject();
        try jw.endObject();
        try jw.endObject();
    }

    fn writeMessage(jw: *Stringify, m: types.TransferMessage) Stringify.Error!void {
        try jw.beginObject();
        try writeTime(jw, "messageTime", m.time);
        try jw.objectField("severity");
        try jw.write(m.severity.wireName().?);
        try jw.objectField("messageText");
        try jw.write(m.text);
        try jw.endObject();
    }

    fn writeToken(jw: *Stringify, next: ?usize) Stringify.Error!void {
        const n = next orelse return;
        try jw.objectField("nextPageToken");
        try jw.print("\"p{d}\"", .{n});
    }

    fn json(arena: Allocator, value: anytype, comptime write: anytype, extra: anytype) Allocator.Error!Reply {
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        write(&jw, value, extra) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    // Routes and parameters.

    const ConfigRoute = struct { location: []const u8, id: []const u8 };
    const RunRoute = struct { location: []const u8, config: []const u8, id: []const u8 };

    const Route = struct {
        project: []const u8,
        kind: union(enum) {
            locations,
            configs: []const u8,
            config: ConfigRoute,
            start: ConfigRoute,
            runs: ConfigRoute,
            run: RunRoute,
            messages: RunRoute,
        },
    };

    fn pathOf(url: []const u8) []const u8 {
        const scheme = std.mem.indexOf(u8, url, "://") orelse return url;
        const rest = url[scheme + 3 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "/";
        return rest[slash..];
    }

    /// `/v1/projects/{p}/locations[/{l}/transferConfigs[/{id}[:startManualRuns|/runs[/{r}[/transferLogs]]]]]`,
    /// each segment decoded.
    fn parseRoute(arena: Allocator, path: []const u8) Allocator.Error!?Route {
        const prefix = "/v1/projects/";
        if (!std.mem.startsWith(u8, path, prefix)) return null;
        var segments: [9][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, path[prefix.len..], '/');
        while (it.next()) |segment| {
            if (n == segments.len or segment.len == 0) return null;
            segments[n] = std.Uri.percentDecodeInPlace(try arena.dupe(u8, segment));
            n += 1;
        }
        const s = segments[0..n];
        if (s.len < 2 or !std.mem.eql(u8, s[1], "locations")) return null;
        const project = s[0];
        if (s.len == 2) return .{ .project = project, .kind = .locations };
        if (s.len < 4 or !std.mem.eql(u8, s[3], "transferConfigs")) return null;
        const location = s[2];
        if (s.len == 4) return .{ .project = project, .kind = .{ .configs = location } };
        var id = s[4];
        if (s.len == 5) {
            if (std.mem.endsWith(u8, id, ":startManualRuns")) {
                id = id[0 .. id.len - ":startManualRuns".len];
                return .{ .project = project, .kind = .{ .start = .{ .location = location, .id = id } } };
            }
            return .{ .project = project, .kind = .{ .config = .{ .location = location, .id = id } } };
        }
        if (!std.mem.eql(u8, s[5], "runs")) return null;
        if (s.len == 6) return .{ .project = project, .kind = .{ .runs = .{ .location = location, .id = id } } };
        const run: RunRoute = .{ .location = location, .config = id, .id = s[6] };
        if (s.len == 7) return .{ .project = project, .kind = .{ .run = run } };
        if (s.len == 8 and std.mem.eql(u8, s[7], "transferLogs")) return .{ .project = project, .kind = .{ .messages = run } };
        return null;
    }

    const Param = struct { name: []const u8, value: []const u8 };

    fn parseParams(arena: Allocator, query: []const u8) Allocator.Error!?[]const Param {
        var list: std.ArrayList(Param) = .empty;
        if (query.len == 0) return list.items;
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return null;
            const name_copy = try arena.dupe(u8, pair[0..eq]);
            const value_copy = try arena.dupe(u8, pair[eq + 1 ..]);
            try list.append(arena, .{
                .name = std.Uri.percentDecodeInPlace(name_copy),
                .value = std.Uri.percentDecodeInPlace(value_copy),
            });
        }
        return list.items;
    }

    fn paramOf(params: []const Param, name: []const u8) ?[]const u8 {
        for (params) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
        return null;
    }

    /// Whether `value` passes a repeated filter `name`: any value given, or
    /// none given at all.
    fn wanted(params: []const Param, name: []const u8, value: []const u8) bool {
        var any = false;
        for (params) |p| if (std.mem.eql(u8, p.name, name)) {
            any = true;
            if (std.mem.eql(u8, p.value, value)) return true;
        };
        return !any;
    }

    const Window = struct { from: usize, to: usize, next: ?usize };

    fn pageOf(params: []const Param, total: usize) ?Window {
        var size: usize = @min(total, 1000);
        if (paramOf(params, "pageSize")) |text| {
            const n = std.fmt.parseInt(usize, text, 10) catch return null;
            if (n != 0) size = @min(n, total);
        }
        var from: usize = 0;
        if (paramOf(params, "pageToken")) |t| {
            if (!std.mem.startsWith(u8, t, "p")) return null;
            from = std.fmt.parseInt(usize, t[1..], 10) catch return null;
            if (from > total) return null;
        }
        const to = @min(total, from + size);
        return .{ .from = from, .to = to, .next = if (to < total) to else null };
    }

    fn pageRefusal(arena: Allocator) Allocator.Error!Reply {
        return fail(arena, 400, "INVALID_ARGUMENT", "fake: an invalid page token or page size");
    }

    fn configNotFound(arena: Allocator, project: []const u8, location: []const u8, id: []const u8) Allocator.Error!Reply {
        return fail(arena, 404, "NOT_FOUND", try arena.print("The requested transfer config (projects/{s}/locations/{s}/transferConfigs/{s}) was not found.", .{ project, location, id }));
    }

    fn runNotFound(arena: Allocator, held: *FakeConfig, id: []const u8) Allocator.Error!Reply {
        return fail(arena, 404, "NOT_FOUND", try arena.print("The requested transfer run ({s}/runs/{s}) was not found.", .{ held.config.name, id }));
    }

    /// Data Transfer's error body: the code, the message and the status
    /// (measured; no details on these).
    fn fail(arena: Allocator, code: u16, status: []const u8, message: []const u8) Allocator.Error!Reply {
        return .{ .status = code, .body = try Stringify.valueAlloc(arena, .{ .@"error" = .{
            .code = code,
            .message = message,
            .status = status,
        } }, .{}) };
    }

    fn notModelled(arena: Allocator, what: []const u8) Allocator.Error!Reply {
        return fail(arena, 501, "UNIMPLEMENTED", try arena.print("fake: {s} is not modelled", .{what}));
    }

    fn unmeasured(arena: Allocator, what: []const u8) Allocator.Error!Reply {
        return fail(arena, 501, "UNIMPLEMENTED", try arena.print("fake: production's answer to {s} was not measured", .{what}));
    }

    fn refusal(arena: Allocator, status: u16) Allocator.Error!Reply {
        const name = switch (status) {
            400 => "INVALID_ARGUMENT",
            401 => "UNAUTHENTICATED",
            403 => "PERMISSION_DENIED",
            404 => "NOT_FOUND",
            429 => "RESOURCE_EXHAUSTED",
            500 => "INTERNAL",
            503 => "UNAVAILABLE",
            504 => "DEADLINE_EXCEEDED",
            else => "UNKNOWN",
        };
        return fail(arena, status, name, "fake: refused as the test asked");
    }
};

// Tests, held to what production answered in milestone 0.

const testing = std.testing;
const codec = @import("codec.zig");
const production = @import("production_bodies.zig");
const Client = @import("Client.zig");

const Bench = struct {
    clock: core.testing.FakeClock,
    fake: FakeDataTransfer,
    token: core.StaticToken,
    diag: core.Diagnostics,
    client: Client,

    fn init(b: *Bench, options: FakeDataTransfer.Options) !void {
        b.* = .{ .clock = .{ .now_ns = 1_792_608_298 * std.time.ns_per_s }, .fake = undefined, .token = .{ .token = "t" }, .diag = .{}, .client = undefined };
        b.fake = .init(testing.allocator, b.clock.io(), options);
        errdefer b.fake.deinit();
        b.client = try .init(testing.allocator, b.clock.io(), .{
            .project_id = options.project_id,
            .token_provider = b.token.provider(),
            .transport = b.fake.transport(),
            .diagnostics = &b.diag,
            .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
        });
    }

    fn deinit(b: *Bench) void {
        b.client.deinit();
        b.fake.deinit();
    }

    fn raw(b: *Bench, arena: Allocator, method: tp.Method, path: []const u8, body: ?[]const u8) !FakeDataTransfer.Reply {
        return b.fake.serve(.{ .method = method, .url = path, .bearer = "t", .body = body }, arena);
    }
};

const probe: FakeDataTransfer.Options = .{ .project_id = "extractctl", .project_number = "82150720798" };

/// A config as production answered its get, put in as it was.
fn putProduction(fake: *FakeDataTransfer, a: Allocator, body: []const u8) ![]const u8 {
    const c = try codec.decodeConfig(a, a, body);
    return fake.putConfig(.{
        .location = c.location,
        .id = c.id,
        .display_name = c.display_name,
        .data_source_id = c.data_source_id,
        .destination_dataset_id = c.destination_dataset_id,
        .schedule = c.schedule,
        .next_run_time = c.next_run_time,
        .disabled = c.disabled,
        .owner_email = c.owner_email,
        .update_time = c.update_time,
        .params = c.params,
    });
}

/// The probe's three configs, in the order production lists them.
fn seedProbe(fake: *FakeDataTransfer, a: Allocator) !void {
    try fake.putLocation("us");
    try fake.putLocation("europe");
    const page = try codec.decodeConfigPage(a, a, production.configs_page);
    for (page.configs) |listed| {
        for ([_][]const u8{ production.config_manual, production.config_scheduled, production.config_failing }) |body| {
            const c = try codec.decodeConfig(a, a, body);
            if (std.mem.eql(u8, c.name, listed.name)) _ = try putProduction(fake, a, body);
        }
    }
}

const manual = "projects/82150720798/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862";

/// `c` with its params sorted by key: production wrote one config's params
/// in one order in its get and another in its list (a map's order), so
/// they compare as sets.
fn sortedParams(a: Allocator, c: types.TransferConfig) !types.TransferConfig {
    var copy = c;
    const params = try a.dupe(types.Param, c.params);
    std.mem.sort(types.Param, params, {}, struct {
        fn less(_: void, x: types.Param, y: types.Param) bool {
            return std.mem.lessThan(u8, x.key, y.key);
        }
    }.less);
    copy.params = params;
    return copy;
}

test "gets and lists answer as production did, decoded field for field" {
    var b: Bench = undefined;
    try b.init(probe);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try seedProbe(&b.fake, a);
    const c = &b.client;
    inline for (.{ production.config_manual, production.config_scheduled, production.config_failing }) |body| {
        const want = try codec.decodeConfig(a, a, body);
        var got = try c.getTransferConfig(want.name);
        defer got.deinit();
        try testing.expectEqualDeep(want, got.value);
    }
    var page = try c.listTransferConfigs("us", .{});
    defer page.deinit();
    const want_page = try codec.decodeConfigPage(a, a, production.configs_page);
    try testing.expectEqual(want_page.configs.len, page.value.configs.len);
    for (want_page.configs, page.value.configs) |w, g| try testing.expectEqualDeep(try sortedParams(a, w), try sortedParams(a, g));
    try testing.expectEqual(want_page.next_page_token, page.value.next_page_token);
    var scheduled_only = try c.listTransferConfigs("us", .{ .data_sources = &.{"scheduled_query"} });
    defer scheduled_only.deinit();
    try testing.expectEqual(3, scheduled_only.value.configs.len);
    var none = try c.listTransferConfigs("us", .{ .data_sources = &.{"google_cloud_storage"} });
    defer none.deinit();
    try testing.expectEqual(0, none.value.configs.len);
    var paged = try c.listTransferConfigs("us", .{ .page_size = 1 });
    defer paged.deinit();
    try testing.expect(paged.value.next_page_token != null);
    var empty = try c.listTransferConfigs("europe", .{});
    defer empty.deinit();
    try testing.expectEqual(0, empty.value.configs.len);
    // The project by id in the path answers the config named by number.
    var by_id = try c.getTransferConfig("projects/extractctl/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862");
    defer by_id.deinit();
    try testing.expectEqualStrings(manual, by_id.value.name);
    var locations = try c.listLocations(.{});
    defer locations.deinit();
    try testing.expectEqual(2, locations.value.locations.len);
    try testing.expectEqualStrings("us", locations.value.locations[0].id);
    try testing.expectEqualStrings("projects/extractctl/locations/us", locations.value.locations[0].name);
}

test "runs list as production listed them: newest run time first, LATEST one a run date" {
    var b: Bench = undefined;
    try b.init(probe);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try seedProbe(&b.fake, a);
    const want = try codec.decodeRunPage(a, a, production.runs_page);
    // Put in out of order: the fake sorts.
    var i: usize = want.runs.len;
    while (i > 0) {
        i -= 1;
        const r = want.runs[(i * 5) % want.runs.len];
        _ = b.fake.putRun(.{ .config = manual, .id = r.id, .state = r.state, .schedule_time = r.schedule_time, .run_time = r.run_time, .start_time = r.start_time, .end_time = r.end_time }) catch |err| switch (err) {
            error.InvalidEntry => {}, // put already, from an earlier index
            else => return err,
        };
    }
    var runs = try b.client.listRuns(manual, .{});
    defer runs.deinit();
    try testing.expectEqual(want.runs.len, runs.value.runs.len);
    for (want.runs, runs.value.runs) |w, g| try testing.expectEqualStrings(w.id, g.id);
    var latest = try b.client.listRuns(manual, .{ .latest_only = true });
    defer latest.deinit();
    const want_latest = try codec.decodeRunPage(a, a, production.runs_latest);
    try testing.expectEqual(want_latest.runs.len, latest.value.runs.len);
    for (want_latest.runs, latest.value.runs) |w, g| try testing.expectEqualStrings(w.id, g.id);
    var succeeded = try b.client.listRuns(manual, .{ .states = &.{.succeeded} });
    defer succeeded.deinit();
    try testing.expectEqual(8, succeeded.value.runs.len);
    var running = try b.client.listRuns(manual, .{ .states = &.{ .pending, .running } });
    defer running.deinit();
    try testing.expectEqual(0, running.value.runs.len);
    var two = try b.client.listRuns(manual, .{ .page_size = 2 });
    defer two.deinit();
    try testing.expect(two.value.next_page_token != null);
    var ok = try b.client.getRun(manual ++ "/runs/6ae65981-0000-2805-bdde-883d24fa83a4");
    defer ok.deinit();
    const want_ok = try codec.decodeRun(a, a, production.run_succeeded);
    try testing.expectEqual(want_ok.run_time, ok.value.run_time);
    try testing.expectEqual(null, ok.value.@"error");
}

test "a run now: pending until moved, or ended at once as the config says, with its messages" {
    var b: Bench = undefined;
    try b.init(probe);
    defer b.deinit();
    try b.fake.putLocation("us");
    const query: types.ScheduledQuery = .{ .query = "SELECT 17 AS x", .destination_table_name_template = "t_{run_date}", .write_disposition = "WRITE_TRUNCATE" };
    const pending = try b.fake.putConfig(.{ .location = "us", .display_name = "pending", .destination_dataset_id = "d", .scheduled_query = query });
    const ok = try b.fake.putConfig(.{ .location = "us", .destination_dataset_id = "d", .scheduled_query = query, .manual_run = .succeeded });
    const bad = try b.fake.putConfig(.{ .location = "us", .destination_dataset_id = "d", .scheduled_query = query, .manual_run = .{ .failed = .{ .code = 3, .message = "division by zero: 1 / 0" } } });
    const off = try b.fake.putConfig(.{ .location = "us", .scheduled_query = query, .schedule = .{ .time_based = .{ .schedule = "every 24 hours" } }, .disabled = true });
    const c = &b.client;

    var started = try c.startManualRun(pending, .{});
    defer started.deinit();
    const run = started.value.runs[0];
    try testing.expectEqual(types.TransferState.pending, run.state);
    try testing.expectEqual(std.Io.Timestamp{ .nanoseconds = b.clock.now_ns }, run.run_time.?);
    var config = try c.getTransferConfig(pending);
    defer config.deinit();
    try testing.expectEqual(types.TransferState.pending, config.value.state);
    try testing.expectEqualStrings("SELECT 17 AS x", config.value.scheduled_query.?.query);
    try b.fake.setRunState(run.name, .running, null);
    b.clock.now_ns += 75 * std.time.ns_per_s;
    try b.fake.setRunState(run.name, .succeeded, null);
    var ended = try c.getRun(run.name);
    defer ended.deinit();
    try testing.expect(ended.value.succeeded() and ended.value.start_time != null and ended.value.end_time != null);
    try testing.expectEqual(null, ended.value.@"error");
    try testing.expectError(error.InvalidEntry, b.fake.setRunState(run.name, .running, null));

    var done = try c.startManualRun(ok, .{});
    done.deinit();
    var ok_runs = try c.listRuns(ok, .{});
    defer ok_runs.deinit();
    try testing.expect(ok_runs.value.runs[0].succeeded());
    var messages = try c.listMessages(ok_runs.value.runs[0].name, .{});
    defer messages.deinit();
    try testing.expectEqualStrings("Summary: succeeded 1 jobs, failed 0 jobs.", messages.value.messages[0].text);
    try testing.expect(std.mem.startsWith(u8, messages.value.messages[messages.value.messages.len - 1].text, "Dispatched run to data source with id "));

    var failed = try c.startManualRun(bad, .{});
    failed.deinit();
    var bad_runs = try c.listRuns(bad, .{ .states = &.{.failed} });
    defer bad_runs.deinit();
    try testing.expectEqual(3, bad_runs.value.runs[0].@"error".?.code);
    var errors_only = try c.listMessages(bad_runs.value.runs[0].name, .{ .severities = &.{.@"error"} });
    defer errors_only.deinit();
    try testing.expectEqual(1, errors_only.value.messages.len);
    try testing.expect(std.mem.indexOf(u8, errors_only.value.messages[0].text, "failed with error INVALID_ARGUMENT: division by zero: 1 / 0") != null);
    var bad_config = try c.getTransferConfig(bad);
    defer bad_config.deinit();
    try testing.expectEqual(types.TransferState.failed, bad_config.value.state);

    // Disabled: refused in production's words, nothing started.
    try testing.expectError(error.InvalidArgument, c.startManualRun(off, .{}));
    try testing.expectEqualStrings("Transfer is disabled. Please enable the transfer config before starting transfer runs.", b.diag.message());
    // The same time twice makes two runs; a time ahead is taken.
    const t: std.Io.Timestamp = .{ .nanoseconds = b.clock.now_ns };
    var first = try c.startManualRun(pending, .{ .run_time = t });
    first.deinit();
    var second = try c.startManualRun(pending, .{ .run_time = t });
    second.deinit();
    var ahead = try c.startManualRun(pending, .{ .run_time = .{ .nanoseconds = b.clock.now_ns + 60 * std.time.ns_per_s } });
    ahead.deinit();
    try testing.expectEqual(6, b.fake.runsStarted());
    var all = try c.listRuns(pending, .{});
    defer all.deinit();
    try testing.expectEqual(4, all.value.runs.len);
}

test "a lost answer to a run now leaves the run started, and the client does not send it again" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us");
    const config = try b.fake.putConfig(.{ .location = "us", .scheduled_query = .{ .query = "SELECT 1" } });
    b.fake.loseNext(1, 503);
    try testing.expectError(error.Unavailable, b.client.startManualRun(config, .{}));
    try testing.expectEqual(1, b.fake.runsStarted());
    try testing.expectEqual(1, b.fake.callCount());
    // The runs say it started.
    var runs = try b.client.listRuns(config, .{});
    defer runs.deinit();
    try testing.expectEqual(1, runs.value.runs.len);
    // A dropped connection on a read is retried.
    b.fake.dropNext(1);
    var again = try b.client.listRuns(config, .{});
    again.deinit();
    b.fake.refuseNext(1, 503);
    var third = try b.client.getTransferConfig(config);
    third.deinit();
}

test "refusals in production's words" {
    var b: Bench = undefined;
    try b.init(probe);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try seedProbe(&b.fake, a);
    const c = &b.client;
    const words = struct {
        fn of(arena_: Allocator, body: []const u8) ![]const u8 {
            const v = try std.json.parseFromSliceLeaky(std.json.Value, arena_, body, .{});
            return v.object.get("error").?.object.get("message").?.string;
        }
    };
    try testing.expectError(error.NotFound, c.getTransferConfig("projects/extractctl/locations/us/transferConfigs/zigps-nobody"));
    try testing.expectEqualStrings(try words.of(a, production.config_unknown), b.diag.message());
    try testing.expectError(error.NotFound, c.getTransferConfig("projects/extractctl/locations/europe/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862"));
    try testing.expectEqualStrings(try words.of(a, production.config_wrong_location), b.diag.message());
    try testing.expectError(error.NotFound, c.listRuns("projects/extractctl/locations/us/transferConfigs/zigps-nobody", .{}));
    try testing.expectError(error.NotFound, c.getRun(manual ++ "/runs/00000000-0000-0000-0000-000000000000"));
    try testing.expectEqualStrings(try words.of(a, production.run_unknown), b.diag.message());
    try testing.expectError(error.InvalidArgument, c.listTransferConfigs("zz-nowhere1", .{}));
    try testing.expectEqualStrings(try words.of(a, production.location_invalid), b.diag.message());
    // What the client refuses before sending, the fake refuses as
    // production does.
    const dash = try b.raw(a, .GET, "/v1/projects/extractctl/locations/-/transferConfigs", null);
    try testing.expectEqual(400, dash.status);
    try testing.expectEqualStrings(try words.of(a, production.location_dash), try words.of(a, dash.body));
    const states = try b.raw(a, .GET, "/v1/" ++ manual ++ "/runs?states=NOPE", null);
    try testing.expectEqualStrings(try words.of(a, production.runs_states_invalid), try words.of(a, states.body));
    const page_size = try b.raw(a, .GET, "/v1/projects/extractctl/locations?pageSize=2", null);
    try testing.expectEqualStrings(try words.of(a, production.locations_page_size), try words.of(a, page_size.body));
    const unauthenticated = try b.fake.serve(.{ .method = .GET, .url = "/v1/projects/extractctl/locations" }, a);
    try testing.expectEqual(401, unauthenticated.status);
    const Raw = struct { tp.Method, []const u8, ?[]const u8, []const u8 };
    for ([_]Raw{
        .{ .GET, "/v1/projects/extractctl/transferConfigs", null, "fake: this path, a regionless one among them is not modelled" },
        .{ .GET, "/v1/projects/other/locations", null, "fake: a project other than the fake's own is not modelled" },
        .{ .POST, "/v1/projects/extractctl/locations/us/transferConfigs", "{}", "fake: a write other than a run now is not modelled" },
        .{ .PATCH, "/v1/" ++ manual, "{}", "fake: anything but a read or a run now is not modelled" },
        .{ .POST, "/v1/" ++ manual ++ ":startManualRuns", "{\"requestedTimeRange\":{}}", "fake: a backfill over a time range is not modelled" },
        .{ .POST, "/v1/" ++ manual ++ ":startManualRuns", "{}", "fake: production's answer to a run now without a time was not measured" },
    }) |r| {
        const reply = try b.raw(a, r[0], r[1], r[2]);
        try testing.expectEqual(501, reply.status);
        try testing.expectEqualStrings(r[3], try words.of(a, reply.body));
    }
}

test "the wire as production writes it, beyond what the client reads" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try b.fake.putLocation("US");
    // Put in out of id order; listed by id, as production lists them.
    const later = try b.fake.putConfig(.{ .location = "US", .id = "zz-later", .scheduled_query = .{ .query = "SELECT 1" }, .manual_run = .succeeded });
    _ = try b.fake.putConfig(.{ .location = "US", .id = "aa-first", .scheduled_query = .{ .query = "SELECT 2" } });
    var page = try b.client.listTransferConfigs("US", .{});
    defer page.deinit();
    try testing.expectEqualStrings("aa-first", page.value.configs[0].id);
    try testing.expectEqualStrings("zz-later", page.value.configs[1].id);
    // The region lower case, as production's `us`.
    try testing.expectEqualStrings("us", page.value.configs[0].dataset_region);
    // A manual config in both shapes, as production wrote it.
    const got = try b.raw(a, .GET, "/v1/projects/my-project/locations/US/transferConfigs/zz-later", null);
    try testing.expect(std.mem.indexOf(u8, got.body, "\"scheduleOptions\":{\"disableAutoScheduling\":true}") != null);
    try testing.expect(std.mem.indexOf(u8, got.body, "\"scheduleOptionsV2\":{\"manualSchedule\":{}}") != null);
    // A succeeded run's error as `{}`.
    var started = try b.client.startManualRun(later, .{});
    defer started.deinit();
    const run = try b.raw(a, .GET, try std.fmt.allocPrint(a, "/v1/{s}", .{started.value.runs[0].name}), null);
    try testing.expect(std.mem.indexOf(u8, run.body, "\"state\":\"SUCCEEDED\"") != null);
    try testing.expect(std.mem.indexOf(u8, run.body, "\"errorStatus\":{}") != null);
    // A run now's answer, PENDING and without an error.
    try testing.expect(started.value.runs[0].@"error" == null);
}

test "what a test puts in, the fake checks" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us");
    try testing.expectError(error.InvalidEntry, b.fake.putLocation("us"));
    try testing.expectError(error.InvalidEntry, b.fake.putLocation("-"));
    try testing.expectError(error.InvalidEntry, b.fake.putConfig(.{ .location = "europe" }));
    try testing.expectError(error.InvalidEntry, b.fake.putConfig(.{ .location = "us", .data_source_id = "Bad Source" }));
    try testing.expectError(error.InvalidEntry, b.fake.putConfig(.{ .location = "us", .id = "a/b" }));
    try testing.expectError(error.InvalidEntry, b.fake.putConfig(.{ .location = "us", .data_source_id = "google_cloud_storage", .params = &.{.{ .key = "x", .json = "{" }} }));
    const config = try b.fake.putConfig(.{ .location = "us", .id = "c1" });
    try testing.expectEqualStrings("projects/123456789012/locations/us/transferConfigs/c1", config);
    const nobody = "projects/123456789012/locations/us/transferConfigs/c1/runs/nobody";
    try testing.expectError(error.InvalidEntry, b.fake.putConfig(.{ .location = "us", .id = "c1" }));
    try testing.expectError(error.InvalidEntry, b.fake.putRun(.{ .config = "projects/x/locations/us/transferConfigs/nobody" }));
    try testing.expectError(error.InvalidEntry, b.fake.putRun(.{ .config = config, .state = .unknown }));
    const run = try b.fake.putRun(.{ .config = config, .id = "r1", .state = .running });
    try testing.expectError(error.InvalidEntry, b.fake.putRun(.{ .config = config, .id = "r1" }));
    try testing.expectError(error.InvalidEntry, b.fake.putMessage(nobody, .{ .severity = .info }));
    try testing.expectError(error.InvalidEntry, b.fake.putMessage(run, .{ .severity = .unknown }));
    try b.fake.putMessage(run, .{ .severity = .warning, .text = "slow" });
    try testing.expectError(error.InvalidEntry, b.fake.setRunState(run, .unknown, null));
    try testing.expectError(error.InvalidEntry, b.fake.setRunState(nobody, .failed, null));
    var messages = try b.client.listMessages(run, .{ .severities = &.{.warning} });
    defer messages.deinit();
    try testing.expectEqualStrings("slow", messages.value.messages[0].text);
}

test "every allocation failure in the fake is OutOfMemory without leaks" {
    const Run = struct {
        fn calls(gpa: Allocator) !void {
            var clock: core.testing.FakeClock = .{};
            var fake: FakeDataTransfer = .init(gpa, clock.io(), probe);
            defer fake.deinit();
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            try seedProbe(&fake, arena.allocator());
            const ok = try fake.putConfig(.{ .location = "us", .scheduled_query = .{ .query = "SELECT 1" }, .manual_run = .succeeded });
            var token: core.StaticToken = .{ .token = "t" };
            var client = try Client.init(gpa, clock.io(), .{ .project_id = "extractctl", .token_provider = token.provider(), .transport = fake.transport(), .retry = .{ .max_attempts = 1 } });
            defer client.deinit();
            var locations = try client.listLocations(.{});
            locations.deinit();
            var configs = try client.listTransferConfigs("us", .{});
            configs.deinit();
            var config = try client.getTransferConfig(manual);
            config.deinit();
            var started = try client.startManualRun(ok, .{});
            defer started.deinit();
            var runs = try client.listRuns(ok, .{ .latest_only = true });
            runs.deinit();
            var messages = try client.listMessages(started.value.runs[0].name, .{});
            messages.deinit();
        }
    };
    try testing.checkAllAllocationFailures(core.testing.no_grow_allocator, Run.calls, .{});
}

// The slow property: the client against the fake, held to a model of
// production's runs as milestone 0 measured them.

const RunModel = struct {
    const Config = struct {
        name: []const u8,
        outcome: std.meta.Tag(FakeDataTransfer.ManualRun),
        disabled: bool,
        state: types.TransferState = .unknown,
    };
    const Run = struct {
        config: usize,
        name: []const u8,
        run_time: i96,
        state: types.TransferState,
    };
    configs: [3]Config,
    runs: std.ArrayList(Run) = .empty,
};

fn runsProperty(_: void, input: []const u8) !void {
    const gpa = @import("test_util.zig").propertyAllocator();
    var g: core.testing.ByteGen = .init(input);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var clock: core.testing.FakeClock = .{ .now_ns = 1_792_608_298 * std.time.ns_per_s };
    var fake: FakeDataTransfer = .init(gpa, clock.io(), .{});
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "t" };
    var client = try Client.init(gpa, clock.io(), .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
        .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 1 },
    });
    defer client.deinit();
    try fake.putLocation("us");

    var m: RunModel = .{ .configs = undefined };
    for (&m.configs) |*c| {
        const outcome = g.pick(std.meta.Tag(FakeDataTransfer.ManualRun), &.{ .pending, .succeeded, .failed });
        const disabled = g.intRange(u8, 0, 4) == 0;
        const name = try fake.putConfig(.{
            .location = "us",
            .destination_dataset_id = "d",
            .scheduled_query = .{ .query = "SELECT 1" },
            .disabled = disabled,
            .manual_run = switch (outcome) {
                .pending => .pending,
                .succeeded => .succeeded,
                .failed => .{ .failed = .{ .code = 3, .message = "division by zero: 1 / 0" } },
            },
        });
        c.* = .{ .name = try a.dupe(u8, name), .outcome = outcome, .disabled = disabled };
    }

    const steps = g.intRange(u8, 1, 24);
    for (0..steps) |_| {
        // Each step a second apart, so run times never tie.
        clock.now_ns += std.time.ns_per_s;
        fake.dropNext(0);
        fake.loseNext(0, 503);
        switch (g.intRange(u8, 0, 7)) {
            // A run now, now or for a past day, its answer maybe lost.
            0, 1 => {
                const k = g.intRange(usize, 0, 2);
                const c = &m.configs[k];
                const days_back = g.intRange(u8, 0, 3);
                const run_time = clock.now_ns - @as(i96, days_back) * std.time.ns_per_day;
                const lose = g.intRange(u8, 0, 5) == 0;
                if (lose) fake.loseNext(1, 503);
                const result = client.startManualRun(c.name, .{ .run_time = .{ .nanoseconds = run_time } });
                if (c.disabled) {
                    // Refused; a lost answer arrives as the loss.
                    try testing.expectError(if (lose) error.Unavailable else error.InvalidArgument, result);
                    continue;
                }
                const state: types.TransferState = switch (c.outcome) {
                    .pending => .pending,
                    .succeeded => .succeeded,
                    .failed => .failed,
                };
                var name: []const u8 = undefined;
                if (lose) {
                    // Sent once: the error comes back, and the run started.
                    try testing.expectError(error.Unavailable, result);
                    var page = try client.listRuns(c.name, .{});
                    defer page.deinit();
                    name = for (page.value.runs) |r| {
                        if (r.run_time.?.nanoseconds == run_time) break try a.dupe(u8, r.name);
                    } else return error.TestUnexpectedResult;
                } else {
                    var started = try result;
                    defer started.deinit();
                    try testing.expectEqual(types.TransferState.pending, started.value.runs[0].state);
                    try testing.expectEqual(run_time, started.value.runs[0].run_time.?.nanoseconds);
                    name = try a.dupe(u8, started.value.runs[0].name);
                }
                try m.runs.append(a, .{ .config = k, .name = name, .run_time = run_time, .state = state });
                c.state = state;
            },
            // The service moves a run on.
            2 => {
                if (m.runs.items.len == 0) continue;
                const r = &m.runs.items[g.intRange(usize, 0, m.runs.items.len - 1)];
                const to = g.pick(types.TransferState, &.{ .running, .succeeded, .failed, .cancelled });
                const result = fake.setRunState(r.name, to, if (to == .failed) .{ .code = 3, .message = "x" } else null);
                if (r.state.ended()) {
                    try testing.expectError(error.InvalidEntry, result);
                    continue;
                }
                try result;
                r.state = to;
                m.configs[r.config].state = to;
            },
            // A run read.
            3 => {
                if (m.runs.items.len == 0) continue;
                const r = m.runs.items[g.intRange(usize, 0, m.runs.items.len - 1)];
                var got = try client.getRun(r.name);
                defer got.deinit();
                try testing.expectEqual(r.state, got.value.state);
                try testing.expectEqual(r.state == .failed, got.value.@"error" != null);
            },
            // A config's runs, every way.
            4 => {
                const k = g.intRange(usize, 0, 2);
                const latest = g.boolean();
                const only_ended = g.boolean();
                const states: []const types.TransferState = if (only_ended) &.{ .succeeded, .failed, .cancelled } else &.{};
                var page = try client.listRuns(m.configs[k].name, .{ .latest_only = latest, .states = states });
                defer page.deinit();
                var want: std.ArrayList(RunModel.Run) = .empty;
                for (m.runs.items) |r| if (r.config == k and (!only_ended or r.state.ended())) try want.append(a, r);
                std.mem.sort(RunModel.Run, want.items, {}, struct {
                    fn newer(_: void, x: RunModel.Run, y: RunModel.Run) bool {
                        return x.run_time > y.run_time;
                    }
                }.newer);
                var expected: std.ArrayList(RunModel.Run) = .empty;
                var last_day: ?i96 = null;
                for (want.items) |r| {
                    const day = @divFloor(r.run_time, std.time.ns_per_day);
                    if (latest and last_day != null and last_day.? == day) continue;
                    last_day = day;
                    try expected.append(a, r);
                }
                try testing.expectEqual(expected.items.len, page.value.runs.len);
                for (expected.items, page.value.runs) |w, got| try testing.expectEqualStrings(w.name, got.name);
            },
            // A run's messages: a summary once it ended at once.
            5 => {
                if (m.runs.items.len == 0) continue;
                const r = m.runs.items[g.intRange(usize, 0, m.runs.items.len - 1)];
                var page = try client.listMessages(r.name, .{});
                defer page.deinit();
                const at_once = m.configs[r.config].outcome != .pending;
                try testing.expectEqual(@as(usize, if (at_once) 5 else 1), page.value.messages.len);
                if (at_once) try testing.expect(std.mem.startsWith(u8, page.value.messages[0].text, "Summary: "));
                var errors_only = try client.listMessages(r.name, .{ .severities = &.{.@"error"} });
                defer errors_only.deinit();
                try testing.expectEqual(@as(usize, if (m.configs[r.config].outcome == .failed) 1 else 0), errors_only.value.messages.len);
            },
            // A config read: its latest run's state.
            6 => {
                const k = g.intRange(usize, 0, 2);
                var got = try client.getTransferConfig(m.configs[k].name);
                defer got.deinit();
                try testing.expectEqual(m.configs[k].state, got.value.state);
                try testing.expectEqual(m.configs[k].disabled, got.value.disabled);
            },
            // Hours pass.
            7 => clock.now_ns += @as(i96, g.intRange(u8, 1, 30)) * std.time.ns_per_hour,
            else => unreachable,
        }
    }
    var started: usize = 0;
    for (m.runs.items) |_| started += 1;
    try testing.expectEqual(started, fake.runsStarted());
}

test "slow property: runs now, state moves, lists and lost answers against the fake, held to a model" {
    try core.testing.fuzzBytes({}, runsProperty, .{});
}
