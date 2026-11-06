//! Service Usage in memory, for tests of code that asks which APIs a
//! project has enabled: behind `Client.Options.transport`, it answers the
//! module's calls as production answered them when measured on 2026-11-06.
//!
//! - Services are put in by the test (`putService`), each enabled or
//!   disabled; `setState` stands in for enabling or disabling one
//!   elsewhere. Nothing changes on its own.
//! - Names carry the project by number (`Options.project_number`), as
//!   production's do; a path may name the project by id or number. A
//!   batch get takes a name under any project as one under its own, as
//!   production did.
//! - Lists are in name order, by the three filters production takes,
//!   50 to a page unless asked (production answered its 45 enabled ones
//!   on one page, so its own size for that list was not seen past 45).
//!   The enabled list's page tokens are production's offset form,
//!   `enabled-services-offset:N` in base64 (production also answered a
//!   cursor form, 13 calls in 30); the other lists' are the fake's own,
//!   which either of the two takes (production's disabled list took the
//!   unfiltered list's).
//! - Answers are written as production writes them under the client's
//!   fields masks, byte for byte: `documentation` is `{}` with no
//!   summary, and an empty title is left out.
//! - Refused in production's words, with its ErrorInfo reason and
//!   metadata (its PreconditionFailure and per-call Help Token left out):
//!   a service nobody put, a project not the fake's, no credentials, a
//!   filter, page size or page token production refuses, and a batch of
//!   none, of more than 30, or of a name with no project. Faults a test
//!   asks for: refusals and dropped connections.
//!
//! Not modelled, answered 501 with the reason: a service's whole
//! configuration (a call without the client's fields mask, or with
//! another), a short name such as `pubsub`, which production answered as
//! `pubsub.googleapis.com` but `storage` as unknown, enabling and
//! disabling, operations, quotas, and folders or organizations.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const core = @import("core");
const tp = core.transport;
const codec = @import("codec.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");

