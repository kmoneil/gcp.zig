//! Cloud Run in memory, for tests of code that reads services and
//! revisions: behind `Client.Options.transport`, it answers the module's
//! reads as production answered them when measured on 2026-10-19 (issue
//! #244).
//!
//! - Locations, services and revisions are put in by the test: the API
//!   here is read only, so `putLocation`, `putService` and `putRevision`
//!   stand in for whoever deployed.
//! - The `-` location lists every region's services, as production
//!   answers it (though its documentation says otherwise), with the
//!   `unreachable` regions a test asks for; `services/-` lists every
//!   service's revisions in the location.
//! - Lists sort by name and page; revisions sort newest first, as
//!   production answered them.
//! - Refused in production's words: a service nobody has is 404
//!   "Resource '<id>' of kind 'SERVICE' in region '<l>' in project '<p>'
//!   does not exist." (a revision's the same with kind 'REVISION',
//!   production's shape though only the service's was measured), a
//!   location that is no region is 400 "The request has errors";
//!   revisions of a service nobody has are an empty page, not a 404, as
//!   production answered.
//! - Faults a test asks for: refusals, dropped connections, and a lost
//!   answer.
//!
//! Not modelled, answered 501 with the reason: writes of any kind
//! (deploys, traffic, deletes, IAM), jobs, executions, operations, and
//! another project's paths.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const core = @import("core");
const tp = core.transport;
const types = @import("types.zig");
const validate = @import("validate.zig");

