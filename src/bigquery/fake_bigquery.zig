//! BigQuery in memory, for tests of code that browses datasets and runs
//! queries: behind `Client.Options.transport`, it answers the module's
//! reads, dry runs, queries, result pages and cancels as production
//! answered them when measured on 2026-10-21.
//!
//! - There is no SQL engine. A test gives each query text its `Answer`:
//!   the schema and rows of its results, the tables it reads, the bytes
//!   it processes, how many reads of it answer it unfinished, whether
//!   the cache serves it, or the refusal it meets. A query nobody
//!   answered is 501, "fake: no answer was given for this query text".
//! - Datasets, tables and jobs are put in by the test (`putDataset`,
//!   `putTable`, `putJob`) as a get answers them, any project's, so a
//!   test can hold `bigquery-public-data` beside its own.
//! - A dry run answers the bytes, the schema and the statement type, and
//!   makes no job. A run makes a job in the history, owned by
//!   `Options.user_email`: done at once, or running for the reads its
//!   answer's `polls` gives, each answering it unfinished with its job
//!   and nothing else. Billing follows production: nothing for a query
//!   that reads no table or one the cache answers, otherwise the bytes
//!   rounded up to a MiB, at least 10 MiB a table (measured for one
//!   table); a `maximumBytesBilled` below that refuses the run in
//!   production's words, billing nothing.
//! - A repeated `requestId` with the same text answers the first job,
//!   unfinished and without rows, as production answered one that had
//!   ended; with another text it makes a new job. A request id is
//!   remembered for 15 minutes.
//! - Results page by token, by `maxResults` and by `startIndex`;
//!   `maxResults` 0 answers the schema, the count and a token, no rows.
//!   A statement other than a SELECT (DDL, DML) answers no row count, as
//!   production's CREATE, INSERT and the like answered none.
//! - A cancel answers the job as it stands, running when it was; the
//!   job is then done with the error `stopped`, "Job execution was
//!   cancelled: User requested cancellation". A cancel of a done job
//!   answers it, no refusal.
//! - A job is found without a location when it is in the US or the EU,
//!   and is not found with another location's: "Not found: Job
//!   <project>:<location>.<id>". A query asked to run somewhere other
//!   than its tables is refused as production refused a US table queried
//!   in the EU.
//! - Refused in production's words: datasets, tables, projects and jobs
//!   nobody has, and an answer's own refusal (a syntax error, a runtime
//!   one, a quota). Faults a test asks for: refusals, dropped
//!   connections, and a lost answer.
//!
//! Not modelled, answered 501 with the reason: legacy SQL, `jobs.insert`
//! and every write to datasets and tables, `tabledata.list`, the results
//! of a job put in rather than run here or of one cancelled, and rows
//! without `formatOptions.useInt64Timestamp`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const core = @import("core");
const tp = core.transport;
const types = @import("types.zig");
const values = @import("values.zig");
const validate = @import("validate.zig");