pub const FakeServiceUsage = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    options: Options,
    /// Strings, freed with the fake.
    store: std.heap.ArenaAllocator,
    /// In name order.
    services: std.ArrayList(Held) = .empty,
    faults: [2]Fault = .{ .{}, .{} },
    calls: usize = 0,

    const Held = struct { name: []const u8, title: []const u8, summary: []const u8, state: types.State };

    const Fault = struct { n: usize = 0, status: u16 = 0 };
    const refuse = 0;
    const drop = 1;

    pub const Options = struct {
        /// The project, by id: what paths may name.
        project_id: []const u8 = "my-project",
        /// The project, by number: what names carry, as production's do.
        project_number: []const u8 = "123456789012",
    };

    pub const Reply = struct { status: u16, headers: []const tp.Header = &.{}, body: []const u8 };

    pub fn init(gpa: Allocator, io: std.Io, options: Options) FakeServiceUsage {
        return .{ .gpa = gpa, .io = io, .options = options, .store = .init(gpa) };
    }

    pub fn deinit(f: *FakeServiceUsage) void {
        f.services.deinit(f.gpa);
        f.store.deinit();
        f.* = undefined;
    }

    /// Goes into `Client.Options.transport`.
    pub fn transport(f: *FakeServiceUsage) tp.Transport {
        return .{ .ptr = f, .vtable = &.{ .send = send } };
    }

    // Faults, each for the next `n` calls.

    /// Answers them with `status`.
    pub fn refuseNext(f: *FakeServiceUsage, n: usize, status: u16) void {
        f.setFault(refuse, .{ .n = n, .status = status });
    }

    /// Closes their connection before any answer.
    pub fn dropNext(f: *FakeServiceUsage, n: usize) void {
        f.setFault(drop, .{ .n = n });
    }

    fn setFault(f: *FakeServiceUsage, slot: usize, fault: Fault) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.faults[slot] = fault;
    }

    fn takeFault(f: *FakeServiceUsage, slot: usize) ?Fault {
        const fault = &f.faults[slot];
        if (fault.n == 0) return null;
        fault.n -= 1;
        return fault.*;
    }

    /// Calls served, refusals included.
    pub fn callCount(f: *FakeServiceUsage) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.calls;
    }

    // What a test puts in.

    pub const PutError = error{ OutOfMemory, InvalidEntry };

    pub const PutService = struct {
        /// Such as `pubsub.googleapis.com`: what the client takes.
        name: []const u8,
        title: []const u8 = "",
        summary: []const u8 = "",
        /// `.enabled` or `.disabled`.
        state: types.State = .disabled,
    };

    /// A service of the project, enabled or not. A name the client would
    /// refuse, one put already, or `.unknown` is `error.InvalidEntry`.
    pub fn putService(f: *FakeServiceUsage, s: PutService) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (validate.serviceNameProblem(s.name) != null or s.state == .unknown) return error.InvalidEntry;
        const at = f.place(s.name);
        if (at < f.services.items.len and std.mem.eql(u8, f.services.items[at].name, s.name)) return error.InvalidEntry;
        const a = f.store.allocator();
        try f.services.insert(f.gpa, at, .{
            .name = try a.dupe(u8, s.name),
            .title = try a.dupe(u8, s.title),
            .summary = try a.dupe(u8, s.summary),
            .state = s.state,
        });
    }

    /// Enables or disables a service put before, as the console or gcloud
    /// would.
    pub fn setState(f: *FakeServiceUsage, name: []const u8, state: types.State) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (state == .unknown) return error.InvalidEntry;
        const held = f.find(name) orelse return error.InvalidEntry;
        held.state = state;
    }

    /// Where `name` is, or would go, in name order.
    fn place(f: *FakeServiceUsage, name: []const u8) usize {
        return std.sort.lowerBound(Held, f.services.items, name, struct {
            fn order(n: []const u8, h: Held) std.math.Order {
                return std.mem.order(u8, n, h.name);
            }
        }.order);
    }

    fn find(f: *FakeServiceUsage, name: []const u8) ?*Held {
        const at = f.place(name);
        if (at < f.services.items.len and std.mem.eql(u8, f.services.items[at].name, name)) return &f.services.items[at];
        return null;
    }

    // The transport.

    fn send(ptr: *anyopaque, req: tp.Request, arena: Allocator) tp.Error!tp.Response {
        const f: *FakeServiceUsage = @ptrCast(@alignCast(ptr));
        const reply = try f.serve(req, arena);
        return .{ .status = reply.status, .headers = reply.headers, .body = reply.body };
    }

    /// One request, as `send` serves it: for a test that wants to send
    /// what no client would.
    pub fn serve(f: *FakeServiceUsage, req: tp.Request, arena: Allocator) tp.Error!Reply {
        const path = pathOf(req.url);
        const q_at = std.mem.indexOfScalar(u8, path, '?');
        const route_text = path[0 .. q_at orelse path.len];
        const query = if (q_at) |q| path[q + 1 ..] else "";
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.calls += 1;
        if (f.takeFault(drop) != null) return error.ConnectionResetByPeer;
        if (f.takeFault(refuse)) |fault| return refusal(arena, fault.status);
        return f.route(req, arena, route_text, query);
    }

    fn route(f: *FakeServiceUsage, req: tp.Request, arena: Allocator, route_text: []const u8, query: []const u8) Allocator.Error!Reply {
        if (req.bearer == null) return fail(arena, 403, "PERMISSION_DENIED", "Method doesn't allow unregistered callers (callers without established identity). Please use API Key or other form of API consumer identity to call this API.", null);
        const target = try parseRoute(arena, route_text) orelse return notModelled(arena, "this path");
        if (!std.mem.eql(u8, target.project, f.options.project_id) and !std.mem.eql(u8, target.project, f.options.project_number)) {
            return fail(arena, 403, "PERMISSION_DENIED", try arena.print("Project '{s}' not found or permission denied.", .{target.project}), .{
                .reason = "RESOURCES_NOT_FOUND",
                .metadata = &.{ .{ "type", "Project" }, .{ "resource_id", target.project } },
            });
        }
        if (req.method != .GET) return notModelled(arena, "anything but a read");
        const params = try parseParams(arena, query) orelse return notModelled(arena, "a query string that is not name=value pairs");
        const mask: []const u8 = switch (target.kind) {
            .list => codec.list_fields,
            .get => codec.service_fields,
            .batch => codec.batch_fields,
        };
        const fields = paramOf(params, "fields") orelse return notModelled(arena, "a service's whole configuration, asked with no fields mask");
        if (!std.mem.eql(u8, fields, mask)) return notModelled(arena, "a fields mask other than the client's");
        return switch (target.kind) {
            .list => f.list(arena, params),
            .get => |name| f.get(arena, name),
            .batch => f.batch(arena, params),
        };
    }

    fn list(f: *FakeServiceUsage, arena: Allocator, params: []const Param) Allocator.Error!Reply {
        const filter = paramOf(params, "filter") orelse "";
        const state: types.StateFilter = if (filter.len == 0)
            .any
        else if (std.mem.eql(u8, filter, "state:ENABLED"))
            .enabled
        else if (std.mem.eql(u8, filter, "state:DISABLED"))
            .disabled
        else
            return fail(arena, 400, "INVALID_ARGUMENT", "Valid values for filter are: '', 'state:ENABLED', 'state:DISABLED'.", .{ .reason = "SU_INVALID_FILTER" });
        var size: usize = default_page_size;
        if (paramOf(params, "pageSize")) |text| {
            const n = std.fmt.parseInt(i64, text, 10) catch return unmeasured(arena, "a page size that is no integer");
            if (n < 0 or n > validate.max_page_size) return fail(arena, 400, "INVALID_ARGUMENT", "Invalid page size, should be in [0, 200].", .{
                .reason = "SU_INVALID_PAGE_SIZE",
                .metadata = &.{.{ "max", "200" }},
            });
            if (n > 0) size = @intCast(n);
        }
        var from: usize = 0;
        if (paramOf(params, "pageToken")) |t| if (t.len > 0) {
            from = try f.tokenStart(arena, state, t) orelse return pageTokenRefusal(arena, state, t);
        };
        var page: std.ArrayList(Held) = .empty;
        var i = from;
        var last: usize = from;
        while (i < f.services.items.len and page.items.len < size) : (i += 1) {
            const s = f.services.items[i];
            if (!passes(state, s.state)) continue;
            try page.append(arena, s);
            last = i + 1;
        }
        // A next page only when another service passes after this one.
        var more = false;
        for (f.services.items[last..]) |s| if (passes(state, s.state)) {
            more = true;
            break;
        };
        const next: ?[]const u8 = if (!more) null else switch (state) {
            .enabled => try enabledToken(arena, f.countBefore(.enabled, last)),
            .disabled, .any => try afterToken(arena, f.services.items[last - 1].name),
        };
        return f.writeList(arena, page.items, next);
    }

    const default_page_size = 50;

    fn passes(filter: types.StateFilter, state: types.State) bool {
        return switch (filter) {
            .enabled => state == .enabled,
            .disabled => state == .disabled,
            .any => true,
        };
    }

    /// How many services before index `end` pass `filter`.
    fn countBefore(f: *FakeServiceUsage, filter: types.StateFilter, end: usize) usize {
        var n: usize = 0;
        for (f.services.items[0..end]) |s| {
            if (passes(filter, s.state)) n += 1;
        }
        return n;
    }

    /// The index a page token starts at, or null when the list does not
    /// take it.
    fn tokenStart(f: *FakeServiceUsage, arena: Allocator, filter: types.StateFilter, t: []const u8) Allocator.Error!?usize {
        const text = try unbase64(arena, t) orelse return null;
        switch (filter) {
            .enabled => {
                if (!std.mem.startsWith(u8, text, enabled_prefix)) return null;
                const skip = std.fmt.parseInt(usize, text[enabled_prefix.len..], 10) catch return null;
                // The offset counts enabled services.
                var seen: usize = 0;
                for (f.services.items, 0..) |s, i| {
                    if (seen == skip) return i;
                    if (s.state == .enabled) seen += 1;
                }
                return if (seen == skip) f.services.items.len else null;
            },
            .disabled, .any => {
                if (!std.mem.startsWith(u8, text, after_prefix)) return null;
                const name = text[after_prefix.len..];
                return std.sort.upperBound(Held, f.services.items, name, struct {
                    fn order(n: []const u8, h: Held) std.math.Order {
                        return std.mem.order(u8, n, h.name);
                    }
                }.order);
            },
        }
    }

    const enabled_prefix = "enabled-services-offset:";
    const after_prefix = "zigps-fake-services-after:";

    fn enabledToken(arena: Allocator, offset: usize) Allocator.Error![]const u8 {
        return base64(arena, try arena.print(enabled_prefix ++ "{d}", .{offset}));
    }

    fn afterToken(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
        return base64(arena, try arena.print(after_prefix ++ "{s}", .{name}));
    }

    fn base64(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
        const enc = std.base64.standard.Encoder;
        const out = try arena.alloc(u8, enc.calcSize(text.len));
        return enc.encode(out, text);
    }

    fn unbase64(arena: Allocator, t: []const u8) Allocator.Error!?[]const u8 {
        const dec = std.base64.standard.Decoder;
        const n = dec.calcSizeForSlice(t) catch return null;
        const out = try arena.alloc(u8, n);
        dec.decode(out, t) catch return null;
        return out;
    }

    /// Production's two refusals of a page token: the enabled list's token
    /// under another filter says so with a colon; any other token, without.
    fn pageTokenRefusal(arena: Allocator, filter: types.StateFilter, t: []const u8) Allocator.Error!Reply {
        const enabled_form = if (try unbase64(arena, t)) |text| std.mem.startsWith(u8, text, enabled_prefix) else false;
        if (filter != .enabled and enabled_form) {
            return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Invalid page token: '{s}'.", .{t}), .{
                .reason = "SU_INVALID_PAGE_TOKEN",
                .metadata = &.{.{ "token", t }},
            });
        }
        return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Invalid page token '{s}'.", .{t}), .{
            .reason = "STORAGE_INVALID_PAGE_TOKEN",
            .metadata = &.{.{ "token", t }},
        });
    }

    fn get(f: *FakeServiceUsage, arena: Allocator, name: []const u8) Allocator.Error!Reply {
        if (name.len == 0) return notModelled(arena, "an empty service name, which production answered as the unfiltered list");
        const held = f.find(name) orelse return unknownService(arena, name);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        f.writeService(&jw, held.*) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn batch(f: *FakeServiceUsage, arena: Allocator, params: []const Param) Allocator.Error!Reply {
        var names: std.ArrayList([]const u8) = .empty;
        for (params) |p| if (std.mem.eql(u8, p.name, "names")) try names.append(arena, p.value);
        if (names.items.len == 0) return fail(arena, 400, "INVALID_ARGUMENT", "Name(s) should not be empty.", .{ .reason = "SU_MISSING_NAMES" });
        if (names.items.len > validate.max_batch) return fail(arena, 400, "INVALID_ARGUMENT", "Number of services must not exceed the maximum batch size (30).", .{
            .reason = "SU_MAX_BATCH_SIZE_EXCEEDED",
            .metadata = &.{.{ "max", "30" }},
        });
        const found = try arena.alloc(Held, names.items.len);
        for (names.items, found) |n, *out| {
            const parsed = codec.parseName(n) orelse return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Invalid parent format \"{s}\".", .{n}), .{
                .reason = "API_SHARED_INVALID_PARENT_FORMAT",
                .metadata = &.{.{ "parent", n }},
            });
            out.* = (f.find(parsed.service) orelse return unknownService(arena, parsed.service)).*;
        }
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeBatch(f, &jw, found) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn writeBatch(f: *FakeServiceUsage, jw: *Stringify, found: []const Held) Stringify.Error!void {
        try jw.beginObject();
        if (found.len > 0) {
            try jw.objectField("services");
            try jw.beginArray();
            for (found) |s| try f.writeService(jw, s);
            try jw.endArray();
        }
        try jw.endObject();
    }

    fn writeList(f: *FakeServiceUsage, arena: Allocator, page: []const Held, next: ?[]const u8) Allocator.Error!Reply {
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        f.writePage(&jw, page, next) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn writePage(f: *FakeServiceUsage, jw: *Stringify, page: []const Held, next: ?[]const u8) Stringify.Error!void {
        try jw.beginObject();
        if (page.len > 0) {
            try jw.objectField("services");
            try jw.beginArray();
            for (page) |s| try f.writeService(jw, s);
            try jw.endArray();
        }
        if (next) |t| {
            try jw.objectField("nextPageToken");
            try jw.write(t);
        }
        try jw.endObject();
    }

    /// A service as production writes it under the client's mask:
    /// `{"name":...,"config":{"name":...,"title":...,"documentation":{...}},"state":...}`.
    fn writeService(f: *FakeServiceUsage, jw: *Stringify, s: Held) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.print("\"projects/{s}/services/{s}\"", .{ f.options.project_number, s.name });
        try jw.objectField("config");
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(s.name);
        if (s.title.len > 0) {
            try jw.objectField("title");
            try jw.write(s.title);
        }
        try jw.objectField("documentation");
        try jw.beginObject();
        if (s.summary.len > 0) {
            try jw.objectField("summary");
            try jw.write(s.summary);
        }
        try jw.endObject();
        try jw.endObject();
        try jw.objectField("state");
        try jw.write(s.state.wireName().?);
        try jw.endObject();
    }

    // Routes and parameters.

    const Route = struct {
        project: []const u8,
        kind: union(enum) {
            list,
            /// The name, decoded.
            get: []const u8,
            batch,
        },
    };

    fn pathOf(url: []const u8) []const u8 {
        const scheme = std.mem.indexOf(u8, url, "://") orelse return url;
        const rest = url[scheme + 3 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "/";
        return rest[slash..];
    }

    /// `/v1/projects/{p}/services[/{name}|:batchGet]`, each segment
    /// decoded.
    fn parseRoute(arena: Allocator, path: []const u8) Allocator.Error!?Route {
        const prefix = "/v1/projects/";
        if (!std.mem.startsWith(u8, path, prefix)) return null;
        const rest = path[prefix.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        const project = std.Uri.percentDecodeInPlace(try arena.dupe(u8, rest[0..slash]));
        if (project.len == 0) return null;
        const tail = rest[slash..];
        if (std.mem.eql(u8, tail, "/services")) return .{ .project = project, .kind = .list };
        if (std.mem.eql(u8, tail, "/services:batchGet")) return .{ .project = project, .kind = .batch };
        if (!std.mem.startsWith(u8, tail, "/services/")) return null;
        const name = tail["/services/".len..];
        if (std.mem.indexOfScalar(u8, name, '/') != null) return null;
        return .{ .project = project, .kind = .{ .get = std.Uri.percentDecodeInPlace(try arena.dupe(u8, name)) } };
    }

    const Param = struct { name: []const u8, value: []const u8 };

    fn parseParams(arena: Allocator, query: []const u8) Allocator.Error!?[]const Param {
        var params: std.ArrayList(Param) = .empty;
        if (query.len == 0) return params.items;
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return null;
            try params.append(arena, .{
                .name = std.Uri.percentDecodeInPlace(try arena.dupe(u8, pair[0..eq])),
                .value = std.Uri.percentDecodeInPlace(try arena.dupe(u8, pair[eq + 1 ..])),
            });
        }
        return params.items;
    }

    fn paramOf(params: []const Param, name: []const u8) ?[]const u8 {
        for (params) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
        return null;
    }

    fn unknownService(arena: Allocator, name: []const u8) Allocator.Error!Reply {
        return fail(arena, 403, "PERMISSION_DENIED", try arena.print("Not found or permission denied for service(s): {s}.", .{name}), .{
            .reason = "SERVICE_CONFIG_NOT_FOUND_OR_PERMISSION_DENIED",
            .metadata = &.{.{ "services", name }},
        });
    }

    const Info = struct {
        reason: []const u8,
        metadata: []const [2][]const u8 = &.{},
    };

    /// Service Usage's error body: code, message, status, and an ErrorInfo
    /// in production's domain when it gave one.
    fn fail(arena: Allocator, code: u16, status: []const u8, message: []const u8, info: ?Info) Allocator.Error!Reply {
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeError(&jw, code, status, message, info) catch return error.OutOfMemory;
        return .{ .status = code, .body = out.written() };
    }

    fn writeError(jw: *Stringify, code: u16, status: []const u8, message: []const u8, info: ?Info) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("error");
        try jw.beginObject();
        try jw.objectField("code");
        try jw.write(code);
        try jw.objectField("message");
        try jw.write(message);
        try jw.objectField("status");
        try jw.write(status);
        if (info) |i| {
            try jw.objectField("details");
            try jw.beginArray();
            try jw.beginObject();
            try jw.objectField("@type");
            try jw.write("type.googleapis.com/google.rpc.ErrorInfo");
            try jw.objectField("reason");
            try jw.write(i.reason);
            try jw.objectField("domain");
            try jw.write("serviceusage.googleapis.com");
            if (i.metadata.len > 0) {
                try jw.objectField("metadata");
                try jw.beginObject();
                for (i.metadata) |kv| {
                    try jw.objectField(kv[0]);
                    try jw.write(kv[1]);
                }
                try jw.endObject();
            }
            try jw.endObject();
            try jw.endArray();
        }
        try jw.endObject();
        try jw.endObject();
    }

    fn notModelled(arena: Allocator, what: []const u8) Allocator.Error!Reply {
        return fail(arena, 501, "UNIMPLEMENTED", try arena.print("fake: {s} is not modelled", .{what}), null);
    }

    fn unmeasured(arena: Allocator, what: []const u8) Allocator.Error!Reply {
        return fail(arena, 501, "UNIMPLEMENTED", try arena.print("fake: production's answer to {s} was not measured", .{what}), null);
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
        return fail(arena, status, name, "fake: refused as the test asked", null);
    }
};