pub const FakeRun = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    options: Options,
    /// Strings and resources, freed with the fake.
    store: std.heap.ArenaAllocator,
    /// Location ids, in the order put in.
    locations: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// By full name.
    services: std.StringArrayHashMapUnmanaged(*FakeService) = .empty,
    /// By full name.
    revisions: std.StringArrayHashMapUnmanaged(*FakeRevision) = .empty,
    /// What a `-` location's answer names as unreachable.
    unreachable_regions: []const []const u8 = &.{},
    faults: [3]Fault = .{ .{}, .{}, .{} },
    calls: usize = 0,

    const Fault = struct { n: usize = 0, status: u16 = 0 };
    const refuse = 0;
    const drop = 1;
    const lose = 2;

    pub const Options = struct {
        /// The project it answers for, by id.
        project_id: []const u8 = "my-project",
    };

    pub const Reply = struct { status: u16, headers: []const tp.Header = &.{}, body: []const u8 };

    const FakeService = struct {
        name: []const u8,
        id: []const u8,
        location: []const u8,
        description: []const u8,
        uri: []const u8,
        urls: []const []const u8,
        latest_ready_revision: []const u8,
        latest_created_revision: []const u8,
        traffic: []const types.TrafficTarget,
        traffic_statuses: []const types.TrafficTarget,
        terminal_condition: ?types.Condition,
        conditions: []const types.Condition,
        create_time: ?std.Io.Timestamp,
        update_time: ?std.Io.Timestamp,
        creator: []const u8,
        last_modifier: []const u8,
        generation: ?i64,
        observed_generation: ?i64,
        reconciling: bool,
        labels: []const types.Label,
    };

    const FakeRevision = struct {
        name: []const u8,
        id: []const u8,
        service: []const u8,
        location: []const u8,
        create_time: ?std.Io.Timestamp,
        update_time: ?std.Io.Timestamp,
        generation: ?i64,
        containers: []const types.Container,
        conditions: []const types.Condition,
        log_uri: []const u8,
        service_account: []const u8,
        labels: []const types.Label,
    };

    pub fn init(gpa: Allocator, io: std.Io, options: Options) FakeRun {
        return .{ .gpa = gpa, .io = io, .options = options, .store = .init(gpa) };
    }

    pub fn deinit(f: *FakeRun) void {
        f.locations.deinit(f.gpa);
        f.services.deinit(f.gpa);
        f.revisions.deinit(f.gpa);
        f.store.deinit();
        f.* = undefined;
    }

    /// Goes into `Client.Options.transport`.
    pub fn transport(f: *FakeRun) tp.Transport {
        return .{ .ptr = f, .vtable = &.{ .send = send } };
    }

    // Faults, each for the next `n` calls.

    /// Answers them with `status`, and changes nothing.
    pub fn refuseNext(f: *FakeRun, n: usize, status: u16) void {
        f.setFault(refuse, .{ .n = n, .status = status });
    }

    /// Closes their connection before any answer.
    pub fn dropNext(f: *FakeRun, n: usize) void {
        f.setFault(drop, .{ .n = n });
    }

    /// Serves them and answers `status` instead of what was read.
    pub fn loseNext(f: *FakeRun, n: usize, status: u16) void {
        f.setFault(lose, .{ .n = n, .status = status });
    }

    fn setFault(f: *FakeRun, slot: usize, fault: Fault) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.faults[slot] = fault;
    }

    fn takeFault(f: *FakeRun, slot: usize) ?Fault {
        const fault = &f.faults[slot];
        if (fault.n == 0) return null;
        fault.n -= 1;
        return fault.*;
    }

    // What a test reads.

    /// Calls served, refusals included.
    pub fn callCount(f: *FakeRun) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.calls;
    }

    /// Services held, every location together.
    pub fn serviceCount(f: *FakeRun) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.services.count();
    }

    /// Revisions held, every service together.
    pub fn revisionCount(f: *FakeRun) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.revisions.count();
    }

    // What a test puts in.

    pub const PutError = error{ OutOfMemory, InvalidEntry };

    /// A location services can live in, such as "us-central1".
    pub fn putLocation(f: *FakeRun, id: []const u8) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (!validate.isLocation(id) or std.mem.eql(u8, id, "-")) return error.InvalidEntry;
        if (f.locations.contains(id)) return error.InvalidEntry;
        try f.locations.put(f.gpa, try f.store.allocator().dupe(u8, id), {});
    }

    /// What a `-` location's list answers as its unreachable regions.
    pub fn setUnreachable(f: *FakeRun, regions: []const []const u8) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const s = f.store.allocator();
        const copy = try s.alloc([]const u8, regions.len);
        for (regions, copy) |region, *out| out.* = try s.dupe(u8, region);
        f.unreachable_regions = copy;
    }

    /// A service as a test puts one in, standing in for whoever deployed
    /// it. Everything `types.Service` reads back can be set.
    pub const PutService = struct {
        /// Must be put with `putLocation` first.
        location: []const u8,
        id: []const u8,
        description: []const u8 = "",
        uri: []const u8 = "",
        urls: []const []const u8 = &.{},
        /// Revision ids, as production answers their trailing segments.
        latest_ready_revision: []const u8 = "",
        latest_created_revision: []const u8 = "",
        traffic: []const types.TrafficTarget = &.{},
        traffic_statuses: []const types.TrafficTarget = &.{},
        terminal_condition: ?types.Condition = null,
        conditions: []const types.Condition = &.{},
        create_time: ?std.Io.Timestamp = null,
        update_time: ?std.Io.Timestamp = null,
        creator: []const u8 = "",
        last_modifier: []const u8 = "",
        generation: ?i64 = null,
        observed_generation: ?i64 = null,
        reconciling: bool = false,
        labels: []const types.Label = &.{},
    };

    /// Puts a service in and returns its full name, owned by the fake.
    ///
    /// `error.InvalidEntry`, with nothing kept, for: a location nobody
    /// put; an id taken or malformed (or `-`, which Cloud Run reads as
    /// every service).
    pub fn putService(f: *FakeRun, service: PutService) PutError![]const u8 {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (!f.locations.contains(service.location)) return error.InvalidEntry;
        if (!validate.isResourceId(service.id) or std.mem.eql(u8, service.id, "-")) return error.InvalidEntry;
        const s = f.store.allocator();
        const name = try std.fmt.allocPrint(s, "projects/{s}/locations/{s}/services/{s}", .{ f.options.project_id, service.location, service.id });
        if (f.services.contains(name)) return error.InvalidEntry;
        const held = try s.create(FakeService);
        held.* = .{
            .name = name,
            .id = name[std.mem.lastIndexOfScalar(u8, name, '/').? + 1 ..],
            .location = try s.dupe(u8, service.location),
            .description = try s.dupe(u8, service.description),
            .uri = try s.dupe(u8, service.uri),
            .urls = try dupeStrings(s, service.urls),
            .latest_ready_revision = try s.dupe(u8, service.latest_ready_revision),
            .latest_created_revision = try s.dupe(u8, service.latest_created_revision),
            .traffic = try dupeTraffic(s, service.traffic),
            .traffic_statuses = try dupeTraffic(s, service.traffic_statuses),
            .terminal_condition = if (service.terminal_condition) |c| try dupeCondition(s, c) else null,
            .conditions = try dupeConditions(s, service.conditions),
            .create_time = service.create_time,
            .update_time = service.update_time,
            .creator = try s.dupe(u8, service.creator),
            .last_modifier = try s.dupe(u8, service.last_modifier),
            .generation = service.generation,
            .observed_generation = service.observed_generation,
            .reconciling = service.reconciling,
            .labels = try dupeLabels(s, service.labels),
        };
        try f.services.put(f.gpa, held.name, held);
        return held.name;
    }

    /// A revision as a test puts one in. The service must be put first;
    /// the id follows production's `<service>-0000N-<suffix>` shape in
    /// spirit but is taken as given.
    pub const PutRevision = struct {
        location: []const u8,
        /// The service's id, as the wire's `service` field names it.
        service: []const u8,
        id: []const u8,
        create_time: ?std.Io.Timestamp = null,
        update_time: ?std.Io.Timestamp = null,
        generation: ?i64 = null,
        containers: []const types.Container = &.{},
        conditions: []const types.Condition = &.{},
        log_uri: []const u8 = "",
        service_account: []const u8 = "",
        labels: []const types.Label = &.{},
    };

    /// Puts a revision in and returns its full name, owned by the fake.
    ///
    /// `error.InvalidEntry`, with nothing kept, for: a service nobody
    /// put; an id taken, malformed or `-`.
    pub fn putRevision(f: *FakeRun, revision: PutRevision) PutError![]const u8 {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const s = f.store.allocator();
        const service_name = try std.fmt.allocPrint(s, "projects/{s}/locations/{s}/services/{s}", .{ f.options.project_id, revision.location, revision.service });
        if (!f.services.contains(service_name)) return error.InvalidEntry;
        if (!validate.isResourceId(revision.id) or std.mem.eql(u8, revision.id, "-")) return error.InvalidEntry;
        const name = try std.fmt.allocPrint(s, "{s}/revisions/{s}", .{ service_name, revision.id });
        if (f.revisions.contains(name)) return error.InvalidEntry;
        const held = try s.create(FakeRevision);
        held.* = .{
            .name = name,
            .id = name[std.mem.lastIndexOfScalar(u8, name, '/').? + 1 ..],
            .service = try s.dupe(u8, revision.service),
            .location = try s.dupe(u8, revision.location),
            .create_time = revision.create_time,
            .update_time = revision.update_time,
            .generation = revision.generation,
            .containers = try dupeContainers(s, revision.containers),
            .conditions = try dupeConditions(s, revision.conditions),
            .log_uri = try s.dupe(u8, revision.log_uri),
            .service_account = try s.dupe(u8, revision.service_account),
            .labels = try dupeLabels(s, revision.labels),
        };
        try f.revisions.put(f.gpa, held.name, held);
        return held.name;
    }

    fn dupeStrings(s: Allocator, items: []const []const u8) Allocator.Error![]const []const u8 {
        const out = try s.alloc([]const u8, items.len);
        for (items, out) |item, *o| o.* = try s.dupe(u8, item);
        return out;
    }

    fn dupeLabels(s: Allocator, labels: []const types.Label) Allocator.Error![]const types.Label {
        const out = try s.alloc(types.Label, labels.len);
        for (labels, out) |l, *o| o.* = .{ .key = try s.dupe(u8, l.key), .value = try s.dupe(u8, l.value) };
        return out;
    }

    fn dupeTraffic(s: Allocator, targets: []const types.TrafficTarget) Allocator.Error![]const types.TrafficTarget {
        const out = try s.alloc(types.TrafficTarget, targets.len);
        for (targets, out) |t, *o| o.* = .{
            .type = t.type,
            .revision = try s.dupe(u8, t.revision),
            .percent = t.percent,
            .tag = try s.dupe(u8, t.tag),
            .uri = try s.dupe(u8, t.uri),
        };
        return out;
    }

    fn dupeCondition(s: Allocator, c: types.Condition) Allocator.Error!types.Condition {
        return .{
            .type = try s.dupe(u8, c.type),
            .state = c.state,
            .message = try s.dupe(u8, c.message),
            .reason = try s.dupe(u8, c.reason),
            .severity = c.severity,
            .last_transition_time = c.last_transition_time,
        };
    }

    fn dupeConditions(s: Allocator, conditions: []const types.Condition) Allocator.Error![]const types.Condition {
        const out = try s.alloc(types.Condition, conditions.len);
        for (conditions, out) |c, *o| o.* = try dupeCondition(s, c);
        return out;
    }

    fn dupeContainers(s: Allocator, containers: []const types.Container) Allocator.Error![]const types.Container {
        const out = try s.alloc(types.Container, containers.len);
        for (containers, out) |c, *o| o.* = .{ .name = try s.dupe(u8, c.name), .image = try s.dupe(u8, c.image) };
        return out;
    }

    // The transport.

    fn send(ptr: *anyopaque, req: tp.Request, arena: Allocator) tp.Error!tp.Response {
        const f: *FakeRun = @ptrCast(@alignCast(ptr));
        const reply = try f.serve(req, arena);
        return .{ .status = reply.status, .headers = reply.headers, .body = reply.body };
    }

    /// One request, as `send` serves it: for a test that wants to send
    /// what no client would.
    pub fn serve(f: *FakeRun, req: tp.Request, arena: Allocator) tp.Error!Reply {
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

    fn route(f: *FakeRun, req: tp.Request, arena: Allocator, route_text: []const u8, query: []const u8) Allocator.Error!Reply {
        if (req.bearer == null) return fail(arena, 401, "UNAUTHENTICATED", "Request is missing required authentication credential. Expected OAuth 2 access token, login cookie or other valid authentication credential. See https://developers.google.com/identity/sign-in/web/devconsole-project.");
        if (req.method != .GET) return notModelled(arena, "anything but a read");
        const target = parseRoute(route_text) orelse return notModelled(arena, "this path");
        if (!std.mem.eql(u8, target.project, f.options.project_id)) return notModelled(arena, "a project other than the fake's own");
        const params = try parseParams(arena, query) orelse return fail(arena, 400, "INVALID_ARGUMENT", "Invalid query string.");
        switch (target.kind) {
            .locations => return f.listLocations(arena, params),
            .services => |location| {
                if (!std.mem.eql(u8, location, "-") and !f.locations.contains(location)) return badRegion(arena);
                return f.listServices(arena, location, params);
            },
            .service => |svc| {
                if (!f.locations.contains(svc.location)) return badRegion(arena);
                const name = try serviceNameOf(arena, f.options.project_id, svc.location, svc.id);
                const service = f.services.get(name) orelse return fail(arena, 404, "NOT_FOUND", try arena.print("Resource '{s}' of kind 'SERVICE' in region '{s}' in project '{s}' does not exist.", .{ svc.id, svc.location, f.options.project_id }));
                var out: std.Io.Writer.Allocating = .init(arena);
                var jw: Stringify = .{ .writer = &out.writer };
                writeService(&jw, service) catch return error.OutOfMemory;
                return .{ .status = 200, .body = out.written() };
            },
            .revisions => |rev| {
                if (!f.locations.contains(rev.location)) return badRegion(arena);
                return f.listRevisions(arena, rev.location, rev.service, params);
            },
            .revision => |rev| {
                if (!f.locations.contains(rev.location)) return badRegion(arena);
                var w: std.Io.Writer.Allocating = .init(arena);
                w.writer.print("projects/{s}/locations/{s}/services/{s}/revisions/{s}", .{ f.options.project_id, rev.location, rev.service, rev.id }) catch return error.OutOfMemory;
                const revision = f.revisions.get(w.written()) orelse return fail(arena, 404, "NOT_FOUND", try arena.print("Resource '{s}' of kind 'REVISION' in region '{s}' in project '{s}' does not exist.", .{ rev.id, rev.location, f.options.project_id }));
                var out: std.Io.Writer.Allocating = .init(arena);
                var jw: Stringify = .{ .writer = &out.writer };
                writeRevision(&jw, revision) catch return error.OutOfMemory;
                return .{ .status = 200, .body = out.written() };
            },
        }
    }

    fn badRegion(arena: Allocator) Allocator.Error!Reply {
        return fail(arena, 400, "INVALID_ARGUMENT", "The request has errors");
    }

    fn serviceNameOf(arena: Allocator, project: []const u8, location: []const u8, id: []const u8) Allocator.Error![]const u8 {
        var w: std.Io.Writer.Allocating = .init(arena);
        w.writer.print("projects/{s}/locations/{s}/services/{s}", .{ project, location, id }) catch return error.OutOfMemory;
        return w.written();
    }

    fn listLocations(f: *FakeRun, arena: Allocator, params: []const Param) Allocator.Error!Reply {
        var sorted: std.ArrayList([]const u8) = .empty;
        try sorted.appendSlice(arena, f.locations.keys());
        std.mem.sort([]const u8, sorted.items, {}, stringLess);
        const window = pageOf(params, sorted.items.len, sorted.items.len) orelse return pageRefusal(arena);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        write: {
            jw.beginObject() catch break :write;
            if (window.to > window.from) {
                jw.objectField("locations") catch break :write;
                jw.beginArray() catch break :write;
                for (sorted.items[window.from..window.to]) |id| {
                    jw.beginObject() catch break :write;
                    jw.objectField("name") catch break :write;
                    jw.print("\"projects/{s}/locations/{s}\"", .{ f.options.project_id, id }) catch break :write;
                    jw.objectField("locationId") catch break :write;
                    jw.write(id) catch break :write;
                    jw.endObject() catch break :write;
                }
                jw.endArray() catch break :write;
            }
            if (window.next) |n| {
                jw.objectField("nextPageToken") catch break :write;
                jw.print("\"p{d}\"", .{n}) catch break :write;
            }
            jw.endObject() catch break :write;
            return .{ .status = 200, .body = out.written() };
        }
        return error.OutOfMemory;
    }

    fn listServices(f: *FakeRun, arena: Allocator, location: []const u8, params: []const Param) Allocator.Error!Reply {
        const everywhere = std.mem.eql(u8, location, "-");
        var matched: std.ArrayList(*FakeService) = .empty;
        for (f.services.values()) |service| {
            if (everywhere or std.mem.eql(u8, service.location, location)) try matched.append(arena, service);
        }
        std.mem.sort(*FakeService, matched.items, {}, struct {
            fn inner(_: void, a: *FakeService, b: *FakeService) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.inner);
        const window = pageOf(params, matched.items.len, 1000) orelse return pageRefusal(arena);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        write: {
            jw.beginObject() catch break :write;
            if (window.to > window.from) {
                jw.objectField("services") catch break :write;
                jw.beginArray() catch break :write;
                for (matched.items[window.from..window.to]) |service| writeService(&jw, service) catch break :write;
                jw.endArray() catch break :write;
            }
            if (window.next) |n| {
                jw.objectField("nextPageToken") catch break :write;
                jw.print("\"p{d}\"", .{n}) catch break :write;
            }
            if (everywhere and f.unreachable_regions.len > 0) {
                jw.objectField("unreachable") catch break :write;
                jw.beginArray() catch break :write;
                for (f.unreachable_regions) |region| jw.write(region) catch break :write;
                jw.endArray() catch break :write;
            }
            jw.endObject() catch break :write;
            return .{ .status = 200, .body = out.written() };
        }
        return error.OutOfMemory;
    }

    fn listRevisions(f: *FakeRun, arena: Allocator, location: []const u8, service_id: []const u8, params: []const Param) Allocator.Error!Reply {
        const everywhere = std.mem.eql(u8, service_id, "-");
        var matched: std.ArrayList(*FakeRevision) = .empty;
        for (f.revisions.values()) |revision| {
            if (!std.mem.eql(u8, revision.location, location)) continue;
            if (everywhere or std.mem.eql(u8, revision.service, service_id)) try matched.append(arena, revision);
        }
        // Newest first, as production answered the revisions after the
        // bad deploy; ties by name for a stable page walk.
        std.mem.sort(*FakeRevision, matched.items, {}, struct {
            fn inner(_: void, a: *FakeRevision, b: *FakeRevision) bool {
                const at: i96 = if (a.create_time) |t| t.nanoseconds else 0;
                const bt: i96 = if (b.create_time) |t| t.nanoseconds else 0;
                if (at != bt) return at > bt;
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.inner);
        const window = pageOf(params, matched.items.len, 1000) orelse return pageRefusal(arena);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        write: {
            jw.beginObject() catch break :write;
            if (window.to > window.from) {
                jw.objectField("revisions") catch break :write;
                jw.beginArray() catch break :write;
                for (matched.items[window.from..window.to]) |revision| writeRevision(&jw, revision) catch break :write;
                jw.endArray() catch break :write;
            }
            if (window.next) |n| {
                jw.objectField("nextPageToken") catch break :write;
                jw.print("\"p{d}\"", .{n}) catch break :write;
            }
            jw.endObject() catch break :write;
            return .{ .status = 200, .body = out.written() };
        }
        return error.OutOfMemory;
    }

    fn writeService(jw: *Stringify, service: *const FakeService) Stringify.Error!void {
        var buf: [core.timestamp.max_len]u8 = undefined;
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(service.name);
        if (service.description.len > 0) {
            try jw.objectField("description");
            try jw.write(service.description);
        }
        if (service.generation) |n| {
            try jw.objectField("generation");
            try jw.print("\"{d}\"", .{n});
        }
        if (service.labels.len > 0) {
            try jw.objectField("labels");
            try writeLabelObject(jw, service.labels);
        }
        if (service.create_time) |t| {
            try jw.objectField("createTime");
            try jw.write(core.timestamp.format(&buf, t));
        }
        if (service.update_time) |t| {
            try jw.objectField("updateTime");
            try jw.write(core.timestamp.format(&buf, t));
        }
        if (service.creator.len > 0) {
            try jw.objectField("creator");
            try jw.write(service.creator);
        }
        if (service.last_modifier.len > 0) {
            try jw.objectField("lastModifier");
            try jw.write(service.last_modifier);
        }
        if (service.traffic.len > 0) {
            try jw.objectField("traffic");
            try writeTraffic(jw, service.traffic, false);
        }
        if (service.urls.len > 0) {
            try jw.objectField("urls");
            try jw.beginArray();
            for (service.urls) |url| try jw.write(url);
            try jw.endArray();
        }
        if (service.observed_generation) |n| {
            try jw.objectField("observedGeneration");
            try jw.print("\"{d}\"", .{n});
        }
        if (service.terminal_condition) |condition| {
            try jw.objectField("terminalCondition");
            try writeCondition(jw, condition);
        }
        if (service.conditions.len > 0) {
            try jw.objectField("conditions");
            try jw.beginArray();
            for (service.conditions) |condition| try writeCondition(jw, condition);
            try jw.endArray();
        }
        if (service.latest_ready_revision.len > 0) {
            try jw.objectField("latestReadyRevision");
            try jw.print("\"{s}/revisions/{s}\"", .{ service.name, service.latest_ready_revision });
        }
        if (service.latest_created_revision.len > 0) {
            try jw.objectField("latestCreatedRevision");
            try jw.print("\"{s}/revisions/{s}\"", .{ service.name, service.latest_created_revision });
        }
        if (service.traffic_statuses.len > 0) {
            try jw.objectField("trafficStatuses");
            try writeTraffic(jw, service.traffic_statuses, true);
        }
        if (service.uri.len > 0) {
            try jw.objectField("uri");
            try jw.write(service.uri);
        }
        if (service.reconciling) {
            try jw.objectField("reconciling");
            try jw.write(true);
        }
        try jw.endObject();
    }

    fn writeRevision(jw: *Stringify, revision: *const FakeRevision) Stringify.Error!void {
        var buf: [core.timestamp.max_len]u8 = undefined;
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(revision.name);
        if (revision.generation) |n| {
            try jw.objectField("generation");
            try jw.print("\"{d}\"", .{n});
        }
        if (revision.labels.len > 0) {
            try jw.objectField("labels");
            try writeLabelObject(jw, revision.labels);
        }
        if (revision.create_time) |t| {
            try jw.objectField("createTime");
            try jw.write(core.timestamp.format(&buf, t));
        }
        if (revision.update_time) |t| {
            try jw.objectField("updateTime");
            try jw.write(core.timestamp.format(&buf, t));
        }
        try jw.objectField("service");
        try jw.write(revision.service);
        if (revision.service_account.len > 0) {
            try jw.objectField("serviceAccount");
            try jw.write(revision.service_account);
        }
        if (revision.containers.len > 0) {
            try jw.objectField("containers");
            try jw.beginArray();
            for (revision.containers) |container| {
                try jw.beginObject();
                if (container.name.len > 0) {
                    try jw.objectField("name");
                    try jw.write(container.name);
                }
                try jw.objectField("image");
                try jw.write(container.image);
                try jw.endObject();
            }
            try jw.endArray();
        }
        if (revision.conditions.len > 0) {
            try jw.objectField("conditions");
            try jw.beginArray();
            for (revision.conditions) |condition| try writeCondition(jw, condition);
            try jw.endArray();
        }
        if (revision.log_uri.len > 0) {
            try jw.objectField("logUri");
            try jw.write(revision.log_uri);
        }
        try jw.endObject();
    }

    fn writeTraffic(jw: *Stringify, targets: []const types.TrafficTarget, with_uri: bool) Stringify.Error!void {
        try jw.beginArray();
        for (targets) |target| {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write(switch (target.type) {
                .latest => "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST",
                .revision => "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION",
                else => "TRAFFIC_TARGET_ALLOCATION_TYPE_UNSPECIFIED",
            });
            if (target.revision.len > 0) {
                try jw.objectField("revision");
                try jw.write(target.revision);
            }
            if (target.percent != 0) {
                try jw.objectField("percent");
                try jw.print("{d}", .{target.percent});
            }
            if (target.tag.len > 0) {
                try jw.objectField("tag");
                try jw.write(target.tag);
            }
            if (with_uri and target.uri.len > 0) {
                try jw.objectField("uri");
                try jw.write(target.uri);
            }
            try jw.endObject();
        }
        try jw.endArray();
    }

    fn writeCondition(jw: *Stringify, condition: types.Condition) Stringify.Error!void {
        try jw.beginObject();
        if (condition.type.len > 0) {
            try jw.objectField("type");
            try jw.write(condition.type);
        }
        try jw.objectField("state");
        try jw.write(switch (condition.state) {
            .succeeded => "CONDITION_SUCCEEDED",
            .failed => "CONDITION_FAILED",
            .pending => "CONDITION_PENDING",
            .reconciling => "CONDITION_RECONCILING",
            else => "STATE_UNSPECIFIED",
        });
        if (condition.message.len > 0) {
            try jw.objectField("message");
            try jw.write(condition.message);
        }
        if (condition.last_transition_time) |t| {
            var buf: [core.timestamp.max_len]u8 = undefined;
            try jw.objectField("lastTransitionTime");
            try jw.write(core.timestamp.format(&buf, t));
        }
        if (condition.severity != .unspecified) {
            try jw.objectField("severity");
            try jw.write(switch (condition.severity) {
                .@"error" => "ERROR",
                .warning => "WARNING",
                .info => "INFO",
                else => "SEVERITY_UNSPECIFIED",
            });
        }
        if (condition.reason.len > 0) {
            try jw.objectField("reason");
            try jw.write(condition.reason);
        }
        try jw.endObject();
    }

    fn writeLabelObject(jw: *Stringify, labels: []const types.Label) Stringify.Error!void {
        try jw.beginObject();
        for (labels) |l| {
            try jw.objectField(l.key);
            try jw.write(l.value);
        }
        try jw.endObject();
    }

    fn stringLess(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    // Routes and parameters.

    const Route = struct {
        project: []const u8,
        kind: union(enum) {
            locations,
            services: []const u8,
            service: struct { location: []const u8, id: []const u8 },
            revisions: struct { location: []const u8, service: []const u8 },
            revision: struct { location: []const u8, service: []const u8, id: []const u8 },
        },
    };

    fn pathOf(url: []const u8) []const u8 {
        const scheme = std.mem.indexOf(u8, url, "://") orelse return url;
        const rest = url[scheme + 3 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "/";
        return rest[slash..];
    }

    fn parseRoute(path: []const u8) ?Route {
        // v1's one path, the locations list.
        if (std.mem.startsWith(u8, path, "/v1/projects/")) {
            var parts = std.mem.splitScalar(u8, path["/v1/projects/".len..], '/');
            const project = parts.next() orelse return null;
            if (!std.mem.eql(u8, parts.next() orelse return null, "locations")) return null;
            if (parts.next() != null) return null;
            return .{ .project = project, .kind = .locations };
        }
        if (!std.mem.startsWith(u8, path, "/v2/projects/")) return null;
        var parts = std.mem.splitScalar(u8, path["/v2/projects/".len..], '/');
        const project = parts.next() orelse return null;
        if (!std.mem.eql(u8, parts.next() orelse return null, "locations")) return null;
        const location = parts.next() orelse return null;
        if (!std.mem.eql(u8, parts.next() orelse return null, "services")) return null;
        const service_id = parts.next() orelse return .{ .project = project, .kind = .{ .services = location } };
        const revisions_word = parts.next() orelse return .{ .project = project, .kind = .{ .service = .{ .location = location, .id = service_id } } };
        if (!std.mem.eql(u8, revisions_word, "revisions")) return null;
        const revision_id = parts.next() orelse return .{ .project = project, .kind = .{ .revisions = .{ .location = location, .service = service_id } } };
        if (parts.next() != null) return null;
        return .{ .project = project, .kind = .{ .revision = .{ .location = location, .service = service_id, .id = revision_id } } };
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

    const Window = struct { from: usize, to: usize, next: ?usize };

    fn pageOf(params: []const Param, total: usize, max: usize) ?Window {
        var size = max;
        if (paramOf(params, "pageSize")) |text| {
            const n = std.fmt.parseInt(usize, text, 10) catch return null;
            if (n != 0) size = @min(n, max);
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
        return fail(arena, 400, "INVALID_ARGUMENT", "Invalid page token or page size.");
    }

    fn fail(arena: Allocator, code: u16, status: []const u8, message: []const u8) Allocator.Error!Reply {
        return .{ .status = code, .body = try Stringify.valueAlloc(arena, .{ .@"error" = .{
            .code = code,
            .message = message,
            .status = status,
        } }, .{}) };
    }

    fn notModelled(arena: Allocator, what: []const u8) Allocator.Error!Reply {
        return fail(arena, 501, "UNIMPLEMENTED", try arena.print("fake: {s} is not modelled yet", .{what}));
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
    fake: FakeRun,
    token: core.StaticToken,
    diag: core.Diagnostics,
    client: Client,

    fn init(b: *Bench, options: FakeRun.Options) !void {
        b.* = .{ .clock = .{}, .fake = undefined, .token = .{ .token = "t" }, .diag = .{}, .client = undefined };
        b.fake = .init(testing.allocator, b.clock.io(), options);
        errdefer b.fake.deinit();
        b.client = try .init(testing.allocator, b.clock.io(), .{
            .project_id = options.project_id,
            .token_provider = b.token.provider(),
            .transport = b.fake.transport(),
            .diagnostics = &b.diag,
            .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
        });
    }

    fn deinit(b: *Bench) void {
        b.client.deinit();
        b.fake.deinit();
    }

    fn raw(b: *Bench, arena: Allocator, method: tp.Method, path: []const u8) !FakeRun.Reply {
        return b.fake.serve(.{ .method = method, .url = path, .bearer = "t" }, arena);
    }
};

fn ts(text: []const u8) std.Io.Timestamp {
    return core.timestamp.parse(text) catch unreachable;
}

/// The probe's service and both revisions, as production answered them
/// after the bad deploy, fed back through `putService` and `putRevision`.
fn seedProbe(fake: *FakeRun) !void {
    try fake.putLocation("us-central1");
    _ = try fake.putService(.{
        .location = "us-central1",
        .id = "zigps-a12c61",
        .uri = "https://zigps-a12c61-el44yx5gia-uc.a.run.app",
        .urls = &.{ "https://zigps-a12c61-82150720798.us-central1.run.app", "https://zigps-a12c61-el44yx5gia-uc.a.run.app" },
        .latest_ready_revision = "zigps-a12c61-00001-ct8",
        .latest_created_revision = "zigps-a12c61-00002-qmv",
        .traffic = &.{.{ .type = .latest, .percent = 100 }},
        .traffic_statuses = &.{.{ .type = .latest, .revision = "zigps-a12c61-00001-ct8", .percent = 100 }},
        .terminal_condition = .{ .type = "Ready", .state = .failed, .message = "Image 'us-docker.pkg.dev/cloudrun/container/hello:zigps-no-such-tag' not found.", .reason = "REVISION_FAILED", .last_transition_time = ts("2026-10-19T19:32:39.040916Z") },
        .conditions = &.{
            .{ .type = "RoutesReady", .state = .succeeded, .last_transition_time = ts("2026-10-19T19:32:36.714800Z") },
            .{ .type = "ConfigurationsReady", .state = .failed, .last_transition_time = ts("2026-10-19T19:32:38.903177Z") },
        },
        .create_time = ts("2026-10-19T19:32:31.428729Z"),
        .update_time = ts("2026-10-19T19:32:38.561685Z"),
        .creator = "zig-gcp@extractctl.iam.gserviceaccount.com",
        .generation = 2,
        .observed_generation = 2,
        .labels = &.{.{ .key = "zigps", .value = "probe" }},
    });
    _ = try fake.putRevision(.{
        .location = "us-central1",
        .service = "zigps-a12c61",
        .id = "zigps-a12c61-00001-ct8",
        .create_time = ts("2026-10-19T19:32:31.559921Z"),
        .generation = 1,
        .containers = &.{.{ .name = "hello-1", .image = "us-docker.pkg.dev/cloudrun/container/hello@sha256:efd04605322d5d1ce6b1fd3dfc63a9c1fb2b99c97194ec316c0df0fd8f5dcf01" }},
        .conditions = &.{.{ .type = "Ready", .state = .succeeded, .message = "Deploying revision succeeded in 3.77s.", .last_transition_time = ts("2026-10-19T19:32:35.332279Z") }},
        .log_uri = "https://console.cloud.google.com/logs/viewer?project=extractctl",
    });
    _ = try fake.putRevision(.{
        .location = "us-central1",
        .service = "zigps-a12c61",
        .id = "zigps-a12c61-00002-qmv",
        .create_time = ts("2026-10-19T19:32:38.561685Z"),
        .generation = 2,
        .containers = &.{.{ .name = "hello-1", .image = "us-docker.pkg.dev/cloudrun/container/hello:zigps-no-such-tag" }},
        .conditions = &.{.{ .type = "Ready", .state = .failed, .message = "Image 'us-docker.pkg.dev/cloudrun/container/hello:zigps-no-such-tag' not found.", .last_transition_time = ts("2026-10-19T19:32:38.903177Z") }},
    });
}

test "the probe's service put in, read back as production answered it" {
    var b: Bench = undefined;
    try b.init(.{ .project_id = "extractctl" });
    defer b.deinit();
    try seedProbe(&b.fake);
    try testing.expectEqual(1, b.fake.serviceCount());
    try testing.expectEqual(2, b.fake.revisionCount());

    // Field for field what production.service_failed decodes to, for
    // everything the fake's put covers.
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const wanted = try codec.decodeService(out.allocator(), scratch.allocator(), production.service_failed);
    var got = try b.client.getService("us-central1", "zigps-a12c61");
    defer got.deinit();
    try testing.expectEqualStrings(wanted.name, got.value.name);
    try testing.expectEqualStrings(wanted.id, got.value.id);
    try testing.expectEqual(wanted.ready(), got.value.ready());
    try testing.expectEqual(wanted.terminal_condition.?.state, got.value.terminal_condition.?.state);
    try testing.expectEqualStrings(wanted.terminal_condition.?.reason, got.value.terminal_condition.?.reason);
    try testing.expectEqualStrings(wanted.terminal_condition.?.message, got.value.terminal_condition.?.message);
    try testing.expectEqualStrings(wanted.latest_ready_revision, got.value.latest_ready_revision);
    try testing.expectEqualStrings(wanted.latest_created_revision, got.value.latest_created_revision);
    try testing.expectEqualStrings(wanted.uri, got.value.uri);

    // The revisions, newest first as production answered them, through
    // the service and through services/-.
    var revisions = try b.client.listRevisions("us-central1", "zigps-a12c61", .{});
    defer revisions.deinit();
    try testing.expectEqual(2, revisions.value.revisions.len);
    try testing.expectEqualStrings("zigps-a12c61-00002-qmv", revisions.value.revisions[0].id);
    try testing.expect(!revisions.value.revisions[0].ready());
    try testing.expect(std.mem.indexOf(u8, revisions.value.revisions[0].readyCondition().?.message, "zigps-no-such-tag") != null);
    try testing.expect(revisions.value.revisions[1].ready());
    var everywhere = try b.client.listRevisions("us-central1", "-", .{});
    defer everywhere.deinit();
    try testing.expectEqual(2, everywhere.value.revisions.len);
    var by_name = try b.client.getRevisionNamed("projects/extractctl/locations/us-central1/services/zigps-a12c61/revisions/zigps-a12c61-00001-ct8");
    defer by_name.deinit();
    try testing.expect(by_name.value.ready());
    // On the wire the latest revisions carry their full names, as
    // production sends them; the client trims to the id either way.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const raw_service = try b.raw(arena.allocator(), .GET, "https://host/v2/projects/extractctl/locations/us-central1/services/zigps-a12c61");
    try testing.expectEqual(200, raw_service.status);
    try testing.expect(std.mem.indexOf(u8, raw_service.body, "\"latestReadyRevision\":\"projects/extractctl/locations/us-central1/services/zigps-a12c61/revisions/zigps-a12c61-00001-ct8\"") != null);
    try testing.expect(std.mem.startsWith(u8, by_name.value.containers[0].image, "us-docker.pkg.dev/cloudrun/container/hello@sha256:"));
}

test "locations, the - location, pages and refusals as production answered" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us-east1");
    try b.fake.putLocation("us-central1");
    try b.fake.setUnreachable(&.{ "europe-west15", "me-central2" });
    for ([_][]const u8{ "svc-c", "svc-a" }) |id| {
        _ = try b.fake.putService(.{ .location = "us-central1", .id = id, .terminal_condition = .{ .type = "Ready", .state = .succeeded } });
    }
    _ = try b.fake.putService(.{ .location = "us-east1", .id = "svc-b", .terminal_condition = .{ .type = "Ready", .state = .succeeded } });

    var locations = try b.client.listLocations(.{});
    defer locations.deinit();
    try testing.expectEqual(2, locations.value.locations.len);
    try testing.expectEqualStrings("us-central1", locations.value.locations[0].id);

    // One region: sorted by name, paged with a token.
    var page = try b.client.listServices("us-central1", .{ .page_size = 1 });
    defer page.deinit();
    try testing.expectEqual(1, page.value.services.len);
    try testing.expectEqualStrings("svc-a", page.value.services[0].id);
    // A regional listing names no unreachable regions: only '-' does.
    try testing.expectEqual(0, page.value.unreachable_regions.len);
    var rest = try b.client.listServices("us-central1", .{ .page_size = 1, .page_token = page.value.next_page_token.? });
    defer rest.deinit();
    try testing.expectEqualStrings("svc-c", rest.value.services[0].id);
    try testing.expectEqual(null, rest.value.next_page_token);

    // The - location: every region, with the unreachable regions named.
    var everywhere = try b.client.listServices("-", .{});
    defer everywhere.deinit();
    try testing.expectEqual(3, everywhere.value.services.len);
    try testing.expectEqual(2, everywhere.value.unreachable_regions.len);
    try testing.expectEqualStrings("europe-west15", everywhere.value.unreachable_regions[0]);

    // An empty region is {}, and so are an unknown service's revisions.
    var empty = try b.client.listRevisions("us-east1", "zigps-nobody", .{});
    defer empty.deinit();
    try testing.expectEqual(0, empty.value.revisions.len);

    // Production's words for what it refused.
    try testing.expectError(error.InvalidArgument, b.client.listServices("us-fake1", .{}));
    try testing.expectEqualStrings("The request has errors", b.diag.message());
    try testing.expectError(error.NotFound, b.client.getService("us-central1", "zigps-nobody"));
    try testing.expectEqualStrings("Resource 'zigps-nobody' of kind 'SERVICE' in region 'us-central1' in project 'my-project' does not exist.", b.diag.message());
    try testing.expectError(error.NotFound, b.client.getRevision("us-central1", "svc-a", "nobody"));
    try testing.expectEqualStrings("Resource 'nobody' of kind 'REVISION' in region 'us-central1' in project 'my-project' does not exist.", b.diag.message());
}

test "what the puts refuse, nothing kept; writes and other projects 501" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try testing.expectError(error.InvalidEntry, b.fake.putLocation("-"));
    try b.fake.putLocation("us-central1");
    try testing.expectError(error.InvalidEntry, b.fake.putLocation("us-central1"));
    try testing.expectError(error.InvalidEntry, b.fake.putService(.{ .location = "nowhere1", .id = "s" }));
    try testing.expectError(error.InvalidEntry, b.fake.putService(.{ .location = "us-central1", .id = "-" }));
    try testing.expectError(error.InvalidEntry, b.fake.putService(.{ .location = "us-central1", .id = "a/b" }));
    _ = try b.fake.putService(.{ .location = "us-central1", .id = "taken" });
    try testing.expectError(error.InvalidEntry, b.fake.putService(.{ .location = "us-central1", .id = "taken" }));
    try testing.expectError(error.InvalidEntry, b.fake.putRevision(.{ .location = "us-central1", .service = "nobody", .id = "r" }));
    try testing.expectError(error.InvalidEntry, b.fake.putRevision(.{ .location = "us-central1", .service = "taken", .id = "-" }));
    _ = try b.fake.putRevision(.{ .location = "us-central1", .service = "taken", .id = "taken-00001-ab" });
    try testing.expectError(error.InvalidEntry, b.fake.putRevision(.{ .location = "us-central1", .service = "taken", .id = "taken-00001-ab" }));
    try testing.expectEqual(1, b.fake.serviceCount());
    try testing.expectEqual(1, b.fake.revisionCount());

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const write = try b.raw(arena.allocator(), .POST, "https://host/v2/projects/my-project/locations/us-central1/services");
    try testing.expectEqual(501, write.status);
    const other = try b.raw(arena.allocator(), .GET, "https://host/v2/projects/other/locations/us-central1/services");
    try testing.expectEqual(501, other.status);
    const bare = b.fake.serve(.{ .method = .GET, .url = "https://host/v2/projects/my-project/locations/us-central1/services" }, arena.allocator());
    try testing.expectEqual(401, (try bare).status);
}

test "faults on request: dropped, refused and lost answers" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.fake.putLocation("us-central1");
    _ = try b.fake.putService(.{ .location = "us-central1", .id = "s" });

    b.fake.dropNext(1);
    var got = try b.client.getService("us-central1", "s");
    got.deinit();
    b.fake.refuseNext(1, 403);
    try testing.expectError(error.PermissionDenied, b.client.getService("us-central1", "s"));
    b.fake.loseNext(1, 500);
    var again = try b.client.getService("us-central1", "s");
    again.deinit();
    try testing.expect(b.fake.callCount() >= 5);
}