pub const FakeBigQuery = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    options: Options,
    /// Strings and resources, freed with the fake.
    store: std.heap.ArenaAllocator,
    /// Project ids with anything in them, in the order put in.
    projects: std.StringArrayHashMapUnmanaged(void) = .empty,
    datasets: std.ArrayList(types.Dataset) = .empty,
    tables: std.ArrayList(types.Table) = .empty,
    jobs: std.ArrayList(*FakeJob) = .empty,
    answers: std.StringArrayHashMapUnmanaged(*const Stored) = .empty,
    request_ids: std.StringArrayHashMapUnmanaged(RequestId) = .empty,
    faults: [3]Fault = .{ .{}, .{}, .{} },
    calls: usize = 0,
    queries_run: usize = 0,

    const Fault = struct { n: usize = 0, status: u16 = 0 };
    const refuse = 0;
    const drop = 1;
    const lose = 2;

    pub const Options = struct {
        /// The project queries run in, by id.
        project_id: []const u8 = "my-project",
        /// Who runs the queries: their jobs are the caller's own, listed
        /// without `all_users`.
        user_email: []const u8 = "fake@my-project.iam.gserviceaccount.com",
        /// Where a query that reads no table runs when it names no
        /// location.
        default_location: []const u8 = "US",
    };

    pub const Reply = struct { status: u16, headers: []const tp.Header = &.{}, body: []const u8 };

    /// What a query text answers.
    pub const Answer = struct {
        /// The columns of its results.
        schema: []const types.Field = &.{},
        /// Its results, each fitting `schema` (`values.fits`).
        rows: []const values.Row = &.{},
        /// The tables it reads: none for a query of literals. They set
        /// what a run bills, and the first is named when the query is
        /// asked to run somewhere other than `location`.
        tables: []const types.TableRef = &.{},
        /// Where its tables are.
        location: []const u8 = "US",
        bytes_processed: u64 = 0,
        statement_type: []const u8 = "SELECT",
        num_dml_affected_rows: ?u64 = null,
        /// Reads of its results that answer it unfinished before it
        /// completes, `query`'s own included: 0 completes at once.
        polls: u32 = 0,
        /// Whether a run with the cache on is answered from the cache:
        /// nothing processed, nothing billed, `cacheHit` true.
        cached: bool = false,
        /// The refusal a dry run and a run of it meet instead.
        refusal: ?Refusal = null,
    };

    /// A refusal as BigQuery words one: its status, its
    /// `errors[].reason`, and its message.
    pub const Refusal = struct {
        status: u16 = 400,
        reason: []const u8 = "invalidQuery",
        message: []const u8,
    };

    const Stored = struct {
        text: []const u8,
        answer: Answer,
        /// Each row as the wire carries it.
        rows: []const []const u8,
    };

    const RequestId = struct { job: *FakeJob, text: []const u8, at: std.Io.Timestamp };

    const FakeJob = struct {
        job: types.Job,
        /// Null for a job put in rather than run here.
        results: ?*const Stored = null,
        polls_left: u32 = 0,
    };

    pub fn init(gpa: Allocator, io: std.Io, options: Options) FakeBigQuery {
        return .{ .gpa = gpa, .io = io, .options = options, .store = .init(gpa) };
    }

    pub fn deinit(f: *FakeBigQuery) void {
        f.projects.deinit(f.gpa);
        f.datasets.deinit(f.gpa);
        f.tables.deinit(f.gpa);
        f.jobs.deinit(f.gpa);
        f.answers.deinit(f.gpa);
        f.request_ids.deinit(f.gpa);
        f.store.deinit();
        f.* = undefined;
    }

    /// Goes into `Client.Options.transport`.
    pub fn transport(f: *FakeBigQuery) tp.Transport {
        return .{ .ptr = f, .vtable = &.{ .send = send } };
    }

    // Faults, each for the next `n` calls.

    /// Answers them with `status`, and changes nothing.
    pub fn refuseNext(f: *FakeBigQuery, n: usize, status: u16) void {
        f.setFault(refuse, .{ .n = n, .status = status });
    }

    /// Closes their connection before any answer.
    pub fn dropNext(f: *FakeBigQuery, n: usize) void {
        f.setFault(drop, .{ .n = n });
    }

    /// Serves them and answers `status` instead of what was read.
    pub fn loseNext(f: *FakeBigQuery, n: usize, status: u16) void {
        f.setFault(lose, .{ .n = n, .status = status });
    }

    fn setFault(f: *FakeBigQuery, slot: usize, fault: Fault) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.faults[slot] = fault;
    }

    fn takeFault(f: *FakeBigQuery, slot: usize) ?Fault {
        const fault = &f.faults[slot];
        if (fault.n == 0) return null;
        fault.n -= 1;
        return fault.*;
    }

    // What a test reads.

    /// Calls served, refusals included.
    pub fn callCount(f: *FakeBigQuery) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.calls;
    }

    /// Jobs in the history, put in and run here.
    pub fn jobCount(f: *FakeBigQuery) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.jobs.items.len;
    }

    /// Queries run here, a repeat answered from its request id not
    /// counted: what a test of "ran it once" asks.
    pub fn queryCount(f: *FakeBigQuery) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.queries_run;
    }

    // What a test puts in.

    pub const PutError = error{ OutOfMemory, InvalidEntry };

    /// A dataset, as a get answers it. An empty project is the fake's
    /// own. Its tables go in with `putTable`.
    pub fn putDataset(f: *FakeBigQuery, dataset: types.Dataset) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const project = f.projectOf(dataset.ref.project);
        if (!validate.isDatasetId(dataset.ref.dataset) or !core.names.isProjectId(project)) return error.InvalidEntry;
        if (f.findDataset(project, dataset.ref.dataset) != null) return error.InvalidEntry;
        const s = f.store.allocator();
        var copy = dataset;
        copy.ref = .{ .project = try s.dupe(u8, project), .dataset = try s.dupe(u8, dataset.ref.dataset) };
        copy.friendly_name = try s.dupe(u8, dataset.friendly_name);
        copy.description = try s.dupe(u8, dataset.description);
        copy.labels = try dupeLabels(s, dataset.labels);
        copy.location = try s.dupe(u8, if (dataset.location.len > 0) dataset.location else "US");
        copy.type = try s.dupe(u8, if (dataset.type.len > 0) dataset.type else "DEFAULT");
        try f.projects.put(f.gpa, copy.ref.project, {});
        try f.datasets.append(f.gpa, copy);
    }

    /// A table, as a get answers it, schema and all, in a dataset put in
    /// before. Its location is its dataset's.
    pub fn putTable(f: *FakeBigQuery, table: types.Table) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const project = f.projectOf(table.ref.project);
        const dataset = f.findDataset(project, table.ref.dataset) orelse return error.InvalidEntry;
        if (!validate.isTableId(table.ref.table)) return error.InvalidEntry;
        if (f.findTable(project, table.ref.dataset, table.ref.table) != null) return error.InvalidEntry;
        const s = f.store.allocator();
        var copy = table;
        copy.ref = .{ .project = dataset.ref.project, .dataset = dataset.ref.dataset, .table = try s.dupe(u8, table.ref.table) };
        copy.schema = try dupeFields(s, table.schema);
        if (table.time_partitioning) |p| copy.time_partitioning = .{ .type = try s.dupe(u8, p.type), .field = try s.dupe(u8, p.field), .expiration_ms = p.expiration_ms };
        if (table.range_partitioning) |p| copy.range_partitioning = .{ .field = try s.dupe(u8, p.field), .start = p.start, .end = p.end, .interval = p.interval };
        copy.clustering = try dupeStrings(s, table.clustering);
        if (table.view_query) |q| copy.view_query = try s.dupe(u8, q);
        if (table.materialized_view) |m| copy.materialized_view = .{ .query = try s.dupe(u8, m.query), .enable_refresh = m.enable_refresh, .refresh_interval_ms = m.refresh_interval_ms, .last_refresh_time = m.last_refresh_time };
        copy.friendly_name = try s.dupe(u8, table.friendly_name);
        copy.description = try s.dupe(u8, table.description);
        copy.labels = try dupeLabels(s, table.labels);
        copy.location = dataset.location;
        try f.tables.append(f.gpa, copy);
    }

    /// A job for the history, as a get answers it: one someone else ran,
    /// or one run before the test began. An empty project is the fake's
    /// own; an empty location, the US. Its results are not held, so
    /// reading them is 501.
    pub fn putJob(f: *FakeBigQuery, job: types.Job) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (!validate.isJobId(job.ref.id)) return error.InvalidEntry;
        const project = f.projectOf(job.ref.project);
        for (f.jobs.items) |held| if (std.mem.eql(u8, held.job.ref.id, job.ref.id) and std.mem.eql(u8, held.job.ref.project, project)) return error.InvalidEntry;
        const s = f.store.allocator();
        var copy = job;
        copy.ref = .{
            .project = try s.dupe(u8, project),
            .id = try s.dupe(u8, job.ref.id),
            .location = try s.dupe(u8, if (job.ref.location.len > 0) job.ref.location else "US"),
        };
        if (job.@"error") |e| copy.@"error" = try dupeError(s, e);
        const errs = try s.alloc(types.JobError, job.errors.len);
        for (job.errors, errs) |e, *o| o.* = try dupeError(s, e);
        copy.errors = errs;
        copy.query = try s.dupe(u8, job.query);
        copy.statement_type = try s.dupe(u8, job.statement_type);
        copy.user_email = try s.dupe(u8, job.user_email);
        copy.labels = try dupeLabels(s, job.labels);
        const held = try s.create(FakeJob);
        held.* = .{ .job = copy };
        try f.projects.put(f.gpa, copy.ref.project, {});
        try f.jobs.append(f.gpa, held);
    }

    /// What `text` answers from now on: given again, the new answer
    /// replaces the old for runs to come. Each row must fit the schema
    /// and be a value production could have sent.
    pub fn answer(f: *FakeBigQuery, text: []const u8, a: Answer) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (!validate.isQuery(text)) return error.InvalidEntry;
        const s = f.store.allocator();
        var scratch: std.heap.ArenaAllocator = .init(f.gpa);
        defer scratch.deinit();
        const rows = try s.alloc([]const u8, a.rows.len);
        for (a.rows, rows) |row, *out| {
            if (!values.fits(a.schema, row)) return error.InvalidEntry;
            var w: std.Io.Writer.Allocating = .init(s);
            values.writeRow(&w.writer, a.schema, row) catch return error.OutOfMemory;
            // Written, it must read back: a value no wire could carry
            // (a 13th month, an unknown decimal form) is refused here.
            const as_list = try std.mem.concat(scratch.allocator(), u8, &.{ "[", w.written(), "]" });
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), as_list, .{ .parse_numbers = false }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidEntry,
            };
            _ = values.decodeRows(scratch.allocator(), a.schema, parsed.array) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidResponse => return error.InvalidEntry,
            };
            out.* = w.written();
        }
        var copy = a;
        copy.schema = try dupeFields(s, a.schema);
        copy.rows = &.{};
        const tables = try s.alloc(types.TableRef, a.tables.len);
        for (a.tables, tables) |t, *o| o.* = .{
            .project = try s.dupe(u8, f.projectOf(t.project)),
            .dataset = try s.dupe(u8, t.dataset),
            .table = try s.dupe(u8, t.table),
        };
        copy.tables = tables;
        copy.location = try s.dupe(u8, a.location);
        copy.statement_type = try s.dupe(u8, a.statement_type);
        if (a.refusal) |r| copy.refusal = .{ .status = r.status, .reason = try s.dupe(u8, r.reason), .message = try s.dupe(u8, r.message) };
        const stored = try s.create(Stored);
        stored.* = .{ .text = try s.dupe(u8, text), .answer = copy, .rows = rows };
        try f.answers.put(f.gpa, stored.text, stored);
    }

    fn projectOf(f: *const FakeBigQuery, project: []const u8) []const u8 {
        return if (project.len > 0) project else f.options.project_id;
    }

    fn findDataset(f: *FakeBigQuery, project: []const u8, id: []const u8) ?*types.Dataset {
        for (f.datasets.items) |*d| if (std.mem.eql(u8, d.ref.project, project) and std.mem.eql(u8, d.ref.dataset, id)) return d;
        return null;
    }

    fn findTable(f: *FakeBigQuery, project: []const u8, dataset: []const u8, id: []const u8) ?*types.Table {
        for (f.tables.items) |*t| {
            if (std.mem.eql(u8, t.ref.project, project) and std.mem.eql(u8, t.ref.dataset, dataset) and std.mem.eql(u8, t.ref.table, id)) return t;
        }
        return null;
    }

    fn dupeLabels(s: Allocator, labels: []const types.Label) Allocator.Error![]const types.Label {
        const out = try s.alloc(types.Label, labels.len);
        for (labels, out) |l, *o| o.* = .{ .key = try s.dupe(u8, l.key), .value = try s.dupe(u8, l.value) };
        return out;
    }

    fn dupeStrings(s: Allocator, list: []const []const u8) Allocator.Error![]const []const u8 {
        const out = try s.alloc([]const u8, list.len);
        for (list, out) |text, *o| o.* = try s.dupe(u8, text);
        return out;
    }

    fn dupeFields(s: Allocator, fields: []const types.Field) Allocator.Error![]const types.Field {
        const out = try s.alloc(types.Field, fields.len);
        for (fields, out) |field, *o| {
            o.* = field;
            o.name = try s.dupe(u8, field.name);
            o.type_name = try s.dupe(u8, field.type_name);
            o.description = try s.dupe(u8, field.description);
            o.fields = try dupeFields(s, field.fields);
        }
        return out;
    }

    fn dupeError(s: Allocator, e: types.JobError) Allocator.Error!types.JobError {
        return .{ .reason = try s.dupe(u8, e.reason), .location = try s.dupe(u8, e.location), .message = try s.dupe(u8, e.message) };
    }

    // The transport.

    fn send(ptr: *anyopaque, req: tp.Request, arena: Allocator) tp.Error!tp.Response {
        const f: *FakeBigQuery = @ptrCast(@alignCast(ptr));
        const reply = try f.serve(req, arena);
        return .{ .status = reply.status, .headers = reply.headers, .body = reply.body };
    }

    /// One request, as `send` serves it: for a test that wants to send
    /// what no client would.
    pub fn serve(f: *FakeBigQuery, req: tp.Request, arena: Allocator) tp.Error!Reply {
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

    fn route(f: *FakeBigQuery, req: tp.Request, arena: Allocator, route_text: []const u8, query: []const u8) Allocator.Error!Reply {
        if (req.bearer == null) return fail(arena, 401, "UNAUTHENTICATED", "unauthorized", "Request is missing required authentication credential. Expected OAuth 2 access token, login cookie or other valid authentication credential. See https://developers.google.com/identity/sign-in/web/devconsole-project.");
        const target = try parseRoute(arena, route_text) orelse return notModelled(arena, "this path");
        const params = try parseParams(arena, query) orelse return fail(arena, 400, "INVALID_ARGUMENT", "invalid", "Invalid query string.");
        switch (req.method) {
            .GET => {},
            .POST => switch (target.kind) {
                .queries => return f.runQuery(arena, target.project, req.body orelse ""),
                .cancel => |id| return f.cancel(arena, target.project, id, params),
                else => return notModelled(arena, "a write other than a query or a cancel"),
            },
            else => return notModelled(arena, "anything but a read, a query or a cancel"),
        }
        switch (target.kind) {
            .datasets => return f.listDatasets(arena, target.project, params),
            .dataset => |id| {
                const d = f.findDataset(target.project, id) orelse return notFound(arena, try arena.print("Not found: Dataset {s}:{s}", .{ target.project, id }));
                return f.json(arena, d.*, writeDataset);
            },
            .tables => |dataset| return f.listTables(arena, target.project, dataset, params),
            .table => |t| {
                const table = f.findTable(target.project, t.dataset, t.id) orelse return notFound(arena, try arena.print("Not found: Table {s}:{s}.{s}", .{ target.project, t.dataset, t.id }));
                return f.json(arena, table.*, writeTable);
            },
            .jobs => return f.listJobs(arena, target.project, params),
            .job => |id| {
                const held = try f.findJob(arena, target.project, id, params) orelse return f.unknownJob(arena, target.project, id, params);
                var out: std.Io.Writer.Allocating = .init(arena);
                var jw: Stringify = .{ .writer = &out.writer };
                writeJob(&jw, held.job, .get) catch return error.OutOfMemory;
                return .{ .status = 200, .body = out.written() };
            },
            .results => |id| return f.results(arena, target.project, id, params),
            .queries, .cancel => return notModelled(arena, "a read of this path"),
        }
    }

    fn json(f: *FakeBigQuery, arena: Allocator, value: anytype, comptime write: fn (*Stringify, @TypeOf(value), Shape) Stringify.Error!void) Allocator.Error!Reply {
        _ = f;
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        write(&jw, value, .get) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    // The reads.

    fn listDatasets(f: *FakeBigQuery, arena: Allocator, project: []const u8, params: []const Param) Allocator.Error!Reply {
        if (!f.projects.contains(project) and !std.mem.eql(u8, project, f.options.project_id)) {
            return notFound(arena, try arena.print("Not found: Project {s}", .{project}));
        }
        const all = if (paramOf(params, "all")) |v| std.mem.eql(u8, v, "true") else false;
        const filter = paramOf(params, "filter") orelse "";
        var picked: std.ArrayList(types.Dataset) = .empty;
        for (f.datasets.items) |d| {
            if (!std.mem.eql(u8, d.ref.project, project)) continue;
            // An id starting with _ is hidden (BigQuery's rule).
            if (!all and std.mem.startsWith(u8, d.ref.dataset, "_")) continue;
            if (!labelsMatch(d.labels, filter)) continue;
            try picked.append(arena, d);
        }
        const window = pageOf(params, picked.items.len) orelse return pageRefusal(arena);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeDatasetPage(&jw, picked.items[window.from..window.to], window.next) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn listTables(f: *FakeBigQuery, arena: Allocator, project: []const u8, dataset: []const u8, params: []const Param) Allocator.Error!Reply {
        if (f.findDataset(project, dataset) == null) return notFound(arena, try arena.print("Not found: Dataset {s}:{s}", .{ project, dataset }));
        var picked: std.ArrayList(types.Table) = .empty;
        for (f.tables.items) |t| {
            if (std.mem.eql(u8, t.ref.project, project) and std.mem.eql(u8, t.ref.dataset, dataset)) try picked.append(arena, t);
        }
        const window = pageOf(params, picked.items.len) orelse return pageRefusal(arena);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeTablePage(&jw, picked.items[window.from..window.to], window.next, picked.items.len) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn listJobs(f: *FakeBigQuery, arena: Allocator, project: []const u8, params: []const Param) Allocator.Error!Reply {
        const all_users = if (paramOf(params, "allUsers")) |v| std.mem.eql(u8, v, "true") else false;
        const full = if (paramOf(params, "projection")) |v| std.ascii.eqlIgnoreCase(v, "full") else false;
        var states: [3]bool = .{ false, false, false };
        var any_state = false;
        for (params) |p| if (std.mem.eql(u8, p.name, "stateFilter")) {
            const state = types.JobState.fromWire(p.value);
            if (state == .unknown) return fail(arena, 400, "INVALID_ARGUMENT", "invalid", try arena.print("Invalid value for stateFilter: {s}", .{p.value}));
            states[@backingInt(state)] = true;
            any_state = true;
        };
        const min = if (paramOf(params, "minCreationTime")) |v| std.fmt.parseInt(i64, v, 10) catch return pageRefusal(arena) else null;
        const max = if (paramOf(params, "maxCreationTime")) |v| std.fmt.parseInt(i64, v, 10) catch return pageRefusal(arena) else null;
        var picked: std.ArrayList(types.Job) = .empty;
        for (f.jobs.items) |held| {
            const j = held.job;
            if (!std.mem.eql(u8, j.ref.project, project)) continue;
            if (!all_users and !std.mem.eql(u8, j.user_email, f.options.user_email)) continue;
            if (any_state and !states[@backingInt(j.state)]) continue;
            const created = millisOf(j.creation_time) orelse 0;
            if (min) |m| if (created < m) continue;
            if (max) |m| if (created > m) continue;
            try picked.append(arena, j);
        }
        // Newest first, as production lists them.
        std.mem.sort(types.Job, picked.items, {}, newerFirst);
        const window = pageOf(params, picked.items.len) orelse return pageRefusal(arena);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeJobPage(&jw, picked.items[window.from..window.to], window.next, if (full) .list_full else .list_minimal) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn newerFirst(_: void, a: types.Job, b: types.Job) bool {
        return (millisOf(a.creation_time) orelse 0) > (millisOf(b.creation_time) orelse 0);
    }

    /// The job by its id and the request's location: none given finds a
    /// US or EU job, as production found a US one; another location's
    /// job is not found.
    fn findJob(f: *FakeBigQuery, arena: Allocator, project: []const u8, id: []const u8, params: []const Param) Allocator.Error!?*FakeJob {
        _ = arena;
        const location = paramOf(params, "location");
        for (f.jobs.items) |held| {
            if (!std.mem.eql(u8, held.job.ref.project, project) or !std.mem.eql(u8, held.job.ref.id, id)) continue;
            if (location) |l| {
                if (!std.ascii.eqlIgnoreCase(l, held.job.ref.location)) return null;
            } else if (!std.ascii.eqlIgnoreCase(held.job.ref.location, "US") and !std.ascii.eqlIgnoreCase(held.job.ref.location, "EU")) {
                return null;
            }
            return held;
        }
        return null;
    }

    fn unknownJob(f: *FakeBigQuery, arena: Allocator, project: []const u8, id: []const u8, params: []const Param) Allocator.Error!Reply {
        _ = f;
        // As sent; none is the US, as production named it.
        const location = paramOf(params, "location") orelse "US";
        return notFound(arena, try arena.print("Not found: Job {s}:{s}.{s}", .{ project, location, id }));
    }

    // Queries.

    const Request = struct {
        text: []const u8,
        dry_run: bool,
        location: ?[]const u8,
        use_query_cache: bool,
        maximum_bytes_billed: ?u64,
        max_results: ?u64,
        request_id: ?[]const u8,
        int64_timestamps: bool,
        labels: []const types.Label,
    };

    fn parseRequest(arena: Allocator, body: []const u8) Allocator.Error!union(enum) { ok: Request, bad: []const u8 } {
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{ .parse_numbers = false }) catch return .{ .bad = "a body that is not JSON" };
        if (value != .object) return .{ .bad = "a body that is not an object" };
        const o = value.object;
        const text = o.get("query") orelse return .{ .bad = "a query without text" };
        if (text != .string) return .{ .bad = "a query without text" };
        const legacy = o.get("useLegacySql") orelse return .{ .bad = "legacy SQL, BigQuery's default when useLegacySql is left out" };
        if (legacy != .bool or legacy.bool) return .{ .bad = "legacy SQL" };
        var r: Request = .{
            .text = text.string,
            .dry_run = boolOf(o, "dryRun") orelse false,
            .location = if (o.get("location")) |l| (if (l == .string) l.string else null) else null,
            .use_query_cache = boolOf(o, "useQueryCache") orelse true,
            .maximum_bytes_billed = intOf(o, "maximumBytesBilled"),
            .max_results = intOf(o, "maxResults"),
            .request_id = if (o.get("requestId")) |id| (if (id == .string) id.string else null) else null,
            .int64_timestamps = false,
            .labels = &.{},
        };
        if (o.get("formatOptions")) |format| if (format == .object) {
            r.int64_timestamps = boolOf(format.object, "useInt64Timestamp") orelse false;
        };
        if (o.get("labels")) |labels| if (labels == .object) {
            const list = try arena.alloc(types.Label, labels.object.count());
            for (labels.object.keys(), labels.object.values(), list) |k, v, *l| {
                l.* = .{ .key = k, .value = if (v == .string) v.string else "" };
            }
            r.labels = list;
        };
        return .{ .ok = r };
    }

    fn boolOf(o: std.json.ObjectMap, name: []const u8) ?bool {
        const v = o.get(name) orelse return null;
        return if (v == .bool) v.bool else null;
    }

    /// An int64 as a JSON string, or a uint32 as a number.
    fn intOf(o: std.json.ObjectMap, name: []const u8) ?u64 {
        const v = o.get(name) orelse return null;
        const text = switch (v) {
            .string, .number_string => |s| s,
            else => return null,
        };
        return std.fmt.parseInt(u64, text, 10) catch null;
    }

    /// What a run of `a` bills: nothing from the cache or for literals;
    /// otherwise the bytes rounded up to a MiB, at least 10 MiB a table.
    fn billed(a: Answer, from_cache: bool) u64 {
        if (from_cache or a.tables.len == 0) return 0;
        const mib = 1024 * 1024;
        const rounded = std.math.divCeil(u64, a.bytes_processed, mib) catch unreachable;
        return @max(rounded *| mib, 10 * mib * @as(u64, a.tables.len));
    }

    fn runQuery(f: *FakeBigQuery, arena: Allocator, project: []const u8, body: []const u8) Allocator.Error!Reply {
        if (!std.mem.eql(u8, project, f.options.project_id)) return notModelled(arena, "a query billed to a project other than the fake's own");
        const r = switch (try parseRequest(arena, body)) {
            .ok => |r| r,
            .bad => |what| return notModelled(arena, what),
        };
        const stored = f.answers.get(r.text) orelse return fail(arena, 501, "UNIMPLEMENTED", "notImplemented", "fake: no answer was given for this query text");
        const a = stored.answer;
        if (a.refusal) |refused| return refuseWith(arena, refused);
        if (r.location) |location| if (a.tables.len > 0 and !std.ascii.eqlIgnoreCase(location, a.location)) {
            const t = a.tables[0];
            return fail(arena, 403, "PERMISSION_DENIED", "accessDenied", try arena.print("Access Denied: Table {s}:{s}.{s}: User does not have permission to query table {s}:{s}.{s}, or perhaps it does not exist.", .{ t.project, t.dataset, t.table, t.project, t.dataset, t.table }));
        };
        const from_cache = a.cached and r.use_query_cache;
        const bill = billed(a, from_cache);
        const now = std.Io.Clock.real.now(f.io);
        const location = if (a.tables.len > 0) a.location else r.location orelse f.options.default_location;

        if (r.dry_run) {
            var out: std.Io.Writer.Allocating = .init(arena);
            writeDryRun(&out.writer, f.options.project_id, stored, location, from_cache, bill, now) catch return error.OutOfMemory;
            return .{ .status = 200, .body = out.written() };
        }
        if (r.maximum_bytes_billed) |limit| if (bill > limit) {
            return fail(arena, 400, "INVALID_ARGUMENT", "bytesBilledLimitExceeded", try arena.print("Query exceeded limit for bytes billed: {d}. {d} or higher required.", .{ limit, bill }));
        };
        if (!r.int64_timestamps and stored.rows.len > 0) return notModelled(arena, "rows without formatOptions.useInt64Timestamp");

        // A request id seen within 15 minutes with the same text answers
        // the first job, unfinished and without rows (measured).
        if (r.request_id) |id| if (f.request_ids.get(id)) |seen| {
            const age_ms = seen.at.durationTo(now).toMilliseconds();
            if (age_ms <= 15 * std.time.ms_per_min and std.mem.eql(u8, seen.text, r.text)) {
                var out: std.Io.Writer.Allocating = .init(arena);
                writeUnfinished(&out.writer, seen.job.job, "bigquery#queryResponse") catch return error.OutOfMemory;
                return .{ .status = 200, .body = out.written() };
            }
        };

        const held = try f.newJob(r, stored, location, from_cache, bill, now);
        if (r.request_id) |id| {
            const s = f.store.allocator();
            try f.request_ids.put(f.gpa, try s.dupe(u8, id), .{ .job = held, .text = stored.text, .at = now });
        }
        return f.page(arena, held, .{ .first = true, .max_results = r.max_results });
    }

    fn newJob(f: *FakeBigQuery, r: Request, stored: *const Stored, location: []const u8, from_cache: bool, bill: u64, now: std.Io.Timestamp) Allocator.Error!*FakeJob {
        const s = f.store.allocator();
        var random: [21]u8 = undefined;
        f.io.random(&random);
        var id_buf: [32]u8 = undefined;
        const encoded = std.base64.url_safe_no_pad.Encoder.encode(&id_buf, &random);
        const a = stored.answer;
        const held = try s.create(FakeJob);
        held.* = .{
            .job = .{
                .ref = .{
                    .project = f.options.project_id,
                    .id = try std.fmt.allocPrint(s, "job_{s}", .{encoded}),
                    .location = try s.dupe(u8, location),
                },
                .type = .query,
                .state = if (a.polls > 0) .running else .done,
                .query = stored.text,
                .statement_type = a.statement_type,
                .total_bytes_processed = if (from_cache) 0 else a.bytes_processed,
                .total_bytes_billed = bill,
                .cache_hit = from_cache,
                .num_dml_affected_rows = a.num_dml_affected_rows,
                .creation_time = now,
                .start_time = now,
                .end_time = if (a.polls > 0) null else now,
                .user_email = f.options.user_email,
                .labels = try dupeLabels(s, r.labels),
            },
            .results = stored,
            .polls_left = a.polls,
        };
        try f.jobs.append(f.gpa, held);
        f.queries_run += 1;
        return held;
    }

    const PageAsk = struct {
        first: bool = false,
        max_results: ?u64 = null,
        start: usize = 0,
    };

    /// A read of `held`'s results: unfinished while its polls last, then
    /// the asked window of its rows.
    fn page(f: *FakeBigQuery, arena: Allocator, held: *FakeJob, ask: PageAsk) Allocator.Error!Reply {
        const kind = if (ask.first) "bigquery#queryResponse" else "bigquery#getQueryResultsResponse";
        if (held.polls_left > 0) {
            held.polls_left -= 1;
            var out: std.Io.Writer.Allocating = .init(arena);
            writeUnfinished(&out.writer, held.job, kind) catch return error.OutOfMemory;
            return .{ .status = 200, .body = out.written() };
        }
        if (held.job.state != .done) {
            held.job.state = .done;
            held.job.end_time = std.Io.Clock.real.now(f.io);
        }
        const stored = held.results.?;
        const total = stored.rows.len;
        if (ask.start > total) return fail(arena, 400, "INVALID_ARGUMENT", "invalid", "fake: a start past the last row");
        const size: usize = if (ask.max_results) |n| @intCast(@min(n, total)) else total;
        const to = @min(total, ask.start + size);
        // A page that stops short names where the next begins; one that
        // asked for no rows names the first (measured).
        const next: ?usize = if (to < total) to else null;
        var out: std.Io.Writer.Allocating = .init(arena);
        writePage(&out.writer, held.job, stored, ask.first, kind, stored.rows[ask.start..to], next) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn results(f: *FakeBigQuery, arena: Allocator, project: []const u8, id: []const u8, params: []const Param) Allocator.Error!Reply {
        const held = try f.findJob(arena, project, id, params) orelse return f.unknownJob(arena, project, id, params);
        if (held.results == null) return notModelled(arena, "the results of a job put in rather than run here");
        if (held.job.@"error" != null) return unmeasured(arena, "the results of a cancelled job");
        const int64 = if (paramOf(params, "formatOptions.useInt64Timestamp")) |v| std.mem.eql(u8, v, "true") else false;
        var ask: PageAsk = .{};
        if (paramOf(params, "maxResults")) |text| ask.max_results = std.fmt.parseInt(u64, text, 10) catch return pageRefusal(arena);
        if (!int64 and held.results.?.rows.len > 0 and (ask.max_results orelse 1) > 0) return notModelled(arena, "rows without formatOptions.useInt64Timestamp");
        const token = paramOf(params, "pageToken");
        const index = paramOf(params, "startIndex");
        if (token != null and index != null) return unmeasured(arena, "a page token and a start index together");
        if (token) |t| {
            if (!std.mem.startsWith(u8, t, "p")) return pageRefusal(arena);
            ask.start = std.fmt.parseInt(usize, t[1..], 10) catch return pageRefusal(arena);
        }
        if (index) |i| ask.start = std.fmt.parseInt(usize, i, 10) catch return pageRefusal(arena);
        return f.page(arena, held, ask);
    }

    fn cancel(f: *FakeBigQuery, arena: Allocator, project: []const u8, id: []const u8, params: []const Param) Allocator.Error!Reply {
        const held = try f.findJob(arena, project, id, params) orelse return f.unknownJob(arena, project, id, params);
        // Answered as it stands; then stopped, as production stopped one.
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeCancel(&jw, held.job) catch return error.OutOfMemory;
        if (held.job.state != .done) {
            const s = f.store.allocator();
            held.job.state = .done;
            held.job.end_time = std.Io.Clock.real.now(f.io);
            held.job.@"error" = .{ .reason = "stopped", .location = "", .message = try s.dupe(u8, "Job execution was cancelled: User requested cancellation") };
            held.polls_left = 0;
        }
        return .{ .status = 200, .body = out.written() };
    }

    // Writing what production writes.

    const Shape = enum { get, list_full, list_minimal };

    fn writeRef(jw: *Stringify, comptime fields: anytype) Stringify.Error!void {
        try jw.beginObject();
        inline for (fields) |pair| {
            try jw.objectField(pair[0]);
            try jw.write(pair[1]);
        }
        try jw.endObject();
    }

    fn writeMillis(jw: *Stringify, name: []const u8, t: ?std.Io.Timestamp) Stringify.Error!void {
        const ms = millisOf(t) orelse return;
        try jw.objectField(name);
        try jw.print("\"{d}\"", .{ms});
    }

    fn writeInt(jw: *Stringify, name: []const u8, n: anytype) Stringify.Error!void {
        const v = n orelse return;
        try jw.objectField(name);
        try jw.print("\"{d}\"", .{v});
    }

    fn writeLabels(jw: *Stringify, labels: []const types.Label) Stringify.Error!void {
        if (labels.len == 0) return;
        try jw.objectField("labels");
        try jw.beginObject();
        for (labels) |l| {
            try jw.objectField(l.key);
            try jw.write(l.value);
        }
        try jw.endObject();
    }

    fn writeString(jw: *Stringify, name: []const u8, text: []const u8) Stringify.Error!void {
        if (text.len == 0) return;
        try jw.objectField(name);
        try jw.write(text);
    }

    fn writeDataset(jw: *Stringify, d: types.Dataset, shape: Shape) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write("bigquery#dataset");
        try jw.objectField("id");
        try jw.print("\"{s}:{s}\"", .{ d.ref.project, d.ref.dataset });
        try jw.objectField("datasetReference");
        try jw.beginObject();
        try jw.objectField("datasetId");
        try jw.write(d.ref.dataset);
        try jw.objectField("projectId");
        try jw.write(d.ref.project);
        try jw.endObject();
        try writeString(jw, "friendlyName", d.friendly_name);
        if (shape == .get) try writeString(jw, "description", d.description);
        try writeLabels(jw, d.labels);
        if (shape == .get) {
            try writeInt(jw, "defaultTableExpirationMs", d.default_table_expiration_ms);
            try writeInt(jw, "defaultPartitionExpirationMs", d.default_partition_expiration_ms);
            try writeMillis(jw, "creationTime", d.creation_time);
            try writeMillis(jw, "lastModifiedTime", d.last_modified_time);
        }
        try writeString(jw, "location", d.location);
        try writeString(jw, "type", d.type);
        try jw.endObject();
    }

    fn writeDatasetPage(jw: *Stringify, datasets: []const types.Dataset, next: ?usize) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write("bigquery#datasetList");
        if (datasets.len > 0) {
            try jw.objectField("datasets");
            try jw.beginArray();
            for (datasets) |d| try writeDataset(jw, d, .list_full);
            try jw.endArray();
        }
        try writeToken(jw, next);
        try jw.endObject();
    }

    fn writeToken(jw: *Stringify, next: ?usize) Stringify.Error!void {
        const n = next orelse return;
        try jw.objectField("nextPageToken");
        try jw.print("\"p{d}\"", .{n});
    }

    fn fieldWire(f: types.Field) []const u8 {
        return switch (f.type) {
            // The legacy names, as production writes them (measured).
            .int64 => "INTEGER",
            .float64 => "FLOAT",
            .boolean => "BOOLEAN",
            .record => "RECORD",
            .string => "STRING",
            .bytes => "BYTES",
            .numeric => "NUMERIC",
            .bignumeric => "BIGNUMERIC",
            .timestamp => "TIMESTAMP",
            .date => "DATE",
            .time => "TIME",
            .datetime => "DATETIME",
            .geography => "GEOGRAPHY",
            .json => "JSON",
            .interval => "INTERVAL",
            .range => "RANGE",
            .unknown => f.type_name,
        };
    }

    fn writeFields(jw: *Stringify, fields: []const types.Field) Stringify.Error!void {
        try jw.beginArray();
        for (fields) |f| {
            try jw.beginObject();
            try jw.objectField("name");
            try jw.write(f.name);
            try jw.objectField("type");
            try jw.write(fieldWire(f));
            try jw.objectField("mode");
            try jw.write(switch (f.mode) {
                .nullable, .unknown => "NULLABLE",
                .required => "REQUIRED",
                .repeated => "REPEATED",
            });
            if (f.fields.len > 0) {
                try jw.objectField("fields");
                try writeFields(jw, f.fields);
            }
            if (f.range_element) |e| {
                try jw.objectField("rangeElementType");
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write(fieldWire(.{ .name = "", .type = e }));
                try jw.endObject();
            }
            try writeString(jw, "description", f.description);
            try writeInt(jw, "precision", f.precision);
            try writeInt(jw, "scale", f.scale);
            try writeInt(jw, "maxLength", f.max_length);
            try jw.endObject();
        }
        try jw.endArray();
    }

    fn writeSchema(jw: *Stringify, fields: []const types.Field) Stringify.Error!void {
        try jw.objectField("schema");
        try jw.beginObject();
        try jw.objectField("fields");
        try writeFields(jw, fields);
        try jw.endObject();
    }

    fn tableWire(t: types.TableType) []const u8 {
        return switch (t) {
            .table => "TABLE",
            .view => "VIEW",
            .materialized_view => "MATERIALIZED_VIEW",
            .external => "EXTERNAL",
            .snapshot => "SNAPSHOT",
            .unknown => "TABLE",
        };
    }

    fn writeTable(jw: *Stringify, t: types.Table, shape: Shape) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write("bigquery#table");
        try jw.objectField("id");
        try jw.print("\"{s}:{s}.{s}\"", .{ t.ref.project, t.ref.dataset, t.ref.table });
        try jw.objectField("tableReference");
        try jw.beginObject();
        try jw.objectField("projectId");
        try jw.write(t.ref.project);
        try jw.objectField("datasetId");
        try jw.write(t.ref.dataset);
        try jw.objectField("tableId");
        try jw.write(t.ref.table);
        try jw.endObject();
        try writeString(jw, "friendlyName", t.friendly_name);
        try writeLabels(jw, t.labels);
        try jw.objectField("type");
        try jw.write(tableWire(t.type));
        if (t.time_partitioning) |p| {
            try jw.objectField("timePartitioning");
            try jw.beginObject();
            try writeString(jw, "type", p.type);
            try writeString(jw, "field", p.field);
            try writeInt(jw, "expirationMs", p.expiration_ms);
            try jw.endObject();
        }
        if (t.range_partitioning) |p| {
            try jw.objectField("rangePartitioning");
            try jw.beginObject();
            try writeString(jw, "field", p.field);
            try jw.objectField("range");
            try jw.beginObject();
            try writeInt(jw, "start", @as(?i64, p.start));
            try writeInt(jw, "end", @as(?i64, p.end));
            try writeInt(jw, "interval", @as(?i64, p.interval));
            try jw.endObject();
            try jw.endObject();
        }
        if (t.clustering.len > 0) {
            try jw.objectField("clustering");
            try jw.beginObject();
            try jw.objectField("fields");
            try jw.write(t.clustering);
            try jw.endObject();
        }
        try writeMillis(jw, "creationTime", t.creation_time);
        try writeMillis(jw, "expirationTime", t.expiration_time);
        if (shape == .get) {
            try writeString(jw, "description", t.description);
            try writeSchema(jw, t.schema);
            try writeInt(jw, "numRows", t.num_rows);
            try writeInt(jw, "numBytes", t.num_bytes);
            try writeMillis(jw, "lastModifiedTime", t.last_modified_time);
            try writeString(jw, "location", t.location);
            if (t.require_partition_filter) {
                try jw.objectField("requirePartitionFilter");
                try jw.write(true);
            }
            if (t.view_query) |q| {
                try jw.objectField("view");
                try jw.beginObject();
                try jw.objectField("query");
                try jw.write(q);
                try jw.objectField("useLegacySql");
                try jw.write(t.view_uses_legacy_sql);
                try jw.endObject();
            }
            if (t.materialized_view) |m| {
                try jw.objectField("materializedView");
                try jw.beginObject();
                try jw.objectField("query");
                try jw.write(m.query);
                try jw.objectField("enableRefresh");
                try jw.write(m.enable_refresh);
                try writeInt(jw, "refreshIntervalMs", m.refresh_interval_ms);
                try writeMillis(jw, "lastRefreshTime", m.last_refresh_time);
                try jw.endObject();
            }
        }
        try jw.endObject();
    }

    fn writeTablePage(jw: *Stringify, tables: []const types.Table, next: ?usize, total: usize) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write("bigquery#tableList");
        if (tables.len > 0) {
            try jw.objectField("tables");
            try jw.beginArray();
            for (tables) |t| try writeTable(jw, t, .list_full);
            try jw.endArray();
        }
        try writeToken(jw, next);
        try jw.objectField("totalItems");
        try jw.write(total);
        try jw.endObject();
    }

    fn stateWire(state: types.JobState) []const u8 {
        return switch (state) {
            .pending => "PENDING",
            .running => "RUNNING",
            .done, .unknown => "DONE",
        };
    }

    fn jobTypeWire(t: types.JobType) []const u8 {
        return switch (t) {
            .query => "QUERY",
            .load => "LOAD",
            .extract => "EXTRACT",
            .copy => "COPY",
            .unknown => "UNKNOWN",
        };
    }

    fn writeJobError(jw: *Stringify, e: types.JobError) Stringify.Error!void {
        try jw.beginObject();
        try writeString(jw, "reason", e.reason);
        try writeString(jw, "location", e.location);
        try writeString(jw, "message", e.message);
        try jw.endObject();
    }

    fn writeJob(jw: *Stringify, j: types.Job, shape: Shape) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write("bigquery#job");
        try jw.objectField("id");
        try jw.print("\"{s}:{s}.{s}\"", .{ j.ref.project, j.ref.location, j.ref.id });
        try jw.objectField("jobReference");
        try jw.beginObject();
        try jw.objectField("projectId");
        try jw.write(j.ref.project);
        try jw.objectField("jobId");
        try jw.write(j.ref.id);
        try jw.objectField("location");
        try jw.write(j.ref.location);
        try jw.endObject();
        if (shape != .get) {
            // A list item carries its state and its error at its top.
            try jw.objectField("state");
            try jw.write(stateWire(j.state));
            if (j.@"error") |e| {
                try jw.objectField("errorResult");
                try writeJobError(jw, e);
            }
        }
        if (shape != .list_minimal) {
            try jw.objectField("configuration");
            try jw.beginObject();
            try jw.objectField("jobType");
            try jw.write(jobTypeWire(j.type));
            if (j.dry_run) {
                try jw.objectField("dryRun");
                try jw.write(true);
            }
            try writeLabels(jw, j.labels);
            if (j.type == .query) {
                try jw.objectField("query");
                try jw.beginObject();
                try jw.objectField("query");
                try jw.write(j.query);
                try jw.objectField("useLegacySql");
                try jw.write(false);
                try jw.endObject();
            }
            try jw.endObject();
        }
        try jw.objectField("status");
        try jw.beginObject();
        if (j.@"error") |e| {
            try jw.objectField("errorResult");
            try writeJobError(jw, e);
        }
        if (j.errors.len > 0 or j.@"error" != null) {
            try jw.objectField("errors");
            try jw.beginArray();
            if (j.errors.len > 0) {
                for (j.errors) |e| try writeJobError(jw, e);
            } else try writeJobError(jw, j.@"error".?);
            try jw.endArray();
        }
        try jw.objectField("state");
        try jw.write(stateWire(j.state));
        try jw.endObject();
        try jw.objectField("statistics");
        try jw.beginObject();
        try writeMillis(jw, "creationTime", j.creation_time);
        try writeMillis(jw, "startTime", j.start_time);
        try writeMillis(jw, "endTime", j.end_time);
        try writeInt(jw, "totalBytesProcessed", j.total_bytes_processed);
        if (j.type == .query) {
            try jw.objectField("query");
            try jw.beginObject();
            try writeInt(jw, "totalBytesProcessed", j.total_bytes_processed);
            try writeInt(jw, "totalBytesBilled", j.total_bytes_billed);
            if (j.cache_hit) |hit| {
                try jw.objectField("cacheHit");
                try jw.write(hit);
            }
            try writeString(jw, "statementType", j.statement_type);
            try writeInt(jw, "numDmlAffectedRows", j.num_dml_affected_rows);
            try jw.endObject();
        }
        try jw.endObject();
        try writeString(jw, "user_email", j.user_email);
        try jw.endObject();
    }

    fn writeJobPage(jw: *Stringify, jobs: []const types.Job, next: ?usize, shape: Shape) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write("bigquery#jobList");
        if (jobs.len > 0) {
            try jw.objectField("jobs");
            try jw.beginArray();
            for (jobs) |j| try writeJob(jw, j, shape);
            try jw.endArray();
        }
        try writeToken(jw, next);
        try jw.endObject();
    }

    fn writeCancel(jw: *Stringify, j: types.Job) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write("bigquery#jobCancelResponse");
        try jw.objectField("job");
        try writeJob(jw, j, .get);
        try jw.endObject();
    }

    fn writeDryRun(w: *std.Io.Writer, project: []const u8, stored: *const Stored, location: []const u8, from_cache: bool, bill: u64, now: std.Io.Timestamp) Stringify.Error!void {
        const a = stored.answer;
        var jw: Stringify = .{ .writer = w };
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write("bigquery#queryResponse");
        try writeSchema(&jw, a.schema);
        // A dry run's reference names no job (measured).
        try jw.objectField("jobReference");
        try jw.beginObject();
        try jw.objectField("projectId");
        try jw.write(project);
        try jw.objectField("location");
        try jw.write(location);
        try jw.endObject();
        // A dry run says what the query reads, cached or not.
        try writeInt(&jw, "totalBytesProcessed", @as(?u64, a.bytes_processed));
        try jw.objectField("jobComplete");
        try jw.write(true);
        try jw.objectField("cacheHit");
        try jw.write(from_cache);
        try writeInt(&jw, "totalBytesBilled", @as(?u64, if (from_cache) 0 else bill));
        try jw.objectField("location");
        try jw.write(location);
        try writeMillis(&jw, "creationTime", now);
        try writeMillis(&jw, "endTime", now);
        try writeString(&jw, "statementType", a.statement_type);
        try jw.endObject();
    }

    /// A job not finished, or a repeat's answer: its reference and
    /// nothing of its results (measured).
    fn writeUnfinished(w: *std.Io.Writer, j: types.Job, kind: []const u8) Stringify.Error!void {
        var jw: Stringify = .{ .writer = w };
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write(kind);
        try writeJobReference(&jw, j);
        try jw.objectField("jobComplete");
        try jw.write(false);
        try jw.objectField("queryId");
        try jw.write(j.ref.id);
        try jw.objectField("location");
        try jw.write(j.ref.location);
        try writeMillis(&jw, "creationTime", j.creation_time);
        try writeMillis(&jw, "startTime", j.start_time);
        try writeString(&jw, "statementType", j.statement_type);
        try jw.endObject();
    }

    /// Whether a statement's answer counts rows: not DDL's or DML's.
    fn answersRows(statement: []const u8) bool {
        for ([_][]const u8{ "CREATE_", "DROP_", "ALTER_" }) |prefix| if (std.mem.startsWith(u8, statement, prefix)) return false;
        for ([_][]const u8{ "TRUNCATE_TABLE", "INSERT", "UPDATE", "DELETE", "MERGE" }) |name| if (std.mem.eql(u8, statement, name)) return false;
        return true;
    }

    fn writeJobReference(jw: *Stringify, j: types.Job) Stringify.Error!void {
        try jw.objectField("jobReference");
        try jw.beginObject();
        try jw.objectField("projectId");
        try jw.write(j.ref.project);
        try jw.objectField("jobId");
        try jw.write(j.ref.id);
        try jw.objectField("location");
        try jw.write(j.ref.location);
        try jw.endObject();
    }

    fn writePage(w: *std.Io.Writer, j: types.Job, stored: *const Stored, first: bool, kind: []const u8, rows: []const []const u8, next: ?usize) Stringify.Error!void {
        var jw: Stringify = .{ .writer = w };
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write(kind);
        try writeSchema(&jw, stored.answer.schema);
        try writeJobReference(&jw, j);
        if (answersRows(stored.answer.statement_type)) try writeInt(&jw, "totalRows", @as(?u64, stored.rows.len));
        if (next) |n| {
            try jw.objectField("pageToken");
            try jw.print("\"p{d}\"", .{n});
        }
        if (rows.len > 0) {
            try jw.objectField("rows");
            try jw.beginArray();
            for (rows) |row| {
                try jw.beginWriteRaw();
                try jw.writer.writeAll(row);
                jw.endWriteRaw();
            }
            try jw.endArray();
        }
        try writeInt(&jw, "totalBytesProcessed", j.total_bytes_processed);
        try jw.objectField("jobComplete");
        try jw.write(true);
        if (j.cache_hit) |hit| {
            try jw.objectField("cacheHit");
            try jw.write(hit);
        }
        if (first) {
            try jw.objectField("queryId");
            try jw.write(j.ref.id);
            try writeInt(&jw, "totalBytesBilled", j.total_bytes_billed);
            try jw.objectField("location");
            try jw.write(j.ref.location);
            try writeString(&jw, "statementType", j.statement_type);
            try writeInt(&jw, "numDmlAffectedRows", j.num_dml_affected_rows);
        }
        try jw.endObject();
    }

    // Routes and parameters.

    const Route = struct {
        project: []const u8,
        kind: union(enum) {
            datasets,
            dataset: []const u8,
            tables: []const u8,
            table: struct { dataset: []const u8, id: []const u8 },
            jobs,
            job: []const u8,
            cancel: []const u8,
            queries,
            results: []const u8,
        },
    };

    fn pathOf(url: []const u8) []const u8 {
        const scheme = std.mem.indexOf(u8, url, "://") orelse return url;
        const rest = url[scheme + 3 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "/";
        return rest[slash..];
    }

    /// The path's segments, each decoded: ids travel percent-encoded.
    fn parseRoute(arena: Allocator, path: []const u8) Allocator.Error!?Route {
        const prefix = "/bigquery/v2/projects/";
        if (!std.mem.startsWith(u8, path, prefix)) return null;
        var segments: [6][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, path[prefix.len..], '/');
        while (it.next()) |segment| {
            if (n == segments.len or segment.len == 0) return null;
            segments[n] = std.Uri.percentDecodeInPlace(try arena.dupe(u8, segment));
            n += 1;
        }
        const s = segments[0..n];
        if (s.len < 2) return null;
        const project = s[0];
        const word = s[1];
        if (std.mem.eql(u8, word, "datasets")) return switch (s.len) {
            2 => .{ .project = project, .kind = .datasets },
            3 => .{ .project = project, .kind = .{ .dataset = s[2] } },
            4 => if (std.mem.eql(u8, s[3], "tables")) .{ .project = project, .kind = .{ .tables = s[2] } } else null,
            5 => if (std.mem.eql(u8, s[3], "tables")) .{ .project = project, .kind = .{ .table = .{ .dataset = s[2], .id = s[4] } } } else null,
            else => null,
        };
        if (std.mem.eql(u8, word, "jobs")) return switch (s.len) {
            2 => .{ .project = project, .kind = .jobs },
            3 => .{ .project = project, .kind = .{ .job = s[2] } },
            4 => if (std.mem.eql(u8, s[3], "cancel")) .{ .project = project, .kind = .{ .cancel = s[2] } } else null,
            else => null,
        };
        if (std.mem.eql(u8, word, "queries")) return switch (s.len) {
            2 => .{ .project = project, .kind = .queries },
            3 => .{ .project = project, .kind = .{ .results = s[2] } },
            else => null,
        };
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

    /// Whether `labels` match every term of a filter such as
    /// `labels.team:data labels.active`.
    fn labelsMatch(labels: []const types.Label, filter: []const u8) bool {
        var terms = std.mem.tokenizeScalar(u8, filter, ' ');
        while (terms.next()) |term| {
            if (!std.mem.startsWith(u8, term, "labels.")) return false;
            const rest = term["labels.".len..];
            const colon = std.mem.indexOfScalar(u8, rest, ':');
            const key = rest[0 .. colon orelse rest.len];
            const want = if (colon) |c| rest[c + 1 ..] else null;
            const found = for (labels) |l| {
                if (std.mem.eql(u8, l.key, key)) break l;
            } else return false;
            if (want) |v| if (!std.mem.eql(u8, found.value, v)) return false;
        }
        return true;
    }

    const Window = struct { from: usize, to: usize, next: ?usize };

    fn pageOf(params: []const Param, total: usize) ?Window {
        var size = total;
        if (paramOf(params, "maxResults")) |text| {
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

    fn millisOf(t: ?std.Io.Timestamp) ?i64 {
        const ts = t orelse return null;
        return @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_ms));
    }

    fn pageRefusal(arena: Allocator) Allocator.Error!Reply {
        return fail(arena, 400, "INVALID_ARGUMENT", "invalid", "fake: an invalid page token, page size or time");
    }

    /// BigQuery's error body: the code, the message, `errors[]` with its
    /// reason, and the status (measured).
    fn fail(arena: Allocator, code: u16, status: []const u8, reason: []const u8, message: []const u8) Allocator.Error!Reply {
        return .{ .status = code, .body = try Stringify.valueAlloc(arena, .{ .@"error" = .{
            .code = code,
            .message = message,
            .errors = .{.{ .message = message, .domain = "global", .reason = reason }},
            .status = status,
        } }, .{}) };
    }

    fn refuseWith(arena: Allocator, r: Refusal) Allocator.Error!Reply {
        return fail(arena, r.status, statusName(r.status), r.reason, r.message);
    }

    fn notFound(arena: Allocator, message: []const u8) Allocator.Error!Reply {
        return fail(arena, 404, "NOT_FOUND", "notFound", message);
    }

    fn notModelled(arena: Allocator, what: []const u8) Allocator.Error!Reply {
        return fail(arena, 501, "UNIMPLEMENTED", "notImplemented", try arena.print("fake: {s} is not modelled", .{what}));
    }

    fn unmeasured(arena: Allocator, what: []const u8) Allocator.Error!Reply {
        return fail(arena, 501, "UNIMPLEMENTED", "notImplemented", try arena.print("fake: production's answer to {s} was not measured", .{what}));
    }

    fn statusName(status: u16) []const u8 {
        return switch (status) {
            400 => "INVALID_ARGUMENT",
            401 => "UNAUTHENTICATED",
            403 => "PERMISSION_DENIED",
            404 => "NOT_FOUND",
            409 => "ALREADY_EXISTS",
            429 => "RESOURCE_EXHAUSTED",
            500 => "INTERNAL",
            503 => "UNAVAILABLE",
            504 => "DEADLINE_EXCEEDED",
            else => "UNKNOWN",
        };
    }

    fn refusal(arena: Allocator, status: u16) Allocator.Error!Reply {
        return fail(arena, status, statusName(status), "fake", "fake: refused as the test asked");
    }
};

// Tests, held to what production answered in milestone 0.

const testing = std.testing;
const codec = @import("codec.zig");
const production = @import("production_bodies.zig");
const Client = @import("Client.zig");

const Bench = struct {
    clock: core.testing.FakeClock,
    fake: FakeBigQuery,
    token: core.StaticToken,
    diag: core.Diagnostics,
    client: Client,

    fn init(b: *Bench, options: FakeBigQuery.Options) !void {
        b.* = .{ .clock = .{ .now_ns = 1_792_597_000 * std.time.ns_per_s }, .fake = undefined, .token = .{ .token = "t" }, .diag = .{}, .client = undefined };
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

    fn raw(b: *Bench, arena: Allocator, method: tp.Method, path: []const u8, body: ?[]const u8) !FakeBigQuery.Reply {
        return b.fake.serve(.{ .method = method, .url = path, .bearer = "t", .body = body }, arena);
    }
};

/// The probe's dataset, its four tables and the public samples, as
/// production answered their gets.
fn seedProbe(fake: *FakeBigQuery, a: Allocator) !void {
    try fake.putDataset(try codec.decodeDataset(a, a, production.dataset_public));
    try fake.putTable(try codec.decodeTable(a, a, production.table_shakespeare));
    try fake.putDataset(try codec.decodeDataset(a, a, production.dataset_ours));
    // In the order production lists them.
    try fake.putTable(try codec.decodeTable(a, a, production.table_events));
    try fake.putTable(try codec.decodeTable(a, a, production.table_view));
    try fake.putTable(try codec.decodeTable(a, a, production.table_materialized_view));
    try fake.putTable(try codec.decodeTable(a, a, production.table_typed));
}

const hamlet = "SELECT word, word_count FROM `bigquery-public-data.samples.shakespeare` WHERE corpus = 'hamlet' ORDER BY word_count DESC LIMIT 5";
const shakespeare: types.TableRef = .{ .project = "bigquery-public-data", .dataset = "samples", .table = "shakespeare" };

/// Hamlet's five words as production answered them, read from the cache
/// as milestone 0's run was.
fn answerHamlet(fake: *FakeBigQuery, a: Allocator, cached: bool) !void {
    const page = try codec.decodeQueryPage(a, a, production.query_run);
    try fake.answer(hamlet, .{
        .schema = page.schema,
        .rows = page.rows,
        .tables = &.{shakespeare},
        .bytes_processed = 5_114_816,
        .cached = cached,
    });
}

test "gets answer as production did, decoded field for field" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "extractctl" });
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try seedProbe(&b.fake, a);
    const c = &b.client;

    var public = try c.getDataset(.{ .project = "bigquery-public-data", .dataset = "samples" });
    defer public.deinit();
    try testing.expectEqualDeep(try codec.decodeDataset(a, a, production.dataset_public), public.value);
    var ours = try c.getDataset(.{ .dataset = "zigps_9cb674" });
    defer ours.deinit();
    try testing.expectEqualDeep(try codec.decodeDataset(a, a, production.dataset_ours), ours.value);
    inline for (.{ production.table_shakespeare, production.table_typed, production.table_events, production.table_view, production.table_materialized_view }) |body| {
        const want = try codec.decodeTable(a, a, body);
        var got = try c.getTable(want.ref);
        defer got.deinit();
        try testing.expectEqualDeep(want, got.value);
    }
}