// Tests, held to what production answered in milestone 0.

const testing = std.testing;
const production = @import("production_bodies.zig");
const Client = @import("Client.zig");
const test_util = @import("test_util.zig");

const Bench = struct {
    clock: core.testing.FakeClock,
    fake: FakeServiceUsage,
    token: core.StaticToken,
    diag: core.Diagnostics,
    client: Client,

    fn init(b: *Bench, gpa: Allocator, options: FakeServiceUsage.Options) !void {
        b.* = .{ .clock = .{ .now_ns = 1_793_980_800 * std.time.ns_per_s }, .fake = undefined, .token = .{ .token = "t" }, .diag = .{}, .client = undefined };
        b.fake = .init(gpa, b.clock.io(), options);
        errdefer b.fake.deinit();
        b.client = try .init(gpa, b.clock.io(), .{
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

    /// The fake's answer to `path` and `query` under extractctl, as the
    /// client would ask it.
    fn raw(b: *Bench, arena: Allocator, path: []const u8, query: []const u8) !FakeServiceUsage.Reply {
        const url = try std.fmt.allocPrint(arena, "https://serviceusage.googleapis.com/v1/projects/extractctl/services{s}{s}", .{ path, query });
        return b.fake.serve(.{ .method = .GET, .url = url, .bearer = "t" }, arena);
    }
};

const probe: FakeServiceUsage.Options = .{ .project_id = "extractctl", .project_number = "82150720798" };

/// Production's 45 enabled services, and the four disabled ones its
/// disabled list began with, put in as production answered them.
fn seedProbe(fake: *FakeServiceUsage, a: Allocator) !void {
    inline for (.{ production.list_enabled_all, production.list_disabled_page, production.list_disabled_next }) |body| {
        const page = try codec.decodeServicePage(a, a, body);
        for (page.services) |s| try fake.putService(.{ .name = s.name, .title = s.title, .summary = s.summary, .state = s.state });
    }
}

const list_q = "&fields=services%28name%2Cconfig%28name%2Ctitle%2Cdocumentation%2Fsummary%29%2Cstate%29%2CnextPageToken&prettyPrint=false";
const get_q = "?fields=name%2Cconfig%28name%2Ctitle%2Cdocumentation%2Fsummary%29%2Cstate&prettyPrint=false";
const batch_q = "&fields=services%28name%2Cconfig%28name%2Ctitle%2Cdocumentation%2Fsummary%29%2Cstate%29&prettyPrint=false";
const a10 = "a10-thunder-adc-601b150-byol.endpoints.a10networks-public-396315.cloud.goog";

test "lists, gets and batches answer as production did, byte for byte" {
    var b: Bench = undefined;
    try b.init(testing.allocator, probe);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try seedProbe(&b.fake, a);

    const Case = struct { []const u8, []const u8, []const u8 };
    for ([_]Case{
        .{ "?filter=state%3AENABLED&pageSize=3" ++ list_q, "", production.list_enabled_page },
        .{ "?filter=state%3AENABLED&pageSize=3&pageToken=ZW5hYmxlZC1zZXJ2aWNlcy1vZmZzZXQ6Mw%3D%3D" ++ list_q, "", production.list_enabled_next },
        .{ "?filter=state%3AENABLED" ++ list_q, "", production.list_enabled_all },
        .{ "/pubsub.googleapis.com", get_q, production.get_enabled },
        .{ "/backupdr.googleapis.com", get_q, production.get_no_summary },
        .{ "/" ++ a10, get_q, production.get_disabled },
        .{ ":batchGet?names=projects%2Fextractctl%2Fservices%2Fpubsub.googleapis.com&names=projects%2Fextractctl%2Fservices%2F" ++ a10, batch_q, production.batch_two },
        .{ ":batchGet?names=projects%2Fextractctl%2Fservices%2Fpubsub.googleapis.com&names=projects%2Fbigquery-public-data%2Fservices%2Fbigquery.googleapis.com", batch_q, production.batch_other_project_name },
    }) |case| {
        const reply = try b.raw(a, case[0], case[1]);
        try testing.expectEqual(200, reply.status);
        try testing.expectEqualStrings(case[2], reply.body);
    }

    // The other lists' tokens are the fake's own; their services are
    // production's.
    for ([_][2][]const u8{
        .{ "?filter=state%3ADISABLED&pageSize=2" ++ list_q, production.list_disabled_page },
        .{ "?pageSize=2" ++ list_q, production.list_any_page },
    }) |case| {
        const reply = try b.raw(a, case[0], "");
        const got = try codec.decodeServicePage(a, a, reply.body);
        const want = try codec.decodeServicePage(a, a, case[1]);
        try testing.expectEqualDeep(want.services, got.services);
        try testing.expect(got.next_page_token != null);
    }

    // Through the client, every enabled one.
    var all = try b.client.enabledServices();
    defer all.deinit();
    const want = try codec.decodeServicePage(a, a, production.list_enabled_all);
    try testing.expectEqualDeep(want.services, all.value);
}

/// A refusal as a test compares it: the status, production's status
/// word, its message with the per-call Help Token cut, and its ErrorInfo
/// reason and metadata, sorted.
const Refusal = struct {
    code: u16,
    status: []const u8,
    message: []const u8,
    reason: []const u8,
    metadata: []const core.errors.ErrorInfo.Entry,

    fn of(a: Allocator, code: u16, body: []const u8) !Refusal {
        const e = (try core.errors.decodeErrorBody(a, body)).?;
        const infos = try core.errors.decodeErrorInfos(a, body);
        const cut = std.mem.indexOf(u8, e.message, "\nHelp Token: ") orelse e.message.len;
        const metadata: []core.errors.ErrorInfo.Entry = if (infos.len > 0) try a.dupe(core.errors.ErrorInfo.Entry, infos[0].metadata) else &.{};
        std.mem.sort(core.errors.ErrorInfo.Entry, metadata, {}, struct {
            fn less(_: void, x: core.errors.ErrorInfo.Entry, y: core.errors.ErrorInfo.Entry) bool {
                return std.mem.lessThan(u8, x.key, y.key);
            }
        }.less);
        return .{
            .code = code,
            .status = e.status,
            .message = e.message[0..cut],
            .reason = if (infos.len > 0) infos[0].reason else "",
            .metadata = metadata,
        };
    }
};

test "refusals in production's words, reasons and metadata" {
    var b: Bench = undefined;
    try b.init(testing.allocator, probe);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try seedProbe(&b.fake, a);

    var thirty_one: std.Io.Writer.Allocating = .init(a);
    const every = try codec.decodeServicePage(a, a, production.list_enabled_all);
    for (every.services[0..30]) |s| try thirty_one.writer.print("names=projects%2Fextractctl%2Fservices%2F{s}&", .{s.name});
    try thirty_one.writer.writeAll("names=projects%2Fextractctl%2Fservices%2Fpubsub.googleapis.com");

    const Case = struct { []const u8, []const u8, u16, []const u8 };
    for ([_]Case{
        .{ "/zigps-nope-316.googleapis.com", get_q, production.get_unknown_status, production.get_unknown },
        .{ ":batchGet?names=projects%2Fextractctl%2Fservices%2Fzigps-nope-a.googleapis.com&names=projects%2Fextractctl%2Fservices%2Fpubsub.googleapis.com&names=projects%2Fextractctl%2Fservices%2Fzigps-nope-b.googleapis.com", batch_q, production.batch_unknown_two_status, production.batch_unknown_two },
        .{ try std.fmt.allocPrint(a, ":batchGet?{s}", .{thirty_one.written()}), batch_q, production.batch_31_status, production.batch_31 },
        .{ ":batchGet?", batch_q[1..], production.batch_none_status, production.batch_none },
        .{ ":batchGet?names=pubsub.googleapis.com", batch_q, production.batch_bare_name_status, production.batch_bare_name },
        .{ "?filter=state%3AENABLED&pageSize=201" ++ list_q, "", production.page_size_201_status, production.page_size_201 },
        .{ "?filter=state%3Aenabled&pageSize=2" ++ list_q, "", production.filter_lowercase_status, production.filter_lowercase },
        .{ "?filter=state%3AENABLED&pageToken=abc" ++ list_q, "", production.token_garbage_status, production.token_garbage },
        .{ "?pageSize=2&pageToken=ZW5hYmxlZC1zZXJ2aWNlcy1vZmZzZXQ6Mw%3D%3D" ++ list_q, "", production.token_enabled_under_any_status, production.token_enabled_under_any },
        .{ "?filter=state%3AENABLED&pageSize=2&pageToken=Cs8BCAISyAFFa2tLUjNSNWNHVXVaMjl2WjJ4bFlYQnBjeTVqYjIwdloyOXZaMnhsTG1Gd2FTNXpaWEoyYVdObGJXRnVZV2RsYldWdWRDNTJNUzVNYVhOMFUyVnlkbWxqWlhOU1pYRjFaWE4wSWtkaE1UQXRkblJvZFc1a1pYSXRZV1JqTFRFd01HMWljSE11Wlc1a2NHOXBiblJ6TG1FeE1HNWxkSGR2Y210ekxYQjFZbXhwWXkwek9UWXpNVFV1WTJ4dmRXUXVaMjl2Wnc9PSABEhkI____________ARIMCJn8t9cGEOicuOICIAE%3D" ++ list_q, "", production.token_disabled_under_enabled_status, production.token_disabled_under_enabled },
    }) |case| {
        const reply = try b.raw(a, case[0], case[1]);
        const want = try Refusal.of(a, case[2], case[3]);
        const got = try Refusal.of(a, reply.status, reply.body);
        try testing.expectEqualDeep(want, got);
    }

    // A project not the fake's, and no credentials.
    const elsewhere = try b.fake.serve(.{ .method = .GET, .url = "https://serviceusage.googleapis.com/v1/projects/zigps-no-such-project-316/services?filter=state%3AENABLED" ++ list_q, .bearer = "t" }, a);
    try testing.expectEqualDeep(try Refusal.of(a, production.no_such_project_status, production.no_such_project), try Refusal.of(a, elsewhere.status, elsewhere.body));
    const anonymous = try b.fake.serve(.{ .method = .GET, .url = "https://serviceusage.googleapis.com/v1/projects/extractctl/services?filter=state%3AENABLED" ++ list_q }, a);
    try testing.expectEqualDeep(try Refusal.of(a, production.no_credentials_status, production.no_credentials), try Refusal.of(a, anonymous.status, anonymous.body));

    // Through the client, as errors.
    try testing.expectError(error.PermissionDenied, b.client.getService("zigps-nope-316.googleapis.com"));
    try testing.expectEqualStrings("Not found or permission denied for service(s): zigps-nope-316.googleapis.com.", b.diag.message());
    try testing.expectError(error.InvalidArgument, b.client.listServices(.{ .page_token = "abc" }));
    try testing.expectEqualStrings("Invalid page token 'abc'.", b.diag.message());
}

test "a service enabled elsewhere shows in the enabled list, and leaves the disabled one" {
    var b: Bench = undefined;
    try b.init(testing.allocator, .{});
    defer b.deinit();
    try b.fake.putService(.{ .name = "pubsub.googleapis.com", .title = "Cloud Pub/Sub API" });
    var none = try b.client.enabledServices();
    try testing.expectEqual(0, none.value.len);
    none.deinit();
    try b.fake.setState("pubsub.googleapis.com", .enabled);
    var one = try b.client.enabledServices();
    defer one.deinit();
    try testing.expectEqual(1, one.value.len);
    try testing.expectEqualStrings("123456789012", one.value[0].project_number);
    var off = try b.client.listServices(.{ .state = .disabled });
    defer off.deinit();
    try testing.expectEqual(0, off.value.services.len);
    try testing.expectEqual(null, off.value.next_page_token);
    var got = try b.client.getService("pubsub.googleapis.com");
    defer got.deinit();
    try testing.expectEqual(types.State.enabled, got.value.state);
    // The project by number in the path is the same project.
    var by_number = try Client.init(testing.allocator, b.clock.io(), .{ .project_id = "123456789012", .token_provider = b.token.provider(), .transport = b.fake.transport() });
    defer by_number.deinit();
    var again = try by_number.getService("pubsub.googleapis.com");
    defer again.deinit();
    try testing.expectEqualStrings("Cloud Pub/Sub API", again.value.title);
}

test "a batch of 30, the most production takes, answered in the order asked" {
    var b: Bench = undefined;
    try b.init(testing.allocator, .{});
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const names = try a.alloc([]const u8, validate.max_batch);
    for (names, 0..) |*name, i| {
        // Put in name order, asked in reverse.
        const made = try std.fmt.allocPrint(a, "api{d:0>2}.googleapis.com", .{i});
        try b.fake.putService(.{ .name = made, .state = if (i % 2 == 0) .enabled else .disabled });
        name.* = made;
    }
    std.mem.reverse([]const u8, names);
    var got = try b.client.getServices(names);
    defer got.deinit();
    try testing.expectEqual(30, got.value.len);
    for (names, got.value) |want, s| try testing.expectEqualStrings(want, s.name);
    try testing.expectEqual(types.State.disabled, got.value[0].state);
}

test "what a test puts in, the fake checks" {
    var fake: FakeServiceUsage = .init(testing.allocator, std.Io.failing, .{});
    defer fake.deinit();
    try fake.putService(.{ .name = "pubsub.googleapis.com" });
    try testing.expectError(error.InvalidEntry, fake.putService(.{ .name = "pubsub.googleapis.com", .state = .enabled }));
    try testing.expectError(error.InvalidEntry, fake.putService(.{ .name = "Pubsub.googleapis.com" }));
    try testing.expectError(error.InvalidEntry, fake.putService(.{ .name = "" }));
    try testing.expectError(error.InvalidEntry, fake.putService(.{ .name = "x.googleapis.com", .state = .unknown }));
    try testing.expectError(error.InvalidEntry, fake.setState("x.googleapis.com", .enabled));
    try testing.expectError(error.InvalidEntry, fake.setState("pubsub.googleapis.com", .unknown));
}

test "faults a test asks for, and what the fake does not model" {
    var b: Bench = undefined;
    try b.init(testing.allocator, .{});
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try b.fake.putService(.{ .name = "pubsub.googleapis.com", .state = .enabled });

    // A 503 and a dropped connection are retried; a 403 is final.
    b.fake.refuseNext(1, 503);
    var retried = try b.client.getService("pubsub.googleapis.com");
    retried.deinit();
    try testing.expectEqual(2, b.fake.callCount());
    b.fake.dropNext(1);
    var redone = try b.client.listServices(.{});
    redone.deinit();
    try testing.expectEqual(4, b.fake.callCount());
    b.fake.refuseNext(1, 403);
    try testing.expectError(error.PermissionDenied, b.client.getServices(&.{"pubsub.googleapis.com"}));
    try testing.expectEqualStrings("fake: refused as the test asked", b.diag.message());

    const base = "https://serviceusage.googleapis.com/v1/projects/my-project/services";
    const Case = struct { tp.Method, []const u8, []const u8 };
    for ([_]Case{
        .{ .GET, base ++ "/pubsub.googleapis.com", "fake: a service's whole configuration, asked with no fields mask is not modelled" },
        .{ .GET, base ++ "/pubsub.googleapis.com?fields=name", "fake: a fields mask other than the client's is not modelled" },
        .{ .POST, base ++ "/pubsub.googleapis.com:enable", "fake: anything but a read is not modelled" },
        .{ .GET, base ++ "/" ++ get_q, "fake: an empty service name, which production answered as the unfiltered list is not modelled" },
        .{ .GET, base ++ "?pageSize=x" ++ list_q, "fake: production's answer to a page size that is no integer was not measured" },
        .{ .GET, "https://serviceusage.googleapis.com/v1/operations", "fake: this path is not modelled" },
        .{ .GET, "https://serviceusage.googleapis.com/v1/projects/my-project/services/a/b", "fake: this path is not modelled" },
    }) |case| {
        const reply = try b.fake.serve(.{ .method = case[0], .url = case[1], .bearer = "t" }, a);
        try testing.expectEqual(501, reply.status);
        try testing.expectEqualStrings(case[2], (try core.errors.decodeErrorBody(a, reply.body)).?.message);
    }
}

/// Random services, each enabled or not, put in any order; every filter
/// read to its end at a random page size through the client, against the
/// model's sorted list; a batch of random names in the order asked, and
/// one nobody put refused.
fn pagesProperty(_: void, input: []const u8) !void {
    const gpa = test_util.propertyAllocator();
    var g: test_util.ByteGen = .init(input);
    var b: Bench = undefined;
    try b.init(gpa, .{});
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const model = try putRandom(&g, &b.fake, a);
    for ([_]types.StateFilter{ .enabled, .disabled, .any }) |filter| {
        const size: u32 = if (g.boolean()) 0 else g.intRange(u8, 1, 7);
        const seen = try readToEnd(&b.client, a, filter, size, model.len);
        var want: std.ArrayList([]const u8) = .empty;
        for (model) |m| if (FakeServiceUsage.passes(filter, m.state)) try want.append(a, m.name);
        try testing.expectEqual(want.items.len, seen.len);
        for (want.items, seen) |w, s| try testing.expectEqualStrings(w, s);
    }

    if (model.len > 0) {
        const n = g.intRange(u8, 1, 5);
        const names = try a.alloc([]const u8, n);
        for (names) |*name| name.* = model[g.intRange(u8, 0, @intCast(@min(model.len - 1, 255)))].name;
        var got = try b.client.getServices(names);
        defer got.deinit();
        for (names, got.value) |want, s| try testing.expectEqualStrings(want, s.name);
    }
    try testing.expectError(error.PermissionDenied, b.client.getService("zigps-nobody.googleapis.com"));
}

/// Up to 40 services with short random names, each enabled or not, put
/// in the order made; the ones the fake took, in name order.
fn putRandom(g: *test_util.ByteGen, fake: *FakeServiceUsage, a: Allocator) ![]const FakeServiceUsage.Held {
    const Held = FakeServiceUsage.Held;
    const alphabet = "abz09.-";
    var model: std.ArrayList(Held) = .empty;
    const count = g.intRange(u8, 0, 40);
    for (0..count) |_| {
        const name = try a.alloc(u8, g.intRange(u8, 1, 4));
        for (name) |*c| c.* = alphabet[g.intRange(u8, 0, alphabet.len - 1)];
        const state: types.State = if (g.boolean()) .enabled else .disabled;
        fake.putService(.{ .name = name, .state = state }) catch |err| switch (err) {
            error.InvalidEntry => continue, // put already
            else => return err,
        };
        try model.append(a, .{ .name = name, .title = "", .summary = "", .state = state });
    }
    std.mem.sort(Held, model.items, {}, struct {
        fn less(_: void, x: Held, y: Held) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.less);
    return model.items;
}

/// Every name `filter` lists, page after page at `size`, each page full
/// but the last and each service passing the filter. A token means there
/// is more: production's enabled list answered none after its last
/// enabled service, with thousands of disabled ones after it.
fn readToEnd(client: *Client, a: Allocator, filter: types.StateFilter, size: u32, most: usize) ![]const []const u8 {
    const full: usize = if (size == 0) FakeServiceUsage.default_page_size else size;
    var seen: std.ArrayList([]const u8) = .empty;
    var token: ?[]const u8 = null;
    for (0..most + 2) |_| {
        var page = try client.listServices(.{ .state = filter, .page_size = size, .page_token = token });
        defer page.deinit();
        if (token != null) try testing.expect(page.value.services.len > 0);
        try testing.expect(page.value.services.len <= full);
        for (page.value.services) |s| {
            try testing.expect(FakeServiceUsage.passes(filter, s.state));
            try seen.append(a, try a.dupe(u8, s.name));
        }
        const next = page.value.next_page_token orelse return seen.items;
        try testing.expectEqual(full, page.value.services.len);
        token = try a.dupe(u8, next);
    }
    return error.TestUnexpectedResult; // more pages than services
}

test "fuzz fake pages: every filter read to its end at any page size is the model's sorted list" {
    try test_util.fuzzBytes({}, pagesProperty, .{ .corpus = &.{
        "",
        "\x05\x01a\x01\x02b\x00\x03c\x01\x01\x01\x02\x00\x03\x02",
        "\x28" ++ core.testing.repeat("\x02\x01\x02\x01", 40) ++ "\x00\x01\x02\x00",
    } });
}

test "every allocation failure in the fake is OutOfMemory without leaks" {
    const Run = struct {
        fn calls(gpa: Allocator) !void {
            var b: Bench = undefined;
            try b.init(gpa, probe);
            defer b.deinit();
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            try seedProbe(&b.fake, arena.allocator());
            var page = try b.client.listServices(.{ .page_size = 3 });
            defer page.deinit();
            var next = try b.client.listServices(.{ .page_size = 3, .page_token = page.value.next_page_token });
            next.deinit();
            var off = try b.client.listServices(.{ .state = .disabled, .page_size = 1 });
            defer off.deinit();
            var off_next = try b.client.listServices(.{ .state = .any, .page_size = 1, .page_token = off.value.next_page_token });
            off_next.deinit();
            var one = try b.client.getService("pubsub.googleapis.com");
            one.deinit();
            var two = try b.client.getServices(&.{ "pubsub.googleapis.com", a10 });
            two.deinit();
            if (b.client.getService("zigps-nope-316.googleapis.com")) |unexpected| {
                var u = unexpected;
                u.deinit();
                return error.TestUnexpectedResult;
            } else |err| if (err != error.PermissionDenied) return err;
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.calls, .{});
}