test "lists answer as production did: datasets and tables, a list's fields only" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "extractctl" });
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try seedProbe(&b.fake, a);
    const c = &b.client;

    var datasets = try c.listDatasets(.{});
    defer datasets.deinit();
    try testing.expectEqualDeep(try codec.decodeDatasetPage(a, a, production.datasets_page), datasets.value);
    var tables = try c.listTables(.{ .dataset = "zigps_9cb674" }, .{});
    defer tables.deinit();
    const want = try codec.decodeTablePage(a, a, production.tables_page);
    try testing.expectEqual(want.tables.len, tables.value.tables.len);
    for (want.tables, tables.value.tables) |w, g| try testing.expectEqualDeep(w, g);

    // Paged by the size asked.
    var first = try c.listTables(.{ .dataset = "zigps_9cb674" }, .{ .page_size = 3 });
    defer first.deinit();
    try testing.expectEqual(3, first.value.tables.len);
    try testing.expectEqual(4, first.value.total_items.?);
    var rest = try c.listTables(.{ .dataset = "zigps_9cb674" }, .{ .page_size = 3, .page_token = first.value.next_page_token.? });
    defer rest.deinit();
    try testing.expectEqualStrings("typed", rest.value.tables[0].ref.table);
    try testing.expectEqual(null, rest.value.next_page_token);
}

test "datasets: hidden ones with all, labels by filter, another project's" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putDataset(.{ .ref = .{ .dataset = "sales" }, .labels = &.{ .{ .key = "team", .value = "data" }, .{ .key = "active", .value = "" } } });
    try b.fake.putDataset(.{ .ref = .{ .dataset = "_scratch" } });
    try b.fake.putDataset(.{ .ref = .{ .dataset = "ops" }, .labels = &.{.{ .key = "team", .value = "ops" }} });
    try b.fake.putDataset(.{ .ref = .{ .project = "bigquery-public-data", .dataset = "samples" } });
    const c = &b.client;
    const Case = struct { types.ListDatasetsOptions, []const []const u8 };
    for ([_]Case{
        .{ .{}, &.{ "sales", "ops" } },
        .{ .{ .all = true }, &.{ "sales", "_scratch", "ops" } },
        .{ .{ .label_filter = "labels.team:data" }, &.{"sales"} },
        .{ .{ .label_filter = "labels.team" }, &.{ "sales", "ops" } },
        .{ .{ .label_filter = "labels.team:data labels.active" }, &.{"sales"} },
        .{ .{ .label_filter = "labels.team:ops labels.active" }, &.{} },
        .{ .{ .project = "bigquery-public-data" }, &.{"samples"} },
    }) |case| {
        var page = try c.listDatasets(case[0]);
        defer page.deinit();
        try testing.expectEqual(case[1].len, page.value.datasets.len);
        for (case[1], page.value.datasets) |id, d| try testing.expectEqualStrings(id, d.ref.dataset);
    }
}

test "not found, in production's words" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "extractctl" });
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try seedProbe(&b.fake, a);
    try b.fake.putJob(try codec.decodeJob(a, a, production.job_cancelled));
    const c = &b.client;
    const words = struct {
        fn of(arena_: Allocator, body: []const u8) ![]const u8 {
            const v = try std.json.parseFromSliceLeaky(std.json.Value, arena_, body, .{});
            return v.object.get("error").?.object.get("message").?.string;
        }
    };
    try testing.expectError(error.NotFound, c.getDataset(.{ .dataset = "zigps_nobody" }));
    try testing.expectEqualStrings(try words.of(a, production.dataset_unknown), b.diag.message());
    try testing.expectError(error.NotFound, c.getTable(.{ .project = "bigquery-public-data", .dataset = "samples", .table = "zigps_nobody" }));
    try testing.expectEqualStrings(try words.of(a, production.table_unknown), b.diag.message());
    try testing.expectError(error.NotFound, c.listDatasets(.{ .project = "zigps-not-a-project-x" }));
    try testing.expectEqualStrings(try words.of(a, production.project_unknown), b.diag.message());
    try testing.expectError(error.NotFound, c.getJob(.{ .id = "zigps_nobody" }));
    try testing.expectEqualStrings(try words.of(a, production.job_unknown), b.diag.message());
    try testing.expectError(error.NotFound, c.getJob(.{ .id = "job_uJJN89pQ9cqYnDKc4Z_VpBpHsSqC", .location = "EU" }));
    try testing.expectEqualStrings(try words.of(a, production.job_wrong_location), b.diag.message());
    try testing.expectError(error.NotFound, c.listTables(.{ .dataset = "zigps_nobody" }, .{}));
    // The US job found without its location, as production found it.
    var job = try c.getJob(.{ .id = "job_uJJN89pQ9cqYnDKc4Z_VpBpHsSqC" });
    defer job.deinit();
    try testing.expectEqualDeep(try codec.decodeJob(a, a, production.job_cancelled), job.value);
}

test "a query's answers: dry run, run, the cache, its limit, its location, as production answered" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "extractctl" });
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try answerHamlet(&b.fake, a, true);
    const c = &b.client;

    // Production's dry run was served from the cache.
    var dry = try c.dryRun(.{ .query = hamlet });
    defer dry.deinit();
    try testing.expectEqualDeep(try codec.decodeDryRun(a, a, production.query_dry_run), dry.value);
    try testing.expectEqual(0, b.fake.jobCount());

    var run = try c.query(.{ .query = hamlet, .maximum_bytes_billed = 100_000_000 });
    defer run.deinit();
    const want = try codec.decodeQueryPage(a, a, production.query_run);
    try testing.expectEqualDeep(want.schema, run.value.schema);
    try testing.expectEqualDeep(want.rows, run.value.rows);
    try testing.expectEqual(want.total_rows, run.value.total_rows);
    try testing.expectEqual(want.total_bytes_processed, run.value.total_bytes_processed);
    try testing.expectEqual(want.total_bytes_billed, run.value.total_bytes_billed);
    try testing.expectEqual(want.cache_hit, run.value.cache_hit);
    try testing.expectEqualStrings(want.statement_type, run.value.statement_type);
    try testing.expectEqualStrings("US", run.value.job.?.location);
    try testing.expectEqual(1, b.fake.jobCount());

    // Without the cache: the 10 MiB minimum, and the limit below it.
    var fresh = try c.query(.{ .query = hamlet, .use_query_cache = false });
    defer fresh.deinit();
    try testing.expectEqual(10_485_760, fresh.value.total_bytes_billed.?);
    try testing.expectEqual(5_114_816, fresh.value.total_bytes_processed.?);
    try testing.expectError(error.BytesBilledLimitExceeded, c.query(.{ .query = hamlet, .use_query_cache = false, .maximum_bytes_billed = 1000 }));

    try testing.expectEqualStrings("Query exceeded limit for bytes billed: 1000. 10485760 or higher required.", b.diag.message());
    // From the cache the limit is no bar: nothing is billed.
    var cached = try c.query(.{ .query = hamlet, .maximum_bytes_billed = 1000 });
    cached.deinit();
    try testing.expectError(error.PermissionDenied, c.query(.{ .query = hamlet, .location = "EU" }));
    try testing.expectEqualStrings("Access Denied: Table bigquery-public-data:samples.shakespeare: User does not have permission to query table bigquery-public-data:samples.shakespeare, or perhaps it does not exist.", b.diag.message());
    // A refused query makes no job.
    try testing.expectEqual(3, b.fake.jobCount());
    try testing.expectEqual(3, b.fake.queryCount());
    // A limit the bill meets exactly is no bar.
    var exact = try c.query(.{ .query = hamlet, .use_query_cache = false, .maximum_bytes_billed = 10_485_760 });
    exact.deinit();
}

test "billing: the bytes rounded up to a MiB, at least 10 MiB a table" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    const mib = 1024 * 1024;
    const Case = struct { u64, usize, u64 };
    for ([_]Case{
        .{ 0, 1, 10 * mib },
        .{ 20 * mib + 1, 1, 21 * mib },
        .{ 20 * mib, 1, 20 * mib },
        .{ 5 * mib, 2, 20 * mib },
        .{ 5 * mib, 0, 0 },
    }, 0..) |case, i| {
        var text_buf: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&text_buf, "SELECT {d}", .{i});
        const tables = [_]types.TableRef{ .{ .dataset = "d", .table = "a" }, .{ .dataset = "d", .table = "b" } };
        try b.fake.answer(text, .{ .tables = tables[0..case[1]], .bytes_processed = case[0] });
        var page = try b.client.query(.{ .query = text });
        defer page.deinit();
        try testing.expectEqual(case[2], page.value.total_bytes_billed.?);
    }
}

test "every type, from milestone 0's row, written back as production wrote it" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "extractctl" });
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const want = try codec.decodeQueryPage(a, a, production.query_every_type);
    try b.fake.answer("SELECT every type", .{ .schema = want.schema, .rows = want.rows });
    var got = try b.client.query(.{ .query = "SELECT every type" });
    defer got.deinit();
    try testing.expectEqualDeep(want.schema, got.value.schema);
    try testing.expectEqual(want.rows.len, got.value.rows.len);
    for (want.rows[0].cells, got.value.rows[0].cells) |w, g| {
        // NaN is not equal to itself; its text is.
        try testing.expectEqualStrings(w.text, g.text);
        if (w.value == .float64 and std.math.isNan(w.value.float64)) continue;
        try testing.expectEqualDeep(w.value, g.value);
    }
    // Literals bill nothing.
    try testing.expectEqual(0, got.value.total_bytes_billed.?);
    try testing.expectEqual(1, got.value.total_rows.?);

    // DML and DDL answer no row count (measured).
    try b.fake.answer("INSERT t (n) VALUES (1), (2)", .{ .statement_type = "INSERT", .num_dml_affected_rows = 2 });
    var insert = try b.client.query(.{ .query = "INSERT t (n) VALUES (1), (2)" });
    defer insert.deinit();
    try testing.expectEqual(null, insert.value.total_rows);
    try testing.expectEqual(2, insert.value.num_dml_affected_rows.?);
    try testing.expectEqualStrings("INSERT", insert.value.statement_type);
    try b.fake.answer("CREATE TABLE t (n INT64)", .{ .statement_type = "CREATE_TABLE" });
    var create = try b.client.query(.{ .query = "CREATE TABLE t (n INT64)" });
    defer create.deinit();
    try testing.expectEqual(null, create.value.total_rows);
    // A statement type left out counts its rows.
    try b.fake.answer("SELECT 2", .{ .statement_type = "" });
    var unnamed = try b.client.query(.{ .query = "SELECT 2" });
    defer unnamed.deinit();
    try testing.expectEqual(0, unnamed.value.total_rows.?);
}

test "a job that runs a while: unfinished reads, then pages by size, token and index" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = try a.alloc(values.Row, 25);
    for (rows, 0..) |*row, i| {
        const cells = try a.alloc(values.Cell, 1);
        cells[0] = .{ .value = .{ .int64 = @intCast(i) } };
        row.* = .{ .cells = cells };
    }
    try b.fake.answer("SELECT n", .{ .schema = &.{.{ .name = "n", .type = .int64 }}, .rows = rows, .polls = 2 });
    const c = &b.client;

    var first = try c.query(.{ .query = "SELECT n" });
    defer first.deinit();
    try testing.expect(!first.value.complete);
    try testing.expectEqual(0, first.value.schema.len);
    const job = first.value.job.?;
    var running = try c.getJob(job);
    defer running.deinit();
    try testing.expectEqual(types.JobState.running, running.value.state);
    try testing.expectEqual(null, running.value.end_time);
    var again = try c.getQueryResults(job, .{});
    defer again.deinit();
    try testing.expect(!again.value.complete);
    // Waited out without rows: the schema, the count and a token.
    var wait = try c.getQueryResults(job, .{ .page_size = 0 });
    defer wait.deinit();
    try testing.expect(wait.value.complete);
    try testing.expectEqual(0, wait.value.rows.len);
    try testing.expectEqual(25, wait.value.total_rows.?);
    try testing.expect(wait.value.page_token != null);
    var done = try c.getJob(job);
    defer done.deinit();
    try testing.expect(done.value.succeeded());

    var token: ?[]const u8 = wait.value.page_token;
    var seen: usize = 0;
    var pages: [3]types.Owned(types.QueryPage) = undefined;
    var n: usize = 0;
    defer for (pages[0..n]) |*p| p.deinit();
    while (token) |t| {
        pages[n] = try c.getQueryResults(job, .{ .page_token = t, .page_size = 10 });
        for (pages[n].value.rows) |row| {
            try testing.expectEqual(@as(i64, @intCast(seen)), row.cells[0].value.int64);
            seen += 1;
        }
        token = pages[n].value.page_token;
        n += 1;
    }
    try testing.expectEqual(25, seen);
    try testing.expectEqual(3, n);
    var tail = try c.getQueryResults(job, .{ .start_index = 20 });
    defer tail.deinit();
    try testing.expectEqual(5, tail.value.rows.len);
    try testing.expectEqual(20, tail.value.rows[0].cells[0].value.int64);
}

test "a repeated request id answers the first job, unfinished; another text, a new job" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.answer("SELECT 1", .{ .schema = &.{.{ .name = "f0_", .type = .int64 }}, .rows = &.{.{ .cells = &.{.{ .value = .{ .int64 = 1 } }} }} });
    try b.fake.answer("SELECT 2", .{ .schema = &.{.{ .name = "f0_", .type = .int64 }}, .rows = &.{.{ .cells = &.{.{ .value = .{ .int64 = 2 } }} }} });
    const c = &b.client;
    var first = try c.query(.{ .query = "SELECT 1", .request_id = "zigps-rid" });
    defer first.deinit();
    try testing.expect(first.value.complete);
    var repeat = try c.query(.{ .query = "SELECT 1", .request_id = "zigps-rid" });
    defer repeat.deinit();
    try testing.expect(!repeat.value.complete);
    try testing.expectEqualStrings(first.value.job.?.id, repeat.value.job.?.id);
    try testing.expectEqual(1, b.fake.queryCount());
    // The rows are there to read.
    var read = try c.getQueryResults(repeat.value.job.?, .{});
    defer read.deinit();
    try testing.expectEqual(1, read.value.rows[0].cells[0].value.int64);
    var other = try c.query(.{ .query = "SELECT 2", .request_id = "zigps-rid" });
    defer other.deinit();
    try testing.expect(!std.mem.eql(u8, first.value.job.?.id, other.value.job.?.id));
    try testing.expectEqual(2, b.fake.queryCount());
    // Forgotten after 15 minutes.
    b.clock.now_ns += 16 * std.time.ns_per_min;
    var later = try c.query(.{ .query = "SELECT 1", .request_id = "zigps-rid" });
    defer later.deinit();
    try testing.expect(later.value.complete);
    try testing.expectEqual(3, b.fake.queryCount());
}

test "a query whose answer is lost is retried, and the repeat answers its first job" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.answer("SELECT 1", .{ .schema = &.{.{ .name = "f0_", .type = .int64 }}, .rows = &.{.{ .cells = &.{.{ .value = .{ .int64 = 1 } }} }} });
    const c = &b.client;
    b.fake.loseNext(1, 503);
    var page = try c.query(.{ .query = "SELECT 1" });
    defer page.deinit();
    // Run once, answered as production answers a repeat.
    try testing.expectEqual(1, b.fake.queryCount());
    try testing.expect(!page.value.complete);
    var read = try c.getQueryResults(page.value.job.?, .{});
    defer read.deinit();
    try testing.expect(read.value.complete);
    // A dropped connection and a refusal are retried as well.
    b.fake.dropNext(1);
    b.fake.refuseNext(1, 503);
    var list = try c.listJobs(.{});
    defer list.deinit();
    try testing.expectEqual(1, list.value.jobs.len);
    try testing.expectEqual(6, b.fake.callCount());
}

test "a cancel answers the job running, then it is done, stopped; a done job's cancel is no refusal" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.answer("SELECT slow", .{ .schema = &.{.{ .name = "n", .type = .int64 }}, .polls = 5 });
    const c = &b.client;
    var started = try c.query(.{ .query = "SELECT slow" });
    defer started.deinit();
    const job = started.value.job.?;
    var cancelled = try c.cancelJob(job);
    defer cancelled.deinit();
    try testing.expectEqual(types.JobState.running, cancelled.value.state);
    try testing.expectEqual(null, cancelled.value.@"error");
    var after = try c.getJob(job);
    defer after.deinit();
    try testing.expect(after.value.failed());
    try testing.expectEqualStrings("stopped", after.value.@"error".?.reason);
    try testing.expectEqualStrings("Job execution was cancelled: User requested cancellation", after.value.@"error".?.message);
    var again = try c.cancelJob(job);
    defer again.deinit();
    try testing.expect(again.value.failed());
    try testing.expectError(error.Unimplemented, c.getQueryResults(job, .{}));
    try testing.expectEqualStrings("fake: production's answer to the results of a cancelled job was not measured", b.diag.message());
}

test "the history: one's own, everyone's, by state and time, newest first" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    const at = struct {
        fn ms(n: i64) std.Io.Timestamp {
            return .{ .nanoseconds = @as(i96, n) * std.time.ns_per_ms };
        }
    }.ms;
    try b.fake.putJob(.{ .ref = .{ .id = "job_old" }, .type = .query, .state = .done, .query = "SELECT 0", .creation_time = at(1_000), .user_email = "fake@my-project.iam.gserviceaccount.com" });
    try b.fake.putJob(.{ .ref = .{ .id = "job_theirs" }, .type = .load, .state = .running, .creation_time = at(3_000), .user_email = "someone@example.com" });
    try b.fake.putJob(.{ .ref = .{ .id = "job_eu", .location = "EU" }, .type = .query, .state = .pending, .query = "SELECT 1", .creation_time = at(2_000), .user_email = "fake@my-project.iam.gserviceaccount.com" });
    const c = &b.client;
    const Case = struct { types.ListJobsOptions, []const []const u8 };
    for ([_]Case{
        .{ .{}, &.{ "job_eu", "job_old" } },
        .{ .{ .all_users = true }, &.{ "job_theirs", "job_eu", "job_old" } },
        .{ .{ .all_users = true, .states = &.{ .running, .pending } }, &.{ "job_theirs", "job_eu" } },
        .{ .{ .all_users = true, .min_creation_time = at(2_000) }, &.{ "job_theirs", "job_eu" } },
        .{ .{ .all_users = true, .max_creation_time = at(2_000) }, &.{ "job_eu", "job_old" } },
        .{ .{ .all_users = true, .page_size = 1 }, &.{"job_theirs"} },
    }) |case| {
        var page = try c.listJobs(case[0]);
        defer page.deinit();
        try testing.expectEqual(case[1].len, page.value.jobs.len);
        for (case[1], page.value.jobs) |id, j| try testing.expectEqualStrings(id, j.ref.id);
    }
    var eu = try c.getJob(.{ .id = "job_eu" });
    defer eu.deinit();
    try testing.expectEqualStrings("SELECT 1", eu.value.query);
    // A job in a region is found only by its location.
    try b.fake.putJob(.{ .ref = .{ .id = "job_regional", .location = "us-central1" }, .type = .query, .state = .done });
    try testing.expectError(error.NotFound, c.getJob(.{ .id = "job_regional" }));
    try testing.expectEqualStrings("Not found: Job my-project:US.job_regional", b.diag.message());
    var regional = try c.getJob(.{ .id = "job_regional", .location = "us-central1" });
    regional.deinit();
    try testing.expectError(error.NotFound, c.getJob(.{ .id = "job_regional", .location = "europe-west1" }));
    try testing.expectEqualStrings("Not found: Job my-project:europe-west1.job_regional", b.diag.message());
    try testing.expectEqual(types.JobType.load, (blk: {
        var theirs = try c.getJob(.{ .id = "job_theirs" });
        defer theirs.deinit();
        break :blk theirs.value.type;
    }));
    // A minimal projection leaves the configuration out.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const minimal = try b.raw(arena.allocator(), .GET, "/bigquery/v2/projects/my-project/jobs?projection=minimal", null);
    const page = try codec.decodeJobPage(arena.allocator(), arena.allocator(), minimal.body);
    try testing.expectEqualStrings("", page.jobs[0].query);
    try testing.expectEqual(types.JobState.pending, page.jobs[0].state);
    // A list item carries its state at its top too, as production's do.
    const listed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), minimal.body, .{});
    try testing.expectEqualStrings("PENDING", listed.object.get("jobs").?.array.items[0].object.get("state").?.string);
}

test "what the fake does not model, it says; what a test puts in, it checks" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = &b.client;
    try testing.expectError(error.Unimplemented, c.query(.{ .query = "SELECT nobody answered" }));
    try testing.expectEqualStrings("fake: no answer was given for this query text", b.diag.message());
    try testing.expectError(error.Unimplemented, c.dryRun(.{ .query = "SELECT nobody answered" }));
    try b.fake.answer("SELECT 1", .{});
    const Raw = struct { tp.Method, []const u8, ?[]const u8, []const u8 };
    for ([_]Raw{
        .{ .POST, "/bigquery/v2/projects/my-project/queries", "{\"query\":\"SELECT 1\"}", "fake: legacy SQL, BigQuery's default when useLegacySql is left out is not modelled" },
        .{ .POST, "/bigquery/v2/projects/my-project/queries", "{\"query\":\"SELECT 1\",\"useLegacySql\":true}", "fake: legacy SQL is not modelled" },
        .{ .POST, "/bigquery/v2/projects/other/queries", "{\"query\":\"SELECT 1\",\"useLegacySql\":false}", "fake: a query billed to a project other than the fake's own is not modelled" },
        .{ .POST, "/bigquery/v2/projects/my-project/jobs", "{}", "fake: a write other than a query or a cancel is not modelled" },
        .{ .DELETE, "/bigquery/v2/projects/my-project/datasets/d", null, "fake: anything but a read, a query or a cancel is not modelled" },
        .{ .GET, "/bigquery/v2/projects/my-project/datasets/d/tables/t/data", null, "fake: this path is not modelled" },
        .{ .GET, "/bigquery/v2/projects/my-project/queries", null, "fake: a read of this path is not modelled" },
    }) |r| {
        const reply = try b.raw(a, r[0], r[1], r[2]);
        try testing.expectEqual(501, reply.status);
        try testing.expect(std.mem.indexOf(u8, reply.body, r[3]) != null);
    }
    const unauthenticated = try b.fake.serve(.{ .method = .GET, .url = "/bigquery/v2/projects/my-project/datasets" }, a);
    try testing.expectEqual(401, unauthenticated.status);

    // The results of a job put in are not held.
    try b.fake.putJob(.{ .ref = .{ .id = "job_put" }, .type = .query, .state = .done });
    try testing.expectError(error.Unimplemented, c.getQueryResults(.{ .id = "job_put" }, .{}));

    const schema = [_]types.Field{.{ .name = "d", .type = .date }};
    try testing.expectError(error.InvalidEntry, b.fake.answer("SELECT d", .{ .schema = &schema, .rows = &.{.{ .cells = &.{.{ .value = .{ .int64 = 1 } }} }} }));
    try testing.expectError(error.InvalidEntry, b.fake.answer("SELECT d", .{ .schema = &schema, .rows = &.{.{ .cells = &.{ .{ .value = .null }, .{ .value = .null } } }} }));
    const required = [_]types.Field{.{ .name = "d", .type = .date, .mode = .required }};
    try testing.expectError(error.InvalidEntry, b.fake.answer("SELECT d", .{ .schema = &required, .rows = &.{.{ .cells = &.{.{ .value = .null }} }} }));
    try testing.expectError(error.InvalidEntry, b.fake.answer("SELECT d", .{ .schema = &schema, .rows = &.{.{ .cells = &.{.{ .value = .{ .date = .{ .year = 2026, .month = 13, .day = 1 } } }} }} }));
    try testing.expectError(error.InvalidEntry, b.fake.answer("", .{}));
    try testing.expectError(error.InvalidEntry, b.fake.putTable(.{ .ref = .{ .dataset = "nobody", .table = "t" } }));
    try b.fake.putDataset(.{ .ref = .{ .dataset = "d" } });
    try testing.expectError(error.InvalidEntry, b.fake.putDataset(.{ .ref = .{ .dataset = "d" } }));
    try testing.expectError(error.InvalidEntry, b.fake.putDataset(.{ .ref = .{ .dataset = "a-b" } }));
    try b.fake.putTable(.{ .ref = .{ .dataset = "d", .table = "t" } });
    try testing.expectError(error.InvalidEntry, b.fake.putTable(.{ .ref = .{ .dataset = "d", .table = "t" } }));
    try testing.expectError(error.InvalidEntry, b.fake.putJob(.{ .ref = .{ .id = "job_put" } }));
    try testing.expectError(error.InvalidEntry, b.fake.putJob(.{ .ref = .{ .id = "a b" } }));
    // An answer given again replaces the first.
    try b.fake.answer("SELECT 1", .{ .refusal = .{ .message = "Syntax error: Unexpected end of script at [1:9]" } });
    try testing.expectError(error.InvalidQuery, c.dryRun(.{ .query = "SELECT 1" }));
    try testing.expectEqualStrings("Syntax error: Unexpected end of script at [1:9]", b.diag.message());
}

test "every allocation failure in the fake is OutOfMemory without leaks" {
    const Run = struct {
        fn calls(gpa: Allocator) !void {
            var clock: core.testing.FakeClock = .{};
            var fake: FakeBigQuery = .init(gpa, clock.io(), .{ .project_id = "extractctl" });
            defer fake.deinit();
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            try seedProbe(&fake, a);
            try fake.putJob(try codec.decodeJob(a, a, production.job_cancelled));
            try answerHamlet(&fake, a, false);
            var token: core.StaticToken = .{ .token = "t" };
            var client = try Client.init(gpa, clock.io(), .{ .project_id = "extractctl", .token_provider = token.provider(), .transport = fake.transport(), .retry = .{ .max_attempts = 1 } });
            defer client.deinit();
            var datasets = try client.listDatasets(.{});
            datasets.deinit();
            var table = try client.getTable(shakespeare);
            table.deinit();
            var jobs = try client.listJobs(.{ .all_users = true });
            jobs.deinit();
            var page = try client.query(.{ .query = hamlet, .request_id = "r" });
            defer page.deinit();
            var results = try client.getQueryResults(page.value.job.?, .{ .page_size = 2 });
            results.deinit();
            var cancel = try client.cancelJob(page.value.job.?);
            cancel.deinit();
        }
    };
    try testing.checkAllAllocationFailures(core.testing.no_grow_allocator, Run.calls, .{});
}

// The slow property: the client against the fake, held to a model of
// production's queries as milestone 0 measured them.

const Model = struct {
    const Text = struct {
        rows: u8,
        polls: u8,
        cached: bool,
        reads_table: bool,
        refused: bool,
    };

    const Job = struct {
        id: []const u8,
        text: usize,
        polls_left: u32,
        done: bool,
        cancelled: bool,
    };

    const Seen = struct { job: usize, text: usize, at_ns: i96 };

    texts: [4]Text,
    jobs: std.ArrayList(Job) = .empty,
    request_ids: [2]?Seen = .{ null, null },
    queries_run: usize = 0,

    fn bill(m: *const Model, text: usize, use_cache: bool) u64 {
        const t = m.texts[text];
        if ((t.cached and use_cache) or !t.reads_table) return 0;
        return 10 * 1024 * 1024;
    }

    /// A read of a job's results: unfinished while its polls last.
    fn read(job: *Job) bool {
        if (job.polls_left > 0) {
            job.polls_left -= 1;
            return false;
        }
        job.done = true;
        return true;
    }
};

const query_texts = [_][]const u8{ "SELECT a", "SELECT b", "SELECT c", "SELECT syntax error" };

fn expectRows(page: types.QueryPage, start: usize, size: ?u32, total: usize) !void {
    const want_to = if (size) |n| @min(total, start + n) else total;
    const want_len = want_to - @min(start, want_to);
    try testing.expectEqual(want_len, page.rows.len);
    for (page.rows, 0..) |row, i| try testing.expectEqual(@as(i64, @intCast(start + i)), row.cells[0].value.int64);
    try testing.expectEqual(@as(?u64, total), page.total_rows);
    try testing.expectEqual(want_to < total, page.page_token != null);
}

fn queriesProperty(_: void, input: []const u8) !void {
    const gpa = @import("test_util.zig").propertyAllocator();
    var g: core.testing.ByteGen = .init(input);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var clock: core.testing.FakeClock = .{ .now_ns = 1_792_597_000 * std.time.ns_per_s };
    var fake: FakeBigQuery = .init(gpa, clock.io(), .{});
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "t" };
    var client = try Client.init(gpa, clock.io(), .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
        .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 1 },
    });
    defer client.deinit();

    var m: Model = .{ .texts = undefined };
    for (&m.texts, 0..) |*t, i| {
        t.* = .{
            .rows = g.intRange(u8, 0, 12),
            .polls = g.intRange(u8, 0, 3),
            .cached = g.boolean(),
            .reads_table = g.boolean(),
            .refused = i == 3,
        };
        const rows = try a.alloc(values.Row, t.rows);
        for (rows, 0..) |*row, n| {
            const cells = try a.alloc(values.Cell, 1);
            cells[0] = .{ .value = .{ .int64 = @intCast(n) } };
            row.* = .{ .cells = cells };
        }
        try fake.answer(query_texts[i], .{
            .schema = &.{.{ .name = "n", .type = .int64 }},
            .rows = rows,
            .tables = if (t.reads_table) &.{.{ .dataset = "d", .table = "t" }} else &.{},
            .bytes_processed = if (t.reads_table) 1024 else 0,
            .polls = t.polls,
            .cached = t.cached,
            .refusal = if (t.refused) .{ .message = "Syntax error: Unexpected end of script at [1:20]" } else null,
        });
    }
    const request_ids = [_][]const u8{ "zigps-rid-0", "zigps-rid-1" };

    const steps = g.intRange(u8, 1, 24);
    for (0..steps) |_| {
        // Each step meets its own fault at most: one a step without a
        // call left unused does not carry over.
        fake.dropNext(0);
        fake.loseNext(0, 503);
        const lose = g.intRange(u8, 0, 9) == 0;
        if (lose) fake.loseNext(1, 503) else if (g.intRange(u8, 0, 9) == 0) fake.dropNext(1);
        switch (g.intRange(u8, 0, 7)) {
            // A query.
            0, 1 => {
                const text = g.intRange(usize, 0, 3);
                const rid: ?usize = if (g.boolean()) g.intRange(usize, 0, 1) else null;
                const use_cache = g.boolean();
                const limit: ?u64 = g.pick(?u64, &.{ null, 1000, 20 * 1024 * 1024 });
                const size: ?u32 = if (g.boolean()) g.intRange(u32, 0, 5) else null;
                // The fake stamps a request id when it serves the first
                // attempt, before any retry's backoff.
                const sent_ns = clock.now_ns;
                const result = client.query(.{
                    .query = query_texts[text],
                    .use_query_cache = use_cache,
                    .maximum_bytes_billed = limit,
                    .page_size = size,
                    .request_id = if (rid) |r| request_ids[r] else null,
                });
                if (m.texts[text].refused) {
                    try testing.expectError(error.InvalidQuery, result);
                    continue;
                }
                if (limit) |l| if (m.bill(text, use_cache) > l) {
                    try testing.expectError(error.BytesBilledLimitExceeded, result);
                    continue;
                };
                var page = try result;
                defer page.deinit();
                // A repeat of the same text within 15 minutes, whether
                // the caller's or the client's own retry after a lost
                // answer, answers the first job unfinished.
                const repeat: ?usize = if (rid) |r| if (m.request_ids[r]) |seen|
                    (if (seen.text == text and clock.now_ns - seen.at_ns <= 15 * std.time.ns_per_min) seen.job else null)
                else
                    null else null;
                if (repeat) |j| {
                    try testing.expect(!page.value.complete);
                    try testing.expectEqualStrings(m.jobs.items[j].id, page.value.job.?.id);
                    continue;
                }
                m.queries_run += 1;
                try m.jobs.append(a, .{
                    .id = try a.dupe(u8, page.value.job.?.id),
                    .text = text,
                    .polls_left = m.texts[text].polls,
                    .done = false,
                    .cancelled = false,
                });
                const job = &m.jobs.items[m.jobs.items.len - 1];
                if (rid) |r| m.request_ids[r] = .{ .job = m.jobs.items.len - 1, .text = text, .at_ns = sent_ns };
                const complete = Model.read(job);
                if (lose) {
                    // The first answer was lost; the retry with the same
                    // request id is a repeat.
                    try testing.expect(!page.value.complete);
                    continue;
                }
                try testing.expectEqual(complete, page.value.complete);
                if (complete) try expectRows(page.value, 0, size, m.texts[text].rows);
            },
            // A read of a job's results.
            2, 3 => {
                if (m.jobs.items.len == 0) continue;
                const job = &m.jobs.items[g.intRange(usize, 0, m.jobs.items.len - 1)];
                const size: ?u32 = if (g.boolean()) g.intRange(u32, 0, 5) else null;
                const start: ?u64 = if (g.boolean()) g.intRange(u64, 0, 14) else null;
                const result = client.getQueryResults(.{ .id = job.id }, .{ .page_size = size, .start_index = start });
                if (job.cancelled) {
                    try testing.expectError(error.Unimplemented, result);
                    continue;
                }
                const total = m.texts[job.text].rows;
                // Served twice when the first answer is lost.
                if (lose) _ = Model.read(job);
                const complete = Model.read(job);
                if (complete and (start orelse 0) > total) {
                    try testing.expectError(error.InvalidArgument, result);
                    continue;
                }
                var page = try result;
                defer page.deinit();
                try testing.expectEqual(complete, page.value.complete);
                if (complete) try expectRows(page.value, @intCast(start orelse 0), size, total);
            },
            // A cancel.
            4 => {
                if (m.jobs.items.len == 0) continue;
                const job = &m.jobs.items[g.intRange(usize, 0, m.jobs.items.len - 1)];
                var answer_ = try client.cancelJob(.{ .id = job.id });
                defer answer_.deinit();
                // A lost first cancel stopped the job; the retry finds it
                // done.
                const was_running = !job.done and !lose;
                if (!job.done) {
                    job.done = true;
                    job.cancelled = true;
                    job.polls_left = 0;
                }
                try testing.expectEqual(if (was_running) types.JobState.running else types.JobState.done, answer_.value.state);
                try testing.expectEqual(!was_running and job.cancelled, answer_.value.failed());
            },
            // A get.
            5 => {
                if (m.jobs.items.len == 0) continue;
                const job = &m.jobs.items[g.intRange(usize, 0, m.jobs.items.len - 1)];
                var got = try client.getJob(.{ .id = job.id });
                defer got.deinit();
                try testing.expectEqual(if (job.done) types.JobState.done else types.JobState.running, got.value.state);
                try testing.expectEqual(job.cancelled, got.value.failed());
                try testing.expectEqualStrings(query_texts[job.text], got.value.query);
            },
            // The history, and a dry run, which makes none.
            6 => {
                var page = try client.listJobs(.{});
                defer page.deinit();
                try testing.expectEqual(m.jobs.items.len, page.value.jobs.len);
                const text = g.intRange(usize, 0, 3);
                const dry = client.dryRun(.{ .query = query_texts[text] });
                if (m.texts[text].refused) {
                    try testing.expectError(error.InvalidQuery, dry);
                } else {
                    var d = try dry;
                    d.deinit();
                }
            },
            // Time passes: a request id is forgotten after 15 minutes.
            // Whole minutes and 7 s, so no sum of steps lands on the
            // boundary, where a retry's millisecond of backoff would
            // decide it.
            7 => clock.now_ns += @as(i96, g.intRange(u32, 1, 20)) * std.time.ns_per_min + 7 * std.time.ns_per_s,
            else => unreachable,
        }
    }
    try testing.expectEqual(m.queries_run, fake.queryCount());
    try testing.expectEqual(m.jobs.items.len, fake.jobCount());
}

test "slow property: queries, repeats, polls, pages and cancels against the fake, held to a model" {
    try core.testing.fuzzBytes({}, queriesProperty, .{ .corpus = &.{request_id_at_fifteen_minutes} });
}

/// Fuzz-found: a request id reused 15 minutes to the millisecond after
/// a lost first answer, the model stamping it after the retry's backoff.
const request_id_at_fifteen_minutes = "\x2f\xf7\x67\x06\xe4\xf7\x38\x03\x82\x20\x9f\x99\x4f\x5e\xba\xb8\xff\xea\x14\xc8\xad\x7b\x44\xc6\x20\x64\xf6\x64\x8c\xc0\xcf\x3b\x44\xaf\x0a\x97\x4a\xef\xb8\x95\xf0\x0b\x27\xc3\xb3\x82\x83\xbd\xe5\x9b\x0c\x56\xa1\x1b\xc7\x9a\x37\x3e\xa9\x94\xcb\x05\x62\x8f\x38\xb8\xc4\x97\xbd\xc7\x55\x56\xf5\x7f\x15\x36\x52\xe9\xa4\xc2\x61\xeb\xd8\x95\xac\xcc\xbc\x9d\x23\xad\x70\x21\xf2\xe5\x51\xa6\x46\x66\x3d\x5b\xa7\xf4\xbc\x2a\xbf\xd8\x86\xf6\x20\xa7\x36\x7c\x05\x08\xfe\x5c\x19\xa3\x98\x7b\x7d\x0a\xd2\x83\xd3\x4f\xdc\xd3\xb0\xe3\x41\xc6\x1d\x5b\xe8\x0b\x73\x41\x72\x63\xda\x6e\xa3\x75\xbb\x9c\x95\x98\xdc\xd1\x70\xfc\x0b\x5a\xf8\x4b\x2e\x81\xdb\x9e\x07\x5d\x2d\x41\x2e\x16\xb5\x9b\xd5\x17\x4b\x71\x21\xc2\xe1\xaa\x4f\xe9\x2b\x75\xc8\x0d\xef\xf2\xb5\xa9\x27\x2b\xd6\x39\xc0\x1b\x27\x3a\xe0\x47\x60\x0b\x65\xb9\xd9\x44\x79\x4d\x76\x1a\x74\x49\xa0\x7d\x00\x0e\x18\x2a\x97\x92\xd1\xcc\x00\x45\x58\x1a\x16\x19\xc0\x0c\x96\xb0\xee\xe7\xf4\xa7\xf4\x4e\x58\x36\x96\x4f\x43\x85\x46\x1f\x53\x7d\xf6\x82\x12\x08\x9c\xab\x35\xb9\xf7\xbe\x04\xf9\x3a\x8e\x29\x49\xae\x46\x90\x6f\x8e\x73\x72\xf5\x77\x1d\xc5\xf4\x71\xbc\x2c\xac\xab\xba\x7e\x08\xf4\x1b\x15\x8f\xe7\xf1\xcc\xa5\x1b\x71\xd8\x60\xde\xf1\xd0\xaf\xee\xd2\x12\x7b\xe0\x9e\xff\x66\x7d\x35\x24\x11\xb9\x8d\x73\xd1\xab\x1d\xe2\x03\x8d\x27\xf9\x39\xb2\x11\xa5\xc4\x85\x8d\x96\x17\xab\xa4\x5f\xf9\x5a\xd8\x22\xbc\xad\x1c\x31\x5d\x8f\xc4\xf9\x59\x73\xe7\xda\x08\x63\xfd\xa2\xe4\xcc\xe3\xde\x47\x87\xc9\xa3\x9b\xa6\x2d\x26\x65\xd0\x8e\x80\x91\xb4\x68\x1f\x49\x4f\x89\xed\xad\x96\x8d\x90\x8d\xfb\xcb\x14\x48\xcf\x6d\x43\xd3\xbc\xfb\x91\x92\x00\x71\x38\x85\xf4\x01\x3e\xfc\x09\x4d\x34\x86\x3d\xc9\x19\xd2\xfb\xec\x5c\x5f\x6d\x23\x7d\x7f\xec\xa0\xb1\x34\x1e\xa9\xc7\xc7\xaf\xed\xf1\x86\x5b\xd4\xe2\x0c\xb3\x45\x86\x9f\x57\x91\x1f\x75\xe8\xae\x32\x0a\x14\x55\xc0\xd8\x55\xae\x6b\x0f\xda\x44\xfa\x75\xac\x39\x74\x03\xd7\x91\x22\x76\xf2\xa7\x80\x3b\xa8\xde\x62\x8f\x03\xee\x30\xf2\x09\xbd\xab\xaf\xec\xb3\x3c\x68\x61\x47\x1f\x4b\xfb\x17\x38\x77\xcf\xa3\x58\xe3\x7a\xe8\xd9\x0e\xa0\x38\xa0\x88\x63\x63\xe2\x50\xdd\xdf\x26\x2f\x96\xac\x9a\xe2\x97\x3f\xcd\x6a\xb6\x24\xa0\x5b\x21\x73\x8e\x47\x41\xe6\x80\xe2\x58\x8b\xd3\x8d\xec\xce\xac\xa2\x7b\x21\x86\x8d\x90\xbf\xd8\x60\x4f\x78\x64\x50\xfa\xb6\x91\xca\x50\x1c\x72\xea\x5f\xf1\x67\xf9\x01\x8a\xaa\x3d\x74\x9b\x6f\x45\x7d\x3c\x76\xd6\x19\xe2\x9e\x55\xe1\x2c\x60\x8e\x5b\x21\xa3\x02\xc9\x95\xfd\x45\x1a\xb7\x58\x40\xcb\x4a\x89\x16\x81\x9c\x12\x17\x6b\x5d\xdd\x6f\x91\x63\xb2\x0a\xce\x61\x65\x92\xdf\xa2\x23\x0a\x1d\x1e\xa3\x4d\x50\xb1\xb0\xbd\x89\xb0\x24\x3c\xa3\xb5\x32\xee\x85\x6b\xdf\xdb\xdf\x93\x22\x5d\x1c\x84\xf8\xf7\x76\xc2\xf6\x02\xdc\x92\xae\x91\xe3\x76\x69\xb9\x47\xc9\x30\xfa\x85\x32\x18\x1b\xe7\x15\xe4\x3f\x74\x6d\x65\xe8\xb1\x4c\x49\x53\x4f\x6a\x71\x2f\x6b\xf1\x9e\x05\x8f\xc3\x93\xee\xc1\xa8\xde\x10\xfb\x7d\x47\xa7\x97\x3e\xc8\xb1\xb5\x2b\x8c\x24\xb8\x74\xab\xac\xc6\x15\x53\xdd\xcc\xc3\x1e\xdc\x70\x75\x59\xdb\x7b\x2b\x1e\xf0\xd3\x18\xf7\x46\xa7\xac\xac\xb5\xe0\xbf\x41\x90\xe6\xfd\xc2\xd7\x40\xfb\xb3\x47\x2d\xd5\x8d\x74\xa4\xab\x3e\x11\x40\x91\xd0\x07\xce\x72\x03\xef\x36\x67\x1a\xf0\xed\xf3\x94\x43\xca\xc6\xb9\xb7\xb5\x15\x2d\x5a\x3c\x3d\xfd\x5f\x4e\xb5\x29\x8d\x5a\x93\xb2\xa4\x7f\xbb\x51\x22\xe0\xb4\xbe\x46\x23\x5c\x8b\xeb\x76\x4f\x60\x99\xe8\xd7\x1c\xb9\x2c\x97\xc4\x21\x07\x51\xb2\x8d\xdd\x3a\xfa\xf1\x30\xeb\xa6\x63\x1e\xd9\x1c\x20\xef\x0f\xfe\x10\x10\x6f\xb2\x9c\x55\x32\x36\x29\xb8\xd7\x01\xad\xf2\xc3\xc3\xc2\x2e\x61\x92\x4f\xcd\x05\xed\x41\x27\xe0\xd4\xdb\x65\xef\x20\x46\xc1\x38\x04\x40\xfe\x55\x9f\x9e\xf2\x42\xad\xbe\xfa\x5f\x67\x73\xa5\x19\xee\x60\xec\xae\x3d\x39\xc5\xba\x4d\xf1\xc5\x5b\xde\x31\x7e\x89\x90\x65\x6f\x6f\x44\xb6\xd2\xdb\x0c\x97\x97\xef\xe9\x2c\x7d\xca\xbb\xd5\x72\xf0\x56\x18\x5a\x3c\xaf\xcb\x5d\x2b\xbe\x61\x1c\x16\x58\x58\xfa\xf4\x4c\x24\x0f\x79\x24\xa4\x54\x25\xa6\x66\xc3\xdc\x4b\xc7\x54\xf7\x09\x99\x4c\x85\xc6\xd8\x0c\x9e\x89\x1f\x60\x63\x6f\x91\x3b\xc2\xc8\x46\xfd\xb6\x94\x1b\x79\xa8\xbb\xcc\x9c\xa6\x9e\x32\x1e\x0c\x2b\x70\xb7\xbf\xba\x84\x38\x73\x99\x6a\x63\x6c\x52\x2e\xf9\x5c\x98\x59\xad\x03\xc7\x46\x6f\x01\x86\xd9\xb1\x7a\xff\x81\xec\xf4\x82\x17\x1e\x2f\x41\x37\x25\xa2\xf9\x40\x82\x8b\x0b\xd8\x22\x4f\xce\xf8\xc7\xbb\x93\x62\xa1\xc2\x4d\x8d\x84\x23\x6b\x83\x3d\xca\x26\x2d\xe6\x17\xbd\xdb\x3d\xd0\x98\xf6\x53\xd8\xd7\x5d\x45\x26\xf6\xe0\xc4\xb4\x74\xba\x06\x61\x0e\xe1\x92\x46\xa9\x00\x6e\xef\x15\xed\x8f\x71\xb9\xf5\x5e\x8a\xb7\x99\x73\xe7\x13\xb3\x48\xa8\x8b\x7d\x1a\x5f\x77\x07\x61\x03\xe2\x68\x0d\x64\x99\xb4\x36\xcf\x03\x0f\x7b\xc5\x1a\xcc\x18\x08\xf7\x4f\xe8\xf6\xad\xd9\x84\x35\x0b\x8b\xfe\xab\xbe\xcb\x29\x74\xd5\x75\xb1\x70\x73\x59\xa0\xa2\x4c\x45\xde\x9d\x0f\x6d\xe8\x79\xf6\x51\xbd\xc1\x0c\xa0\xd2\xf3\x60\xcc\x86\xb7\xb0\xd4\xe1\x28\x8e\xc1\x0e\xd4\xbb\x34\x15\x94\xbe\xd0\xb0\x5b\x6e\xc3\xe5\xa9\x5a\x0a\x90\x1f\xc2\xfc\x8d\x29\x18\x80\x54\xaf\x47\xe8\xb5\xe7\xe8\x7d\x9b\x2b\xf9\x06\x33\x39\x6b\x3c\x70\x95\x6c\x02\x0e\xd8\x0d\xe6\x67\x8a\xf6\x80\xe4\x6b\x5e\xb9\xf6\xb0\xa4\xd3\xf4\xf3\x79\xca\x89\x55\xaf\xe7\x67\x58\xa3\x95\x57\x12\x0f\xe0\xa8\x1d\xc6\x8a\xc2\x86\x64\xc7\x53\x07\x94\x95\x7f\x5d\x8f\x7f\x3b\xe8\x75\x94\x65\x39\x57\xc4\xa0\xd6\x15\x82\xd1\x73\x88\x5b\xc5\x24\xb8\x6f\xab\xdc\x66\xab\x14\x32\x87\x62\xec\x64\xd6\x34\x92\x87\x94\x66\x32\xbe\x79\xde\x63\xf2\xaa\xbc\x9c\x89\x1f\xaf\x50\xb5\x50\xca\xbd\xc8\xe7\x68\x32\xac\x84\x7f\xa7\xd9\x36\xb0\x4c\x68\x53\xf1\x7e\xcb\xc1\x61\x5f\x8a\x88\xec\xc7\x33\x4d\x16\x21\xbc\x3b\x26\xfe\xb2\x0f\x23\xbf\xcc\xbd\x96\x77\x25\x10\xcd\x75\xca\x70\x12\x1d\x15\x5e\xaa\x11\x89\x44\x8b\x76\xb3\xda\x8e\x84\x7e\x8b\x08\x45\x4c\x65\x68\x5c\x5d\x74\x29\xab\x08\xd3\x81\x68\x8b\xac\x29\xec\x38\xf5\xeb\xb9\xab\xd2\xd7\x09\x07\x3a\xb2\xe8\x3a\x28\xab\x9c\x0c\xae\xb5\x94\x44\xf3\x54\x61\x00\x65\xba\xe9\x1b\x13\x9a\x87\x0c\x3c\x27\xae\x03\x85\xb6\xd6\x4d\xbe\x2a\x7a\xc1\x99\xed\xeb\xbf\x4c\xe0\x7e\xe8\x91\x99\x4b\xcf\x49\x9a\xbb\xb1\x21\x14\x6f\x0b\xe3\xaf\x3a\x12\xf2\xd1\x7b\x4b\x07\x55\x24\x0e\xfd\x61\x15\xd0\x98\x62\x44\x77\x26\xba\xa4\xec\x1f\x29\x18\xb5\xa8\x57\xe4\x2c\xa0\xd0\x75\x6c\x77\xab\x8d\x77\x60\x55\x66\xd1\x14\xbe\x22\xe5\xa8\x77\x0b\x81\xbd\x21\xe2\xe7\x55\x91\xf7\x52\x92\xef\xfe\x9f\x0e\x08\x3b\x71\x66\xc9";
